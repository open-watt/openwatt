module protocol.ezsp.client;

import urt.array;
import urt.endian;
import urt.fibre;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.traits;

import manager.base;

import router.stream;

import protocol.ezsp;
import protocol.ezsp.ashv2;

public import protocol.ezsp.commands;

//version = DebugMessageFlow;

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

class EZSPClient : BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("stack-type", stack_type)(),
                                         Property.create!("stack-version", stack_version)(),
                                         Property.create!("protocol-version", protocol_version)() ];
@nogc:

    enum type_name = "ezsp";

    this(String name, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!EZSPClient, name.move, flags);
    }

    // Properties...

    final inout(Stream) stream() inout pure nothrow
        => ash.stream;
    final void stream(Stream stream) nothrow
    {
        if (ash.stream !is stream)
        {
            // rebuild ASH and reset
            ash = ASH(stream);
            ash.setEventCallback(&event_callback);
            ash.setPacketCallback(&incoming_packet);
            restart();
        }
    }

    final EZSPStackType stack_type() const pure nothrow
        => _stack_type;

    final String stack_version() const pure nothrow
        => _stack_version;

    final ubyte protocol_version() const pure nothrow
        => _known_version;

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

        final bool send_command(Callback)(Callback response_handler, auto ref RequestParams args, void* user_data = null)
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
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], null, null, null, null);
            else static if (is_delegate!Callback)
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], &response_shim!(HasUserData, ResponseParams), response_handler.funcptr, response_handler.ptr, HasUserData ? user_data : null);
            else
                return send_command_impl(EZSP_Command.Command, buffer[0..offset], &response_shim!(HasUserData, ResponseParams), response_handler, null, HasUserData ? user_data : null);
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
            writeDebugf("EZSP: --> [{0}] - {1}(x{2, 04x}) - {3,?5}{4,!5}", _sequence_number, cmdName ? cmdName.name : "UNKNOWN", cmd, cmdName ? cmdName.reqFmt(buffer[5..i]) : null, cast(void[])buffer[0..i], cmdName !is null);
        }

        if (!ash.send(buffer[0..i]))
        {
            version(DebugMessageFlow)
                writeDebug("EZSP: send failed!");

            // error?!
            return -1;
        }

        return _sequence_number++;
    }

    final override bool validate() const pure
        => ash.stream !is null;

    override CompletionStatus startup()
    {
        ash.update();

        if (_known_version)
            return CompletionStatus.complete;

        if (ash.isConnected())
        {
            if (_requested_version == 0)
            {
                writeDebug("EZSP: connecting...");

                _requested_version = PREFERRED_VERSION;
                immutable ubyte[4] version_msg = [ _sequence_number++, 0x00, 0x00, _requested_version ];
                ash.send(version_msg);

                _last_event = getTime();
            }
            else if (getTime() - _last_event > 10.seconds)
                return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        ash.reset();
        _known_version = 0;
        _requested_version = 0;
        _sequence_number = 0;
        return CompletionStatus.complete;
    }

    final override void update()
    {
        if (!validate())
            return;

        ash.update();

        MonoTime now = getTime();
        if (_queued_requests.length > 0 && now - _queued_requests[0].ts > 200.msecs)
        {
            writeWarningf("EZSP: request {0,02x} timed out", _queued_requests[0].sequence_number);
            _queued_requests.popFront();

            send_queued_message();
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
        ushort cmd;
        Array!ubyte data;
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_shim;
        void* cb_funcptr;
        void* cb_instance;
        void* user_data;
    }

    struct CommandHandler
    {
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_shim;
        void* cb_funcptr;
        void* cb_instance;
        void* user_data;
    }

    enum PREFERRED_VERSION = 13;

    MonoTime _last_event;

    ubyte _requested_version;
    ubyte _known_version;
    EZSPStackType _stack_type;
    String _stack_version;

    ubyte _sequence_number;

    ASH ash;

    void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc _message_handler;
    Map!(ushort, CommandHandler) _command_handlers;
    Array!QueuedRequest _queued_requests;

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

    void event_callback(ASH.Event event)
    {
        if (event == ASH.Event.Reset)
        {
            _known_version = 0;
            _requested_version = 0;
            _sequence_number = 0;
            _stack_type = EZSPStackType.unknown;
            _stack_version = null;
            _queued_requests.clear();
            restart();
        }
        else
            assert(false, "Unhandled ASH event");
    }

    void incoming_packet(const(ubyte)[] msg)
    {
//        writeWarningf("ASHv2: [!!!] empty frame received! [x{0,02x}]", control);

        ubyte seq;
        ushort control;
        ushort cmd;
        if (_known_version >= 8)
        {
            if (msg.length < 5)
            {
                writeWarning("EZSP: [!!!] invalid frame; frame is too short!");
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
                writeWarning("EZSP: [!!!] invalid frame; frame is too short!");
                return;
            }

            seq = msg[0];
            control = msg[1];

            if (msg[2] == 0xff)
            {
                assert(false); // TODO: we don't understand this case!

                if (msg.length < 5)
                {
                    writeWarning("EZSP: [!!!] invalid frame; frame is too short!");
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

        assert(control & 0x80); // responses always have the high bit set

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
                    ash.send(versionMsg);
                    break;
                }

                import urt.string.format : tformat;
                import urt.mem.allocator : defaultAllocator;

                _stack_type = cast(EZSPStackType)r.stackType;
                _stack_version = tformat("{0}.{1}.{2}.{3}", r.stackVersion >> 12, (r.stackVersion >> 8) & 0xF, (r.stackVersion >> 4) & 0xF, r.stackVersion & 0xF).makeString(defaultAllocator());

                _known_version = _requested_version;
                _requested_version = 0;

                writeInfof("EZSP: connected: {0} V{1} - protocol version {2}", r.stackType == 1 ? "ROUTER" : r.stackType == 2 ? "COORDINATOR" : "UNKNOWN", _stack_version, _known_version);
                break;

            case 0x0058: // invalid command
                EzspStatus reason = cast(EzspStatus)msg[0];
                writeWarning("EZSP: invalid command: ", reason);
                break;

            default:
                version(DebugMessageFlow)
                {
                    CommandData* cmdName = command in commandNames;
                    writeDebugf("EZSP: <-- [{0,!2}{1,?2}] - {3}(x{4,04x}) - {5,?7}{6,!7}", seq, "CB", cb_type != 0, cmdName ? cmdName.name : "UNKNOWN", command, cmdName ? cmdName.resFmt(msg) : null, cast(void[])msg, cmdName !is null);
                }

                if (cb_type == 1)
                {
                    // TODO: can we confirm when and why this is sent? does it need special handling?
                    assert(false); // this is a solicited callback, or something?
                }

                if (cb_type == 0)
                {
                    // message is a response to a queued request...

                    if (_queued_requests.length == 0 || seq < _queued_requests[0].sequence_number)
                    {
                        // stale response?
                        writeWarning("EZSP: received stale response - seq: ", seq);
                        return;
                    }
                    if (seq > _queued_requests[0].sequence_number)
                    {
                        // out-of-order response? (this could be because the seq counter wrapped?)
                        writeWarning("EZSP: received unsolicited or out-of-order response - seq: ", seq);
                        return;
                    }
                    if (command != _queued_requests[0].cmd)
                    {
                        // mismatched response?
                        writeWarningf("EZSP: received mismatched response - expected cmd x{0,04x} but got x{1,04x}", _queued_requests[0].cmd, command);
                        return;
                    }

                    debug assert(_queued_requests[0].response_shim);

                    _queued_requests[0].response_shim(msg, _queued_requests[0].cb_funcptr, _queued_requests[0].cb_instance, _queued_requests[0].user_data);
                    _queued_requests.popFront();

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

    bool send_command_impl(ushort cmd, ubyte[] data, void function(const(ubyte)[], void*, void*, void*) nothrow @nogc response_handler, void* cb, void* inst, void* user_data)
    {
        ref QueuedRequest req = _queued_requests.pushBack();
        req.cmd = cmd;
        req.response_shim = response_handler;
        req.cb_funcptr = cb;
        req.cb_instance = inst;
        req.user_data = user_data;

        if (_queued_requests.length == 1)
        {
            int seq = send_message(cmd, data);
            if (seq < 0)
            {
                _queued_requests.popFront();
                return false;
            }
            req.sequence_number = cast(ubyte)seq;
            req.ts = getTime();
        }
        else
            req.data = data[];

        return true;
    }

    void send_queued_message()
    {
        while (_queued_requests.length > 0)
        {
            ref QueuedRequest req = _queued_requests[0];
            int seq = send_message(req.cmd, req.data[]);
            if (seq < 0)
            {
                _queued_requests.popFront();
                continue;
            }
            req.sequence_number = cast(ubyte)seq;
            req.ts = getTime();
            break;
        }
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
            writeWarning("EZSP: error deserialising response");
            return;
        }
        if (taken < response.length)
        {
            // TODO: WE SEE THIS WEIRD 02 TAIL BYTE ALL THE TIME IN NORMAL COMMUNICATION!
            //       WTF IS IT? WHY DO WE SEE IT?
            if (taken != response.length - 1 || response[$ - 1] != 0x02)
                writeWarning("EZSP: response buffer contains more bytes than expected! tail bytes: ", cast(void[])response[taken .. $]);
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
