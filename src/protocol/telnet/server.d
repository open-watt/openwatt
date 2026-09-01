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
import protocol.ip.tcp_stream;

nothrow @nogc:


class TelnetServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port));
nothrow @nogc:

    enum type_name = "telnet-server";
    enum path = "/protocol/telnet/server";
    enum collection_id = CollectionType.telnet_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TelnetServer, id, flags);
    }

    ushort port() const pure
        => _port;
    final void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        mark_set!(typeof(this), "port")();
        restart();
    }

    override bool validate() const
        => _port != 0;

    override CompletionStatus startup()
    {
        const(char)[] server_name = Collection!TCPServer().generate_name(name[]);
        _server = Collection!TCPServer().create(server_name, ObjectFlags.dynamic);
        if (!_server)
            return CompletionStatus.error;
        _server.port = _port;
        _server.set_connection_callback(&accept_connection, null);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_server)
        {
            _server.destroy();
            _server = null;
        }

        while (!_sessions.empty)
        {
            Session session = _sessions[$ - 1];
            _sessions.popBack();
            session.unsubscribe(&session_state_change);
            if (!(session.flags & ObjectFlags.disabled))
                g_app.console.destroy_session(session);
        }
        return CompletionStatus.complete;
    }

private:
    ushort _port;
    TCPServer _server;
    Array!Session _sessions;

    void accept_connection(Stream client, ref const InetAddress remote, void* user_data)
    {
        const(char)[] stream_name = Collection!Stream().generate_name(name[]);

        TelnetStream telnet_stream = Collection!TelnetStream().create(stream_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("transport", client));
        if (telnet_stream is null)
        {
            client.destroy();
            return;
        }

        Session session = g_app.console.createSession!Session(telnet_stream);
        session.show_prompt(true);
        session.load_history(".telnet_history");

        session.subscribe(&session_state_change);
        _sessions ~= session;
    }

    void session_state_change(ActiveObject object, StateSignal signal)
    {
        if (signal != StateSignal.destroyed)
            return;

        Session session = dyn_cast!Session(object);
        session.unsubscribe(&session_state_change);
        _sessions.removeFirstSwapLast(session);
    }
}
