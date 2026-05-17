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

import manager.binding;
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

    version (AllocTracking)
    {
        import urt.log : writeDebug;
        import urt.mem.tracking : alloc_print_live;
        writeDebug("Allocation tracker: leak dump after application teardown");
        alloc_print_live((const(char)[] line) { writeDebug(line); });
    }
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

        console.set_prompt(StringLit!"> ");

        console.register_command!log_level("/system", this);
        console.register_command!set_hostname("/system", this);
        console.register_command!get_hostname("/system", this, "hostname");
        console.register_command!set_update_rate("/system", this, "update-rate");
        console.register_command!uptime("/system", this);
        console.register_command!sysinfo("/system", this);
        console.register_command!show_time("/system", this, "time");
        console.register_command!sleep("/system", this);
        console.register_command!reboot("/system", this);

        version (AllocTracking)
        {
            console.register_command!alloc_stats_cmd("/system/alloc", this, "stats");
            console.register_command!alloc_mark_cmd("/system/alloc", this, "mark");
            console.register_command!alloc_leaks_cmd("/system/alloc", this, "leaks");
        }

        console.register_command!device_add("/device", this, "add");
        console.register_command!device_print("/device", this, "print");
        console.register_command!link_add("/element/link", this, "add");
        console.register_command!link_print("/element/link", this, "print");

        console.register_collection!Secret();

        register_modules(this);

        foreach (m; modules)
            m.pre_init();

        foreach (m; modules)
            m.init();

        foreach (m; modules)
            m.post_init();

        console.freeze();
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
        import urt.log : writeWarning;

        enum SlowTickThresholdMs = 100;

        MonoTime tick_start = getTime();
        Duration worst_module_dur;
        const(char)[] worst_module_name;
        const(char)[] worst_module_phase;

        foreach (m; modules)
        {
            MonoTime t = getTime();
            m.pre_update();
            Duration d = getTime() - t;
            if (d > worst_module_dur)
            {
                worst_module_dur = d;
                worst_module_name = m.module_name[];
                worst_module_phase = "pre_update";
            }
        }

        foreach (m; modules)
        {
            MonoTime t = getTime();
            m.update();
            Duration d = getTime() - t;
            if (d > worst_module_dur)
            {
                worst_module_dur = d;
                worst_module_name = m.module_name[];
                worst_module_phase = "update";
            }
        }

        import urt.async : asyncUpdate;
        MonoTime async_t = getTime();
        asyncUpdate();
        Duration async_d = getTime() - async_t;
        if (async_d > worst_module_dur)
        {
            worst_module_dur = async_d;
            worst_module_name = "(async)";
            worst_module_phase = "asyncUpdate";
        }

        MonoTime devices_t = getTime();
        foreach (device; devices.values)
            device.update();
        Duration devices_d = getTime() - devices_t;
        if (devices_d > worst_module_dur)
        {
            worst_module_dur = devices_d;
            worst_module_name = "(devices)";
            worst_module_phase = "device.update";
        }

        MonoTime bindings_t = getTime();
        Collection!ProtocolBinding().update_all();
        Duration bindings_d = getTime() - bindings_t;
        if (bindings_d > worst_module_dur)
        {
            worst_module_dur = bindings_d;
            worst_module_name = "(bindings)";
            worst_module_phase = "binding.update";
        }

        foreach (m; modules)
        {
            MonoTime t = getTime();
            m.post_update();
            Duration d = getTime() - t;
            if (d > worst_module_dur)
            {
                worst_module_dur = d;
                worst_module_name = m.module_name[];
                worst_module_phase = "post_update";
            }
        }

        Duration total = getTime() - tick_start;
        if (total.as!"msecs" >= SlowTickThresholdMs)
        {
            writeWarning("slow-tick: ", total.as!"msecs", "ms (worst: ", worst_module_name,
                         ".", worst_module_phase, " = ", worst_module_dur.as!"msecs", "ms)");
        }
    }


    import urt.meta.nullable;

    void device_add(Session session, const(char)[] id, const(char)[] _profile, Nullable!(const(char)[]) name, Nullable!(const(char)[]) model)
    {
        import urt.mem.temp : tconcat;
        import manager.profile : Profile, ElementDesc, load_profile;
        import manager.device : create_device_from_profile;
        import manager.element : Element;

        if (id in devices)
        {
            session.write_line("Device '", id, "' already exists");
            return;
        }

        Profile* profile = load_profile(tconcat("conf/device_profiles/", _profile, ".conf"), allocator);
        if (!profile)
        {
            session.write_line("Failed to load profile '", _profile, "'");
            return;
        }

        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null,
            (Device, Element* e, ref const ElementDesc desc, ubyte) {
                session.write_line("Element '", e.id, "' is protocol-coupled (", desc.type, "); not allowed in a naked device profile");
            });
        if (!device)
            session.write_line("Failed to create device '", id, "'");
    }


    // /device/print command
    @TabComplete(&device_print_suggest)
    CommandState device_print(Session session, Nullable!(const(char)[]) filter, const(Variant)[] args)
    {
        const(char)[] pattern = filter ? filter.value : null;
        bool watch;
        bool expand_all;
        foreach (a; args)
        {
            auto s = a.asString();
            if (s == "-w" || s == "--watch")
                watch = true;
            else if (s == "-e" || s == "--expand")
                expand_all = true;
        }

        if (watch)
        {
            auto view = allocator.allocT!DeviceTreeView(session, this, pattern);
            view.default_expand = expand_all;
            return view;
        }

        build_device_table(pattern).render(session);
        return null;
    }

    Table build_device_table(const(char)[] pattern)
    {
        import urt.mem.temp : tconcat;

        enum t_branch = "├─ ";
        enum t_last   = "└─ ";
        enum t_pipe   = "│  ";
        enum t_blank  = "   ";

        Table table;
        table.add_column("name");
        table.add_column("value");
        table.add_column("age", Table.TextAlign.right);

        SysTime now = getSysTime();

        const(char)[] format_age(Duration d)
        {
            long ds = d.as!"msecs" / 100;
            if (ds < 600)
                return tconcat(ds / 10, ".", ds % 10, "s");
            long s = ds / 10;
            if (s < 3600)
                return tconcat(s / 60, "m", s % 60, "s");
            return tconcat(s / 3600, "h", (s / 60) % 60, "m");
        }

        Array!char path;
        Array!char prefix;

        bool path_matches()
            => pattern.length == 0 || wildcard_match(pattern, path[]);

        void push(const(char)[] id)
        {
            path ~= '.';
            path ~= id;
        }

        bool subtree_matches(Component c)
        {
            if (path_matches())
                return true;
            size_t reset = path.length;
            scope(exit) path.resize(reset);
            foreach (e; c.elements)
            {
                push(e.id[]);
                if (path_matches())
                    return true;
                path.resize(reset);
            }
            foreach (sc; c.components)
            {
                push(sc.id[]);
                if (subtree_matches(sc))
                    return true;
                path.resize(reset);
            }
            return false;
        }

        void emit_node(Component c, bool is_last, bool is_root)
        {
            const(char)[] branch = is_root ? "" : (is_last ? t_last : t_branch);
            const(char)[] label = c.name.length ? tconcat(c.id[], " (", c.name[], ")") : c.id[];
            table.add_row();
            table.cell(tconcat(prefix[], branch, label));
            table.cell(c.template_.length ? tconcat("[", c.template_[], "]") : "");
            table.cell("");

            size_t path_reset = path.length;
            size_t prefix_reset = prefix.length;
            scope(exit) { path.resize(path_reset); prefix.resize(prefix_reset); }

            if (!is_root)
                prefix ~= (is_last ? t_blank : t_pipe);

            size_t visible;
            foreach (e; c.elements)
            {
                push(e.id[]);
                if (path_matches())
                    ++visible;
                path.resize(path_reset);
            }
            foreach (sc; c.components)
            {
                push(sc.id[]);
                if (subtree_matches(sc))
                    ++visible;
                path.resize(path_reset);
            }

            size_t emitted;
            foreach (e; c.elements)
            {
                push(e.id[]);
                scope(exit) path.resize(path_reset);
                if (!path_matches())
                    continue;
                ++emitted;
                bool last = emitted == visible;
                table.add_row();
                table.cell(tconcat(prefix[], last ? t_last : t_branch, e.id[]));
                table.cell(e.value);
                table.cell(e.last_update && e.sampling_mode != SamplingMode.constant ? format_age(now - e.last_update) : "");
            }
            foreach (sc; c.components)
            {
                push(sc.id[]);
                scope(exit) path.resize(path_reset);
                if (!subtree_matches(sc))
                    continue;
                ++emitted;
                bool last = emitted == visible;
                emit_node(sc, last, false);
            }
        }

        foreach (dev; devices.values)
        {
            path.clear();
            prefix.clear();
            path ~= dev.id[];
            if (!subtree_matches(dev))
                continue;
            emit_node(dev, true, true);
        }
        return table;
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

        // any device's pending refs may resolve to the new element via a leading-dot global path
        foreach (device; devices.values)
            device.try_bind_pending();
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


class DeviceTreeView : TreeViewState
{
nothrow @nogc:

    this(Session session, Application app, const(char)[] pattern)
    {
        super(session, null);
        _app = app;
        if (pattern.length > 0)
        {
            _pattern = pattern.makeString(app.allocator);
            compute_auto_expand();
        }
    }

    override void configure_columns(ref Table table)
    {
        table.add_column("value");
        table.add_column("age", Table.TextAlign.right);
    }

    override bool default_expanded(const(char)[] id)
    {
        if (super.default_expanded(id))
            return true;
        if (_pattern.length == 0)
            return false;
        uint start = 0;
        foreach (end; _auto_expand_ends[])
        {
            if (_auto_expand_paths[start .. end] == id)
                return true;
            start = end;
        }
        return false;
    }

    override void walk_tree(scope TreeYield yield)
    {
        import urt.mem.temp : tconcat;

        SysTime now = getSysTime();
        Array!char path;

        const(char)[] format_age(Duration d)
        {
            long ds = d.as!"msecs" / 100;
            if (ds < 600)
                return tconcat(ds / 10, ".", ds % 10, "s");
            long s = ds / 10;
            if (s < 3600)
                return tconcat(s / 60, "m", s % 60, "s");
            return tconcat(s / 3600, "h", (s / 60) % 60, "m");
        }

        void emit_element(Element* e, uint depth, bool is_last)
        {
            TreeNodeInfo info = TreeNodeInfo(path[], e.id[], depth, is_last, false);
            yield(info, (ref Table t) {
                t.cell(e.value);
                t.cell(e.last_update && e.sampling_mode != SamplingMode.constant
                    ? format_age(now - e.last_update) : "");
            });
        }

        void emit_component(Component c, uint depth, bool is_last)
        {
            const(char)[] label = c.name.length ? tconcat(c.id[], " (", c.name[], ")") : c.id[];
            size_t total = c.elements.length + c.components.length;
            TreeNodeInfo info = TreeNodeInfo(path[], label, depth, is_last, total > 0);
            bool descend = yield(info, (ref Table t) {
                t.cell(c.template_.length ? tconcat("[", c.template_[], "]") : "");
                t.cell("");
            });

            if (!descend || total == 0)
                return;

            size_t emitted;
            size_t reset = path.length;
            foreach (e; c.elements)
            {
                ++emitted;
                path ~= '.';
                path ~= e.id[];
                emit_element(e, depth + 1, emitted == total);
                path.resize(reset);
            }
            foreach (sc; c.components)
            {
                ++emitted;
                path ~= '.';
                path ~= sc.id[];
                emit_component(sc, depth + 1, emitted == total);
                path.resize(reset);
            }
        }

        size_t total_devs = _app.devices.length;
        size_t emitted_devs;
        foreach (dev; _app.devices.values)
        {
            ++emitted_devs;
            path.clear();
            path ~= dev.id[];
            emit_component(dev, 0, emitted_devs == total_devs);
        }
    }

private:
    Application _app;
    String _pattern;
    Array!char _auto_expand_paths;
    Array!uint _auto_expand_ends;

    void compute_auto_expand()
    {
        Array!char path;

        void add_with_ancestors(const(char)[] p)
        {
            size_t end = p.length;
            while (end > 0)
            {
                const(char)[] sub = p[0 .. end];
                bool present;
                uint start = 0;
                foreach (e; _auto_expand_ends[])
                {
                    if (_auto_expand_paths[start .. e] == sub)
                    {
                        present = true;
                        break;
                    }
                    start = e;
                }
                if (!present)
                {
                    _auto_expand_paths ~= sub;
                    _auto_expand_ends ~= cast(uint)_auto_expand_paths.length;
                }
                size_t prev_dot = end;
                foreach_reverse (i, c; sub)
                {
                    if (c == '.')
                    {
                        prev_dot = i;
                        break;
                    }
                }
                if (prev_dot == end)
                    break;
                end = prev_dot;
            }
        }

        void check(const(char)[] p)
        {
            if (wildcard_match(_pattern[], p))
                add_with_ancestors(p);
        }

        void walk_paths(Component c)
        {
            check(path[]);
            foreach (e; c.elements)
            {
                size_t r = path.length;
                path ~= '.';
                path ~= e.id[];
                check(path[]);
                path.resize(r);
            }
            foreach (sc; c.components)
            {
                size_t r = path.length;
                path ~= '.';
                path ~= sc.id[];
                walk_paths(sc);
                path.resize(r);
            }
        }

        foreach (dev; _app.devices.values)
        {
            path.clear();
            path ~= dev.id[];
            walk_paths(dev);
        }
    }
}


Array!String device_print_suggest(bool is_value, const(char)[] name, const(char)[] value) nothrow @nogc
{
    Array!String result;

    if (!is_value)
    {
        static immutable flags = ["-e", "-w", "--expand", "--watch"];
        foreach (f; flags)
        {
            if (f.startsWith(name))
                result ~= f.makeString(defaultAllocator);
        }
        return result;
    }

    if (name != "filter" || g_app is null)
        return result;

    size_t last_dot = value.findLast('.');
    const(char)[] parent_path = last_dot == value.length ? null : value[0 .. last_dot];
    const(char)[] partial = last_dot == value.length ? value : value[last_dot + 1 .. $];

    Array!char buf;
    if (parent_path.length > 0)
    {
        buf ~= parent_path;
        buf ~= '.';
    }
    size_t reset = buf.length;

    void emit(const(char)[] id)
    {
        if (!id.startsWith(partial))
            return;
        buf.resize(reset);
        buf ~= id;
        result ~= buf[].makeString(defaultAllocator);
    }

    if (parent_path.length == 0)
    {
        foreach (dev; g_app.devices.values)
            emit(dev.id[]);
        return result;
    }

    Component parent = g_app.find_component(parent_path);
    if (parent is null)
        return result;
    foreach (e; parent.elements)
        emit(e.id[]);
    foreach (sc; parent.components)
        emit(sc.id[]);
    return result;
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
