module manager.console.command;

import manager;
import manager.console;
import manager.console.builtin_commands;
import manager.console.session;
import manager.expression : NamedArgument;

import urt.array;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.variant;


//version = ExcludeAutocomplete;
//version = ExcludeHelpText;


enum CommandCompletionState : ubyte
{
    InProgress,         ///< Command is still in progress
    CancelRequested,    ///< A cancel has been requested
    CancelPending,      ///< Waiting for cancellation to complete

    // These are finishing states, command will stop
    Finished,           ///< Command execution has finished
    Cancelled,          ///< Command was aborted for some reason
    Error,              ///< Command was aborted for some reason
    Timeout,            ///< Command was aborted for some reason
}

class CommandState
{
nothrow @nogc:

    Session session;
    Command command;
    CommandCompletionState state;

    this(Session session, Command command)
    {
        this.session = session;
        this.command = command;
    }

    CommandCompletionState update()
    {
        return CommandCompletionState.Finished;
    }
}

class Command
{
nothrow @nogc:

    const String name;

    this(ref Console console, String name) nothrow @nogc
    {
        m_console = &console;
        this.name = name.move;
    }

    final Application app() pure nothrow @nogc => m_console.appInstance;
    final ref Console console() pure nothrow @nogc => *m_console;

    abstract CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs);

    MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            MutableString!0 result = cmdLine;
            Array!String tokens = suggest(cmdLine);
            if (tokens.empty)
                return result;
            size_t lastToken = cmdLine.length;
            while (lastToken > 0 && !isSeparator(cmdLine[lastToken - 1]))
                --lastToken;
            result ~= getCompletionSuffix(cmdLine[lastToken .. cmdLine.length], tokens);
            return result;
        }
    }

    Array!String suggest(const(char)[] cmdLine)
        => Array!String();

    const(char)[] help(const(char)[] args) const
    {
        version (ExcludeHelpText)
            return "Help text unavailable in this build.";
        else
        {
            assert(false);
//            bcString help{ Allocator(), "No help available for command `" };
//            help.PushBack(m_command);
//            help.PushBack("`.");
//            return help;
            return String(null);
        }
    }


package:
    final NoGCAllocator allocator() => m_console.m_allocator;
    final NoGCAllocator tempAllocator() => m_console.m_tempAllocator;

    Console* m_console;
    Scope parent = null;
}


nothrow @nogc:

bool isValidIdentifier(const(char)[] s) pure
{
    if (s.length == 0)
        return false;
    if (!is_alpha(s[0]) && s[0] != '_')
        return false;
    foreach (char c; s[1..$])
    {
        if (!is_alpha_numeric(c) && c != '_')
            return false;
    }
    // TODO: should keywords be filtered?
    return true;
}

inout(char)[] takeIdentifier(ref inout(char)[] s) pure
{
    if (s.length == 0)
        return s[0..0];
    if (!is_alpha(s[0]) && s[0] != '-' && s[0] != '_')
        return s[0..0];
    size_t i = 1;
    for (; i < s.length; ++i)
    {
        if (!is_alpha_numeric(s[i]) && s[i] != '-' && s[i] != '_')
            break;
    }
    inout(char)[] r = s[0 .. i];
    s = s[i .. $];
    return r;
}

inout(char)[] trimCmdLine(inout(char)[] s) pure
{
    while(s.length > 0)
    {
        if (s[0] == '#')
            return s[$ .. $];
        if (is_whitespace(s[0]))
            s = s[1 .. $];
        else
            break;
    }
    return s;
}

bool frontIs(const(char)[] s, char c) pure
{
    return s.length > 0 && s[0] == c;
}

bool frontIs(const(char)[] s, const(char)[] s2) pure
{
    return s.length >= s2.length && s[0..s2.length] == s2[];
}
