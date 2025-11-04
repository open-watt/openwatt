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
import manager.console.argument;
public import manager.console.command;
public import manager.console.session;
public import manager.expression : NamedArgument;


// UDA to attach custom tab completion to a command function
struct TabComplete
{
    Array!String function(bool is_value, const(char)[] name, const(char)[] value) nothrow @nogc suggest;
}


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
enum TransformCommandName(const(char)[] name) = transformCommandName(name);

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

        alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!fun[1 .. $]);
        alias Params = STATIC_MAP!(Unqual, Parameters!fun[1 .. $]);

        static foreach (j; 0 .. ParamNames.length)
        {
            static if (ParamNames[j] != "args" && ParamNames[j] != "named_args")
            {{
                fnCmd.args ~= FunctionArgument(StringLit!(ParamNames[j]));
                static if (is(Params[j] == Nullable!T, T))
                    alias ArgTy = T;
                else
                    alias ArgTy = Params[j];
                static if (is(typeof(&suggestCompletion!ArgTy)))
                    fnCmd.args[$-1].suggest = &suggestCompletion!ArgTy;
            }}
        }

        // Check for TabComplete UDA on the function
        static foreach (attr; __traits(getAttributes, fun))
        {
            static if (is(typeof(attr) == TabComplete))
                fnCmd.custom_suggest = attr.suggest;
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
            if (cmdLine[lastToken - 1].is_whitespace)
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
    Array!String function(bool, const(char)[], const(char)[]) nothrow @nogc custom_suggest;

    Array!String suggestArgs(const(char)[] arg_prefix)
    {
        Array!String suggestions;
        if (custom_suggest !is null)
            suggestions = custom_suggest(false, arg_prefix, null);
        foreach (ref arg; args)
        {
            if (arg.name.startsWith(arg_prefix))
                suggestions ~= String(MutableString!0(Concat, arg.name, '=')); // TODO: MOVE construct!
        }
        return suggestions;
    }

    Array!String suggestValues(const(char)[] argument, const(char)[] value)
    {
        if (custom_suggest !is null)
        {
            Array!String suggestions = custom_suggest(true, argument, value);
            if (suggestions.length > 0)
                return suggestions;
        }

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
    if (is_some_function!F)
{
    import urt.meta;

    alias Params = STATIC_MAP!(Unqual, Parameters!F[1 .. $]);
    alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!F[1 .. $]);

    Tuple!Params params;
    error = null;
    bool[Params.length] gotArg;

    outer: foreach (ref param; parameters)
    {
        param_switch: switch (param.name)
        {
            static foreach (i, P; Params)
            {
                static if (ParamNames[i] != "args" && ParamNames[i] != "named-args")
                {
                    case ParamNames[i]:
                        error = convertVariant(param.value, params[i]);
                        if (error)
                        {
                            error = tconcat("Argument '", param.name, "' error: ", error);
                            break outer;
                        }
                        gotArg[i] = true;
                        break param_switch;
                }
            }
            default:
                error = tconcat("Unknown parameter '", param.name, "'");
                break outer;
        }
    }

    static foreach (i, P; Params)
    {
        {
            static if (ParamNames[i] == "args")
            {
                static assert(is(const(Variant)[] : P), "`args` parameter must be of type const(Variant)[]");
                params[i] = args;
            }
            else static if (ParamNames[i] == "named-args")
            {
                static assert(is(const(NamedArgument)[] : P), "`named_args` parameter must be of type const(NamedArgument)[]");
                params[i] = parameters;
            }
            else static if (!is(P : Nullable!U, U))
            {
                if (!gotArg[i])
                {
                    error = tconcat("Missing argument: ", ParamNames[i]);
                    goto done;
                }
            }
        }
    }

done:
    return params;
}
