module manager;

import urt.array;
import urt.lifetime : move;
import urt.map;
import urt.mem.allocator;
import urt.mem.string;
import urt.si.quantity;
import urt.si.unit;
import urt.string;

import manager.collection;
import manager.component;
import manager.console;
import manager.device;
import manager.plugin;
import manager.secret;
import manager.system;

public static import manager.pcap;

nothrow @nogc:


enum AuthResult : ubyte
{
    accepted,
    unknown_user,
    wrong_password,
    no_service_access,
}

alias AuthCallback = void delegate(AuthResult result, const(char)[] profile) nothrow @nogc;


__gshared Application g_app = null;

Application create_application()
{
    return defaultAllocator().allocT!Application();
}

void shutdown_application()
{
    defaultAllocator().freeT(g_app);
}

Mod get_module(Mod)()
    if (is(Mod : Module))
{
    __gshared Mod g_module_instance = null;
    if (!g_module_instance)
        g_module_instance = cast(Mod)g_app.module_instance(Mod.ModuleName);
    return g_module_instance;
}


class Application
{
nothrow @nogc:

    String name;

    NoGCAllocator allocator;
    NoGCAllocator temp_allocator;

    Array!Module modules;

    Console console;

    Map!(const(char)[], Device) devices;

    uint update_rate_hz = 20;

    Collection!Secret secrets;

    // database...

    this()
    {
        import urt.mem;

        allocator = defaultAllocator;
        temp_allocator = temp_allocator;

        assert(!g_app, "Application already created!");
        g_app = this;

        console = Console(this, String("console".addString), Mallocator.instance);

        console.setPrompt(StringLit!"openwatt > ");

        console.registerCommand!log_level("/system", this);
        console.registerCommand!set_hostname("/system", this);
        console.registerCommand!get_hostname("/system", this, "hostname");
        console.registerCommand!set_update_rate("/system", this, "update-rate");
        console.registerCommand!uptime("/system", this);
        console.registerCommand!sysinfo("/system", this);
        console.registerCommand!show_time("/system", this, "time");
        console.registerCommand!sleep("/system", this);

        console.registerCommand!device_print("/device", this, "print");

        console.registerCollection("/secret", secrets);

        register_modules(this);

        foreach (m; modules)
            m.post_init();
    }

    ~this()
    {
        g_app = null;
    }

    void set_update_rate(Session, Quantity!(uint, Hertz) rate)
    {
        update_rate_hz = rate.value;
    }

    void register_module(Module mod)
    {
        import urt.string.format;

        foreach (m; modules)
            assert(m.module_name[] != mod.module_name, tconcat("Module '", mod.module_name, "' already registered!"));

        mod.module_id = modules.length;
        modules ~= mod;

        mod.init();
    }

    Module module_instance(const(char)[] name) pure
    {
        foreach (i; 0 .. modules.length)
            if (modules[i].module_name[] == name[])
                return modules[i];
        return null;
    }

    Mod module_instance(Mod)() pure
        if (is(Mod : Module))
    {
        return cast(Mod)module_instance(Mod.ModuleName);
    }

    bool validate_login(const(char)[] username, const(char)[] password, const(char)[] service, scope AuthCallback callback) const
    {
        if (const Secret* secret = secrets.exists(username[]))
        {
            if (secret.validate_password(password))
            {
                String profile;
                if (secret.allow_service(service, &profile))
                    callback(AuthResult.accepted, profile[]);
                else
                    callback(AuthResult.no_service_access, null);
                return true;
            }
            else
                callback(AuthResult.wrong_password, null);
            return true;
        }

        // TODO: request auth from RADIUS servers, etc...

        return false;
    }

    Device find_device(const(char)[] device_id) pure
    {
        if (Device* d = device_id[] in devices)
            return *d;
        return null;
    }

    Component find_component(const(char)[] name) pure
    {
        const(char)[] device_name = name.split!'.';
        if (Device* d = device_name[] in devices)
            return name.empty ? *d : (*d).find_component(name);
        return null;
    }

    void update()
    {
        foreach (m; modules)
            m.pre_update();

        foreach (m; modules)
            m.update();

        import urt.async : asyncUpdate;
        asyncUpdate();

        // TODO: polling is pretty lame! data connections should be in threads and receive data immediately
        // processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)
//        foreach (server; servers)
//            server.poll();
        foreach (device; devices.values)
            device.update();

        foreach (m; modules)
            m.post_update();
    }


    // /device/print command
    import urt.meta.nullable;
    void device_print(Session session, Nullable!(const(char)[]) _scope)
    {
        if (_scope)
        {
            // split on dots...
        }

        void printComponent(Component c, int indent)
        {
            session.writef("{'', *0}{1}: {2} [{3}]\n", indent, c.id, c.name, c.template_);
            foreach (e; c.elements)
                session.writef("{'', *5}  {0}{@4, ?3}: {2}\n", e.id, e.name, e.latest, e.name.length > 0, " ({1})", indent);
            foreach (c2; c.components)
                printComponent(c2, indent + 2);
        }

        const(char)[] newLine = "";
        foreach (dev; devices.values)
        {
            session.writeLine(newLine, dev.id, ": ", dev.name);
            newLine = "\n";
            foreach (c; dev.components)
                printComponent(c, 2);
        }


/+
        import urt.util;

        size_t nameLen = 4;
        size_t typeLen = 4;
        foreach (i, iface; interfaces)
        {
            nameLen = max(nameLen, iface.name.length);
            typeLen = max(typeLen, iface.type.length);

            // TODO: MTU stuff?
        }

        session.writeLine("Flags: R - RUNNING; S - SLAVE");
        if (stats)
        {
            size_t rxLen = 7;
            size_t txLen = 7;
            size_t rpLen = 9;
            size_t tpLen = 9;
            size_t rdLen = 7;
            size_t tdLen = 7;

            foreach (i, iface; interfaces)
            {
                rxLen = max(rxLen, iface.getStatus.recvBytes.format_int(null));
                txLen = max(txLen, iface.getStatus.sendBytes.format_int(null));
                rpLen = max(rpLen, iface.getStatus.recvPackets.format_int(null));
                tpLen = max(tpLen, iface.getStatus.sendPackets.format_int(null));
                rdLen = max(rdLen, iface.getStatus.recvDropped.format_int(null));
                tdLen = max(tdLen, iface.getStatus.sendDropped.format_int(null));
            }

            session.writef(" ID    {0, *1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {12, *13}\n",
                           "NAME", nameLen,
                           "RX-BYTE", rxLen, "TX-BYTE", txLen,
                           "RX-PACKET", rpLen, "TX-PACKET", tpLen,
                           "RX-DROP", rdLen, "TX-DROP", tdLen);

            size_t i = 0;
            foreach (iface; interfaces)
            {
                session.writef("{0, 3} {1}{2} {3, *4}  {5, *6}  {7, *8}  {9, *10}  {11, *12}  {13, *14}  {15, *16}\n",
                               i, iface.getStatus.linkStatus ? 'R' : ' ', iface.master ? 'S' : ' ',
                               iface.name, nameLen,
                               iface.getStatus.recvBytes, rxLen, iface.getStatus.sendBytes, txLen,
                               iface.getStatus.recvPackets, rpLen, iface.getStatus.sendPackets, tpLen,
                               iface.getStatus.recvDropped, rdLen, iface.getStatus.sendDropped, tdLen);
                ++i;
            }
        }
        else
        {
            session.writef(" ID    {0, *1}  {2, *3}  MAC-ADDRESS\n", "NAME", nameLen, "TYPE", typeLen);
            size_t i = 0;
            foreach (iface; interfaces)
            {
                session.writef("{0, 3} {6}{7}  {1, *2}  {3, *4}  {5}\n", i, iface.name, nameLen, iface.type, typeLen, iface.mac, iface.getStatus.linkStatus ? 'R' : ' ', iface.master ? 'S' : ' ');
                ++i;
            }
        }
+/
    }
}
