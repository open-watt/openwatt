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
import urt.variant;

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
    none = 0,

    crlf = 1 << 1,          // Client recognises CR-LF for newline
    linemode = 1 << 2,      // Client uses line-mode
    escape = 1 << 3,        // Client can parse control sequences
    cursor = 1 << 4,        // Client supports cursor movement
    format = 1 << 5,        // Client supports screen formatting
    textattrs = 1 << 6,     // Client supports text attributes
    gfx = 1 << 7,           // Client supports graphics
    basiccolour = 1 << 8,   // Client supports color
    fullcolour = 1 << 9,    // Client supports full color
    resize = 1 << 10,       // Client supports terminal resizing
    mouse = 1 << 11,        // Client supports mouse events
    utf8 = 1 << 12,         // Client supports UTF-8

    nvt = crlf,
    vt100 = escape | cursor | format | textattrs | gfx,
    ansi = escape | cursor | format | textattrs | basiccolour | utf8,
    xterm = ansi | gfx | fullcolour | mouse | resize | utf8,
    windows = crlf | cursor | format | textattrs | basiccolour | resize | utf8,
}

class Session
{
nothrow @nogc:

    this(ref Console console)
    {
        _console = &console;
        _prompt = "> ";
        _cur_scope = console.get_root;
    }

    ~this()
    {
        close_history();
        close_session();
    }

    /// Update the session.
    /// This is called periodically from the session's console instances `Update()` method.
    void update()
    {
        if (_current_command)
        {
            CommandCompletionState state = _current_command.update();
            if (state >= CommandCompletionState.finished)
            {
                CommandState commandData = _current_command;
                _current_command = null;

                command_finished(commandData, state);
                allocator.freeT(commandData);

                // untaken input should be fed back into the command line
                MutableString!0 input = take_input();
                receive_input(input[]);
            }
        }
    }

    /// Test if the session is attached to a console instance. A detached session is effectively 'closed', and ready to be cleaned up.
    final bool is_attached() pure
        => _console != null;

    /// Test if the session has no active commands executing
    final bool is_idle() const pure
        => _current_command is null;

    /// Close this session and detach from the bound console instance.
    void close_session()
    {
        if (_current_command)
        {
            allocator.freeT(_current_command);
            _current_command = null;
        }

        if (_session_stack.length)
            _console = _session_stack.popBack();
        else
            _console = null;
    }


    abstract void write_output(const(char)[] text, bool newline);

    pragma(inline, true) final void write(Args...)(ref Args args)
        if (Args.length == 1 && is(Args[0] : const(char)[]))
    {
        return write_output(args[0], false);
    }

    final void write(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        char[1024] text;
        write_output(concat(text, forward!args), false);
    }

    pragma(inline, true) final void write_line(Args...)(auto ref Args args)
        if (Args.length == 1 && is(Args[0] : const(char)[]))
    {
        return write_output(args[0], true);
    }

    final void write_line(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        write_output(tconcat(forward!args), true);
    }

    final void writef(Args...)(const(char)[] format, auto ref Args args)
    {
        import urt.string.format;

        write_output(tformat(format, forward!args), false);
    }

    bool show_prompt(bool show)
        => _show_prompt.swap(show);

    const(char)[] set_prompt(const(char)[] prompt)
        => _prompt.swap(prompt);

    // TODO: I don't like this API... needs work!
    final const(char[]) get_input()
        => _buffer[];

    MutableString!0 set_input(const(char)[] text)
    {
        MutableString!0 old = _buffer.move;
        _buffer = null;
        _position = 0;
        receive_input(text);
        return old.move;
    }

    ptrdiff_t append_input(const(char)[] text)
    {
        assert(_console != null, "Session was closed!");

        // TODO: well, actually, the current command should receive this input, and ^C should cancel the command
        assert(!_current_command);

        assert(_buffer.length + text.length <= MaxStringLen, "Exceeds max string length");
        _buffer.reserve(cast(ushort)(_buffer.length + text.length));

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
                    if (_position < _buffer.length)
                        _buffer.erase(_position, 1);
                }
                else if (seq[] == ANSI_ARROW_UP)
                {
                    if (_history_cursor > 0)
                    {
                        if (_history_cursor == _history.length)
                            _history_head = _buffer.move;
                        _history_cursor--;
                        _buffer = _history[_history_cursor][];
                        _position = cast(uint)_buffer.length;
                    }
                }
                else if (seq[] == ANSI_ARROW_DOWN)
                {
                    if (_history_cursor < _history.length)
                    {
                        _history_cursor++;
                        if (_history_cursor != _history.length)
                            _buffer = _history[_history_cursor];
                        else
                        {
                            _buffer = _history_head.move;
                            _history_head.clear();
                        }
                        _position = cast(uint)_buffer.length;
                    }
                }
                else if (seq[] == ANSI_ARROW_LEFT)
                {
                    if (_position > 0)
                        --_position;
                }
                else if (seq[] == ANSI_ARROW_RIGHT)
                {
                    if (_position < _buffer.length)
                        ++_position;
                }
                else if (seq[] == "\x1b[1;5D" || seq[] == "\x1bOD") // CTRL_LEFT
                {
                    bool passedAny = false;
                    while (_position > 0)
                    {
                        if (_buffer[_position - 1] == ' ' && passedAny)
                            break;
                        if (_buffer[--_position] != ' ')
                            passedAny = true;
                    }
                }
                else if (seq[] == "\x1b[1;5C" || seq[] == "\x1bOC") // CTRL_RIGHT
                {
                    bool passedAny = false;
                    while (_position < _buffer.length)
                    {
                        if (_buffer[_position] != ' ')
                            passedAny = true;
                        if (_buffer[_position++] == ' ' && passedAny)
                            break;
                    }
                }
                else if (seq[] == ANSI_HOME1)
                {
                    _position = 0;
                }
                else if (seq[] == ANSI_HOME2 || seq[] == ANSI_HOME3)
                {
                    _position = 0;
                }
                else if (seq[] == ANSI_END1)
                {
                    _position = cast(uint)_buffer.length;
                }
                else if (seq[] == ANSI_END2 || seq[] == ANSI_END3)
                {
                    _position = cast(uint)_buffer.length;
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
                    if (_position > 0)
                        _buffer.erase(--_position, 1);
                }
                else if (t[i] == '\t')
                {
                    if (_suggestion_pending)
                    {
                        Array!String suggestions = _console.suggest(_buffer[], _cur_scope);
                        if (!suggestions.empty)
                            show_suggestions(suggestions[]);
                    }
                    else
                    {
                        const(char)[] completeFrom = _buffer[0 .. _position];
                        MutableString!0 completed = _console.complete(completeFrom, _cur_scope);
                        if (completed[] != completeFrom[])
                        {
                            uint oldPos = _position;
                            _position = cast(uint)completed.length;
                            completed ~= _buffer[oldPos .. $];
                            _buffer = completed.move;
                        }
                        else
                        {
                            _suggestion_pending = true;

                            // advance i since we skip the bottom part of the loop
                            i += take;
                            continue;
                        }
                    }
                }
                else if (t[i] == '\a')
                {
                    i += 1;
                    do_bell();
                }
            }
            else
            {
                _buffer.insert(_position, t[i .. i + take]);
                _position += take;
            }

            i += take;
            _suggestion_pending = false;
        }

        return len;

    close_session:
        // Ctrl-C
        close_session();

        // store the tail of the input buffer so the outer context can claim it
        _buffer = text[i .. $];
        return -1;
    }

    MutableString!0 take_input()
    {
        MutableString!0 take = _buffer.move;
        _buffer = null;
        _position = 0;
        return take.move;
    }


    /// \returns The width of the terminal in characters.
    final ushort width() => _width;

    /// \returns The height of the terminal in characters.
    final ushort height() => _height;

    /// Set the size of the console. Some session types may not support this feature.
    void setConsoleSize(ushort width, ushort height)
    {
        _width = width;
        _height = height;
    }

protected:
    /// Called immediately before console commands are executed.
    /// It may be used, for instance, to update any visual state required by the session on execution of a command.
    /// \param command
    ///  The complete command line being executed.
    void enter_command(const(char)[] command)
    {
    }

    /// Called immediately after console commands complete, or are aborted.
    /// It may be used, for instance, to update any visual state required by the session on completion of a command.
    /// \param commandData
    ///  The command state for the completing command.
    /// \param state
    ///  The completion state of the command. This can determine if the command completed, or was aborted.
    void command_finished(CommandState command_state, CommandCompletionState state)
    {
    }

    /// Called when suggestions should be presented to the user.
    /// Session implementations may implement this method to customise how to display the suggestions. For instance, show
    /// a tooltip that the user can select from, etc. Default implementation will write the suggestions to the output stream.
    /// \param suggestions
    ///  Set of suggestion that apply to the current context
    void show_suggestions(const(String)[] suggestions)
    {
        size_t max = 0;
        foreach (ref s; suggestions)
            max = max < s.length ? s.length : max;

        MutableString!0 text;
        size_t line_offset = 0;
        foreach (ref s; suggestions)
        {
            if (line_offset + max + 3 > _width)
            {
                text ~= (_features & ClientFeatures.crlf) ? "\r\n" : "\n";
                line_offset = 0;
            }
            text.append_format("   {0, *1}", s[], max);
            line_offset += max + 3;
        }

        write_line(text);
    }

    final void receive_input(const(char)[] input)
    {
        if (_current_command)
        {
            import urt.string : findFirst;
            size_t ctrl_c = input.findFirst('\x03');
            if (ctrl_c < input.length)
            {
                _current_command.request_cancel();
                _buffer.clear();
                _position = 0;
                _buffer ~= input[ctrl_c + 1 .. $];
            }
            else
                _buffer ~= input;
            return;
        }

        MutableString!0 input_backup;
        while (!_current_command && !input.empty)
        {
            ptrdiff_t taken = append_input(input);

            if (taken < 0)
            {
                // session was termianted...
                return;
            }
            else if (taken < input.length)
            {
                if (input[taken] == '\r' && input.length > taken + 1 && input[taken + 1] == '\n')
                    ++taken;

                MutableString!0 cmdInput = take_input();
                const(char)[] command = cmdInput[].trim_cmd_line;
                _buffer = input[taken + 1 .. $];

                Variant result;
                if (command.empty || execute(command, result))
                {
                    // possible the command terminated the session
                    if (!is_attached())
                        return;

                    // echo the result (since it wasn't captured)
                    if (!result.isNull)
                    {
                        ptrdiff_t l = result.toString(null, null, null);
                        if (l <= 0)
                            return;
                        Array!char buffer;
                        l = result.toString(buffer.extend(l), null, null);
                        write_line(buffer[0..l]);
                    }

                    // command was instantaneous; take leftover input and continue
                    input_backup = take_input();
                    input = input_backup[];
                }
            }
            else
                break;
        }
    }

protected:

    final NoGCAllocator allocator() pure
        => _console._allocator;
    final NoGCAllocator tempAllocator() pure
        => _console._tempAllocator;

    void do_bell()
    {
        // TODO: anything to handle BEEP?
    }

    final bool execute(const(char)[] command, out Variant result)
    {
        // TODO: command history!
        add_to_history(command);
        _history_head.clear();

        enter_command(command);

        _current_command = _console.execute(this, command, result);

        // possible the command terminated the session
        if (!is_attached())
        {
            assert(_current_command is null);
            return true;
        }

        if (!_current_command)
            command_finished(null, CommandCompletionState.finished);
        return _current_command is null;
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
        size_t file_size = cast(size_t)size;

        char[] mem = cast(char[])allocator.alloc(file_size);
        if (mem == null)
        {
            writeError("Error allocating memory for history");
            return;
        }

        scope(exit)
            allocator.free(mem);

        _history_file.read(mem, file_size);

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

    final void add_to_history(const(char)[] line)
    {
        if (!line.empty && (_history.empty || line[] != _history[$-1][]))
        {
            _history.pushBack(MutableString!0(line));
            if (_history.length > 50)
                _history.popFront();

            if (_history_file.is_open)
            {
                static bool write_to_file(char[] text, ref File file)
                {
                    size_t bytes_written;
                    Result result = file.write(text, bytes_written);
                    if (result.succeeded && bytes_written == text.length)
                        return true;

                    writeError("Error writing session history.");
                    return false;
                }

                _history_file.set_pos(0);
                size_t total_size;
                bool success = true;
                foreach (entry; _history)
                {
                    success = write_to_file(entry[], _history_file);
                    if (!success)
                        break;

                    total_size += entry.length;

                    success = write_to_file(cast(char[])"\n", _history_file);
                    if (!success)
                        break;

                    total_size += 1;
                }

                if (success)
                    _history_file.set_size(total_size);
                else
                    _history_file.close();
            }
        }
        _history_cursor = cast(uint)_history.length;
    }


    ClientFeatures _features;
    ushort _width = 80;
    ushort _height = 24;
    char _escape_char;

    bool _show_prompt = true;
    bool _suggestion_pending = false;

    const(char)[] _prompt;
    MutableString!0 _buffer;
    uint _position = 0;

    CommandState _current_command = null;

    Map!(String, String) _local_variables;

//    list!String _history;
//    list!String.iterator _history_cursor;
    // TODO: swap to SharedString, and also swap to List
    Array!(MutableString!0) _history;
    uint _history_cursor = 0;
    MutableString!0 _history_head;
    File _history_file;

    Array!(Console*) _session_stack;

package:
    Console* _console;
    Scope _cur_scope = null;

    ref CommandState current_command() => _current_command;
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
        return _output[];
    }

    MutableString!0 takeOutput()
    {
        return _output.move;
    }

    void clearOutput()
    {
        _output = null;
    }

    override void write_output(const(char)[] text, bool newline)
    {
        if (newline)
            _output.append(text, '\n');
        else
            _output ~= text;
    }

private:
    MutableString!0 _output;
}

class SimpleSession : Session
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console);
    }

    override void write_output(const(char)[] text, bool newline)
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

        // set up raw terminal mode for character-by-character input
        version (Windows)
        {
            _h_stdin = GetStdHandle(STD_INPUT_HANDLE);
            _h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
            _h_stderr = GetStdHandle(STD_ERROR_HANDLE);

            // Check if stdout is a real console or redirected (pipe/file)
            DWORD mode;
            bool is_console = GetConsoleMode(_h_stdout, &mode) != 0;

            if (is_console)
            {
                // Real console - enable full ANSI features
                _features = ClientFeatures.ansi;

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
                SetConsoleMode(_h_stdin, inputMode);

                // Get console screen buffer info to determine height
                CONSOLE_SCREEN_BUFFER_INFO csbi;
                if (GetConsoleScreenBufferInfo(_h_stdout, &csbi))
                {
                    _width = cast(ushort)(csbi.srWindow.Right - csbi.srWindow.Left + 1);
                    _height = cast(ushort)(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
                }
            }
            else
            {
                // Redirected output - disable ANSI to avoid escape codes in pipes
                _features = ClientFeatures.none;
                _original_input_mode = 0;
                _original_output_mode = 0;
                _original_stderr_mode = 0;

                // Disable prompt rendering when piped - just read commands and write output
                _show_prompt = false;

                // Piped I/O - use line-buffered mode
                _width = 80;
                _height = 24;
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

        if (_show_prompt)
            send_prompt_and_buffer(true);
    }

    override void update()
    {
        super.update();

        if (!is_attached())
            return;

        enum DefaultBufferLen = 512;
        ubyte[DefaultBufferLen] recvbuf = void;

        // read from stdin
        version (Windows)
        {
            if (_features & ClientFeatures.ansi)
            {
                // Real console - use console input events
                DWORD num_events = 0;
                GetNumberOfConsoleInputEvents(_h_stdin, &num_events);
                if (num_events == 0)
                    return;

                Array!(char, 0) input; // TODO: stack-allocate some bytes when move semantics land!
                input.reserve(num_events + 32); // add some extra bytes for escape sequences

                INPUT_RECORD[32] events = void;
                DWORD events_read;
                while  (num_events && ReadConsoleInputA(_h_stdin, events.ptr, num_events < events.length ? num_events : events.length, &events_read))
                {
                    num_events -= events_read;

                    for (DWORD i = 0; i < events_read; i++)
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
                receive_input(input[]);
            }
            else
            {
                // Piped input - use ReadFile with non-blocking I/O
                DWORD bytes_read;
                DWORD bytes_avail;

                // Check if data is available without blocking
                if (PeekNamedPipe(_h_stdin, null, 0, null, &bytes_avail, null) && bytes_avail > 0)
                {
                    if (ReadFile(_h_stdin, recvbuf.ptr, recvbuf.length, &bytes_read, null) && bytes_read > 0)
                        receive_input(cast(char[])recvbuf[0 .. bytes_read]);
                }
            }
        }
        else version(Posix)
        {
            ptrdiff_t r = read(STDIN_FILENO, recvbuf.ptr, recvbuf.length);
            if (r > 0)
                receive_input(cast(char[])recvbuf[0 .. r]);
        }
    }

    override void enter_command(const(char)[] command)
    {
        write_output("", true);
    }

    override void command_finished(CommandState command_state, CommandCompletionState state)
    {
        if (_show_prompt)
            send_prompt_and_buffer(false);
    }

    override void close_session()
    {
        restore_terminal();
        super.close_session();
    }

    override void write_output(const(char)[] text, bool newline)
    {
        version (Windows)
        {
            DWORD written;
            if (text.length > 0)
            {
                // Check if stdout is a console or a pipe/file
                DWORD mode;
                if (GetConsoleMode(_h_stdout, &mode))
                {
                    // It's a real console - use WriteConsoleA for proper Unicode support
                    WriteConsoleA(_h_stdout, text.ptr, cast(DWORD)text.length, &written, null);
                }
                else
                {
                    // It's redirected (pipe/file) - use WriteFile
                    WriteFile(_h_stdout, text.ptr, cast(DWORD)text.length, &written, null);
                }
            }
            if (newline)
            {
                DWORD mode;
                if (GetConsoleMode(_h_stdout, &mode))
                    WriteConsoleA(_h_stdout, "\r\n".ptr, 2, &written, null);
                else
                    WriteFile(_h_stdout, "\n".ptr, 1, &written, null);  // Use \n for pipes
            }
        }
        else version(Posix)
        {
            core.sys.posix.unistd.write(STDOUT_FILENO, text.ptr, text.length);
            if (newline)
                core.sys.posix.unistd.write(STDOUT_FILENO, "\n".ptr, 1);
        }
    }

    override void show_suggestions(const(String)[] suggestions)
    {
        write_output("", true);
        super.show_suggestions(suggestions);
        if (_show_prompt)
            send_prompt_and_buffer(false);
    }

    override bool show_prompt(bool show)
    {
        bool old = super.show_prompt(show);

        if (!_current_command)
        {
            if (show && !old)
                send_prompt_and_buffer(true);
            else if (!show && old)
                clear_line();
        }
        return old;
    }

    override const(char)[] set_prompt(const(char)[] prompt)
    {
        const(char)[] old = super.set_prompt(prompt);
        if (!_current_command && _show_prompt && prompt[] != old[])
            send_prompt_and_buffer(true);
        return old;
    }

    override ptrdiff_t append_input(const(char)[] text)
    {
        import urt.util : min;

        MutableString!0 before = _buffer;
        uint before_pos = _position;

        ptrdiff_t taken = super.append_input(text);
        if (taken < 0)
            return taken;

        // Only echo input back to terminal in interactive ANSI mode
        // When piped, don't echo - just accept commands silently
        if (_features & ClientFeatures.ansi)
        {
            // echo changes back to the terminal
            size_t diff_offset = 0;
            size_t len = min(_buffer.length, before.length);
            while (diff_offset < len && before[diff_offset] == _buffer[diff_offset])
                ++diff_offset;
            bool no_change = _buffer.length == before.length && diff_offset == _buffer.length;

            MutableString!0 echo;
            if (no_change)
            {
                // maybe the cursor moved?
                if (before_pos != _position)
                {
                    if (_position < before_pos)
                        echo.concat("\x1b[", before_pos - _position, 'D');
                    else
                        echo.concat("\x1b[", _position - before_pos, 'C');
                }
            }
            else
            {
                if (diff_offset != before_pos)
                {
                    // shift the cursor to the change position
                    if (diff_offset < before_pos)
                        echo.concat("\x1b[", before_pos - diff_offset, 'D');
                    else
                        echo.concat("\x1b[", diff_offset - before_pos, 'C');
                }

                if (diff_offset < _buffer.length)
                    echo.append(_buffer[diff_offset .. $]);

                if (_buffer.length < before.length)
                {
                    // erase the tail
                    echo.append("\x1b[K");
                }

                if (echo.length && _position != _buffer.length)
                {
                    assert(_position < _buffer.length); // shouldn't be possible for the cursor to be beyond the end of the line
                    echo.append("\x1b[", _buffer.length - _position, 'D');
                }
            }

            if (echo.length)
                write_output(echo[], false);
        }

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
        write_output(Clear, false);
    }

    void send_prompt_and_buffer(bool with_clear = false)
    {
        import urt.string.format;

        if (_features & ClientFeatures.ansi)
        {
            enum Clear = ANSI_ERASE_LINE ~ "\r"; // clear line and return to start

            // format: [clear?] [prompt] [buffer] [move cursor back if not at end?]
            char[] prompt = tformat("{0, ?1}{2}{3}{@5, ?4}", Clear, with_clear, _prompt, _buffer, _position < _buffer.length, "\x1b[{6}D", _buffer.length - _position);
            write_output(prompt, false);
        }
        else
        {
            // No ANSI - simple output
            if (with_clear)
                write_output("\r", false);  // Just carriage return
            char[] prompt = tformat("{0}{1}", _prompt, _buffer);
            write_output(prompt, false);
        }
    }
}

class SerialSession : Session
{
    import router.stream;
nothrow @nogc:

    this(ref Console console, Stream stream, ClientFeatures features = ClientFeatures.ansi, ushort width = 80, ushort height = 24)
    {
        super(console);
        _features |= features;
        _stream = stream;
        _width = width;
        _height = height;
    }

    override void update()
    {
        enum DefaultBufferLen = 512;
        char[DefaultBufferLen] recvbuf = void;

        Array!(char, 0) input; // TODO: add a generous stack buffer

        ptrdiff_t read;
        do
        {
            read = _stream.read(recvbuf[]);
            if (read < 0)
            {
                close_session();
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
                    if (_features & ClientFeatures.crlf)
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
            receive_input(input[]);

        super.update();
    }

    override void write_output(const(char)[] text, bool newline)
    {
        import urt.io;
        _stream.write(text);
        if (newline)
            _stream.write((_features & ClientFeatures.crlf) ? "\r\n" : "\n");
    }

private:
    Stream _stream;
}
