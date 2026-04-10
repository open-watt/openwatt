module router.stream.console;

import urt.io;
import urt.log;
import urt.mem.allocator;
import urt.string : StringLit;
import urt.string;
import urt.string.ansi;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.session;
import manager.plugin;

import router.stream;

version (Windows)
{
    import urt.internal.sys.windows;

    extern(Windows) BOOL SetConsoleOutputCP(UINT wCodePageID) nothrow @nogc;
}
else version (Posix)
{
    import urt.internal.sys.posix;
    import urt.internal.sys.posix.termios;
}

nothrow @nogc:


class ConsoleStream : Stream
{
nothrow @nogc:

    enum type_name = "console";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ConsoleStream, id, flags);
    }

    override TerminalChannel* terminal_channel()
        => &_terminal;

    override const(char)[] remote_name()
        => "console";

    override ptrdiff_t read(void[] buffer)
    {
        version (Windows)
            return read_console_input(buffer);
        else version (Posix)
            return urt.internal.sys.posix.read(STDIN_FILENO, buffer.ptr, buffer.length);
        else version (Embedded)
            return 0;
        else
            static assert(false, "Unsupported platform");
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        ptrdiff_t total = 0;
        foreach (d; data)
        {
            auto n = write_console(cast(const(char)[])d);
            if (n < 0)
                return -1;
            total += n;
        }
        return total;
    }

    override ptrdiff_t pending()
    {
        version (Windows)
        {
            DWORD num_events = 0;
            GetNumberOfConsoleInputEvents(_h_stdin, &num_events);
            return cast(ptrdiff_t)num_events;
        }
        else
            return 0;
    }

    override ptrdiff_t flush()
    {
        urt.io.flush!();
        return 0;
    }

    override CompletionStatus startup()
    {
        setup_terminal();
        _terminal.pending_events |= TerminalEvents.features_changed | TerminalEvents.resized;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        restore_terminal();
        return CompletionStatus.complete;
    }

private:
    TerminalChannel _terminal;
    bool _terminal_restored;

    version (Windows)
    {
        HANDLE _h_stdin;
        HANDLE _h_stdout;
        HANDLE _h_stderr;
        DWORD _original_input_mode;
        DWORD _original_output_mode;
        DWORD _original_stderr_mode;
    }
    else version (Posix)
    {
        termios _original_termios;
    }

    void setup_terminal()
    {
        version (Windows)
        {
            _h_stdin = GetStdHandle(STD_INPUT_HANDLE);
            _h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
            _h_stderr = GetStdHandle(STD_ERROR_HANDLE);

            _terminal.features = cast(ClientFeatures)(ClientFeatures.crlf | ClientFeatures.ansi);

            SetConsoleOutputCP(65001); // UTF-8

            GetConsoleMode(_h_stdin, &_original_input_mode);
            GetConsoleMode(_h_stdout, &_original_output_mode);
            GetConsoleMode(_h_stderr, &_original_stderr_mode);

            SetConsoleMode(_h_stdout, _original_output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            SetConsoleMode(_h_stderr, _original_stderr_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            SetConsoleMode(_h_stdin, ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS | ENABLE_QUICK_EDIT_MODE);

            CONSOLE_SCREEN_BUFFER_INFO csbi;
            if (GetConsoleScreenBufferInfo(_h_stdout, &csbi))
            {
                _terminal.width = cast(uint)(csbi.srWindow.Right - csbi.srWindow.Left + 1);
                _terminal.height = cast(uint)(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
            }
        }
        else version (Posix)
        {
            tcgetattr(STDIN_FILENO, &_original_termios);

            termios raw = _original_termios;
            raw.c_lflag &= ~(ICANON | ECHO);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 0;
            tcsetattr(STDIN_FILENO, TCSANOW, &raw);

            int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
            fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

            _terminal.features = cast(ClientFeatures)(ClientFeatures.crlf | ClientFeatures.ansi);
        }
    }

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
        else version (Posix)
        {
            tcsetattr(STDIN_FILENO, TCSANOW, &_original_termios);
        }

        _terminal_restored = true;
    }

    ptrdiff_t write_console(const(char)[] text)
    {
        if (text.length == 0)
            return 0;

        version (Windows)
        {
            DWORD written;
            WriteConsoleA(_h_stdout, text.ptr, cast(DWORD)text.length, &written, null);
            return cast(ptrdiff_t)written;
        }
        else version (Posix)
            return urt.internal.sys.posix.write(STDOUT_FILENO, text.ptr, text.length);
        else
            return urt.io.write(text);
    }

    version (Windows)
    {
        ptrdiff_t read_console_input(void[] buffer) // @suppress(dscanner.confusing.builtin_property_names)
        {
            DWORD num_events = 0;
            GetNumberOfConsoleInputEvents(_h_stdin, &num_events);
            if (num_events == 0)
                return 0;

            char[] out_buf = cast(char[])buffer;
            size_t out_pos = 0;

            INPUT_RECORD[32] events = void;
            DWORD events_read;
            while (num_events && ReadConsoleInputA(_h_stdin, events.ptr, num_events < events.length ? num_events : events.length, &events_read))
            {
                num_events -= events_read;

                for (DWORD i = 0; i < events_read; ++i)
                {
                    if (events[i].EventType == WINDOW_BUFFER_SIZE_EVENT)
                    {
                        // re-query actual visible window size (not buffer size)
                        CONSOLE_SCREEN_BUFFER_INFO csbi;
                        if (GetConsoleScreenBufferInfo(_h_stdout, &csbi))
                        {
                            _terminal.width = cast(uint)(csbi.srWindow.Right - csbi.srWindow.Left + 1);
                            _terminal.height = cast(uint)(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
                        }
                        _terminal.pending_events |= TerminalEvents.resized;
                        continue;
                    }

                    if (events[i].EventType != KEY_EVENT || !events[i].KeyEvent.bKeyDown)
                        continue;

                    char ch = events[i].KeyEvent.AsciiChar;
                    if (ch != 0)
                    {
                        if (out_pos < out_buf.length)
                            out_buf[out_pos++] = ch;
                    }
                    else
                    {
                        WORD vk = events[i].KeyEvent.wVirtualKeyCode;
                        DWORD controlKeyState = events[i].KeyEvent.dwControlKeyState;

                        // translate virtual keys to ANSI sequences
                        const(char)[] seq;
                        if (vk == VK_UP)
                            seq = ANSI_ARROW_UP;
                        else if (vk == VK_DOWN)
                            seq = ANSI_ARROW_DOWN;
                        else if (vk == VK_LEFT)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                seq = "\x1b[1;5D";
                            else
                                seq = ANSI_ARROW_LEFT;
                        }
                        else if (vk == VK_RIGHT)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                seq = "\x1b[1;5C";
                            else
                                seq = ANSI_ARROW_RIGHT;
                        }
                        else if (vk == VK_HOME)
                            seq = ANSI_HOME1;
                        else if (vk == VK_END)
                            seq = ANSI_END1;
                        else if (vk == VK_DELETE)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                seq = "\x1b[3;5~";
                            else
                                seq = ANSI_DEL;
                        }
                        else if (vk == VK_PRIOR)
                            seq = ANSI_PGUP;
                        else if (vk == VK_NEXT)
                            seq = ANSI_PGDN;
                        else if (vk == VK_BACK)
                        {
                            if (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))
                                seq = "\x17"; // Ctrl+Backspace → Ctrl+W
                            else
                                seq = "\b";
                        }

                        if (seq.length > 0 && out_pos + seq.length <= out_buf.length)
                        {
                            out_buf[out_pos .. out_pos + seq.length] = seq;
                            out_pos += seq.length;
                        }
                    }
                }
            }

            return cast(ptrdiff_t)out_pos;
        }

    }
}

class ConsoleStreamModule : Module
{
    mixin DeclareModule!"stream.console";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!ConsoleStream("/stream/console");
    }
}
