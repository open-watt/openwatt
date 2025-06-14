module protocol.ezsp;

import urt.endian;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.ezsp.client;

import router.stream;

nothrow @nogc:


class EZSPProtocolModule : Module
{
    mixin DeclareModule!"protocol.ezsp";
nothrow @nogc:

    Map!(const(char)[], EZSPClient) clients;

    override void init()
    {
        g_app.console.registerCommand!client_add("/protocol/ezsp/client", this, "add");
    }

    EZSPClient getClient(const(char)[] client)
    {
        if (auto c = client in clients)
            return *c;
        return null;
    }

    override void update()
    {
        foreach(name, client; clients)
            client.update();
    }

    void client_add(Session session, const(char)[] name, Stream stream)
    {
        if (name.empty)
            getModule!StreamModule.generateStreamName("ezsp");

        NoGCAllocator a = g_app.allocator;

        String n = name.makeString(a);
        EZSPClient client = a.allocT!EZSPClient(n.move, stream);
        clients.insert(client.name[], client);

//        writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
    }
}


size_t ezspSerialise(T)(ref T data, ubyte[] buffer)
{
    static assert(!is(T == class) && !is(T == interface) && !is(T == U*, U), T.stringof ~ " is not POD");

    static if (is(T == struct))
    {
        size_t length = 0;
        static foreach(ref m; s.tupleof)
        {
            alias M = typeof(m);
            size_t len = ezspSerialise(m, buffer[length..$]);
            if (len == 0)
                return 0;
            length += len;
        }
        return length;
    }
    else static if (is(T == ubyte[N], size_t N))
    {
        if (buffer.length < N)
            return 0;
        buffer[0 .. N] = data;
        return N;
    }
    else
    {
        if (buffer.length < T.sizeof)
            return 0;
        buffer[0 .. T.sizeof] = nativeToLittleEndian(data);
        return T.sizeof;
    }
}

size_t ezspDeserialise(T)(const(ubyte)[] data, out T t)
{
    static assert(!is(T == class) && !is(T == interface) && !is(T == U*, U), T.stringof ~ " is not POD");

    static if (is(T == struct))
    {
        size_t offset = 0;
        alias tup = t.tupleof;
        static foreach(i; 0..tup.length)
        {{
            size_t took = data[offset..$].ezspDeserialise(tup[i]);
            if (took == 0)
                return 0;
            offset += took;
        }}
        return offset;
    }
    else static if (is(T == ubyte[N], size_t N))
    {
        if (data.length < N)
            return 0;
        t = data[0 .. N];
        return N;
    }
    else
    {
        if (data.length < T.sizeof)
            return 0;
        t = data[0 .. T.sizeof].littleEndianToNative!T;
        return T.sizeof;
    }
}
