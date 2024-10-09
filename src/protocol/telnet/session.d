module protocol.telnet.session;

import urt.socket;
import urt.string;
import urt.string.ansi;

import manager.console;
import manager.console.session;

import router.stream;

nothrow @nogc:


enum DefaultBufferLen = 512;

enum TELNET_ERASE_LINE = "\xff\xf8";

class TelnetSession : Session
{
nothrow @nogc:

    this(ref Console console, Stream clientStream)
    {
        super(console);
        this.m_stream = clientStream;

        clientStream.setOpts(StreamOptions.NonBlocking);

        ubyte[15] introduction = [ 0xff, 0xfb, 0x01,    // WILL echo back characters
                                   0xff, 0xfe, 0x01,    // DON'T echo back characters
                                   0xff, 0xfb, 0x03,    // WILL supress go-ahead, stops remote clients from doing local linemode
                                   0xff, 0xfd, 0x1f,    // DO negotiate window size
                                   0xff, 0xfd, 0x2a ];  // DO character set

        ptrdiff_t sent = clientStream.write(introduction);

        assert(sent == 15);
    }

    ~this()
    {
        closeSession();
    }

    override void update()
    {
        enum DefaultBufferLen = 512;
        ubyte[DefaultBufferLen] recvbuf;

//        MutableString!512 input;

        ptrdiff_t read;
        do
        {
            read = m_stream.read(recvbuf[]);
            if (read < 0)
            {
                closeSession();
                return;
            }
            receiveInput(cast(char[])recvbuf[0 .. read]);
//            input.append(recvbuf[0 .. read]);
        } while (read == recvbuf.length);

//        if (!input.empty())
//        {
//            // telnet sends '\0' instead of '\n' for some reason!
//            foreach (char c; input)
//            {
//                assert(c != '\0', "Why is this loop even here? What did I write it for?");
//                if (c == '\0')
//                    c = '\n';
//            }
//
//            receiveInput(input);
//        }

        super.update();
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
        NoGCAllocator conAllocator;
        if (isAttached())
            conAllocator = allocator;

        super.closeSession();

        if (!isAttached())
        {
            assert(conAllocator || !m_stream, "Why didn't the stream get freed before the console was lost?");

            if (conAllocator)
            {
                conAllocator.freeT(m_stream);
                m_stream = null;
            }
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
            if (text[i] == '\n' && i > 0 && text[i - 1] != '\r')
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

        return taken;
    }

private:
    Stream m_stream;

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
}
