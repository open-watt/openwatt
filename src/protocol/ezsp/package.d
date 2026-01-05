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
        g_app.console.register_collection("/protocol/ezsp/client", clients);
    }

    override void update()
    {
        clients.update_all();
    }
}


size_t ezsp_serialise(T)(ref T data, ubyte[] buffer)
{
    static assert(!is(T == class) && !is(T == interface) && !is(T == U*, U), T.stringof ~ " is not POD");

    static if (is(T == struct))
    {
        size_t bytes = 0;
        alias members = data.tupleof;
        static foreach(i; 0 .. members.length)
        {{
            static if (is(typeof(members[i]) == const(ushort)[]))
            {
                // HACK: EZSP_AddEndpoint is the only message that has a ushort[], and that message is
                //       special because there are 2 arrays back-to-back, so it needs this hack to write
                //       the in-clusters and out-clusters in one sequence with 2 length's prepended
                static if (i == members.length - 2)
                {
                    size_t len = (members[i].length + members[i + 1].length)*2;
                    if (buffer.length < bytes + 2 + len)
                        return 0;
                    buffer[bytes++] = cast(ubyte)members[i].length;
                    buffer[bytes++] = cast(ubyte)members[i + 1].length;
                    ushort* arr = cast(ushort*)(buffer.ptr + bytes);
                    arr[0 .. members[i].length] = members[i];
                    arr += members[i].length;
                    arr[0 .. members[i + 1].length] = members[i + 1];
                    bytes += len;
                }
            }
            else
            {
                size_t len = ezsp_serialise(members[i], buffer[bytes..$]);
                if (len == 0)
                    return 0;
                bytes += len;
            }
        }}
        return bytes;
    }
    else static if (is(T == ubyte[N], size_t N))
    {
        if (buffer.length < N)
            return 0;
        buffer[0 .. N] = data;
        return N;
    }
    else static if (is(T == ubyte[]))
    {
        static assert(false, "TODO: This struct message is not yet supported!");
    }
    else static if (is(T : const(ubyte)[]))
    {
        assert(data.length <= 255, "Data must be <= 255 bytes");
        if (buffer.length < 1 + data.length)
            return 0;
        buffer[0] = cast(ubyte)data.length;
        buffer[1 .. 1 + data.length] = data[];
        return 1 + data.length;
    }
    else
    {
        if (buffer.length < T.sizeof)
            return 0;
        buffer[0 .. T.sizeof] = nativeToLittleEndian(data);
        return T.sizeof;
    }
}

size_t ezsp_deserialise(T)(const(ubyte)[] data, out T t)
{
    static assert(!is(T == class) && !is(T == interface) && !is(T == U*, U), T.stringof ~ " is not POD");

    static if (is(T == struct))
    {
        size_t offset = 0;
        alias tup = t.tupleof;
        static foreach(i; 0..tup.length)
        {{
            static if (is(typeof(tup[i]) == const(ushort)[]))
            {
                // HACK: EZSP_AddEndpoint is the only message that has a ushort[], and that message is
                //       special because there are 2 arrays back-to-back, so it needs this hack to write
                //       the in-clusters and out-clusters in one sequence with 2 length's prepended
                static if (i == tup.length - 2)
                {
                    if (data.length < offset + 2)
                        return 0;
                    ubyte len1 = data.ptr[offset];
                    ubyte len2 = data.ptr[offset + 1];
                    size_t len = 2 + (len1 + len2)*2;
                    if (data.length < offset + len)
                        return 0;
                    const arr = cast(ushort*)(data.ptr + offset + 2);
                    tup[i] = arr[0 .. len1];
                    tup[i + 1] = (arr + len1)[0 .. len2];
                    offset += len;
                }
            }
            else
            {
                size_t took = data.ptr[offset..data.length].ezsp_deserialise(tup[i]);
                if (took == 0)
                    return 0;
                offset += took;
            }
        }}
        return offset;
    }
    else static if (is(T == ubyte[N], size_t N))
    {
        if (data.length < N)
            return 0;
        t = data.ptr[0 .. N];
        return N;
    }
    else static if (is(T == U[N], U, size_t N))
    {
        if (data.length < T.sizeof)
            return 0;
        const(ubyte)* p = data.ptr;
        for (size_t i = 0; i < N; i++, p += U.sizeof)
            t[i] = p[0..U.sizeof].littleEndianToNative!U;
        return T.sizeof;
    }
    else static if (is(T : const(ubyte)[]))
    {
        if (data.length < 1 || data.length < 1 + data[0])
            return 0;
        t = (data.ptr + 1)[0 .. data[0]];
        return 1 + t.length;
    }
    else
    {
        if (data.length < T.sizeof)
            return 0;
        t = data.ptr[0 .. T.sizeof].littleEndianToNative!T;
        return T.sizeof;
    }
}
