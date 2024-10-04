module manager.console.session;

import manager.console;

import urt.array;
import urt.map;
import urt.mem;
import urt.string;
import urt.util;

class Session
{
nothrow @nogc:

	this(ref Console console)
	{
		m_console = &console;
		m_prompt = "> ";
		curScope = console.getRoot;
	}

	~this()
	{
		closeSession();
	}

	/// Update the session.
	/// This is called periodically from the session's console instances `Update()` method.
	void update()
	{
		if (m_currentCommand)
		{
			CommandCompletionState state = m_currentCommand.command.update(m_currentCommand);
			if (state == CommandCompletionState.Finished)
			{
				CommandState commandData = m_currentCommand;
				m_currentCommand = null;

				commandFinished(commandData, state);
				allocator.freeT(commandData);

				// untaken input should be fed back into the command line
				const(char)[] input = takeInput();
				receiveInput(input);
			}
		}
	}

	/// Test if the session is attached to a console instance. A detached session is effectively 'closed', and ready to be cleaned up.
	final bool isAttached() pure
		=> m_console != null;

	/// Close this session and detach from the bound console instance.
	void closeSession()
	{
		if (m_currentCommand)
		{
			allocator.freeT(m_currentCommand);
			m_currentCommand = null;
		}

		if (m_sessionStack.length)
			m_console = m_sessionStack.popBack();
		else
			m_console = null;
	}


	abstract void writeOutput(const(char)[] text, bool newline);

	pragma(inline, true) final void write(Args...)(ref Args args)
		if (Args.length == 1 && is(Args[0] : const(char)[]))
	{
		return writeOutput(args[0], false);
	}

	final void write(Args...)(ref Args args)
		if (Args.length != 1 || !is(Args[0] : const(char)[]))
	{
		import urt.string.format;

		char[1024] text;
		writeOutput(concat(text, args), false);
	}

	pragma(inline, true) final void writeLine(Args...)(ref Args args)
		if (Args.length == 1 && is(Args[0] : const(char)[]))
	{
		return writeOutput(args[0], true);
	}

	final void writeLine(Args...)(ref Args args)
		if (Args.length != 1 || !is(Args[0] : const(char)[]))
	{
		import urt.string.format;

		char[1024] text;
		writeOutput(concat(text, args, '\n'), false);
	}

	final void writef(Args...)(const(char)[] format, ref Args args)
	{
		import urt.string.format;

		char[1024] text;
		format(text, format, args).writeOutput;
	}

	bool showPrompt(bool show)
		=> m_showPrompt.swap(show);

	const(char)[] setPrompt(const(char)[] prompt)
		=> m_prompt.swap(prompt);

	// TODO: I don't like this API... needs work!
	final const(char[]) getInput()
		=> m_buffer;

	MutableString!0 setInput(const(char)[] text)
	{
		import core.lifetime : move;

		MutableString!0 old = m_buffer.move;
		m_buffer = null;
		m_position = 0;
		receiveInput(text);
		return old.move;
	}

	ptrdiff_t appendInput(const(char)[] text)
	{
		assert(m_console != null, "Session was closed!");
		assert(!m_currentCommand);

//		m_buffer.Reserve(m_buffer.Size() + text.Size());

		const(char)* t = text.ptr;
		size_t len = text.length;
		size_t i = 0;
		while (i < len)
		{
			size_t take = 1;

			// handle NVT commands...?
			if (t[i] == '\xff')
			{
				char opt = 0, cmd = t[++i];
				if (cmd >= '\xfb' && cmd <= '\xfe')
					opt = t[++i];

				// NVT command...
				// do we care about any of these?
//				BC_REF(opt);
			}
			else if (t[i] == '\x03')
			{
				// Ctrl-C
				closeSession();

				// store the tail of the input buffer so the outer context can claim it
				m_buffer = text[i + 1 .. $];
				return -1;
			}
			else if (t[i] == '\r' || t[i] == '\n')
			{
				return i;
			}
			else if (t[i] == '\b' || t[i] == '\x7f')
			{
				if (m_position > 0)
				{
					m_buffer = m_buffer[0 .. $-1];
					--m_position;
				}
			}
			else if (t[i] == '\t')
			{
				assert(false);
//				if (m_suggestionPending)
//				{
//					bcVector<bcString> suggestions = m_console->Suggest(m_buffer);
//					if (!suggestions.IsEmpty())
//						ShowSuggestions(suggestions);
//				}
//				else
//				{
//					bcString completeFrom(Allocator(), m_buffer.Data(), m_position);
//					bcString completed = m_console->Complete(completeFrom);
//					if (completed != completeFrom)
//					{
//						uint32 oldPos = m_position;
//						m_position = completed.Size();
//						completed.Append(m_buffer.Data() + oldPos, m_buffer.Size() - oldPos);
//						m_buffer = bcMove(completed);
//					}
//					else
//					{
//						m_suggestionPending = true;
//
//						// advance i` since we skip the bottom part of the loop
//						i += take;
//						continue;
//					}
//				}
			}
			else if (t[i] == '\x1b' && i + 1 < len && t[i + 1] == '[')
			{
				assert(false);
//				// ANSI sequences...
//				if (StartsWith(t + i, ANSI_DEL))
//				{
//					if (m_position < m_buffer.Size())
//						m_buffer.Erase(m_position, 1);
//					take = sizeof(ANSI_DEL) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_ARROW_UP))
//				{
//					if (m_historyCursor != m_history.begin())
//					{
//						if (m_historyCursor == m_history.end())
//							m_historyHead = bcMove(m_buffer);
//						m_historyCursor--;
//						m_buffer = *m_historyCursor;
//						m_position = m_buffer.Size();
//					}
//					take = sizeof(ANSI_ARROW_UP) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_ARROW_DOWN))
//				{
//					if (m_historyCursor != m_history.end())
//					{
//						m_historyCursor++;
//						if (m_historyCursor != m_history.end())
//							m_buffer = *m_historyCursor;
//						else
//						{
//							m_buffer = bcMove(m_historyHead);
//							m_historyHead.Clear();
//						}
//						m_position = m_buffer.Size();
//					}
//					take = sizeof(ANSI_ARROW_DOWN) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_ARROW_LEFT))
//				{
//					if (m_position > 0)
//						--m_position;
//					take = sizeof(ANSI_ARROW_LEFT) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_ARROW_RIGHT))
//				{
//					if (m_position < m_buffer.Size())
//						++m_position;
//					take = sizeof(ANSI_ARROW_RIGHT) - 1;
//				}
//				else if (StartsWith(t + i, "\x1b[1;5D")) // CTRL_LEFT
//				{
//					bool passedAny = false;
//					while (m_position > 0)
//					{
//						if (m_buffer[m_position - 1] == ' ' && passedAny)
//							break;
//						if (m_buffer[--m_position] != ' ')
//							passedAny = true;
//					}
//					take = sizeof("\x1b[1;5D") - 1;
//				}
//				else if (StartsWith(t + i, "\x1b[1;5C")) // CTRL_RIGHT
//				{
//					bool passedAny = false;
//					while (m_position < m_buffer.Size())
//					{
//						if (m_buffer[m_position] != ' ')
//							passedAny = true;
//						if (m_buffer[m_position++] == ' ' && passedAny)
//							break;
//					}
//					take = sizeof("\x1b[1;5C") - 1;
//				}
//				else if (StartsWith(t + i, ANSI_HOME1))
//				{
//					m_position = 0;
//					take = sizeof(ANSI_HOME1) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_HOME2) || StartsWith(t + i, ANSI_HOME3))
//				{
//					m_position = 0;
//					take = sizeof(ANSI_HOME2) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_END1))
//				{
//					m_position = m_buffer.Size();
//					take = sizeof(ANSI_END1) - 1;
//				}
//				else if (StartsWith(t + i, ANSI_END2) || StartsWith(t + i, ANSI_END3))
//				{
//					m_position = m_buffer.Size();
//					take = sizeof(ANSI_END2) - 1;
//				}
			}
			else
			{
				m_buffer.insert(m_position, t[i .. i + take]);
				m_position += take;
			}

			i += take;
			m_suggestionPending = false;
		}

		return len;
	}

	MutableString!0 takeInput()
	{
		import core.lifetime : move;

		MutableString!0 take = m_buffer.move;
		m_buffer = null;
		m_position = 0;
		return take.move;
	}


	/// \returns The width of the terminal in characters.
	final uint width() => m_width;

	/// \returns The height of the terminal in characters.
	final uint height() => m_height;

	/// Set the size of the console. Some session types may not support this feature.
	void setConsoleSize(uint width, uint height)
	{
		m_width = width;
		m_height = height;
	}

protected:
	/// Called immediately before console commands are executed.
	/// It may be used, for instance, to update any visual state required by the session on execution of a command.
	/// \param command
	///  The complete command line being executed.
	void enterCommand(const(char)[] command)
	{
	}

	/// Called immediately after console commands complete, or are aborted.
	/// It may be used, for instance, to update any visual state required by the session on completion of a command.
	/// \param commandData
	///  The command state for the completing command.
	/// \param state
	///  The completion state of the command. This can determine if the command completed, or was aborted.
	void commandFinished(CommandState commandState, CommandCompletionState state)
	{
	}

	/// Called when suggestions should be presented to the user.
	/// Session implementations may implement this method to customise how to display the suggestions. For instance, show
	/// a tooltip that the user can select from, etc. Default implementation will write the suggestions to the output stream.
	/// \param suggestions
	///  Set of suggestion that apply to the current context
	void showSuggestions(const(String)[] suggestions)
	{
		assert(false);
//		uint32 max = 0;
//		for (auto& s : suggestions)
//			max = max < s.Size() ? s.Size() : max;
//
//		bcString text{ TempAllocator() };
//		uint32 lineOffset = 0;
//		for (auto& s : suggestions)
//		{
//			if (lineOffset + max + 3 > GetWidth())
//			{
//				text.Append("\r\n");
//				lineOffset = 0;
//			}
//			text.AppendFormat("   %-*s", (int)max, s.Data());
//			lineOffset += max + 3;
//		}
//
//		WriteLine(text);
	}

	final void receiveInput(const(char)[] input)
	{
		if (m_currentCommand)
			m_buffer ~= input;

		MutableString!0 inputBackup;
		while (!m_currentCommand && !input.empty)
		{
			ptrdiff_t taken = appendInput(input);

			if (taken < 0)
			{
				// session was termianted...
				return;
			}
			else if (taken < input.length)
			{
				assert(input[taken] == '\r' || input[taken] == '\n', "Should only be here when user presses enter?");

				// consume following '\n'??
				if (input[taken] == '\r' && taken + 1 < input.length && input[taken + 1] == '\n')
					++taken;

				MutableString!0 cmdInput = takeInput();
				const(char)[] command = cmdInput.trimCmdLine;
				m_buffer = input[taken + 1 .. $];

				if (command.empty || execute(command))
				{
					// possible the command terminated the session
					if (!isAttached())
						return;

					// command was instantaneous; take leftover input and continue
					inputBackup = takeInput();
					input = inputBackup[];
				}
			}
			else
				break;
		}
	}

package:
    // Internal stuff...
    final NoGCAllocator allocator() pure
        => m_console.m_allocator;
    final NoGCAllocator tempAllocator() pure
        => m_console.m_tempAllocator;

	final bool execute(const(char)[] command)
	{
		// TODO: command history!
//		AddToHistory(command);
//		m_historyHead.Clear();

		enterCommand(command);

		m_currentCommand = m_console.execute(this, command);

		// possible the command terminated the session
		if (!isAttached())
		{
			assert(m_currentCommand is null);
			return true;
		}

		if (!m_currentCommand)
			commandFinished(null, CommandCompletionState.Finished);
		return m_currentCommand is null;
	}

	final void addToHistory(String line)
	{
		assert(false);
//		if (!line.IsEmpty() && (m_history.empty() || line != m_history.back()))
//		{
//			m_history.push_back(line);
//			if (m_history.size() > 50)
//				m_history.pop_front();
//		}
//		m_historyCursor = m_history.end();
	}


	Console* m_console;
	CommandState m_currentCommand = null;

	Scope curScope = null;
	// TODO: remove the GC, swap for container!!
	Map!(String, String) localVariables;

	uint m_width = 80;
	uint m_height = 24;

	bool m_showPrompt = true;
	bool m_suggestionPending = false;

	const(char)[] m_prompt;
	MutableString!0 m_buffer;
	uint m_position = 0;

//	list<String> m_history;
//	list<String>::iterator m_historyCursor;
	const(char)[][] m_history;
	uint m_historyCursor = 0;
	const(char)[] m_historyHead;

	Array!(Console*) m_sessionStack;

protected:
	final CommandState _currentCommand() => m_currentCommand;
	final const(char)[] _prompt() => m_prompt;
	final const(char)[] _buffer() => m_buffer;
	final uint _position() => m_position;
	final bool _showPrompt() => m_showPrompt;
	final bool _suggestionPending() => m_suggestionPending;
}

class StringSession : Session
{
nothrow @nogc:

	this(ref Console console)
	{
		super(console);
	}

	const(char[]) getOutput() const pure
	{
		return m_output;
	}

	MutableString!0 takeOutput()
	{
		return m_output.move;
	}

	void clearOutput()
	{
		m_output = null;
	}

	override void writeOutput(const(char)[] text, bool newline)
	{
		if (newline)
			m_output.concat(text, '\n');
		else
			m_output ~= text;
	}

private:
	MutableString!0 m_output;
}

class ConsoleSession : Session
{
nothrow @nogc:

	this(ref Console console)
	{
		super(console);
	}

	override void writeOutput(const(char)[] text, bool newline)
	{
		import urt.io;
		if (newline)
			write(text);
		else
			writeln(text);
	}
}
