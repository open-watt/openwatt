module driver.sfp;

import manager;
import manager.features;
import manager.plugin;

import router.iface.sfp;

version (Windows)
    alias SFPPort = SFPInterface;
else version (linux)
    alias SFPPort = SFPInterface;
else
{
    import urt.driver.ethernet : num_ethernet;
    static if (num_ethernet > 0)
    {
        import driver.baremetal.sfp : BuiltinSFP;
        alias SFPPort = BuiltinSFP;
    }
    else
        alias SFPPort = SFPInterface;
}

nothrow @nogc:


struct SFPModule
{
    mixin DeclareStaticModule!"driver.sfp";
nothrow @nogc:

    static void init()
    {
        g_app.console.register_collection!SFPPort();
        SFPInterface.init_doorbell();
        static if (has_all)
            g_app.console.register_collection!SFPBinding();
    }
}
