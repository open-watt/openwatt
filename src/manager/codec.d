module manager.codec;

// Bespoke wire encodings: named decode/encode pairs that produce values of REAL types.
// An encoding name appears in profile grammar (dt48:yymmddhhmmss) and compiled descs only;
// encodings never mint types, and the record shape produced is an ordinary DataFormat.
// Registered types need no entry here - the grammar resolves bare type names against
// urt.typereg directly - so this table holds only encodings whose wire form is not a
// type's canonical image.

import urt.time : DateTime, get_date_time, get_sys_time, Month, SysTime;
import urt.typereg;

import manager.series;

nothrow @nogc:


struct Encoding
{
    const(char)[] name;
    ubyte wire_bytes;               // canonical-image bytes consumed; 0 = text-only
    DataFormat format;              // record shape produced; descs point at this instance
    // binary wire (null when text-only); image is post-swizzle, reading order
    bool function(const(void)[] image, void[] record) nothrow @nogc decode;
    bool function(const(void)[] record, void[] image) nothrow @nogc encode;
    // text wire (null when binary-only)
    ptrdiff_t function(const(char)[] token, void[] record) nothrow @nogc parse;
    ptrdiff_t function(const(void)[] record, char[] buffer) nothrow @nogc format_text;
}

const(Encoding)* find_encoding(const(char)[] name)
{
    foreach (ref e; g_encodings[0 .. g_num_encodings])
    {
        if (e.name == name)
            return &e;
    }
    return null;
}

const(Encoding)* encoding_by_index(ushort i)
{
    assert(i < g_num_encodings, "invalid encoding index");
    return &g_encodings[i];
}

ushort encoding_index_of(ref const Encoding e)
    => cast(ushort)(&e - g_encodings.ptr);

void register_builtin_encodings()
{
    const(TypeDetails)* dt = find_type_by_name("dt");
    assert(dt, "SysTime not registered");
    Encoding e = Encoding("yymmddhhmmss", 6, DataFormat(ValueType.user, Semantics.held, dt), &yymmddhhmmss_decode, &yymmddhhmmss_encode);
    register_encoding(e);
}

void register_encoding(Encoding e)
{
    assert(g_num_encodings < g_encodings.length, "too many encodings");
    debug foreach (ref x; g_encodings[0 .. g_num_encodings])
        assert(x.name != e.name, "encoding already registered");
    g_encodings[g_num_encodings++] = e;
}


unittest
{
    register_builtin_encodings();
    const(Encoding)* e = find_encoding("yymmddhhmmss");
    assert(e && e.wire_bytes == 6);
    assert(e.format.type == ValueType.user && e.format.user_type.name == "dt");

    ubyte[6] img = [26, 7, 18, 13, 45, 30];   // 2026-07-18 13:45:30, reading order
    SysTime st;
    assert(e.decode(img, (cast(void*)&st)[0 .. SysTime.sizeof]));
    DateTime dt = get_date_time(st);
    assert(dt.year == 2026 && dt.month == Month.July && dt.day == 18 &&
           dt.hour == 13 && dt.minute == 45 && dt.second == 30);

    ubyte[6] back;
    assert(e.encode((cast(const(void)*)&st)[0 .. SysTime.sizeof], back));
    assert(back == img);

    assert(find_encoding("no-such-encoding") is null);
}


private:

__gshared Encoding[16] g_encodings;
__gshared ushort g_num_encodings;

// six binary bytes yy MM dd hh mm ss in reading order
bool yymmddhhmmss_decode(const(void)[] image, void[] record)
{
    if (image.length < 6 || record.length < SysTime.sizeof)
        return false;
    const(ubyte)* i = cast(const(ubyte)*)image.ptr;
    DateTime dt;
    dt.year = cast(short)(2000 + i[0]);
    dt.month = cast(Month)i[1];
    dt.day = i[2];
    dt.hour = i[3];
    dt.minute = i[4];
    dt.second = i[5];
    *cast(SysTime*)record.ptr = get_sys_time(dt);
    return true;
}

bool yymmddhhmmss_encode(const(void)[] record, void[] image)
{
    if (image.length < 6 || record.length < SysTime.sizeof)
        return false;
    DateTime dt = get_date_time(*cast(const(SysTime)*)record.ptr);
    ubyte* o = cast(ubyte*)image.ptr;
    o[0] = cast(ubyte)(dt.year - 2000);
    o[1] = dt.month;
    o[2] = dt.day;
    o[3] = dt.hour;
    o[4] = dt.minute;
    o[5] = dt.second;
    return true;
}
