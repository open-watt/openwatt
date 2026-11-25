module protocol.ntp;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.ntp.client;

nothrow @nogc:


struct NTPModule
{
    mixin DeclareStaticModule!"protocol.ntp";
nothrow @nogc:

    static void init()
    {
        g_app.console.register_collection!NTPClient();
    }

    static void update()
    {
        Collection!NTPClient().update_all();
    }
}
