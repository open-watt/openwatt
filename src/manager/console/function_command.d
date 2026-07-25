module manager.console.function_command;

import urt.array;
import urt.mem;
import urt.string;
import urt.string.format;
import urt.variant;

public import manager;
public import manager.console;
import manager.console.argument;
public import manager.console.command;
public import manager.console.session;
public import manager.expression : NamedArgument;
public import manager.call : TabComplete;
import manager.call;

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

    static FunctionCommand create(alias fun, Instance)(ref Console console, Instance i, const(char)[] commandName = null)
    {
        enum FunctionName = transform_function_name(__traits(identifier, fun));
        Function function_ = Function.create_contextual!(fun, Instance, suggest_completion)(i);
        return console._allocator.allocT!FunctionCommand(
            console,
            commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName,
            function_);
    }


    this(ref Console console, String scopeName, Function function_)
    {
        super(console, scopeName);
        _function = function_;
    }

    override CommandState execute(Session session, Scope*, const Variant[] _args, const NamedArgument[] namedArgs, out Variant result)
    {
        CallContext context = CallContext(session);
        CallResult call = _function.call(context, _args, namedArgs);
        if (call.error)
        {
            session.write_line(call.error);
            return null;
        }
        if (call.state)
        {
            CommandState state = cast(CommandState)call.state;
            assert(state, "a console function returned a non-command call state");
            state.command = this;
            return state;
        }
        if (call.has_value)
            session.write_line(call.value);
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
        foreach (ref a; _function.info.parameters)
        {
            if (a.flags & (ParameterFlags.positional_rest | ParameterFlags.named_rest))
                continue;
            buf ~= "\n  ";
            const(char)[] tn = a.type_name[];
            bool optional = (a.flags & ParameterFlags.optional) != 0;
            if (optional)
                buf ~= '[';
            buf.append(a.name[], "=<", tn, '>');
            if (optional) buf ~= ']';
        }
        return tconcat(buf[]);
    }

private:
    Function _function;

    Array!String suggest_args(const(char)[] arg_prefix)
    {
        Array!String suggestions;
        if (_function.info.custom_suggest)
            suggestions = _function.info.custom_suggest(false, arg_prefix, null);
        foreach (ref arg; _function.info.parameters)
        {
            if (arg.flags & (ParameterFlags.positional_rest | ParameterFlags.named_rest))
                continue;
            if (arg.name[].startsWith(arg_prefix))
                suggestions ~= String(MutableString!0(Concat, arg.name, '=')); // TODO: MOVE construct!
        }
        return suggestions;
    }

    Array!String suggest_values(const(char)[] argument, const(char)[] value)
    {
        if (_function.info.custom_suggest)
        {
            Array!String suggestions = _function.info.custom_suggest(true, argument, value);
            if (suggestions.length > 0)
                return suggestions;
        }

        foreach (ref arg; _function.info.parameters)
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
