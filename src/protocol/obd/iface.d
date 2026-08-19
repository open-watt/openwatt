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


// Whether the vehicle is answering. A parked car stops replying without the link
// failing, so this is reported rather than treated as an error.
enum VehicleState : ubyte
{
    unknown,  // nothing heard yet; neither state has been proven
    awake,
    asleep,
}


class OBDInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("interface", can_iface),
                                 Elem!("vehicle", VehicleState, ReadOnly));
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

    final VehicleState vehicle() const pure
        => prop_read!(typeof(this), "vehicle");

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
        {
            final switch (vehicle)
            {
                case VehicleState.unknown:  return "Waiting for the vehicle";
                case VehicleState.asleep:   return "Asleep";
                case VehicleState.awake:    return "Running";
            }
        }
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
        _unanswered = 0;

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
        set_vehicle(VehicleState.unknown);

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
                note_dispatched();
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
    MonoTime _unanswered_since;
    ubyte _unanswered;

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

        note_awake();

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

        note_awake();

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

    bool elm_send(const(char)[] cmd)
    {
        Stream s = _stream.get;
        if (!s)
            return false;
        version (DebugOBDInterface)
            log.debug_("elm tx: ", cmd);
        if (s.write(cmd, "\r") != cmd.length + 1)
        {
            log.warning("adapter write failed");
            elm_fail();
            return false;
        }
        _elm_busy = true;
        g_app.cancel(&elm_timeout_fired);
        g_app.schedule(getTime() + elm_timeout, &elm_timeout_fired);
        return true;
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
        if (elm_send(cmd[0 .. len]))
            note_dispatched();
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

    void set_vehicle(VehicleState value)
    {
        if (vehicle == value)
            return;
        prop_write!(typeof(this), "vehicle")(value);
        write_status();
    }

    // a message from the vehicle proves it regardless of backend, and must land before
    // the message reaches subscribers so they resume on the same event that woke it
    void note_awake()
    {
        _unanswered = 0;
        set_vehicle(VehicleState.awake);
    }

    // only a reply ends a run, even when dispatches are sparse
    void note_dispatched()
    {
        MonoTime now = getTime();
        if (_unanswered == 0)
            _unanswered_since = now;
        if (_unanswered <= unanswered_threshold)
            ++_unanswered;
        if (_unanswered > unanswered_threshold && now - _unanswered_since >= silence_timeout)
            set_vehicle(VehicleState.asleep);
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
        note_awake();

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
enum Duration silence_timeout = 15.seconds;
enum unanswered_threshold = 3;

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


// ====================================================================
// Tests
// ====================================================================

unittest
{
    import urt.mem.allocator;
    import manager.element : SampleUpdate;

    // with no stream and no CAN interface both transmit paths are inert
    static class TestOBD : OBDInterface
    {
    nothrow @nogc:
        uint notifications;
        bool saw_packet;
        VehicleState at_delivery;

        this() { super(CID(1)); }

        void on_vehicle(ref const SampleUpdate) { ++notifications; }

        void on_packet(ref const Packet, BaseInterface, PacketDirection, void*)
        {
            saw_packet = true;
            at_delivery = vehicle;
        }
    }

    // drives the adapter dispatch point; with no stream elm_send reports no write,
    // so this stands in for a request that never reached the adapter
    static void dispatch_unsent(TestOBD o) nothrow @nogc
    {
        OBDInterface.ElmRequest req;
        req.dst = 0x7E0;
        req.len = 2;
        static immutable ubyte[2] probe = [0x01, 0x00];
        req.data[0 .. 2] = probe[];
        req.handle = o._elm_tags.alloc();
        o._elm_pending = req;
        o._elm_pending_valid = true;
        o.elm_dispatch_pending();
    }

    // a run long enough in both count and elapsed span
    static void sustained_silence(TestOBD o) nothrow @nogc
    {
        o.note_dispatched();
        o._unanswered_since = getTime() - silence_timeout - 1.seconds;
        foreach (_; 0 .. unanswered_threshold)
            o.note_dispatched();
    }

    TestOBD o = defaultAllocator().allocT!TestOBD();
    scope (exit) defaultAllocator().freeT(o);
    o._elm_state = OBDInterface.ElmState.ready;
    o.prop_element(prop_index!(OBDInterface, "vehicle")).subscribe(&o.on_vehicle);

    assert(o.vehicle == VehicleState.unknown && o.notifications == 0);

    // any delivered message proves the vehicle, whichever backend produced it
    static immutable ubyte[3] rsp = [0x41, 0x00, 0x01];
    o.deliver_message(0x7E8, false, rsp[], getTime());
    assert(o.vehicle == VehicleState.awake && o.notifications == 1);

    // a request that never reached the adapter is not evidence of anything
    foreach (_; 0 .. unanswered_threshold * 4)
        dispatch_unsent(o);
    assert(o._unanswered == 0 && o.vehicle == VehicleState.awake);

    // a burst of unanswered requests is not sleep: the run has to last long enough
    // for a reply to have been possible
    foreach (_; 0 .. unanswered_threshold * 4)
        o.note_dispatched();
    assert(o.vehicle == VehicleState.awake && o.notifications == 1);

    // nor is a long-standing run of too few requests
    o.deliver_message(0x7E8, false, rsp[], getTime());
    o.note_dispatched();
    o._unanswered_since = getTime() - silence_timeout - 1.seconds;
    o.note_dispatched();
    assert(o.vehicle == VehicleState.awake);

    // a run that is sustained in both count and span concludes sleep
    o.deliver_message(0x7E8, false, rsp[], getTime());
    assert(o.notifications == 1);       // still awake; no edge
    sustained_silence(o);
    assert(o.vehicle == VehicleState.asleep && o.notifications == 2);

    // holding the verdict does not re-notify
    o.note_dispatched();
    assert(o.vehicle == VehicleState.asleep && o.notifications == 2);

    // the wake lands before the message reaches subscribers, and clears the run
    o.subscribe(&o.on_packet, PacketFilter(type: PacketType.obd, direction: PacketDirection.incoming));
    o.deliver_message(0x7E8, false, rsp[], getTime());
    assert(o.vehicle == VehicleState.awake && o.notifications == 3 && o._unanswered == 0);
    assert(o.saw_packet && o.at_delivery == VehicleState.awake);
    o.unsubscribe(&o.on_packet);

    // an elm frame proves the vehicle before isotp reassembly completes
    sustained_silence(o);
    assert(o.vehicle == VehicleState.asleep);
    static immutable char[] first_frame = "7E8 10 14 62 F1 90 4C 53";
    o._elm_line[0 .. first_frame.length] = first_frame[];
    o._elm_line_len = cast(ushort)first_frame.length;
    o.elm_line();
    assert(o.vehicle == VehicleState.awake);

    // status chatter is not a reply and must not wake it
    sustained_silence(o);
    assert(o.vehicle == VehicleState.asleep);
    static immutable char[] chatter = "NO DATA";
    o._elm_line[0 .. chatter.length] = chatter[];
    o._elm_line_len = cast(ushort)chatter.length;
    o.elm_line();
    assert(o.vehicle == VehicleState.asleep);

    // a recognised response id proves the vehicle at recognition: this frame joins
    // no reassembly session and is discarded, yet it still wakes it
    static immutable ubyte[8] orphan = [0x21, 0x57, 0x37, 0x34, 0x30, 0x39, 0x33, 0x4D];
    Packet cp;
    ref CANFrame can = cp.init!CANFrame(orphan[]);
    can.id = 0x7E8;
    o.can_packet_handler(cp, null, PacketDirection.incoming, null);
    assert(o.vehicle == VehicleState.awake);

    // a frame that is not a diagnostic response proves nothing
    sustained_silence(o);
    assert(o.vehicle == VehicleState.asleep);
    ref CANFrame other = cp.init!CANFrame(orphan[]);
    other.id = 0x123;
    o.can_packet_handler(cp, null, PacketDirection.incoming, null);
    assert(o.vehicle == VehicleState.asleep);

    // an accepted dispatch reaches g_app through elm_send's timeout arming, and
    // shutdown() cancels that timer, so neither is covered by a unittest.

    o.prop_element(prop_index!(OBDInterface, "vehicle")).unsubscribe(&o.on_vehicle);
}
