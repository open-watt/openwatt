module manager.console.builtin_commands;

import manager.console;
import manager.console.command;
import manager.console.expression;

import urt.string;


class Scope : Command
{
	this(ref Console console, String scopeName, Command[] children...)
	{
		super(console, scopeName);
		commands ~= children;
	}

	Command[] commands;

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

class Collection : Scope
{
	enum Features : ubyte
	{
		AddRemove = 1,
		SetUnset = 2,
		EnableDisable = 4,
		Print = 8,
		Comment = 16
	}

	Session session;

	this(ref Console console, String name, Features features, Command[] additionalCommands...)
	{
		Command[8] subCmds;
		size_t numSubCmds = 0;

		if (features & Features.AddRemove)
		{
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"add", this);
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"remove", this);
		}
		if (features & Features.SetUnset)
		{
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"set", this);
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"unset", this);
		}
		if (features & Features.EnableDisable)
		{
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"enable", this);
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"disable", this);
		}
		if (features & Features.Print)
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"print", this);
		if (features & Features.Comment)
			subCmds[numSubCmds++] = new SubCommand(console, StringLit!"comment", this);

		super(console, name, subCmds[0 .. numSubCmds]);

		foreach (c; additionalCommands)
			addCommand(c);
	}

	void add(KVP[] params)
	{
		assert(false, "Not implemented");
	}

	void remove(const(char)[] item)
	{
		assert(false, "Not implemented");
	}

	void set(const(char)[] item, KVP[] params)
	{
		assert(false, "Not implemented");
	}

	void unset(const(char)[] item, const(char)[][] params)
	{
		assert(false, "Not implemented");
	}

	void enable(const(char)[] item)
	{
		assert(false, "Not implemented");
	}

	void disable(const(char)[] item)
	{
		assert(false, "Not implemented");
	}

	void print(KVP[] params)
	{
		assert(false, "Not implemented");
	}

	void comment(const(char)[] item, KVP[] params)
	{
		assert(false, "Not implemented");
	}

	const(char)[][] getItems()
	{
		return null;
	}

	CommandState execute(Session session, const(char)[] command, const(char)[] cmdLine)
	{
		import urt.mem.scratchpad;
		import urt.mem.region;

		void[] scratch = allocScratchpad();
		scope(exit) freeScratchpad(scratch);

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

		this.session = session;

		switch (command)
		{
			case "add":
				add(params[0 .. numParams]);
				break;
			case "remove":
				if (numParams != 1)
					session.writeLine("Error: expected 1 parameter");
				else if (params[0].v.type != Token.Type.None)
					session.writeLine("Error: expected identifier");
				else
					remove(params[0].v.token);
				break;
			case "set":
				if (numParams < 1)
					session.writeLine("Error: expected at least 1 parameter");
				else if (params[0].v.type != Token.Type.None)
					session.writeLine("Error: expected identifier");
				else
					set(params[0].v.token, params[1 .. numParams]);
				break;
			case "unset":
				if (numParams < 1)
					session.writeLine("Error: expected at least 1 parameter");
				else
				{
					const(char)[][] keys = region.allocArray!(const(char)[])(numParams - 1);
					for (size_t i = 0; i < numParams; ++i)
					{
						if (params[i].v.type != Token.Type.None)
						{
							session.writeLine("Error: expected identifier");
							goto unset_fail;
						}
						if (i > 0)
							keys[i-1] = params[i].k.token;
					}
					unset(params[0].k.token, keys);
				}
			unset_fail:
				break;
			case "enable":
				if (numParams != 1)
					session.writeLine("Error: expected 1 parameter");
				else if (params[0].v.type != Token.Type.None)
					session.writeLine("Error: expected identifier");
				else
					enable(params[0].v.token);
				break;
			case "disable":
				if (numParams != 1)
					session.writeLine("Error: expected 1 parameter");
				else if (params[0].v.type != Token.Type.None)
					session.writeLine("Error: expected identifier");
				else
					disable(params[0].v.token);
				break;
			case "print":
				print(params[0 .. numParams]);
				break;
			case "comment":
				if (numParams < 1)
					session.writeLine("Error: expected at least 1 parameter");
				else if (params[0].v.type != Token.Type.None)
					session.writeLine("Error: expected identifier");
				else
					comment(params[0].v.token, params[1 .. numParams]);
				break;
			default:
				assert(false, "Error: unknown command");
		}

		this.session = null;

		return null;
	}

	version (ExcludeAutocomplete) {} else
	{
		String complete(const(char)[] command, const(char)[] cmdLine) const
		{
			assert(false);
			return String(null);
		}

		String[] suggest(const(char)[] command, const(char)[] cmdLine) const
		{
			return null;
		}
	}

	version (ExcludeHelpText) {} else
	{
		const(char)[] help(const(char)[] command, const(char)[] args) const
		{
			assert(false);
			return String(null);
		}
	}

private:
	static class SubCommand : Command
	{
		Collection collection;

		this(ref Console console, String name, Collection collection)
		{
			super(console, name);
			this.collection = collection;
		}

		override CommandState execute(Session session, const(char)[] cmdLine)
		{
			return collection.execute(session, name[], cmdLine);
		}

		version (ExcludeAutocomplete) {} else
		{
			override String complete(const(char)[] cmdLine) const
			{
				return collection.complete(name[], cmdLine);
			}

			override String[] suggest(const(char)[] cmdLine) const
			{
				return collection.suggest(name[], cmdLine);
			}
		}

		version (ExcludeHelpText) {} else
		{
			override const(char)[] help(const(char)[] args) const
			{
				return collection.help(name[], args);
			}
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
//    console.RegisterCommand!ExitCommand("exit");
//    console.RegisterCommand!HelpCommand("help");
//    console.RegisterCommand!EnterCommand("enter");
}
