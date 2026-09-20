module protocol.sep2;

import manager;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

nothrow @nogc:


static if (has_tls && has_http_client)
{
    public import protocol.sep2.binding;
    public import protocol.sep2.der;
    public import protocol.sep2.schema;

    final class Sep2Module : Module
    {
        mixin DeclareModule!"sep2";
    nothrow @nogc:

        override void init()
        {
            g_app.register_enum!Sep2Phase();
            g_app.register_enum!Sep2Scheme();
            g_app.console.register_collection!Sep2Binding();
        }
    }
}
