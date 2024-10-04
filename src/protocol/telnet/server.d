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
        this.name = name.move;
        m_allocator = allocator;
        m_console = console;
//        , m_listeners(allocator)
//        , m_sessions(allocator)

        m_server = m_allocator.allocT!TCPServer(name, port, &acceptConnection, null);
    }

    ~this()
    {
        m_server.stop();

//        for (dcTelnetSession* ts : m_sessions)
//            m_allocator.Delete(ts);
//
//        for (auto&& listener : m_listeners)
//        {
//            if (listener.listenSocket != bcInvalidSocket)
//                bcCloseSocket(listener.listenSocket);
//        }
//
//        bcSocketTerminate();
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
//        for (auto&& listener : m_listeners)
//        {
//            if (listener.listenPort == listenPort)
//                return false;
//        }
//
//        ListenPort newPort{
//            listenPort,
//                bcInvalidSocket,
//                console,
//                bcString{ m_allocator, loginScript ? loginScript : "" }
//        };
//
//        bcAddressInfo hints;
//        bcMemZero(&hints, sizeof(hints));
//        hints.family = bcAddressFamily::Inet;
//        hints.sockType = bcSocketType::Stream;
//        hints.protocol = bcProtocol::TCP;
//        hints.flags = bcAddressInfoFlags::Passive;
//
//        char portNumber[11];
//        bcToString(portNumber, listenPort);
//
//        bcAddressInfoResolver aiResult;
//        if (!bcGetAddressInfo(nullptr, portNumber, &hints, aiResult))
//            return false;
//
//        bcAddressInfo ai;
//        if (!aiResult.GetNextAddress(&ai))
//            return false;
//
//        bcResult r = bcOpenSocket(ai.family, ai.sockType, ai.protocol, newPort.listenSocket);
//        if (newPort.listenSocket == bcInvalidSocket)
//            return false;
//
//        r = bcBind(newPort.listenSocket, ai.address);
//        if (r)
//            r = bcListen(newPort.listenSocket);
//        if (!r)
//        {
//            bcCloseSocket(newPort.listenSocket);
//            newPort.listenSocket = bcInvalidSocket;
//            return false;
//        }
//
//        m_listeners.PushBack(bcMove(newPort));
//        return true;
        return false;
    }

    /// Update the telnet server. Should be called once per frame (or periodically) from a main thread.
    void update()
    {
        m_server.update();

        foreach (i, s; m_sessions)
        {
            if (s.isAttached)
                s.update();

            // clean up closed sessions
            if (!s.isAttached)
            {
                m_allocator.freeT(s);
                // TODO: remove the item from the array!
                assert(false);
            }
        }

//        bcPollFd fds[128];
//        size_t numSockets = 0;
//        for (auto& listener : m_listeners)
//        {
//            if (listener.listenSocket == bcInvalidSocket)
//                continue;
//            fds[numSockets].socket = listener.listenSocket;
//            fds[numSockets].requestEvents = bcPollEvents::Read;
//            fds[numSockets].userData = &listener;
//            ++numSockets;
//        }
//
//        uint32 numEvents;
//        bcResult r = bcPoll(fds, numSockets, bcDuration_Zero, numEvents);
//        if (!r)
//        {
//            // poll failed?
//        }
//        for (uint32 i = 0; i < numSockets; ++i)
//        {
//            if (+(fds[i].returnEvents & bcPollEvents::Read))
//            {
//            dcTelnetServer::ListenPort& port = *static_cast<dcTelnetServer::ListenPort*>(fds[i].userData);
//                acceptConnection(port);
//            }
//        }
//
//        // clean up closed sessions
//        for (uint32 i = 0; i < m_sessions.Size(); )
//        {
//            dcTelnetSession* session = m_sessions[i];
//            if (!session->IsAttached())
//            {
//                m_sessions.Erase(i);
//                m_allocator.Delete(session);
//            }
//            else
//                ++i;
//        }
    }

package:
//    struct ListenPort
//    {
//        ushort listenPort;
//        bcSocket listenSocket;
//        dcDebugConsole* console;
//        bcString loginScript;
//    }

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
