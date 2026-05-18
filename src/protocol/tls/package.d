module protocol.tls;

public import protocol.tls.certificate;
public import protocol.tls.stream;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

nothrow @nogc:


class TLSModule : Module
{
    mixin DeclareModule!"tls";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!Certificate();
        g_app.console.register_collection!TLSStream();
        g_app.console.register_collection!TLSServer();
    }

    override void update()
    {
        Collection!Certificate().update_all();
        Collection!TLSServer().update_all();
    }
}
