module manager.value;

import urt.mem.allocator;

version (_64Bit)
    version = LocalLong;

nothrow @nogc:


// use this allocator for all value related memory allocation (except strings, which use normal string allocation techniques)
NoGCAllocator valueAllocator()
{
    return defaultAllocator();
}


struct Value
{
nothrow @nogc:

    enum Type : ubyte
    {
        Void,
        Null,
        Bool,
        Integer,
        Float,

        PackedEnum,
        PackedBitfield,

        AllocatedTypes,

        Long,
        Double,
        Duration,

        String = AllocatedTypes,
        Time,
        Binary,
        Custom,

        // enum/bitfield? carry metadata?

        // element-ref? (just a string?)

        // special stuff
        // MAC address, IP4, IP6, netmask, 
    }

    this(ref typeof(this) rhs)
    {
        // copy the memory...
    }

    this(typeof(null))
    {
        type = Type.Null;
        this.p = null;
    }
    this(float f)
    {
        type = Type.Float;
        this.f = f;
    }
    this(int i)
    {
        type = Type.Integer;
        this.i = cast(uint)i;
    }
    this(bool b)
    {
        type = Type.Bool;
        this.i = b ? 1 : 0;
    }
    this(const(char)[] s)
    {
        debug assert(s.length <= 0x0FFFFFFF);
        type = Type.String;
        this.length = cast(uint)s.length;
        this.p = cast(void*)s.ptr;
    }
    this(float[] arr)
    {
        debug assert(arr.length <= 0x0FFFFFFF);
        type = Type.Float;
        this.length = cast(uint)arr.length;
        this.p = cast(void*)arr.ptr;
    }
    this(int[] arr)
    {
        debug assert(arr.length <= 0x0FFFFFFF);
        type = Type.Integer;
        this.length = cast(uint)arr.length;
        this.p = cast(void*)arr.ptr;
    }

    ref Value opAssign(T)(auto ref T val)
    {
        import urt.lifetime;
        this.destroy();
        emplace(&this, forward!val);
        return this;
    }

    Type type() const
        => cast(Type)(len_ty >> 28);

    bool isString() const => type == Type.String;

    size_t length() const
        => len_ty & 0x0FFFFFFF;

    bool getBool() const
        => i != 0;
    int getInt() const
        => cast(int)i;
    float getFloat() const
        => f;
    const(char)[] getString() const
        => (cast(const(char)*)p)[0..length];
    bool[] getBoolArray() const
        => (cast(bool*)p)[0..length];
    int[] getIntArray() const
        => (cast(int*)p)[0..length];
    float[] getFloatArray() const
        => (cast(float*)p)[0..length];

    float asFloat() const
    {
        switch (type)
        {
            case Type.Float:
                return f;
            case Type.Integer:
                return cast(float)i;
            case Type.String:
            {
                import urt.conv : parseFloat;

                const(char)[] s = getString();
                size_t len;
                double v = parseFloat(s, &len);
                if (len == s.length)
                    return v;
                return 0;
            }
            default:
                return 0;
        }
    }

    // should probably use this instead of those above...
    T get(T)() const
    {
        static if (is(T == bool))
            return i != 0;
        else static if (is(T == int))
            return cast(int)i;
        else static if (is(T == float))
            return f;
        else static if (is(T == const(char)[]))
            return (cast(const(char)*)p)[0..length];
        else
            static assert(false, "TODO: not implemented");
    }

    import urt.string.format;
    ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const
    {
        switch (type)
        {
            case Type.Void:
            case Type.Null:
                return 0;
            case Type.Bool:
                return format(buffer, "{0,@1}", getBool(), fmt).length;
            case Type.Integer:
                if (length)
                    return format(buffer, "{0,@1}", getIntArray(), fmt).length;
                else
                    return format(buffer, "{0,@1}", getInt(), fmt).length;
            case Type.Float:
                if (length)
                    return format(buffer, "{0,@1}", getFloatArray(), fmt).length;
                else
                    return format(buffer, "{0,@1}", getFloat(), fmt).length;
            case Type.String:
                return format(buffer, "{0,@1}", getString(), fmt).length;
            default:
                assert(false);
        }
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        if (s.length == 0)
        {
            len_ty = Type.Null;
            p = null;
            return 0;
        }
        bool isQuotes = false;
        if (s[0] == '"' || s[0] == '\"' || s[0] == '`')
            isQuotes = true;
        else
        {
            // try and handle non-string cases

            // maybe bool?

            // maybe float?

            // maybe int?

            //...
        }

        import urt.mem.allocator;
        import urt.string;

        // accept it as a string...
        debug assert(s.length <= 0x0FFFFFFF);

        // TODO: Value's don't own their memory, but they should...
        //       for now, we just dup and leak!
        char[] mem = cast(char[])defaultAllocator.alloc(s.length);
        if (isQuotes)
            mem = s.unQuote(mem);
        else
            mem[] = s[];

        type = Type.String;
        length = cast(uint)mem.length;
        p = cast(void*)mem.ptr;

        return s.length;
    }

private:
    uint len_ty = 0;
    union
    {
        void* p = null;
        int i;
        float f;
    }

    void type(Type ty)
    {
        len_ty = (len_ty & 0x0FFFFFFF) | (cast(uint)ty << 28);
    }
    void length(size_t len)
    {
        debug assert(len <= 0x0FFFFFFF);
        len_ty = (len & 0x0FFFFFFF) | (len_ty & 0xF0000000);
    }
}
