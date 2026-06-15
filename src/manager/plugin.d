module manager.plugin;

import urt.log : Log;
import urt.string;

import manager;
import manager.config : ConfItem;
import manager.features;

nothrow @nogc:


class Module
{
nothrow @nogc:

    alias log = Log!module_name;

    String module_name;
    size_t module_id = -1;

    void pre_init()
    {
    }

    void init()
    {
    }

    void post_init()
    {
    }

    void deinit()
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
    import manager.log, manager.cron, manager.record, manager.sync;
    import db;
    register_module!(manager.log)(app);
    register_module!(manager.cron)(app);
    register_module!(db)(app);
    register_module!(manager.record)(app);
    register_module!(manager.sync)(app);

    static if (has_switch)
    {
        version (linux)
        {
            import driver.linux.fdwatch;
            register_module!(driver.linux.fdwatch)(app);
            import driver.linux.netlink;
            register_module!(driver.linux.netlink)(app);
            import driver.linux.netlink_write;
            register_module!(driver.linux.netlink_write)(app);
            version (KernelMirror)
            {
                import driver.linux.bridge;
                register_module!(driver.linux.bridge)(app);
                import driver.linux.netlink_dump;
                register_module!(driver.linux.netlink_dump)(app);
            }
        }

        import router.pcap;
        register_module!(router.pcap)(app);

        import router.stream;
        register_module!(router.stream)(app);
        register_module!(router.stream.bridge)(app);
        register_module!(router.stream.console)(app);
        register_module!(router.stream.duplex)(app);
        register_module!(router.stream.file)(app);
        register_module!(router.stream.memory)(app);
        register_module!(router.stream.serial)(app);

        import router.iface;
        register_module!(router.iface)(app);
        register_module!(router.iface.bridge)(app);
        register_module!(router.iface.wifi)(app);

        import driver.ethernet, driver.wifi;
        register_module!(driver.ethernet)(app);
        register_module!(driver.wifi)(app);
    }

    static if (has_all)
    {
        import protocol;
        register_module!(protocol.ble)(app);

        import driver.ble;
        static if (is(BLEDriverModule))
            register_module!(driver.ble)(app);
        register_module!(protocol.can)(app);
        register_module!(protocol.dhcp)(app);
        register_module!(protocol.dns)(app);
        register_module!(protocol.esphome)(app);
        register_module!(protocol.ezsp)(app);
        register_module!(protocol.goodwe)(app);
        register_module!(protocol.http)(app);
        register_module!(protocol.ip)(app);
        register_module!(protocol.modbus)(app);
        register_module!(protocol.mqtt)(app);
        register_module!(protocol.ntp)(app);
        register_module!(protocol.ppp)(app);
//        register_module!(protocol.snmp)(app);
        register_module!(protocol.telnet)(app);
        register_module!(protocol.tesla)(app);
        register_module!(protocol.zigbee)(app);

        static if (has_tls)
        {
            import protocol.tls;
            register_module!(protocol.tls)(app);
        }

        import apps.api;
        register_module!(apps.api)(app);

        import apps.energy;
        register_module!(apps.energy)(app);

        import apps.ota;
        register_module!(apps.ota)(app);
    }
    else static if (has_ip)
    {
        import protocol.ip;
        import protocol.dhcp;
        register_module!(protocol.ip)(app);
        register_module!(protocol.dhcp)(app);
    }
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
