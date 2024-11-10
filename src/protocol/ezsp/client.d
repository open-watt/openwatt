module protocol.ezsp.client;

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
    __gshared Property[1] Properties = [ Property.create!("stream", stream)() ];
@nogc:

    enum TypeName = StringLit!"ezsp";

    enum StackType : ubyte
    {
        Unknown = 0,
        Router = 1,
        Coordinator = 2
    }

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow
    {
        super(collectionTypeInfo!EZSPClient, name.move, flags);
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
            ash.setEventCallback(&eventCallback);
            ash.setPacketCallback(&incomingPacket);
            restart();
        }
    }

    // API...

    final void reboot() nothrow
    {
        sendCommand!EZSP_ResetNode(null);
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

        static void response(void* userData, typeof(R.Response.tupleof) results)
        {
            Result* r = cast(Result*)userData;
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

        bool success = sendCommand!R(&response, forward!args, cast(void*)&r);
        assert(success, "EZSP: failed to send command!");

        yield(ev);

        static if (!is(EZSPResult!R == void))
            return r.result;
    }

nothrow:
    final void setMessageHandler(void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc callback) pure nothrow
    {
        messageHandler = callback;
    }

    template setCallbackHandler(EZSP_Command)
        if (IsEZSPRequest!EZSP_Command)
    {
        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final void setCallbackHandler(Callback)(Callback responseHandler, void* userData = null) nothrow
        {
            alias Args = Parameters!Callback;
            static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* userData` argument in the first position.");
            enum HasUserData = Args.length > 0 && is(Args[0] == void*);

            version(DebugMessageFlow)
            {
                import urt.string.format;
                if ((EZSP_Command.Command in commandNames) is null)
                    commandNames.insert(EZSP_Command.Command, CommandData(EZSP_Command.stringof[5 .. $],
                                                                          (const(ubyte)[] data){ EZSP_Command.Request r; data.ezspDeserialise(r); return tconcat(r); },
                                                                          (const(ubyte)[] data){ EZSP_Command.Response r; data.ezspDeserialise(r); return tconcat(r); }));
            }

            auto handler = &commandHandlers.replace(EZSP_Command.Command, CommandHandler());

            handler.responseShim = &responseShim!(HasUserData, ResponseParams);
            handler.userData = HasUserData ? userData : null;
            static if (is_delegate!Callback)
            {
                handler.cbFnPtr = responseHandler.funcptr;
                handler.cbInstance = responseHandler.ptr;
            }
            else
            {
                handler.cbFnPtr = responseHandler;
                handler.cbInstance = null;
            }
        }
    }

    template sendCommand(EZSP_Command)
        if (IsEZSPRequest!EZSP_Command)
    {
        alias RequestParams = typeof(EZSP_Command.Request.tupleof);
        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final bool sendCommand(Callback)(Callback responseHandler, auto ref RequestParams args, void* userData = null)
        {
            if (!running)
                return false;

            static if (!is(Callback == typeof(null)))
            {
                alias Args = Parameters!Callback;
                static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* userData` argument in the first position.");
                enum HasUserData = Args.length > 0 && is(Args[0] == void*);
            }

            version(DebugMessageFlow)
            {
                import urt.string.format;
                if ((EZSP_Command.Command in commandNames) is null)
                    commandNames.insert(EZSP_Command.Command, CommandData(EZSP_Command.stringof[5 .. $],
                                                                          (const(ubyte)[] data){ EZSP_Command.Request r; data.ezspDeserialise(r); return tconcat(r); },
                                                                          (const(ubyte)[] data){ EZSP_Command.Response r; data.ezspDeserialise(r); return tconcat(r); }));
            }

            ubyte[EZSP_Command.Request.sizeof] buffer = void;
            EZSP_Command.Request tr = void;
            tr.tupleof[] = args[];
            size_t offset = tr.ezspSerialise(buffer[]);

            static if (is(Callback == typeof(null)))
                return sendCommandImpl(EZSP_Command.Command, buffer[0..offset], null, null, null, null);
            else static if (is_delegate!Callback)
                return sendCommandImpl(EZSP_Command.Command, buffer[0..offset], &responseShim!(HasUserData, ResponseParams), responseHandler.funcptr, responseHandler.ptr, HasUserData ? userData : null);
            else
                return sendCommandImpl(EZSP_Command.Command, buffer[0..offset], &responseShim!(HasUserData, ResponseParams), responseHandler, null, HasUserData ? userData : null);
        }
    }

    final int sendMessage(ushort cmd, const(ubyte)[] data)
    {
        if (!running)
            return -1;

        ubyte[256] buffer = void;
        ubyte i = 0;

        buffer[i++] = sequenceNumber;

        // the EZSP frame control byte (0x00)
        buffer[i++] = 0x00;
        if (knownVersion >= 8)
            buffer[i++] = 0x01;

        if (cmd != 0 && knownVersion < 8)
        {
            // For all EZSPv6 or EZSPv7 frames except 'version' frame, force an extended header 0xff 0x00
            buffer[i++] = 0xFF;
            buffer[i++] = 0x00;
        }

        buffer[i++] = cast(ubyte)cmd;
        if (knownVersion >= 8)
            buffer[i++] = cmd >> 8;

        buffer[i .. i + data.length] = data[];
        i += data.length;

        version(DebugMessageFlow)
        {
            CommandData* cmdName = cmd in commandNames;
            writeDebugf("EZSP: --> [{0}] - {1}(x{2, 04x}) - {3,?5}{4,!5}", sequenceNumber, cmdName ? cmdName.name : "UNKNOWN", cmd, cmdName ? cmdName.reqFmt(buffer[5..i]) : null, cast(void[])buffer[0..i], cmdName !is null);
        }

        if (!ash.send(buffer[0..i]))
        {
            version(DebugMessageFlow)
                writeDebug("EZSP: send failed!");

            // error?!
            return -1;
        }

        return sequenceNumber++;
    }

    final override bool validate() const pure
        => ash.stream !is null;

    override CompletionStatus startup()
    {
        ash.update();

        if (knownVersion)
            return CompletionStatus.Complete;

        if (ash.isConnected())
        {
            if (requestedVersion == 0)
            {
                writeDebug("EZSP: connecting...");

                requestedVersion = PreferredVersion;
                immutable ubyte[4] versionMsg = [ sequenceNumber++, 0x00, 0x00, requestedVersion ];
                ash.send(versionMsg);

                lastEvent = getTime();
            }
            else if (getTime() - lastEvent > 10.seconds)
                return CompletionStatus.Error;
        }
        return CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        ash.reset();
        knownVersion = 0;
        requestedVersion = 0;
        sequenceNumber = 0;
        return CompletionStatus.Complete;
    }

    final override void update()
    {
        if (!validate())
            return;

        ash.update();

        if (!knownVersion)
        {
            if (ash.isConnected())
            {
                if (requestedVersion == 0)
                {
                    writeDebug("EZSP: connecting...");

                    requestedVersion = PreferredVersion;
                    immutable ubyte[4] versionMsg = [ sequenceNumber++, 0x00, 0x00, requestedVersion ];
                    ash.send(versionMsg);

                    lastEvent = getTime();
                }
                else if (getTime() - lastEvent > 10.seconds)
                    restart();
            }
            return;
        }
    }

private:

    static class YieldEZSP : AwakenEvent
    {
        nothrow @nogc:
        bool finished;
        override bool ready() { return finished; }
    }

    struct ActiveRequests
    {
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc responseShim;
        void* cbFnPtr;
        void* cbInstance;
        void* userData;
        ubyte sequenceNumber;
    }

    struct CommandHandler
    {
        void function(const(ubyte)[], void*, void*, void*) nothrow @nogc responseShim;
        void* cbFnPtr;
        void* cbInstance;
        void* userData;
    }

    enum PreferredVersion = 13;

    MonoTime lastEvent;

    ubyte requestedVersion;
    ubyte knownVersion;
    StackType stackType;
    String stackVersion;

    ubyte sequenceNumber;

    ASH ash;

    void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc messageHandler;
    Map!(ushort, CommandHandler) commandHandlers;
    ActiveRequests[16] activeRequests;

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

    void eventCallback(ASH.Event event)
    {
        if (event == ASH.Event.Reset)
        {
            knownVersion = 0;
            requestedVersion = 0;
            sequenceNumber = 0;
            stackType = StackType.Unknown;
            stackVersion = null;
            activeRequests[] = ActiveRequests();
        }
        else
            assert(false, "Unhandled ASH event");
    }

    void incomingPacket(const(ubyte)[] msg)
    {
//        writeWarningf("ASHv2: [!!!] empty frame received! [x{0,02x}]", control);

        ubyte seq;
        ushort control;
        ushort cmd;
        if (knownVersion >= 8)
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
        bool callbackPending = (control & 0x4) != 0;
        ubyte callbackType = (control >> 3) & 0x3;
        ubyte networkIndex = (control >> 5) & 0x3;
        ubyte frameFormatVersion = (control >> 8) & 0x3;
        bool paddingEnabled = (control & 0x4000) != 0;
        bool securityEnabled = (control & 0x8000) != 0;

        lastEvent = getTime();

        dispatchCommand(seq, cmd, msg);
    }

    void dispatchCommand(ubyte seq, ushort command, const(ubyte)[] msg)
    {
        switch (command)
        {
            case 0x0000: // version
                EZSP_Version.Response r;
                msg.ezspDeserialise(r);

                if (r.protocolVersion != requestedVersion)
                {
                    // we'll negotiate down to the version it supports
                    requestedVersion = r.protocolVersion;
                    immutable ubyte[4] versionMsg = [ sequenceNumber++, 0x00, 0x00, requestedVersion ];
                    ash.send(versionMsg);
                    break;
                }

                import urt.string.format : tformat;
                import urt.mem.allocator : defaultAllocator;

                stackType = cast(StackType)r.stackType;
                stackVersion = tformat("{0}.{1}.{2}.{3}", r.stackVersion >> 12, (r.stackVersion >> 8) & 0xF, (r.stackVersion >> 4) & 0xF, r.stackVersion & 0xF).makeString(defaultAllocator());

                knownVersion = requestedVersion;
                requestedVersion = 0;

                writeInfof("EZSP: connected: {0} V{1} - protocol version {2}", r.stackType == 1 ? "ROUTER" : r.stackType == 2 ? "COORDINATOR" : "UNKNOWN", stackVersion, knownVersion);
                break;

            case 0x0058: // invalidCommand
                EzspStatus reason = cast(EzspStatus)msg[0];
                writeWarning("EZSP: invalid command: ", reason);
                break;

            default:
                version(DebugMessageFlow)
                {
                    CommandData* cmdName = command in commandNames;
                    writeDebugf("EZSP: <-- [{0}] - {1}(x{2,04x}) - {3,?5}{4,!5}", seq, cmdName ? cmdName.name : "UNKNOWN", command, cmdName ? cmdName.resFmt(msg) : null, cast(void[])msg, cmdName !is null);
                }

                int slot = seq & 0xF;
                if (activeRequests[slot].responseShim != null)
                {
                    activeRequests[slot].responseShim(msg, activeRequests[slot].cbFnPtr, activeRequests[slot].cbInstance, activeRequests[slot].userData);
                    activeRequests[slot].responseShim = null;
                }
                else
                {
                    if (auto cmdHandler = command in commandHandlers)
                        cmdHandler.responseShim(msg, cmdHandler.cbFnPtr, cmdHandler.cbInstance, cmdHandler.userData);
                    else if (messageHandler)
                        messageHandler(seq, command, msg);
                    else
                    {
                        // TODO: unhandled message?
                    }
                }
                break;
        }
    }

    bool sendCommandImpl(ushort cmd, ubyte[] data, void function(const(ubyte)[], void*, void*, void*) nothrow @nogc responseHandler, void* cb, void* inst, void* userData)
    {
        int seq = sendMessage(cmd, data);
        if (seq < 0)
            return false;

        if (activeRequests[seq & 0xF].responseShim != null)
        {
            // the request is already in flight!
            assert(false, "TODO: how to handle this case?");
            return false;
        }

        activeRequests[seq & 0xF].responseShim = responseHandler;
        activeRequests[seq & 0xF].cbFnPtr = cb;
        activeRequests[seq & 0xF].cbInstance = inst;
        activeRequests[seq & 0xF].userData = userData;
        activeRequests[seq & 0xF].sequenceNumber = seq & 0xFF;

        return true;
    }
}

void responseShim(bool withUserdata, Args...)(const(ubyte)[] response, void* cb, void* inst, void* userData)
{
    import urt.meta.tuple;

    Tuple!Args args;
    static if (Args.length > 0)
    {
        size_t taken = response.ezspDeserialise(args);
        if (taken == 0 || taken > response.length)
        {
            writeWarning("EZSP: error deserialising response");
            return;
        }
        if (taken < response.length)
            writeWarning("EZSP: response buffer contains more bytes than expected! tail bytes: ", cast(void[])response[taken .. $]);
    }

    if (inst)
    {
        void delegate() callback;
        callback.ptr = inst;
        callback.funcptr = cast(void function())cb;
        static if (withUserdata)
            (cast(void delegate(void*, Args) nothrow @nogc)callback)(userData, args.expand);
        else
            (cast(void delegate(Args) nothrow @nogc)callback)(args.expand);
    }
    else
    {
        static if (withUserdata)
            (cast(void function(void*, Args) nothrow @nogc)cb)(userData, args.expand);
        else
            (cast(void function(Args) nothrow @nogc)cb)(args.expand);
    }
}
