module protocol.tls;

import manager;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

static if (has_tls)
{
    public import protocol.tls.certificate;
    public import protocol.tls.stream;
}

nothrow @nogc:


static if (has_tls)
{
    struct TLSModule
    {
    mixin DeclareStaticModule!"tls";
    nothrow @nogc:

        static void init()
        {
            g_app.register_enum!CertType();
            g_app.register_enum!CertStatus();

            g_app.console.register_collection!Certificate();
            g_app.console.register_collection!TLSStream();
            g_app.console.register_collection!TLSServer();
        }

        static void update()
        {
            Collection!Certificate().update_all();
            Collection!TLSServer().update_all();
        }
    }
}
