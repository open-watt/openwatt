module urt.string.format;

import urt.conv : parseIntFast;
import urt.string;
import urt.traits;
import urt.util;

public import urt.mem.temp : tformat, tconcat, tstring;


nothrow @nogc:

debug
{
    static bool InFormatFunction = false;
}

alias StringifyFunc = ptrdiff_t delegate(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) nothrow @nogc;
alias IntifyFunc = ptrdiff_t delegate() nothrow @nogc;


ptrdiff_t toString(T)(auto ref T value, char[] buffer)
{
    import urt.string.format : FormatArg;

    debug InFormatFunction = true;
    FormatArg a = FormatArg(value);
    ptrdiff_t r = a.getString(buffer, null, null);
    debug InFormatFunction = false;
    return r;
}

char[] concat(Args...)(char[] buffer, auto ref Args args)
{
    static if (Args.length == 0)
    {
        return buffer.ptr[0 .. 0];
    }
    else static if ((Args.length == 1 && allAreStrings!Args) || allConstCorrectStrings!Args)
    {
        // this implementation handles pure string concatenations
        if (!buffer.ptr)
        {
            size_t length = 0;
            static foreach (i, s; args)
            {
                static if (is(typeof(s) : char))
                    length += 1;
                else
                    length += s.length;
            }
            return (cast(char*)null)[0 .. length];
        }
        size_t offset = 0;
        static foreach (i, s; args)
        {
            static if (is(typeof(s) : char))
            {
                if (buffer.length < offset + 1)
                    return null;
                buffer.ptr[offset++] = s;
            }
            else
            {
                if (buffer.length < offset + s.length)
                    return null;
                buffer.ptr[offset .. offset + s.length] = s.ptr[0 .. s.length];
                offset += s.length;
            }
        }
        return buffer.ptr[0 .. offset];
    }
    static if (allAreStrings!Args)
    {
        // TODO: why can't inline this?!
//        pragma(inline, true);

        // avoid duplicate instantiations with different attributes...
        return concat!(constCorrectedStrings!Args)(buffer, args);
    }
    else
    {
        // this implementation handles all the other kinds of things!

        debug if (!__ctfe) InFormatFunction = true;
        FormatArg[Args.length] argFuncs;
        // TODO: no need to collect int-ify functions in the arg set...
        static foreach(i, arg; args)
            argFuncs[i] = FormatArg(arg);
        char[] r = concatImpl(buffer, argFuncs);
        debug if (!__ctfe) InFormatFunction = false;
        return r;
    }
}

char[] format(Args...)(char[] buffer, const(char)[] fmt, ref Args args)
{
    debug InFormatFunction = true;
    FormatArg[Args.length] argArr = void;
    static foreach(i, arg; args)
        argArr[i] = FormatArg(arg);
    char[] r = formatImpl(buffer, fmt, argArr);
    debug InFormatFunction = false;
    return r;
}

ptrdiff_t formatValue(T)(auto ref T value, char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs)
{
    static if (is(typeof(&value.toString) : StringifyFunc))
        return value.toString(buffer, format, formatArgs);
    else
        return value.defFormat.toString(buffer, format, formatArgs);
}

struct FormatArg
{
    enum IsAggregate(T) = is(T == struct) || is(T == class);

    private this(T)(ref T value) pure nothrow @nogc
    {
        static if (IsAggregate!T && is(typeof(&value.toString) : StringifyFunc))
            toString = &value.toString;
        else static if (IsAggregate!T && __traits(compiles, value.toString(buffer, "format", cast(FormatArg[])null) == 0))
        {
            // wrap in a delegate that adjusts for format + args...
            static assert(false);
        }
        else static if (IsAggregate!T && __traits(compiles, value.toString(buffer, "format") == 0))
        {
            // wrap in a delegate that adjusts for format...
            static assert(false);
        }
        else static if (IsAggregate!T && __traits(compiles, value.toString(buffer) == 0))
        {
            // wrap in a delegate...
            static assert(false);
        }
        else static if (IsAggregate!T && __traits(compiles, value.toString((const(char)[]){}) == 0))
        {
            // version with a sink function...
            // wrap in a delegate that adjusts for format + args...
            static assert(false);
        }
        else
            toString = &defFormat(value).toString;

        static if (is(typeof(&defFormat(value).toInt)))
            toInt = &defFormat(value).toInt;
        else
            toInt = null;
    }

    ptrdiff_t getString(char[] buffer, const(char)[] format, const(FormatArg)[] args) const nothrow @nogc
    {
        return toString(buffer, format, args);
    }
    ptrdiff_t getLength(const(char)[] format, const(FormatArg)[] args) const nothrow @nogc
    {
        return toString(null, format, args);
    }

    bool canInt() const nothrow @nogc
    {
        return toInt != null;
    }
    ptrdiff_t getInt() const nothrow @nogc
    {
        return toInt();
    }

private:
    // TODO: we could assert that the delegate pointers match, and only store it once...
    StringifyFunc toString;
    IntifyFunc toInt;
}


private:

pragma(inline, true)
DefFormat!T* defFormat(T)(ref const(T) value) pure nothrow @nogc
{
    return cast(DefFormat!T*)&value;
}

ptrdiff_t defToString(T)(ref const(T) value, char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) nothrow @nogc
{
    return (cast(DefFormat!T*)&value).toString(buffer, format, formatArgs);
}

struct DefFormat(T)
{
    T value;

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
    {
        static if (is(T == typeof(null)))
        {
            if (!buffer.ptr)
                return 4;
            if (buffer.length < 4)
                return -1;
            buffer[0 .. 4] = "null";
            return 4;
        }
        else static if (is(T == bool))
        {
            size_t len = value ? 4 : 5;
            if (!buffer.ptr)
                return len;
            if (buffer.length < len)
                return -1;
            buffer[0 .. len] = value ? "true" : "false";
            return len;
        }
        else static if (is(T == char) || is(T == wchar) || is(T == dchar))
        {
            if (is(T == char) || value <= 0x7F)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < 1)
                        return -1;
                    buffer[0] = cast(char)value;
                }
                return 1;
            }
            else if (value <= 0x7FF)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < 2)
                        return -1;
                    buffer[0] = cast(char)(0xC0 | (value >> 6));
                    buffer[1] = cast(char)(0x80 | (value & 0x3F));
                }
                return 2;
            }
            else if (value <= 0xFFFF)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < 3)
                        return -1;
                    buffer[0] = cast(char)(0xE0 | (value >> 12));
                    buffer[1] = cast(char)(0x80 | ((value >> 6) & 0x3F));
                    buffer[2] = cast(char)(0x80 | (value & 0x3F));
                }
                return 3;
            }
            else if (value <= 0x10FFFF)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < 4)
                        return -1;
                    buffer[0] = cast(char)(0xF0 | (value >> 18));
                    buffer[1] = cast(char)(0x80 | ((value >> 12) & 0x3F));
                    buffer[2] = cast(char)(0x80 | ((value >> 6) & 0x3F));
                    buffer[3] = cast(char)(0x80 | (value & 0x3F));
                }
                return 4;
            }
            else
            {
                assert(false, "Invalid code point");
                return 0;
            }
        }
        else static if (is(T == double) || is(T == float))
        {
            import urt.conv : formatFloat, formatInt;

            char[16] tmp = void;
            if (format.length && format[0] == '*')
            {
                bool success;
                size_t arg = format[1..$].parseIntFast(success);
                if (!success || !formatArgs[arg].canInt)
                    return -2;
                size_t width = formatArgs[arg].getInt;
                size_t len = width.formatInt(tmp);
                format = tmp[0..len];
            }
            return formatFloat(value, buffer, format);
        }
        else static if (is(T == ulong) || is(T == long))
        {
            import urt.conv : formatInt, formatUint;

            // TODO: what formats are interesting for ints?

            bool leadingZeroes = false;
            bool toLower = false;
            bool varLen = false;
            ptrdiff_t padding = 0;
            uint base = 10;

            static if (is(T == long))
            {
                bool showSign = false;
                if (format.length && format[0] == '+')
                {
                    showSign = true;
                    format.popFront;
                }
            }
            if (format.length && format[0] == '0')
            {
                leadingZeroes = true;
                format.popFront;
            }
            if (format.length && format[0] == '*')
            {
                varLen = true;
                format.popFront;
            }
            if (format.length && format[0].isNumeric)
            {
                bool success;
                padding = format.parseIntFast(success);
                if (varLen)
                {
                    if (padding < 0 || !formatArgs[padding].canInt)
                        return -2;
                    padding = formatArgs[padding].getInt;
                }
            }
            if (format.length)
            {
                char b = format[0] | 0x20;
                if (b == 'x')
                {
                    base = 16;
                    toLower = format[0] == 'x' && buffer.ptr;
                }
                else if (b == 'b')
                    base = 2;
                else if (b == 'o')
                    base = 8;
                else if (b == 'd')
                    base = 10;
                format.popFront;
            }

            static if (is(T == long))
                size_t len = formatInt(value, buffer, base, cast(uint)padding, leadingZeroes ? '0' : ' ', showSign);
            else
                size_t len = formatUint(value, buffer, base, cast(uint)padding, leadingZeroes ? '0' : ' ');

            if (toLower && len > 0)
            {
                for (size_t i = 0; i < len; ++i)
                    if (cast(uint)(buffer.ptr[i] - 'A') < 26)
                        buffer.ptr[i] |= 0x20;
            }

            return len;
        }
        else static if (is(T == ubyte) || is(T == ushort) || is(T == uint))
        {
            return defToString(ulong(value), buffer, format, formatArgs);
        }
        else static if (is(T == byte) || is(T == short) || is(T == int))
        {
            return defToString(long(value), buffer, format, formatArgs);
        }
        else static if (is(T == const(char)*) || is(T == const(char*)))
        {
            const char[] t = value[0 .. value.strlen];
            return t.defToString(buffer, format, formatArgs);
        }
        else static if (is(T : const(U)*, U))
        {
            static assert(size_t.sizeof == 4 || size_t.sizeof == 8);
            enum Fmt = "0" ~ (size_t.sizeof == 4 ? "8" : "16") ~ "X";
            size_t p = cast(size_t)value;
            return p.defToString(buffer, Fmt, null);
        }
        else static if (is(T == const char[]))
        {
            bool leftJustify = false;
            bool varLen = false;
            ptrdiff_t width = value.length;
            if (format.length && format[0] == '-')
            {
                leftJustify = true;
                format.popFront;
            }
            if (format.length && format[0] == '*')
            {
                varLen = true;
                format.popFront;
            }
            if (varLen && (!format.length || !format[0].isNumeric))
                return -2;
            if (format.length && format[0].isNumeric)
            {
                bool success;
                width = format.parseIntFast(success);
                if (varLen)
                {
                    if (width < 0 || !formatArgs[width].canInt)
                        return -2;
                    width = formatArgs[width].getInt;
                }
                if (width < value.length)
                    width = value.length;
            }

            if (!buffer.ptr)
                return width;
            if (buffer.length < width)
                return -1;

            // TODO: accept padd string in the formatSpec?

            size_t padding = width - value.length;
            size_t pad = 0, len = 0;
            if (!leftJustify && padding > 0)
            {
                pad = buffer.length < padding ? buffer.length : padding;
                buffer[0 .. pad] = ' ';
                buffer.takeFront(pad);
            }
            len = buffer.length < value.length ? buffer.length : value.length;
            buffer[0 .. len] = value[0 .. len];
            if (padding > 0 && leftJustify)
            {
                buffer.takeFront(len);
                pad = buffer.length < padding ? buffer.length : padding;
                buffer[0 .. pad] = ' ';
            }
            return pad + len;
        }
        else static if (is(T : const char[]))
        {
            return defToString!(const char[])(cast(const char[])value[], buffer, format, formatArgs);
        }
//        else static if (is(T : const(wchar)[]))
//        {
//        }
//        else static if (is (T : const(U)[], U : dchar))
//        {
//            // TODO: UTF ENCODE...
//        }
        else static if (is(T == void[]) || is(T == const(void)[]))
        {
            if (!value.length)
                return 0;

            int grp1 = 1, grp2 = 0;
            if (format.length && format[0].isNumeric)
            {
                bool success;
                grp1 = cast(int)format.parseIntFast(success);
                if (success && format.length > 0 && format[0] == ':' &&
                               format.length > 1 && format[1].isNumeric)
                {
                    format.popFront();
                    grp2 = cast(int)format.parseIntFast(success);
                }
                if (!success)
                    return -2;
            }

            if (!buffer.ptr)
            {
                size_t len = value.length*2;
                if (grp1)
                    len += (value.length-1) / grp1;
                return len;
            }

            char[] hex = toHexString(cast(ubyte[])value, buffer, grp1, grp2);
            return hex.length;
        }
        else static if (is(T : const U[], U))
        {
            // arrays of other stuff
            size_t len = 1;
            if (buffer.ptr)
            {
                if (buffer.length < 1)
                    return -1;
                buffer[0] = '[';
            }

            for (size_t i = 0; i < value.length; ++i)
            {
                if (i > 0)
                {
                    if (buffer.ptr)
                    {
                        if (len == buffer.length)
                            return -1;
                        buffer[len] = ',';
                    }
                    ++len;
                }

                FormatArg arg = FormatArg(value[i]);
                if (buffer.ptr)
                {
                    ptrdiff_t argLen = arg.getString(buffer.ptr[len .. buffer.length], format, formatArgs);
                    if (argLen < 0)
                        return argLen;
                    len += argLen;
                }
                else
                    len += arg.getLength(format, formatArgs);
            }

            if (buffer.ptr)
            {
                if (len == buffer.length)
                    return -1;
                buffer[len] = ']';
            }
            return ++len;
        }
        else static if (is(T B == enum))
        {
            // TODO: optimise short enums with a TABLE!

            // TODO: should probably return FQN ???
            string key = null;
            val: switch (value)
            {
                static foreach (i, KeyName; __traits(allMembers, T))
                {
                    static if (!EnumKeyIsDuplicate!(T, i))
                    {
                        case __traits(getMember, T, KeyName):
                            key = KeyName;
                            break val;
                    }
                }
                default:
                    if (!buffer.ptr)
                        return T.stringof.length + 2 + defToString!B(cast(B)value, null, null, null);

                    if (buffer.length < T.stringof.length + 2)
                        return -1;
                    buffer[0 .. T.stringof.length] = T.stringof;
                    buffer[T.stringof.length] = '(';
                    ptrdiff_t len = defToString!B(*cast(B*)&value, buffer[T.stringof.length + 1 .. $], null, null);
                    if (len < 0)
                        return len;
                    len = T.stringof.length + 2 + len;
                    if (buffer.length < len)
                        return -1;
                    buffer[len - 1] = ')';
                    return len;
            }

            size_t len = T.stringof.length + 1 + key.length;
            if (!buffer.ptr)
                return len;

            if (buffer.length < len)
                return -1;
            buffer[0 .. T.stringof.length] = T.stringof;
            buffer[T.stringof.length] = '.';
            buffer[T.stringof.length + 1 .. len] = key[];
            return len;
        }
        else static if (is(T == class))
        {
            try
            {
                const(char)[] t = (cast()value).toString();
                if (!buffer.ptr)
                    return t.length;
                if (buffer.length < t.length)
                    return -1;
                buffer[0 .. t.length] = t[];
                return t.length;
            }
            catch (Exception)
                return -1;
        }
        else static if (is(T == const))
        {
            return defToString!(Unqual!T)(cast()value, buffer, format, formatArgs);
        }
        else static if (is(T == struct))
        {
            // general structs
            if (buffer.ptr)
            {
                if (buffer.length < T.stringof.length + 2)
                    return -1;
                buffer[0 .. T.stringof.length] = T.stringof;
                buffer[T.stringof.length] = '(';
            }

            size_t len = T.stringof.length + 1;
            static foreach (i; 0 .. value.tupleof.length)
            {{
                static if (i > 0)
                {
                    if (buffer.ptr)
                    {
                        if (len + 2 > buffer.length)
                            return -1;
                        buffer[len .. len + 2] = ", ";
                    }
                    len += 2;
                }

                FormatArg arg = FormatArg(value.tupleof[i]);
                if (buffer.ptr)
                {
                    ptrdiff_t argLen = arg.getString(buffer.ptr[len .. buffer.length], null, null);
                    if (argLen < 0)
                        return argLen;
                    len += argLen;
                }
                else
                    len += arg.getLength(null, null);

            }}

            if (buffer.ptr)
            {
                if (len == buffer.length)
                    return -1;
                buffer[len] = ')';
            }
            return ++len;
        }
        else
            static assert(false, "Not implemented for type: ", T.stringof);
    }

    static if (isSomeInt!T || is(T == bool))
    {
        ptrdiff_t toInt() const pure nothrow @nogc
        {
            static if (T.max > ptrdiff_t.max)
                debug assert(value <= ptrdiff_t.max);
            return cast(ptrdiff_t)value;
        }
    }
}

char[] concatImpl(char[] buffer, const(FormatArg)[] args) nothrow @nogc
{
    size_t len = 0;
    foreach (a; args)
    {
        ptrdiff_t r = a.getString(buffer.ptr ? buffer[len..$] : null, null, null);
        if (r < 0)
            return null;
        len += r;
    }
    return buffer.ptr[0..len];
}

char[] formatImpl(char[] buffer, const(char)[] format, const(FormatArg)[] args) nothrow @nogc
{
    char *pBuffer = buffer.ptr;
    size_t length = 0;

    while (format.length > 0)
    {
        if (format[0] == '\\')
        {
            if (format.length == 1)
                break;
            format.popFront;
            goto write_char;
        }
        else if (format[0] == '{')
        {
            ptrdiff_t len = parseFormat(format, buffer, args);
            if (len < 0)
            {
                assert(len == -1, "Bad format string!");
                return null;
            }
            length += len;
        }
//        else if (0) // TODO: handle ANSI codes for colour and shiz...?
//        {
//        }
        else
        {
        write_char:
            char c = format.popFront;
            if (buffer.ptr)
            {
                if (buffer.length == 0)
                    return null;
                buffer.popFront = c;
            }
            ++length;
        }
    }
    return pBuffer[0..length];
}

ptrdiff_t parseFormat(ref const(char)[] format, ref char[] buffer, const(FormatArg)[] args) nothrow @nogc
{
    if (format.popFront != '{')
    {
        assert(false, "Not a format string!");
        return -2;
    }

    format = format.trimFront;
    if (format.length == 0)
        return -2;

    // check for indirection
    const(char)[] immediate = null;
    bool bIndirect = false;
    ptrdiff_t arg = 0;
    if (format[0] == '\'')
    {
        format.popFront;
        const(char)* pFormat = format.ptr;
        while (format.length && format[0] != '\'')
            format.popFront;
        if (!format.length)
            return -2;
        immediate = pFormat[0 .. format.ptr - pFormat];
        format.popFront;
    }
    else
    {
        if (format[0] == '@')
        {
            bIndirect = true;
            format.popFront;
        }
        bool varRef = false;
        if (format[0] == '*')
        {
            varRef = true;
            format.popFront;
        }

        // get the arg index
        bool success;
        arg = format.parseIntFast(success);
        if (!success)
        {
            assert(false, "Invalid format string: Number expected!");
            return -2;
        }
        if (arg < 0)
            arg = args.length + arg;
        if (varRef)
        {
            if (arg < 0 || arg >= args.length || !args[arg].canInt)
                return -2;
            arg = args[arg].getInt;
        }
        if (arg < 0 || arg >= args.length)
        {
            assert(false, "Invalid arg index!");
            return -2;
        }
    }

    format = format.trimFront;
    if (format.length == 0)
        return -2;

    // get the format string (if present)
    const(char)[] formatSpec;
    if (format[0] == ',')
    {
        format.popFront;
        const(char)* pFormat = format.ptr;
        while (format.length && format[0] != '}')
            format.popFront;
        if (!format.length)
            return -2;
        formatSpec = pFormat[0 .. format.ptr - pFormat];
        formatSpec = formatSpec.trim;
    }

    // expect terminating '}'
    if (format.popFront() != '}')
    {
        assert(false, "Invalid format string!");
        return -2;
    }

    // check for universal format strings
    char[64] indirectFormatSpec = void;
    if (formatSpec.length)
    {
        // indrect formatting allows to take the format string from another parameter
        while (formatSpec.length && (formatSpec[0] == '?' || formatSpec[0] == '!' || formatSpec[0] == '@'))
        {
            char token = formatSpec.popFront();

//            bool varRef = false;
//            if (formatSpec.length && formatSpec[0] == '*')
//            {
//                varRef = true;
//                formatSpec.popFront();
//            }

            bool success;
            ptrdiff_t index = formatSpec.parseIntFast(success);
//            if (varRef)
//            {
//                if (arg < 0 || !args[arg].canInt)
//                    return -2;
//                arg = args[arg].getInt;
//            }
            if (!success)
            {
                assert(false, "Invalid format string: Number expected!");
                return -2;
            }

            if (token == '?' || token == '!')
            {
                if (!args[index].canInt)
                {
                    assert(false, "Argument can not be interpreted as an integer!");
                    return -2;
                }
                ptrdiff_t condition = args[index].getInt;
                if ((token == '?' && !condition) || (token == '!' && condition))
                    return 0;
            }
            else if (token == '@')
            {
                size_t formatLen = args[index].getLength(null, null);
                // TODO: we should use a growable buffer, but for now, just assume it's short
                assert(formatLen <= indirectFormatSpec.sizeof);
//                indirectFormatSpec.reserve(formatLen);
                args[index].getString(indirectFormatSpec, null, null);
                formatSpec = indirectFormatSpec[0 .. formatLen];
            }
        }
    }

    ptrdiff_t len;
    if (immediate.ptr)
    {
        len = immediate.defToString(buffer, formatSpec, args);
    }
    else if (bIndirect)
    {
        // TODO: i think this is incorrect... i don't think the indirect format should be supplied formatSpec...
        //       i think the string should be fetched raw, and then the formatSpec applied to the resolved text?

        // interpret the arg as an indirect format string
        // TODO: make growable?
        char[128] indirectFormat = void;
//        MutableString128 indirectFormat(Reserve, bytes);
        ptrdiff_t bytes = args[arg].getString(indirectFormat[], formatSpec, args);
        if (bytes < 0)
            return -2;
        char[] t = formatImpl(buffer, indirectFormat.ptr[0 .. bytes], args);
        len = t.length;
    }
    else
    {
        // append the arg
        len = args[arg].getString(buffer, formatSpec, args);
    }

    if (buffer.ptr && len >= 0)
        buffer = buffer.ptr[len .. buffer.length];
    return len;
}



unittest
{
    char[1024] tmp;

    char[] r = format(tmp, "hello");
    assert(r == "hello");

    r = format(tmp, "hello {0}", null);
    assert(r == "hello null");

    r = format(tmp, "{0} {1}", true, false);
    assert(r == "true false");

    r = format(tmp, "{0} {1} {2,04} {3,04} {4,4} {5,+X} {6,+x}", 10, -10, 10, -10, -10, 10, -10);
    assert(r == "10 -10 0010 -010  -10 +A -a");// TODO!!!

    r = format(tmp, "{'?',?0}{'!',!0}", true);
    assert(r == "?");
    r = format(tmp, "{'?',?0}{'!',!0}", false);
    assert(r == "!");

    r = format(tmp, "{0}", cast(void*)0xDEADBEEF);
    static if (size_t.sizeof == 4)
        assert(r == "DEADBEEF");
    else
        assert(r == "00000000DEADBEEF");

    const char *pName = "manu";
    int[3] arr = [ 1, 2, 30 ];
    r = format(tmp, "{1}, {'?',?7}{'!',!7}, {@6} {3}", "hello ", pName, 10, arr, "-*5", 10, "<{0,@4}>", false);
    assert(r == "manu, !, <hello     > [1,2,30]");

    r = format(tmp, "{0}", cast(void[])arr);
    version (LittleEndian)
        assert(r == "01 00 00 00 02 00 00 00 1E 00 00 00");
    else
        assert(r == "00 00 00 01 00 00 00 02 00 00 00 1E");

}



// a template that tests is all template args are a char array, or a char
template allAreStrings(Args...)
{
    static if (Args.length == 1)
        enum allAreStrings = is(Args[0] : const(char[])) || is(isSomeChar!(Args[0]));
    else
        enum allAreStrings = (is(Args[0] : const(char[])) || is(isSomeChar!(Args[0]))) && allAreStrings!(Args[1 .. $]);
}

template allConstCorrectStrings(Args...)
{
    static if (Args.length == 1)
        enum allConstCorrectStrings = is(Args[0] == const(char[])) || is(Args[0] == const char);
    else
        enum allConstCorrectStrings = (is(Args[0] == const(char[])) || is(Args[0] == const char)) && allConstCorrectStrings!(Args[1 .. $]);
}

template constCorrectedStrings(Args...)
{
    import urt.meta : AliasSeq;
    alias constCorrectedStrings = AliasSeq!();
    static foreach (Ty; Args)
    {
        static if (is(Ty : const(char)[]))
            constCorrectedStrings = AliasSeq!(constCorrectedStrings, const(char[]));
        else static if (isSomeChar!Ty)
            constCorrectedStrings = AliasSeq!(constCorrectedStrings, const(char));
        else
            static assert(false, "Argument must be a char array or a char: ", T);
    }
}

template EnumKeyIsDuplicate(Enum, size_t item)
{
    alias Elements = __traits(allMembers, Enum);
    enum Key = __traits(getMember, Enum, Elements[item]);
    alias Exists = void;
    static foreach (i; 0 .. item)
        static if (Key == __traits(getMember, Enum, Elements[i]))
            Exists = int;
    enum EnumKeyIsDuplicate = is(Exists == int);
}
