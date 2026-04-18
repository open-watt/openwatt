module manager;

import urt.array;
import urt.lifetime : move;
import urt.map;
import urt.mem.allocator;
import urt.mem.string;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.time;
import urt.traits : is_enum, Unqual;
import urt.variant;

import manager.collection;
import manager.component;
import manager.console;
import manager.device;
import manager.element;
import manager.id;
import manager.plugin;
import manager.secret;
import manager.system;

nothrow @nogc:


enum AuthResult : ubyte
{
    accepted,
    unknown_user,
    wrong_password,
    no_service_access,
}

alias AuthCallback = void delegate(AuthResult result, const(char)[] profile) nothrow @nogc;

alias IntrinsicFunction = Variant function(Variant[] args) nothrow @nogc;

struct ElementLink
{
nothrow @nogc:

    bool resolved() const pure
        => !a.dangling && a.elem !is null && !b.dangling && b.elem !is null;

    void resolve()
    {
        a.elem.add_subscriber(&element_updated);
        b.elem.add_subscriber(&element_updated);
        if (a.elem.last_update > b.elem.last_update)
            b.elem.value(a.elem.latest, a.elem.last_update);
        else if (b.elem.last_update > a.elem.last_update)
            a.elem.value(b.elem.latest, b.elem.last_update);
    }

    void unlink()
    {
        if (resolved)
        {
            a.elem.remove_subscriber(&element_updated);
            b.elem.remove_subscriber(&element_updated);
        }
        a.release();
        b.release();
    }

    void element_updated(ref Element changed, ref const Variant val, SysTime timestamp, ref const Variant, SysTime)
    {
        if (propagating)
            return;
        propagating = true;
        Element* dest = (&changed is a.elem) ? b.elem : a.elem;
        dest.value(val, timestamp);
        propagating = false;
    }

private:
    private struct Endpoint
    {
    nothrow @nogc:
        union
        {
            Element* elem;
            String _path;
            size_t _ptr;
        }

        bool dangling() const pure
            => (_ptr & 1) != 0;

        void set_element(Element* e)
        {
            elem = e;
        }

        void set_path(String path)
        {
            _path = path;
            assert((_ptr & 1) == 0);
            _ptr |= 1;
        }

        String path() const pure
        {
            size_t p = _ptr ^ 1;
            return *cast(String*)&p;
        }

        void release()
        {
            if (dangling)
            {
                _ptr ^= 1;
                _path = null;
            }
        }
    }

    Endpoint a;
    Endpoint b;
    bool propagating;
}

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

    struct RegisteredType
    {
        const(CollectionTypeInfo)* type_info;
        const(char)[] path;
    }

    String name;

    NoGCAllocator allocator;
    NoGCAllocator temp_allocator;

    Array!Module modules;

    Console console;
    Map!(String, IntrinsicFunction) intrinsic_functions;

    Map!(const(char)[], Device) devices;

    uint update_rate_hz = 20;

    Array!(ElementLink*) links;

    Map!(String, RegisteredType) types;
    Map!(String, const(VoidEnumInfo)*) enum_templates;

    // database...

    this()
    {
        import urt.mem;

        allocator = defaultAllocator;
        temp_allocator = temp_allocator;

        assert(!g_app, "Application already created!");
        g_app = this;

        id_init();
        init_collections();
        init_elements();

        register_enum!Boolean();
        register_enum!ObjectFlags();
        register_enum!HashFunction();

        register_intrinsic(StringLit!"select", &select);
        register_intrinsic(StringLit!"math.pow", &pow);

        console = Console(this, String("console".addString), Mallocator.instance);

        console.set_prompt(StringLit!"openwatt > ");

        console.register_command!log_level("/system", this);
        console.register_command!set_hostname("/system", this);
        console.register_command!get_hostname("/system", this, "hostname");
        console.register_command!set_update_rate("/system", this, "update-rate");
        console.register_command!uptime("/system", this);
        console.register_command!sysinfo("/system", this);
        console.register_command!show_time("/system", this, "time");
        console.register_command!sleep("/system", this);

        console.register_command!device_print("/device", this, "print");
        console.register_command!link_add("/element/link", this, "add");
        console.register_command!link_print("/element/link", this, "print");

        console.register_collection!Secret("/secret");

        register_modules(this);

        foreach (m; modules)
            m.pre_init();

        foreach (m; modules)
            m.init();

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

    bool validate_login(const(char)[] username, const(char)[] password, const(char)[] service, scope AuthCallback callback)
    {
        if (auto secret = Collection!Secret().get(username[]))
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

    Element* find_element(const(char)[] name) pure
    {
        const(char)[] device_name = name.split!'.';
        if (Device* d = device_name[] in devices)
            return name.empty ? null : (*d).find_element(name);
        return null;
    }

    void register_type(const(CollectionTypeInfo)* type_info, const(char)[] path)
    {
        assert(type_info.type !in types, "Type already registered!");
        types.insert(type_info.type, RegisteredType(type_info, path));
    }

    void register_enum(E)()
        if (is_enum!E)
    {
        static assert(is(E == Unqual!E), "Enum type must not be qualified!");

        import urt.meta.enuminfo : enum_info;
        enum_templates.insert(StringLit!(E.stringof), enum_info!E.make_void());
    }

    void register_intrinsic(String identifier, IntrinsicFunction func)
    {
        assert(identifier[] !in intrinsic_functions, "Intrinsic function already registered!");
        intrinsic_functions.insert(identifier.move, func);
    }

    void update()
    {
        foreach (m; modules)
            m.pre_update();

        foreach (m; modules)
            m.update();

        import urt.async : asyncUpdate;
        asyncUpdate();

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
                session.writef("{'', *5}  {0}{@4, ?3}: {2}\n", e.id, e.name, e.value, e.name.length > 0, " ({1})", indent);
            foreach (c2; c.components)
                printComponent(c2, indent + 2);
        }

        const(char)[] newLine = "";
        foreach (dev; devices.values)
        {
            session.write_line(newLine, dev.id, ": ", dev.name);
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

        session.write_line("Flags: R - RUNNING; S - SLAVE");
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
                rxLen = max(rxLen, iface.getStatus.rx_bytes.format_int(null));
                txLen = max(txLen, iface.getStatus.tx_bytes.format_int(null));
                rpLen = max(rpLen, iface.getStatus.rx_packets.format_int(null));
                tpLen = max(tpLen, iface.getStatus.tx_packets.format_int(null));
                rdLen = max(rdLen, iface.getStatus.rx_dropped.format_int(null));
                tdLen = max(tdLen, iface.getStatus.tx_dropped.format_int(null));
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
                               i, iface.getStatus.link_status ? 'R' : ' ', iface.master ? 'S' : ' ',
                               iface.name, nameLen,
                               iface.getStatus.rx_bytes, rxLen, iface.getStatus.tx_bytes, txLen,
                               iface.getStatus.rx_packets, rpLen, iface.getStatus.tx_packets, tpLen,
                               iface.getStatus.rx_dropped, rdLen, iface.getStatus.tx_dropped, tdLen);
                ++i;
            }
        }
        else
        {
            session.writef(" ID    {0, *1}  {2, *3}  MAC-ADDRESS\n", "NAME", nameLen, "TYPE", typeLen);
            size_t i = 0;
            foreach (iface; interfaces)
            {
                session.writef("{0, 3} {6}{7}  {1, *2}  {3, *4}  {5}\n", i, iface.name, nameLen, iface.type, typeLen, iface.mac, iface.getStatus.link_status ? 'R' : ' ', iface.master ? 'S' : ' ');
                ++i;
            }
        }
+/
    }

    // element link API

    ElementLink* create_link(Element* a, const(char)[] a_path, Element* b, const(char)[] b_path)
    {
        assert((a || a_path) && (b || b_path), "Must specify `a` and `b`");

        ElementLink* link = allocator.allocT!ElementLink();

        if (a)
            link.a.set_element(a);
        else
            link.a.set_path(a_path.makeString(allocator));

        if (b)
            link.b.set_element(b);
        else
            link.b.set_path(b_path.makeString(allocator));

        if (link.resolved)
            link.resolve();

        links ~= link;
        return link;
    }

    void notify_element_created(Element* e)
    {
        char[256] buf = void;
        ptrdiff_t len = e.full_path(buf);
        if (len <= 0 || len > buf.length)
            return;
        const(char)[] path = buf[0 .. len];

        foreach (link; links)
        {
            if (link.resolved)
                continue;
            if (link.a.dangling && link.a.path[] == path)
            {
                link.a.release();
                link.a.set_element(e);
            }
            if (link.b.dangling && link.b.path[] == path)
            {
                link.b.release();
                link.b.set_element(e);
            }
            if (link.resolved)
                link.resolve();
        }
    }

    void destroy_link(ElementLink* link)
    {
        link.unlink();
        links.removeFirstSwapLast(link);
        allocator.freeT(link);
    }

    // /element/link commands

    void link_add(Session session, const(char)[] source, const(char)[] target)
    {
        Element* a = resolve_global_element(source);
        Element* b = resolve_global_element(target);
        create_link(a, source, b, target);
    }

    void link_print(Session session)
    {
        char[256] buf_a = void, buf_b = void;
        foreach (link; links)
        {
            const(char)[] a, b;
            if (link.a.dangling)
                a = link.a.path[];
            else
            {
                ptrdiff_t len = link.a.elem.full_path(buf_a);
                a = buf_a[0 .. len];
            }
            if (link.b.dangling)
                b = link.b.path[];
            else
            {
                ptrdiff_t len = link.b.elem.full_path(buf_b);
                b = buf_b[0 .. len];
            }
            const(char)[] status = link.resolved ? "linked" : "pending";
            session.write_line(a, " <-> ", b, "  [", status, "]");
        }
    }

}

Element* resolve_global_element(const(char)[] path) nothrow @nogc
{
    const(char)[] rest = path;
    const(char)[] device_id = rest.split!'.';
    if (rest.empty)
        return null;
    if (Device* d = device_id in g_app.devices)
        return (*d).find_element(rest);
    return null;
}



private:

enum Boolean : ubyte
{
    true_ = 0,
    false_ = 1
}

Variant select(Variant[] args)
{
    if (args.length != 3)
        return Variant();
    bool b;
    if (args[0].isBool)
        b = args[0].asBool;
    else if (args[0].isNumber && !args[0].isQuantity)
        b = args[0].asDouble() != 0;
    else if (args[0].isString())
    {
        const(char)[] str = args[0].asString();
        switch (str)
        {
            case "true":
            case "yes":
                b = true;
                break;
            case "false":
            case "no":
                b = false;
                break;
            default:
                import urt.conv : parse_float;
                size_t taken;
                double f = str.parse_float(&taken);
                if (taken != str.length)
                    return Variant();
                b = f ? true : false;
                break;
        }
    }
    else
        return Variant();
    return b ? args[1] : args[2];
}

Variant pow(Variant[] args)
{
    import urt.math : pow;
    if (args.length != 2 || !args[0].isNumber || !args[1].isNumber)
        return Variant();
    return Variant(pow(args[0].asDouble(), args[1].asDouble()));
}
