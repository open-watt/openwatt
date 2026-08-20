module protocol.telnet.server;

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.session;
import manager.expression : NamedArgument;
import manager.plugin;

import protocol.telnet;
import protocol.telnet.stream;

import router.iface;
import router.stream;
import router.transport.tcp.stream;

nothrow @nogc:


class TelnetServer
{
nothrow @nogc:

    const String name;

    this(String name, Console* console, BaseInterface iface, ushort port)
    {
        this.name = name.move;
        _console = console;

        const(char)[] server_name = Collection!TCPServer().generate_name(this.name[]);

        m_server = Collection!TCPServer().create(server_name, ObjectFlags.dynamic);
        m_server.port = port;
        m_server.set_connection_callback(&acceptConnection, null);
    }

    ~this()
    {
        m_server.destroy();

        while (!m_sessions.empty)
        {
            Session session = m_sessions[$ - 1];
            m_sessions.popBack();
            session.unsubscribe(&session_state_change);
            if (!(session.flags & ObjectFlags.disabled))
                _console.destroy_session(session);
        }
    }

    /// Add a listening port to the server.
    /// Multiple ports may be registered for a server. Different ports may bind to different console instances, or trigger different login scripts on session creation.
    /// For instance, a port may be assigned where new session instances execute the `log` command and the session effectively becomes a remote log stream.
    /// \param console
    ///  The console instance that new telnet sessions will be bound to.
    /// \param listenPort
    ///  A listening port for the telnet server.
    /// \param loginScript
    ///  A script to be executed on creation of new sessions connecting to this port.
    /// \returns Returns `true` if the new port was registered successfully.
    final bool addListenPort(Console* console, ushort listenPort, const(char)[] loginScript)
    {
        return false;
    }

package:
    Console* _console;
    TCPServer m_server;

    Array!Session m_sessions;

    void acceptConnection(Stream client, ref const InetAddress remote, void* user_data)
    {
        const(char)[] stream_name = Collection!Stream().generate_name(this.name[]);

        TelnetStream telnet_stream = cast(TelnetStream)Collection!TelnetStream().create(stream_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("transport", client));
        if (telnet_stream is null)
        {
            client.destroy();
            return;
        }

        Session session = _console.createSession!Session(cast(Stream)telnet_stream);
        session.show_prompt(true);
        session.load_history(".telnet_history");

        session.subscribe(&session_state_change);
        m_sessions ~= session;
    }

    void session_state_change(ActiveObject object, StateSignal signal)
    {
        if (signal != StateSignal.destroyed)
            return;

        Session session = cast(Session)object;
        session.unsubscribe(&session_state_change);
        m_sessions.removeFirstSwapLast(session);
    }
}
