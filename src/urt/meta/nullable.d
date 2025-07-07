module urt.meta.nullable;

import urt.string.format : formatValue, FormatArg;
import urt.traits;


template Nullable(T)
    if (is(T == class) || is(T == U[], U) || is(T == U*, U))
{
    struct Nullable
    {
        enum T NullValue = null;
        T value = NullValue;

        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is NullValue;

        bool opEquals(typeof(null)) const
            => value is null;
        bool opEquals(T v) const
            => value == v;

        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is null)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (isBoolean!T)
{
    struct Nullable
    {
        enum ubyte NullValue = 0xFF;
        private ubyte _value = NullValue;

        this(typeof(null))
        {
            _value = NullValue;
        }
        this(T v)
        {
            _value = v;
        }

        bool value() const
            => _value == 1;

        bool opCast(T : bool)() const
            => _value != NullValue;

        bool opEquals(typeof(null)) const
            => _value == NullValue;
        bool opEquals(T v) const
            => _value == cast(ubyte)v;

        void opAssign(typeof(null))
        {
            _value = NullValue;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != NullValue);
            _value = cast(ubyte)v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == NullValue)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (isSomeInt!T)
{
    struct Nullable
    {
        enum T NullValue = isSignedInt!T ? T.min : T.max;
        T value = NullValue;

        this(typeof(null))
        {
            value = NullValue;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value != NullValue;

        bool opEquals(typeof(null)) const
            => value == NullValue;
        bool opEquals(T v) const
            => value != NullValue && value == v;

        void opAssign(typeof(null))
        {
            value = NullValue;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != NullValue);
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == NullValue)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (isSomeFloat!T)
{
    struct Nullable
    {
        enum T NullValue = T.nan;
        T value = NullValue;

        this(typeof(null))
        {
            value = NullValue;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is NullValue;

        bool opEquals(typeof(null)) const
            => value is NullValue;
        bool opEquals(T v) const
            => value == v; // because nan doesn't compare with anything

        void opAssign(typeof(null))
        {
            value = NullValue;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is NullValue)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == struct))
{
    import urt.lifetime : moveEmplace;

    struct Nullable
    {
        T value = void;
        bool isValue = false;

        this(typeof(null))
        {
            isValue = false;
        }
        this(T v)
        {
            moveEmplace(v, value);
            isValue = true;
        }

        ~this()
        {
            if (isValue)
                value.destroy();
        }

        bool opCast(T : bool)() const
            => isValue;

        bool opEquals(typeof(null)) const
            => !isValue;
        bool opEquals(T v) const
            => isValue && value == v;

        void opAssign(typeof(null))
        {
            if (isValue)
                value.destroy();
            isValue = false;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            if (!isValue)
                moveEmplace(v, value);
            else
                value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!isValue)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == enum))
{
    struct Nullable
    {
        T value;
        bool isValue;

        this(typeof(null))
        {
            isValue = false;
        }
        this(T v)
        {
            value = v;
            isValue = true;
        }

        bool opCast(T : bool)() const
            => isValue;

        bool opEquals(typeof(null)) const
            => !isValue;
        bool opEquals(T v) const
            => isValue && value == v;

        void opAssign(typeof(null))
        {
            isValue = false;
        }
        void opAssign(T v)
        {
            value = v;
            isValue = true;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!isValue)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}
