module manager.console.session;

import urt.array;
import urt.file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.reclaim;
import urt.result;
import urt.string;
import urt.string.ansi;
import urt.util;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

import router.stream;

nothrow @nogc:


enum default_console_session_name = "default";


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


enum TerminalProfile : ubyte
{
    dumb,
    nvt,
    vt100,
    ansi,
    xterm,
    windows,
}


ClientFeatures terminal_features(TerminalProfile profile) pure
{
    final switch (profile)
    {
        case TerminalProfile.dumb:
        case TerminalProfile.nvt:
            return ClientFeatures.nvt;
        case TerminalProfile.vt100:
            return cast(ClientFeatures)(ClientFeatures.vt100 | ClientFeatures.crlf);
        case TerminalProfile.ansi:
            return cast(ClientFeatures)(ClientFeatures.ansi | ClientFeatures.crlf);
        case TerminalProfile.xterm:
            return cast(ClientFeatures)(ClientFeatures.xterm | ClientFeatures.crlf);
        case TerminalProfile.windows:
            return ClientFeatures.windows;
    }
}

// Out-of-band terminal events delivered via TerminalChannel
enum TerminalEvents : ubyte
{
    none             = 0,
    resized          = 1 << 0,
    features_changed = 1 << 1,
    interrupt        = 1 << 2,
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

class Session : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("profile", profile),
                                 Prop!("history", history),
                                 Prop!("initial-command", initial_command));
nothrow @nogc:

    enum type_name = "console-session";
    enum path = "/console/session";
    enum collection_id = CollectionType.console_session;
    enum syncable = false;
    enum max_history_entries = 50;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        this(id, flags, g_app.console);
    }

    this(CID id, ObjectFlags flags, ref Console console)
    {
        super(collection_type_info!Session, id, flags);
        _console = &console;
        _prompt_suffix = "> ";
        _cur_scope = console.root;
        set_prompt(console.get_prompt());
    }

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream value)
    {
        if (_stream.get is value)
            return;
        unsubscribe_stream();
        _stream = value;
        mark_set!(typeof(this), "stream")();
        restart();
    }

    final TerminalProfile profile() const pure
        => _profile;
    final void profile(TerminalProfile value)
    {
        _profile = value;
        _profile_set = true;
        _features = terminal_features(value);
        _features_override = true;
        mark_set!(typeof(this), "profile")();
    }

    final ref const(String) history() const pure
        => _history_path;
    final void history(String value)
    {
        if (_history_path == value)
            return;
        _history_path = value.move;
        mark_set!(typeof(this), "history")();
        restart();
    }

    final ref const(String) initial_command() const pure
        => _initial_command;
    final void initial_command(String value)
    {
        if (_initial_command == value)
            return;
        _initial_command = value.move;
        mark_set!(typeof(this), "initial-command")();
        restart();
    }

    final bool attached() const pure
        => _started && !_close_requested && !_destroy_requested;

    final bool is_attached() const pure
        => attached();

    override bool validate() const pure
        => (_stream !is null && _profile_set) || (_flags & ObjectFlags.dynamic);

    override CompletionStatus startup()
    {
        Stream s = _stream;
        if (s)
        {
            if (!s.running)
                return CompletionStatus.continue_;

            s.subscribe(&stream_state_change);
            _stream_subscribed = true;
        }

        _close_requested = false;
        _destroy_requested = false;
        _closing = false;
        _started = true;
        _show_prompt = false;

        static if (has_all)
        {
            import protocol.telnet.stream : TelnetStream;
            _nvt_input = dyn_cast!TelnetStream(s) !is null;
        }
        rebuild_prompt();

        if (s)
        {
            auto term = s.terminal_channel();
            if (term)
            {
                if (!_profile_set)
                    _features = term.features;
                _width = cast(ushort)term.width;
                _height = cast(ushort)term.height;
            }
        }

        if (!_history_path.empty)
            load_history(_history_path[]);
        if (!_initial_command.empty)
        {
            Array!char command;
            command ~= _initial_command[];
            if (!_console.execute_script(this, command.move))
                return CompletionStatus.error;
        }
        if (!(_flags & ObjectFlags.dynamic))
            show_prompt(true);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_stream();

        if (_current_command)
        {
            _current_command.request_cancel();
            if (_current_command.update() < CommandCompletionState.finished)
                return CompletionStatus.continue_;
            free(_current_command);
            _current_command = null;
        }

        close_history();
        _buffer.clear();
        _position = 0;
        _suggestion_pending = false;
        _history.clear();
        _history_cursor = 0;
        _history_head.clear();
        _cur_scope = _console.root;
        _executing_context = null;
        _session_locals.clear();
        _return_value = Variant();
        _returning = false;
        _closing = false;
        _started = false;

        Stream s = _stream;
        if ((_flags & ObjectFlags.dynamic) && s &&
            (s.flags & ObjectFlags.dynamic) && !(s.flags & ObjectFlags.disabled))
            s.destroy();

        return CompletionStatus.complete;
    }

    override void update()
    {
        Stream s = _stream;
        if (s)
        {
            enum BufLen = 512;
            char[BufLen] recvbuf = void;

            ptrdiff_t r;
            do
            {
                r = s.read(recvbuf[]);
                if (r < 0)
                {
                    restart();
                    return;
                }
                if (r > 0)
                {
                    if (_current_command && _current_command.consumes_input())
                        _current_command.receive_input(recvbuf[0 .. r]);
                    else
                        receive_input(recvbuf[0 .. r]);
                }
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

                echo_result(commandData.result);
                command_finished(commandData, state);
                free(commandData);

                if (_closing)
                {
                    _closing = false;
                    finish_close();
                    return;
                }

                MutableString!0 input = take_input();
                receive_input(input[]);
            }
        }
    }

    final bool is_idle() const pure
        => _current_command is null;

    final void close_session()
    {
        if (_current_command)
        {
            _current_command.request_cancel();

            if (_current_command.update() >= CommandCompletionState.finished)
            {
                free(_current_command);
                _current_command = null;
            }
            else
            {
                _closing = true;
                return;
            }
        }

        finish_close();
    }

    final void request_destroy()
    {
        if (_destroy_requested)
            return;
        _destroy_requested = true;
        destroy();
    }

    final ushort width() const pure
        => _width;
    final ushort height() const pure
        => _height;
    final ClientFeatures features() const pure
        => _features;
    final const(char)[] terminal_type()
    {
        if (!_stream)
            return null;
        auto term = _stream.terminal_channel();
        return term ? term.terminal_type : null;
    }

    ptrdiff_t write_raw(const(void)[] data)
    {
        if (!_stream)
            return -1;
        return _stream.write(data);
    }

    void write_output(const(char)[] text, bool newline)
    {
        if (_stream)
        {
            if (text.length > 0)
            {
                if (_features & ClientFeatures.crlf)
                {
                    // convert bare \n (not preceded by \r) to \r\n for NVT clients
                    size_t written = 0, search = 0;
                    while (search < text.length)
                    {
                        size_t pos = text[search .. $].findFirst('\n');
                        if (pos == text.length - search)
                            break;
                        pos += search;
                        if (pos == 0 || text[pos - 1] != '\r')
                        {
                            _stream.write(text[written .. pos]);
                            _stream.write("\r\n");
                            written = pos + 1;
                        }
                        search = pos + 1;
                    }
                    if (written < text.length)
                        _stream.write(text[written .. $]);
                }
                else
                    _stream.write(text);
            }
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
        const(char)[] old = _prompt_suffix.swap(prompt);
        if (prompt[] != old[])
            rebuild_prompt();
        return old;
    }

    package final void set_scope(Scope* s)
    {
        if (_cur_scope is s)
            return;
        _cur_scope = s;
        rebuild_prompt();
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
                else if (t[i] == '\x15') // Ctrl+U - kill line
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
        _features_override = true;
        if (w) _width = w;
        if (h) _height = h;
    }

    final Array!String suggest(const(char)[] text)
        => _console.suggest(text, _cur_scope);

    void set_local(const(char)[] name, ref const Variant value)
    {
        _session_locals[make_string(name)] = value;
    }

protected:
    void enter_command(const(char)[])
    {
        if (_features & ClientFeatures.escape)
            write_output("", true);
    }

    void command_finished(CommandState, CommandCompletionState)
    {
        if (_show_prompt && (_features & ClientFeatures.escape))
            send_prompt_and_buffer(false);
    }

    void show_suggestions(const(String)[] suggestions)
    {
        if (_features & ClientFeatures.escape)
            write_output("", true);

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
                import manager.expression : skip_whitespace_and_newlines;
                MutableString!0 cmdInput = take_input();
                const(char)[] command = cmdInput[];
                skip_whitespace_and_newlines(command);
                _buffer = input[taken + 1 .. $];

                Variant result;
                if (command.empty || execute(command, result))
                {
                    // possible the command terminated the session
                    if (!is_attached())
                        return;

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

        char[] mem = cast(char[])alloc(file_size);
        if (mem == null)
        {
            writeError("Error allocating memory for history");
            return;
        }

        scope(exit)
            free(mem);

        _history_file.read(mem, file_size);

        char[] buff = mem.trim;
        while (!buff.empty)
        {
            // take the next line
            const(char)[] line = buff.split!('\n', false);
            if (!line.empty)
            {
                _history ~= MutableString!0(line);
                trim_history();
            }
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
            trim_history();

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
        {
            echo_result(result);
            command_finished(null, CommandCompletionState.finished);
        }
        return _current_command is null;
    }

    final void echo_result(ref const Variant result)
    {
        if (result.isNull)
            return;
        ptrdiff_t l = result.toString(null, null, null);
        if (l <= 0)
            return;
        Array!char buffer;
        l = result.toString(buffer.extend(l), null, null);
        write_line(buffer[0..l]);
    }

private:
    ObjectRef!Stream _stream;
    String _history_path;
    String _initial_command;

    ClientFeatures _features;
    ushort _width = 80;
    ushort _height = 24;
    TerminalProfile _profile;

    bool _show_prompt = false;
    bool _suggestion_pending = false;
    bool _started = false;
    bool _closing = false;
    bool _close_requested = false;
    bool _destroy_requested = false;
    bool _nvt_input = false;
    bool _stream_subscribed = false;
    bool _features_override = false;
    bool _profile_set = false;

    const(char)[] _prompt_suffix;
    MutableString!0 _prompt;
    MutableString!0 _buffer;
    uint _position = 0;

    CommandState _current_command = null;

    Array!(MutableString!0) _history;
    uint _history_cursor = 0;
    MutableString!0 _history_head;
    File _history_file;

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.online)
            return;
        unsubscribe_stream();
        if (_stream && (_stream.flags & ObjectFlags.temporary))
            _stream = null;
        restart();
    }

    void unsubscribe_stream()
    {
        if (_stream_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _stream_subscribed = false;
        }
    }

    void finish_close()
    {
        _close_requested = true;
        // a configured session has no client to hand back to, so it re-offers a prompt
        if (_flags & (ObjectFlags.dynamic | ObjectFlags.temporary))
            request_destroy();
        else
            restart();
    }

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
            if (!_features_override)
                _features = term.features;
            term.pending_events &= ~TerminalEvents.features_changed;
            if (_show_prompt && (_features & ClientFeatures.escape))
                send_prompt_and_buffer(true);
        }
        if (term.pending_events & TerminalEvents.interrupt)
        {
            term.pending_events &= ~TerminalEvents.interrupt;
            char[1] ctrl_c = ['\x03'];
            if (_current_command && _current_command.consumes_input())
                _current_command.receive_input(ctrl_c[]);
            else
                receive_input(ctrl_c[]);
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

    ReclaimResult reclaim_history(size_t bytes_needed, out bool reclaimed)
    {
        reclaimed = false;
        if (!bytes_needed)
            return ReclaimResult.exhausted;
        foreach (i, ref entry; _history[])
        {
            if (!entry.ptr || entry.capacity + 4 < bytes_needed)
                continue;
            size_t count = i + 1;
            _history.remove(0, count);
            _history_cursor = _history_cursor >= count ? _history_cursor - cast(uint)count : 0;
            reclaimed = true;
            return ReclaimResult.more;
        }

        bool satisfied = _history.ptr && _history.capacity * MutableString!0.sizeof >= bytes_needed;
        // Moving into locals is the back door to free the backing allocations on scope exit.
        Array!(MutableString!0) history = _history.move;
        reclaimed = history.ptr !is null;
        _history_cursor = 0;
        if (satisfied)
            return _history_head.ptr ? ReclaimResult.more : ReclaimResult.exhausted;

        MutableString!0 head = _history_head.move;
        reclaimed |= head.ptr !is null;
        return ReclaimResult.exhausted;
    }

    bool has_reclaimable_history() const pure
        => _history.ptr !is null || _history_head.ptr !is null;

    void trim_history()
    {
        while (_history.length > max_history_entries)
        {
            _history.popFront();
            if (_history_cursor > 0)
                --_history_cursor;
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
            char[] prompt = tformat("{0, ?1}{2}{3}\x1b[K{@5, ?4}", "\r", with_clear, _prompt[], _buffer, _position < _buffer.length, "\x1b[{6}D", _buffer.length - _position);
            write_output(prompt, false);
        }
        else
        {
            if (with_clear)
                write_output("\r", false);
            char[] prompt = tformat("{0}{1}", _prompt[], _buffer);
            write_output(prompt, false);
        }
    }

    void rebuild_prompt()
    {
        MutableString!0 buf;
        buf ~= '[';
        append_scope_path(buf, _cur_scope);
        buf ~= ']';
        buf ~= _prompt_suffix;

        if (buf[] == _prompt[])
            return;
        _prompt = buf.move;

        if ((_features & ClientFeatures.escape) && !_current_command && _executing_context is null && _show_prompt)
            send_prompt_and_buffer(true);
    }

    void append_scope_path(ref MutableString!0 buf, Scope* s)
    {
        if (s is null || s.parent(*_console) is null)
        {
            buf ~= '/';
            return;
        }
        walk_scope_path(buf, s);
    }

    void walk_scope_path(ref MutableString!0 buf, Scope* s)
    {
        Scope* p = s.parent(*_console);
        if (p is null)
            return;
        walk_scope_path(buf, p);
        buf ~= '/';
        buf ~= s.name[];
    }

package:
    Console* _console;
    Scope* _cur_scope = null;
    Context _executing_context = null;
    Map!(String, Variant) _session_locals;
    Variant _return_value;
    bool _returning = false;

    ref CommandState current_command() => _current_command;
}

// TODO: DELETE THIS IF WE INTRODUCE A MemoryStream or BufferStream??
class StringSession : Session
{
nothrow @nogc:

    this(CID id, ObjectFlags flags, ref Console console)
    {
        super(id, flags, console);
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


class ConsoleSessionModule : Module
{
    mixin DeclareModule!"console.session";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!TerminalProfile();
        g_app.console.register_collection!Session();

        bool registered = register_reclaimer(&reclaim_history, 180, false);
        debug assert(registered, "console history reclaimer registration failed");
    }

    override void deinit()
    {
        unregister_reclaimer(&reclaim_history);
    }

    override void update()
    {
        Collection!Session().update_all();
    }

private:
    ReclaimResult reclaim_history(size_t bytes_needed)
    {
        foreach (session; Collection!Session().values)
        {
            bool reclaimed;
            ReclaimResult result = session.reclaim_history(bytes_needed, reclaimed);
            if (!reclaimed)
                continue;
            if (result == ReclaimResult.more)
                return result;
            foreach (remaining; Collection!Session().values)
                if (remaining.has_reclaimable_history())
                    return ReclaimResult.more;
            return ReclaimResult.exhausted;
        }
        return ReclaimResult.exhausted;
    }
}


version (unittest):

private class SessionTestStream : Stream
{
nothrow @nogc:

    enum type_name = "session-test-stream";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SessionTestStream, id, flags);
    }

    override ptrdiff_t read(void[])
        => 0;

    override ptrdiff_t write(const(void[])[] data...)
    {
        size_t written;
        foreach (d; data)
        {
            _output ~= cast(const(ubyte)[])d;
            written += d.length;
        }
        return written;
    }

    const(ubyte)[] output() const pure
        => _output[];

private:
    Array!ubyte _output;
}


unittest
{
    import urt.mem;

    Console* console = alloc!Console(null, StringLit!"test.session");

    SessionTestStream stream = Collection!SessionTestStream().create("session-test-stream");
    assert(stream && stream.running);

    auto sessions = Collection!Session();
    CID id = sessions.allocate_id("configured-session-test");
    Session session = alloc!Session(id, ObjectFlags.none, *console);
    session.stream(stream);
    session.profile(TerminalProfile.dumb);
    session.initial_command(StringLit!":put started");
    sessions.add(session);
    session.do_update();

    assert(session.running);
    assert(session.attached());
    assert(cast(const(char)[])stream.output == "started\r\n");

    session.add_to_history("one");
    session.add_to_history("two");
    session.add_to_history("three");
    session.history_prev();
    assert(session._buffer[] == "three");
    bool reclaimed;
    assert(session.reclaim_history(size_t.max, reclaimed) == ReclaimResult.exhausted && reclaimed);
    assert(session._history.empty);
    assert(session._history_cursor == 0);

    session.destroy();
    sessions.update_all();

    StringSession temporary = console.createSession!StringSession();
    Variant result;
    console.execute(temporary, ":exit", result);
    console.destroy_session(temporary);
    sessions.update_all();

    stream.destroy();
    Collection!Stream().update_all();
}

