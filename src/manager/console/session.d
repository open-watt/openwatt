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

// Out-of-band terminal events delivered via TerminalChannel
enum TerminalEvents : ubyte
{
    none             = 0,
    resized          = 1 << 0,
    features_changed = 1 << 1,
}

// Side-channel between a protocol-aware stream and a Session.
// Carries terminal state that doesn't belong in the data path.
struct TerminalChannel
{
    uint width = 80;
    uint height = 24;
    ClientFeatures features;
    const(char)[] terminal_type;
    TerminalEvents pending_events;
}

class Session
{
    import router.stream;
nothrow @nogc:

    this(ref Console console, Stream stream = null)
    {
        import protocol.telnet.stream : TelnetStream;

        _console = &console;
        _stream = stream;
        _prompt = "> ";
        _cur_scope = console.get_root;
        _nvt_input = cast(TelnetStream)stream !is null;

        if (_stream)
        {
            auto term = _stream.terminal_channel();
            if (term)
            {
                _features = term.features;
                _width = cast(ushort)term.width;
                _height = cast(ushort)term.height;
            }
        }
    }

    ~this()
    {
        close_history();
        if (_current_command)
        {
            _current_command.request_cancel();
            allocator.freeT(_current_command);
            _current_command = null;
        }
        _console = null;
    }

    void update()
    {
        // Read from stream if present
        if (_stream)
        {
            enum BufLen = 512;
            char[BufLen] recvbuf = void;

            ptrdiff_t r;
            do
            {
                r = _stream.read(recvbuf[]);
                if (r < 0)
                {
                    close_session();
                    return;
                }
                if (r > 0)
                    receive_input(recvbuf[0 .. r]);
            }
            while (r == recvbuf.length);

            poll_terminal_events();
        }

        // Poll async command completion
        if (_current_command)
        {
            CommandCompletionState state = _current_command.update();
            if (state >= CommandCompletionState.finished)
            {
                CommandState commandData = _current_command;
                _current_command = null;

                // echo the result (since it wasn't captured)
                if (!commandData.result.isNull)
                {
                    ptrdiff_t l = commandData.result.toString(null, null, null);
                    if (l > 0)
                    {
                        Array!char buffer;
                        l = commandData.result.toString(buffer.extend(l), null, null);
                        write_line(buffer[0..l]);
                    }
                }

                command_finished(commandData, state);
                allocator.freeT(commandData);

                if (_closing)
                {
                    _console = null;
                    _closing = false;
                    return;
                }

                MutableString!0 input = take_input();
                receive_input(input[]);
            }
        }
    }

    final bool is_attached() pure
        => _console != null;

    final bool is_idle() const pure
        => _current_command is null;

    final void close_session()
    {
        if (_current_command)
        {
            _current_command.request_cancel();

            if (_current_command.update() >= CommandCompletionState.finished)
            {
                allocator.freeT(_current_command);
                _current_command = null;
            }
            else
            {
                _closing = true;
                return;
            }
        }

        _console = null;
    }

    void write_output(const(char)[] text, bool newline)
    {
        if (_stream)
        {
            if (text.length > 0)
                _stream.write(text);
            if (newline)
                _stream.write((_features & ClientFeatures.crlf) ? "\r\n" : "\n");
        }
        else if (text.length > 0)
        {
            import urt.log : writeInfo;
            writeInfo("session: ", text);
        }
    }

    pragma(inline, true) void write(Args...)(ref Args args)
        if (Args.length == 1 && is(Args[0] : const(char)[]))
    {
        return write_output(args[0], false);
    }

    void write(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        char[1024] text;
        write_output(concat(text, forward!args), false);
    }

    pragma(inline, true) void write_line(Args...)(auto ref Args args)
        if (Args.length == 1 && is(Args[0] : const(char)[]))
    {
        return write_output(args[0], true);
    }

    void write_line(Args...)(auto ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;

        write_output(tconcat(forward!args), true);
    }

    void writef(Args...)(const(char)[] format, auto ref Args args)
    {
        import urt.string.format;

        write_output(tformat(format, forward!args), false);
    }

    final bool show_prompt(bool show)
    {
        bool old = _show_prompt.swap(show);
        if (show && !old)
            poll_terminal_events();
        if ((_features & ClientFeatures.escape) && !_current_command)
        {
            if (show && !old)
                send_prompt_and_buffer(true);
            else if (!show && old)
                clear_line();
        }
        return old;
    }

    final const(char)[] set_prompt(const(char)[] prompt)
    {
        const(char)[] old = _prompt.swap(prompt);
        if ((_features & ClientFeatures.escape) && !_current_command && _show_prompt && prompt[] != old[])
            send_prompt_and_buffer(true);
        return old;
    }

    final ptrdiff_t read_input(char[] buffer)
    {
        import urt.util : min;

        size_t n = min(buffer.length, _buffer.length);
        if (n == 0)
            return 0;
        buffer[0 .. n] = _buffer[0 .. n];
        _buffer.erase(0, n);
        _position = cast(uint)min(_position, _buffer.length);
        return cast(ptrdiff_t)n;
    }

    final const(char)[] get_input()
        => _buffer[];

    final void feed_input(const(char)[] text)
    {
        receive_input(text);
    }

    final void feed_input(Array!char text)
    {
        receive_input(text[]);
    }

    ptrdiff_t append_input(const(char)[] text)
    {
        assert(_console != null, "Session was closed!");
        assert(!_current_command);

        assert(_buffer.length + text.length <= MaxStringLen, "Exceeds max string length");
        _buffer.reserve(cast(ushort)(_buffer.length + text.length));

        MutableString!0 before = _buffer;
        uint before_pos = _position;

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
                take = ansiLen;
                handle_ansi_sequence(t[i .. i + ansiLen]);
            }
            else if (t[i] < '\x20')
            {
                if (t[i] == '\x03')
                {
                    i += 1;
                    goto close_session;
                }
                else if (t[i] == '\n')
                    return i;
                else if (t[i] == '\r')
                {
                    // Normalize: consume \n or \0 (NVT stuffing) after \r
                    if (i + 1 < len && (t[i + 1] == '\n' || (_nvt_input && t[i + 1] == '\0')))
                        ++i;
                    return i;
                }
                else if (t[i] == '\b')
                {
                erase_char:
                    if (_position > 0)
                        _buffer.erase(--_position, 1);
                }
                else if (t[i] == '\x17') // Ctrl+W / Ctrl+Backspace
                {
                    uint start = word_boundary_left();
                    if (_position > start)
                    {
                        _buffer.erase(start, _position - start);
                        _position = start;
                    }
                }
                else if (t[i] == '\t')
                {
                    handle_tab_completion();
                    if (_suggestion_pending)
                    {
                        i += take;
                        continue;
                    }
                }
                else if (t[i] == '\x15') // Ctrl+U — kill line
                {
                    _buffer.clear();
                    _position = 0;
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

        echo_diff(before[], before_pos);

        return len;

    close_session:
        close_session();
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


    final ushort width() => _width;
    final ushort height() => _height;
    final ClientFeatures features() => _features;

    final void set_features(ClientFeatures f, ushort w = 0, ushort h = 0)
    {
        _features = f;
        if (w) _width = w;
        if (h) _height = h;
    }

    final Array!String suggest(const(char)[] text)
        => _console.suggest(text, _cur_scope);

protected:
    void enter_command(const(char)[])
    {
        if (_features & ClientFeatures.escape)
            write_output("\n", false);
    }

    void command_finished(CommandState, CommandCompletionState)
    {
        if (_show_prompt && (_features & ClientFeatures.escape))
            send_prompt_and_buffer(false);
    }

    void show_suggestions(const(String)[] suggestions)
    {
        if (_features & ClientFeatures.escape)
            write_output("\n", false);

        size_t max = 0;
        foreach (ref s; suggestions)
            max = max < s.length ? s.length : max;

        MutableString!0 text;
        size_t line_offset = 0;
        foreach (ref s; suggestions)
        {
            if (line_offset + max + 3 > _width)
            {
                text ~= "\n";
                line_offset = 0;
            }
            text.append_format("   {0, *1}", s[], max);
            line_offset += max + 3;
        }

        write_line(text);

        if (_show_prompt && (_features & ClientFeatures.escape))
            send_prompt_and_buffer(false);
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

    public final void load_history(const char[] filename)
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

    final NoGCAllocator allocator() pure
        => _console._allocator;
    final NoGCAllocator tempAllocator() pure
        => _console._tempAllocator;

    void do_bell()
    {
    }

    final bool execute(const(char)[] command, out Variant result)
    {
        add_to_history(command);
        _history_head.clear();

        enter_command(command);

        _current_command = _console.execute(this, command, result);

        if (!is_attached())
        {
            assert(_current_command is null);
            return true;
        }

        if (!_current_command)
            command_finished(null, CommandCompletionState.finished);
        return _current_command is null;
    }

private:
    Stream _stream;

    ClientFeatures _features;
    ushort _width = 80;
    ushort _height = 24;

    bool _show_prompt = false;
    bool _suggestion_pending = false;
    bool _closing = false;
    bool _nvt_input = false;

    const(char)[] _prompt;
    MutableString!0 _buffer;
    uint _position = 0;

    CommandState _current_command = null;

    Array!(MutableString!0) _history;
    uint _history_cursor = 0;
    MutableString!0 _history_head;
    File _history_file;

    void poll_terminal_events()
    {
        if (!_stream)
            return;
        auto term = _stream.terminal_channel();
        if (!term)
            return;
        if (term.pending_events & TerminalEvents.resized)
        {
            _width = cast(ushort)term.width;
            _height = cast(ushort)term.height;
            term.pending_events &= ~TerminalEvents.resized;
        }
        if (term.pending_events & TerminalEvents.features_changed)
        {
            _features = term.features;
            term.pending_events &= ~TerminalEvents.features_changed;
            if (_show_prompt && (_features & ClientFeatures.escape))
                send_prompt_and_buffer(true);
        }
    }

    import urt.string.ascii : is_alpha_numeric, is_whitespace;

    static bool is_word_char(char c)
        => is_alpha_numeric(c) || c == '_' || c == '-';

    // TODO: this skipping logic is not great
    uint word_boundary_right()
    {
        uint p = _position;
        uint len = cast(uint)_buffer.length;
        while (p < len && is_whitespace(_buffer[p]))
            ++p;
        while (p < len && is_word_char(_buffer[p]))
            ++p;
        while (p < len && !is_word_char(_buffer[p]) && !is_whitespace(_buffer[p]))
            ++p;
        while (p < len && is_whitespace(_buffer[p]))
            ++p;
        return p;
    }

    // TODO: this skipping logic is not great
    uint word_boundary_left()
    {
        uint p = _position;
        while (p > 0 && is_whitespace(_buffer[p - 1]))
            --p;
        while (p > 0 && !is_word_char(_buffer[p - 1]) && !is_whitespace(_buffer[p - 1]))
            --p;
        while (p > 0 && is_word_char(_buffer[p - 1]))
            --p;
        while (p > 0 && is_whitespace(_buffer[p - 1]))
            --p;
        return p;
    }

    void handle_ansi_sequence(const(char)[] seq)
    {
        if (seq[] == ANSI_DEL)
        {
            if (_position < _buffer.length)
                _buffer.erase(_position, 1);
        }
        else if (seq[] == ANSI_ARROW_UP)
            history_prev();
        else if (seq[] == ANSI_ARROW_DOWN)
            history_next();
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
        else if (seq[] == "\x1b[1;5D" || seq[] == "\x1bOD") // Ctrl+Left
            _position = word_boundary_left();
        else if (seq[] == "\x1b[1;5C" || seq[] == "\x1bOC") // Ctrl+Right
            _position = word_boundary_right();
        else if (seq[] == "\x1b[3;5~") // Ctrl+Delete
        {
            uint end = word_boundary_right();
            if (end > _position)
                _buffer.erase(_position, end - _position);
        }
        else if (seq[] == ANSI_HOME1 || seq[] == ANSI_HOME2 || seq[] == ANSI_HOME3)
            _position = 0;
        else if (seq[] == ANSI_END1 || seq[] == ANSI_END2 || seq[] == ANSI_END3)
            _position = cast(uint)_buffer.length;
    }

    void history_prev()
    {
        if (_history_cursor > 0)
        {
            if (_history_cursor == _history.length)
                _history_head = _buffer.move;
            --_history_cursor;
            _buffer = _history[_history_cursor][];
            _position = cast(uint)_buffer.length;
        }
    }

    void history_next()
    {
        if (_history_cursor < _history.length)
        {
            ++_history_cursor;
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

    void handle_tab_completion()
    {
        if (_suggestion_pending)
        {
            Array!String suggestions = _console.suggest(_buffer[], _cur_scope);
            if (!suggestions.empty)
                show_suggestions(suggestions[]);
            _suggestion_pending = false;
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
                _suggestion_pending = true;
        }
    }

    void echo_diff(const(char)[] before, uint before_pos)
    {
        import urt.util : min;

        if (!(_features & ClientFeatures.escape))
            return;

        size_t diff_offset = 0;
        size_t dlen = min(_buffer.length, before.length);
        while (diff_offset < dlen && before[diff_offset] == _buffer[diff_offset])
            ++diff_offset;
        bool no_change = _buffer.length == before.length && diff_offset == _buffer.length;

        MutableString!0 echo;
        if (no_change)
        {
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
                if (diff_offset < before_pos)
                    echo.concat("\x1b[", before_pos - diff_offset, 'D');
                else
                    echo.concat("\x1b[", diff_offset - before_pos, 'C');
            }

            if (diff_offset < _buffer.length)
                echo.append(_buffer[diff_offset .. $]);

            if (_buffer.length < before.length)
                echo.append("\x1b[K");

            if (echo.length && _position != _buffer.length)
            {
                assert(_position < _buffer.length);
                echo.append("\x1b[", _buffer.length - _position, 'D');
            }
        }

        if (echo.length)
            write_output(echo[], false);
    }

    void clear_line()
    {
        write_output("\r\x1b[K", false);
    }

    void send_prompt_and_buffer(bool with_clear = false)
    {
        import urt.string.format;

        if (_features & ClientFeatures.escape)
        {
            char[] prompt = tformat("{0, ?1}{2}{3}\x1b[K{@5, ?4}", "\r", with_clear, _prompt, _buffer, _position < _buffer.length, "\x1b[{6}D", _buffer.length - _position);
            write_output(prompt, false);
        }
        else
        {
            if (with_clear)
                write_output("\r", false);
            char[] prompt = tformat("{0}{1}", _prompt, _buffer);
            write_output(prompt, false);
        }
    }

package:
    Console* _console;
    Scope _cur_scope = null;

    ref CommandState current_command() => _current_command;
}

// TODO: DELETE THIS IF WE INTRODUCE A MemoryStream or BufferStream??
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

