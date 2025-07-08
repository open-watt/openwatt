module protocol.telnet.server;

import urt.array;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;

import manager.console;

import protocol.telnet.session;

import router.iface;
import router.stream.tcp;

nothrow @nogc:


class TelnetServer
{
nothrow @nogc:

    const String name;

    this(NoGCAllocator allocator, String name, Console* console, BaseInterface iface, ushort port)
    {
        this.name = name;
        m_allocator = allocator;
        m_console = console;

        m_server = m_allocator.allocT!TCPServer(name.move, port, &acceptConnection, null);
    }

    ~this()
    {
        m_allocator.freeT(m_server);

        foreach (TelnetSession s; m_sessions)
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
    bool addListenPort(Console* console, ushort listenPort, const(char)[] loginScript)
    {
        // TODO: support multiple listening ports which direct to different console instasnces?
        return false;
    }

    /// Update the telnet server. Should be called once per frame (or periodically) from a main thread.
    void update()
    {
        m_server.update();

        for (size_t i; i < m_sessions.length; )
        {
            TelnetSession s = m_sessions[i];

            // update session
            if (s.isAttached)
                s.update();

            // clean up closed sessions
            if (!s.isAttached)
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

    Console* m_console;
    TCPServer m_server;

    Array!TelnetSession m_sessions;

    void acceptConnection(TCPStream client, void* userData)
    {
        TelnetSession session = m_console.createSession!TelnetSession(client);
        m_sessions ~= session;

        // TODO: we might implement a login script here...
//        if (!listenPort.loginScript.IsEmpty())
//        {
//            // TODO: implement this in a better way that the prompt and command are not echoed to the session...
//            bcString login = listenPort.loginScript;
//            login.Append("\r\n");
//            s.SetInput(login);
//        }
    }
}
