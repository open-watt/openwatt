module router.transport;

// L4 endpoint layer: family-agnostic transports. Ether peers ride the router fabric on every
// platform; ip peers lower onto the internal stack when the ip module is present, else onto
// the OS kernel's sockets.

import urt.time;

import manager : g_app;
import manager.collection;
import manager.console;
import manager.features : has_ip, has_tcp, has_tcp_endpoints;
import manager.plugin;

import router.transport.tcp;
import router.transport.udp;
import router.transport.tcp.stream;

nothrow @nogc:


// Pure build-shape flags. This module must not import protocol.ip: the ip stack imports the
// transports back, and a static if here that needed an ip symbol would deadlock the cycle.
version (UseInternalIPStack) enum internal_stack = true; else enum internal_stack = false;
enum ip_lowering = has_ip && internal_stack;    // transports lower ip peers onto the internal stack
enum os_sockets  = !internal_stack;             // the host kernel carries the ip families
version (Windows) enum os_iocp = os_sockets; else enum os_iocp = false;  // ... via overlapped winsock
enum os_bsd = os_sockets && !os_iocp;                                    // ... via urt.socket


class TransportModule : Module
{
    mixin DeclareModule!"router.transport";
nothrow @nogc:

    override void init()
    {
        static if (has_tcp_endpoints)
        {
            g_app.console.register_collection!TCPStream();
            g_app.console.register_collection!TCPServer();
        }
        static if (has_tcp)
        {
            import router.iface.endpoint : set_ether_tcp_input;
            import router.transport.tcp.engine : tcp_print;

            set_ether_tcp_input(&ether_tcp_input);
            g_app.console.register_command!tcp_print("/transport/tcp", this, "print");
        }
        g_app.console.register_command!udp_print("/transport/udp", this, "print");

        static if (os_iocp)
        {
            import driver.windows.winsock : load_socket_extensions;
            load_socket_extensions();
        }
    }

    override void deinit()
    {
        tcp_deinit();
        udp_deinit();
    }

    override void update()
    {
        tcp_update();
        udp_update();
        static if (has_tcp_endpoints)
            Collection!TCPServer().update_all();
    }
}
