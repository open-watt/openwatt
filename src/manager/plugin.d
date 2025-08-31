module manager.plugin;

import urt.string;

import manager;
import manager.config : ConfItem;

nothrow @nogc:


class Module
{
nothrow @nogc:

    String moduleName;
    size_t moduleId = -1;

    void init()
    {
    }

    void preUpdate()
    {
    }

    void update()
    {
    }

    void postUpdate()
    {
    }

protected:
    this(Application app, String name)
    {
        import urt.lifetime : move;
        this.moduleName = name.move;
    }
}

// helper template to register a plugin
mixin template DeclareModule(string name)
{
    import manager : Application;

    enum string ModuleName = name;

    this(Application app) nothrow @nogc
    {
        super(app, StringLit!ModuleName);
    }
}


//
// HACK: MANUALLY REGISTER ALL THE MODULES
//
void registerModules(Application app)
{
    import manager.log;
    registerModule!(manager.log)(app);
    registerModule!(manager.pcap)(app);

    import router.stream;
    registerModule!(router.stream)(app);
    registerModule!(router.stream.bridge)(app);
    registerModule!(router.stream.serial)(app);
    registerModule!(router.stream.tcp)(app);
    registerModule!(router.stream.udp)(app);

    import router.iface;
    registerModule!(router.iface)(app);
    registerModule!(router.iface.bridge)(app);
    registerModule!(router.iface.can)(app);
    registerModule!(router.iface.modbus)(app);
    registerModule!(router.iface.tesla)(app);
    registerModule!(router.iface.zigbee)(app);

    import protocol;
    registerModule!(protocol.dns)(app);
    registerModule!(protocol.ezsp)(app);
    registerModule!(protocol.http)(app);
    registerModule!(protocol.modbus)(app);
    registerModule!(protocol.mqtt)(app);
    registerModule!(protocol.ppp)(app);
//    registerModule!(protocol.snmp)(app);
    registerModule!(protocol.telnet)(app);
    registerModule!(protocol.tesla)(app);
    registerModule!(protocol.zigbee)(app);

    import apps.energy;
    registerModule!(apps.energy)(app);
}


private:

void registerModule(alias mod)(Application app)
{
    alias AllModules = Modules!mod;
    static if (AllModules.length == 0)
        pragma(msg, "Warning: No `Module`s declared in ", mod.stringof);
    else static foreach (m; AllModules)
        app.registerModule(app.allocator.allocT!m(app));
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
