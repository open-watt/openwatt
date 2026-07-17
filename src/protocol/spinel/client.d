module protocol.spinel.client;

import urt.log;
import urt.mem.allocator;
import urt.mem.temp : tformat;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager.base;
import manager.collection : CollectionType;
import manager.plugin;

import router.iface;

import protocol.spinel;

//version = DebugMessageFlow;

nothrow @nogc:


//
// Spinel is the host<->radio protocol spoken by Thread / 802.15.4 radio co-processors (RCPs).
// https://datatracker.ietf.org/doc/html/draft-rquattle-spinel-unified-00
//
// The wire framing is transport-specific and lives OUTSIDE this client: over a bare UART the frames are
// HDLC-lite delimited, but over a Silicon Labs multi-PAN co-processor they ride a CPCEndpoint which does
// its own framing. Either way the transport is a BaseInterface that hands us decapsulated spinel frames as
// RawFrame packets and accepts RawFrames to transmit. This client speaks only the spinel command layer.
//
class SpinelClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("iid", iid),
                                 Prop!("protocol-version", protocol_version, "status"),
                                 Prop!("ncp-version", ncp_version, "status"));
nothrow @nogc:

    enum type_name = "spinel";
    enum path = "/protocol/spinel/client";
    enum collection_id = CollectionType.spinel;

    this(CID id, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!SpinelClient, id, flags);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure nothrow
        => _iface.get;
    final void iface(BaseInterface value) nothrow
    {
        if (_iface.get is value)
            return;
        unsubscribe_iface();
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    // spinel interface identifier (bits 5..4 of the frame header). multi-PAN co-processors route frames by
    // IID; single-instance NCPs use 0. Silabs' zigbeed defaults to 1 -- exposed so it can be varied live.
    final ubyte iid() const pure nothrow
        => _iid;
    final void iid(ubyte value) nothrow
    {
        _iid = value & 3;
        mark_set!(typeof(this), "iid")();
        restart();
    }

    final String protocol_version() const pure nothrow
        => _protocol_version;

    final String ncp_version() const pure nothrow
        => _ncp_version;

protected:

    override bool validate() const pure
        => _iface !is null;

    override CompletionStatus startup()
    {
        BaseInterface i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            PacketFilter filter;
            filter.type = PacketType.raw;
            filter.direction = PacketDirection.incoming;
            i.subscribe(&incoming_packet, filter);
            i.subscribe(&iface_state_change);
            _subscribed = true;
        }

        if (_have_ncp_version)
            return CompletionStatus.complete;

        MonoTime now = getTime();
        if (_first_attempt == MonoTime())
            _first_attempt = now;
        else if (now - _first_attempt > connect_timeout)
        {
            log.error("no response from spinel secondary on '", i.name, "'");
            return CompletionStatus.error;
        }

        // Always lead with a spinel RESET, then wait for the unsolicited LAST_STATUS reset notice (proof the
        // RCP is alive and parsing our frames) before interrogating -- this is exactly what the OpenThread host
        // does (SpinelDriver::Init resets before any query). RESET is a stack reset, so it doesn't drop CPC.
        // Firing everything at once is wrong on a window-1 transport: only the first frame reaches the wire.
        if (!_reset_sent)
        {
            send_command!(Command.RESET)();
            _reset_sent = true;
            _last_attempt = now;
            return CompletionStatus.continue_;
        }
        if (!_reset_seen)
        {
            if (now - _last_attempt >= request_interval)
            {
                if (++_reset_retries > max_reset_retries)
                    _reset_seen = true; // give up waiting; not all RCPs announce a reset -- try querying anyway
                else
                    send_command!(Command.RESET)();
                _last_attempt = now;
            }
            if (!_reset_seen)
                return CompletionStatus.continue_;
        }

        // interrogate versions once the reset notice has landed (or we gave up waiting for it)
        if (_last_attempt == MonoTime() || now - _last_attempt >= request_interval)
        {
            send_command!(Command.PROP_VALUE_GET)(SpinelProperty.PROTOCOL_VERSION);
            send_command!(Command.PROP_VALUE_GET)(SpinelProperty.NCP_VERSION);
            _last_attempt = now;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_iface();
        _have_ncp_version = false;
        _reset_sent = false;
        _reset_seen = false;
        _reset_retries = 0;
        _protocol_version = null;
        _ncp_version = null;
        _first_attempt = MonoTime();
        _last_attempt = MonoTime();
        _txid = 1;
        return CompletionStatus.complete;
    }

private:
    ObjectRef!BaseInterface _iface;
    bool _subscribed;
    bool _reset_sent;
    bool _reset_seen;
    bool _have_ncp_version;
    ubyte _iid;
    ubyte _txid = 1;
    ubyte _reset_retries;
    MonoTime _first_attempt;
    MonoTime _last_attempt;

    String _protocol_version;
    String _ncp_version;

    enum connect_timeout = 10.seconds;
    enum request_interval = 1.seconds;
    enum max_reset_retries = 3;

    // Send a spinel command whose payload matches its format table entry. The frame is
    // [header][command:i][args...]; the transport interface frames it on the wire.
    bool send_command(Command cmd)(SpinelTypeTuple!(command_format(cmd)) args)
    {
        enum string fmt = 'i' ~ command_format(cmd);

        ubyte[128] msg = void;
        msg[0] = cast(ubyte)(0x80 | ((_iid & 3) << 4) | (_txid & 0x0F));    // FLG | IID | TID

        size_t len = 1 + SpinelTuple!fmt(cmd, args).spinelSerialise!fmt(msg[1..$]);

        version (DebugMessageFlow)
        {
            static if (args.length == 0)
                log.debug_("--> ", cmd);
            else
                log.debug_("--> ", cmd, " ", SpinelTuple!fmt(args));
        }

        if (!send_frame(msg[0..len]))
            return false;
        _txid = _txid == 0xF ? 1 : cast(ubyte)(_txid + 1);
        return true;
    }

    bool send_frame(const(ubyte)[] msg)
    {
        BaseInterface i = _iface.get;
        if (!i)
            return false;
        Packet p;
        p.init!RawFrame(msg);
        return i.forward(p) >= 0;
    }

    void incoming_packet(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        const(ubyte)[] buf = cast(const(ubyte)[])p.data();
        // Silabs multi-PAN CPC 15.4 framing packs one or more spinel frames per CPC transfer, each prefixed
        // with a 2-byte big-endian length (RCP->host only; our host->RCP frames go bare and are accepted). A
        // frame whose first byte already has the FLG bit set is taken as a bare, unprefixed spinel frame.
        while (buf.length >= 1)
        {
            if ((buf[0] & 0x80) != 0)
            {
                parse_spinel_frame(buf);
                return;
            }
            if (buf.length < 2)
                return;
            size_t len = (size_t(buf[0]) << 8) | buf[1];
            buf = buf[2 .. $];
            if (len == 0 || len > buf.length)
                return;
            parse_spinel_frame(buf[0 .. len]);
            buf = buf[len .. $];
        }
    }

    void parse_spinel_frame(const(ubyte)[] frame)
    {
        if (frame.length < 2 || (frame[0] & 0x80) == 0)     // FLG bit must be set
            return;

        const(ubyte)[] buf = frame[1..$];
        uint cmd = read_packed_uint(buf);

        switch (cmd)
        {
            case Command.PROP_VALUE_IS:
            case Command.PROP_VALUE_INSERTED:
            case Command.PROP_VALUE_REMOVED:
                uint key = read_packed_uint(buf);
                handle_property(key, buf);
                break;
            default:
                version (DebugMessageFlow)
                    log.debug_("<-- cmd ", cmd, " (", buf.length, " bytes)");
                break;
        }
    }

    void handle_property(uint key, const(ubyte)[] value)
    {
        switch (key)
        {
            case SpinelProperty.LAST_STATUS:
                uint status = read_packed_uint(value);
                _reset_seen = true;     // any status reply proves the RCP is alive and parsing our frames
                log.info("last status: ", status);
                break;

            case SpinelProperty.PROTOCOL_VERSION:
                uint major = read_packed_uint(value);
                uint minor = read_packed_uint(value);
                _protocol_version = tformat("{0}.{1}", major, minor).makeString(defaultAllocator());
                mark_set!(typeof(this), "protocol-version")();  // flag dirty so the sync layer pushes it to the UI
                log.info("protocol version ", major, ".", minor);
                break;

            case SpinelProperty.NCP_VERSION:
                const(char)[] ver = read_utf8(value);
                _ncp_version = ver.makeString(defaultAllocator());
                _have_ncp_version = true;
                mark_set!(typeof(this), "ncp-version")();
                log.info("ncp version: ", ver);
                break;

            default:
                version (DebugMessageFlow)
                    log.debug_("<-- prop ", key, " (", value.length, " bytes)");
                break;
        }
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
        else if (signal == StateSignal.destroyed)
        {
            // the subscription died with the interface; drop our bookkeeping and let restart re-bind
            _subscribed = false;
            restart();
        }
    }

    void unsubscribe_iface() nothrow
    {
        if (!_subscribed)
            return;
        if (BaseInterface i = _iface.get)
        {
            i.unsubscribe(&incoming_packet);
            i.unsubscribe(&iface_state_change);
        }
        _subscribed = false;
    }

    static uint read_packed_uint(ref const(ubyte)[] buf) pure
    {
        uint v = 0;
        int shift = 0;
        while (buf.length)
        {
            ubyte b = buf[0];
            buf = buf[1..$];
            v |= uint(b & 0x7F) << shift;
            if ((b & 0x80) == 0)
                break;
            shift += 7;
        }
        return v;
    }

    static const(char)[] read_utf8(const(ubyte)[] value) pure
    {
        size_t n = value.length;
        foreach (idx, b; value)
        {
            if (b == 0)
            {
                n = idx;
                break;
            }
        }
        return cast(const(char)[])value[0 .. n];
    }
}
