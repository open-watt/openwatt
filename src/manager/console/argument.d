module manager.console.argument;

import urt.array;
import urt.mem;
import urt.mem.temp;
import urt.meta;
import urt.meta.nullable;
import urt.si.quantity;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time : Duration;
import urt.traits;
import urt.variant;

import manager;
import manager.collection;

// these are used by the conversion functions...
import manager.base : BaseObject;
import manager.component : Component;
import manager.device : Device;
import router.iface;
import router.stream;

nothrow @nogc:


// argument conversion functions...
// TODO: THESE NEED ADL STYLE LOOKUP!

const(char[]) convertVariant(ref const Variant v, out typeof(null) r) nothrow @nogc
{
    if (!v.isNull)
        return "Not null";
    r = null;
    return null;
}

const(char[]) convertVariant(ref const Variant v, out bool r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(ref const Variant v, out Duration r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(ref const Variant v, out String r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(U)(ref const Variant v, out U[] r) nothrow @nogc
    if (!is_some_char!U)
{
    static if (is(U == const V, V))
    {
        V[] tmp;
        const(char[]) err = v.convertVariant(tmp);
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
            if (const(char[]) error = convertVariant(e, r[i]))
                return error;
        }
        return null;
    }
}

const(char[]) convertVariant(U, size_t N)(ref const Variant v, out U[N] r) nothrow @nogc
    if (!is(U : dchar))
{
    U[] tmp;
    const(char)[] err = convertVariant!(U[])(v, tmp);
    if (err)
        return err;
    if (tmp.length != N)
        return "Array length mismatch";
    r = tmp[0..N];
    return null;
}

const(char[]) convertVariant(T : Nullable!U, U)(ref const Variant v, out T r) nothrow @nogc
{
    U tmp;
    const(char[]) error = convertVariant(v, tmp);
    if (!error)
        r = tmp.move;
    return error;
}

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r) nothrow @nogc
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

const(char[]) convertVariant(ref const Variant v, out Component r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid component value";
    const(char)[] s = v.asString;
    r = g_app.find_component(s);
    return r ? null : tconcat("No component '", s, '\'');
}

const(char[]) convertVariant(ref const Variant v, out Device r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid device value";
    const(char)[] s = v.asString;
    r = g_app.find_device(s);
    return r ? null : tconcat("No device '", s, '\'');
}

const(char[]) convertVariant(I)(ref const Variant v, out I r) nothrow @nogc
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
                return tconcat("Requires ", I.TypeName, " interface, but ", i.name[], " is ", i.type[]);
    }
    return r ? null : tconcat("Interface does not exist: ", n);
}

const(char[]) convertVariant(S)(ref const Variant v, out S r) nothrow @nogc
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
                return tconcat("Requires ", S.TypeName, " stream, but ", n, " is ", stream.type[]);
    }
    return r ? null : tconcat("Stream does not exist: ", n);
}


// argument completions...
// TODO: THESE NEED ADL STYLE LOOKUP!

Array!String suggestCompletion(T : typeof(null))(const(char)[] argumentText)
{
    if (StringLit!"null".startsWith(argumentText))
        return Array!String(Concat, StringLit!"null");
    return Array!String();
}

Array!String suggestCompletion(T : bool)(const(char)[] argumentText)
{
    __gshared const String[4] vals = [ StringLit!"true", StringLit!"false", StringLit!"yes", StringLit!"no" ];
    Array!String completions;
    foreach (ref s; vals)
    {
        if (s.startsWith(argumentText))
            completions ~= s;
    }
    return completions;
}

Array!String suggestCompletion(E)(const(char)[] argumentText)
    if (is(E == enum))
{
    Array!String completions;
    static foreach(M; __traits(allMembers, E))
    {{
        enum Member = Alias!(M.to_lower);
        if (Member.startsWith(argumentText))
            completions ~= StringLit!Member;
    }}
    return completions;
}

Array!String suggestCompletion(T : const Component)(const(char)[] argumentText)
    if(!is(T == typeof(null)))
{
    Array!String devices;
    size_t dot = argumentText.findFirst('.');
    if (dot == argumentText.length)
    {
        devices = suggestCompletion!Device(argumentText);
        if (devices.length == 1)
        {
            dot = devices[0].length;
            argumentText = devices[0];
        }
        else
            return devices;
    }
    Device* dev = argumentText[0 .. dot] in g_app.devices;
    if (!dev)
        return Array!String();
    Component cmp = *dev;
    auto prefix = MutableString!0(Concat, cmp.id, '.');
    if (devices.length == 1)
        argumentText = prefix[];

    find_inner: while (true)
    {
        argumentText = argumentText[dot + 1 .. $];
        dot = argumentText.findFirst('.');
        if (dot == argumentText.length)
            break;

        foreach (c; cmp.components)
        {
            if (c.id == argumentText[0 .. dot])
            {
                prefix.append(c.id, '.');
                cmp = c;
                continue find_inner;
            }
        }
        return Array!String();
    }

    Array!String completions;
    size_t cid;
    foreach (i, c; cmp.components)
    {
        if (c.id.startsWith(argumentText))
        {
            cid = i;
            completions ~= String(MutableString!0(Concat, prefix, c.id)); // TODO: MOVE construct!
        }
    }
    if (completions.length == 1)
    {
        cmp = cmp.components[cid];
        foreach (i, c; cmp.components)
            completions ~= String(MutableString!0(Concat, completions[0], '.', c.id)); // TODO: MOVE construct!
    }
    return completions;
}

Array!String suggestCompletion(T : const Device)(const(char)[] argumentText)
    if(!is(T == typeof(null)))
{
    Array!String completions;
    foreach (name; g_app.devices.keys)
    {
        if (name.startsWith(argumentText))
            completions ~= name.makeString(defaultAllocator);
    }
    return completions;
}

Array!String suggestCompletion(I)(const(char)[] argumentText)
    if (!is(I == typeof(null)) && is(const I == const BaseInterface))
{
    Array!String completions;
    foreach (ref name; get_module!InterfaceModule.interfaces.keys)
    {
        if (name.startsWith(argumentText))
            completions ~= name;
    }
    return completions;
}

Array!String suggestCompletion(S)(const(char)[] argumentText)
    if (!is(S == typeof(null)) && is(const S == const Stream))
{
    Array!String completions;
    foreach (ref name; get_module!StreamModule.streams.keys)
    {
        if (name.startsWith(argumentText))
            completions ~= name;
    }
    return completions;
}

Array!String suggestCompletion(T)(const(char)[] argumentText)
    if (!is(T == typeof(null)) && is(T : const BaseObject) && !is(const T == const BaseInterface) && !is(const T == const Stream))
{
    alias Type = Unqual!T;
    const collection = collection_for!Type();
    if (collection is null)
        return Array!String();

    Array!String completions;
    foreach (ref name; collection.keys)
    {
        if (name.startsWith(argumentText))
            completions ~= name;
    }
    return completions;
}
