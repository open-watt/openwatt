module urt.variant;

import urt.array;
import urt.kvp;
import urt.lifetime;
import urt.map;
import urt.si.quantity;
import urt.si.unit : ScaledUnit;
import urt.traits;

nothrow @nogc:


enum ValidUserType(T) = (is(T == struct) || is(T == class)) &&
                        !is(T == Variant) &&
                        !is(T == VariantKVP) &&
                        !is(T == Array!U, U) &&
                        !is(T : const(char)[]) &&
                        !is(T == Quantity!(T, U), T, alias U);


alias VariantKVP = KVP!(const(char)[], Variant);


struct Variant
{
nothrow @nogc:
    this(this) @disable;
    this(ref Variant rh)
    {
        if (rh.type == Type.Map || rh.type == Type.Array)
        {
            Array!Variant arr = rh.nodeArray;
            takeNodeArray(arr);
            flags = rh.flags;
        }
        else
        {
            assert((rh.flags & Flags.NeedDestruction) == 0);
            __pack = rh.__pack;
        }
    }

    version (EnableMoveSemantics) {
    this(Variant rh)
    {
        value.ul = rh.value.ul;
        count = rh.count;
        alloc = rh.alloc;
        flags = rh.flags;

        rh.value.ul = 0;
        rh.count = 0;
        rh.flags = Flags.Null;
    }
    }

    this(typeof(null))
    {
    }

    this(bool b)
    {
        flags = b ? Flags.True : Flags.False;
    }

    this(I)(I i)
        if (is(I == byte) || is(I == short))
    {
        flags = Flags.NumberInt;
        value.l = i;
        if (i >= 0)
            flags |= Flags.UintFlag | Flags.Uint64Flag;
    }
    this(I)(I i)
        if (is(I == ubyte) || is(I == ushort))
    {
        flags = cast(Flags)(Flags.NumberUint | Flags.IntFlag);
        value.ul = i;
    }

    this(int i)
    {
        flags = Flags.NumberInt;
        value.l = i;
        if (i >= 0)
            flags |= Flags.UintFlag | Flags.Uint64Flag;
    }

    this(uint i)
    {
        flags = Flags.NumberUint;
        value.ul = i;
        if (i <= int.max)
            flags |= Flags.IntFlag;
    }

    this(long i)
    {
        flags = Flags.NumberInt64;
        value.l = i;
        if (i >= 0)
        {
            flags |= Flags.Uint64Flag;
            if (i <= int.max)
                flags |= Flags.IntFlag | Flags.UintFlag;
            else if (i <= uint.max)
                flags |= Flags.UintFlag;
        }
        else if (i >= int.min)
            flags |= Flags.IntFlag;
    }

    this(ulong i)
    {
        flags = Flags.NumberUint64;
        value.ul = i;
        if (i <= int.max)
            flags |= Flags.IntFlag | Flags.UintFlag | Flags.Int64Flag;
        else if (i <= uint.max)
            flags |= Flags.UintFlag | Flags.Int64Flag;
        else if (i <= long.max)
            flags |= Flags.Int64Flag;
    }

    this(float f)
    {
        flags = Flags.NumberFloat;
        value.d = f;
    }
    this(double d)
    {
        flags = Flags.NumberDouble;
        value.d = d;
    }

    this(U, ScaledUnit _U)(Quantity!(U, _U) q)
    {
        this(q.value);
        flags |= Flags.IsQuantity;
        count = q.unit.pack;
    }

    this(const(char)[] s) // TODO: (S)(S s)
//        if (is(S : const(char)[]))
    {
        if (s.length < embed.length)
        {
            flags = Flags.ShortString;
            embed[0 .. s.length] = s[];
            embed[$-1] = cast(ubyte)s.length;
            return;
        }
        flags = Flags.String;
        value.s = s.ptr;
        count = cast(uint)s.length;
    }

    this(Variant[] a)
    {
        flags = Flags.Array;
        nodeArray = a[];
    }
    this(T)(T[] a)
        if (!is(T == Variant) && !is(T == VariantKVP) && !is(T : dchar))
    {
        flags = Flags.Array;
        nodeArray.reserve(a.length);
        foreach (ref i; a)
            nodeArray.emplaceBack(i);
    }

    this(Array!Variant a)
    {
        takeNodeArray(a);
        flags = Flags.Array;
    }

    this(VariantKVP[] map...)
    {
        flags = Flags.Map;
        nodeArray.reserve(map.length * 2);
        foreach (ref VariantKVP kvp; map)
        {
            nodeArray.emplaceBack(kvp.key);
            move(kvp.value, nodeArray.pushBack());
        }
    }

    this(K, V)(ref Map!(K, V) map)
    {
        flags = Flags.Map;
        nodeArray.reserve(map.length * 2);
        foreach (ref k, ref v; map)
        {
            nodeArray.emplaceBack(k);
            move(v, nodeArray.pushBack());
        }
    }

    // TODO: should we have a formal ENUM type which can store the key/values?

    this(T)(auto ref T thing)
        if (ValidUserType!T)
    {
        alias dummy = MakeTypeDetails!T;

        flags = Flags.User;
        static if (is(T == class))
        {
            count = UserTypeId!T;
            value.p = cast(void*)&thing;
        }
        else static if (EmbedUserType!T)
        {
            flags |= Flags.Embedded;
            alloc = UserTypeShortId!T;
            emplace(cast(T*)embed.ptr, forward!thing);
        }
        else
        {
//            flags |= Flags.NeedDestruction; // if T has a destructor...
            count = UserTypeId!T;
            assert(false, "TODO: alloc for the object...");
        }
    }

    ~this()
    {
        destroy!false();
    }

    // TODO: since this is a catch-all, the error messages will be a bit shit
    //       maybe we can find a way to constrain it to valid inputs?
    void opAssign(T)(auto ref T value)
    {
        destroy!false();
        emplace(&this, forward!value);
    }

    // TODO: do we want Variant to support +=, ~=, etc...?
    //       or maybe rather, we SHOULDN'T allow variant to support [$]/length()/etc...

    // support indexing for arrays and maps...
    alias opDollar = length;

    ref inout(Variant) opIndex(size_t i) inout pure
    {
        assert(isArray());
        assert(i < count);
        return value.n[i];
    }

    ref const(Variant) opIndex(const(char)[] member) const pure
    {
        const(Variant)* m = getMember(member);
        assert(m !is null);
        return *m;
    }
    ref Variant opIndex(const(char)[] member)
    {
        Variant* m = getMember(member);
        if (m)
            return *m;
        nodeArray.emplaceBack(member);
        return nodeArray.pushBack();
    }

    bool isNull() const pure
        => flags == Flags.Null;
    bool isFalse() const pure
        => flags == Flags.False;
    bool isTrue() const pure
        => flags == Flags.True;
    bool isBool() const pure
        => (flags & Flags.IsBool) != 0;
    bool isNumber() const pure
        => (flags & Flags.IsNumber) != 0;
    bool isInt() const pure
        => (flags & Flags.IntFlag) != 0;
    bool isUint() const pure
        => (flags & Flags.UintFlag) != 0;
    bool isLong() const pure
        => (flags & Flags.Int64Flag) != 0;
    bool isUlong() const pure
        => (flags & Flags.Uint64Flag) != 0;
    bool isFloat() const pure
        => (flags & Flags.FloatFlag) != 0;
    bool isDouble() const pure
        => (flags & Flags.DoubleFlag) != 0;
    bool isQuantity() const pure
        => (flags & Flags.IsQuantity) != 0;
    bool isString() const pure
        => (flags & Flags.IsString) != 0;
    bool isArray() const pure
        => flags == Flags.Array;
    bool isObject() const pure
        => flags == Flags.Map;
    bool isUser(T)() const pure
        if (ValidUserType!T)
    {
        if ((flags & Flags.TypeMask) != Type.User)
            return false;
        static if (EmbedUserType!T)
            return alloc == UserTypeShortId!T;
        else
            return count == UserTypeId!T;
    }


    bool asBool() const pure @property
    {
        assert(isBool());
        return flags == Flags.True;
    }

    int asInt() const pure @property
    {
        assert(isInt());
        return cast(int)value.l;
    }
    uint asUint() const pure @property
    {
        assert(isUint());
        return cast(uint)value.ul;
    }
    long asLong() const pure @property
    {
        assert(isLong());
        return value.l;
    }
    ulong asUlong() const pure @property
    {
        assert(isUlong());
        return value.ul;
    }

    double asDouble() const pure @property
    {
        assert(isNumber());
        if ((flags & Flags.DoubleFlag) != 0)
            return value.d;
        if ((flags & Flags.UintFlag) != 0)
            return cast(double)cast(uint)value.ul;
        if ((flags & Flags.IntFlag) != 0)
            return cast(double)cast(int)cast(long)value.ul;
        if ((flags & Flags.Uint64Flag) != 0)
            return cast(double)value.ul;
        return cast(double)cast(long)value.ul;
    }

    Quantity!T asQuantity(T = double)() const pure @property
    {
        assert(isNumber());

        Quantity!double r;
        static if (is(T == double))
            r.value = asDouble();
//        else static if (is(T == float))
//            r.value = asFloat();
        else static if (is(T == int))
            r.value = asInt();
        else static if (is(T == uint))
            r.value = asUint();
        else static if (is(T == long))
            r.value = asLong();
        else static if (is(T == ulong))
            r.value = asUlong();
        else
            assert(false, "Unsupported quantity type!");
        if (isQuantity())
            r.unit.pack = count;
        return r;
    }

    const(char)[] asString() const pure
    {
        assert(isString());
        if (flags & Flags.Embedded)
            return embed[0 .. embed[$-1]];
        return value.s[0 .. count];
    }

    ref const(Array!Variant) asArray() const pure
    {
        assert(isArray());
        return nodeArray;
    }

    ref Array!Variant asArray() pure
    {
        if (flags == Flags.Null)
            flags = Flags.Array;
        else
            assert(isArray());
        return nodeArray;
    }

    ref inout(T) asUser(T)() inout pure
        if (ValidUserType!T && UserTypeReturnByRef!T)
    {
        if (!isUser!T)
            assert(false, "Variant is not a " ~ T.stringof);
        static assert(!is(T == class), "Should be impossible?");
        static if (EmbedUserType!T)
            return *cast(inout(T)*)embed.ptr;
        else
            return *cast(inout(T)*)ptr;
    }
    inout(T) asUser(T)() inout pure
        if (ValidUserType!T && !UserTypeReturnByRef!T)
    {
        if (!isUser!T)
            assert(false, "Variant is not a " ~ T.stringof);
        static if (is(T == class))
            return cast(inout(T))ptr;
        else static if (EmbedUserType!T)
            static assert(false, "TODO: memcpy to a stack local and return that...");
        else
            static assert(false, "Should be impossible?");
    }

    size_t length() const pure
    {
        if (flags == Flags.Null)
            return 0;
        else if (isString())
            return (flags & Flags.Embedded) ? embed[$-1] : count;
        else if (isArray())
            return count;
        else
            assert(false);
    }

    bool empty() const pure
        => isObject() ? count == 0 : length() == 0;

    inout(Variant)* getMember(const(char)[] member) inout pure
    {
        assert(isObject());
        for (uint i = 0; i < count; i += 2)
        {
            if (value.n[i].asString() == member)
                return value.n + i + 1;
        }
        return null;
    }

    // TODO: this seems to interfere with UFCS a lot...
//    ref inout(Variant) opDispatch(string member)() inout pure
//    {
//        inout(Variant)* m = getMember(member);
//        assert(m !is null);
//        return *m;
//    }

    int opApply(int delegate(const(char)[] k, ref Variant v) @nogc dg)
    {
        assert(isObject());
        int r = 0;
        try
        {
            for (uint i = 0; i < count; i += 2)
            {
                r = dg(value.n[i].asString(), value.n[i + 1]);
                if (r != 0)
                    break;
            }
        }
        catch(Exception e)
        {
            assert(false, "Exception in loop body!");
        }
        return r;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        final switch (type)
        {
            case Variant.Type.Null:
                if (!buffer.ptr)
                    return 4;
                if (buffer.length < 4)
                    return -1;
                buffer[0 .. 4] = "null";
                return 4;

            case Variant.Type.False:
                if (!buffer.ptr)
                    return 5;
                if (buffer.length < 5)
                    return -1;
                buffer[0 .. 5] = "false";
                return 5;

            case Variant.Type.True:
                if (!buffer.ptr)
                    return 4;
                if (buffer.length < 4)
                    return -1;
                buffer[0 .. 4] = "true";
                return 4;

            case Variant.Type.Number:
                import urt.conv;

                if (isQuantity())
                    assert(false, "TODO: implement quantity formatting for JSON");

                if (isDouble())
                    return asDouble().formatFloat(buffer);

                // TODO: parse args?
                //format

                if (flags & Flags.Uint64Flag)
                    return asUlong().formatUint(buffer);
                return asLong().formatInt(buffer);

            case Variant.Type.String:
                const char[] s = asString();
                if (buffer.ptr)
                {
                    // TODO: should we write out quotes?
                    // a string of a number won't be distinguishable from a number without quotes...
                    if (buffer.length < s.length)
                        return -1;
                    buffer[0 .. s.length] = s[];
                }
                return s.length;

            case Variant.Type.Map:
            case Variant.Type.Array:
                import urt.format.json;

                // should we just format this like JSON or something?
                return writeJson(this, buffer);

            case Variant.Type.User:
                if (flags & Flags.Embedded)
                    return findTypeDetails(alloc).stringify(embed.ptr, buffer);
                else
                    return findTypeDetails(count).stringify(ptr, buffer);
        }
    }

package:
    union Value
    {
        long l;
        ulong ul;
        double d;
//        int i;   // maybe implement these if the platform has no native 64bit int support
//        uint u;
//        float f; // if there is no hardware double support, then we should use this...

        const(char)* s;

        struct {
            // HACK: on 32bit, `n` must be placed immediately before `count`
            static if (size_t.sizeof == 4)
                uint __placeholder;
            Variant* n;
        }
    }

    union {
        ulong[2] __pack; // for efficient copying...

        struct {
            union {
                Value value;
                void* ptr;
            }
            uint count;
            ushort alloc;
            Flags flags;
        }

        enum EmbedSize = 14;
        char[EmbedSize] embed; // a buffer for locally embedded data
    }

    Type type() const pure
        => cast(Type)(flags & Flags.TypeMask);

    ref inout(Array!Variant) nodeArray() @property inout pure
        => *cast(inout(Array!Variant)*)&value.n;
    void takeNodeArray(ref Array!Variant arr)
    {
        value.n = arr[].ptr;
        count = cast(uint)arr.length;
        emplace(&arr);
    }

    void destroy(bool reset = true)()
    {
        if (flags & Flags.NeedDestruction)
            doDestroy();

        static if (reset)
            __pack[] = 0;
    }

    private void doDestroy()
    {
        Type t = type();
        if ((t == Type.Map || t == Type.Array) && value.n)
            nodeArray.destroy!false();
        else if (t == Type.User)
        {
            if (flags & Flags.Embedded)
                findTypeDetails(alloc).destroy(embed.ptr);
            else
                findTypeDetails(count).destroy(ptr);
        }
    }

    enum Type : ushort
    {
        Null        = 0,
        False       = 1,
        True        = 2,
        Number      = 3,
        String      = 4,
        Array       = 5,
        Map         = 6,
        User        = 7
    }

    enum Flags : ushort
    {
        Null            = cast(Flags)Type.Null,
        False           = cast(Flags)Type.False  | Flags.IsBool,
        True            = cast(Flags)Type.True   | Flags.IsBool,
        NumberInt       = cast(Flags)Type.Number | Flags.IsNumber | Flags.IntFlag  | Flags.Int64Flag,
        NumberUint      = cast(Flags)Type.Number | Flags.IsNumber | Flags.UintFlag | Flags.Uint64Flag | Flags.Int64Flag,
        NumberInt64     = cast(Flags)Type.Number | Flags.IsNumber | Flags.Int64Flag,
        NumberUint64    = cast(Flags)Type.Number | Flags.IsNumber | Flags.Uint64Flag,
        NumberFloat     = cast(Flags)Type.Number | Flags.IsNumber | Flags.FloatFlag | Flags.DoubleFlag,
        NumberDouble    = cast(Flags)Type.Number | Flags.IsNumber | Flags.DoubleFlag,
        String          = cast(Flags)Type.String | Flags.IsString,
        ShortString     = cast(Flags)Type.String | Flags.IsString | Flags.Embedded,
        Array           = cast(Flags)Type.Array | Flags.NeedDestruction,
        Map             = cast(Flags)Type.Map | Flags.NeedDestruction,
        User            = cast(Flags)Type.User,

        IsBool          = 1 << (TypeBits + 0),
        IsNumber        = 1 << (TypeBits + 1),
        IsString        = 1 << (TypeBits + 2),
        IntFlag         = 1 << (TypeBits + 3),
        UintFlag        = 1 << (TypeBits + 4),
        Int64Flag       = 1 << (TypeBits + 5),
        Uint64Flag      = 1 << (TypeBits + 6),
        FloatFlag       = 1 << (TypeBits + 7),
        DoubleFlag      = 1 << (TypeBits + 8),
        IsQuantity      = 1 << (TypeBits + 9),
        Embedded        = 1 << (TypeBits + 10),
        NeedDestruction = 1 << (TypeBits + 11),
//        CopyFlag        = 1 << (TypeBits + 12), // maybe we want to know if a thing is a copy, or a reference to an external one?

        TypeMask        = (1 << TypeBits) - 1,
        TypeBits        = 3
    }
}

unittest
{
    import urt.inet;
    import urt.si.quantity : Metres;

    // fabricate some variants
    Variant v;
    v.asArray ~= Variant(42);
    v.asArray ~= Variant(101.1);
    v.asArray ~= Variant(VariantKVP("wow", Variant(true)), VariantKVP("bogus", Variant(false)));
    v.asArray ~= Variant(IPAddrLit!"127.0.0.1");
    v.asArray ~= Variant(Metres(10));

    assert(v.length == 5);
    assert(v[0].asInt == 42);
    assert(v[1].asDouble == 101.1);
    assert(v[2]["wow"].isTrue);
    assert(v[2]["bogus"].asBool == false);
    assert(v[3].asUser!IPAddr == IPAddrLit!"127.0.0.1");
    assert(v[4].asQuantity == Metres(10));
}


private:

import urt.hash : fnv1aHash;

static assert(Variant.sizeof == 16);
static assert(Variant.Type.max <= Variant.Flags.TypeMask);

enum uint UserTypeId(T) = fnv1aHash(cast(const(ubyte)[])T.stringof); // maybe this isn't a good enough hash?
enum uint UserTypeShortId(T) = cast(ushort)UserTypeId!T ^ (UserTypeId!T >> 16);
enum bool EmbedUserType(T) = is(T == struct) && T.sizeof <= Variant.embed.sizeof - 2 && T.alignof <= Variant.alignof;
enum bool UserTypeReturnByRef(T) = is(T == struct);

ptrdiff_t newline(char[] buffer, ref ptrdiff_t offset, int level)
{
    if (offset + level >= buffer.length)
        return false;
    buffer[offset++] = '\n';
    buffer[offset .. offset + level] = ' ';
    offset += level;
    return true;
}

template MakeTypeDetails(T)
{
    // this is a hack which populates an array of user type details when the program starts
    // TODO: we can probably NOT do this for class types, and just use RTTI instead...
    shared static this()
    {
        assert(numTypeDetails < typeDetails.length, "Too many user types!");

        TypeDetails* ty = &typeDetails[numTypeDetails++];
        static if (EmbedUserType!T)
            ty.typeId = UserTypeShortId!T;
        else
            ty.typeId = UserTypeId!T;
        // TODO: I'd like to not generate a destroy function if the data is POD
        ty.destroy = (void* val) {
            static if (!is(T == class))
                destroy!false(*cast(T*)val);
        };
        ty.stringify = (const void* val, char[] buffer) {
            import urt.string.format : toString;
            return toString(*cast(T*)val, buffer);
        };
    }

    alias MakeTypeDetails = void;
}

struct TypeDetails
{
    uint typeId;
    void function(void* val) nothrow @nogc destroy;
    ptrdiff_t function(const void* val, char[] buffer) nothrow @nogc stringify;
}
TypeDetails[8] typeDetails;
size_t numTypeDetails = 0;

ref TypeDetails findTypeDetails(uint typeId)
{
    foreach (i, ref td; typeDetails[0 .. numTypeDetails])
    {
        if (td.typeId == typeId)
            return td;
    }
    assert(false, "TypeDetails not found!");
}
