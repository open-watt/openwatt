module manager.console.builtin_commands;

import urt.array;
import urt.mem;
import urt.string;

import manager.console;
import manager.console.command;
import manager.console.expression;

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

	override CommandState execute(Session session, const(char)[] cmdLine)
	{
		cmdLine = cmdLine.trimCmdLine;
		if (cmdLine.frontIs('/'))
			cmdLine = cmdLine[1..$].trimCmdLine;

		// move to scope...
		if (cmdLine.length == 0)
		{
			session.curScope = this;
			return null;
		}

		// check for '..'
		if (cmdLine.frontIs(".."))
		{
			if (cmdLine.length == 2 || (cmdLine.length > 2 && isWhitespace(cmdLine[2]) || cmdLine[2] == '/' || cmdLine[2] == '#'))
			{
				if (parent is null)
				{
					session.writeOutput("Error: '..' used at top level", true);
					return null;
				}
				return parent.execute(session, cmdLine[2..$]);
			}
		}

		// take next identifier and see if it's a child...
		const(char)[] identifier = cmdLine.takeIdentifier;

		if (identifier.empty)
		{
			session.writeOutput("Error: expected identifier", true);
			return null;
		}

		foreach (Command cmd; commands)
		{
			if (cmd.name[] == identifier[])
				return cmd.execute(session, cmdLine);
		}

		session.writeOutput("Error: no command ``", true);
		return null;
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

class dcEnterCommand : public dcDebugCommand
{
public:
	dcEnterCommand(dcDebugConsole& console, const char* cmd)
	: dcDebugCommand(console, cmd)
{}

	dcCommandState* Execute(dcConsoleSession& session, bcStringView cmdLine) override
	{
		bcStringView args = cmdLine;
		bcStringView arg = dcTakeFirstToken(args);

		if (arg.IsEmpty())
		{
			session.WriteLine(Help(args));
			return nullptr;
		}

		// see if we can find the console
		dcDebugConsole* toEnter = dcDebugConsole::FindConsole(arg);
		if (!toEnter)
		{
			session.WriteF("No console: `%.*s`\n", int(arg.size()), arg.data());
			return nullptr;
		}

		session.m_sessionStack.PushBack(session.m_console);
		session.m_console = toEnter;

		return nullptr;
	}

	bcVector<bcString> Suggest(bcStringView cmdLine) const override
	{
		bcVector<bcStringView> tokens = dcTokenizeCommandLine(cmdLine);

		// only accepts one argument
		if (tokens.Size() > 1 || (tokens.Size() == 1 && dcIsSeparator(cmdLine[cmdLine.Size() - 1])))
			return bcVector<bcString>(Allocator());

		// get command name suggestions
		bcVector<bcString> consoles(Allocator());
		// TODO: this is not threadsafe! adding/removing/iterating console instances should be mutex guarded
		for (dcDebugConsole* console = dcDebugConsole::s_consoleInstances; console != nullptr; console = console->m_nextConsoleInstance)
			consoles.PushBack(bcString{ Allocator(), console->m_identifier });
		return consoles;
	}

	bcString Help(bcStringView) const override
	{
		return bcString{ Allocator(), "Enter a named terminal session.\r\n"
				"Usage: `enter IDENTIFIER`" };
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
//	console.RegisterCommand!ExitCommand("exit");
//	console.RegisterCommand!HelpCommand("help");
//	console.RegisterCommand!EnterCommand("enter");
}
