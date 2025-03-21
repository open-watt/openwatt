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
import urt.file;
import urt.result;


enum ClientFeatures : ushort
{
    None = 0,

    CRLF = 1 << 1,          // Client recognises CR-LF for newline
    LineMode = 1 << 2,      // Client uses line-mode
    Escape = 1 << 3,        // Client can parse control sequences
    Cursor = 1 << 4,        // Client supports cursor movement
    Format = 1 << 5,        // Client supports screen formatting
    TextAttrs = 1 << 6,     // Client supports text attributes
    Gfx = 1 << 7,           // Client supports graphics
    BasicColour = 1 << 8,   // Client supports color
    FullColour = 1 << 9,    // Client supports full color
    Resize = 1 << 10,       // Client supports terminal resizing
    Mouse = 1 << 11,        // Client supports mouse events
    UTF8 = 1 << 12,         // Client supports UTF-8

    NVT = CRLF,
    VT100 = Escape | Cursor | Format | TextAttrs | Gfx,
    ANSI = Escape | Cursor | Format | TextAttrs | BasicColour | UTF8,
    XTERM = ANSI | Gfx | FullColour | Mouse | Resize | UTF8,
    Windows = CRLF | Cursor | Format | TextAttrs | BasicColour | Resize | UTF8,
}

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
            if (state >= CommandCompletionState.Finished)
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

        // TODO: well, actually, the current command should receive this input, and ^C should cancel the command
        assert(!m_currentCommand);

        assert(m_buffer.length + text.length <= MaxStringLen, "Exceeds max string length");
        m_buffer.reserve(cast(ushort)(m_buffer.length + text.length));

        const(char)* t = text.ptr;
        size_t len = text.length;
        size_t i = 0;
        while (i < len)
        {
            size_t take = 1;

            if (t[i] == '\x7f')
                goto erase_char;
            if (size_t ansiLen = parseANSICode(t[i .. len]))
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
            else if (t[i] < '\x20')
            {
                if (t[i] == '\x03')
                {
                    i += 1;
                    goto close_session;
                }
                else if (t[i] == '\r')
                {
                    return i;
                }
                else if (t[i] == '\b')
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
                else if (t[i] == '\a')
                {
                    i += 1;
                    doBell();
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
    final ushort width() => m_width;

    /// \returns The height of the terminal in characters.
    final ushort height() => m_height;

    /// Set the size of the console. Some session types may not support this feature.
    void setConsoleSize(ushort width, ushort height)
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
                text ~= (features & ClientFeatures.CRLF) ? "\r\n" : "\n";
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
                assert(input[taken] == '\r', "Should only be here when user presses enter?");

//                // TODO: what about not-telnet?
//                //       consume following '\n'?? do enter keypresses expect a '\n'? maybe ClientFeatures.CRLF?
//                if (taken + 1 < input.length && (input[taken + 1] == '\n'))
//                    ++taken;

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

    void doBell()
    {
        // TODO: anything to handle BEEP?
    }

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

            if (m_historyFile.is_open)
            {
                static bool WriteToFile(char[] text, ref File file) {
                    size_t bytesWritten;
                    Result result = file.write(text, bytesWritten);
                    if (result.succeeded && bytesWritten == text.length)
                        return true;

                    writeError("Error writing session history.");
                    return false;
                };

                m_historyFile.set_pos(0);
                size_t totalSize;
                bool success = true;
                foreach (entry; m_history)
                {
                    success = WriteToFile(entry, m_historyFile);
                    if (!success)
                        break;

                    totalSize += entry.length;

                    success = WriteToFile(cast(char[])"\n", m_historyFile);
                    if (!success)
                        break;

                    totalSize += 1;
                }

                if (success)
                    m_historyFile.set_size(totalSize);
                else
                    m_historyFile.close();
            }
        }
        m_historyCursor = cast(uint)m_history.length;
    }


    ClientFeatures features;
    ushort m_width = 80;
    ushort m_height = 24;
    char escapeChar;

    bool m_showPrompt = true;
    bool m_suggestionPending = false;

    const(char)[] m_prompt;
    MutableString!0 m_buffer;
    uint m_position = 0;

    CommandState m_currentCommand = null;

    Map!(String, String) localVariables;

//    list<String> m_history;
//    list<String>::iterator m_historyCursor;
    // TODO: swap to SharedString, and also swap to List
    Array!(MutableString!0) m_history;
    uint m_historyCursor = 0;
    MutableString!0 m_historyHead;
    File m_historyFile;

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

class SerialSession : Session
{
    import router.stream;
nothrow @nogc:

    this(ref Console console, Stream stream, ClientFeatures features = ClientFeatures.ANSI, ushort width = 80, ushort height = 24)
    {
        super(console);
        features |= features;
        m_stream = stream;
        m_width = width;
        m_height = height;
    }

    override void update()
    {
        enum DefaultBufferLen = 512;
        char[DefaultBufferLen] recvbuf = void;

        Array!(char, 0) input; // TODO: add a generous stack buffer

        ptrdiff_t read;
        do
        {
            read = m_stream.read(recvbuf[]);
            if (read < 0)
            {
                closeSession();
                return;
            }
            else if (read == 0)
                break;

            // TODO: process the stream for CRLF, or for null, or for any other things we gotta handle?
            input.reserve(input.length + read);
            for (size_t i = 0; i < read; ++i)
            {
                char c = cast(char)recvbuf[i];
                if (c == '\r')
                {
                    if (features & ClientFeatures.CRLF)
                    {
                        if (i == read - 1)
                        {
                            // TODO: buffer this byte for later... it might have been a split transmission
                            //       if it's the end of transmission, we'll ignore it
                            //       otherwise if it's alone, it's probably intentional and we should pass it through...
                            assert(false);
                        }
                        if (recvbuf[i + 1] == '\n')
                        {
                            c = '\n';
                            ++i;
                        }
                        else
                        {
                            // I think '\r' alone is from an enter keypress...?
                            assert(false);
                        }
                    }
                }
                else if (c == '\0')
                {
                    // TODO: do we ignore null, or treat it as a newline?
//                    c = '\n';
                    continue;
                }

                input ~= c;
            }
        }
        while (read == recvbuf.length);

        if (!input.empty)
            receiveInput(input[]);

        super.update();
    }

    override void writeOutput(const(char)[] text, bool newline)
    {
        import urt.io;
        m_stream.write(text);
        if (newline)
            m_stream.write((features & ClientFeatures.CRLF) ? "\r\n" : "\n");
    }

private:
    Stream m_stream;
}
