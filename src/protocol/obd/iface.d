module protocol.obd.iface;

import urt.array;
import urt.conv;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.string.ascii;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.stream;

import protocol.can.iface;
import protocol.obd.isotp;

//version = DebugOBDInterface;

nothrow @nogc:


enum uint obd_functional_11 = 0x7DF;
enum uint obd_functional_29 = 0x18DB33F1;

struct OBDFrame
{
    enum Type = PacketType.obd;

    uint src_id;    // sender arbitration id; 0 = the local tester
    uint dst_id;    // destination arbitration id; 0 = the local tester
    bool extended;

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!OBDFrame().src_id;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.obd) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!OBDFrame().dst_id;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.obd) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
    {
        uint id = cast(uint)(address & 0xFFFFFFFFFFFF);
        return id == obd_functional_11 || id == obd_functional_29;
    }

    // OW encapsulation wire codec: [src:4 BE][dst:4 BE][flags:1] (bit0 = extended)
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        if (buffer.length < 9)
            return -1;
        ref const f = p.hdr!OBDFrame;
        buffer[0 .. 4] = f.src_id.nativeToBigEndian;
        buffer[4 .. 8] = f.dst_id.nativeToBigEndian;
        buffer[8] = f.extended ? 1 : 0;
        return 9;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        if (header.length < 9)
            return -1;
        p.type = PacketType.obd;
        ref f = p.hdr!OBDFrame;
        f.src_id = header[0 .. 4].bigEndianToNative!uint;
        f.dst_id = header[4 .. 8].bigEndianToNative!uint;
        f.extended = (header[8] & 1) != 0;
        return 9;
    }
}


class OBDInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("interface", can_iface));
nothrow @nogc:

    enum type_name = "obd";
    enum path = "/interface/obd";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!OBDInterface, id, flags);

        mtu = isotp_max_message;
        _max_l2mtu = mtu;
        l2mtu = _max_l2mtu;
        mark_set!(typeof(this), "max-l2mtu")();
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream value)
    {
        if (_stream is value)
            return;
        release_source();
        _stream = value;
        _can = null;
        _backend = Backend.elm327;
        mark_set!(typeof(this), [ "stream", "interface" ])();
        restart();
    }

    final inout(CANInterface) can_iface() inout pure
        => _can.get;
    final void can_iface(CANInterface value)
    {
        if (_can.get is value)
            return;
        release_source();
        _can = value;
        _stream = null;
        _backend = Backend.can;
        mark_set!(typeof(this), [ "stream", "interface" ])();
        restart();
    }

    // API...

    // a live handle is always pre-dispatch: the handle is released at the request write,
    // so nothing queryable is ever on the wire
    final override MessageState msg_state(int msg_handle) const
    {
        if (_elm_pending_valid && _elm_pending.handle == msg_handle)
            return MessageState.queued;
        for (size_t i = 0; i < _elm_queue.length; ++i)
        {
            if (_elm_queue[i].handle == msg_handle)
                return MessageState.queued;
        }
        return MessageState.complete;
    }

    override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        if (_elm_pending_valid && _elm_pending.handle == msg_handle)
        {
            _elm_pending_valid = false;
            finish_request(_elm_pending, reason);
            return;
        }
        for (size_t i = 0; i < _elm_queue.length; ++i)
        {
            if (_elm_queue[i].handle == msg_handle)
            {
                ElmRequest req = _elm_queue[i];
                _elm_queue.remove(i);
                finish_request(req, reason);
                return;
            }
        }
    }

    override const(char)[] status_message() const
    {
        if (running)
            return "Running";
        final switch (_backend)
        {
            case Backend.none:
                break;
            case Backend.elm327:
                if (!_stream || !_stream.get.running)
                    return "Waiting for stream";
                if (_elm_state != ElmState.ready)
                    return "Initialising ELM327";
                break;
            case Backend.can:
                if (!_can || !_can.get.running)
                    return "Waiting for CAN interface";
                break;
        }
        return super.status_message();
    }

protected:

    override bool validate() const
    {
        final switch (_backend)
        {
            case Backend.none:
                return false;
            case Backend.elm327:
                return _stream.get !is null;
            case Backend.can:
                return _can.get !is null;
        }
    }

    override CompletionStatus startup()
    {
        final switch (_backend)
        {
            case Backend.none:
                return CompletionStatus.error;

            case Backend.elm327:
                Stream s = _stream.get;
                if (!s || !s.running)
                    return CompletionStatus.continue_;
                if (!_subscribed)
                {
                    s.subscribe(&source_state_change);
                    s.rx_handler(&stream_rx);
                    _subscribed = true;
                }
                if (_elm_state == ElmState.reset)
                {
                    _elm_state = ElmState.init_;
                    _elm_init_step = 0;
                    elm_send("ATZ");
                }
                if (_elm_state == ElmState.failed)
                {
                    _fail_reason = "ELM327 not responding";
                    _elm_state = ElmState.reset;
                    return CompletionStatus.error;
                }
                if (_elm_state != ElmState.ready)
                    return CompletionStatus.continue_;
                return CompletionStatus.complete;

            case Backend.can:
                CANInterface i = _can.get;
                if (!i || !i.running)
                    return CompletionStatus.continue_;
                i.subscribe(&can_packet_handler, PacketFilter(type: PacketType.can, direction: PacketDirection.incoming));
                i.subscribe(&source_state_change);
                _subscribed = true;
                return CompletionStatus.complete;
        }
    }

    override CompletionStatus shutdown()
    {
        release_source();

        g_app.cancel(&elm_timeout_fired);
        elm_drain_queue(MessageState.failed);
        _reassembler.reset();
        _elm_state = ElmState.reset;
        _elm_line_len = 0;
        _elm_busy = false;
        _elm_recover = 0;
        _elm_header = 0;

        return CompletionStatus.complete;
    }


    override int transmit(ref const Packet packet, MessageCallback callback, const(QueuePolicy)*)
    {
        if (packet.type != PacketType.obd)
        {
            add_tx_drop();
            return -1;
        }

        ref const f = packet.hdr!OBDFrame;
        const(ubyte)[] payload = cast(const(ubyte)[])packet.data;

        // TODO: multi-frame transmit (ISO-TP FF/CF with flow control); no OBD polling request needs it
        if (payload.length == 0 || payload.length > 7)
        {
            add_tx_drop();
            return -1;
        }

        uint dst = f.dst_id ? f.dst_id : (f.extended ? obd_functional_29 : obd_functional_11);

        final switch (_backend)
        {
            case Backend.none:
                add_tx_drop();
                return -1;

            case Backend.elm327:
                // TODO: 29-bit ELM addressing needs ATSP6/7 + ATCP; until then reject
                // rather than transmit under a stale 11-bit header
                if (f.extended || dst > 0x7FF)
                {
                    add_tx_drop();
                    return -1;
                }
                int handle = _elm_queue.length < 8 ? _elm_tags.alloc() : -1;
                if (handle < 0)
                {
                    add_tx_drop();
                    return -1;
                }
                ElmRequest* r = &_elm_queue.pushBack();
                r.dst = dst;
                r.len = cast(ubyte)payload.length;
                r.data[0 .. payload.length] = payload[];
                r.handle = handle;
                r.cb = callback;
                add_tx_frame(payload.length);
                elm_service();
                return handle;

            case Backend.can:
                Packet p;
                ubyte[8] frame = void;
                isotp_single(payload, frame);
                ref CANFrame can = p.init!CANFrame(frame[], packet.creation_time);
                can.id = dst;
                can.extended = f.extended || dst > 0x7FF;
                if (_can.forward(p) < 0)
                {
                    add_tx_drop();
                    return -1;
                }
                add_tx_frame(payload.length);
                return 0;
        }
    }

private:
    enum Backend : ubyte
    {
        none,
        elm327,
        can,
    }

    enum ElmState : ubyte
    {
        reset,
        init_,
        ready,
        failed,
    }

    struct ElmRequest
    {
        uint dst;
        ubyte len;
        ubyte[7] data;
        int handle;
        MessageCallback cb;
    }

    ObjectRef!Stream _stream;
    ObjectRef!CANInterface _can;
    Backend _backend;
    bool _subscribed;

    IsoTpReassembler _reassembler;

    ElmState _elm_state;
    ubyte _elm_init_step;
    ubyte _elm_recover;
    bool _elm_busy;
    uint _elm_header;
    char[128] _elm_line = void;
    ushort _elm_line_len;
    Array!ElmRequest _elm_queue;
    TagAllocator _elm_tags;

    static immutable string[4] elm_init_cmds = [ "ATE0", "ATL0", "ATS1", "ATH1" ];
    enum elm_final_cmd = "ATSP0";

    void release_source()
    {
        if (!_subscribed)
            return;
        if (_backend == Backend.can)
        {
            _can.unsubscribe(&can_packet_handler);
            _can.unsubscribe(&source_state_change);
        }
        else
        {
            if (Stream s = _stream.get)
                s.release_rx_handler(&stream_rx);
            _stream.unsubscribe(&source_state_change);
        }
        _subscribed = false;
    }

    void source_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void deliver_message(uint src_id, bool extended, const(ubyte)[] message, MonoTime rx_time)
    {
        version (DebugOBDInterface)
            log.debug_("rx from ", src_id, ": [ ", cast(const(void)[])message, " ]");

        Packet p;
        ref OBDFrame f = p.init!OBDFrame(message, rx_time);
        f.src_id = src_id;
        f.dst_id = 0;
        f.extended = extended;
        incoming_packet(p);
    }

    // --- CAN backend ---

    void can_packet_handler(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        if (p.type != PacketType.can)
            return;

        ref const can = p.hdr!CANFrame;

        uint fc_id = 0;
        if (!can.extended && can.id >= 0x7E8 && can.id <= 0x7EF)
            fc_id = can.id - 8;
        else if (can.extended && (can.id & 0x1FFFFF00) == 0x18DAF100)
            fc_id = 0x18DA0000 | ((can.id & 0xFF) << 8) | 0xF1;
        else
            return; // TODO: ECU table for non-convention id pairings

        const(ubyte)[] message;
        final switch (_reassembler.feed(can.id, cast(const(ubyte)[])p.data, message))
        {
            case IsoTpResult.complete:
                deliver_message(can.id, can.extended, message, p.creation_time);
                return;

            case IsoTpResult.need_fc:
                Packet fc;
                ubyte[8] frame = void;
                isotp_flow_control(frame);
                ref CANFrame tx = fc.init!CANFrame(frame[]);
                tx.id = fc_id;
                tx.extended = can.extended;
                _can.forward(fc);
                return;

            case IsoTpResult.none:
            case IsoTpResult.flow_control:
                return;

            case IsoTpResult.error:
                add_rx_drop();
                return;
        }
    }

    // --- ELM327 backend ---

    void elm_send(const(char)[] cmd)
    {
        Stream s = _stream.get;
        if (!s)
            return;
        version (DebugOBDInterface)
            log.debug_("elm tx: ", cmd);
        if (s.write(cmd, "\r") != cmd.length + 1)
        {
            log.warning("adapter write failed");
            elm_fail();
            return;
        }
        _elm_busy = true;
        g_app.cancel(&elm_timeout_fired);
        g_app.schedule(getTime() + elm_timeout, &elm_timeout_fired);
    }

    void elm_fail()
    {
        _elm_busy = false;
        _elm_state = ElmState.failed;
        // while Starting the state machine observes the failed state and backs off;
        // while Running it must be kicked back through init
        if (running)
            restart();
    }

    void elm_timeout_fired(MonoTime)
    {
        if (!_elm_busy)
            return;
        version (DebugOBDInterface)
            log.debug_("elm response timeout");
        if (_elm_state == ElmState.init_)
        {
            _elm_state = ElmState.failed;
            _elm_busy = false;
            return;
        }
        if (++_elm_recover >= elm_recover_limit)
        {
            log.warning("adapter unresponsive");
            elm_fail();
            return;
        }
        // any RS232 char interrupts a busy ELM327 and ATI answers with a fresh prompt
        // without touching the bus; a bare CR would repeat the last command
        elm_send("ATI");
    }

    void stream_rx(Stream, const(void)[] data, MonoTime)
    {
        foreach (c; cast(const(char)[])data)
        {
            if (c == '>')
            {
                elm_line();
                elm_prompt();
            }
            else if (c == '\r' || c == '\n')
                elm_line();
            else if (_elm_line_len < _elm_line.length)
                _elm_line[_elm_line_len++] = c;
        }
    }

    void elm_service()
    {
        if (_elm_busy || _elm_state != ElmState.ready || _elm_pending_valid || _elm_queue.empty)
            return;

        _elm_pending = _elm_queue[0];
        _elm_queue.remove(0);
        _elm_pending_valid = true;

        if (_elm_pending.dst != _elm_header)
        {
            char[16] cmd = void;
            cmd[0 .. 4] = "ATSH";
            size_t len = 4 + format_uint(_elm_pending.dst, cmd[4 .. $], 16, 3, '0');
            _elm_header = _elm_pending.dst;
            elm_send(cmd[0 .. len]);
            return;
        }
        elm_dispatch_pending();
    }

    // the dispatch notification is the requester's cue to start its response timing
    void elm_dispatch_pending()
    {
        ElmRequest req = _elm_pending;
        _elm_pending_valid = false;

        char[16] cmd = void;
        size_t len = 0;
        foreach (b; req.data[0 .. req.len])
        {
            cmd[len++] = hex_digits[b >> 4];
            cmd[len++] = hex_digits[b & 0xF];
        }
        elm_send(cmd[0 .. len]);
        finish_request(req, _elm_state == ElmState.failed ? MessageState.failed : MessageState.complete);
    }

    void finish_request(ref const ElmRequest req, MessageState state)
    {
        _elm_tags.free(cast(ubyte)req.handle);
        if (req.cb)
            req.cb(req.handle, state);
    }

    void elm_drain_queue(MessageState state)
    {
        if (_elm_pending_valid)
        {
            _elm_pending_valid = false;
            finish_request(_elm_pending, state);
        }
        while (!_elm_queue.empty)
        {
            ElmRequest req = _elm_queue[0];
            _elm_queue.remove(0);
            finish_request(req, state);
        }
    }

    void elm_prompt()
    {
        _elm_busy = false;
        _elm_recover = 0;
        g_app.cancel(&elm_timeout_fired);

        if (_elm_state == ElmState.init_)
        {
            if (_elm_init_step < elm_init_cmds.length)
                elm_send(elm_init_cmds[_elm_init_step++]);
            else if (_elm_init_step == elm_init_cmds.length)
            {
                ++_elm_init_step;
                elm_send(elm_final_cmd);
            }
            else
                _elm_state = ElmState.ready;
            return;
        }

        if (_elm_pending_valid)
        {
            elm_dispatch_pending();
            return;
        }

        elm_service();
    }

    void elm_line()
    {
        const(char)[] line = _elm_line[0 .. _elm_line_len].trim;
        _elm_line_len = 0;
        if (line.empty || _elm_state != ElmState.ready)
            return;

        version (DebugOBDInterface)
            log.debug_("elm rx: ", line);

        // data lines with headers on: "7E8 06 41 0C 1A F8 00 00"
        const(char)[] tail = line;
        const(char)[] tok = tail.split!' ';
        if (tok.length != 3 || !all_hex(tok))
            return; // status chatter: SEARCHING..., NO DATA, OK, errors

        size_t taken;
        uint id = cast(uint)tok.parse_uint(&taken, 16);
        if (taken != tok.length)
            return;

        ubyte[8] frame = void;
        size_t n = 0;
        while (n < frame.length)
        {
            tok = tail.split!' ';
            if (tok.empty)
                break;
            if (tok.length != 2 || !all_hex(tok))
                return;
            frame[n++] = cast(ubyte)tok.parse_uint(&taken, 16);
        }
        if (n == 0)
            return;

        const(ubyte)[] message;
        if (_reassembler.feed(id, frame[0 .. n], message) == IsoTpResult.complete)
            deliver_message(id, false, message, getTime());
    }

    ElmRequest _elm_pending;
    bool _elm_pending_valid;
}


private:

enum Duration elm_timeout = 3.seconds;
enum elm_recover_limit = 3;

immutable char[16] hex_digits = "0123456789ABCDEF";

bool all_hex(const(char)[] s) pure
{
    foreach (c; s)
    {
        if (!is_hex(c))
            return false;
    }
    return true;
}
