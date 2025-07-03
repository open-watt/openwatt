module protocol.ezsp;

import urt.endian;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.collection;
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

    Collection!EZSPClient clients;

    override void init()
    {
        g_app.console.registerCollection("/protocol/ezsp/client", clients);
    }

    override void update()
    {
        clients.updateAll();
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
