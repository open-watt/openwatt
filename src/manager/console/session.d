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

version (Windows)
{
    import core.sys.windows.windows;

    extern(Windows) BOOL SetConsoleOutputCP(UINT wCodePageID) nothrow @nogc;
}
else version(Posix)
{
    import core.sys.posix.termios;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
}
else
    static assert(false, "Unsupported platform!");

nothrow @nogc:


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
        close_history();
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

    /// Test if the session has no active commands executing
    final bool is_idle() const pure
        => m_currentCommand is null;

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
            if (size_t ansiLen = parse_ansi_code(t[i .. len]))
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
                    if (_history_cursor > 0)
                    {
                        if (_history_cursor == _history.length)
                            _history_head = m_buffer.move;
                        _history_cursor--;
                        m_buffer = _history[_history_cursor][];
                        m_position = cast(uint)m_buffer.length;
                    }
                }
                else if (seq[] == ANSI_ARROW_DOWN)
                {
                    if (_history_cursor < _history.length)
                    {
                        _history_cursor++;
                        if (_history_cursor != _history.length)
                            m_buffer = _history[_history_cursor];
                        else
                        {
                            m_buffer = _history_head.move;
                            _history_head.clear();
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
                else if (t[i] == '\r' || t[i] == '\n')
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
                        Array!String suggestions = m_console.suggest(m_buffer, curScope);
                        if (!suggestions.empty)
                            showSuggestions(suggestions[]);
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
                if (input[taken] == '\r' && input.length > taken + 1 && input[taken + 1] == '\n')
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

    void doBell()
    {
        // TODO: anything to handle BEEP?
    }

    final bool execute(const(char)[] command)
    {
        // TODO: command history!
        addToHistory(command);
        _history_head.clear();

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

    final void load_history(const char[] filename)
    {
        // TODO: probably should store a history file per user... (pending user login?)

        Result result = open(_history_file, filename, FileOpenMode.ReadWrite);
        if (result.failed)
        {
            writeError("Error opening history:", result.file_result);
            return;
        }

        ulong size = _history_file.get_size();

        // TODO: maybe we should specify a "MAX_ALLOC" or something...
        assert(size <= size_t.max, "File too large to read into memory");
        size_t fileSize = cast(size_t)size;

        char[] mem = cast(char[])allocator.alloc(fileSize);
        if (mem == null)
        {
            writeError("Error allocating memory for history");
            return;
        }

        scope(exit)
            allocator.free(mem);

        _history_file.read(mem, fileSize);

        char[] buff = mem.trim;
        while (!buff.empty)
        {
            // take the next line
            const(char)[] line = buff.split!('\n', false);
            if (!line.empty)
                _history ~= MutableString!0(line);
        }
        _history_cursor = cast(uint)_history.length;
    }

    final void close_history()
    {
        if (_history_file.is_open())
            _history_file.close();
    }

    final void addToHistory(const(char)[] line)
    {
        if (!line.empty && (_history.empty || line[] != _history[$-1]))
        {
            _history.pushBack(MutableString!0(line));
            if (_history.length > 50)
                _history.popFront();

            if (_history_file.is_open)
            {
                static bool WriteToFile(char[] text, ref File file) {
                    size_t bytesWritten;
                    Result result = file.write(text, bytesWritten);
                    if (result.succeeded && bytesWritten == text.length)
                        return true;

                    writeError("Error writing session history.");
                    return false;
                };

                _history_file.set_pos(0);
                size_t totalSize;
                bool success = true;
                foreach (entry; _history)
                {
                    success = WriteToFile(entry, _history_file);
                    if (!success)
                        break;

                    totalSize += entry.length;

                    success = WriteToFile(cast(char[])"\n", _history_file);
                    if (!success)
                        break;

                    totalSize += 1;
                }

                if (success)
                    _history_file.set_size(totalSize);
                else
                    _history_file.close();
            }
        }
        _history_cursor = cast(uint)_history.length;
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

//    list<String> _history;
//    list<String>::iterator _history_cursor;
    // TODO: swap to SharedString, and also swap to List
    Array!(MutableString!0) _history;
    uint _history_cursor = 0;
    MutableString!0 _history_head;
    File _history_file;

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

class SimpleSession : Session
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

class ConsoleSession : Session
{
    nothrow @nogc:

    this(ref Console console)
    {
        super(console);
        features = ClientFeatures.ANSI;

        // set up raw terminal mode for character-by-character input
        version (Windows)
        {
            _h_stdin = GetStdHandle(STD_INPUT_HANDLE);
            _h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
            _h_stderr = GetStdHandle(STD_ERROR_HANDLE);

            // set console to UTF-8
            SetConsoleOutputCP(65001); // CP_UTF8

            // save original console modes
            GetConsoleMode(_h_stdin, &_original_input_mode);
            GetConsoleMode(_h_stdout, &_original_output_mode);
            GetConsoleMode(_h_stderr, &_original_stderr_mode);

            // Enable virtual terminal processing for ANSI escape sequences on both streams
            DWORD outputMode = _original_output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            SetConsoleMode(_h_stdout, outputMode);

            DWORD stderrMode = _original_stderr_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            SetConsoleMode(_h_stderr, stderrMode);

            // Enable raw console input - we want key events, not processed input
            // Disable ENABLE_LINE_INPUT and ENABLE_ECHO_INPUT to get character-by-character input
            // Disable ENABLE_PROCESSED_INPUT to handle Ctrl+C ourselves
            DWORD inputMode = ENABLE_WINDOW_INPUT;
            // Optionally keep ENABLE_MOUSE_INPUT if you want mouse support later
            SetConsoleMode(_h_stdin, inputMode);

            // Get console screen buffer info to determine height
            CONSOLE_SCREEN_BUFFER_INFO csbi;
            if (GetConsoleScreenBufferInfo(_h_stdout, &csbi))
            {
                m_width = cast(ushort)(csbi.srWindow.Right - csbi.srWindow.Left + 1);
                m_height = cast(ushort)(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
            }
        }
        else version(Posix)
        {
            // save original terminal settings
            tcgetattr(STDIN_FILENO, &_original_termios);

            // set up new terminal settings for raw mode
            termios raw = _original_termios;
            raw.c_lflag &= ~(ICANON | ECHO);  // disable canonical mode and echo
            raw.c_cc[VMIN] = 0;   // non-blocking read
            raw.c_cc[VTIME] = 0;  // no timeout
            tcsetattr(STDIN_FILENO, TCSANOW, &raw);

            // make stdin non-blocking
            int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
            fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
        }

        load_history(".history");

        if (m_showPrompt)
            send_prompt_and_buffer(true);
    }

    override void update()
    {
        super.update();

        if (!isAttached())
            return;

        enum DefaultBufferLen = 512;
        ubyte[DefaultBufferLen] recvbuf = void;

        // read from stdin
        version (Windows)
        {
            DWORD numEvents = 0;
            GetNumberOfConsoleInputEvents(_h_stdin, &numEvents);
            if (numEvents == 0)
                return;

            Array!(char, 0) input; // TODO: stack-allocate some bytes when move semantics land!
            input.reserve(numEvents + 32); // add some extra bytes for escape sequences

            INPUT_RECORD[32] events = void;
            DWORD eventsRead;
            while  (numEvents && ReadConsoleInputA(_h_stdin, events.ptr, numEvents < events.length ? numEvents : events.length, &eventsRead))
            {
                numEvents -= eventsRead;

                for (DWORD i = 0; i < eventsRead; i++)
                {
                    // filter out non-key-down events
                    if (events[i].EventType != KEY_EVENT || !events[i].KeyEvent.bKeyDown)
                        continue;

                    char ch = events[i].KeyEvent.AsciiChar;
                    if (ch != 0)
                        input ~= ch;
                    else
                    {
                        // not an ascii character...
                        WORD vk = events[i].KeyEvent.wVirtualKeyCode;
                        DWORD controlKeyState = events[i].KeyEvent.dwControlKeyState;

                        if (vk == VK_UP)
                            input ~= ANSI_ARROW_UP;
                        else if (vk == VK_DOWN)
                            input ~= ANSI_ARROW_DOWN;
                        else if (vk == VK_LEFT)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                input ~= "\x1b[1;5D"; // Ctrl+Left
                            else
                                input ~= ANSI_ARROW_LEFT;
                        }
                        else if (vk == VK_RIGHT)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                input ~= "\x1b[1;5C"; // Ctrl+Right
                            else
                                input ~= ANSI_ARROW_RIGHT;
                        }
                        else if (vk == VK_HOME)
                            input ~= ANSI_HOME1;
                        else if (vk == VK_END)
                            input ~= ANSI_END1;
                        else if (vk == VK_DELETE)
                            input ~= ANSI_DEL;
                        else if (vk == VK_BACK)
                            input ~= '\b';
                    }
                }
            }

            if (!input.empty)
                receiveInput(input[]);
        }
        else version(Posix)
        {
            ptrdiff_t r = read(STDIN_FILENO, recvbuf.ptr, recvbuf.length);
            if (r > 0)
                receiveInput(cast(char[])recvbuf[0 .. r]);
        }
    }

    override void enterCommand(const(char)[] command)
    {
        writeOutput("", true);
    }

    override void commandFinished(CommandState commandState, CommandCompletionState state)
    {
        if (m_showPrompt)
            send_prompt_and_buffer(false);
    }

    override void closeSession()
    {
        restore_terminal();
        super.closeSession();
    }

    override void writeOutput(const(char)[] text, bool newline)
    {
        version (Windows)
        {
            DWORD written;
            if (text.length > 0)
                WriteConsoleA(_h_stdout, text.ptr, cast(DWORD)text.length, &written, null);
            if (newline)
                WriteConsoleA(_h_stdout, "\r\n".ptr, 2, &written, null);
        }
        else version(Posix)
        {
            core.sys.posix.unistd.write(STDOUT_FILENO, text.ptr, text.length);
            if (newline)
                core.sys.posix.unistd.write(STDOUT_FILENO, "\n".ptr, 1);
        }
    }

    override void showSuggestions(const(String)[] suggestions)
    {
        writeOutput("", true);
        super.showSuggestions(suggestions);
        if (m_showPrompt)
            send_prompt_and_buffer(false);
    }

    override bool showPrompt(bool show)
    {
        bool old = super.showPrompt(show);

        if (!m_currentCommand)
        {
            if (show && !old)
                send_prompt_and_buffer(true);
            else if (!show && old)
                clear_line();
        }
        return old;
    }

    override const(char)[] setPrompt(const(char)[] prompt)
    {
        const(char)[] old = super.setPrompt(prompt);
        if (!m_currentCommand && m_showPrompt && prompt[] != old[])
            send_prompt_and_buffer(true);
        return old;
    }

    override ptrdiff_t appendInput(const(char)[] text)
    {
        import urt.util : min;

        MutableString!0 before = m_buffer;
        uint beforePos = m_position;

        ptrdiff_t taken = super.appendInput(text);
        if (taken < 0)
            return taken;

        // echo changes back to the terminal
        size_t diffOffset = 0;
        size_t len = min(m_buffer.length, before.length);
        while (diffOffset < len && before[diffOffset] == m_buffer[diffOffset])
            ++diffOffset;
        bool noChange = m_buffer.length == before.length && diffOffset == m_buffer.length;

        MutableString!0 echo;
        if (noChange)
        {
            // maybe the cursor moved?
            if (beforePos != m_position)
            {
                if (m_position < beforePos)
                    echo.concat("\x1b[", beforePos - m_position, 'D');
                else
                    echo.concat("\x1b[", m_position - beforePos, 'C');
            }
        }
        else
        {
            if (diffOffset != beforePos)
            {
                // shift the cursor to the change position
                if (diffOffset < beforePos)
                    echo.concat("\x1b[", beforePos - diffOffset, 'D');
                else
                    echo.concat("\x1b[", diffOffset - beforePos, 'C');
            }

            if (diffOffset < m_buffer.length)
                echo.append(m_buffer[diffOffset .. $]);

            if (m_buffer.length < before.length)
            {
                // erase the tail
                echo.append("\x1b[K");
            }

            if (echo.length && m_position != m_buffer.length)
            {
                assert(m_position < m_buffer.length); // shouldn't be possible for the cursor to be beyond the end of the line
                echo.append("\x1b[", m_buffer.length - m_position, 'D');
            }
        }

        if (echo.length)
            writeOutput(echo[], false);

        return taken;
    }

private:
    version (Windows)
    {
        HANDLE _h_stdin;
        HANDLE _h_stdout;
        HANDLE _h_stderr;
        DWORD _original_input_mode;
        DWORD _original_output_mode;
        DWORD _original_stderr_mode;
    }
    else version(Posix)
    {
        termios _original_termios;
    }

    bool _terminal_restored;

    void restore_terminal()
    {
        if (_terminal_restored)
            return;

        version (Windows)
        {
            SetConsoleMode(_h_stdin, _original_input_mode);
            SetConsoleMode(_h_stdout, _original_output_mode);
            SetConsoleMode(_h_stderr, _original_stderr_mode);
        }
        else version(Posix)
        {
            tcsetattr(STDIN_FILENO, TCSANOW, &_original_termios);
        }

        _terminal_restored = true;
    }

    void clear_line()
    {
        enum Clear = ANSI_ERASE_LINE ~ "\x1b[80D"; // clear and move left 80
        writeOutput(Clear, false);
    }

    void send_prompt_and_buffer(bool with_clear = false)
    {
        import urt.string.format;

        enum Clear = ANSI_ERASE_LINE ~ "\r"; // clear line and return to start

        // format: [clear?] [prompt] [buffer] [move cursor back if not at end?]
        char[] prompt = tformat("{0, ?1}{2}{3}{@5, ?4}", Clear, with_clear, m_prompt, m_buffer, m_position < m_buffer.length, "\x1b[{6}D", m_buffer.length - m_position);
        writeOutput(prompt, false);
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
