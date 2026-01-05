module protocol.dns;

import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.dns;
import protocol.dns.server;

nothrow @nogc:


struct NSLookupResult
{
    bool ready;
    // TODO: details...
}

class DNSModule : Module
{
    mixin DeclareModule!"protocol.dns";
nothrow @nogc:

    // TODO - DNS/name cache

    Collection!DNSServer servers;

    override void init()
    {
        g_app.console.registerCollection("/protocol/dns/server", servers);

        g_app.console.registerCommand!request("/protocol/dns", this, "lookup");
    }

    override void update()
    {
        servers.update_all();
    }


    static class DNSRequestState : FunctionCommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.InProgress;

        this(Session session)
        {
            super(session);
        }

        ~this()
        {
        }

        override CommandCompletionState update()
        {
            // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

            return state;
        }

        //...
    }

    DNSRequestState request(Session session, const(char)[] hostname)
    {
        // try:
        // Local DNS/hostname cache
        // Hosts file
        // DNS servers (or mDNS for .local)
        // LLMNR (if enabled)
        // NBNS broadcast (if NetBIOS over TCP/IP is enabled)
        // WINS (if configured)

        DNSRequestState state = g_app.allocator.allocT!DNSRequestState(session);
//        c.request(method, uri, &state.response_handler);
        return state;
    }
}
