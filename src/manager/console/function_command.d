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
        super(session, null);
    }
}

class FunctionCommand : Command
{
nothrow @nogc:

    alias GenericCall = const(char)[] function(Session, out CommandState, const AlignedArgument[], const Variant[], const NamedArgument[], void*) nothrow @nogc;

    static FunctionCommand create(alias fun, Instance)(ref Console console, Instance i, const(char)[] commandName = null)
    {
        static assert(is(Parameters!fun[0] == Session), "First parameter must be manager.console.session.Session for command hander function");

        enum FunctionName = transform_command_name(__traits(identifier, fun));
        alias ParamNames = STATIC_MAP!(TransformCommandName, parameter_identifier_tuple!fun[1 .. $]);
        alias Params = STATIC_MAP!(Unqual, Parameters!fun[1 .. $]);

        static const(char)[] function_adapter(Session session, out CommandState state, const AlignedArgument[] arguments, const Variant[] positional_arguments, const NamedArgument[] named_arguments, void* _instance)
        {
            Tuple!Params _args;
            size_t error_slot;
            const(char)[] error = convert_arguments!Params(arguments, positional_arguments, named_arguments, _args, error_slot);
            if (error)
            {
                write_argument_error(session, arguments[error_slot].definition.name, error);
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

        FunctionCommand fnCmd = console._allocator.allocT!FunctionCommand(console, commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName, cast(void*)i, &function_adapter);
        static assert(Params.length <= ubyte.max, "Too many command parameters");
        fnCmd._parameter_count = cast(ubyte)Params.length;

        static foreach (j; 0 .. ParamNames.length)
        {
            static if (ParamNames[j] == "named-args")
            {
                static assert(is(const(NamedArgument)[] : Params[j]), "`named_args` parameter must be of type const(NamedArgument)[]");
                fnCmd._accepts_named_arguments = true;
            }
            else static if (ParamNames[j] == "args")
                static assert(is(const(Variant)[] : Params[j]), "`args` parameter must be of type const(Variant)[]");
            else
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
                version (ExcludeHelpText)
                    fnCmd._args ~= FunctionArgument(cast(ubyte)j, ParamIsNullable, StringLit!(ParamNames[j]));
                else
                    fnCmd._args ~= FunctionArgument(cast(ubyte)j, ParamIsNullable, StringLit!(ParamNames[j]), StringLit!(ParamIsNullable ? "?" ~ ArgTy.stringof : ArgTy.stringof));
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

    override CommandState execute(Session session, Scope*, const Variant[] positional_arguments, const NamedArgument[] named_arguments, out Variant result)
    {
        AlignedArgument[] arguments = tempAllocator().allocArray!AlignedArgument(_parameter_count);
        if (const(char)[] error = align_arguments(_args[], named_arguments, arguments, _accepts_named_arguments))
        {
            session.write_line(error);
            return null;
        }

        CommandState state;
        const(char)[] r = _fn(session, state, arguments, positional_arguments, named_arguments, _instance);

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

    override MutableString!0 complete(const(char)[] cmdLine, Scope*, Scope*)
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

    override Array!String suggest(const(char)[] cmdLine, Scope*, Scope*)
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

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
    {
        auto buf = MutableString!0(Concat, "Usage: ", name[]);
        foreach (ref a; _args)
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
            if (optional) buf ~= ']';
        }
        return tconcat(buf[]);
    }

private:
    void* _instance;
    GenericCall _fn;
    Array!FunctionArgument _args;
    Array!String function(bool, const(char)[], const(char)[]) nothrow @nogc _custom_suggest;
    ubyte _parameter_count;
    bool _accepts_named_arguments;

    Array!String suggest_args(const(char)[] arg_prefix)
    {
        Array!String suggestions;
        if (_custom_suggest !is null)
            suggestions = _custom_suggest(false, arg_prefix, null);
        foreach (ref arg; _args)
        {
            if (arg.name[].startsWith(arg_prefix))
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
nothrow @nogc:

    version (ExcludeHelpText)
    this(ubyte slot, bool optional, String name)
    {
        this.slot = slot;
        this.optional = optional;
        this.name = name.move;
    }
    else
    this(ubyte slot, bool optional, String name, String type_name)
    {
        this.slot = slot;
        this.optional = optional;
        this.name = name.move;
        this.type_name = type_name.move;
    }

    String name;
    version (ExcludeHelpText) {} else
        String type_name = StringLit!"";  // prefixed with '?' if the param is Nullable
    Array!String function(const(char)[]) nothrow @nogc suggest;
    ubyte slot;
    bool optional;
}

struct AlignedArgument
{
    const(FunctionArgument)* definition;
    const(Variant)* value;
}

const(char)[] align_arguments(const FunctionArgument[] definitions, const NamedArgument[] parameters, ref AlignedArgument[] arguments, bool accepts_named_arguments)
{
    foreach (ref definition; definitions)
    {
        assert(definition.slot < arguments.length);
        assert(arguments[definition.slot].definition is null);
        arguments[definition.slot].definition = &definition;
    }

    foreach (ref parameter; parameters)
    {
        const(FunctionArgument)* definition;
        foreach (ref candidate; definitions)
        {
            if (candidate.name[] == parameter.name)
            {
                definition = &candidate;
                break;
            }
        }
        if (definition)
            arguments[definition.slot].value = &parameter.value;
        else if (!accepts_named_arguments)
            return tconcat("Unknown parameter '", parameter.name, "'");
    }

    foreach (ref definition; definitions)
    {
        if (!definition.optional && arguments[definition.slot].value is null)
            return tconcat("Missing argument: ", definition.name);
    }
    return null;
}

pragma(inline, false)
const(char)[] convert_arguments(Params...)(const AlignedArgument[] arguments, const Variant[] positional_arguments, const NamedArgument[] named_arguments, ref Tuple!Params result, out size_t error_slot)
{
    assert(arguments.length == Params.length);
    static foreach (i, P; Params)
    {
        static if (is(const(Variant)[] : P))
        {
            assert(arguments[i].definition is null);
            result[i] = positional_arguments;
        }
        else static if (is(const(NamedArgument)[] : P))
        {
            assert(arguments[i].definition is null);
            result[i] = named_arguments;
        }
        else
        {
            assert(arguments[i].definition);
            if (arguments[i].value)
            {
                static if (is(const(Variant) : typeof(result[i])))
                    result[i] = *arguments[i].value;
                else if (const(char)[] error = from_variant(*arguments[i].value, result[i]))
                {
                    error_slot = i;
                    return error;
                }
            }
        }
    }
    return null;
}

pragma(inline, false)
void write_argument_error(Session session, ref const String name, const(char)[] error)
{
    session.write_line(tconcat("Argument '", name, "' error: ", error));
}


unittest
{
    version (ExcludeHelpText)
        FunctionArgument[2] definitions = [FunctionArgument(1, false, StringLit!"required"), FunctionArgument(0, true, StringLit!"optional")];
    else
        FunctionArgument[2] definitions = [FunctionArgument(1, false, StringLit!"required", StringLit!"uint"), FunctionArgument(0, true, StringLit!"optional", StringLit!"uint")];
    NamedArgument[1] parameters = [NamedArgument("required", 42u)];
    AlignedArgument[4] storage;
    AlignedArgument[] arguments = storage[];
    assert(!align_arguments(definitions[], parameters[], arguments, false));
    assert(arguments[0].definition is &definitions[1] && arguments[0].value is null);
    assert(arguments[1].definition is &definitions[0] && arguments[1].value is &parameters[0].value);
    assert(arguments[2].definition is null && arguments[2].value is null);
    assert(arguments[3].definition is null && arguments[3].value is null);

    arguments[] = AlignedArgument.init;
    assert(align_arguments(definitions[], null, arguments, false) == "Missing argument: required");
    arguments[] = AlignedArgument.init;
    NamedArgument[1] unknown = [NamedArgument("unknown", true)];
    assert(align_arguments(definitions[], unknown[], arguments, false) == "Unknown parameter 'unknown'");
    arguments[] = AlignedArgument.init;
    NamedArgument[2] parameters_and_unknown = [NamedArgument("required", 42u), NamedArgument("unknown", true)];
    assert(align_arguments(definitions[], parameters_and_unknown[], arguments, true) is null);

    Tuple!(Nullable!uint, uint, const(Variant)[], const(NamedArgument)[]) result;
    Variant[2] positional = [Variant(1u), Variant(2u)];
    size_t error_slot;
    assert(!convert_arguments!(Nullable!uint, uint, const(Variant)[], const(NamedArgument)[])(arguments, positional[], parameters[], result, error_slot));
    assert(result[0] == null && result[1] == 42u);
    assert(result[2].ptr is positional.ptr && result[2].length == positional.length);
    assert(result[3].ptr is parameters.ptr && result[3].length == parameters.length);
}
