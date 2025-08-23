module protocol.spinel;

import urt.endian;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.meta : AliasSeq;
import urt.string;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.spinel.client;

import router.stream;

nothrow @nogc:


class SpinelProtocolModule : Module
{
    mixin DeclareModule!"protocol.spinel";
nothrow @nogc:

    Map!(const(char)[], SpinelClient) clients;

    override void init()
    {
        app.console.registerCommand!client_add("/protocol/spinel/client", this, "add");
    }

    SpinelClient getClient(const(char)[] client)
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

    void client_add(Session session, const(char)[] name, const(char)[] stream)
    {
        auto mod_stream = app.moduleInstance!StreamModule;

        // is it an error to not specify a stream?
        assert(stream, "'stream' must be specified");

        Stream s = mod_stream.getStream(stream);
        if (!s)
        {
            session.writeLine("Stream does not exist: ", stream);
            return;
        }

        if (name.empty)
            mod_stream.generateStreamName("spinel");

        NoGCAllocator a = app.allocator;

        String n = name.makeString(a);
        SpinelClient client = a.allocT!SpinelClient(n.move, s);
        clients.insert(client.name[], client);

//        writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
    }
}


// SPINEL commands
enum Command : uint
{
    NOOP = 0,
    RESET = 1,
    PROP_VALUE_GET = 2,
    PROP_VALUE_SET = 3,
    PROP_VALUE_INSERT = 4,
    PROP_VALUE_REMOVE = 5,
    PROP_VALUE_IS = 6,
    PROP_VALUE_INSERTED = 7,
    PROP_VALUE_REMOVED = 8,
    PEEK = 18,
    PEEK_RET = 19,
    POKE = 20,
    PROP_VALUE_MULTI_GET = 21,
    PROP_VALUE_MULTI_SET = 22,
    PROP_VALUES_ARE = 23,
}

enum string[Command] spinelCommands = [
    Command.NOOP: "",
    Command.RESET: "",
    Command.PROP_VALUE_GET: "i",
    Command.PROP_VALUE_SET: "iD",
    Command.PROP_VALUE_INSERT: "iD",
    Command.PROP_VALUE_REMOVE: "iD",
    Command.PROP_VALUE_IS: "iD",
    Command.PROP_VALUE_INSERTED: "iD",
    Command.PROP_VALUE_REMOVED: "iD",
    Command.PEEK: "LS",
    Command.PEEK_RET: "LSD",
    Command.POKE: "LSD",
    Command.PROP_VALUE_MULTI_GET: "A(i)",
    Command.PROP_VALUE_MULTI_SET: "A(t(iD))",
    Command.PROP_VALUES_ARE: "A(t(iD))",
];


// Spinel data tuple
alias SpinelTuple(string fmt) = Tuple!(SpinelTypeTuple!fmt);

// Create a tuple of types for the spinel format string
template SpinelTypeTuple(string fmt)
{
    // parse the format string into an array of tokens
    enum tokens = SpinelFormatTokens!fmt;

    // append the data type for each format token
    alias SpinelTypeTuple = AliasSeq!();
    static foreach (i, t; tokens)
    {
        static if (t == "b")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, bool);
        else static if (t == "C")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, ubyte);
        else static if (t == "c")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, byte);
        else static if (t == "S")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, ushort);
        else static if (t == "s")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, short);
        else static if (t == "L")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, uint);
        else static if (t == "l")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, int);
        else static if (t == "i")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, uint);
        else static if (t == "6")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, IPv6Addr);
        else static if (t == "E")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, ubyte[8]);
        else static if (t == "e")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, MACAddress);
        else static if (t == "D")
        {
            static assert (i == tokens.length - 1, "Invalid format string: 'D' may only appear at the end!");
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, const(ubyte)[]);
        }
        else static if (t == "d")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, const(ubyte)[]);
        else static if (t == "U")
            SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, const(char)[]);
        else static if (t[0] == 't')
        {
            static assert (t.length > 3 && t[1] == '(' && t[$-1] == ')', "Invalid format string: 't(...)' must specify sub-types");
            static if (t.length > 3)
                SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, Tuple!(SpinelTypeTuple!(t[2..$-1])));
        }
        else static if (t[0] == 'A')
        {
            static assert (t.length > 3 && t[1] == '(' && t[$-1] == ')', "Invalid format string: 'A(...)' must specify sub-types");
            static assert (t[$-2] != 'D', "Invalid format string: 'D' may only appear at the end!");
            static if (t.length > 3)
            {
                static if (SpinelFormatTokens!(t[2..$-1]).length == 1)
                    SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, (SpinelTypeTuple!(t[2..$-1])[0])[]);
                else
                    SpinelTypeTuple = AliasSeq!(SpinelTypeTuple, SpinelTuple!(t[2..$-1])[]);
            }
        }
        else
            static assert (false, "Invalid format string");
    }
}

// Spinel data struct
struct SpinelData(string fmt)
{
    alias TypeTuple = SpinelTypeTuple!fmt;

    Tuple!TypeTuple data;

    this(TypeTuple args)
    {
        data = Tuple!TypeTuple(args);
    }

    size_t serialise(void[] buffer)
    {
        return spinelSerialise!fmt(data, buffer);
    }

    void deserialise(const(void)[] buffer)
    {
        data = spinelDeserialise!fmt(buffer);
    }
}


size_t spinelSerialise(string fmt)(ref SpinelTuple!fmt data, void[] buffer)
{
    enum string[] tokens = SpinelFormatTokens!fmt;

    ubyte[] buf = cast(ubyte[])buffer;

    static foreach (i, t; tokens)
    {
        static if (t == "b")
            buf.popFront() = data[i] ? 1 : 0;
        else static if (t == "C" || t == "c")
            buf.popFront() = data[i];
        else static if (t == "S" || t == "s")
        {
            buf[0..2] = data[i].nativeToLittleEndian;
            buf = buf[2..$];
        }
        else static if (t == "L" || t == "l")
        {
            buf[0..4] = data[i].nativeToLittleEndian;
            buf = buf[4..$];
        }
        else static if (t == "i")
        {
            if (data[i] < 0x80)
                buf.popFront() = cast(ubyte)data[i];
            else if (data[i] < 0x4000)
            {
                buf[0] = 0x80 | (data[i] & 0x7F);
                buf[1] = cast(ubyte)(data[i] >> 7);
                buf = buf[2..$];
            }
            else
            {
                assert(data[i] < 0x200000, "Can't encode values larger than 0x1FFFFF!");
                buf[0] = 0x80 | (data[i] & 0x7F);
                buf[1] = 0x80 | ((data[i] >> 7) & 0x7F);
                buf[2] = cast(ubyte)(data[i] >> 14);
                buf = buf[3..$];
            }
        }
        else static if (t == "6")
        {
            static foreach (j; 0..8)
                buf[j*2 .. (j+1)*2] = data[i].s[j].nativeToBigEndian;
            buf = buf[16..$];
        }
        else static if (t == "E")
        {
            buf[0..8] = data[i];
            buf = buf[8..$];
        }
        else static if (t == "e")
        {
            buf[0..6] = data[i].b;
            buf = buf[6..$];
        }
        else static if (t == "D")
        {
            static assert (i == tokens.length - 1, "'D' must be the last token in the format string");

            buf[0 .. data[i].length] = data[i][];
            buf = buf[data[i].length .. $];
        }
        else static if (t == "d")
        {
            buf[0 .. 2] = nativeToLittleEndian(cast(ushort)data[i].length);
            buf[2 .. 2 + data[i].length] = data[i][];
            buf = buf[2 + data[i].length .. $];
        }
        else static if (t == "U")
        {
            buf[0 .. data[i].length] = cast(const(ubyte)[])data[i][];
            buf[data[i].length] = '\0';
            buf = buf[data[i].length + 1 .. $];
        }
        else static if (t[0] == 't')
        {{
            static assert (t.length > 3, "Invalid format string");
            enum subFmt = t[2..$-1];

            size_t len = spinelSerialise!subFmt(data[i], buf[2..$]);
            buf[0..2] = nativeToLittleEndian(cast(ushort)len);
            buf = buf[2 + len .. $];
        }}
        else static if (t[0] == 'A')
        {{
            static assert (t.length > 3, "Invalid format string");
            enum subFmt = t[2..$-1];

            foreach (ref e; data[i])
            {
                size_t len = spinelSerialise!subFmt(e, buf);
                buf = buf[len .. $];
            }
        }}
        else
            static assert (false, "Invalid format string");
    }

    return buf.ptr - cast(ubyte*)buffer.ptr;
}

auto spinelDeserialise(string fmt)(const(void)[] buffer)
{
    enum string[] tokens = SpinelFormatTokens!fmt;
    SpinelTuple!fmt r;

    const(ubyte)[] buf = cast(ubyte[])buffer;

    static foreach (i, t; tokens)
    {
        static if (t == "b")
            r[i] = buf.popFront() ? true : false;
        else static if (t == "C" || t == "c")
            r[i] = buf.popFront();
        else static if (t == "S" || t == "s")
        {
            r[i] = buf[0..2].littleEndianToNative!ushort;
            buf = buf[2..$];
        }
        else static if (t == "L" || t == "l")
        {
            r[i] = buf[0..4].littleEndianToNative!uint;
            buf = buf[4..$];
        }
        else static if (t == "i")
        {
            if (buf[0] < 0x80)
                r[i] = buf.popFront();
            else if (buf[1] < 0x80)
            {
                r[i] = (buf[0] & 0x7F) | (buf[1] << 7);
                buf = buf[2..$];
            }
            else
            {
                assert(buf[2] < 0x80, "Maximum 3-byte integer encoding");
                r[i] = (buf[0] & 0x7F) | ((buf[1] & 0x7F) << 7) | (buf[2] << 14);
                buf = buf[3..$];
            }
        }
        else static if (t == "6")
        {
            static foreach (j; 0..8)
                r[i].s[j] = buf[j*2 .. (j+1)*2].bigEndianToNative!ushort;
            buf = buf[16..$];
        }
        else static if (t == "E")
        {
            r[i] = buf[0..8];
            buf = buf[8..$];
        }
        else static if (t == "e")
        {
            r[i].b = buf[0..6];
            buf = buf[6..$];
        }
        else static if (t == "D")
        {
            static assert (i == tokens.length - 1, "'D' must be the last token in the format string");

            r[i] = buf[0 .. $];
        }
        else static if (t == "d")
        {
            r[i] = buf[2 .. 2 + buf[0..2].littleEndianToNative!ushort];
            buf = buf[2 + r[i].length .. $];
        }
        else static if (t == "U")
        {
            r[i] = cast(char[])buf[0 .. strlen(cast(char*)buf.ptr)];
            buf = buf[r[i].length + 1 .. $];
        }
        else static if (t[0] == 't')
        {{
            static assert (t.length > 3, "Invalid format string");
            enum subFmt = t[2..$-1];

            ushort len = buf[0..2].littleEndianToNative!ushort;
            r[i] = spinelDeserialise!subFmt(buf[2..2+len]);
            buf = buf[2 + len .. $];
        }}
        else static if (t[0] == 'A')
        {{
            static assert (t.length > 3, "Invalid format string");
            enum subFmt = t[2..$-1];

            static if (SpinelFormatTokens!subFmt.length == 1)
                alias ArrayEl = SpinelTypeTuple!subFmt[0];
            else
                alias ArrayEl = SpinelTuple!subFmt;

            static if (DirectArray!subFmt)
            {
                static assert(ArrayEl.sizeof == subFmt.length, "!! Something went wrong with the tuple.sizeof!");

                r[i] = (cast(ArrayEl*)buf.ptr)[0 .. buf.length / subFmt.length];
            }
            else
            {
                // TODO: instead of allocating an array, we should use a range that does it lazily...

                import urt.mem;

                size_t len = 0;
                size_t count = 0;
                while (len < buf.length)
                {
                    size_t l = binaryLen!subFmt(buf[len..$]);
                    if (len + l > buf.length)
                        break;
                    len += l;
                    ++count;
                }
                r[i] = cast(ArrayEl[])tempAllocator().alloc(ArrayEl.sizeof * count);

                foreach (j; 0..count)
                {
                    len = binaryLen!subFmt(buf);
                    r[i][j] = spinelDeserialise!subFmt(buf);
                    buf = buf[len .. $];
                }
            }
        }}
        else
            static assert (false, "Invalid format string");
    }

    return r;
}


unittest
{
    ubyte[8] uid = [0,1,2,3,4,5,6,7];
    ubyte[1024] buffer = void;

    alias TupTy = Tuple!(const(char)[], uint, MACAddress);
    TupTy[2] arr = [ TupTy("Hello", 20, MACAddress.lldp_multicast), TupTy(" world!", 1337, MACAddress.broadcast) ];

    auto x = SpinelData!"bcslCSLt(iii)6EeUdA(Uie)"(true, 1, 2, 3, 4, 5, 6, Tuple!(uint, uint, uint)(8, 1337, 0xFEED), IPv6Addr.linkLocal_allNodes, uid, MACAddress.broadcast, "Hello world!", uid[2..5], arr);
    SpinelData!"bcslCSLt(iii)6EeUdA(Uie)" y;

    size_t l = x.serialise(buffer);
    y.deserialise(buffer[0..l]);

    assert(x == y);
}


private:

import router.iface.mac : MACAddress;
import urt.inet : IPv6Addr;
import urt.meta.tuple;

size_t binaryLen(string fmt)(const(void)[] buffer)
{
    enum string[] tokens = SpinelFormatTokens!fmt;

    const(ubyte)* data = cast(ubyte*)buffer.ptr;
    size_t len = 0;

    static foreach (i, t; tokens)
    {
        static if (t == "b" || t == "C" || t == "c")
            len += 1;
        else static if (t == "S" || t == "s")
            len += 2;
        else static if (t == "L" || t == "l")
            len += 4;
        else static if (t == "e")
            len += 6;
        else static if (t == "E")
            len += 8;
        else static if (t == "6")
            len += 16;
        else static if (t == "i")
        {
            if (data[len] < 0x80)
                len += 1;
            else if (data[len + 1] < 0x4000)
                len += 2;
            else
                len += 3;
        }
        else static if (t == "D")
            len += data.length;
        else static if (t == "d" || t[0] == 't')
            len += 2 + data[len..len+2][0..2].littleEndianToNative!ushort;
        else static if (t == "U")
            len += strlen(cast(char*)data + len) + 1;
        else static if (t[0] == 'A')
        {
            static assert (t.length > 3, "Invalid format string");
            enum subFmt = t[2..$-1];

            while (len < buffer.length)
            {
                size_t l = binaryLen!subFmt(data[len..buffer.length]);
                if (len + l > buffer.length)
                    break;
                len += l;
            }
        }
        else
            static assert (false, "Invalid format string");
    }

    return len;
}

enum string[] SpinelFormatTokens(string fmt) = (string fmt) {
        string[] tokens;
        foreach (t; SpinelFormatRange(fmt))
            tokens ~= t;
        return tokens;
    }(fmt);

// Takes tokens from a spinel format string
struct SpinelFormatRange
{
pure nothrow @nogc:
    string fmt;

    bool empty()
        => fmt.length == 0;

    string front()
    {
        if (fmt.length > 1 && fmt[1] == '(')
            return fmt[0 .. 3 + closingParen(fmt[2..$])];
        return fmt[0..1];
    }

    void popFront()
    {
        if (fmt.length > 1 && fmt[1] == '(')
            fmt = fmt[3 + closingParen(fmt[2..$]) .. $];
        else
            fmt = fmt[1..$];
    }

    static size_t closingParen(string s)
    {
        int depth = 0;
        foreach (i, c; s)
        {
            if (c == '(')
                ++depth;
            else if (c == ')')
            {
                if (depth == 0)
                    return i;
                --depth;
            }
        }
        assert(false, "No closing paren in string");
    }
}

template DirectArray(string fmt)
{
    alias Rebind = bool;
    static foreach(c; fmt)
        static if (c != 'b' && c != 'C' && c != 'c')
            Rebind = int;
    enum DirectArray = is(Rebind == bool);
}
