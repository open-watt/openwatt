module protocol.telnet.server;

import urt.array;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.base;
import manager.console;
import manager.console.session;
import manager.expression : NamedArgument;
import manager.plugin;

import protocol.telnet;
import protocol.telnet.stream;

import router.iface;
import router.stream;
import router.stream.tcp;

nothrow @nogc:


class TelnetServer
{
nothrow @nogc:

    const String name;

    this(NoGCAllocator allocator, String name, Console* console, BaseInterface iface, ushort port)
    {
        this.name = name.move;
        m_allocator = allocator;
        _console = console;

        const(char)[] server_name = get_module!TCPStreamModule.tcp_servers.generate_name(this.name[]);

        m_server = get_module!TCPStreamModule.tcp_servers.create(server_name, ObjectFlags.dynamic);
        m_server.port = port;
        m_server.set_connection_callback(&acceptConnection, null);
    }

    ~this()
    {
        m_server.destroy();

        foreach (s; m_sessions)
            m_allocator.freeT(s);
        m_sessions.clear();
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

    final void update()
    {
        for (size_t i; i < m_sessions.length; )
        {
            Session s = m_sessions[i];

            if (s.is_attached)
                s.update();

            if (!s.is_attached)
            {
                m_allocator.freeT(s);
                m_sessions.removeSwapLast(i);
            }
            else
                ++i;
        }
    }

package:
    NoGCAllocator m_allocator;

    Console* _console;
    TCPServer m_server;

    Array!Session m_sessions;

    void acceptConnection(Stream client, void* user_data)
    {
        const(char)[] stream_name = get_module!StreamModule.streams.generate_name(this.name[]);

        TelnetStream telnet_stream = get_module!TelnetModule.telnet_streams.create(stream_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("transport", client));
        if (telnet_stream is null)
        {
            client.destroy();
            return;
        }

        Session session = _console.createSession!Session(cast(Stream)telnet_stream);
        session.show_prompt(true);
        session.load_history(".telnet_history");

        m_sessions ~= session;
    }
}
