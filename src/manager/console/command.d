module manager.console.command;

import manager.instance;
import manager.console;
import manager.console.builtin_commands;
import manager.console.session;

import urt.mem;
import urt.meta.nullable;
import urt.string;


//version = ExcludeAutocomplete;
//version = ExcludeHelpText;


enum CommandCompletionState : ubyte
{
	InProgress, ///< Command is still in progress
	Finished,   ///< Command execution has finished
	Cancelled,  ///< Command was aborted for some reason
}

class CommandState
{
	Console* manager;
	Command command;
	bool cancelPending = false;
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

	final ApplicationInstance appInstance() pure nothrow @nogc => m_console.appInstance;

	abstract CommandState execute(Session session, const(char)[] cmdLine);

	CommandCompletionState update(CommandState data)
	{
		return CommandCompletionState.Finished;
	}

	String complete(const(char)[] cmdLine) const
	{
		version (ExcludeAutocomplete)
			return null;
		else
		{
			assert(false);
//			bcVector<bcString> tokens = Suggest({ cmdLine.Data(), cmdLine.Size() });
//			if (tokens.IsEmpty())
//				return cmdLine;
//			uint32 lastToken = cmdLine.Size();
//			while (lastToken > 0 && !dcIsSeparator(cmdLine[lastToken - 1]))
//				--lastToken;
//			cmdLine.PushBack(dcGetCompletionSuffix({ cmdLine.Data() + lastToken, cmdLine.Size() - lastToken }, tokens).Data());
//			return cmdLine;
			return String(null);
		}
	}


	String[] suggest(const(char)[] cmdLine) const => null;

	const(char)[] help(const(char)[] args) const
	{
		version (ExcludeHelpText)
			return "Help text unavailable in this build.";
		else
		{
			assert(false);
//			bcString help{ Allocator(), "No help available for command `" };
//			help.PushBack(m_command);
//			help.PushBack("`.");
//			return help;
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
	if (!isAlpha(s[0]) && s[0] != '_')
		return false;
	foreach (char c; s[1..$])
	{
		if (!isAlphaNumeric(c) && c != '_')
			return false;
	}
	// TODO: should keywords be filtered?
	return true;
}

inout(char)[] takeIdentifier(ref inout(char)[] s) pure
{
	if (s.length == 0)
		return s[0..0];
	if (!isAlpha(s[0]) && s[0] != '-' && s[0] != '_')
		return s[0..0];
	size_t i = 1;
	for (; i < s.length; ++i)
	{
		if (!isAlphaNumeric(s[i]) && s[i] != '-' && s[i] != '_')
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
		if (isWhitespace(s[0]))
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
