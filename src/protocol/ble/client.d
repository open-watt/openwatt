module protocol.ble.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.uuid;

import manager;
import manager.base;
import manager.collection;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ble.iface;

version = DebugBLEClient;

nothrow @nogc:


alias NotifyDelegate = void delegate(ushort handle, const(ubyte)[] value) nothrow @nogc;
alias DiscoveryDoneDelegate = void delegate() nothrow @nogc;


class BLEClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("peer", peer));
nothrow @nogc:

    enum type_name = "ble-client";
    enum path = "/protocol/ble/client";
    enum collection_id = CollectionType.ble_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BLEClient, id, flags);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        restart();
    }

    MACAddress peer() const pure
        => _peer;
    void peer(MACAddress value)
    {
        if (_peer == value)
            return;
        _peer = value;
        restart();
    }

    // API

    bool discovery_complete()
    {
        if (!_connected)
            return false;
        auto session = ble_iface.find_session_by_peer(_peer);
        return session !is null && session.num_chars > 0;
    }

    ushort find_characteristic(GUID service, GUID char_uuid)
    {
        auto session = ble_iface.find_session_by_peer(_peer);
        if (session is null)
            return 0;
        foreach (ref c; session.chars[0 .. session.num_chars])
        {
            if (c.service_uuid == service && c.char_uuid == char_uuid)
                return c.handle;
        }
        return 0;
    }

    int write(ushort handle, const(ubyte)[] data, bool with_response = true, MessageCallback callback = null)
    {
        if (!_connected || !_iface || handle == 0)
            return -1;

        // ATT MTU is 247 (BLEInterface ctor), leaving 245 bytes for handle+value.
        ubyte[247] buf = void;
        if (2 + data.length > buf.length)
            return -1;
        buf.ptr[0 .. 2] = handle.nativeToLittleEndian;
        buf.ptr[2 .. 2 + data.length] = data[];

        Packet p;
        ref att = p.init!BLEATTFrame(buf[0 .. 2 + data.length]);
        att.src = local_mac;
        att.dst = _peer;
        att.opcode = with_response ? ATTOpcode.write_req : ATTOpcode.write_cmd;

        version (DebugBLEClient)
            log.trace("write ", with_response ? "req" : "cmd", " handle=", handle, " ", data.length, " bytes");

        return _iface.forward(p, callback);
    }

    int read(ushort handle, MessageCallback callback = null)
    {
        if (!_connected || !_iface || handle == 0)
            return -1;

        ubyte[2] payload = handle.nativeToLittleEndian;

        Packet p;
        ref att = p.init!BLEATTFrame(payload[]);
        att.src = local_mac;
        att.dst = _peer;
        att.opcode = ATTOpcode.read_req;
        return _iface.forward(p, callback);
    }

    void on_notify(ushort handle, NotifyDelegate callback)
    {
        _notify_handlers ~= NotifyHandler(handle, callback);
    }

    void clear_notify(ushort handle)
    {
        for (size_t i = 0; i < _notify_handlers.length;)
        {
            if (_notify_handlers[i].handle == handle)
                _notify_handlers.remove(i);
            else
                ++i;
        }
    }

    void on_discovery_done(DiscoveryDoneDelegate callback)
    {
        _discovery_handlers ~= callback;
    }

    void clear_discovery_done(DiscoveryDoneDelegate callback)
    {
        for (size_t i = 0; i < _discovery_handlers.length; ++i)
        {
            if (_discovery_handlers[i] is callback)
            {
                _discovery_handlers.remove(i);
                return;
            }
        }
    }

protected:
    mixin RekeyHandler;

    override bool validate() const
        => _iface !is null && cast(bool)_peer && (cast(const(BLEInterface))_iface.get) !is null;

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            PacketFilter filter;
            filter.type = PacketType.unknown; // accept all BLE packet types
            _iface.subscribe(&incoming_packet, filter);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }
        if (_connect_handle >= 0)
            return CompletionStatus.continue_;
        if (_connected)
            return CompletionStatus.complete;

        // send connect_ind to the interface
        Packet p;
        ref ll = p.init!BLELLFrame(null);
        ll.src = local_mac;
        ll.dst = _peer;
        ll.pdu_type = BLELLType.connect_ind;

        _connect_handle = _iface.forward(p, &on_connect_complete);

        if (_connect_handle < 0)
        {
            log.error("failed to submit connect request");
            return CompletionStatus.error;
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_connect_handle >= 0)
        {
            _iface.abort(_connect_handle);
            _connect_handle = -1;
        }

        if (_connected)
        {
            // send disconnect to the interface
            Packet p;
            ref ll = p.init!BLELLFrame(null);
            ll.src = local_mac;
            ll.dst = _peer;
            ll.pdu_type = BLELLType.disconnect_ind;
            _iface.forward(p);
            _connected = false;
        }

        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
    }

private:
    struct NotifyHandler
    {
        ushort handle;
        NotifyDelegate callback;
    }

    ObjectRef!BaseInterface _iface;
    MACAddress _peer;
    MACAddress _local_mac;
    int _connect_handle = -1;
    bool _subscribed;
    bool _connected;
    Array!NotifyHandler _notify_handlers;
    Array!DiscoveryDoneDelegate _discovery_handlers;

    BLEInterface ble_iface()
        => cast(BLEInterface)_iface.get;

    MACAddress local_mac()
    {
        if (!_local_mac)
        {
            import urt.crc;
            uint crc = name[].calculate_crc!(Algorithm.crc32_iso_hdlc);
            _local_mac = MACAddress(0x02, 0x13, 0x37, crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF);
        }
        return _local_mac;
    }

    void on_connect_complete(int handle, MessageState state)
    {
        if (state < MessageState.complete)
            return;

        _connect_handle = -1;

        if (state == MessageState.complete)
        {
            _connected = true;
            log.info("connected to ", _peer);
        }
        else
        {
            log.error("connection to ", _peer, " failed");
            restart();
        }
    }

    void incoming_packet(ref const Packet p, BaseInterface i, PacketDirection dir, void* user_data)
    {
        if (p.type == PacketType.ble_ll)
        {
            ref ll = p.hdr!BLELLFrame;
            if (ll.dst != local_mac)
                return;

            if (ll.pdu_type == BLELLType.disconnect_ind)
            {
                _connected = false;
                log.info("disconnected from ", _peer);
                restart();
            }
            else if (ll.pdu_type == BLELLType.discovery_done)
            {
                foreach (cb; _discovery_handlers[])
                    cb();
            }
            else if (ll.pdu_type == BLELLType.data_start || ll.pdu_type == BLELLType.data_continue)
                assert(false, "TODO: LL data PDU defragmentation not implemented in BLEClient");
        }
        else if (p.type == PacketType.ble_att)
        {
            ref att = p.hdr!BLEATTFrame;
            if (att.dst != local_mac)
                return;

            const(ubyte)[] payload = cast(const(ubyte)[])p.data;

            switch (att.opcode)
            {
                case ATTOpcode.notification:
                case ATTOpcode.indication:
                    if (payload.length < 2)
                        break;
                    ushort handle = payload.ptr[0 .. 2].littleEndianToNative!ushort;
                    const(ubyte)[] value = payload.length > 2 ? payload[2 .. $] : null;
                    size_t matched = 0;
                    foreach (ref h; _notify_handlers[])
                    {
                        if (h.handle == handle)
                        {
                            ++matched;
                            h.callback(handle, value);
                        }
                    }
                    version (DebugBLEClient)
                        log.trace(att.opcode == ATTOpcode.indication ? "indication" : "notification",
                                  " handle=", handle, " ", value.length, " bytes, ", matched, " handler(s)");
                    break;

                case ATTOpcode.read_rsp:
                    // TODO: demux to registered read callback by handle
                    log.info("read_rsp: [ ", cast(void[])payload, " ]");
                    break;

                case ATTOpcode.write_rsp:
                    // The forward callback already signalled completion to the caller.
                    version (DebugBLEClient)
                        log.trace("write_rsp (write acknowledged)");
                    break;

                default:
                    version (DebugBLEClient)
                        log.trace("unhandled ATT opcode ", att.opcode, " [ ", cast(void[])payload, " ]");
                    break;
            }
        }
    }


    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }
}
