module manager.console.session;

import manager.console;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.string;
import urt.string.ansi;
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
            CommandCompletionState state = m_currentCommand.update();
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

    final void write(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        char[1024] text;
        writeOutput(concat(text, forward!args), false);
    }

    pragma(inline, true) final void writeLine(Args...)(auto ref Args args)
        if (Args.length == 1 && is(Args[0] : const(char)[]))
    {
        return writeOutput(args[0], true);
    }

    final void writeLine(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        writeOutput(tconcat(forward!args), true);
    }

    final void writef(Args...)(const(char)[] format, auto ref Args args)
    {
        import urt.string.format;

        writeOutput(tformat(format, forward!args), false);
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

        assert(m_buffer.length + text.length <= MaxStringLen, "Exceeds max string length");
        m_buffer.reserve(cast(ushort)(m_buffer.length + text.length));

        const(char)* t = text.ptr;
        size_t len = text.length;
        size_t i = 0;
        while (i < len)
        {
            size_t take = 1;

            if (t[i] == '\x03')
            {
                i += 1;
                goto close_session;
            }
            else if (t[i] == '\r' || t[i] == '\n')
            {
                return i;
            }
            else if (t[i] == '\b' || t[i] == '\x7f')
            {
            erase_char:
                if (m_position > 0)
                    m_buffer.erase(--m_position, 1);
            }
            else if (t[i] == '\t')
            {
                if (m_suggestionPending)
                {
                    Array!(MutableString!0) suggestions = m_console.suggest(m_buffer, curScope);
                    if (!suggestions.empty)
                        showSuggestions(cast(String[])suggestions[]); // HACK: this is a brutal cast!!
                }
                else
                {
                    const(char)[] completeFrom = m_buffer[0 .. m_position];
                    MutableString!0 completed = m_console.complete(completeFrom, curScope);
                    if (completed[] != completeFrom[])
                    {
                        uint oldPos = m_position;
                        m_position = cast(uint)completed.length;
                        completed ~= m_buffer[oldPos .. $];
                        m_buffer = completed.move;
                    }
                    else
                    {
                        m_suggestionPending = true;

                        // advance i since we skip the bottom part of the loop
                        i += take;
                        continue;
                    }
                }
            }
            else if (t[i] == '\xff')
            {
                // NVT commands...
                if (i >= len - 1)
                    goto early_return;

                take = 2;
                char cmd = t[i + 1];

                switch (cmd)
                {
                    case '\xf1': // NOP (No Operation)
                        break;
                    case '\xf2': // DM (Data Mark)
                        // Used to mark the position in the data stream where a Telnet break or interruption occurred.
                        break;
                    case '\xf3': // BRK (Break)
                        // Signals that the sender has initiated a break (interrupt) signal.
                        // should probable terminate latent commands...?
                        break;
                    case '\xf4': // IP (Interrupt Process)
                        // Used to interrupt the process running on the remote system.
                        // should probable terminate latent commands...?
                        break;
                    case '\xf5': // AO (Abort Output)
                        // Commands the remote system to stop sending output but allows the process to continue running.
                        break;
                    case '\xf6': // AYT (Are You There)
                        // Used to check if the remote server is still connected and responding.
                        break;
                    case '\xf7': // EC (Erase Character)
                        // Sent to instruct the remote system to erase the last character sent.
                        goto erase_char;
                    case '\xf8': // EL (Erase Line)
                        // Instructs the remote system to erase the entire current line of input.
                        m_buffer.clear();
                        m_position = 0;
                        break;
                    case '\xf9': // GA (Go Ahead)
                        // A command used to indicate that the sender is finished, and the receiver may start sending data. This is primarily used in "line-at-a-time" mode.
                        break;
                    case '\xfa':
                        size_t subNvt = i + 2;
                        while (subNvt < len - 1 && t[subNvt] != '\xff' && t[subNvt + 1] != '\xf0')
                            ++subNvt;
                        if (subNvt >= len - 1)
                        {
                            // this subnegotiation wasn't closed. we must have an incomplete stream...
                            goto early_return;
                        }

                        take = subNvt + 2 - i;
                        const(char)[] sub = t[i + 2 .. subNvt];

                        if (sub.length > 0)
                        {
                            switch (sub[0])
                            {
                                case '\x1f': // WINDOW SIZE
                                    if (sub.length == 5)
                                    {
                                        m_width = cast(uint)sub[1] << 8 | (cast(uint)sub[2]);
                                        m_height = cast(uint)sub[3] << 8 | (cast(uint)sub[4]);
                                    }
                                    break;
                                case '\x2a': // CHARSET
                                    assert(false, "test this path");
                                    break;
                                default:
                                    writeWarningf("Unsupported NVT subnegotiation: \\\\x{0, 02x}", cast(ubyte)sub[0]);
                                    break;
                            }
                        }
                        break;
                    case '\xfb': // WILL
                    case '\xfc': // WON'T
                    case '\xfd': // DO
                    case '\xfe': // DON'T
                        if (i >= len - 2)
                            goto early_return;

                        // ECHO              = 1 (0x01)
                        // SUPPRESS GO-AHEAD = 3 (0x03)
                        // STATUS            = 5 (0x05)
                        // TIMING MARK       = 6 (0x06)
                        // TERMINAL TYPE     = 24 (0x18)
                        // WINDOW SIZE       = 31 (0x1f)
                        // CHARSET           = 42 (0x2a)

                        take = 3;
                        ubyte opt = t[i + 2];

                        final switch (cmd)
                        {
                            case '\xfb': // WILL
                                // This command is sent to indicate that the sender wishes to enable an option. It is typically followed by a byte that specifies which option the sender wants to enable.
                                if (opt == 0x2a)
                                {
                                    assert(false, "this was never tested! not clear if we should transmit the space or not?");
                                    // client has agreed to negotiate character set; we'll request UTF8...
                                    write("\xff\xfa\x2a\x01 UTF-8\xff\xf0");
                                }
                                debug writeDebugf("Telnet: WILL {0}", cast(ubyte)opt);
                                break;
                            case '\xfc': // WON'T
                                // Sent to indicate that the sender refuses to enable an option.
                                debug writeDebugf("Telnet: WON'T {0}", cast(ubyte)opt);
                                break;
                            case '\xfd': // DO
                                // This command is sent to indicate that the sender requests the receiver to enable an option.
                                debug writeDebugf("Telnet: DO {0}", cast(ubyte)opt);
                                break;
                            case '\xfe': // DON'T
                                // Sent to indicate that the sender requests the receiver to disable an option.
                                debug writeDebugf("Telnet: DON'T {0}", cast(ubyte)opt);
                                break;
                        }
                        break;
                    case '\xff': // QUIT
                        // This command indicates that the sender wants to close the Telnet connection.
                        i += 2;
                        goto close_session;
                    default:
                        // surprise NVT command?
                        writeWarningf("Unknown NVT command: \\\\x{0, 02x}", cast(ubyte)cmd);
                        break;
                }
            }
            else if (size_t ansiLen = parseANSICode(t[i .. len]))
            {
                const(char)[] seq = t[i .. i + ansiLen];
                take = ansiLen;

                // ANSI sequences...
                if (seq[] == ANSI_DEL)
                {
                    if (m_position < m_buffer.length)
                        m_buffer.erase(m_position, 1);
                }
                else if (seq[] == ANSI_ARROW_UP)
                {
                    if (m_historyCursor > 0)
                    {
                        if (m_historyCursor == m_history.length)
                            m_historyHead = m_buffer.move;
                        m_historyCursor--;
                        m_buffer = m_history[m_historyCursor][];
                        m_position = cast(uint)m_buffer.length;
                    }
                }
                else if (seq[] == ANSI_ARROW_DOWN)
                {
                    if (m_historyCursor < m_history.length)
                    {
                        m_historyCursor++;
                        if (m_historyCursor != m_history.length)
                            m_buffer = m_history[m_historyCursor];
                        else
                        {
                            m_buffer = m_historyHead.move;
                            m_historyHead.clear();
                        }
                        m_position = cast(uint)m_buffer.length;
                    }
                }
                else if (seq[] == ANSI_ARROW_LEFT)
                {
                    if (m_position > 0)
                        --m_position;
                }
                else if (seq[] == ANSI_ARROW_RIGHT)
                {
                    if (m_position < m_buffer.length)
                        ++m_position;
                }
                else if (seq[] == "\x1b[1;5D" || seq[] == "\x1bOD") // CTRL_LEFT
                {
                    bool passedAny = false;
                    while (m_position > 0)
                    {
                        if (m_buffer[m_position - 1] == ' ' && passedAny)
                            break;
                        if (m_buffer[--m_position] != ' ')
                            passedAny = true;
                    }
                }
                else if (seq[] == "\x1b[1;5C" || seq[] == "\x1bOC") // CTRL_RIGHT
                {
                    bool passedAny = false;
                    while (m_position < m_buffer.length)
                    {
                        if (m_buffer[m_position] != ' ')
                            passedAny = true;
                        if (m_buffer[m_position++] == ' ' && passedAny)
                            break;
                    }
                }
                else if (seq[] == ANSI_HOME1)
                {
                    m_position = 0;
                }
                else if (seq[] == ANSI_HOME2 || seq[] == ANSI_HOME3)
                {
                    m_position = 0;
                }
                else if (seq[] == ANSI_END1)
                {
                    m_position = cast(uint)m_buffer.length;
                }
                else if (seq[] == ANSI_END2 || seq[] == ANSI_END3)
                {
                    m_position = cast(uint)m_buffer.length;
                }
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

    close_session:
        // Ctrl-C
        closeSession();

    early_return:
        // store the tail of the input buffer so the outer context can claim it
        m_buffer = text[i .. $];
        return -1;
    }

    MutableString!0 takeInput()
    {
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
        size_t max = 0;
        foreach (ref s; suggestions)
            max = max < s.length ? s.length : max;

        MutableString!0 text;
        size_t lineOffset = 0;
        foreach (ref s; suggestions)
        {
            if (lineOffset + max + 3 > m_width)
            {
                text ~= "\r\n";
                lineOffset = 0;
            }
            text.appendFormat("   {0, *1}", s[], max);
            lineOffset += max + 3;
        }

        writeLine(text);
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
                if (input[taken] == '\r' && taken + 1 < input.length && (input[taken + 1] == '\n' || input[taken + 1] == '\0'))
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

protected:

    final NoGCAllocator allocator() pure
        => m_console.m_allocator;
    final NoGCAllocator tempAllocator() pure
        => m_console.m_tempAllocator;

    final bool execute(const(char)[] command)
    {
        // TODO: command history!
        addToHistory(command);
        m_historyHead.clear();

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

    final void addToHistory(const(char)[] line)
    {
        if (!line.empty && (m_history.empty || line[] != m_history[$-1]))
        {
            m_history.pushBack(MutableString!0(line));
            if (m_history.length > 50)
                m_history.popFront();
        }
        m_historyCursor = cast(uint)m_history.length;
    }


    CommandState m_currentCommand = null;

    Map!(String, String) localVariables;

    uint m_width = 80;
    uint m_height = 24;

    bool m_showPrompt = true;
    bool m_suggestionPending = false;

    const(char)[] m_prompt;
    MutableString!0 m_buffer;
    uint m_position = 0;

//    list<String> m_history;
//    list<String>::iterator m_historyCursor;
    // TODO: swap to SharedString, and also swap to List
    Array!(MutableString!0) m_history;
    uint m_historyCursor = 0;
    MutableString!0 m_historyHead;

    Array!(Console*) m_sessionStack;

package:

    Console* m_console;
    Scope curScope = null;

    final ref auto _currentCommand() => m_currentCommand;
    final ref auto _prompt() => m_prompt;
    final ref auto _buffer() => m_buffer;
    final ref auto _position() => m_position;
    final ref auto _showPrompt() => m_showPrompt;
    final ref auto _suggestionPending() => m_suggestionPending;
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
