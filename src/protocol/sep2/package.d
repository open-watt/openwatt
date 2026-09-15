module protocol.sep2;

import manager;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

static if (has_tls && has_http_client)
{
    public import protocol.sep2.client;
    public import protocol.sep2.der;
    public import protocol.sep2.schema;
}

nothrow @nogc:


static if (has_tls && has_http_client)
{
    class Sep2Module : Module
    {
        mixin DeclareModule!"sep2";
    nothrow @nogc:

        override void init()
        {
            g_app.register_enum!Sep2Phase();
            g_app.console.register_collection!Sep2Binding();
        }
    }
}
