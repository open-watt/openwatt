module protocol.ezsp.client;

import urt.endian;
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

nothrow @nogc:


//
// EZSP (EmberZNet Serial Protocol) is a protocol used by EmberZNet to communicate with the radio chip.
// https://www.silabs.com/documents/public/user-guides/ug100-ezsp-reference-guide.pdf
//


class EZSPClient : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("running", running)() ];
nothrow @nogc:

    enum TypeName = StringLit!"ezsp";

    this(String name)
    {
        super(collectionTypeInfo!EZSPClient, name.move);
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => ash.stream;
    final void stream(Stream stream)
    {
        // reset and rebuild ASH
        this.ash = ASH(stream);
        ash.setPacketCallback(&incomingPacket);
    }

    final bool running() const pure
        => knownVersion && ash.isConnected();


    // API...

    final override bool validate() const pure
        => ash.stream !is null;

    final override const(char)[] statusMessage() const pure
        => running ? "Running" : super.statusMessage();

    final override bool enable(bool enable)
    {
        bool old = enabled;
        enabled = enable;
        if (!enable)
        {
            ash.reset();
            knownVersion = 0;
            requestedVersion = 0;
            sequenceNumber = 0;
        }
        return old;
    }

    final void setMessageHandler(void delegate(ubyte sequence, ushort command, const(ubyte)[] message) nothrow @nogc callback)
    {
        messageHandler = callback;
    }

    template setCallbackHandler(EZSP_Command)
    {
        static assert(is(typeof(EZSP_Command.Command) : ushort) && is(EZSP_Command.Response == struct),
                      EZSP_Command.stringof ~ " is not an EZSP command structure");

        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final void setCallbackHandler(Callback)(Callback responseHandler, void* userData = null)
        {
            alias Args = Parameters!Callback;
            static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* userData` argument in the first position.");
            enum HasUserData = Args.length > 0 && is(Args[0] == void*);

            auto handler = &commandHandlers.insert(EZSP_Command.Command, CommandHandler());

            handler.responseShim = &responseShim!(HasUserData, ResponseParams);
            handler.userData = HasUserData ? userData : null;
            static if (isDelegate!Callback)
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
    {
        static assert(is(typeof(EZSP_Command.Command) : ushort) && is(EZSP_Command.Request == struct) && is(EZSP_Command.Response == struct),
                      EZSP_Command.stringof ~ " is not an EZSP command structure");

        alias RequestParams = typeof(EZSP_Command.Request.tupleof);
        alias ResponseParams = typeof(EZSP_Command.Response.tupleof);

        final bool sendCommand(Callback)(Callback responseHandler, RequestParams args, void* userData = null)
        {
            if (!running)
                return false;

            alias Args = Parameters!Callback;
            static assert (is(Args == ResponseParams) || is(Args == AliasSeq!(void*, ResponseParams)), "Callback must be a function with arguments matching " ~ EZSP_Command.stringof ~ ".Response, and optionally a `void* userData` argument in the first position.");
            enum HasUserData = Args.length > 0 && is(Args[0] == void*);

            ubyte[EZSP_Command.Request.sizeof] buffer = void;
            size_t offset = 0;
            static foreach (i; 0 .. RequestParams.length)
            {{
                size_t len = args[i].ezspSerialise(buffer[offset..$]);
                assert(len != 0, "Request buffer too small! How did we miscalculate this?");
                offset += len;
            }}

            writeInfof("EZSP: sending request - " ~ EZSP_Command.stringof ~ "(x{0, 04x})", EZSP_Command.Command);

            static if (isDelegate!Callback)
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

        if (!ash.send(buffer[0..i]))
        {
            // error?!
            return -1;
        }
        return sequenceNumber++;
    }

    final override void update()
    {
        if (!enabled || !validate())
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

    bool enabled = true;

    ubyte requestedVersion;
    ubyte knownVersion;

    ubyte sequenceNumber;

    ASH ash;

    void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc messageHandler;
    Map!(ushort, CommandHandler) commandHandlers;
    ActiveRequests[16] activeRequests;

    void incomingPacket(const(ubyte)[] msg)
    {
        ubyte seq = msg[0];
        ushort control;
        ushort cmd;
        if (knownVersion >= 8)
        {
            assert(msg.length >= 5);

            control = msg[1] | (msg[2] << 8);
            cmd = msg[3] | (msg[4] << 8);
            msg = msg[5 .. $];
        }
        else
        {
            assert(msg.length >= 4);

            control = msg[1];

            if (msg.length >= 3 && msg[2] == 0xff)
            {
                assert(false); // TODO: we don't understand this case!
                if (msg.length < 4)
                    assert(false);
                cmd = msg[4];
                msg = msg[5..$];
            }
            else
            {
                assert(msg.length >= 3);

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

                knownVersion = requestedVersion;
                requestedVersion = 0;

                writeInfo("EZSP: agreed version: ", knownVersion);
                break;

            case 0x0058: // invalidCommand
                EzspStatus reason = cast(EzspStatus)msg[0];
                writeInfo("EZSP: invalid command: ", reason);
                break;

            default:
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
                        writeInfof("EZSP: unhandled message - seq: {0}  cmd: x{1,04x} - {2}", seq, command, cast(void[])msg);
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
    size_t taken = response.ezspDeserialise(args);
    if (taken != response.length)
    {
        writeWarning("EZSP: error deserialising response");
        return;
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

