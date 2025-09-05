module protocol.mqtt.util;

nothrow @nogc:


inout(As)[] take(As = ubyte)(ref inout(ubyte)[] buffer, size_t n)
{
    inout(ubyte)[] r = buffer[0 .. n*As.sizeof];
    buffer = buffer[n*As.sizeof .. $];
    return cast(inout(As)[])r;
}

ubyte take(T : ubyte)(ref const(ubyte)[] buffer)
{
    ubyte r = buffer[0];
    buffer = buffer[1 .. $];
    return r;
}

ushort take(T : ushort)(ref const(ubyte)[] buffer)
{
    ushort r = (buffer[0] << 8) | buffer[1];
    buffer = buffer[2 .. $];
    return r;
}

uint take(T : uint)(ref const(ubyte)[] buffer)
{
    uint r = (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];
    buffer = buffer[4 .. $];
    return r;
}

inout(U)[] take(T : U[], U)(ref inout(ubyte)[] buffer)
{
    ushort len = (buffer[0] << 8) | buffer[1];
    inout(U)[] r = cast(inout(U)[])buffer[2 .. 2 + len];
    buffer = buffer[2 + len .. $];
    return r;
}

uint takeVarInt(ref const(ubyte)[] buffer)
{
    uint r = buffer[0];
    if (r < 128)
    {
        buffer = buffer[1..$];
        return r;
    }
    r = (r & 0x7F) | ((buffer[1] & 0x7F) << 7);
    if (buffer[1] < 128)
    {
        buffer = buffer[2..$];
        return r;
    }
    r |= (buffer[2] & 0x7F) << 14;
    if (buffer[2] < 128)
    {
        buffer = buffer[3..$];
        return r;
    }
    r |= buffer[3] << 21;
    if (buffer[3] < 128)
    {
        buffer = buffer[4..$];
        return r;
    }
    return -1;
}


void put(ref ubyte[] buffer, const(ubyte)[] val)
{
    buffer[0 .. val.length] = val[];
    buffer = buffer[val.length .. $];
}

void put(ref ubyte[] buffer, ubyte val)
{
    buffer[0] = val;
    buffer = buffer[1 .. $];
}

void put(ref ubyte[] buffer, ushort val)
{
    buffer[0] = val >> 8;
    buffer[1] = val & 0xFF;
    buffer = buffer[2 .. $];
}

void put(ref ubyte[] buffer, uint val)
{
    buffer[0] = val >> 24;
    buffer[1] = (val >> 16) & 0xFF;
    buffer[2] = (val >> 8) & 0xFF;
    buffer[3] = val & 0xFF;
    buffer = buffer[2 .. $];
}

void put(ref ubyte[] buffer, const(char)[] val)
{
    buffer.put(cast(ushort)val.length);
    buffer.put(cast(ubyte[])val);
}

void putVarInt(ref ubyte[] buffer, uint val)
{
    if (val >= (1 << 28))
        return;
    if (val < 128)
    {
        buffer[0] = cast(ubyte)val;
        buffer = buffer[1..$];
        return;
    }
    buffer[0] = (val & 0x7F) | 0x80;
    val >>= 7;
    if (val < 128)
    {
        buffer[1] = cast(ubyte)val;
        buffer = buffer[2..$];
        return;
    }
    buffer[1] = (val & 0x7F) | 0x80;
    val >>= 7;
    if (val < 128)
    {
        buffer[2] = cast(ubyte)val;
        buffer = buffer[3..$];
        return;
    }
    buffer[2] = (val & 0x7F) | 0x80;
    val >>= 7;
    if (val < 128)
    {
        buffer[3] = cast(ubyte)val;
        buffer = buffer[4..$];
    }
}
