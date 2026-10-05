module protocol.telnet.stream;

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.pagepool;
import urt.string;
import urt.time : MonoTime, getTime;

import manager : g_app;
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

enum TelnetRole : ubyte
{
    server,
    client,
}

final class TelnetStream : Stream
{
    alias Properties = AliasSeq!(Prop!("transport", transport),
                                 Prop!("role", role));
nothrow @nogc:

    ~this() {}

    enum type_name = "telnet";
    enum path = "/stream/telnet";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TelnetStream, id, flags);
    }

    inout(Stream) transport() inout pure
        => _inner.get;

    final void transport(Stream value)
    {
        if (_inner.get is value)
            return;
        if (_inner)
            _inner.release_tx_handler(&provide_tx_page);
        if (_subscribed)
        {
            _inner.release_rx_handler(&inner_rx);
            _inner.unsubscribe(&inner_state_change);
            _subscribed = false;
        }
        _inner = value;
        mark_set!(typeof(this), "transport")();
        restart();
    }

    TelnetRole role() const pure
        => _role;

    final void role(TelnetRole value)
    {
        if (_role == value)
            return;
        _role = value;
        mark_set!(typeof(this), "role")();
        restart();
    }

    override TerminalChannel* terminal_channel()
    {
        return &_terminal;
    }

    final void set_terminal_state(uint width, uint height, ClientFeatures features, const(char)[] terminal_type)
    {
        bool first = !_terminal_aware;
        bool size_changed = (_terminal.width != width || _terminal.height != height);

        _terminal.width = width;
        _terminal.height = height;
        _terminal.features = features;
        if (terminal_type.length > 0)
        {
            _terminal_type.clear();
            _terminal_type ~= terminal_type;
            _terminal.terminal_type = _terminal_type[];
        }
        _terminal_aware = true;

        if (_role != TelnetRole.client || !_inner || !_inner.running)
            return;

        if (first)
        {
            will(TelnetOptions.TERMINAL_TYPE);
            will(TelnetOptions.WINDOW_SIZE);
            do_(TelnetOptions.ECHO);
            do_(TelnetOptions.SUPPRESS_GO_AHEAD);
            emit_naws();
        }
        else if (size_changed && (_server_state & (1UL << TelnetOptions.WINDOW_SIZE)))
            emit_naws();
    }

    final bool server_enabled(TelnetOptions opt)
        => (_server_state & _server_state_req & (1UL << opt)) != 0;

    final bool client_enabled(TelnetOptions opt)
        => (_client_state & _client_state_req & (1UL << opt)) != 0;

    // Stream API

    // Write data to the stream, escaping 0xFF bytes.
    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!_inner)
            return -1;
        if (_tx_pending)
            return queue_behind_pending(data);

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
                        if (r < 0)
                            return -1;
                        total += r;
                    }
                    ubyte[2] iac = [0xFF, 0xFF];
                    auto r = _inner.write(iac[]);
                    if (r < 0)
                        return -1;
                    total += 1;
                    start = j + 1;
                }
            }
            if (start < bytes.length)
            {
                auto r = _inner.write(bytes[start .. $]);
                if (r < 0)
                    return -1;
                total += r;
            }
        }
        return total;
    }

    override ulong tx_link_speed() const
        => _inner ? _inner.tx_link_speed : 0;
    override ulong rx_link_speed() const
        => _inner ? _inner.rx_link_speed : 0;

    override size_t tx_request() const
        => _inner ? _inner.tx_request : 0;


protected:

    override bool validate() const pure
        => _inner !is null;

    override CompletionStatus startup()
    {
        if (!_inner.running)
            return CompletionStatus.continue_;

        final switch (_role)
        {
            case TelnetRole.server:
                will(TelnetOptions.ECHO);
                dont(TelnetOptions.ECHO, true);
                will(TelnetOptions.SUPPRESS_GO_AHEAD);
                do_(TelnetOptions.TERMINAL_TYPE);
                do_(TelnetOptions.WINDOW_SIZE);
                do_(TelnetOptions.CHARSET);

                _terminal.features = cast(ClientFeatures)(ClientFeatures.crlf | ClientFeatures.ansi);
                _terminal.pending_events |= TerminalEvents.features_changed;
                break;

            case TelnetRole.client:
                // Naked client mode: send nothing proactively; respond passively.
                // set_terminal_state() upgrades to terminal-aware mode and advertises
                // WILL NAWS / WILL TTYPE / DO ECHO / DO SGA.
                if (_terminal_aware)
                {
                    will(TelnetOptions.TERMINAL_TYPE);
                    will(TelnetOptions.WINDOW_SIZE);
                    do_(TelnetOptions.ECHO);
                    do_(TelnetOptions.SUPPRESS_GO_AHEAD);
                    emit_naws();
                }
                break;
        }

        _inner.rx_handler(&inner_rx);
        _inner.subscribe(&inner_state_change);
        _subscribed = true;
        tx_handler_changed();

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_inner)
            _inner.release_tx_handler(&provide_tx_page);
        g_app.cancel(&resume_rx);
        free_pending_tx();
        if (_subscribed)
        {
            _inner.release_rx_handler(&inner_rx);
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

    // a consumer that returns takes what was held on the next pass, and the transport reads again after it
    override void rx_handler_changed()
    {
        Stream stream = _inner.get;
        if (!rx_handler || !_subscribed || !stream || stream.rx_handler is &inner_rx)
            return;
        g_app.cancel(&resume_rx);
        g_app.schedule(getTime(), &resume_rx);
    }

    override void tx_handler_changed()
    {
        Stream stream = _inner.get;
        if (!stream || !stream.running)
            return;
        if (tx_handler || _tx_pending)
            stream.tx_handler(&provide_tx_page);
        else
            stream.release_tx_handler(&provide_tx_page);
    }

private:
    enum size_t tx_page_payload = 1600;

    ObjectRef!Stream _inner;
    TerminalChannel _terminal;
    Array!char _terminal_type;
    Array!ubyte _tail;          // input not yet parsed: an incomplete sequence, or what arrived with no consumer
    Page* _tx_pending;
    bool _subscribed;
    bool _terminal_aware;
    TxStatus _tx_pending_status;

    // strips IAC sequences; commands update the TerminalChannel and set pending events
    void inner_rx(Stream, const(void)[] data, MonoTime rx_time)
    {
        enum RawBufLen = 512;
        const(ubyte)[] input = cast(const(ubyte)[])data;
        while (input.length)
        {
            // with no consumer the rest waits unparsed, and the transport stops reading until one returns
            if (!rx_handler)
            {
                _tail ~= input;
                _inner.release_rx_handler(&inner_rx);
                return;
            }

            ubyte[RawBufLen] rawbuf = void;
            ubyte[RawBufLen] out_buf = void;

            // an incomplete sequence from the previous chunk leads this one
            size_t raw_len = _tail.length;
            if (raw_len > RawBufLen / 2)
                raw_len = RawBufLen / 2;
            rawbuf[0 .. raw_len] = _tail[0 .. raw_len];
            _tail.clear();
            size_t take = input.length < RawBufLen - raw_len ? input.length : RawBufLen - raw_len;
            rawbuf[raw_len .. raw_len + take] = input[0 .. take];
            input = input[take .. $];
            raw_len += take;

            size_t out_pos = 0;
            size_t i = 0;
            parse_loop: for (; i < raw_len; ++i)
            {
                if (rawbuf[i] == NVT.IAC)
                {
                    size_t iac_start = i;

                    if (i >= raw_len - 1)
                        break; // incomplete - save for next read

                    NVT cmd = cast(NVT)rawbuf[++i];
                    switch (cmd)
                    {
                        case NVT.NOP:
                            break;

                        case NVT.DM:
                            break;

                        case NVT.BRK:
                        case NVT.IP:
                            _terminal.pending_events |= TerminalEvents.interrupt;
                            break;

                        case NVT.AO:
                            break;

                        case NVT.AYT:
                            _inner.write("\a");
                            break;

                        case NVT.EC:
                            if (out_pos < out_buf.length)
                                out_buf[out_pos++] = '\b';
                            break;

                        case NVT.EL:
                            if (out_pos < out_buf.length)
                                out_buf[out_pos++] = '\x15'; // Ctrl+U - kill line
                            break;

                        case NVT.GA:
                            break;

                        case NVT.SB:
                            size_t sub_start = i + 1;
                            while (sub_start < raw_len - 1 && !(rawbuf[sub_start] == NVT.IAC && rawbuf[sub_start + 1] == NVT.SE))
                                ++sub_start;
                            if (sub_start >= raw_len - 1)
                            {
                                // Incomplete subnegotiation - save from IAC start
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
                            if (out_pos < out_buf.length)
                                out_buf[out_pos++] = 0xff;
                            break;

                        default:
                            writeWarningf("Unknown NVT command: \\\\x{0, 02x}", cast(ubyte)cmd);
                            break;
                    }
                }
                else
                {
                    if (out_pos < out_buf.length)
                        out_buf[out_pos++] = rawbuf[i];
                }
            }

            if (i < raw_len)
                _tail = rawbuf[i .. raw_len];
            incoming(out_buf[0 .. out_pos], rx_time);
        }
    }
    TelnetRole _role;

    ulong _server_state;
    ulong _server_state_req;
    ulong _client_state;
    ulong _client_state_req;

    Page* provide_tx_page(ref const TxRequest req, out TxStatus status)
    {
        if (_tx_pending)
            return take_pending_tx(req, status);

        Page* page = request_tx_page(req, status);
        if (!page)
            return null;

        add_tx_bytes(page.length);
        if (_logging)
            write_to_log(false, page.data);
        Page* output = escape_page(page);
        if (!output)
        {
            tx_handler(null);
            status = TxStatus.abort;
            return null;
        }
        _tx_pending = output;
        _tx_pending_status = status;
        return take_pending_tx(req, status);
    }

    Page* take_pending_tx(ref const TxRequest req, out TxStatus status)
    {
        Page* page = take_tx_page(_tx_pending, req, status);
        if (page)
            status = _tx_pending || tx_handler ? TxStatus.more : _tx_pending_status;
        return page;
    }

    // pending output was produced earlier, so written bytes queue behind it
    ptrdiff_t queue_behind_pending(const(void[])[] data)
    {
        ptrdiff_t total = 0;
        foreach (d; data)
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])d;
            while (bytes.length)
            {
                size_t n = bytes.length < tx_page_payload ? bytes.length : tx_page_payload;
                Page* page = page_alloc(n);
                if (!page)
                    return total;
                (cast(ubyte[])page.data)[] = bytes[0 .. n];
                Page* output = escape_page(page);
                if (!output)
                    return total;
                append_tx_chain(_tx_pending, output);
                bytes = bytes[n .. $];
                total += n;
            }
        }
        return total;
    }

    // consumes page
    Page* escape_page(Page* page)
    {
        size_t input_length = page.length;
        const(ubyte)[] input = cast(const(ubyte)[])page.data;
        size_t escaped_length = input_length;
        foreach (b; input)
            escaped_length += b == NVT.IAC;
        if (escaped_length == input_length)
            return page;

        if (escaped_length - input_length <= page.tailroom)
        {
            ubyte[] storage = (cast(ubyte*)page)[0 .. page.capacity];
            size_t source = page.offset + input_length;
            size_t destination = page.offset + escaped_length;
            while (source != destination)
            {
                ubyte b = storage[--source];
                storage[--destination] = b;
                if (b == NVT.IAC)
                    storage[--destination] = b;
            }
            page.length = cast(ushort)escaped_length;
            return page;
        }

        size_t input_position;
        bool repeat;
        size_t output_position;
        Page* head;
        Page* tail;
        while (output_position != escaped_length)
        {
            size_t length = escaped_length - output_position;
            if (length > tx_page_payload)
                length = tx_page_payload;
            Page* output = page_alloc(length, size_t.sizeof, page.headroom, page.tailroom);
            if (!output)
            {
                free_page_chain(head);
                page_free(page);
                return null;
            }
            if (tail)
                tail.next = output;
            else
                head = output;
            tail = output;

            ubyte[] bytes = cast(ubyte[])output.data;
            foreach (ref b; bytes)
            {
                ubyte value = input[input_position];
                b = value;
                if (value == NVT.IAC && !repeat)
                    repeat = true;
                else
                {
                    repeat = false;
                    ++input_position;
                }
            }
            output_position += length;
        }
        page_free(page);
        return head;
    }

    void free_pending_tx()
    {
        free_page_chain(_tx_pending);
        _tx_pending = null;
    }

    static void free_page_chain(Page* page)
    {
        while (page)
        {
            Page* next = page.next;
            page_free(page);
            page = next;
        }
    }

    void resume_rx(MonoTime now)
    {
        Stream stream = _inner.get;
        if (!rx_handler || !_subscribed || !stream || stream.rx_handler is &inner_rx)
            return;
        Array!ubyte held = _tail.move;
        inner_rx(stream, held[], now);
        if (rx_handler && _subscribed)
            stream.rx_handler(&inner_rx);
    }

    void inner_state_change(ActiveObject, StateSignal signal)
    {
        if (signal != StateSignal.offline)
            return;

        if (_inner && (_inner.flags & ObjectFlags.temporary))
        {
            _inner.release_tx_handler(&provide_tx_page);
            _inner.unsubscribe(&inner_state_change);
            _subscribed = false;
            _inner = null;
        }
        restart();
    }

    void handle_subnegotiation(const(ubyte)[] sub)
    {
        switch (sub[0])
        {
            case TelnetOptions.TERMINAL_TYPE:
                if (sub.length < 2)
                    break;
                if (sub[1] == 0x00) // IS: peer is telling us their terminal type
                {
                    _terminal_type.clear();
                    _terminal_type ~= cast(const(char)[])sub[2 .. $];
                    _terminal.terminal_type = _terminal_type[];
                    _terminal.features = cast(ClientFeatures)(map_terminal_features(_terminal.terminal_type) | ClientFeatures.crlf);
                    _terminal.pending_events |= TerminalEvents.features_changed;

                    version (TelnetDebug)
                        debug log.trace("Telnet: <-- TERMINAL-TYPE: ", _terminal.terminal_type);
                }
                else if (sub[1] == 0x01) // SEND: peer is asking for our terminal type
                    emit_ttype_is();
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
                    // only the server side of TERMINAL_TYPE solicits the value
                    if (_role == TelnetRole.server && opt == TelnetOptions.TERMINAL_TYPE)
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
                    ulong supported = SupportedOptions;
                    // naked client streams have no terminal state to source
                    if (_role == TelnetRole.client && !_terminal_aware)
                        supported &= ~((1UL << TelnetOptions.TERMINAL_TYPE) | (1UL << TelnetOptions.WINDOW_SIZE));
                    if (supported & (1UL << opt))
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

    void emit_naws()
    {
        // 16-bit big-endian width, height; payload bytes must IAC-escape 0xFF.
        ubyte[4] payload = [
            cast(ubyte)(_terminal.width  >> 8), cast(ubyte)(_terminal.width  & 0xff),
            cast(ubyte)(_terminal.height >> 8), cast(ubyte)(_terminal.height & 0xff),
        ];
        ubyte[14] t = void;
        size_t n = 0;
        t[n++] = NVT.IAC; t[n++] = NVT.SB; t[n++] = TelnetOptions.WINDOW_SIZE;
        foreach (b; payload)
        {
            t[n++] = b;
            if (b == 0xff)
                t[n++] = 0xff;
        }
        t[n++] = NVT.IAC; t[n++] = NVT.SE;
        _inner.write(t[0 .. n]);

        version (TelnetDebug)
            debug log.trace("Telnet: --> NAWS ", _terminal.width, 'x', _terminal.height);
    }

    void emit_ttype_is()
    {
        const(char)[] tt = _terminal.terminal_type.length ? _terminal.terminal_type : "UNKNOWN";

        ubyte[4] hdr = [NVT.IAC, NVT.SB, TelnetOptions.TERMINAL_TYPE, 0x00];
        ubyte[2] trl = [NVT.IAC, NVT.SE];
        _inner.write(hdr[], cast(const(ubyte)[])tt, trl[]);

        version (TelnetDebug)
            debug log.trace("Telnet: --> TERMINAL-TYPE IS ", tt);
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

    // Unknown - assume basic ANSI
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


unittest
{
    import urt.mem : alloc, free;

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    TelnetStream telnet = alloc!TelnetStream(CID(1));
    scope (exit) free(telnet);

    Page* iacs = page_alloc(64);
    (cast(ubyte[])iacs.data)[] = NVT.IAC;
    telnet._tx_pending = telnet.escape_page(iacs);
    telnet._tx_pending_status = TxStatus.idle;

    ubyte[3] later = [1, 2, 3];
    const(void)[][1] data = [later[]];
    assert(telnet.queue_behind_pending(data[]) == 3);

    TxRequest small = TxRequest(min_tx_request);
    TxStatus status;
    size_t sent;
    while (telnet._tx_pending)
    {
        Page* page = telnet.take_pending_tx(small, status);
        assert(page && page.length <= small.bytes);
        foreach (b; cast(const(ubyte)[])page.data)
        {
            if (sent < 128)
                assert(b == NVT.IAC);
            else
                assert(b == later[sent - 128]);
            ++sent;
        }
        assert(status == (telnet._tx_pending ? TxStatus.more : TxStatus.idle));
        page_free(page);
    }
    assert(sent == 131);

    // with no consumer the transport is paused and the delivery held; a returning consumer gets it whole, in order
    {
        static class Transport : Stream
        {
        nothrow @nogc:
            ~this() {}
            enum type_name = "telnet-test-transport";
            this(CID id, ObjectFlags flags = ObjectFlags.none)
            {
                super(collection_type_info!Transport, id, flags);
            }
            override ptrdiff_t write(const(void[])[] data...) => 0;
            void feed(const(char)[] text)
            {
                incoming(text, MonoTime());
            }
        }
        static struct Consumer
        {
            Array!char text;
            void recv(Stream, const(void)[] data, MonoTime) nothrow @nogc
            {
                text ~= cast(const(char)[])data;
            }
        }

        Transport transport = Collection!Transport().create("telnet-test-transport");
        scope (exit)
        {
            transport.destroy();
            Collection!Stream().update_all();
        }
        TelnetStream filter = alloc!TelnetStream(CID(2));
        scope (exit) free(filter);
        filter._inner = transport;
        filter._subscribed = true;
        transport.rx_handler(&filter.inner_rx);

        transport.feed("hello \xFF\xF1world");
        assert(transport.rx_handler is null && filter._tail[] == cast(const(ubyte)[])"hello \xFF\xF1world");

        // the hook schedules the resume on the application; the test takes the timer's place
        Consumer consumer;
        filter._subscribed = false;
        filter.rx_handler(&consumer.recv);
        filter._subscribed = true;
        assert(consumer.text.empty);
        filter.resume_rx(MonoTime());
        assert(consumer.text[] == "hello world" && transport.rx_handler is &filter.inner_rx);

        transport.feed("more");
        assert(consumer.text[] == "hello worldmore");
        filter.release_rx_handler(&consumer.recv);
        transport.feed("later");
        assert(transport.rx_handler is null && filter._tail[] == cast(const(ubyte)[])"later");
        filter._subscribed = false;
    }
}
