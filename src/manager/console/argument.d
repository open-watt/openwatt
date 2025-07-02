module manager.console.argument;

import urt.array;
import urt.mem;
import urt.mem.temp;
import urt.meta;
import urt.meta.nullable;
import urt.string;
import urt.traits;
import urt.variant;

import manager;

// these are used by the conversion functions...
import manager.base : BaseObject;
import manager.component : Component;
import manager.device : Device;
import router.iface;
import router.stream;

nothrow @nogc:


// argument conversion functions...
// TODO: THESE NEED ADL STYLE LOOKUP!

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
    if (isSomeInt!T)
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
        import urt.conv : parseInt, parseUint;

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
        long i = base != 10 ? cast(long)s.parseUint(&taken, base) : s.parseInt(&taken);
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
    if (isSomeFloat!T)
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
        import urt.conv : parseFloat;

        const(char)[] s = v.asString;
        size_t taken;
        r = cast(T)s.parseFloat(&taken);
        if (taken != s.length)
            return "Invalid float value";
    }
    else
        return "Invalid float value";
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
                case Alias!(toLower(E)):
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
    if (!isSomeChar!U)
{
    const(Variant)[] arr;
    if (v.isArray)
        arr = v.asArray()[];
    else if (v.isString)
        assert(false, "TODO: split on ',' and re-tokenise all the elements...");
    else
        return "Invalid array";

    r = tempAllocator().allocArray!U(arr.length);
    foreach (i, ref e; arr)
    {
        const(char[]) error = convertVariant(e, r[i]);
        if (error)
            return error;
    }
    return null;
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
//    if (ValidUserType!T && !is(T : const(BaseObject)))
    // TODO: DELETE THIS LINE, USE THE ONE ABOVE WHEN STREAM AND INTERFACE ARE MIGRATED TO COLLECTIONS...
    if (ValidUserType!T && !is(T : const BaseObject) && !is(T : const Stream) && !is(T : const BaseInterface))
{
    if (v.isUser!T)
        r = v.asUser!T;
    else if (v.isString)
    {
        const(char)[] s = v.asString;
        return r.fromString(s) == s.length ? null : tconcat("Couldn't parse `" ~ T.stringof ~ "` from string: ", v);
    }
    else
        return "Invalid value";
    return null;
}

const(char[]) convertVariant(ref const Variant v, out Component r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid component value";
    const(char)[] s = v.asString;
    r = g_app.findComponent(s);
    return r ? null : tconcat("No component '", s, '\'');
}

const(char[]) convertVariant(ref const Variant v, out Device r) nothrow @nogc
{
    if (!v.isString)
        return "Invalid device value";
    const(char)[] s = v.asString;
    r = g_app.findDevice(s);
    return r ? null : tconcat("No device '", s, '\'');
}

const(char[]) convertVariant(I)(ref const Variant v, out I r) nothrow @nogc
    if (is(I : const BaseInterface))
{
    // TODO: parse as mac address...?
    if (!v.isString)
        return "Invalid interface value";
    const(char)[] s = v.asString;
    if (BaseInterface i = getModule!InterfaceModule.interfaces.get(s))
    {
        r = cast(I)i;
        static if (!is(Unqual!I == BaseInterface))
            if (!r)
                return tconcat("Requires ", I.TypeName, " interface, but ", i.name[], " is ", i.type[]);
    }
    return r ? null : tconcat("Interface does not exist: ", s);
}

const(char[]) convertVariant(S)(ref const Variant v, out S r) nothrow @nogc
    if (is(S : const Stream))
{
    if (!v.isString)
        return "Invalid stream value";
    const(char)[] s = v.asString;
    if (Stream stream = getModule!StreamModule.streams.get(s))
    {
        r = cast(S)stream;
        static if (!is(Unqual!S == Stream))
            if (!r)
                return tconcat("Requires ", S.TypeName, " stream, but ", s, " is ", stream.type[]);
    }
    return r ? null : tconcat("Stream does not exist: ", s);
}


// argument completions...
// TODO: THESE NEED ADL STYLE LOOKUP!

Array!String suggestCompletion(T : bool)(const(char)[] argumentText)
{
    Array!String completions = [ "true", "false", "yes", "no", "1", "0" ];
    return completions;
}

Array!String suggestCompletion(E)(const(char)[] argumentText)
    if (is(E == enum))
{
    Array!String completions;
    static foreach(M; __traits(allMembers, E))
    {{
        enum Member = Alias!(M.toLower);
        if (Member.startsWith(argumentText))
            completions ~= StringLit!Member;
    }}
    return completions;
}

Array!String suggestCompletion(T : Component)(const(char)[] argumentText)
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

Array!String suggestCompletion(T : Device)(const(char)[] argumentText)
{
    Array!String completions;
    foreach (name, device; g_app.devices)
    {
        if (name.startsWith(argumentText))
            completions ~= name.makeString(defaultAllocator);
    }
    return completions;
}

Array!String suggestCompletion(I)(const(char)[] argumentText)
    if (is(I : const BaseInterface))
{
    Array!String completions;
    foreach (i; getModule!InterfaceModule.interfaces.values)
    {
        static if (is(typeof(I.TypeName)))
        {
            if (i.type[] != I.TypeName)
                continue;
        }
        if (i.name.startsWith(argumentText))
            completions ~= i.name;
    }
    return completions;
}

Array!String suggestCompletion(S)(const(char)[] argumentText)
    if (is(S : const Stream))
{
    Array!String completions;
    foreach (s; getModule!StreamModule.streams.keys)
    {
        if (s.startsWith(argumentText))
            completions ~= s;
    }
    return completions;
}
