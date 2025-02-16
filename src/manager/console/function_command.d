module manager.console.function_command;

import urt.mem;
import urt.meta;
import urt.meta.nullable;
import urt.meta.tuple;
import urt.traits;
import urt.string;
import urt.string.format;

public import manager.console;
public import manager.console.command;
public import manager.console.expression;
public import manager.console.session;
public import manager.instance;


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

    alias GenericCall = const(char)[] function(Session, out FunctionCommandState state, KVP[], void*) nothrow @nogc;

    static FunctionCommand create(alias fun, Instance)(ref Console console, Instance i, const(char)[] commandName = null)
    {
        static assert(is(Parameters!fun[0] == Session), "First parameter must be manager.console.session.Session for command hander function");

        enum FunctionName = transformCommandName(__traits(identifier, fun));

        static const(char)[] functionAdapter(Session session, out FunctionCommandState state, KVP[] parameters, void* instance)
        {
            const(char)[] error;
            auto args = makeArgTuple!fun(parameters, error, session.m_console.appInstance);
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

        return console.m_allocator.allocT!FunctionCommand(console, commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName, cast(void*)i, &functionAdapter);
    }


    this(ref Console console, String scopeName, void* instance, GenericCall fn)
    {
        super(console, scopeName);
        this.instance = instance;
        this.fn = fn;
    }

    override FunctionCommandState execute(Session session, const(char)[] cmdLine)
    {
        import urt.mem.scratchpad;
        import urt.mem.region;

        void[] scratch = allocScratchpad();
        scope(exit) freeScratchpad(scratch);

        // TODO: move this to its own function...
        Region* region = scratch.makeRegion;
        KVP[] params = region.allocArray!KVP(40);
        assert(params !is null);
        size_t numParams = 0;

        while (!cmdLine.empty)
        {
            KVP kvp = cmdLine.takeKVP;
            if (kvp.k.type == Token.Type.Error)
            {
                session.writeLine("Error: ", kvp.k.token);
                return null;
            }
            if (!kvp.k.type == Token.Type.None)
                params[numParams++] = kvp;
        }

        FunctionCommandState state;
        const(char)[] result = fn(session, state, params[0 .. numParams], instance);
        if (state)
            state.command = this;

        // TODO: when a function returns a token, it might be fed into the calling context?
        assert(!(state && result), "Shouldn't return a latent state AND a result...");

        return state;
    }

private:
    void* instance;
    GenericCall fn;
}


private:


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

auto makeArgTuple(alias F)(KVP[] args, out const(char)[] error, ApplicationInstance app)
    if (isSomeFunction!F)
{
    import urt.meta;

    alias Params = staticMap!(Unqual, Parameters!F[1 .. $]);
    alias ParamNames = ParameterIdentifierTuple!F[1 .. $];

    Tuple!Params params;
    error = null;
    bool[Params.length] gotArg;

    outer: foreach (ref kvp; args)
    {
        // validate argument name...
        if (kvp.k.type != Token.Type.Identifier)
        {
            error = tconcat("Invalid parameter type");
            break;
        }

        const(char)[] key = kvp.k.token[];
        arg: switch (key)
        {
            static foreach (i, P; Params)
            {
                case Alias!(transformCommandName(ParamNames[i])):
                    error = kvp.v.tokenToValue(params[i], app);
                    if (error)
                    {
                        error = tconcat("Error parsing argument '", key, "': ", error);
                        break outer;
                    }
                    gotArg[i] = true;
                    break arg;
            }
            default:
                error = tconcat("Unknown parameter '", key, "'");
                break outer;
        }
    }

    static foreach (i, P; Params)
    {
        {
            static if (!is(P : Nullable!U, U))
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

const(char)[] tokenValue(ref const Token t, bool acceptString) nothrow @nogc
{
    if (t.type == Token.Type.Command)
    {
        assert(false, "TODO: [command] expressions need to be evaluated... but what if the user calls a command with latency?");
    }
    else if (t.type == Token.Type.String)
    {
        if (acceptString)
            return t.token[].unQuote;
        else
            return null;
    }
    return t.token[];
}

const(char[]) tokenToValue(ref const Token t, out bool r, ApplicationInstance app) nothrow @nogc
{
    const(char)[] v = tokenValue(t, false);
    if (!v)
    {
        r = true;
        return null;
    }
    if (v[] == "true" || v[] == "yes")
    {
        r = true;
        return null;
    }
    else if (v[] == "false" || v[] == "no")
    {
        r = false;
        return null;
    }
    return "Invalid boolean value";
}

const(char[]) tokenToValue(I)(ref const Token t, out I r, ApplicationInstance app) nothrow @nogc
    if (isSomeInt!I)
{
    import urt.conv : parseInt;
    const(char)[] v = tokenValue(t, false);
    if (!v)
        return "No value";
    int base = 10;
    if (v.length > 2 && v[0..2] == "0x")
    {
        base = 16;
        v = v[2 .. $];
    }
    if (v.length > 2 && v[0..2] == "0b")
    {
        base = 2;
        v = v[2 .. $];
    }
    size_t taken;
    long i = v.parseInt(&taken, base);
    if (taken != v.length)
        return "Invalid integer value";
    if ((long.max > I.max && i > I.max) || (long.min < I.min && i < I.min))
        return "Integer value out of range";
    r = cast(I)i;
    return null;
}

const(char[]) tokenToValue(F)(ref const Token t, out F r, ApplicationInstance app) nothrow @nogc
    if (isSomeFloat!F)
{
    import urt.conv : parseFloat;
    const(char)[] v = tokenValue(t, false);
    if (!v)
        return "No value";
    size_t taken;
    r = cast(F)v.parseFloat(&taken);
    return taken == v.length ? null : "Invalid float value";
}

const(char[]) tokenToValue(S : const(char)[])(ref const Token t, out S r, ApplicationInstance app) nothrow @nogc
{
    const(char)[] v = tokenValue(t, true);
    r = v;
    return null;
}

const(char[]) tokenToValue(T)(ref const Token t, out T r, ApplicationInstance app) nothrow @nogc
    if (is(T U == enum))
{
    // try and parse a key from the string...
    const(char)[] v = tokenValue(t, false);
    if (!v)
        return "No value";
    switch (v)
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

    // else parse the base type?
//    const(char)[] v = tokenValue(t, false);

    return "Invalid value";
}

const(char[]) tokenToValue(T : U[], U)(ref const Token t, out T r, ApplicationInstance app) nothrow @nogc
    if (!is(U : char))
{
    const(char)[] v = tokenValue(t, false);

    // TODO: this is tricky, because we need to split on ',' but also need to re-tokenise all the elements...
    //       trouble is; what if the whole token is a string? did it even detect the token type correctly in the first place?

    const(char)[] tmp = v;
    int numArgs = 0;
    while (tmp.split!',')
        ++numArgs;

    r = tempAllocator().allocArray!U(numArgs);
    int i = 0;
    while (!v.empty)
    {
        const(char[]) error = tokenToValue(Token(v.split!','), r[i++], app);
        if (error)
            return error;
    }
    return null;
}

const(char[]) tokenToValue(T : Nullable!U, U)(ref const Token t, out T r, ApplicationInstance app) nothrow @nogc
{
    U tmp;
    const(char[]) error = tokenToValue(t, tmp, app);
    if (!error)
        r = tmp.move;
    return error;
}

const(char[]) tokenToValue(T)(ref const Token t, out T r, ApplicationInstance app) nothrow @nogc
    if (is(T == struct))
{
    const(char)[] v = tokenValue(t, false);
    return r.fromString(v) == v.length ? null : tconcat("Couldn't parse `" ~ T.stringof ~ "` from string: ", t);
}

public import manager.component : Component;
const(char[]) tokenToValue(ref const Token t, out Component r, ApplicationInstance app) nothrow @nogc
{
    const(char)[] v = tokenValue(t, true);
    r = app.findComponent(v);
    return r ? null : tconcat("No component '", v, '\'');
}

public import manager.device : Device;
const(char[]) tokenToValue(ref const Token t, out Device r, ApplicationInstance app) nothrow @nogc
{
    const(char)[] v = tokenValue(t, true);
    r = app.findDevice(v);
    return r ? null : tconcat("No device '", v, '\'');
}
