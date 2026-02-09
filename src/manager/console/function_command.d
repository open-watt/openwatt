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
import manager.value;


// UDA to attach custom tab completion to a command function
struct TabComplete
{
    Array!String function(bool is_value, const(char)[] name, const(char)[] value) nothrow @nogc suggest;
}


// uses GC
char[] transform_command_name(const(char)[] name)
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
enum TransformCommandName(const(char)[] name) = transform_command_name(name);

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

        enum FunctionName = transform_command_name(__traits(identifier, fun));

        static const(char)[] function_adapter(Session session, out FunctionCommandState state, const Variant[] arguments, const NamedArgument[] parameters, void* _instance)
        {
            const(char)[] error;
            auto _args = make_arg_tuple!fun(arguments, parameters, error, session._console.appInstance);
            if (error)
            {
                session.write_line(error);
                return null;
            }
            static if (is(__traits(parent, fun)))
            {
                static if (is(ReturnType!fun == void))
                {
                    __traits(getMember, cast(__traits(parent, fun))_instance, __traits(identifier, fun))(session, _args.expand);
                    return null;
                }
                else static if (is(ReturnType!fun : FunctionCommandState))
                {
                    state = __traits(getMember, cast(__traits(parent, fun))_instance, __traits(identifier, fun))(session, _args.expand);
                    return null;
                }
                else
                {
                    auto r = __traits(getMember, cast(__traits(parent, fun))_instance, __traits(identifier, fun))(session, _args.expand);
                    return tconcat(r);
                }
            }
            else
            {
                static if (is(ReturnType!fun == void))
                {
                    fun(session, _args.expand);
                    return null;
                }
                else static if (is(ReturnType!fun : FunctionCommandState))
                {
                    state = fun(session, _args.expand);
                    return null;
                }
                else
                {
                    auto r = fun(session, _args.expand);
                    return tconcat(r);
                }
            }
        }

        FunctionCommand fnCmd = console._allocator.allocT!FunctionCommand(console, commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName, cast(void*)i, &function_adapter);

        alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!fun[1 .. $]);
        alias Params = STATIC_MAP!(Unqual, Parameters!fun[1 .. $]);

        static foreach (j; 0 .. ParamNames.length)
        {
            static if (ParamNames[j] != "_args" && ParamNames[j] != "named_args")
            {{
                fnCmd._args ~= FunctionArgument(StringLit!(ParamNames[j]));
                static if (is(Params[j] == Nullable!T, T))
                    alias ArgTy = T;
                else
                    alias ArgTy = Params[j];
                static if (is(typeof(&suggest_completion!ArgTy)))
                    fnCmd._args[$-1].suggest = &suggest_completion!ArgTy;
            }}
        }

        // Check for TabComplete UDA on the function
        static foreach (attr; __traits(getAttributes, fun))
        {
            static if (is(typeof(attr) == TabComplete))
                fnCmd._custom_suggest = attr.suggest;
        }

        return fnCmd;
    }


    this(ref Console console, String scopeName, void* _instance, GenericCall _fn)
    {
        super(console, scopeName);
        this._instance = _instance;
        this._fn = _fn;
    }

    override FunctionCommandState execute(Session session, const Variant[] _args, const NamedArgument[] namedArgs, out Variant result)
    {
        FunctionCommandState state;
        const(char)[] r = _fn(session, state, _args, namedArgs, _instance);

        // TODO: when a function returns a token, it might be fed into the calling context?
        assert(!(state && r), "Shouldn't return a latent state AND a result...");

        if (state)
        {
            state.command = this;
            return state;
        }

        if (r)
            session.write_line(r);
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
            while (lastToken > 0 && !is_separator(cmdLine[lastToken - 1]))
                --lastToken;
            const(char)[] lastTok = cmdLine[lastToken .. $];

            size_t equals = lastTok.findFirst('=');
            if (equals == lastTok.length)
            {
                tokens = suggest_args(lastTok);
                result ~= get_completion_suffix(lastTok, tokens);
                if (result.length > 0 && result.length > cmdLine.length)
                {
                    if (result[$-1] == ' ')
                    {
                        result.popBack();
                        tokens = suggest_values(result[0 .. $-1], null);
                        result ~= get_completion_suffix(null, tokens);
                    }
                }
                return result;
            }

            tokens = suggest_values(lastTok[0 .. equals], lastTok[equals + 1 .. $]);
            result ~= get_completion_suffix(lastTok[equals + 1 .. $], tokens);
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
            return suggest_args(lastTok);
        return suggest_values(lastTok[0 .. equals], lastTok[equals + 1 .. $]);
    }

private:
    void* _instance;
    GenericCall _fn;
    Array!FunctionArgument _args;
    Array!String function(bool, const(char)[], const(char)[]) nothrow @nogc _custom_suggest;

    Array!String suggest_args(const(char)[] arg_prefix)
    {
        Array!String suggestions;
        if (_custom_suggest !is null)
            suggestions = _custom_suggest(false, arg_prefix, null);
        foreach (ref arg; _args)
        {
            if (arg.name.startsWith(arg_prefix))
                suggestions ~= String(MutableString!0(Concat, arg.name, '=')); // TODO: MOVE construct!
        }
        return suggestions;
    }

    Array!String suggest_values(const(char)[] argument, const(char)[] value)
    {
        if (_custom_suggest !is null)
        {
            Array!String suggestions = _custom_suggest(true, argument, value);
            if (suggestions.length > 0)
                return suggestions;
        }

        foreach (ref arg; _args)
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

auto make_arg_tuple(alias F)(const Variant[] args, const NamedArgument[] parameters, out const(char)[] error, Application app)
    if (is_some_function!F)
{
    import urt.meta;

    alias Params = STATIC_MAP!(Unqual, Parameters!F[1 .. $]);
    alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!F[1 .. $]);

    Tuple!Params params;
    error = null;
    bool[Params.length] got_arg;
    bool has_named_args = false;

    static foreach (i, P; Params)
    {
        static if (ParamNames[i] != "named-args")
            has_named_args = true;
    }

    outer: foreach (ref param; parameters)
    {
        param_switch: switch (param.name)
        {
            static foreach (i, P; Params)
            {
                static if (ParamNames[i] != "args" && ParamNames[i] != "named-args")
                {
                    case ParamNames[i]:
                        error = from_variant(param.value, params[i]);
                        if (error)
                        {
                            error = tconcat("Argument '", param.name, "' error: ", error);
                            break outer;
                        }
                        got_arg[i] = true;
                        break param_switch;
                }
            }
            default:
                if (!has_named_args)
                {
                    error = tconcat("Unknown parameter '", param.name, "'");
                    break outer;
                }
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
                if (!got_arg[i])
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
