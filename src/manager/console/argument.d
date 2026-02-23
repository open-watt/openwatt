module manager.console.argument;

import urt.array;
import urt.string;
import urt.traits;
import urt.variant;

// these are used by the conversion functions...
import manager.base : BaseObject;
import manager.component : Component;
import manager.device : Device;

import router.iface : BaseInterface;
import router.stream : Stream;

nothrow @nogc:


// argument completions...
// TODO: THESE NEED ADL STYLE LOOKUP!

Array!String suggest_completion(T : typeof(null))(const(char)[] argument_text)
{
    if (StringLit!"null"[].startsWith(argument_text))
        return Array!String(Concat, StringLit!"null");
    return Array!String();
}

Array!String suggest_completion(T : bool)(const(char)[] argument_text)
{
    __gshared const String[4] vals = [ StringLit!"true", StringLit!"false", StringLit!"yes", StringLit!"no" ];
    Array!String completions;
    foreach (ref s; vals)
    {
        if (s[].startsWith(argument_text))
            completions ~= s;
    }
    return completions;
}

Array!String suggest_completion(E)(const(char)[] argument_text)
    if (is(E == enum))
{
    Array!String completions;
    static foreach(M; __traits(allMembers, E))
    {{
        enum Member = Alias!(M.to_lower);
        if (Member.startsWith(argument_text))
            completions ~= StringLit!Member;
    }}
    return completions;
}

Array!String suggest_completion(T : const Component)(const(char)[] argument_text)
    if(!is(T == typeof(null)))
{
    Array!String devices;
    size_t dot = argument_text.findFirst('.');
    if (dot == argument_text.length)
    {
        devices = suggest_completion!Device(argument_text);
        if (devices.length == 1)
        {
            dot = devices[0].length;
            argument_text = devices[0];
        }
        else
            return devices;
    }
    Device* dev = argument_text[0 .. dot] in g_app.devices;
    if (!dev)
        return Array!String();
    Component cmp = *dev;
    auto prefix = MutableString!0(Concat, cmp.id, '.');
    if (devices.length == 1)
        argument_text = prefix[];

    find_inner: while (true)
    {
        argument_text = argument_text[dot + 1 .. $];
        dot = argument_text.findFirst('.');
        if (dot == argument_text.length)
            break;

        foreach (c; cmp.components)
        {
            if (c.id == argument_text[0 .. dot])
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
        if (c.id[].startsWith(argument_text))
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

Array!String suggest_completion(T : const Device)(const(char)[] argument_text)
    if(!is(T == typeof(null)))
{
    Array!String completions;
    foreach (name; g_app.devices.keys)
    {
        if (name[].startsWith(argument_text))
            completions ~= name.makeString(defaultAllocator);
    }
    return completions;
}

Array!String suggest_completion(I)(const(char)[] argument_text)
    if (!is(I == typeof(null)) && is(const I == const BaseInterface))
{
    Array!String completions;
    foreach (ref name; get_module!InterfaceModule.interfaces.keys)
    {
        if (name[].startsWith(argument_text))
            completions ~= name;
    }
    return completions;
}

Array!String suggest_completion(S)(const(char)[] argument_text)
    if (!is(S == typeof(null)) && is(const S == const Stream))
{
    Array!String completions;
    foreach (ref name; get_module!StreamModule.streams.keys)
    {
        if (name[].startsWith(argument_text))
            completions ~= name;
    }
    return completions;
}

Array!String suggest_completion(T)(const(char)[] argument_text)
    if (!is(T == typeof(null)) && is(T : const BaseObject) && !is(const T == const BaseInterface) && !is(const T == const Stream))
{
    import manager.collection : collection_for;

    alias Type = Unqual!T;
    const collection = collection_for!Type();
    if (collection is null)
        return Array!String();

    Array!String completions;
    foreach (ref name; collection.keys)
    {
        if (name[].startsWith(argument_text))
            completions ~= name;
    }
    return completions;
}
