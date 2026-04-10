module protocol.telnet.stream;

import urt.array;
import urt.log;
import urt.mem.allocator;
import urt.string;

import manager.base;
import manager.base : ObjectRef, Property;
import manager.collection;
import manager.console.session;

import router.stream;

version = TelnetDebug;

nothrow @nogc:


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

class TelnetStream : Stream
{
    __gshared Property[1] Properties = [ Property.create!("transport", transport)() ];
nothrow @nogc:

    enum type_name = "telnet";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TelnetStream, id, flags);
    }

    inout(Stream) transport() inout pure
        => _inner;

    final void transport(Stream value)
    {
        if (_inner is value)
            return;
        if (_subscribed)
        {
            _inner.unsubscribe(&inner_state_change);
            _subscribed = false;
        }
        _inner = value;
        restart();
    }

    override TerminalChannel* terminal_channel()
    {
        return &_terminal;
    }

    final bool server_enabled(TelnetOptions opt)
        => (_server_state & _server_state_req & (1UL << opt)) != 0;

    final bool client_enabled(TelnetOptions opt)
        => (_client_state & _client_state_req & (1UL << opt)) != 0;

    // Stream API

    override const(char)[] remote_name()
    {
        return _inner ? _inner.remote_name() : null;
    }

    // Read clean data from the stream, stripping IAC sequences.
    // IAC commands update the TerminalChannel and set pending events.
    override ptrdiff_t read(void[] buffer)
    {
        if (!_inner)
            return -1;

        enum RawBufLen = 512;
        ubyte[RawBufLen] rawbuf = void;

        // Prepend any leftover bytes from previous incomplete IAC sequences
        size_t raw_len = _tail.length;
        if (raw_len > RawBufLen / 2)
            raw_len = RawBufLen / 2; // clamp to leave room for new data
        rawbuf[0 .. raw_len] = _tail[0 .. raw_len];
        _tail.clear();

        ptrdiff_t r = _inner.read(rawbuf[raw_len .. $]);
        if (r < 0)
            return -1;
        if (r == 0 && raw_len == 0)
            return 0;

        raw_len += r;

        size_t out_pos = 0;
        ubyte[] out_buf = cast(ubyte[])buffer;

        size_t i = 0;
        parse_loop: for (; i < raw_len; ++i)
        {
            if (rawbuf[i] == NVT.IAC)
            {
                size_t iac_start = i;

                if (i >= raw_len - 1)
                    break; // incomplete — save for next read

                NVT cmd = cast(NVT)rawbuf[++i];
                switch (cmd)
                {
                    case NVT.NOP:
                        break;

                    case NVT.DM:
                        break;

                    case NVT.BRK:
                    case NVT.IP:
                        if (out_pos < buffer.length)
                            out_buf[out_pos++] = '\x03';
                        break;

                    case NVT.AO:
                        break;

                    case NVT.AYT:
                        _inner.write("\a");
                        break;

                    case NVT.EC:
                        if (out_pos < buffer.length)
                            out_buf[out_pos++] = '\b';
                        break;

                    case NVT.EL:
                        if (out_pos < buffer.length)
                            out_buf[out_pos++] = '\x15'; // Ctrl+U — kill line
                        break;

                    case NVT.GA:
                        break;

                    case NVT.SB:
                        size_t sub_start = i + 1;
                        while (sub_start < raw_len - 1 && !(rawbuf[sub_start] == NVT.IAC && rawbuf[sub_start + 1] == NVT.SE))
                            ++sub_start;
                        if (sub_start >= raw_len - 1)
                        {
                            // Incomplete subnegotiation — save from IAC start
                            i = iac_start;
                            break parse_loop;
                        }

                        const(ubyte)[] sub = rawbuf[i + 1 .. sub_start];
                        i = sub_start + 1; // skip past IAC SE

                        if (sub.length > 0)
                            handle_subnegotiation(sub);
                        break;

                    case NVT.WILL:
                    case NVT.WONT:
                    case NVT.DO:
                    case NVT.DONT:
                        if (i >= raw_len - 1)
                        {
                            i = iac_start;
                            break parse_loop;
                        }
                        TelnetOptions opt = cast(TelnetOptions)rawbuf[++i];
                        handle_option(cmd, opt);
                        break;

                    case cast(NVT)0xff: // escaped IAC
                        if (out_pos < buffer.length)
                            out_buf[out_pos++] = 0xff;
                        break;

                    default:
                        writeWarningf("Unknown NVT command: \\\\x{0, 02x}", cast(ubyte)cmd);
                        break;
                }
            }
            else
            {
                if (out_pos < buffer.length)
                    out_buf[out_pos++] = rawbuf[i];
            }
        }

        // Save unparsed tail for next read
        if (i < raw_len)
            _tail = rawbuf[i .. raw_len];

        return cast(ptrdiff_t)out_pos;
    }

    // Write data to the stream, escaping 0xFF bytes.
    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!_inner)
            return -1;

        // Only need to escape 0xFF (IAC) bytes
        ptrdiff_t total = 0;
        foreach (d; data)
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])d;
            size_t start = 0;
            for (size_t j = 0; j < bytes.length; ++j)
            {
                if (bytes[j] == 0xFF)
                {
                    if (j > start)
                    {
                        auto r = _inner.write(bytes[start .. j]);
                        if (r < 0) return -1;
                        total += r;
                    }
                    ubyte[2] iac = [0xFF, 0xFF];
                    auto r = _inner.write(iac[]);
                    if (r < 0) return -1;
                    total += 1;
                    start = j + 1;
                }
            }
            if (start < bytes.length)
            {
                auto r = _inner.write(bytes[start .. $]);
                if (r < 0) return -1;
                total += r;
            }
        }
        return total;
    }

    override ptrdiff_t pending()
    {
        if (!_inner)
            return -1;
        // Can't know exactly how many clean bytes are pending since
        // IAC sequences consume raw bytes. Return inner pending as estimate.
        return _inner.pending() + cast(ptrdiff_t)_tail.length;
    }

    override ptrdiff_t flush()
    {
        _tail.clear();
        return _inner ? _inner.flush() : 0;
    }

protected:
    override bool validate() const pure
        => _inner !is null;

    override CompletionStatus validating()
    {
        _inner.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_inner.running)
            return CompletionStatus.continue_;

        will(TelnetOptions.ECHO);
        dont(TelnetOptions.ECHO, true);
        will(TelnetOptions.SUPPRESS_GO_AHEAD);
        do_(TelnetOptions.TERMINAL_TYPE);
        do_(TelnetOptions.WINDOW_SIZE);
        do_(TelnetOptions.CHARSET);

        _terminal.features = cast(ClientFeatures)(ClientFeatures.crlf | ClientFeatures.ansi);
        _terminal.pending_events |= TerminalEvents.features_changed;

        _inner.subscribe(&inner_state_change);
        _subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _inner.unsubscribe(&inner_state_change);
            _subscribed = false;
        }
        if (_inner && (_inner.flags & ObjectFlags.temporary))
            _inner.destroy();
        _server_state = 0;
        _server_state_req = 0;
        _client_state = 0;
        _client_state_req = 0;
        _tail.clear();
        return CompletionStatus.complete;
    }

private:
    ObjectRef!Stream _inner;
    TerminalChannel _terminal;
    Array!ubyte _tail;
    bool _subscribed;

    ulong _server_state;
    ulong _server_state_req;
    ulong _client_state;
    ulong _client_state_req;

    void inner_state_change(BaseObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void handle_subnegotiation(const(ubyte)[] sub)
    {
        switch (sub[0])
        {
            case TelnetOptions.TERMINAL_TYPE:
                if (sub.length < 2)
                    break;
                if (sub[1] == 0x00)
                {
                    _terminal.terminal_type = cast(const(char)[])sub[2 .. $];
                    _terminal.features = cast(ClientFeatures)(map_terminal_features(_terminal.terminal_type) | ClientFeatures.crlf);
                    _terminal.pending_events |= TerminalEvents.features_changed;

                    version (TelnetDebug)
                        debug log.trace("Telnet: <-- TERMINAL-TYPE: ", _terminal.terminal_type);
                }
                break;

            case TelnetOptions.WINDOW_SIZE:
                if (sub.length == 5)
                {
                    _terminal.width = cast(uint)sub[1] << 8 | cast(uint)sub[2];
                    _terminal.height = cast(uint)sub[3] << 8 | cast(uint)sub[4];
                    _terminal.pending_events |= TerminalEvents.resized;
                }
                break;

            case TelnetOptions.CHARSET:
                // TODO: handle charset negotiation
                break;

            default:
                writeWarningf("Unsupported NVT subnegotiation: \\\\x{0, 02x}", cast(ubyte)sub[0]);
                break;
        }
    }

    void handle_option(NVT cmd, TelnetOptions opt)
    {
        NVT response;

        switch (cmd)
        {
            case NVT.WILL:
                bool activated = false;
                if (_client_state_req & (1UL << opt))
                {
                    if (!(_client_state & (1UL << opt)))
                        activated = true;
                    _client_state |= 1UL << opt;
                }
                else
                {
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
                        ubyte[6] t = [NVT.IAC, NVT.SB, TelnetOptions.TERMINAL_TYPE, 0x01, NVT.IAC, NVT.SE];
                        _inner.write(t);
                    }
                }

                version (TelnetDebug)
                    debug log.trace("Telnet: <-- WILL ", opt);
                break;

            case NVT.WONT:
                _client_state &= ~(1UL << opt);
                if (_client_state_req & (1UL << opt))
                {
                    _client_state_req ^= 1UL << opt;
                    response = NVT.DONT;
                }

                version (TelnetDebug)
                    debug log.trace("Telnet: <-- WON'T ", opt);
                break;

            case NVT.DO:
                if (_server_state & (1UL << opt))
                {
                    _server_state_req |= 1UL << opt;
                }
                else
                {
                    if (SupportedOptions & (1UL << opt))
                    {
                        _server_state |= 1UL << opt;
                        _server_state_req |= 1UL << opt;
                        response = NVT.WILL;
                    }
                    else
                        response = NVT.WONT;
                }

                version (TelnetDebug)
                    debug log.trace("Telnet: <-- DO ", opt);
                break;

            case NVT.DONT:
                _server_state &= ~(1UL << opt);
                _server_state_req &= ~(1UL << opt);
                response = NVT.WONT;

                version (TelnetDebug)
                    debug log.trace("Telnet: <-- DON'T ", opt);
                break;

            default:
                break;
        }

        if (response)
        {
            ubyte[3] t = [NVT.IAC, response, cast(ubyte)opt];
            _inner.write(t);

            debug version (TelnetDebug)
            {
                __gshared immutable string[4] responses = [ "WILL", "WON'T", "DO", "DON'T" ];
                log.trace("Telnet: --> ", responses[response - NVT.WILL], ' ', opt);
            }
        }
    }

    void will(TelnetOptions opt)
    {
        if (_server_state & (1UL << opt))
            return;
        _server_state |= 1UL << opt;

        ubyte[3] t = [NVT.IAC, NVT.WILL, cast(ubyte)opt];
        _inner.write(t[]);

        version (TelnetDebug)
            debug log.trace("Telnet: --> WILL ", opt);
    }

    void wont(TelnetOptions opt, bool force)
    {
        if ((_server_state & (1UL << opt)) || force)
        {
            ubyte[3] t = [NVT.IAC, NVT.WONT, cast(ubyte)opt];
            _inner.write(t[]);
        }
        _server_state &= ~(1UL << opt);

        version (TelnetDebug)
            debug log.trace("Telnet: --> WON'T ", opt);
    }

    void do_(TelnetOptions opt)
    {
        if (_client_state_req & (1UL << opt))
            return;
        _client_state_req |= 1UL << opt;

        ubyte[3] t = [NVT.IAC, NVT.DO, cast(ubyte)opt];
        _inner.write(t[]);

        version (TelnetDebug)
            debug log.trace("Telnet: --> DO ", opt);
    }

    void dont(TelnetOptions opt, bool force)
    {
        if ((_client_state_req & (1UL << opt)) || force)
        {
            ubyte[3] t = [NVT.IAC, NVT.DONT, cast(ubyte)opt];
            _inner.write(t[]);
        }
        _client_state_req &= ~(1UL << opt);

        version (TelnetDebug)
            debug log.trace("Telnet: --> DON'T ", opt);
    }
}


private:

enum ulong SupportedOptions = (1UL << TelnetOptions.ECHO) |
                              (1UL << TelnetOptions.SUPPRESS_GO_AHEAD) |
                              (1UL << TelnetOptions.TERMINAL_TYPE) |
                              (1UL << TelnetOptions.WINDOW_SIZE) |
                              (1UL << TelnetOptions.CHARSET);

ClientFeatures map_terminal_features(const(char)[] terminal_type)
{
    import urt.string.ascii : to_lower;

    // Normalize to lowercase for matching
    char[64] buf = void;
    size_t len = terminal_type.length < buf.length ? terminal_type.length : buf.length;
    foreach (i; 0 .. len)
        buf[i] = to_lower(terminal_type[i]);
    const(char)[] term = buf[0 .. len];

    // Match known terminal types (most specific first)
    if (term.length >= 5 && term[0..5] == "xterm")
        return ClientFeatures.xterm;
    if (term.length >= 5 && term[0..5] == "vt220")
        return ClientFeatures.ansi;
    if (term.length >= 5 && term[0..5] == "vt100")
        return ClientFeatures.vt100;
    if (term.length >= 4 && term[0..4] == "ansi")
        return ClientFeatures.ansi;
    if (term.length >= 5 && term[0..5] == "linux")
        return ClientFeatures.ansi;
    if (term.length >= 6 && term[0..6] == "screen")
        return ClientFeatures.xterm;
    if (term.length >= 4 && term[0..4] == "tmux")
        return ClientFeatures.xterm;
    if (term.length >= 4 && term[0..4] == "rxvt")
        return ClientFeatures.xterm;
    if (term.length >= 4 && term[0..4] == "dumb")
        return ClientFeatures.none;

    // Unknown — assume basic ANSI
    return ClientFeatures.ansi;
}

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
