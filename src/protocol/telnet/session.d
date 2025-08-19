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
        this.m_stream = clientStream;

        clientStream.setOpts(StreamOptions.NonBlocking);

        will(TelnetOptions.ECHO);
        dont(TelnetOptions.ECHO, true);
        will(TelnetOptions.SUPPRESS_GO_AHEAD);
        do_(TelnetOptions.TERMINAL_TYPE);
        do_(TelnetOptions.WINDOW_SIZE);
        do_(TelnetOptions.CHARSET);

        parseHistory();
    }

    ~this()
    {
        if (m_historyFile.is_open())
            m_historyFile.close();

        closeSession();
    }

    override void update()
    {
        super.update();

        if (!m_stream)
        {
            closeSession();
            return;
        }

        enum DefaultBufferLen = 512;
        ubyte[DefaultBufferLen] recvbuf = void;

        Array!(char, 0) input; // allocate some stack-local buffer...

        size_t bytes = m_tail.length;
        recvbuf[0 .. bytes] = m_tail[];
        while (true)
        {
            ptrdiff_t r = m_stream.read(recvbuf[bytes .. $]);
            if (r < 0)
            {
                closeSession();
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
                            m_stream.write("\a"); // bell
                            break;

                        case NVT.EC: // Erase Character
                            // translate the backspace character
                            input ~= '\b'; // backspace
                            break;

                        case NVT.EL: // Erase Line
                            // erase the entire current line of input
                            // to do this correctly, I think we must flush the buffer to this point, and then clear the buffer, and then continue...
                            receiveInput(input[]);
                            input.clear();
                            m_buffer.clear();
                            m_position = 0;
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
                                            m_width = cast(uint)sub[1] << 8 | (cast(uint)sub[2]);
                                            m_height = cast(uint)sub[3] << 8 | (cast(uint)sub[4]);
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
                                    if (clientStateReq & (1UL << opt))
                                    {
                                        if (!(clientState & (1UL << opt)))
                                            activated = true;

                                        // request was granted
                                        clientState |= 1UL << opt;
                                    }
                                    else
                                    {
                                        // do we want this option?
                                        if (SupportedOptions & (1UL << opt))
                                        {
                                            clientState |= 1UL << opt;
                                            clientStateReq |= 1UL << opt;
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
                                            m_stream.write(t);
                                        }
                                    }

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- WILL {0}", opt);
                                    break;

                                case NVT.WONT:
                                    clientState &= ~(1UL << opt);
                                    if (clientStateReq & (1UL << opt))
                                    {
                                        clientStateReq ^= 1UL << opt;
                                        response = NVT.DONT;
                                    }

                                    version (TelnetDebug)
                                        debug writeDebugf("Telnet: <-- WON'T {0}", opt);
                                    break;

                                case NVT.DO:
                                    if (serverState & (1UL << opt))
                                    {
                                        // offer was accepted
                                        serverStateReq |= 1UL << opt;
                                    }
                                    else
                                    {
                                        // do we handle any option requests?
                                        if (SupportedOptions & (1UL << opt))
                                        {
                                            serverState |= 1UL << opt;
                                            serverStateReq |= 1UL << opt;
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
                                    serverState &= ~(1UL << opt);
                                    serverStateReq &= ~(1UL << opt);
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
                                m_stream.write(t);

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
                    input ~= recvbuf[i];
            }

            if (i < bytes)
            {
                size_t tail = bytes = i;
                recvbuf[0 .. tail] = recvbuf[i .. bytes];
                bytes = tail;
            }
            else
                bytes = 0;
        }

        // dispatch input up to this point
//        size_t taken = receiveInput(input[]);
        receiveInput(input[]);

        // possible that not all bytes were consumed; there could have been incomplete ansi sequences, etc...
//        if (taken < input.length)
//        {
//            m_tail = input[taken .. $];
//            m_tail ~= recvbuf[0 .. bytes];
//        }
//        else
            m_tail = recvbuf[0 .. bytes];
        return;
    }

    override void enterCommand(const(char)[] command)
    {
        write("\r\n");
    }

    override void commandFinished(CommandState commandState, CommandCompletionState state)
    {
        if (m_showPrompt)
            sendPromptAndBuffer(false);
    }

    override void closeSession()
    {
        super.closeSession();

        if (!isAttached() && m_stream)
        {
            m_stream.destroy();
            m_stream.release();
        }
    }


    override void writeOutput(const(char)[] text, bool newline)
    {
        // translate "\n" to "\r\n"
        // if no LF's are discovered, we don't allocate
        MutableString!0 convert;
        size_t lineStart = 0;
        for (size_t i = 0; i < text.length; ++i)
        {
            if (text[i] == '\n')
            {
                if (lineStart == 0)
                    convert.reserve(cast(ushort)(text.length + 64)); // reserve for a bunch of CR's

                convert.append(text[lineStart .. i], "\r\n");
                lineStart = i + 1;
            }
        }
        if (lineStart != 0)
        {
            convert.append(text[lineStart .. $]);
            text = convert[];
        }

        ptrdiff_t sent = m_stream.write(text[]);
        if (newline)
            sent = m_stream.write("\r\n");
    }

    override void showSuggestions(const(String)[] suggestions)
    {
        // move to next line
        ptrdiff_t sent = m_stream.write("\r\n");

        // write the suggestions
        super.showSuggestions(suggestions);

        // put the prompt back
        if (m_showPrompt)
            sendPromptAndBuffer(false);
    }

    override bool showPrompt(bool show)
    {
        bool old = super.showPrompt(show);

        if (!m_currentCommand)
        {
            if (show && !old)
                sendPromptAndBuffer(true);
            else if (!show && old)
                clearLine();
        }
        return old;
    }

    override const(char)[] setPrompt(const(char)[] prompt)
    {
        const(char)[] old = super.setPrompt(prompt);
        if (!m_currentCommand && m_showPrompt && prompt[] != old[])
            sendPromptAndBuffer(true);
        return old;
    }

    override MutableString!0 setInput(const(char)[] text)
    {
        assert(false);
//        bcString r = dcConsoleSession.SetInput(bcMove(text));
//        if (!m_currentCommand && m_showPrompt)
//            sendPromptAndBuffer(true);
//        return r;
    }

    override ptrdiff_t appendInput(const(char)[] text)
    {
        import urt.util : min;

        MutableString!0 before = m_buffer;
        uint beforePos = m_position;

        ptrdiff_t taken = super.appendInput(text);
        if (taken < 0)
            return taken;

        // echo changes back to the terminal...
        if (serverEnabled(TelnetOptions.ECHO))
        {
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
            {
                ptrdiff_t sent = m_stream.write(echo[]);
            }
        }

        return taken;
    }

private:
    ObjectRef!Stream m_stream;
    Array!ubyte m_tail;

    ulong serverState;
    ulong serverStateReq;
    ulong clientState;
    ulong clientStateReq;

    bool serverEnabled(TelnetOptions opt)
        => (serverState & serverStateReq & (1UL << opt)) != 0;
    bool clientEnabled(TelnetOptions opt)
        => (clientState & clientStateReq & (1UL << opt)) != 0;

    void will(TelnetOptions opt)
    {
        if (serverState & (1UL << opt))
            return;
        serverState |= 1UL << opt;

        ubyte[3] t = [ NVT.IAC, NVT.WILL, cast(ubyte)opt ];
        m_stream.write(t[]);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> WILL {0}", opt);
    }

    void wont(TelnetOptions opt, bool force)
    {
        if ((serverState & (1UL << opt)) || force)
        {
            ubyte[3] t = [ NVT.IAC, NVT.WONT, cast(ubyte)opt ];
            m_stream.write(t[]);
        }
        serverState &= ~(1UL << opt);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> WON'T {0}", opt);
    }

    void do_(TelnetOptions opt)
    {
        if (clientStateReq & (1UL << opt))
            return;
        clientStateReq |= 1UL << opt;

        ubyte[3] t = [ NVT.IAC, NVT.DO, cast(ubyte)opt ];
        m_stream.write(t[]);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> DO {0}", opt);
    }

    void dont(TelnetOptions opt, bool force)
    {
        if ((clientStateReq & (1UL << opt)) || force)
        {
            ubyte[3] t = [ NVT.IAC, NVT.DONT, cast(ubyte)opt ];
            m_stream.write(t[]);
        }
        clientStateReq &= ~(1UL << opt);

        version (TelnetDebug)
            debug writeDebugf("Telnet: --> DON'T {0}", opt);
    }

    void clearLine()
    {
        enum Clear = ANSI_ERASE_LINE ~ "\x1b[80D"; // clear and move left 80

        m_stream.write(Clear);
    }

    void sendPromptAndBuffer(bool withErase = false)
    {
        import urt.string.format;

        enum Clear = ANSI_ERASE_LINE ~ "\x1b[80D"; // clear and move left 80

        if (m_position < m_buffer.length)
        {
            import urt.dbg;
            breakpoint;
            // CHECK THAT THE INDIRECT FORMAT STRING WORKS...
            // then delete this code block...
        }

        char[] prompt = tformat("{0, ?1}{2}{3}{@5, ?4}", Clear, withErase, m_prompt, m_buffer, m_position < m_buffer.length, "\x1b[{6}D", m_buffer.length - m_position);
        ptrdiff_t sent = m_stream.write(prompt);
    }

    final void parseHistory()
    {
        Result result = open(m_historyFile, ".telnet_history", FileOpenMode.ReadWrite);
        if (result.failed)
        {
            writeError("Error opening telnet history :", result.file_result);
            return;
        }

        ulong size = m_historyFile.get_size();

        // TODO: maybe we should specify a "MAX_ALLOC" or something...
        assert(size <= size_t.max, "File too large to read into memory");
        size_t fileSize = cast(size_t)size;

        char[] mem = cast(char[])allocator.alloc(fileSize);
        if (mem == null)
        {
            writeError("Error allocating memory for telnet history");
            return;
        }

        scope(exit)
            allocator.free(mem);

        m_historyFile.read(mem, fileSize);

        char[] buff = mem.trim;
        while (!buff.empty)
        {
            // take the next line
            const(char)[] line = buff.split!('\n', false);
            if (!line.empty)
                m_history ~= MutableString!0(line);
        }
        m_historyCursor = cast(uint)m_history.length;
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
