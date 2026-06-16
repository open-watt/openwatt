module protocol.ntp;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.ntp.client;

nothrow @nogc:


class NTPModule : Module
{
    mixin DeclareModule!"protocol.ntp";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!NTPClient();
    }

    override void update()
    {
        Collection!NTPClient().update_all();
    }
}
