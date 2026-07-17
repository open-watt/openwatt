module protocol.ezsp.client;

import urt.array;
import urt.endian;
import urt.fibre;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta : AliasSeq;
import urt.result;
import urt.string;
import urt.time;
import urt.traits;

import manager.base;
import manager.plugin;

import router.iface;
import router.stream;

import protocol.ezsp;
import protocol.ezsp.ashv2;

public import protocol.ezsp.commands;

//version = DebugMessageFlow;
//version = DebugZigbeeLatency;

nothrow @nogc:


//
// EZSP (EmberZNet Serial Protocol) is a protocol used by EmberZNet to communicate with the radio chip.
// https://www.silabs.com/documents/public/user-guides/ug100-ezsp-reference-guide.pdf
//

enum EZSPStackType : ubyte
{
    unknown = 0,
    router = 1,
    coordinator = 2
}

enum IsEZSPRequest(T) = is(typeof(T.Command) : ushort) && is(T.Request == struct) && is(T.Response == struct);

template EZSPArgs(T)
{
    static assert(IsEZSPRequest!T, T.stringof ~ " is not an EZSP command structure");
    alias EZSPArgs = typeof(T.Request.tupleof);
}

template EZSPResult(T)
{
    static assert(IsEZSPRequest!T, T.stringof ~ " is not an EZSP command structure");
    static if (T.Response.tupleof.length == 0)
        alias EZSPResult = void;
    else static if (T.Response.tupleof.length == 1)
        alias EZSPResult = typeof(T.Response.tupleof[0]);
    else
        alias EZSPResult = T.Response;
}

class EZSPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("ash-stream", ash_stream),
                                 Prop!("ash-interface", ash_interface),
                                 Prop!("concurrency", concurrency),
                                 Prop!("stack-type", stack_type, "status"),
                                 Prop!("stack-version", stack_version, "status"),
                                 Prop!("protocol-version", protocol_version, "status"),
                                 Prop!("queued", queued_count, "status"),
                                 Prop!("peak-queue", peak_queue, "status"));
@nogc:

    enum type_name = "ezsp";
    enum path = "/protocol/ezsp/client";
    enum collection_id = CollectionType.ezsp;

    this(CID id, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!EZSPClient, id, flags);
    }

    // Properties...

    final inout(Stream) ash_stream() inout pure nothrow
        => _stream;
    final void ash_stream(Stream stream) nothrow
    {
        if (_stream is stream)
            return;
        _stream = stream;
        _ash_ext = null;
        mark_set!(typeof(this), [ "ash-stream", "ash-interface" ])();
        restart();
    }

    final inout(ASHInterface) ash_interface() inout pure nothrow
        => _ash_ext;
    final void ash_interface(ASHInterface iface) nothrow
    {
        if (_ash_ext is iface)
            return;
        _ash_ext = iface;
        _stream = null;
        mark_set!(typeof(this), [ "ash-interface", "ash-stream" ])();
        restart();
    }

    final ubyte concurrency() const pure nothrow
        => _concurrency;
    final StringResult concurrency(ubyte value) nothrow
    {
        if (value < 1 || value > 5)
            return StringResult("concurrency must be between 1 and 5");
        if (_concurrency == value)
            return StringResult.success;

        ubyte previous = _concurrency;
        _concurrency = value;
        if (_ash)
        {
            StringResult result = _ash.window(value);
            if (!result)
            {
                _concurrency = previous;
                return result;
            }
        }
        mark_set!(typeof(this), "concurrency")();
        if (running)
            send_queued_message();
        return StringResult.success;
    }

    final EZSPStackType stack_type() const pure nothrow
        => _stack_type;

    final String stack_version() const pure nothrow
        => _stack_version;

    final ubyte protocol_version() const pure nothrow
        => _known_version;

    final size_t queued_count() const pure nothrow
        => _queued_requests.length;
    final ushort peak_queue() const pure nothrow
        => _peak_queue;

    // API...

    final void reboot_ncp() nothrow
    {
        send_command!EZSP_ResetNode(null);
        restart();
    }

    EZSPResult!R request(R)(auto ref EZSPArgs!R args)
        if (IsEZSPRequest!R)
    {
        import urt.util : InPlace, Default;

        assert(isInFibre(), "EZSPClient.request() must be called from a fibre context");

        struct Result
        {
            YieldEZSP e;
            static if (!is(EZSPResult!R == void))
                EZSPResult!R result;
        }

        Result r;
        auto ev = InPlace!YieldEZSP(Default);
        r.e = ev;

        static void response(void* user_data, typeof(R.Response.tupleof) results)
        {
            Result* r = cast(Result*)user_data;
            r.e.finished = true;
            enum numResults = R.Response.tupleof.length;
            static if (numResults > 1)
            {
                static foreach (i; 0 .. numResults)
                    r.result.tupleof[i] = results[i];
            }
            else static if (numResults == 1)
                r.result = results[0];
        }

        bool success = send_command!R(&response, forward!args, cast(void*)&r);
        assert(success, "EZSP: failed to send command!");

        yield(ev);

        static if (!is(EZSPResult!R == void))
            return r.result;
    }

nothrow:
    final void set_message_handler(void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc callback) pure nothrow
    {
        _message_handler = callback;
    }

    template set_callback_handler(EZSP_Command)
        if (IsEZSPRequest!EZSP_Command)
    {
        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final void set_callback_handler(Callback)(Callback response_handler, void* user_data = null) nothrow
        {
            static if (is(Callback == typeof(null)))
            {
                _command_handlers.replace(EZSP_Command.Command, CommandHandler());
            }
            else
            {
                alias Args = Parameters!Callback;
                static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* user_data` argument in the first position.");
                enum HasUserData = Args.length > 0 && is(Args[0] == void*);

                version(DebugMessageFlow)
                {
                    import urt.string.format;
                    if ((EZSP_Command.Command in commandNames) is null)
                        commandNames.insert(EZSP_Command.Command, CommandData(EZSP_Command.stringof[5 .. $],
                                                                              (const(ubyte)[] data){ EZSP_Command.Request r; data.ezsp_deserialise(r); return tconcat(r); },
                                                                              (const(ubyte)[] data){ EZSP_Command.Response r; data.ezsp_deserialise(r); return tconcat(r); }));
                }

                auto handler = &_command_handlers.replace(EZSP_Command.Command, CommandHandler());

                handler.response_shim = &response_shim!(HasUserData, ResponseParams);
                handler.user_data = HasUserData ? user_data : null;
                static if (is_delegate!Callback)
                {
                    handler.cb_funcptr = response_handler.funcptr;
                    handler.cb_instance = response_handler.ptr;
                }
                else
                {
                    handler.cb_funcptr = response_handler;
                    handler.cb_instance = null;
                }
            }
        }
    }

    template send_command(EZSP_Command)
        if (IsEZSPRequest!EZSP_Command)
    {
        alias RequestParams = typeof(EZSP_Command.Request.tupleof);
        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final bool send_command(Callback)(Callback response_handler, auto ref RequestParams args,
                                          void* user_data = null, ubyte priority = 1, bool dei = false)
        {
            if (!running)
                return false;

            static if (!is(Callback == typeof(null)))
            {
                alias Args = Parameters!Callback;
                static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* user_data` argument in the first position.");
                enum HasUserData = Args.length > 0 && is(Args[0] == void*);
            }

            version(DebugMessageFlow)
            {
                import urt.string.format;
                if ((EZSP_Command.Command in commandNames) is null)
                    commandNames.insert(EZSP_Command.Command, CommandData(EZSP_Command.stringof[5 .. $],
                                                                          (const(ubyte)[] data){ EZSP_Command.Request r; data.ezsp_deserialise(r); return tconcat(r); },
                                                                          (const(ubyte)[] data){ EZSP_Command.Response r; data.ezsp_deserialise(r); return tconcat(r); }));
            }

            ubyte[256] buffer = void; // TODO: what is the maximum ezsp payload length?
            EZSP_Command.Request tr = void;
            tr.tupleof[] = args[];
            size_t offset = tr.ezsp_serialise(buffer[]);

            static if (is(Callback == typeof(null)))
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], null, null, null, null, null, priority, dei);
            else static if (is_delegate!Callback)
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], &response_shim!(HasUserData, ResponseParams), &fail_shim!(HasUserData, ResponseParams), response_handler.funcptr, response_handler.ptr, HasUserData ? user_data : null, priority, dei);
            else
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], &response_shim!(HasUserData, ResponseParams), &fail_shim!(HasUserData, ResponseParams), response_handler, null, HasUserData ? user_data : null, priority, dei);
        }
    }

    final int send_message(ushort cmd, const(ubyte)[] data)
    {
        if (!running)
            return -1;

        ubyte[256] buffer = void;
        ubyte i = 0;

        buffer[i++] = _sequence_number;

        // the EZSP frame control byte (0x00)
        buffer[i++] = 0x00;
        if (_known_version >= 8)
            buffer[i++] = 0x01;

        if (cmd != 0 && _known_version < 8)
        {
            // For all EZSPv6 or EZSPv7 frames except 'version' frame, force an extended header 0xff 0x00
            buffer[i++] = 0xFF;
            buffer[i++] = 0x00;
        }

        buffer[i++] = cast(ubyte)cmd;
        if (_known_version >= 8)
            buffer[i++] = cmd >> 8;

        buffer[i .. i + data.length] = data[];
        i += data.length;

        version(DebugMessageFlow)
        {
            CommandData* cmdName = cmd in commandNames;
            log.tracef("--> [{0}] - {1}(x{2, 04x}) - {3,?5}{4,!5}", _sequence_number, cmdName ? cmdName.name : "UNKNOWN", cmd, cmdName ? cmdName.reqFmt(buffer[5..i]) : null, cast(void[])buffer[0..i], cmdName !is null);
        }

        if (ash_send(buffer[0..i]) < 0)
        {
            version(DebugMessageFlow)
                log.trace("send failed!");

            // error?!
            return -1;
        }

        return _sequence_number++;
    }

protected:

    override bool validate() const pure
        => (_stream !is null) != (_ash_ext !is null);

    override CompletionStatus startup()
    {
        import manager : get_module;
        import manager.expression : NamedArgument;

        if (!_ash)
        {
            if (_ash_ext)
                _ash = _ash_ext;
            else
            {
                auto ash_coll = Collection!ASHInterface();
                // our previous instance may still be tearing down (destroy defers through the state
                // machine); wait for it to vanish rather than spawn a suffixed duplicate that fights
                // it for the stream's rx_handler
                if (ash_coll.get(name[]))
                    return CompletionStatus.continue_;
                _ash = cast(ASHInterface)ash_coll.create(name[], ObjectFlags.dynamic, NamedArgument("stream", cast(Stream)_stream));
                if (!_ash)
                    return CompletionStatus.error;
            }
            PacketFilter filter;
            filter.type = PacketType.raw;
            filter.direction = PacketDirection.incoming;
            _ash.subscribe(&incoming_packet, filter);
            _ash.subscribe(&ash_state_change);
        }

        // Apply on every startup as an externally supplied ASH interface may have been tuned while
        // this client was stopped. This is a live limit change and does not restart or drop ASH.
        StringResult window_result = _ash.window(_concurrency);
        if (!window_result)
        {
            log.error("failed to configure ASH window: ", window_result.message);
            return CompletionStatus.error;
        }

        if (_known_version)
            return CompletionStatus.complete;

        if (_ash.running)
        {
            if (_requested_version == 0)
            {
                log.debug_("connecting...");

                _requested_version = PREFERRED_VERSION;
                immutable ubyte[4] version_msg = [ _sequence_number++, 0x00, 0x00, _requested_version ];
                ash_send(version_msg);

                _last_event = getTime();
            }
            else if (getTime() - _last_event > 10.seconds)
                return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _known_version = 0;
        _requested_version = 0;
        _sequence_number = 0;
        _stack_type = EZSPStackType.unknown;
        _stack_version = null;
        mark_set!(typeof(this), [ "stack-type", "stack-version", "protocol-version" ])();

        // complete every outstanding request as failed; nothing may be left waiting on a
        // response that can never arrive (send_command rejects new requests while not running)
        foreach (ref req; _queued_requests)
        {
            if (req.fail_shim)
                req.fail_shim(req.cb_funcptr, req.cb_instance, req.user_data);
        }
        _queued_requests.clear();
        mark_set!(typeof(this), "queued")();
        _in_flight = 0;

        if (_ash)
        {
            _ash.unsubscribe(&incoming_packet);
            _ash.unsubscribe(&ash_state_change);
            if (_stream)
                _ash.destroy();
            _ash = null;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        // A healthy NCP responds in milliseconds. This timeout is deliberately longer than ASH's
        // complete retry cycle so the transport owns link-loss recovery rather than being torn down
        // while it still has retransmissions in progress.
        // fail the request and restart for a clean slate
        MonoTime now = getTime();
        if (_in_flight > 0 && now - _queued_requests[0].ts > request_timeout)
        {
            log.errorf("cmd x{0,04x} (seq {1}) timed out after {2}ms; restarting NCP link", _queued_requests[0].cmd, _queued_requests[0].sequence_number, (now - _queued_requests[0].ts).as!"msecs");
            auto fail = _queued_requests[0].fail_shim;
            void* cb = _queued_requests[0].cb_funcptr, inst = _queued_requests[0].cb_instance, ud = _queued_requests[0].user_data;
            _queued_requests.popFront();
            mark_set!(typeof(this), "queued")();
            --_in_flight;
            if (fail)
                fail(cb, inst, ud);
            restart();
        }
    }

private:

    static class YieldEZSP : AwakenEvent
    {
    nothrow @nogc:
        bool finished;
        override bool ready() { return finished; }
    }

    struct QueuedRequest
    {
        MonoTime ts;
        ubyte sequence_number;
        ubyte priority;         // pcp rank; higher jumps ahead of pending lower-priority commands
        bool dei;
        ushort cmd;
        ushort data_len;
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_shim;
        void function(void*, void*, void*) nothrow @nogc fail_shim;
        void* cb_funcptr;
        void* cb_instance;
        void* user_data;
        ubyte[256] data;        // stashed request payload (inline so entries stay POD/swappable)
    }

    struct CommandHandler
    {
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_shim;
        void* cb_funcptr;
        void* cb_instance;
        void* user_data;
    }

    enum PREFERRED_VERSION = 13;

    enum max_queued_requests = 32;

    enum request_timeout = 20.seconds;

    MonoTime _last_event;

    ubyte _in_flight;
    ubyte _concurrency = 1;

    ubyte _requested_version;
    ubyte _known_version;
    EZSPStackType _stack_type;
    String _stack_version;

    ubyte _sequence_number;

    ObjectRef!Stream _stream;
    ObjectRef!ASHInterface _ash_ext;
    ASHInterface _ash;

    void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc _message_handler;
    Map!(ushort, CommandHandler) _command_handlers;
    Array!QueuedRequest _queued_requests;
    ushort _peak_queue;         // high-water mark of the command queue, for back-pressure visibility

    version(DebugMessageFlow)
    {
        struct CommandData
        {
            string name;
            const(char)[] function(const(ubyte)[]) nothrow @nogc reqFmt;
            const(char)[] function(const(ubyte)[]) nothrow @nogc resFmt;
        }
        Map!(ushort, CommandData) commandNames;
    }

    int ash_send(const(ubyte)[] data)
    {
        Packet p;
        p.init!RawFrame(data);
        return _ash.forward(p);
    }

    void ash_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
        else if (signal == StateSignal.destroyed)
        {
            _ash.unsubscribe(&incoming_packet);
            _ash.unsubscribe(&ash_state_change);
            _ash = null;
            restart();
        }
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* ud)
    {
        const(ubyte)[] msg = cast(const(ubyte)[])p.data();
//        writeWarningf("ASHv2: [!!!] empty frame received! [x{0,02x}]", control);

        ubyte seq;
        ushort control;
        ushort cmd;
        if (_known_version >= 8)
        {
            if (msg.length < 5)
            {
                log.warning("invalid frame; frame is too short!");
                return;
            }

            seq = msg[0];
            control = msg[1] | (msg[2] << 8);
            cmd = msg[3] | (msg[4] << 8);
            msg = msg[5 .. $];
        }
        else
        {
            if (msg.length < 3)
            {
                log.warning("invalid frame; frame is too short!");
                return;
            }

            seq = msg[0];
            control = msg[1];

            if (msg[2] == 0xff)
            {
                if (msg.length < 5)
                {
                    log.warning("invalid frame; frame is too short!");
                    return;
                }

                cmd = msg[4];
                msg = msg[5..$];
            }
            else
            {
                cmd = msg[2];
                msg = msg[3..$];
            }
        }

        if (!(control & 0x80))
        {
            log.warning("invalid EZSP frame; response bit is not set");
            return;
        }

        bool overflow = (control & 0x1) != 0;
        bool truncated = (control & 0x2) != 0;
        bool callback_pending = (control & 0x4) != 0;
        ubyte callback_type = (control >> 3) & 0x3;
        ubyte network_index = (control >> 5) & 0x3;
        ubyte frame_format_version = (control >> 8) & 0x3;
        bool padding_enabled = (control & 0x4000) != 0;
        bool security_enabled = (control & 0x8000) != 0;

        _last_event = getTime();

        dispatch_command(seq, callback_type, cmd, msg);
    }

    void dispatch_command(ubyte seq, ubyte cb_type, ushort command, const(ubyte)[] msg)
    {
        switch (command)
        {
            case 0x0000: // version
                EZSP_Version.Response r;
                msg.ezsp_deserialise(r);

                if (r.protocolVersion != _requested_version)
                {
                    // we'll negotiate down to the version it supports
                    _requested_version = r.protocolVersion;
                    immutable ubyte[4] versionMsg = [ _sequence_number++, 0x00, 0x00, _requested_version ];
                    ash_send(versionMsg);
                    break;
                }

                import urt.string.format : tformat;
                import urt.mem.allocator : defaultAllocator;

                _stack_type = cast(EZSPStackType)r.stackType;
                _stack_version = tformat("{0}.{1}.{2}.{3}", r.stackVersion >> 12, (r.stackVersion >> 8) & 0xF, (r.stackVersion >> 4) & 0xF, r.stackVersion & 0xF).makeString(defaultAllocator());

                _known_version = _requested_version;
                _requested_version = 0;

                mark_set!(typeof(this), [ "stack-type", "stack-version", "protocol-version" ])();

                log.noticef("connected: {0} V{1} - protocol version {2}", r.stackType == 1 ? "ROUTER" : r.stackType == 2 ? "COORDINATOR" : "UNKNOWN", _stack_version, _known_version);
                break;

            case 0x0058: // invalid command
                EzspStatus reason = cast(EzspStatus)msg[0];
                log.warning("invalid command: ", reason);
                break;

            default:
                version(DebugMessageFlow)
                {
                    CommandData* cmdName = command in commandNames;
                    log.tracef("<-- [{0,!2}{1,?2}] - {3}(x{4,04x}) - {5,?7}{6,!7}", seq, "CB", cb_type != 0, cmdName ? cmdName.name : "UNKNOWN", command, cmdName ? cmdName.resFmt(msg) : null, cast(void[])msg, cmdName !is null);
                }

                if (cb_type == 1)
                    log.warningf("TODO: EZSP solicited callback received: seq={0}, command=x{1,04x}", seq, command);

                if (cb_type == 0)
                {
                    // responses arrive strictly in order on the reliable ASH link, so each one must
                    // match the oldest in-flight request exactly; equality is wraparound-immune,
                    // unlike ordered comparisons on the ubyte sequence
                    if (_in_flight == 0)
                    {
                        // response to a request we already failed (timeout/restart raced it)
                        log.debug_("stale response - seq: ", seq, " cmd: ", command);
                        return;
                    }
                    if (seq != _queued_requests[0].sequence_number || command != _queued_requests[0].cmd)
                    {
                        log.errorf("response stream corrupt: got seq {0}/cmd x{1,04x}, expected seq {2}/cmd x{3,04x}; restarting", seq, command, _queued_requests[0].sequence_number, _queued_requests[0].cmd);
                        restart();
                        return;
                    }

                    // copy out and pop before invoking; the callback may enqueue new requests,
                    // which can grow (reallocate) the array under us
                    auto shim = _queued_requests[0].response_shim;
                    void* cb = _queued_requests[0].cb_funcptr, inst = _queued_requests[0].cb_instance, ud = _queued_requests[0].user_data;
                    version (DebugZigbeeLatency)
                        Duration rtt = getTime() - _queued_requests[0].ts;
                    _queued_requests.popFront();
                    mark_set!(typeof(this), "queued")();
                    --_in_flight;

                    version (DebugZigbeeLatency)
                    {
                        if (rtt > 100.msecs)
                            log.debugf("slow response: cmd x{0,04x} took {1}ms", command, rtt.as!"msecs");
                    }

                    if (shim)
                        shim(msg, cb, inst, ud);

                    send_queued_message();
                }
                else
                {
                    // message is some callback...

                    if (auto cmdHandler = command in _command_handlers)
                        cmdHandler.response_shim(msg, cmdHandler.cb_funcptr, cmdHandler.cb_instance, cmdHandler.user_data);
                    else if (_message_handler)
                        _message_handler(seq, command, msg);
                    else
                    {
                        // TODO: unhandled message?
                    }
                }
                break;
        }
    }

    bool send_command_impl(ushort cmd, ubyte[] data,
                           void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_handler,
                           void function(void*, void*, void*) nothrow @nogc failure_handler,
                           void* cb, void* inst, void* user_data, ubyte priority = 1, bool dei = false)
    {
        if (data.length > QueuedRequest.data.length)
            return false;

        void function(void*, void*, void*) nothrow @nogc dropped_fail;
        void* dropped_cb;
        void* dropped_inst;
        void* dropped_ud;
        if (_queued_requests.length >= max_queued_requests)
        {
            size_t drop = _queued_requests.length;
            if (!dei)
            {
                foreach (i; _in_flight .. _queued_requests.length)
                {
                    if (_queued_requests[i].dei && _queued_requests[i].priority <= priority &&
                        (drop == _queued_requests.length || _queued_requests[i].priority < _queued_requests[drop].priority))
                        drop = i;
                }
            }

            if (drop == _queued_requests.length)
            {
                log.warningf("command queue full ({0}); rejecting cmd x{1,04x} pri {2}", max_queued_requests, cmd, priority);
                return false;
            }

            dropped_fail = _queued_requests[drop].fail_shim;
            dropped_cb = _queued_requests[drop].cb_funcptr;
            dropped_inst = _queued_requests[drop].cb_instance;
            dropped_ud = _queued_requests[drop].user_data;
            _queued_requests.remove(drop);
            mark_set!(typeof(this), "queued")();
        }

        ref QueuedRequest req = _queued_requests.pushBack();
        mark_set!(typeof(this), "queued")();
        req.cmd = cmd;
        req.priority = priority;
        req.dei = dei;
        req.response_shim = response_handler;
        req.fail_shim = failure_handler;
        req.cb_funcptr = cb;
        req.cb_instance = inst;
        req.user_data = user_data;
        req.data_len = cast(ushort)data.length;
        req.data[0 .. data.length] = data[];

        if (_queued_requests.length > _peak_queue)
        {
            _peak_queue = cast(ushort)_queued_requests.length;
            mark_set!(typeof(this), "peak-queue")();
        }

        version (DebugZigbeeLatency)
        {
            if (_queued_requests.length >= 4)
                log.debugf("queue depth {0} peak {1} (submitting cmd x{2,04x} pri {3})", _queued_requests.length, _peak_queue, cmd, priority);
        }

        if (dropped_fail)
            dropped_fail(dropped_cb, dropped_inst, dropped_ud);

        send_queued_message();
        return true;
    }

    // Requests [0 .. _in_flight) have been transmitted and await ordered responses. The ASH window
    // is kept equal to this limit, so changing concurrency live changes admission without dropping
    // frames already on the wire.
    void send_queued_message()
    {
        if (_in_flight >= _concurrency || _queued_requests.length == 0)
            return;

        while (_in_flight < _concurrency && _in_flight < _queued_requests.length)
        {
            size_t best = _in_flight;
            foreach (i; _in_flight + 1 .. _queued_requests.length)
            {
                if (_queued_requests[i].priority > _queued_requests[best].priority)
                    best = i;
            }
            if (best != _in_flight)
            {
                QueuedRequest* a = &_queued_requests[_in_flight];
                QueuedRequest* b = &_queued_requests[best];
                QueuedRequest tmp = *a;
                *a = *b;
                *b = tmp;
            }

            ref QueuedRequest req = _queued_requests[_in_flight];
            int seq = send_message(req.cmd, req.data[0 .. req.data_len]);
            if (seq < 0)
            {
                // transport rejected the frame; complete the request as failed
                log.warningf("transport rejected cmd x{0,04x}; completing as failed", req.cmd);
                auto fail = req.fail_shim;
                void* cb = req.cb_funcptr, inst = req.cb_instance, ud = req.user_data;
                _queued_requests.remove(_in_flight);
                mark_set!(typeof(this), "queued")();
                if (fail)
                    fail(cb, inst, ud);
                continue;
            }
            req.sequence_number = cast(ubyte)seq;
            req.ts = getTime();
            ++_in_flight;

            log.tracef("--> cmd x{0,04x} seq {1} pri {2} (in-flight {3}, queued {4})", req.cmd, req.sequence_number, req.priority, _in_flight, _queued_requests.length - _in_flight);
        }
    }
}

// Completion contract: every queued request completes exactly once. When no response will ever
// arrive (timeout, transport rejection, shutdown), this delivers the callback with default args,
// substituting a synthetic failure for a leading status field so callers observe !SUCCESS.
void fail_shim(bool withUserdata, Args...)(void* cb, void* inst, void* user_data)
{
    import urt.meta.tuple;

    Tuple!Args args;
    static if (Args.length > 0 && is(Args[0] == EmberStatus))
        args[0] = cast(EmberStatus)0xFF; // synthetic host-side failure; reads as !SUCCESS
    else static if (Args.length > 0 && is(Args[0] == EzspStatus))
        args[0] = cast(EzspStatus)0xFF;

    if (inst)
    {
        void delegate() callback;
        callback.ptr = inst;
        callback.funcptr = cast(void function())cb;
        static if (withUserdata)
            (cast(void delegate(void*, Args) nothrow @nogc)callback)(user_data, args.expand);
        else
            (cast(void delegate(Args) nothrow @nogc)callback)(args.expand);
    }
    else
    {
        static if (withUserdata)
            (cast(void function(void*, Args) nothrow @nogc)cb)(user_data, args.expand);
        else
            (cast(void function(Args) nothrow @nogc)cb)(args.expand);
    }
}

void response_shim(bool withUserdata, Args...)(const(ubyte)[] response, void* cb, void* inst, void* user_data)
{
    import urt.meta.tuple;

    Tuple!Args args;
    static if (Args.length > 0)
    {
        size_t taken = response.ezsp_deserialise(args);
        if (taken == 0 || taken > response.length)
        {
            log_warning("ezsp", "error deserialising response");
            return;
        }
        if (taken < response.length)
        {
            // TODO: WE SEE THIS WEIRD 02 TAIL BYTE ALL THE TIME IN NORMAL COMMUNICATION!
            //       WTF IS IT? WHY DO WE SEE IT?
            if (taken != response.length - 1 || response[$ - 1] != 0x02)
                log_warning("ezsp", "response buffer contains more bytes than expected! tail bytes: ", cast(void[])response[taken .. $]);
        }
    }

    if (inst)
    {
        void delegate() callback;
        callback.ptr = inst;
        callback.funcptr = cast(void function())cb;
        static if (withUserdata)
            (cast(void delegate(void*, Args) nothrow @nogc)callback)(user_data, args.expand);
        else
            (cast(void delegate(Args) nothrow @nogc)callback)(args.expand);
    }
    else
    {
        static if (withUserdata)
            (cast(void function(void*, Args) nothrow @nogc)cb)(user_data, args.expand);
        else
            (cast(void function(Args) nothrow @nogc)cb)(args.expand);
    }
}
