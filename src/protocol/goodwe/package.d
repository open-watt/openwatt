module protocol.goodwe;

import urt.inet;
import urt.log;
import urt.result;
import urt.socket;

import manager;
import manager.collection;
import manager.plugin;

import protocol.goodwe.aa55;
import protocol.goodwe.binding;

nothrow @nogc:


class GoodWeModule : Module
{
    mixin DeclareModule!"protocol.goodwe";
nothrow @nogc:

    Socket aa55_socket;

    override void init()
    {
        g_app.console.register_collection!AA55Client();
        g_app.console.register_collection!GoodWeBinding();

        // Create socket for AA55 clients
        Socket socket;
        Result r = create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, socket);
        if (!r)
        {
            writeError("goodwe: failed to create AA55 socket: ", r);
            return;
        }

        r = socket.set_socket_option(SocketOption.non_blocking, true);
        if (!r)
        {
            socket.close();
            writeError("goodwe: failed to set non-blocking on AA55: ", r);
            return;
        }

        InetAddress bind_addr = InetAddress(IPAddr.any, 0);
        r = bind(socket, bind_addr);
        if (!r)
        {
            socket.close();
            writeError("goodwe: failed to bind AA55 socket: ", r);
            return;
        }

        aa55_socket = socket;
    }

    override void pre_update()
    {
        poll_aa55();

        Collection!AA55Client().update_all();
    }

    void poll_aa55()
    {
        if (!aa55_socket)
            return;

        ubyte[1024] buffer = void;
        size_t bytes;
        InetAddress sender;

        while (true)
        {
            MonoTime now = getTime();
            Result r = aa55_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes);
            if (!r)
            {
                if (r.socket_result() != SocketResult.would_block)
                {
                    // TODO: should we do anything?
                    //       recreate the socket? back-off for a while?
                    writeWarning("goodwe: recvfrom error: ", r);
                }
                break;
            }
            if (bytes == 0)
                continue; // degenerate zero-length packet?

            foreach (c; Collection!AA55Client().values)
            {
                if (c.match_server(sender))
                {
                    c.incoming_message(buffer[0 .. bytes], now);
                    break;
                }
            }
        }
    }

}
