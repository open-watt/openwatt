module manager.plugin;

import urt.string;

import manager;
import manager.config : ConfItem;

nothrow @nogc:


class Module
{
nothrow @nogc:

    String module_name;
    size_t module_id = -1;

    void init()
    {
    }

    void post_init()
    {
    }

    void pre_update()
    {
    }

    void update()
    {
    }

    void post_update()
    {
    }

protected:
    this(Application app, String name)
    {
        import urt.lifetime : move;
        this.module_name = name.move;
    }
}

// helper template to register a plugin
mixin template DeclareModule(string name)
{
    import manager : Application;
    import urt.string : StringLit;

    enum string ModuleName = name;

    this(Application app) nothrow @nogc
    {
        super(app, StringLit!ModuleName);
    }
}


//
// HACK: MANUALLY REGISTER ALL THE MODULES
//
void register_modules(Application app)
{
    import manager.log, manager.pcap, manager.cron;
    register_module!(manager.log)(app);
    register_module!(manager.pcap)(app);
    register_module!(manager.cron)(app);

    import router.stream;
    register_module!(router.stream)(app);
    register_module!(router.stream.bridge)(app);
    register_module!(router.stream.serial)(app);
    register_module!(router.stream.tcp)(app);
    register_module!(router.stream.udp)(app);

    import router.iface;
    register_module!(router.iface)(app);
    register_module!(router.iface.bridge)(app);
    register_module!(router.iface.can)(app);
    register_module!(router.iface.ethernet)(app);
    register_module!(router.iface.modbus)(app);
    register_module!(router.iface.tesla)(app);

    import protocol;
    register_module!(protocol.can)(app);
    register_module!(protocol.dns)(app);
    register_module!(protocol.esphome)(app);
    register_module!(protocol.ezsp)(app);
    register_module!(protocol.goodwe)(app);
    register_module!(protocol.http)(app);
    register_module!(protocol.ip)(app);
    register_module!(protocol.modbus)(app);
    register_module!(protocol.mqtt)(app);
    register_module!(protocol.ppp)(app);
//    register_module!(protocol.snmp)(app);
    register_module!(protocol.telnet)(app);
    register_module!(protocol.tesla)(app);
    register_module!(protocol.zigbee)(app);

    import apps.api;
    register_module!(apps.api)(app);

    import apps.energy;
    register_module!(apps.energy)(app);
}


private:

void register_module(alias mod)(Application app)
{
    alias AllModules = Modules!mod;
    static if (AllModules.length == 0)
        pragma(msg, "Warning: No `Module`s declared in ", mod.stringof);
    else static foreach (m; AllModules)
        app.register_module(app.allocator.allocT!m(app));
}

import urt.meta : AliasSeq;
template Modules(alias mod)
{
    alias Modules = AliasSeq!();
    static foreach (m; __traits(allMembers, mod))
    {
        static if (is(__traits(getMember, mod, m) : Module))
            Modules = AliasSeq!(Modules, __traits(getMember, mod, m));
    }
}
