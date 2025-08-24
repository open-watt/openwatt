module manager.console.builtin_commands;

import urt.array;
import urt.mem;
import urt.string;
import urt.string.format : tconcat;
import urt.variant;

import manager.console;
import manager.console.command;
import manager.expression : NamedArgument;

nothrow @nogc:


class Scope : Command
{
nothrow @nogc:

    this(ref Console console, String scopeName, Command[] children...)
    {
        super(console, scopeName);
        commands ~= children;
    }

    Array!Command commands;

    bool addCommand(Command cmd)
    {
        assert(getCommand(cmd.name) is null, "Command already exists");
        commands ~= cmd;
        return true;
    }

    Command getCommand(const(char)[] name)
    {
        foreach (Command cmd; commands)
            if (cmd.name[] == name[])
                return cmd;
        return null;
    }

    override CommandState execute(Session session, const(Variant)[] args, const NamedArgument[] namedArgs)
    {
        // a lone `/` should only be possible for a root-scope command
        if (args.length > 0 && args[0].isString && args[0].asString == "/")
            args = args[1..$];

        // move to scope...
        if (args.length == 0)
        {
            session.curScope = this;
            return null;
        }

        if (!args[0].isString)
            assert(false, "TODO: the argument to a command must be an identifier? or are there other cases?");
        const(char)[] cmd = args[0].asString;

        // skip the path separator...
        if (cmd.frontIs('/'))
            cmd = cmd[1..$];

        // check for '..'
        if (cmd.frontIs(".."))
        {
            if (parent is null)
            {
                session.writeOutput("Error: '..' used at top level", true);
                return null;
            }
            return parent.execute(session, args[1..$], namedArgs);
        }

        // see if the identifier is a child...
        foreach (Command c; commands)
        {
            if (c.name[] == cmd[])
                return c.execute(session, args[1..$], namedArgs);
        }

        session.writeOutput(tconcat("Error: no command `", cmd[], "`"), true);
        return null;
    }

    override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            if (cmdLine.frontIs('/'))
                ++i;
            while (i < cmdLine.length && is_whitespace(cmdLine[i]))
                ++i;
            if (i < cmdLine.length && cmdLine[i] == '/')
                return MutableString!0(cmdLine);

            size_t j = i;
            while (j < cmdLine.length && !is_whitespace(cmdLine[j]) && cmdLine[j] != '/')
                ++j;

            if (j < cmdLine.length)
            {
                // cmd line is for child-command
                foreach (Command cmd; commands)
                {
                    if (cmd.name[] == cmdLine[i..j])
                        return cmd.complete(cmdLine[j..$]).insert(0, cmdLine[0..j]);
                }
                return MutableString!0(cmdLine);
            }

            // complete command name
            struct Cmd
            {
                const(char)[] name;
                bool isScope;
            }
            Array!Cmd cmds; // TODO: some static buffer would be nice!
//            if (this !is m_console.root)
//                cmds ~= Cmd("..", true);
            foreach (Command cmd; commands)
            {
                if (cmd.name.startsWith(cmdLine[i..j]))
                    cmds ~= Cmd(cmd.name[], cast(Scope)cmd !is null);
            }
            if (cmds.length == 0)
                return MutableString!0(cmdLine);
            if (cmds.length == 1)
                return complete(tconcat(cmdLine[0..i], cmds[0].name[], cmds[0].isScope && (i == 0 || cmdLine[0] == '/') ? '/' : ' '));
            size_t k = j-i;
            outer: for (; k < cmds[0].name.length; ++k)
            {
                for (size_t l = 1; l < cmds.length; ++l)
                    if (k >= cmds[l].name.length || cmds[l].name[k] != cmds[0].name[k])
                        break outer;
            }
            return MutableString!0().concat(cmdLine[0..i], cmds[0].name[0 .. k]);
        }
    }

    override Array!String suggest(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            while (i < cmdLine.length && !is_whitespace(cmdLine[i]) && cmdLine[i] != '/')
                ++i;

            if (i < cmdLine.length)
            {
                // cmd line is for child-command
                foreach (Command cmd; commands)
                {
                    if (cmd.name[] == cmdLine[0 .. i])
                    {
                        size_t j = i;
                        if (cast(Scope)cmd && j < cmdLine.length && cmdLine[j] == '/')
                            ++j;
                        while (j < cmdLine.length && is_whitespace(cmdLine[j]))
                            ++j;
                        return cmd.suggest(cmdLine[j..$]);
                    }
                }
                return Array!String();
            }

            Array!String r;
//            if (this !is m_console.root)
//                r ~= MutableString!0("..");
            foreach (Command cmd; commands)
            {
                if (cmd.name.startsWith(cmdLine))
                    r ~= cmd.name.makeString(defaultAllocator);
            }
            return r;
        }
    }
}



/+
class dcHelpCommand : public dcDebugCommand
{
public:
    dcHelpCommand(dcDebugConsole& console, const char* cmd)
    : dcDebugCommand(console, cmd)
{}

    dcCommandState* Execute(dcConsoleSession& session, bcStringView cmdLine) override
    {
        bcStringView args = cmdLine;
        bcStringView command = dcTakeFirstToken(args);

        if (command.IsEmpty())
        {
            session.WriteLine(Help(args));
            return nullptr;
        }

        // see if we can find the command
        bcString lowerCommand = dcToLower(bcString{ TempAllocator(), command.data(), uint32(command.size()) });
        auto it = m_console.m_commands.Find(lowerCommand);
        if (it == nullptr)
            session.WriteF("Unknown command: `%.*s`\n", int(command.size()), command.data());
        else
            session.WriteLine(it->val->Help(args));
        return nullptr;
    }

    bcVector<bcString> Suggest(bcStringView cmdLine) const override
    {
        bcVector<bcStringView> tokens = dcTokenizeCommandLine(cmdLine);

        // we can only suggest from the command set (first argument)
        if (tokens.Size() > 1 || (tokens.Size() == 1 && dcIsSeparator(cmdLine[cmdLine.Size() - 1])))
            return bcVector<bcString>(Allocator());

        // get command name suggestions
        return m_console.Suggest(!tokens.IsEmpty() ? tokens[0] : bcStringView());
    }

    bcString Help(bcStringView) const override
    {
        return bcString{ Allocator(), "Prints help text for debug console commands.\r\n"
                "Usage: `help COMMAND [OPTIONS...]`" };
    }
};

class dcExitCommand : public dcDebugCommand
{
public:
    dcExitCommand(dcDebugConsole& console, const char* cmd)
    : dcDebugCommand(console, cmd)
{}

    dcCommandState* Execute(dcConsoleSession& session, bcStringView) override
    {
        session.CloseSession();
        return nullptr;
    }

    bcString Help(bcStringView) const override
    {
        return bcString{ Allocator(), "Terminate the debug console session.\r\n"
                "Usage: `exit`" };
    }
};
+/


void RegisterBuiltinCommands(ref Console console)
{
//    console.RegisterCommand!ExitCommand("exit");
//    console.RegisterCommand!HelpCommand("help");
}
