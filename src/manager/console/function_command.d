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
import manager.expression : ScriptCommand, parse_arguments, free_script_command;
import manager.value;


// UDA to attach custom tab completion to a command function
struct TabComplete
{
    Array!String function(bool is_value, const(char)[] name, const(char)[] value) nothrow @nogc suggest;
}


// uses GC
char[] transform_command_name(const(char)[] name)
{
    assert(__ctfe, "Should only be used at compile time");

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


// TODO: DELETE THIS!!!
class FunctionCommandState : CommandState
{
nothrow @nogc:
    this(Session session)
    {
        super(session);
    }
}


template function_command_desc(alias fun, string command_name = null)
{
    static assert(is(Parameters!fun[0] == Session), "First parameter must be manager.console.session.Session for command hander function");

    private enum FunctionName = transform_command_name(__traits(identifier, fun));

    private static const(char)[] function_adapter(Session session, out CommandState state, const Variant[] arguments, const NamedArgument[] parameters, void* _instance)
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
            else static if (is(ReturnType!fun : CommandState))
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
            else static if (is(ReturnType!fun : CommandState))
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

    private alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!fun[1 .. $]);
    private alias Params = STATIC_MAP!(Unqual, Parameters!fun[1 .. $]);

    private enum size_t ArgCount = () {
        size_t n = 0;
        static foreach (j; 0 .. ParamNames.length)
            static if (ParamNames[j] != "args" && ParamNames[j] != "named-args")
                ++n;
        return n;
    }();

    // LDC rejects a by-value zero-length static array return, so a command
    // with no arguments must not instantiate the builder at all.
    static if (ArgCount > 0)
    {
        private FunctionArgument[ArgCount] build_args() pure
        {
            FunctionArgument[ArgCount] args;
            size_t n = 0;
            static foreach (j; 0 .. ParamNames.length)
            {
                static if (ParamNames[j] != "args" && ParamNames[j] != "named-args")
                {{
                    static if (is(Params[j] == Nullable!T, T))
                    {
                        enum bool ParamIsNullable = true;
                        alias ArgTy = T;
                    }
                    else
                    {
                        enum bool ParamIsNullable = false;
                        alias ArgTy = Params[j];
                    }
                    args[n].name = StringLit!(ParamNames[j]);
                    version (ExcludeHelpText) {} else
                    {
                        enum TypeName = ParamIsNullable ? "?" ~ ArgTy.stringof : ArgTy.stringof;
                        args[n].type_name = StringLit!TypeName;
                    }
                    static if (is(typeof(&suggest_completion!ArgTy)))
                        args[n].suggest = &suggest_completion!ArgTy;
                    ++n;
                }}
            }
            return args;
        }

        private static immutable FunctionArgument[ArgCount] function_args = build_args();
    }

    private enum Name = command_name is null ? FunctionName : command_name;

    private CommandDesc build_desc() pure
    {
        CommandDesc d;
        d.cls = &function_command_class;
        d.name = StringLit!Name;
        d.fn = &function_adapter;
        static if (ArgCount > 0)
            d.args = function_args[];
        static foreach (attr; __traits(getAttributes, fun))
        {
            static if (is(typeof(attr) == TabComplete))
                d.custom_suggest = attr.suggest;
        }
        return d;
    }

    static immutable CommandDesc function_command_desc = build_desc();
}


static immutable CommandClass function_command_class = {
    exec: &function_command_exec,
    suggest: &function_command_suggest,
    complete: &function_command_complete,
    help_fn: &function_command_help,
};


CommandState function_command_exec(ref Command cmd, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    CommandState state;
    const(char)[] r = cmd.desc.fn(session, state, args, named_args, cmd.instance);

    // TODO: when a function returns a token, it might be fed into the calling context?
    assert(!(state && r), "Shouldn't return a latent state AND a result...");

    if (state)
    {
        state.command = &cmd;
        return state;
    }

    if (r)
        session.write_line(r);
    return null;
}

MutableString!0 function_command_complete(ref Command cmd, ref Console console, const(char)[] cmd_line, Scope*, Scope*)
{
    version (ExcludeAutocomplete)
        return null;
    else
    {
        MutableString!0 result = cmd_line;
        Array!String tokens;

        size_t lastToken = cmd_line.length;
        while (lastToken > 0 && !is_separator(cmd_line[lastToken - 1]))
            --lastToken;
        const(char)[] lastTok = cmd_line[lastToken .. $];

        size_t equals = lastTok.findFirst('=');
        if (equals == lastTok.length)
        {
            tokens = suggest_args(*cmd.desc, lastTok);
            if (immutable(FunctionArgument)* a = positional_arg(*cmd.desc, cmd_line[0 .. lastToken]))
            {
                if (a.suggest)
                {
                    foreach (ref s; a.suggest(lastTok))
                        tokens ~= s;
                }
            }
            result ~= get_completion_suffix(lastTok, tokens);
            if (result.length > 0 && result.length > cmd_line.length)
            {
                if (result[$-1] == ' ')
                {
                    result.popBack();
                    tokens = suggest_values(*cmd.desc, result[0 .. $-1], null);
                    result ~= get_completion_suffix(null, tokens);
                }
            }
            return result;
        }

        tokens = suggest_values(*cmd.desc, lastTok[0 .. equals], lastTok[equals + 1 .. $]);
        result ~= get_completion_suffix(lastTok[equals + 1 .. $], tokens);
        return result;
    }
}

Array!String function_command_suggest(ref Command cmd, ref Console console, const(char)[] cmd_line, Scope*, Scope*)
{
    // get incomplete argument
    ptrdiff_t lastToken = cmd_line.length;
    while (lastToken > 0)
    {
        if (cmd_line[lastToken - 1].is_whitespace)
            break;
        --lastToken;
    }
    const(char)[] lastTok = cmd_line[lastToken .. $];

    // if the partial argument alrady contains an '='
    size_t equals = lastTok.findFirst('=');
    if (equals == lastTok.length)
    {
        Array!String suggestions = suggest_args(*cmd.desc, lastTok);
        if (immutable(FunctionArgument)* a = positional_arg(*cmd.desc, cmd_line[0 .. lastToken]))
        {
            if (a.suggest)
            {
                foreach (ref s; a.suggest(lastTok))
                    suggestions ~= s;
            }
        }
        return suggestions;
    }
    return suggest_values(*cmd.desc, lastTok[0 .. equals], lastTok[equals + 1 .. $]);
}

version (ExcludeHelpText) {} else
const(char)[] function_command_help(ref const Command cmd, const(char)[] args)
{
    auto buf = MutableString!0(Concat, "Usage: ", cmd.desc.name[]);
    foreach (ref a; cmd.desc.args)
    {
        buf ~= "\n  ";
        const(char)[] tn = a.type_name[];
        bool optional = tn[0] == '?';
        if (optional)
        {
            buf ~= '[';
            tn = tn[1 .. $];
        }
        buf.append(a.name[], "=<", tn, '>');
        if (optional)
            buf ~= ']';
    }
    return tconcat(buf[]);
}


private:

Array!String suggest_args(ref immutable CommandDesc desc, const(char)[] arg_prefix)
{
    Array!String suggestions;
    if (desc.custom_suggest !is null)
        suggestions = desc.custom_suggest(false, arg_prefix, null);
    foreach (ref arg; desc.args)
    {
        if (arg.name[].startsWith(arg_prefix))
            suggestions ~= String(MutableString!0(Concat, arg.name, '=')); // TODO: MOVE construct!
    }
    return suggestions;
}

// an unnamed argument binds to the nth parameter not already given by name, so
// positional completion resolves through the same per-argument suggester. The
// arguments are parsed rather than split on whitespace, so a quoted or braced
// value containing spaces or '=' still counts as the single argument it is.
immutable(FunctionArgument)* positional_arg(ref immutable CommandDesc desc, const(char)[] preceding)
{
    ScriptCommand c;
    scope(exit) free_script_command(c);
    parse_arguments(preceding, c);

    size_t count = c.args.length;
    foreach (ref a; desc.args)
    {
        bool named;
        foreach (ref n; c.named_args)
        {
            if (n.name && n.name.get_str() == a.name[])
            {
                named = true;
                break;
            }
        }
        if (named)
            continue;
        if (count == 0)
            return &a;
        --count;
    }
    return null;
}

Array!String suggest_values(ref immutable CommandDesc desc, const(char)[] argument, const(char)[] value)
{
    if (desc.custom_suggest !is null)
    {
        Array!String suggestions = desc.custom_suggest(true, argument, value);
        if (suggestions.length > 0)
            return suggestions;
    }

    foreach (ref arg; desc.args)
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

public auto make_arg_tuple(alias F)(const Variant[] args, const NamedArgument[] parameters, out const(char)[] error, Application app)
    if (is_some_function!F)
{
    import urt.meta;

    alias Params = STATIC_MAP!(Unqual, Parameters!F[1 .. $]);
    alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!F[1 .. $]);

    Tuple!Params params;
    error = null;
    bool[Params.length] got_arg;
    bool has_named_args = false;
    bool has_args_param = false;

    static foreach (i, P; Params)
    {
        static if (ParamNames[i] == "named-args")
            has_named_args = true;
        else static if (ParamNames[i] == "args")
            has_args_param = true;
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
                        static if (is(const(Variant) : typeof(params[i])))
                            params[i] = param.value;
                        else
                        {
                            error = from_variant(param.value, params[i]);
                            if (error)
                            {
                                error = tconcat("Argument '", param.name, "' error: ", error);
                                break outer;
                            }
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

    // unnamed arguments fill the parameters left over in declaration order; a command
    // taking `args` wants the raw list, so it opts out rather than competing for them
    if (error is null && !has_args_param)
    {
        size_t next;
        static foreach (i, P; Params)
        {
            static if (ParamNames[i] != "args" && ParamNames[i] != "named-args")
            {
                if (!got_arg[i] && next < args.length)
                {
                    static if (is(const(Variant) : typeof(params[i])))
                        params[i] = args[next];
                    else
                    {
                        error = from_variant(args[next], params[i]);
                        if (error)
                        {
                            error = tconcat("Argument '", ParamNames[i], "' error: ", error);
                            goto done;
                        }
                    }
                    got_arg[i] = true;
                    ++next;
                }
            }
        }

        if (next < args.length)
        {
            error = "Too many arguments";
            goto done;
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
