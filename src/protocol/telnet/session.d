module protocol.telnet.session;

import urt.array;
import urt.string;
import urt.string.ansi;

import manager.base;
import manager.console;
import manager.console.session;

import router.stream;

import urt.file;
import urt.result;
import urt.log;
import urt.mem.allocator;

version = TelnetDebug;

nothrow @nogc:


enum TELNET_ERASE_LINE = "\xff\xf8";

enum TelnetOptions : ubyte
{
    ECHO                = 1,
    SUPPRESS_GO_AHEAD   = 3,
    STATUS              = 5,
    TIMING_MARK         = 6,
    LOGOUT              = 18,
    TERMINAL_TYPE       = 24,
    WINDOW_SIZE         = 31,
    TERMINAL_SPEED      = 32,
    REMOTE_FLOW_CONTROL = 33,
    LINE_MODE           = 34,
    ENVIRONMENT         = 36,
    AUTHENTICATION      = 37,
    ENCRYPTION          = 38,
    CHARSET             = 42
}


class TelnetSession : Session
{
nothrow @nogc:

    this(ref Console console, Stream clientStream)
    {
        super(console);
        this._stream = clientStream;

        will(TelnetOptions.ECHO);
        dont(TelnetOptions.ECHO, true);
        will(TelnetOptions.SUPPRESS_GO_AHEAD);
        do_(TelnetOptions.TERMINAL_TYPE);
        do_(TelnetOptions.WINDOW_SIZE);
        do_(TelnetOptions.CHARSET);

        load_history(".telnet_history");
    }

    override void update()
    {
        super.update();

        if (!_stream)
        {
            close_session();
            return;
        }

        enum DefaultBufferLen = 512;
        ubyte[DefaultBufferLen] recvbuf = void;

        Array!(char, 0) input; // allocate some stack-local buffer...

        size_t bytes = _tail.length;
        recvbuf[0 .. bytes] = _tail[];
        while (true)
        {
            ptrdiff_t r = _stream.read(recvbuf[bytes .. $]);
            if (r < 0)
            {
                close_session();
                return;
            }
            if (r == 0)
                break;

            bytes += r;
            input.reserve(input.length + bytes);

            size_t i = 0;
            for (; i < bytes; ++i)
            {
                if (recvbuf[i] == NVT.IAC)
                {
                    // NVT command
                    if (i >= bytes - 1)
                        break;

                    NVT cmd = cast(NVT)recvbuf[++i];
                    switch (cmd)
                    {
                        case NVT.NOP:
                            break;

                        case NVT.DM: // Data Mark
                            // mark the position in the data stream where a Telnet break or interruption occurred
                            assert(false, "TODO: what is this for?");
                            break;

                        case NVT.BRK: // Break
                            // sender has initiated a break (interrupt) signal
                            input ~= '\x03';
                            break;

                        case NVT.IP: // Interrupt Process
                            // interrupt the process running on the remote system
                            // TODO: maybe this should completely terminate a running script?
                            //       for now, it's just a synonym for F3
                            input ~= '\x03';
                            break;

                        case NVT.AO: // Abort Output
                            // command the remote system to stop sending output but allows the process to continue running
                            // this is to silence a chatty process; when should this stop though?
                            // TODO: for now, do nothing. now sure what to do with this...
                            break;

                        case NVT.AYT: // Are You There
                            // check if the remote server is still connected and responding
                            // emit the BELL, or should we write some text, like "[I'M HERE]"?
//                            stream.write("[I'M HERE]");
                            _stream.write("\a"); // bell
                            break;

                        case NVT.EC: // Erase Character
                            // translate the backspace character
                            input ~= '\b'; // backspace
                            break;

                        case NVT.EL: // Erase Line
                            // erase the entire current line of input
                            // to do this correctly, I think we must flush the buffer to this point, and then clear the buffer, and then continue...
                            receive_input(input[]);
                            input.clear();
                            _buffer.clear();
                            _position = 0;
                            break;

                        case NVT.GA: // Go Ahead
                            // indicate that the sender is finished, and the receiver may start sending data. this is primarily used in "line-at-a-time" mode.
                            // TODO: I don't think we have any use for this?
                            assert(false, "TODO: maybe find a way to test this...?");
                            break;

                        case NVT.SB:
                            size_t subNvt = i + 1;
                            while (subNvt < bytes - 2 && recvbuf[subNvt] != NVT.IAC && recvbuf[subNvt + 1] != NVT.SE)
                                ++subNvt;
                            if (subNvt >= bytes - 1)
                            {
                                // this subnegotiation wasn't closed. we must have an incomplete stream...
                                break;
                            }

                            const(ubyte)[] sub = recvbuf[i + 1 .. subNvt];
                            i = subNvt + 1;

                            // handle sub commands...
                            if (sub.length > 0)
                            {
                                switch (sub[0])
                                {
                                    case TelnetOptions.TERMINAL_TYPE:
                                        if (sub.length < 1)
                                            break; // TODO: this is a broken request; drop it I guess?
                                        if (sub[1] == 0x00)
                                        {
                                            // got remote terminal type...
                                            const(char)[] tt = cast(const(char)[])sub[2 .. $];
                                            // TODO: and now what?

                                            version (TelnetDebug)
                                                debug writeDebugf("Telnet: <-- TERMINAL-TYPE: {0}", tt);
                                        }
                                        break;
                                    case TelnetOptions.WINDOW_SIZE:
                                        if (sub.length == 5)
                                        {
                                            _width = cast(uint)sub[1] << 8 | (cast(uint)sub[2]);
                                            _height = cast(uint)sub[3] << 8 | (cast(uint)sub[4]);
                                        }
                                        break;
                                    case TelnetOptions.CHARSET:
                                        assert(false, "test this path");
                                        break;
                                    default:
                                        writeWarningf("Unsupported NVT subnegotiation: \\\\x{0, 02x}", cast(ubyte)sub[0]);
                                        break;
                                }
                            }
                            break;

                        case NVT.WILL:
                        case NVT.WONT:
                        case NVT.DO:
                        case NVT.DONT:
                            if (i >= bytes - 1)
                                break;
                            TelnetOptions opt = cast(TelnetOptions)recvbuf[++i];

                            NVT response;
                            switch (cmd)
                            {
                                case NVT.WILL:
                                    bool activated = false;
                                    if (_client_state_req & (1UL << opt))
                                    {
                                        if (!(_client_state & (1UL << opt)))
                                            activated = true;

                                        // request was granted
                                        _client_state |= 1UL << opt;
                                    }
                                    else
                                    {
                                        // do we want this option?
                                        if (SupportedOptions & (1UL << opt))
                                        {
                                            _client_state |= 1UL << opt;
                                            _client_state_req |= 1UL << opt;
                                            activated = true;
                                            response = NVT.DO;
                                        }
                                        else
                                            response = NVT.DONT;
                                    }

                                    if (activated)
                                    {
                                        if (opt == TelnetOptions.TERMINAL_TYPE)
                                        {
                                            // client has agreed to negotiate terminal type; we'll request "ANSI"
                                            // or should we send "XTERM"?
                                            ubyte[6] t = [ NVT.IAC, NVT.SB, TelnetOptions.TERMINAL_TYPE, 0x01, NVT.IAC, NVT.SE ];
                                            _stream.write(t);
                                        }
                                    }

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- WILL {0}", opt);
                                    break;

                                case NVT.WONT:
                                    _client_state &= ~(1UL << opt);
                                    if (_client_state_req & (1UL << opt))
                                    {
                                        _client_state_req ^= 1UL << opt;
                                        response = NVT.DONT;
                                    }

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- WON'T {0}", opt);
                                    break;

                                case NVT.DO:
                                    if (_server_state & (1UL << opt))
                                    {
                                        // offer was accepted
                                        _server_state_req |= 1UL << opt;
                                    }
                                    else
                                    {
                                        // do we handle any option requests?
                                        if (SupportedOptions & (1UL << opt))
                                        {
                                            _server_state |= 1UL << opt;
                                            _server_state_req |= 1UL << opt;
                                            response = NVT.WILL;

                                            if (opt == TelnetOptions.CHARSET)
                                            {
                                                assert(false, "this was never tested! not clear if we should transmit the space or not?");
                                                // client has agreed to negotiate character set; we'll request UTF8...
                                                write("\xff\xfa\x2a\x01 UTF-8\xff\xf0");
                                            }
                                        }
                                        else
                                            response = NVT.WONT;
                                    }

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- DO {0}", opt);
                                    break;

                                case NVT.DONT:
                                    _server_state &= ~(1UL << opt);
                                    _server_state_req &= ~(1UL << opt);
                                    response = NVT.WONT;

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- DON'T {0}", opt);
                                    break;

                                default:
                                    assert(false, "Unreachable");
                            }
                            if (response)
                            {
                                ubyte[3] t = [ NVT.IAC, response, opt ];
                                _stream.write(t);

                                debug version (TelnetDebug)
                                {
                                    __gshared immutable string[] responses = [ "WILL", "WON'T", "DO", "DON'T" ];
                                    writeDebugf("Telnet: --> {0} {1}", responses[response - NVT.WILL], opt);
                                }
                            }
                            break;

                        case '\xff':
                            input ~= '\xff';
                            break;

                        default:
                            // surprise NVT command?
                            writeWarningf("Unknown NVT command: \\\\x{0, 02x}", cast(ubyte)cmd);
                            break;
                    }
                }
                else if (recvbuf[i] == '\r')
                {
                    if (i == bytes - 1)
                        break;

                    if (recvbuf[++i] == '\0')
                        input ~= '\r';
                    else if (recvbuf[i] == '\n')
                        input ~= '\n';
                    else
                    {
                        writeWarning("Unexpected character following '\\r'!");
                        assert(false, "TODO: attempt to reproduce or delete this assert");
                    }
                }
                else if (recvbuf[i] == '\0')
                {
                    writeWarning("Unexpected '\\0' byte in telnet stream");
                    // TODO: does this need investigation?
                    assert(false, "TODO: attempt to reproduce or delete this assert");
                    input ~= '\0';
                }
                else
                    input ~= char(recvbuf[i]);
            }

            if (i < bytes)
            {
                size_t tail = bytes - i;
                recvbuf[0 .. tail] = recvbuf[i .. bytes];
                bytes = tail;
            }
            else
                bytes = 0;
        }

        // dispatch input up to this point
//        size_t taken = receive_input(input[]);
        receive_input(input[]);

        // possible that not all bytes were consumed; there could have been incomplete ansi sequences, etc...
//        if (taken < input.length)
//        {
//            _tail = input[taken .. $];
//            _tail ~= recvbuf[0 .. bytes];
//        }
//        else
            _tail = recvbuf[0 .. bytes];
        return;
    }

    override void enter_command(const(char)[] command)
    {
        write("\r\n");
    }

    override void command_finished(CommandState command_state, CommandCompletionState state)
    {
        if (_show_prompt)
            send_prompt_and_buffer(false);
    }

    override void close_session()
    {
        super.close_session();

        if (!is_attached() && _stream)
        {
            _stream.destroy();
            _stream.release();
        }
    }


    override void write_output(const(char)[] text, bool newline)
    {
        // translate "\n" to "\r\n"
        // if no LF's are discovered, we don't allocate
        MutableString!0 convert;
        size_t line_start = 0;
        for (size_t i = 0; i < text.length; ++i)
        {
            if (text[i] == '\n')
            {
                if (line_start == 0)
                    convert.reserve(cast(ushort)(text.length + 64)); // reserve for a bunch of CR's

                convert.append(text[line_start .. i], "\r\n");
                line_start = i + 1;
            }
        }
        if (line_start != 0)
        {
            convert.append(text[line_start .. $]);
            text = convert[];
        }

        ptrdiff_t sent = _stream.write(text[]);
        if (newline)
            sent = _stream.write("\r\n");
    }

    override void show_suggestions(const(String)[] suggestions)
    {
        // move to next line
        ptrdiff_t sent = _stream.write("\r\n");

        // write the suggestions
        super.show_suggestions(suggestions);

        // put the prompt back
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

    override MutableString!0 set_input(const(char)[] text)
    {
        assert(false);
//        bcString r = dcConsoleSession.SetInput(bcMove(text));
//        if (!_current_command && _show_prompt)
//            send_prompt_and_buffer(true);
//        return r;
    }

    override ptrdiff_t append_input(const(char)[] text)
    {
        import urt.util : min;

        MutableString!0 before = _buffer;
        uint before_pos = _position;

        ptrdiff_t taken = super.append_input(text);
        if (taken < 0)
            return taken;

        // echo changes back to the terminal...
        if (server_enabled(TelnetOptions.ECHO))
        {
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
            {
                ptrdiff_t sent = _stream.write(echo[]);
            }
        }

        return taken;
    }

private:
    ObjectRef!Stream _stream;
    Array!ubyte _tail;

    ulong _server_state;
    ulong _server_state_req;
    ulong _client_state;
    ulong _client_state_req;

    bool server_enabled(TelnetOptions opt)
        => (_server_state & _server_state_req & (1UL << opt)) != 0;
    bool client_enabled(TelnetOptions opt)
        => (_client_state & _client_state_req & (1UL << opt)) != 0;

    void will(TelnetOptions opt)
    {
        if (_server_state & (1UL << opt))
            return;
        _server_state |= 1UL << opt;

        ubyte[3] t = [ NVT.IAC, NVT.WILL, cast(ubyte)opt ];
        _stream.write(t[]);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> WILL {0}", opt);
    }

    void wont(TelnetOptions opt, bool force)
    {
        if ((_server_state & (1UL << opt)) || force)
        {
            ubyte[3] t = [ NVT.IAC, NVT.WONT, cast(ubyte)opt ];
            _stream.write(t[]);
        }
        _server_state &= ~(1UL << opt);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> WON'T {0}", opt);
    }

    void do_(TelnetOptions opt)
    {
        if (_client_state_req & (1UL << opt))
            return;
        _client_state_req |= 1UL << opt;

        ubyte[3] t = [ NVT.IAC, NVT.DO, cast(ubyte)opt ];
        _stream.write(t[]);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> DO {0}", opt);
    }

    void dont(TelnetOptions opt, bool force)
    {
        if ((_client_state_req & (1UL << opt)) || force)
        {
            ubyte[3] t = [ NVT.IAC, NVT.DONT, cast(ubyte)opt ];
            _stream.write(t[]);
        }
        _client_state_req &= ~(1UL << opt);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> DON'T {0}", opt);
    }

    void clear_line()
    {
        enum Clear = ANSI_ERASE_LINE ~ "\x1b[80D"; // clear and move left 80

        _stream.write(Clear);
    }

    void send_prompt_and_buffer(bool withErase = false)
    {
        import urt.string.format;

        enum Clear = ANSI_ERASE_LINE ~ "\x1b[80D"; // clear and move left 80

        if (_position < _buffer.length)
        {
            import urt.dbg;
            breakpoint;
            // CHECK THAT THE INDIRECT FORMAT STRING WORKS...
            // then delete this code block...
        }

        char[] prompt = tformat("{0, ?1}{2}{3}{@5, ?4}", Clear, withErase, _prompt, _buffer, _position < _buffer.length, "\x1b[{6}D", _buffer.length - _position);
        ptrdiff_t sent = _stream.write(prompt);
    }
}


private:

enum ulong SupportedOptions = (1UL << TelnetOptions.ECHO) |
                              (1UL << TelnetOptions.SUPPRESS_GO_AHEAD) |
                              (1UL << TelnetOptions.TERMINAL_TYPE) |
                              (1UL << TelnetOptions.WINDOW_SIZE) |
                              (1UL << TelnetOptions.CHARSET);

enum NVT : ubyte
{
    NONE = 0x00,
    SE   = 0xf0,
    NOP  = 0xf1,
    DM   = 0xf2,
    BRK  = 0xf3,
    IP   = 0xf4,
    AO   = 0xf5,
    AYT  = 0xf6,
    EC   = 0xf7,
    EL   = 0xf8,
    GA   = 0xf9,
    SB   = 0xfa,
    WILL = 0xfb,
    WONT = 0xfc,
    DO   = 0xfd,
    DONT = 0xfe,
    IAC  = 0xff
}
