module manager.plugin;

import urt.log : Log;
import urt.mem;
import urt.string;

import manager;
import manager.config : ConfItem;
import manager.features;

nothrow:


class Module
{
nothrow @nogc:

    alias log = Log!module_name;

    String module_name;

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

enum ModulePhase : ubyte
{
    pre_init,
    init,
    post_init,
    deinit,
    pre_update,
    update,
    post_update,
}
alias ModuleHook = void function() nothrow @nogc;

struct ModuleRegistration
{
    string name;
    void* state;
    ModuleHook[ModulePhase.max + 1] hooks;
    void function(Application) nothrow @nogc construct;

    void run(ModulePhase phase) const nothrow @nogc
    {
        if (auto hook = hooks[phase])
            invoke(hook);
    }

    void invoke(ModuleHook hook) const nothrow @nogc
    {
        if (state)
        {
            void delegate() nothrow @nogc dg;
            dg.ptr = cast(void*)state;
            dg.funcptr = hook;
            dg();
        }
        else
            hook();
    }
}

mixin template DeclareStaticModule(string name)
{
    enum string ModuleName = name;
    enum is_static_module = true;
}

template legacy_instance(T)
{
    __gshared LegacyModuleState legacy_instance;
}

struct LegacyModuleState
{
    Module instance;

    void invoke(string phase)() nothrow @nogc
    {
        __traits(getMember, instance, phase)();
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


__gshared const(ModuleRegistration[]) registrations = collect_modules();

void run_module_phase(ModulePhase phase, scope const(ModuleRegistration)[] modules = registrations) nothrow @nogc
{
    foreach (ref entry; modules)
        entry.run(phase);
}

static assert(module_names_unique(registrations), "Duplicate module name");

private bool module_names_unique(scope const ModuleRegistration[] modules)
{
    foreach (i, ref module_; modules)
        foreach (ref previous; modules[0 .. i])
            if (module_.name == previous.name)
                return false;
    return true;
}

private ModuleRegistration[] collect_modules()
{
    ModuleRegistration[] result;
    import manager.log, manager.cron, manager.object_signal, manager.panel, manager.record, manager.sync,
           manager.sync.discovery, manager.sync.peering;
    result ~= collect_module!(manager.log)();
    result ~= collect_module!(manager.cron)();
    result ~= collect_module!(manager.object_signal)();
    result ~= collect_module!(manager.panel)();
    result ~= collect_module!(manager.record)();
    result ~= collect_module!(manager.sync)();
    result ~= collect_module!(manager.sync.discovery)();
    result ~= collect_module!(manager.sync.peering)();

    version (NoIDFLog) {}
    else version (ESP8266) {}
    else version (Espressif)
    {
        import driver.esp32.idf_log_bridge;
        result ~= collect_module!(driver.esp32.idf_log_bridge)();
    }

    import router.port;
    result ~= collect_module!(router.port)();

    static if (has_switch)
    {
        version (SmartEVSE)
        {
            import driver.boards.smartevse;
            result ~= collect_module!(driver.boards.smartevse)();
        }

        version (linux)
        {
            import driver.linux.fdwatch;
            result ~= collect_module!(driver.linux.fdwatch)();
            import driver.linux.netlink;
            result ~= collect_module!(driver.linux.netlink)();
            import driver.linux.netlink_write;
            result ~= collect_module!(driver.linux.netlink_write)();
            version (KernelMirror)
            {
                import driver.linux.bridge;
                result ~= collect_module!(driver.linux.bridge)();
                import driver.linux.netlink_dump;
                result ~= collect_module!(driver.linux.netlink_dump)();
            }
        }

        import router.pcap;
        result ~= collect_module!(router.pcap)();

        import router.stream;
        result ~= collect_module!(router.stream)();
        result ~= collect_module!(router.stream.bridge)();
        version (Embedded) {}
        else
            result ~= collect_module!(router.stream.console)();
        result ~= collect_module!(router.stream.duplex)();
        result ~= collect_module!(router.stream.file)();
        result ~= collect_module!(router.stream.memory)();
        result ~= collect_module!(router.stream.serial)();
        version (ESP32_C3)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_C5)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_C6)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_H2)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_P4)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_S2)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_S3)
            result ~= collect_module!(router.stream.usb_serial)();
        else version (ESP32_S31)
            result ~= collect_module!(router.stream.usb_serial)();

        import manager.console.session;
        result ~= collect_module!(manager.console.session)();

        import router.iface;
        result ~= collect_module!(router.iface)();
        result ~= collect_module!(router.iface.bridge)();
        result ~= collect_module!(router.iface.i2c)();
        result ~= collect_module!(router.iface.wifi)();
        result ~= collect_module!(router.iface.wpan)();
        version (BL808)
        {
            import driver.bl808.xram;
            result ~= collect_module!(driver.bl808.xram)();
        }

        import driver.ethernet, driver.wifi, driver.wpan;
        result ~= collect_module!(driver.ethernet)();
        result ~= collect_module!(driver.wifi)();
        static if (is(WpanModule))
            result ~= collect_module!(driver.wpan)();

        static if (has_sfp)
        {
            import driver.sfp;
            result ~= collect_module!(driver.sfp)();
        }
    }

    static if (has_all)
    {
        import driver.power.regulator;
        result ~= collect_module!(driver.power.regulator)();

        import driver.rtc.pcf85063;
        result ~= collect_module!(driver.rtc.pcf85063)();

        import protocol;
        result ~= collect_module!(protocol.ble)();

        import driver.ble;
        static if (is(BLEDriverModule))
            result ~= collect_module!(driver.ble)();
        result ~= collect_module!(protocol.can)();

        import driver.can;
        static if (is(CANDriverModule))
            result ~= collect_module!(driver.can)();

        result ~= collect_module!(protocol.cpc)();
        result ~= collect_module!(protocol.dhcp)();
        result ~= collect_module!(protocol.dns)();
        result ~= collect_module!(protocol.esphome)();
        result ~= collect_module!(protocol.ezsp)();
        result ~= collect_module!(protocol.goodwe)();
        result ~= collect_module!(protocol.gpio)();
        result ~= collect_module!(protocol.http)();
        result ~= collect_module!(protocol.ip)();
        static if (has_modbus)
            result ~= collect_module!(protocol.modbus)();
        result ~= collect_module!(protocol.mqtt)();
        result ~= collect_module!(protocol.ntp)();
        result ~= collect_module!(protocol.obd)();
        result ~= collect_module!(protocol.ppp)();
//        result ~= collect_module!(protocol.snmp)();
        result ~= collect_module!(protocol.spinel)();
        result ~= collect_module!(protocol.telnet)();
        result ~= collect_module!(protocol.tesla)();
        result ~= collect_module!(protocol.zigbee)();

        static if (has_tls)
        {
            import protocol.tls;
            result ~= collect_module!(protocol.tls)();
        }

        import apps.api;
        result ~= collect_module!(apps.api)();

        import apps.automation;
        result ~= collect_module!(apps.automation)();

        import apps.energy;
        result ~= collect_module!(apps.energy)();

        import apps.ota;
        result ~= collect_module!(apps.ota)();
    }
    else
    {
        static if (has_ip)
        {
            import protocol.ip;
            import protocol.dhcp;
            result ~= collect_module!(protocol.ip)();
            result ~= collect_module!(protocol.dhcp)();
        }

        static if (has_http)
        {
            import protocol.http;
            result ~= collect_module!(protocol.http)();
        }

        static if (has_tls)
        {
            import protocol.tls;
            result ~= collect_module!(protocol.tls)();
        }

        static if (has_ota)
        {
            import apps.automation;
            result ~= collect_module!(apps.automation)();

            import apps.ota;
            result ~= collect_module!(apps.ota)();
        }

        static if (has_api)
        {
            import apps.api;
            result ~= collect_module!(apps.api)();
        }
    }
    return result;
}


private:

ModuleRegistration[] collect_module(alias mod)()
{
    ModuleRegistration[] result;
    static foreach (m; __traits(allMembers, mod))
    {{
        static if (is(__traits(getMember, mod, m) : Module))
        {
            alias T = __traits(getMember, mod, m);
            static if (__traits(hasMember, T, "ModuleName"))
                result ~= describe_legacy_module!T();
        }
        else static if (is(__traits(getMember, mod, m) == struct))
        {
            alias T = __traits(getMember, mod, m);
            static if (__traits(hasMember, T, "is_static_module"))
                result ~= describe_static_module!T();
        }
    }}
    return result;
}

ModuleRegistration describe_static_module(T)()
{
    ModuleRegistration result;
    result.name = T.ModuleName;
    enum stateful = __traits(hasMember, T, "module_state");
    static if (stateful)
    {
        static assert(is(typeof(T.module_state) == T));
        static assert(__traits(isZeroInit, T));
        result.state = cast(void*)&T.module_state;
    }

    static foreach (phase; __traits(allMembers, ModulePhase))
    {{
        static if (__traits(hasMember, T, phase))
        {
            alias hook = __traits(getMember, T, phase);
            static assert(__traits(isStaticFunction, hook) != stateful,
                T.stringof ~ "." ~ phase ~ " must match the module's state");
            result.hooks[__traits(getMember, ModulePhase, phase)] = &hook;
        }
    }}
    return result;
}

ModuleRegistration describe_legacy_module(T)()
{
    ModuleRegistration result;
    result.name = T.ModuleName;
    result.state = cast(void*)&legacy_instance!T;
    result.construct = &construct_module!T;
    static foreach (phase; __traits(allMembers, ModulePhase))
    {
        static if (__traits(hasMember, T, phase) && !is(__traits(parent, __traits(getMember, T, phase)) == Module))
            result.hooks[__traits(getMember, ModulePhase, phase)] = &LegacyModuleState.invoke!phase;
    }
    return result;
}

void construct_module(T)(Application app) @nogc
{
    legacy_instance!T.instance = alloc!T(app);
}


unittest
{
    static struct Stateful
    {
    nothrow @nogc:
        int count;
        void update() { ++count; }
    }

    static struct Stateless
    {
    nothrow @nogc:
        static __gshared int count;
        static void update() { ++count; }
    }

    Stateful state;
    ModuleRegistration entry;
    entry.state = &state;
    entry.hooks[ModulePhase.update] = &Stateful.update;
    entry.run(ModulePhase.pre_init);
    assert(state.count == 0);
    entry.run(ModulePhase.update);
    assert(state.count == 1);

    entry.state = null;
    entry.hooks[ModulePhase.update] = &Stateless.update;
    entry.run(ModulePhase.update);
    assert(Stateless.count == 1);
}
