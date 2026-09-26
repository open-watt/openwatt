module driver.sfp;

import manager;
import manager.plugin;

import router.iface.sfp;

import driver.ethernet : SFPPort;

nothrow @nogc:


final class SFPModule : Module
{
    mixin DeclareModule!"driver.sfp";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!SFPPort();
        g_app.console.register_collection!SFPBinding();
    }
}
