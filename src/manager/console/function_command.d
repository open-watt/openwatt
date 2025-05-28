module manager.console.function_command;

import urt.array;
import urt.mem;
import urt.meta;
import urt.meta.nullable;
import urt.meta.tuple;
import urt.traits;
import urt.string;
import urt.string.format;
import urt.variant;

public import manager;
public import manager.console;
public import manager.console.command;
public import manager.console.session;
public import manager.expression : NamedArgument;


// uses GC
char[] transformCommandName(const(char)[] name)
{
    name = name.length > 0 && name[0] == '_' ? name[1 .. $] : name;
    char[] result = name.dup;
    foreach (i, c; result)
    {
        if (c == '_')
            result[i] = '-';
    }
    return result;
}

nothrow @nogc:


class FunctionCommandState : CommandState
{
nothrow @nogc:
    this(Session session)
    {
        super(session, null);
    }
}

class FunctionCommand : Command
{
nothrow @nogc:

    alias GenericCall = const(char)[] function(Session, out FunctionCommandState, const Variant[], const NamedArgument[], void*) nothrow @nogc;

    static FunctionCommand create(alias fun, Instance)(ref Console console, Instance i, const(char)[] commandName = null)
    {
        static assert(is(Parameters!fun[0] == Session), "First parameter must be manager.console.session.Session for command hander function");

        enum FunctionName = transformCommandName(__traits(identifier, fun));

        static const(char)[] functionAdapter(Session session, out FunctionCommandState state, const Variant[] arguments, const NamedArgument[] parameters, void* instance)
        {
            const(char)[] error;
            auto args = makeArgTuple!fun(arguments, parameters, error, session.m_console.appInstance);
            if (error)
            {
                session.writeLine(error);
                return null;
            }
            static if (is(__traits(parent, fun)))
            {
                static if (is(ReturnType!fun == void))
                {
                    __traits(getMember, cast(__traits(parent, fun))instance, __traits(identifier, fun))(session, args.expand);
                    return null;
                }
                else static if (is(ReturnType!fun : FunctionCommandState))
                {
                    state = __traits(getMember, cast(__traits(parent, fun))instance, __traits(identifier, fun))(session, args.expand);
                    return null;
                }
                else
                {
                    auto r = __traits(getMember, cast(__traits(parent, fun))instance, __traits(identifier, fun))(session, args.expand);
                    return tconcat(r);
                }
            }
            else
            {
                static if (is(ReturnType!fun == void))
                {
                    fun(session, args.expand);
                    return null;
                }
                else static if (is(ReturnType!fun : FunctionCommandState))
                {
                    state = fun(session, args.expand);
                    return null;
                }
                else
                {
                    auto r = fun(session, args.expand);
                    return tconcat(r);
                }
            }
        }

        FunctionCommand fnCmd = console.m_allocator.allocT!FunctionCommand(console, commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName, cast(void*)i, &functionAdapter);

        alias ParamNames = ParameterIdentifierTuple!fun[1 .. $];
        alias Params = staticMap!(Unqual, Parameters!fun[1 .. $]);

        static foreach (j; 0 .. ParamNames.length)
        {
            static if (ParamNames[j] != "args")
            {{
                fnCmd.args ~= FunctionArgument(StringLit!(ParamNames[j].transformCommandName()));
                static if (is(Params[j] == Nullable!T, T))
                    alias ArgTy = T;
                else
                    alias ArgTy = Params[j];
                static if (is(typeof(&suggestCompletion!ArgTy)))
                    fnCmd.args[$-1].suggest = &suggestCompletion!ArgTy;
            }}
        }

        return fnCmd;
    }


    this(ref Console console, String scopeName, void* instance, GenericCall fn)
    {
        super(console, scopeName);
        this.instance = instance;
        this.fn = fn;
    }

    override FunctionCommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        FunctionCommandState state;
        const(char)[] result = fn(session, state, args, namedArgs, instance);

        // TODO: when a function returns a token, it might be fed into the calling context?
        assert(!(state && result), "Shouldn't return a latent state AND a result...");

        if (state)
        {
            state.command = this;
            return state;
        }

        if (result)
            session.writeLine(result);
        return null;
    }

    override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            MutableString!0 result = cmdLine;
            Array!String tokens;

            size_t lastToken = cmdLine.length;
            while (lastToken > 0 && !isSeparator(cmdLine[lastToken - 1]))
                --lastToken;
            const(char)[] lastTok = cmdLine[lastToken .. $];

            size_t equals = lastTok.findFirst('=');
            if (equals == lastTok.length)
            {
                tokens = suggestArgs(lastTok);
                result ~= getCompletionSuffix(lastTok, tokens);
                if (result.length > 0 && result.length > cmdLine.length)
                {
                    if (result[$-1] == ' ')
                    {
                        result.popBack();
                        tokens = suggestValues(result[0 .. $-1], null);
                        result ~= getCompletionSuffix(null, tokens);
                    }
                }
                return result;
            }

            tokens = suggestValues(lastTok[0 .. equals], lastTok[equals + 1 .. $]);
            result ~= getCompletionSuffix(lastTok[equals + 1 .. $], tokens);
            return result;
        }
    }

    override Array!String suggest(const(char)[] cmdLine)
    {
        // get incomplete argument
        ptrdiff_t lastToken = cmdLine.length;
        while (lastToken > 0)
        {
            if (cmdLine[lastToken - 1].isWhitespace)
                break;
            --lastToken;
        }
        const(char)[] lastTok = cmdLine[lastToken .. $];

        // if the partial argument alrady contains an '='
        size_t equals = lastTok.findFirst('=');
        if (equals == lastTok.length)
            return suggestArgs(lastTok);
        return suggestValues(lastTok[0 .. equals], lastTok[equals + 1 .. $]);
    }

private:
    void* instance;
    GenericCall fn;
    Array!FunctionArgument args;

    Array!String suggestArgs(const(char)[] argPrefix)
    {
        Array!String suggestions;
        foreach (ref arg; args)
        {
            if (arg.name.startsWith(argPrefix))
                suggestions ~= String(MutableString!0(Concat, arg.name, '=')); // TODO: MOVE construct!
        }
        return suggestions;
    }

    Array!String suggestValues(const(char)[] argument, const(char)[] value)
    {
        foreach (ref arg; args)
        {
            if (arg.name[] == argument[])
            {
                if (arg.suggest)
                    return arg.suggest(value);
                break;
            }
        }
        return Array!String();
    }
}


private:

struct FunctionArgument
{
    String name;
    Array!String function(const(char)[]) nothrow @nogc suggest;
}

auto makeArgTuple(alias F)(const Variant[] args, const NamedArgument[] parameters, out const(char)[] error, Application app)
    if (isSomeFunction!F)
{
    import urt.meta;

    alias Params = staticMap!(Unqual, Parameters!F[1 .. $]);
    alias ParamNames = ParameterIdentifierTuple!F[1 .. $];

    Tuple!Params params;
    error = null;
    bool[Params.length] gotArg;

    outer: foreach (ref param; parameters)
    {
        param_switch: switch (param.name)
        {
            static foreach (i, P; Params)
            {
                case Alias!(transformCommandName(ParamNames[i])):
                    error = convertVariant(param.value, params[i], app);
                    if (error)
                    {
                        error = tconcat("Argument '", param.name, "' error: ", error);
                        break outer;
                    }
                    gotArg[i] = true;
                    break param_switch;
            }
            default:
                error = tconcat("Unknown parameter '", param.name, "'");
                break outer;
        }
    }

    static foreach (i, P; Params)
    {
        {
            static if (transformCommandName(ParamNames[i]) == "args")
            {
                static assert(is(P == Variant[]), "`args` parameter must be of type Variant[]");
                params[i] = args;
            }
            else static if (!is(P : Nullable!U, U))
            {
                if (!gotArg[i])
                {
                    error = tconcat("Missing argument: ", Alias!(transformCommandName(ParamNames[i])));
                    goto done;
                }
            }
        }
    }

done:
    return params;
}


// argument conversion functions...
// TODO: THESE NEED ADL STYLE LOOKUP!

const(char[]) convertVariant(ref const Variant v, out bool r, Application app) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r, Application app) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r, Application app) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r, Application app) nothrow @nogc
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

const(char[]) convertVariant(T)(ref const Variant v, out T r, Application app) nothrow @nogc
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

const(char[]) convertVariant(U)(ref const Variant v, out U[] r, Application app) nothrow @nogc
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
        const(char[]) error = convertVariant(e, r[i], app);
        if (error)
            return error;
    }
    return null;
}

const(char[]) convertVariant(U, size_t N)(ref const Variant v, out U[N] r, Application app) nothrow @nogc
    if (!is(U : dchar))
{
    U[] tmp;
    const(char)[] err = convertVariant!(U[])(v, tmp, app);
    if (err)
        return err;
    if (tmp.length != N)
        return "Array length mismatch";
    r = tmp[0..N];
    return null;
}

const(char[]) convertVariant(T)(ref const Variant v, out T r, Application app) nothrow @nogc
    if (is(T == struct))
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

const(char[]) convertVariant(T : Nullable!U, U)(ref const Variant v, out T r, Application app) nothrow @nogc
{
    U tmp;
    const(char[]) error = convertVariant(v, tmp, app);
    if (!error)
        r = tmp.move;
    return error;
}

public import manager.component : Component;
const(char[]) convertVariant(ref const Variant v, out Component r, Application app) nothrow @nogc
{
    if (!v.isString)
        return "Invalid component value";
    const(char)[] s = v.asString;
    r = app.findComponent(s);
    return r ? null : tconcat("No component '", s, '\'');
}

public import manager.device : Device;
const(char[]) convertVariant(ref const Variant v, out Device r, Application app) nothrow @nogc
{
    if (!v.isString)
        return "Invalid device value";
    const(char)[] s = v.asString;
    r = app.findDevice(s);
    return r ? null : tconcat("No device '", s, '\'');
}


// argument completions...
// TODO: THESE NEED ADL STYLE LOOKUP!

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
