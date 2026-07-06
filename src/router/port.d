module router.port;

import urt.array;
import urt.mem;
import urt.meta.enuminfo : enum_key_from_value;
import urt.meta.nullable;
import urt.string;
import urt.string.format;

import manager;
import manager.console.session;
import manager.plugin;

nothrow @nogc:


enum PortKind : ubyte
{
    unknown,
    ethernet,
    wifi,
    serial,
    can,
    ble,
}

enum PortFlags : ubyte
{
    none       = 0,
    removable  = 1 << 0,
    virtual_   = 1 << 1,
    configured = 1 << 2,
}

struct PortUsb
{
    ushort vid;
    ushort pid;
    const(char)[] manufacturer;
    const(char)[] product;
    const(char)[] serial;

    bool valid() const pure
        => vid != 0 || pid != 0;
}

struct PortInfo
{
    PortKind kind;
    PortFlags flags;

    // Stable driver-owned key. Examples: linux:net:eth0, linux:tty:/dev/ttyUSB0.
    String id;

    // User-facing short name, usually the kernel adapter name or device node.
    String name;

    // OS path or adapter token consumed by stream/interface drivers.
    String path;

    // Driver/module that published this port.
    String driver;

    // Optional user-facing details such as USB serial description or NIC driver.
    String description;

    // Bus identity (USB vid:pid and descriptor strings), zero/empty when not applicable.
    ushort vid;
    ushort pid;
    String manufacturer;
    String product;
    String serial;
}

class PortModule : Module
{
    mixin DeclareModule!"router.port";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!PortKind();
        g_app.console.register_command!port_print("/port", this, "print");
    }

    const(PortInfo)[] ports() const pure
        => _ports[];

    PortInfo* find(PortKind kind, const(char)[] id)
    {
        foreach (ref p; _ports[])
            if (p.kind == kind && p.id[] == id)
                return &p;
        return null;
    }

    PortInfo* add(PortKind kind, const(char)[] id, const(char)[] name,
                  const(char)[] path = null, const(char)[] driver = null,
                  const(char)[] description = null, PortFlags flags = PortFlags.none,
                  PortUsb usb = PortUsb.init)
    {
        if (!id.length)
            return null;
        if (!name.length)
            name = id;
        if (!path.length)
            path = name;

        PortInfo* p = find(kind, id);
        if (p is null)
        {
            PortInfo info;
            info.kind = kind;
            _ports ~= info;
            p = &_ports[$ - 1];
        }

        p.kind = kind;
        p.flags = flags;
        assign(p.id, id);
        assign(p.name, name);
        assign(p.path, path);
        assign(p.driver, driver);
        assign(p.description, description);
        p.vid = usb.vid;
        p.pid = usb.pid;
        assign(p.manufacturer, usb.manufacturer);
        assign(p.product, usb.product);
        assign(p.serial, usb.serial);
        ++_generation;
        return p;
    }

    bool remove(PortKind kind, const(char)[] id)
    {
        foreach (i, ref p; _ports[])
        {
            if (p.kind == kind && p.id[] == id)
            {
                _ports.remove(i);
                ++_generation;
                return true;
            }
        }
        return false;
    }

    void remove_driver(const(char)[] driver)
    {
        for (size_t i = 0; i < _ports.length; )
        {
            if (_ports[i].driver[] == driver)
            {
                _ports.remove(i);
                ++_generation;
            }
            else
                ++i;
        }
    }

    uint generation() const pure
        => _generation;

    void port_print(Session session, Nullable!PortKind kind)
    {
        import urt.string.format : tformat;
        bool any;
        foreach (ref p; _ports[])
        {
            if (kind && p.kind != kind.value)
                continue;
            any = true;
            session.write_line(enum_key_from_value!PortKind(p.kind), "  ", p.name[],
                               "  id=", p.id[],
                               p.path.length ? tconcat("  path=", p.path[]) : "",
                               p.driver.length ? tconcat("  driver=", p.driver[]) : "",
                               p.description.length ? tconcat("  ", p.description[]) : "",
                               (p.vid || p.pid) ? tformat("  usb={0,04x}:{1,04x}", p.vid, p.pid) : "",
                               p.product.length ? tconcat("  product=\"", p.product[], "\"") : "",
                               p.serial.length ? tconcat("  serial=", p.serial[]) : "");
        }
        if (!any)
            session.write_line("No ports found");
    }

private:
    Array!PortInfo _ports;
    uint _generation;

    static void assign(ref String dst, const(char)[] value)
    {
        dst = value.length ? value.makeString(defaultAllocator) : String();
    }
}

PortInfo* port_add(PortKind kind, const(char)[] id, const(char)[] name,
                   const(char)[] path = null, const(char)[] driver = null,
                   const(char)[] description = null, PortFlags flags = PortFlags.none,
                   PortUsb usb = PortUsb.init)
{
    PortModule mod = get_module!PortModule;
    return mod ? mod.add(kind, id, name, path, driver, description, flags, usb) : null;
}

bool port_remove(PortKind kind, const(char)[] id)
{
    PortModule mod = get_module!PortModule;
    return mod ? mod.remove(kind, id) : false;
}

void port_remove_driver(const(char)[] driver)
{
    if (PortModule mod = get_module!PortModule)
        mod.remove_driver(driver);
}

const(PortInfo)[] port_list()
{
    PortModule mod = get_module!PortModule;
    return mod ? mod.ports : null;
}
