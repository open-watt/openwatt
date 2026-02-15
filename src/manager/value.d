module manager.value;

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.mem;
import urt.mem.temp;
import urt.meta;
import urt.meta.nullable;
import urt.si.unit : ScaledUnit;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.traits;
import urt.variant;

import router.iface;
import router.iface.mac;
import router.stream;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


template struct_name_override(T)
{
    static if (is(U == IPAddr))
        enum struct_name_override = "ipv4";
    else static if (is(U == IPv6Addr))
        enum struct_name_override = "ipv6";
    else static if (is(U == IPNetworkAddress))
        enum struct_name_override = "ipv4netwk";
    else static if (is(U == IPv6NetworkAddress))
        enum struct_name_override = "ipv6netwk";
    else static if (is(U == InetAddress))
        enum struct_name_override = "inetaddr";
    else static if (is(U == MACAddress))
        enum struct_name_override = "mac";
    else static if (is(U == EUI64))
        enum struct_name_override = "eui";
    else static if (is(U == DateTime) || is(U == SysTime))
        enum struct_name_override = "dt";
    else
        enum struct_name_override = T.stringof;
}

template type_for(T, Extra...)
{
    private alias U = Unqual!T;
    static if (is(U == Array!V, V))
    {
        static assert(is(V == Unqual!V), "TODO: what case is this qualified?");
        enum type_for = type_for!V ~ "[]";
    }
    else static if (is(U == V[N], V, size_t N))
    {
        static assert(is(V == Unqual!V), "TODO: what case is this qualified?");
        enum type_for = type_for!V ~ "[" ~ N.stringof ~ "]";
    }
    else static if (is_enum!U)
    {
        // Extra[0]: bool is_bitfield
        static if (Extra.length == 1 && is(typeof(Extra[0]) == bool) && Extra[0])
            enum type_for = "bf_" ~ U.stringof;
        else
            enum type_for = "enum_" ~ U.stringof;
    }
    else static if (is_boolean!U)
        enum type_for = "bool";
    else static if (is(U == ubyte))
        enum type_for = "byte";
    else static if (is_unsigned_int!U)
        enum type_for = "uint";
    else static if (is_signed_int!U)
        enum type_for = "int";
    else static if (is_some_float!U)
        enum type_for = "num";
    else static if (is(U == Quantity!(V, unit), V, ScaledUnit unit))
    {
        enum string unit_str = unit.toString();
        enum type_for = "q_" ~ unit_str;
    }
    else static if (is(U : const(char)[]) || is(U == String))
        enum type_for = "str";
    else static if (is(U : Component))
        enum type_for = "com";
    else static if (is(U : Element))
        enum type_for = "elem";
    else static if (is(U == BaseInterface))
        enum type_for = "#iface";
    else static if (is(U == Stream))
        enum type_for = "#stream";
    else static if (is(U : BaseObject))
        enum type_for = "#" ~ U.type_name;
    else static if (is(U == struct))
        enum type_for = struct_name_override!U;
    else
        enum type_for = null; // not supported
}


ref Variant to_variant(ref Variant v) nothrow @nogc
    => v;

Variant to_variant(Variant v) nothrow @nogc
    => v.move;

// this catches a lot of things with Variant's constructor
Variant to_variant(T)(T v) nothrow @nogc
    if (is(Unqual!T == typeof(null)) || is_boolean!T || is_some_int!T || is_some_float!T || is_enum!T ||
        is(T : const(char)[]) || is(Unqual!T == Duration) || is(Unqual!T == Quantity!(U, u), U, alias u))
    => Variant(v);

Variant to_variant(String s) nothrow @nogc
    => Variant(s.move);

Variant to_variant(T)(T[] arr) nothrow @nogc
    if (!is(T[] : const(char)[]))
{
    auto va = Array!Variant(Reserve, arr.length);
    foreach (ref v; arr)
        va ~= to_variant(v);
    return Variant(va.move);
}

Variant to_variant(T)(Array!T arr) nothrow @nogc
{
    static if (is(T == Variant))
        return Variant(arr.move);
    else
        return to_variant(arr[], r);
}

Variant to_variant(T)(ref ObjectRef!T v) nothrow @nogc
{
    // TODO: should we put items directly into variants?
//    if (v.detached)
        return Variant(v.name[]);
//    else
//        return Variant(v.get);
}

Variant to_variant(Stream stream) nothrow @nogc
{
    // TODO: remove this case and allow base collection type to cover it?
    return Variant(stream.name[]);
}

Variant to_variant(BaseInterface iface) nothrow @nogc
{
    // TODO: remove this case and allow base collection type to cover it?
    return Variant(iface.name[]);
}

Variant to_variant(T)(T v) nothrow @nogc
    if (is(T : const BaseObject) && !is(T : const BaseInterface) && !is(T : const Stream))
{
    // we would like to store collection types in variant, but we need a few things
    // 1. variant typeinfo needs to know the hierarchy for asUser!BaseType
    // 2. it must be stored as an ObjectRef!T, because if it's in a variant and the item is destroyed, the variant needs to be corrected!
    return Variant(v.name[]);
}

Variant to_variant(T)(auto ref T v) nothrow @nogc
    if (is(T == struct) && ValidUserType!(Unqual!T))
    => Variant(forward!v);

Variant to_variant(T)(ref T v) nothrow @nogc
    if (is(T == class) && ValidUserType!(Unqual!T) && !is(T : const BaseObject))
    => Variant(v);


// argument conversion functions...
// TODO: THESE NEED ADL STYLE LOOKUP!

const(char[]) from_variant(ref const Variant v, out typeof(null) r) nothrow @nogc
{
    if (!v.isNull)
        return "Not null";
    r = null;
    return null;
}

const(char[]) from_variant(ref const Variant v, out bool r) nothrow @nogc
{
    if (v.isBool)
        r = v.asBool;
    else if (v.isNumber)
    {
        // TODO: confirm; do we even want this implicit conversion?
        if (v.isDouble)
            r = v.asDouble != 0.0;
        else if (v.isLong)
            r = v.asLong != 0;
        else
            r = v.asUlong != 0;
    }
    else if (v.isString)
    {
        const(char)[] s = v.asString;
        if (s == "true" || s == "yes")
            r = true;
        else if (s == "false" || s == "no")
            r = false;
        else
            return "Invalid boolean value";
    }
    else
        return "Invalid boolean value";
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (is_some_int!T)
{
    if (v.isNumber)
    {
        if (v.isDouble)
        {
            double d = v.asDouble;
            r = cast(T)d;
            if (r != d)
                return "Not an integer value";
        }
        else if (v.isLong)
        {
            long l = v.asLong;
            if (l > T.max || l < T.min)
                return "Integer value out of range";
            r = cast(T)l;
        }
        else
        {
            long u = v.asUlong;
            if (u > T.max)
                return "Integer value out of range";
            r = cast(T)u;
        }
    }
    else if (v.isString)
    {
        import urt.conv : parse_int, parse_uint;

        const(char)[] s = v.asString;
        int base = 10;
        if (s.length > 2 && s[0..2] == "0x")
        {
            base = 16;
            s = s[2 .. $];
        }
        if (s.length > 2 && s[0..2] == "0b")
        {
            base = 2;
            s = s[2 .. $];
        }
        size_t taken;
        long i = base != 10 ? cast(long)s.parse_uint(&taken, base) : s.parse_int(&taken);
        if (taken != s.length)
            return "Invalid integer value";
        if ((long.max > T.max && i > T.max) || (long.min < T.min && i < T.min))
            return "Integer value out of range";
        r = cast(T)i;
    }
    else
        return "Invalid integer value";
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (is_some_float!T)
{
    if (v.isNumber)
    {
        if (v.isDouble)
            r = cast(T)v.asDouble;
        else if (v.isLong)
            r = cast(T)v.asLong;
        else
            r = cast(T)v.asUlong;
    }
    else if (v.isString)
    {
        import urt.conv : parse_float;

        const(char)[] s = v.asString;
        size_t taken;
        r = cast(T)s.parse_float(&taken);
        if (taken != s.length)
            return "Invalid float value";
    }
    else
        return "Invalid float value";
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
{
    static if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
    {
        if (v.isQuantity)
        {
            VarQuantity q = v.asQuantity;
            if (!q.isCompatible(r))
                return "Incompatible units";
            r = cast(T)q;
        }
        else if (v.isNumber)
        {
            // TODO: should we actually accept raw numbers? it could be awkward for scripts not to, but for cli, maybe?
            r = T(v.as!U);
        }
        else if (v.isString)
        {
            const(char)[] s = v.asString;
            ptrdiff_t taken = r.fromString(s);
            if (taken != s.length)
                return tconcat("Couldn't parse \"", s, "\" as quantity");
        }
        else
            return "Invalid quantity value";
        return null;
    }
}

const(char[]) from_variant(ref const Variant v, out Duration r) nothrow @nogc
{
    if (v.isDuration)
        r = v.asDuration;
    else if (v.isString)
    {
        const(char)[] s = v.asString;
        ptrdiff_t taken = r.fromString(s);
        if (taken != s.length)
            return "Invalid duration value";
    }
    else
        return "Invalid duration value";
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (is(const(char)[] : T))
{
    if (v.isString)
        r = v.asString;
    else
    {
        // TODO: expand this and catch possible error cases...
        r = v.tstring();
    }
    return null;
}

const(char[]) from_variant(ref const Variant v, out String r) nothrow @nogc
{
    if (v.isString)
        r = v.asString.makeString(defaultAllocator);
    else
    {
        // TODO: expand this and catch possible error cases...
        r = v.tstring().makeString(defaultAllocator);
    }
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (is(T U == enum))
{
    // TODO: variant may be an enum...
//    if (v.isUser!T)
//        r = v.asUser!T;
//    else if (v.isString)
    if (v.isString)
    {
        // try and parse a key from the string...
        const(char)[] s = v.asString;
        if (!s)
            return "No value";
        switch (s)
        {
            static foreach(E; __traits(allMembers, T))
            {
                case Alias!(to_lower(E)):
                    r = __traits(getMember, T, E);
                    return null;
            }
            default:
                break;
        }
    }

    // else parse the base type?
    // TODO: could be a non-key... do we want to allow this?

    return "Invalid value";
}

const(char[]) from_variant(U)(ref const Variant v, out Array!U r) nothrow @nogc
{
    const(Variant)[] arr;
    if (v.isArray)
        arr = v.asArray()[];
    else
        arr = (&v)[0..1];

    r.reserve(arr.length);
    foreach (i, ref e; arr)
    {
        if (const(char[]) error = from_variant(e, r.pushBack()))
            return error;
    }
    return null;
}

const(char[]) from_variant(U)(ref const Variant v, out U[] r) nothrow @nogc
    if (!is_some_char!U)
{
    static if (is(U == const V, V))
    {
        V[] tmp;
        const(char[]) err = v.from_variant(tmp);
        r = tmp;
        return err;
    }
    else
    {
        const(Variant)[] arr;
        if (v.isArray)
            arr = v.asArray()[];
        else
            arr = (&v)[0..1];

        r = tempAllocator().allocArray!U(arr.length);
        foreach (i, ref e; arr)
        {
            if (const(char[]) error = from_variant(e, r[i]))
                return error;
        }
        return null;
    }
}

const(char[]) from_variant(U, size_t N)(ref const Variant v, out U[N] r) nothrow @nogc
    if (!is(U : dchar))
{
    U[] tmp;
    const(char)[] err = from_variant!(U[])(v, tmp);
    if (err)
        return err;
    if (tmp.length != N)
        return "Array length mismatch";
    r = tmp[0..N];
    return null;
}

const(char[]) from_variant(T : Nullable!U, U)(ref const Variant v, out T r) nothrow @nogc
{
    U tmp;
    const(char[]) error = from_variant(v, tmp);
    if (!error)
        r = tmp.move;
    return error;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (ValidUserType!(Unqual!T) && !is(T : const BaseObject))
{
    alias Type = Unqual!T;

    if (v.isUser!Type)
    {
        static if (is(T == class) && !is(T == const Type))
        {
            assert(false, "TODO: can we get a mutable reference to this class from a const Variant?");
//            r = v.asUser!T;
        }
        else
            r = v.asUser!T;
    }
    else if (v.isString)
    {
        const(char)[] s;
        static if (__traits(compiles, { r.fromString(s); }))
        {
            s = v.asString;
            return r.fromString(s) == s.length ? null : tconcat("Couldn't parse `" ~ Type.stringof ~ "` from string: ", v);
        }
        else
            return Type.stringof ~ " must implement fromString";
    }
    else
        return "Invalid value";
    return null;
}

const(char[]) from_variant(T)(ref const Variant v, out T r) nothrow @nogc
    if (ValidUserType!(Unqual!T) && is(T : const BaseObject) && !is(T : const BaseInterface) && !is(T : const Stream))
{
    const(char)[] n;
    if (v.isUser!T)
        n = v.asUser!T.name;
    else if (v.isString)
        n = v.asString;
    else
        return "Invalid value";

    alias Type = Unqual!T;
    Collection!Type* collection = collection_for!Type();
    assert(collection !is null, "No collection for " ~ Type.stringof);

    T* item = collection.exists(n);
    if (item is null)
        return tconcat("Item does not exist: ", n);
    r = *item;
    return null;
}

const(char[]) from_variant(ref const Variant v, out Component r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid component value";
    const(char)[] s = v.asString;
    r = g_app.find_component(s);
    return r ? null : tconcat("No component '", s, '\'');
}

const(char[]) from_variant(ref const Variant v, out Device r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid device value";
    const(char)[] s = v.asString;
    r = g_app.find_device(s);
    return r ? null : tconcat("No device '", s, '\'');
}

const(char[]) from_variant(I)(ref const Variant v, out I r) nothrow @nogc
    if (is(I : const BaseInterface))
{
    // TODO: parse as mac address...?
    const(char)[] n;
    if (v.isUser!BaseInterface)
        n = v.asUser!BaseInterface.name;
    else if (v.isString)
        n = v.asString;
    else
        return "Invalid interface value";
    if (BaseInterface i = get_module!InterfaceModule.interfaces.get(n))
    {
        r = cast(I)i;
        static if (!is(Unqual!I == BaseInterface))
            if (!r)
                return tconcat("Requires " ~ I.type_name ~ " interface, but ", i.name[], " is ", i.type[]);
    }
    return r ? null : tconcat("Interface does not exist: ", n);
}

const(char[]) from_variant(S)(ref const Variant v, out S r) nothrow @nogc
    if (is(S : const Stream))
{
    const(char)[] n;
    if (v.isUser!Stream)
        n = v.asUser!Stream.name;
    else if (v.isString)
        n = v.asString;
    else
        return "Invalid stream value";
    if (Stream stream = get_module!StreamModule.streams.get(n))
    {
        r = cast(S)stream;
        static if (!is(Unqual!S == Stream))
            if (!r)
                return tconcat("Requires " ~ S.type_name ~ " stream, but ", n, " is ", stream.type[]);
    }
    return r ? null : tconcat("Stream does not exist: ", n);
}
