module protocol.telnet.client;

import urt.array;
import urt.conv : parse_uint;
import urt.mem;
import urt.string;

import manager.base;
import manager.collection;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.expression : NamedArgument;

import protocol.telnet.stream;

import router.stream;
import protocol.ip.tcp_stream;

nothrow @nogc:


CommandState telnet(Session session, const(char)[] remote)
{
    ushort port = 23;
    const(char)[] host = remote;
    size_t colon = remote.findFirst(':');
    if (colon < remote.length)
    {
        host = remote[0 .. colon];
        const(char)[] port_str = remote[colon + 1 .. $];
        size_t taken;
        ulong p = parse_uint(port_str, &taken);
        if (taken == 0 || taken != port_str.length || p == 0 || p > 65_535)
        {
            session.write_line("Invalid port in '", remote, "'");
            return null;
        }
        port = cast(ushort)p;
    }
    if (host.length == 0)
    {
        session.write_line("Empty hostname");
        return null;
    }

    auto tcp_name = Collection!TCPStream().generate_name("telnet-c");
    TCPStream tcp = cast(TCPStream)Collection!TCPStream().create(tcp_name,
        cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
        NamedArgument("remote", host),
        NamedArgument("port", port));
    if (tcp is null)
    {
        session.write_line("Failed to create TCP stream to '", host, "'");
        return null;
    }

    auto telnet_name = Collection!TelnetStream().generate_name("telnet-c");
    TelnetStream telnet_stream = cast(TelnetStream)Collection!TelnetStream().create(telnet_name,
        cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
        NamedArgument("transport", tcp),
        NamedArgument("role", "client"));
    if (telnet_stream is null)
    {
        tcp.destroy();
        session.write_line("Failed to create telnet stream");
        return null;
    }

    const(char)[] tt = session.terminal_type();
    if (tt.length == 0)
        tt = "xterm";
    telnet_stream.set_terminal_state(session.width, session.height, session.features, tt);

    session.write_line("Connecting to ", host, ":", port, "  (escape: Ctrl-])");

    return defaultAllocator().allocT!TelnetClientCommand(session, telnet_stream);
}


class TelnetClientCommand : CommandState
{
nothrow @nogc:

    enum char escape_key = '\x1d'; // Ctrl-]

    this(Session session, TelnetStream telnet)
    {
        super(session, null);
        _telnet = telnet;
        telnet.subscribe(&telnet_state_change);
    }

    ~this()
    {
        if (_telnet)
        {
            _telnet.destroy();
            _telnet = null;
        }
    }

    override bool consumes_input() const pure
        => true;

    override void receive_input(const(char)[] data)
    {
        if (!_telnet)
            return;

        for (size_t i = 0; i < data.length; ++i)
        {
            if (data[i] == escape_key)
            {
                if (i > 0)
                    _telnet.write(cast(const(void)[])data[0 .. i]);
                _escape_pressed = true;
                return;
            }
        }
        _telnet.write(cast(const(void)[])data);
    }

    override CommandCompletionState update()
    {
        if (_escape_pressed)
        {
            session.write_line("");
            session.write_line("[disconnected]");
            return CommandCompletionState.finished;
        }
        if (!_telnet)
        {
            if (_remote_closed)
            {
                session.write_line("");
                session.write_line("[connection closed]");
                _remote_closed = false;
            }
            return CommandCompletionState.finished;
        }
        if (_telnet.running)
            _connected = true;
        else if (_connected)
        {
            session.write_line("");
            session.write_line("[connection closed]");
            return CommandCompletionState.finished;
        }
        else
            return CommandCompletionState.in_progress; // still connecting

        ubyte[512] buf = void;
        ptrdiff_t r;
        do
        {
            r = _telnet.read(buf[]);
            if (r < 0)
            {
                session.write_line("");
                session.write_line("[connection closed]");
                return CommandCompletionState.finished;
            }
            if (r > 0)
                session.write_raw(buf[0 .. r]);
        }
        while (r == buf.length);

        auto local = session.stream;
        if (local !is null)
        {
            auto term = local.terminal_channel();
            if (term)
            {
                const(char)[] tt = term.terminal_type.length ? term.terminal_type : "xterm";
                _telnet.set_terminal_state(term.width, term.height, term.features, tt);
            }
        }

        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        _escape_pressed = true;
    }

private:
    void telnet_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.online)
            return;
        _telnet.unsubscribe(&telnet_state_change);
        _telnet = null;
        _remote_closed = true;
    }

    TelnetStream _telnet;
    bool _connected;
    bool _escape_pressed;
    bool _remote_closed;
}
