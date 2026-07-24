module manager;

import urt.array;
import urt.lifetime : move;
import urt.map;
import urt.mem.allocator;
import urt.mem.string;
import urt.mem.temp : tconcat;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.result : StringResult;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.sync.mpsc;
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
import manager.reactor;
import manager.profile : Profile, load_profile;
import manager.secret;
import manager.signal;
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

alias TimerHandler      = void delegate(MonoTime scheduled) nothrow @nogc;
alias EventHandler      = void delegate(MonoTime when) nothrow @nogc;
alias WallclockHandler  = void delegate(Duration delta) nothrow @nogc;
alias HeartbeatHandler  = void delegate(MonoTime now) nothrow @nogc;

enum EventPriority : ubyte
{
    control,
    bulk,
}

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
    foreach (m; g_app.modules)
        m.deinit();

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


// Handle for an `element:` signal subscription owned by the Application.
private class ElementSignalSub : SignalSub
{
nothrow @nogc:
    SignalSink sink;
    String path;
    Element* element;

    override ISignalProvider provider()
        => g_app;

    void on_change(ref Element e, ref const Variant val, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp)
    {
        SignalEvent ev = { source: path[] };
        ev.value = val;   // owned snapshot at change-time, so $value can't race a later live re-read
        sink(getTime(), ev);
    }
}

class Application : ISignalProvider
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
    Map!(String, ISignalProvider) signal_providers;

    DeviceTable devices;

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

        bool reactor_ok = _wake_event.init();
        _priority_events.init();
        _bulk_events.init();

        import urt.time : subscribe_clock_change;
        subscribe_clock_change(&notify_wallclock_change);

        register_enum!Boolean();
        register_bitfield!ObjectFlags();
        register_enum!HashFunction();

        register_signal_provider(StringLit!"element", this);

        register_intrinsic(StringLit!"select", &select);
        import urt.math : pow, sqrt, sin, cos, tan, asin, acos, atan, atan2;
        register_intrinsic(StringLit!"math.pow", &intrin_shim_2!pow);
        register_intrinsic(StringLit!"math.sqrt", &intrin_shim_1!sqrt);
        register_intrinsic(StringLit!"math.sin", &intrin_shim_1!sin);
        register_intrinsic(StringLit!"math.cos", &intrin_shim_1!cos);
        register_intrinsic(StringLit!"math.tan", &intrin_shim_1!tan);
        register_intrinsic(StringLit!"math.asin", &intrin_shim_1!asin);
        register_intrinsic(StringLit!"math.acos", &intrin_shim_1!acos);
        register_intrinsic(StringLit!"math.atan", &intrin_shim_1!atan);
        register_intrinsic(StringLit!"math.atan2", &intrin_shim_2!atan2);
        register_intrinsic(StringLit!"energy.apparent", &apparent);
        register_intrinsic(StringLit!"energy.reactive", &reactive);

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
        console.register_command!element_set("/element", this, "set");
        console.register_command!link_add("/element/link", this, "add");
        console.register_command!link_print("/element/link", this, "print");

        console.register_collection!Secret();
        console.register_collection!ProtocolBinding();

        register_modules(this);

        foreach (m; modules)
            m.pre_init();

        foreach (m; modules)
            m.init();

        foreach (m; modules)
            m.post_init();

        console.freeze();

        if (!reactor_ok)
        {
            import urt.log : writeError;
            import urt.system : abort;
            writeError("reactor initialisation failed");
            abort();
        }

        MonoTime now = getTime();
        schedule(now, &tick);
        schedule(now + 1.seconds, &heartbeat);
    }

    ~this()
    {
        import urt.time : unsubscribe_clock_change;
        unsubscribe_clock_change(&notify_wallclock_change);
        _wake_event.destroy();
        g_app = null;
    }

    void set_update_rate(Session, Quantity!(uint, Hertz) rate)
    {
        uint hz = rate.value;
        update_rate_hz = hz < 1 ? 1 : (hz > 1000 ? 1000 : hz);
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

    // Collect every element whose full data-model path matches `pattern`.
    // '*'/'?' wildcards match anywhere in the dotted path ('*' spans segment
    // boundaries): "device.*.element", "dev*.*.voltage*", "*", etc.
    //
    // TODO: consolidate the HTTP API's element wildcard here. apps.api's
    // collect_with_wildcard / collect_elements_from_component use *segment*
    // semantics ('*' matches exactly one path segment, recursing) rather than
    // the whole-path glob below. Unifying on this would be a behaviour change
    // for existing API clients, so it needs a deliberate decision first.
    Array!(Element*) find_elements(const(char)[] pattern, bool case_insensitive = false)
    {
        Array!(Element*) result;
        find_elements(pattern, result, case_insensitive);
        return result;
    }

    void find_elements(const(char)[] pattern, ref Array!(Element*) result, bool case_insensitive = false)
    {
        import urt.string : wildcard_match;

        bool wild = pattern.findFirst('*') != pattern.length || pattern.findFirst('?') != pattern.length;
        if (!wild)
        {
            if (Element* e = find_element(pattern))
                result ~= e;
            return;
        }

        MutableString!0 path;
        void walk(Component c)
        {
            size_t reset = path.length;
            scope(exit) path.erase(reset, path.length - reset);
            if (reset)
                path ~= '.';
            path ~= c.id[];

            foreach (Element* e; c.elements)
            {
                size_t e_reset = path.length;
                scope(exit) path.erase(e_reset, path.length - e_reset);
                path.append('.', e.id[]);
                if (wildcard_match(pattern, path[], false, case_insensitive))
                    result ~= e;
            }

            foreach (Component child; c.components)
                walk(child);
        }

        foreach (device; devices.values)
            walk(device);
    }

    void register_type(const(CollectionTypeInfo)* type_info, const(char)[] path)
    {
        assert(type_info.type !in types, "Type already registered!");
        types.insert(type_info.type, RegisteredType(type_info, path));
    }

    void register_heartbeat_handler(HeartbeatHandler handler)
    {
        _heartbeat_handlers ~= handler;
    }

    void register_enum(E)()
        if (is_enum!E)
    {
        static assert(is(E == Unqual!E), "Enum type must not be qualified!");

        import urt.meta.enuminfo : enum_info;
        enum_templates.insert(StringLit!(E.stringof), enum_info!E.make_void());
    }

    void register_bitfield(E)()
        if (is_enum!E)
    {
        import urt.meta.enuminfo : is_bitfield_enum;
        static assert(is_bitfield_enum!E, E.stringof ~ " must be declared @bitfield");
        register_enum!E();
    }

    void register_intrinsic(String identifier, IntrinsicFunction func)
    {
        assert(identifier[] !in intrinsic_functions, "Intrinsic function already registered!");
        intrinsic_functions.insert(identifier.move, func);
    }

    void register_signal_provider(String scheme, ISignalProvider provider)
    {
        assert(scheme[] !in signal_providers, "Signal provider already registered!");
        signal_providers.insert(scheme.move, provider);
    }

    ISignalProvider find_signal_provider(const(char)[] scheme)
    {
        if (ISignalProvider* p = scheme in signal_providers)
            return *p;
        return null;
    }

    // The Application is the built-in `element:` signal provider (the `@` sentinel maps to it).
    StringResult validate(ref const SignalUri uri) const
    {
        if (uri.body.length == 0)
            return StringResult("element signal needs an element path");
        return StringResult.success;   // whether the element exists yet is a subscribe-time concern
    }

    StringResult subscribe(ref const SignalUri uri, SignalSink sink, out SignalSub handle)
    {
        if (uri.body.length == 0)
            return StringResult("element signal needs an element path");

        Element* e = find_element(uri.body);
        if (!e)
            return StringResult(tconcat("element not found: ", uri.body));

        ElementSignalSub s = allocator.allocT!ElementSignalSub();
        s.sink = sink;
        s.path = uri.body.makeString(allocator);
        s.element = e;
        e.add_subscriber(&s.on_change);
        handle = s;
        return StringResult.success;
    }

    void unsubscribe(SignalSub handle)
    {
        ElementSignalSub s = cast(ElementSignalSub)handle;
        if (s.element)
            s.element.remove_subscriber(&s.on_change);
        allocator.freeT(s);
    }

    SysTime next_run(SignalSub handle) const
        => SysTime();

    // MAIN THREAD ONLY; off-thread/ISR callers post a message to schedule a new event
    void schedule(MonoTime when, TimerHandler handler)
    {
        _timer_when ~= when;
        _timer_handler ~= handler;
    }

    uint cancel(TimerHandler handler, uint count = 1)
    {
        uint removed = 0;
        foreach (i, h; _timer_handler)
        {
            if (h is handler)
            {
                _timer_remove(i);
                if (++removed == count)
                    return removed;
            }
        }
        return removed;
    }

    MonoTime process_due()
    {
        MonoTime now = getTime();
    again:
        size_t next = size_t.max;
        MonoTime next_when = MonoTime(ulong.max);
        foreach (i, w; _timer_when)
        {
            if (w < next_when)
            {
                next = i;
                next_when = w;
            }
        }
        if (next == size_t.max)
            return MonoTime(ulong.max);
        if (next_when <= now)
        {
            MonoTime scheduled = next_when;
            TimerHandler handler = _timer_handler[next];
            _timer_remove(next);
            handler(scheduled);
            goto again;
        }
        return next_when;
    }

    void subscribe_wallclock_change(WallclockHandler h)
    {
        _wallclock_handlers ~= h;
    }

    void unsubscribe_wallclock_change(WallclockHandler h)
    {
        foreach (i, hh; _wallclock_handlers)
        {
            if (hh is h)
            {
                _wallclock_handlers.removeSwapLast(i);
                return;
            }
        }
    }

    void notify_wallclock_change(long delta_ns)
    {
        Duration delta = delta_ns.nsecs;
        foreach (h; _wallclock_handlers)
            h(delta);
    }

    bool post_event(EventHandler handler, MonoTime when, EventPriority priority = EventPriority.control)
    {
        import urt.atomic : atomicFetchAdd, atomicFetchSub, MemoryOrder;
        import urt.log : writeError, writeWarning;

        bool ok;
        final switch (priority)
        {
            case EventPriority.control:
                atomicFetchAdd!(MemoryOrder.relaxed)(_priority_events_posted, 1);
                ok = _priority_events.enqueue(PendingEvent(handler, when));
                if (!ok)
                {
                    atomicFetchSub!(MemoryOrder.relaxed)(_priority_events_posted, 1);
                    atomicFetchAdd!(MemoryOrder.relaxed)(_priority_event_overflows, 1);
                    writeError("priority event queue overflow handler=", cast(size_t)handler.funcptr, " ctx=", cast(size_t)handler.ptr);
                }
                break;
            case EventPriority.bulk:
                atomicFetchAdd!(MemoryOrder.relaxed)(_bulk_events_posted, 1);
                ok = _bulk_events.enqueue(PendingEvent(handler, when));
                if (!ok)
                {
                    atomicFetchSub!(MemoryOrder.relaxed)(_bulk_events_posted, 1);
                    atomicFetchAdd!(MemoryOrder.relaxed)(_bulk_event_overflows, 1);
                    writeWarning("bulk event queue overflow handler=", cast(size_t)handler.funcptr, " ctx=", cast(size_t)handler.ptr);
                }
                break;
        }
        if (!ok)
            return false;
        _wake_event.set();
        return true;
    }

    void wait_for_wake(MonoTime deadline)
    {
        MonoTime now = getTime();
        if (deadline <= now)
        {
            _wake_event.wait(Duration.zero);    // no sleep, but still dispatch any ready I/O
            return;
        }
        _wake_event.wait(deadline - now);

        // count the system idle time to get a sense of load
        import urt.system : count_system_load;
        count_system_load(now);
    }

    static if (has_reactor_io)
    {
        // register a byte source with the main loop's I/O wait; delivery happens on the main
        // thread from inside wait_for_wake. the owner closes the file AFTER unwatch_io.
        bool watch_io(OsFile file, IoDataHandler on_data, IoErrorHandler on_error)
            => _wake_event.watch_io(file, on_data, on_error);

        void unwatch_io(OsFile file)
        {
            _wake_event.unwatch_io(file);
        }

        // the layer under watch_io: IoOp parking and watch_fd readiness
        ref Reactor reactor()
            => _wake_event;
    }

    void process_events()
    {
        import urt.atomic : atomicFetchAdd, MemoryOrder;
        import urt.log : writeWarning;

        enum Duration bulk_slice = msecs(500);
        enum SlowEventHandlerMs = 50;
        enum SlowEventFlushMs = 200;

        _wake_event.reset();
        MonoTime flush_start = getTime();
        Duration worst_event_dur;
        Duration worst_event_age;
        const(char)[] worst_event_queue = "none";
        size_t worst_event_func;
        size_t worst_event_ctx;
        uint priority_count, bulk_count, passes, slices;
        PendingEvent e;
        for (;;)
        {
            ++passes;
            bool any_priority = false;
            while (_priority_events.dequeue(e))
            {
                atomicFetchAdd!(MemoryOrder.relaxed)(_priority_events_processed, 1);
                MonoTime event_start = getTime();
                e.handler(e.when);
                Duration d = getTime() - event_start;
                Duration age = event_start - e.when;
                if (d > worst_event_dur)
                {
                    worst_event_dur = d;
                    worst_event_age = age;
                    worst_event_queue = "priority";
                    worst_event_func = cast(size_t)e.handler.funcptr;
                    worst_event_ctx = cast(size_t)e.handler.ptr;
                }
                if (d.as!"msecs" >= SlowEventHandlerMs)
                    writeWarning("slow-priority-event: ", d.as!"msecs", "ms age=", age.as!"msecs", "ms handler=", cast(size_t)e.handler.funcptr, " ctx=", cast(size_t)e.handler.ptr);
                ++priority_count;
                any_priority = true;
            }

            MonoTime slice_end = getTime() + bulk_slice;
            bool any_bulk = false;
            while (_bulk_events.dequeue(e))
            {
                atomicFetchAdd!(MemoryOrder.relaxed)(_bulk_events_processed, 1);
                MonoTime event_start = getTime();
                e.handler(e.when);
                Duration d = getTime() - event_start;
                Duration age = event_start - e.when;
                if (d > worst_event_dur)
                {
                    worst_event_dur = d;
                    worst_event_age = age;
                    worst_event_queue = "bulk";
                    worst_event_func = cast(size_t)e.handler.funcptr;
                    worst_event_ctx = cast(size_t)e.handler.ptr;
                }
                if (d.as!"msecs" >= SlowEventHandlerMs)
                    writeWarning("slow-bulk-event: ", d.as!"msecs", "ms age=", age.as!"msecs", "ms handler=", cast(size_t)e.handler.funcptr, " ctx=", cast(size_t)e.handler.ptr);
                ++bulk_count;
                any_bulk = true;
                if (getTime() >= slice_end)
                {
                    ++slices;
                    log_event_flush(flush_start, worst_event_dur, worst_event_age, worst_event_queue, worst_event_func, worst_event_ctx, priority_count, bulk_count, passes, slices, true);
                    _wake_event.set();   // re-arm; let main loop fire timers,
                    return;              // then drop back in priority-first.
                }
            }

            if (!any_priority && !any_bulk)
                break;
        }
        if ((getTime() - flush_start).as!"msecs" >= SlowEventFlushMs)
            log_event_flush(flush_start, worst_event_dur, worst_event_age, worst_event_queue, worst_event_func, worst_event_ctx, priority_count, bulk_count, passes, slices, false);
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


    // Shared profile registry: one parse per file, shared by every consumer.
    // Restarting objects release on shutdown and re-acquire on startup, binding
    // to the live parse with no file reload.
    Profile* acquire_profile(const(char)[] filename)
    {
        if (ProfileCacheEntry* e = filename in _profiles)
        {
            ++e.refs;
            return e.profile;
        }
        Profile* p = load_profile(filename, allocator);
        if (!p)
            return null;
        _profiles.insert(filename.makeString(allocator), ProfileCacheEntry(p, 1));
        return p;
    }

    void release_profile(Profile* profile)
    {
        if (profile is null)
            return;
        foreach (ref e; _profiles.values)
        {
            if (e.profile is profile)
            {
                if (e.refs != 0)
                    --e.refs;
                return;
            }
        }
    }

    import urt.meta.nullable;

    void device_add(Session session, const(char)[] id, const(char)[] _profile, Nullable!(const(char)[]) name, Nullable!(const(char)[]) model)
    {
        import urt.mem.temp : tconcat;
        import manager.profile : ElementDesc;
        import manager.device : create_device_from_profile;
        import manager.element : Element;

        if (id in devices)
        {
            session.write_line("Device '", id, "' already exists");
            return;
        }

        // acquired for the device's lifetime; never released
        Profile* profile = acquire_profile(tconcat("conf/device_profiles/", _profile, ".conf"));
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

    void element_set(Session session, const(char)[] element, Variant value)
    {
        Element* e = find_element(element);
        if (!e)
        {
            session.write_line("Element not found: ", element);
            return;
        }
        e.value(value.move);
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
        request_rebind();
    }

    // MAIN THREAD ONLY; coalesces creation bursts into one deferred rebind flush
    void request_rebind()
    {
        if (_rebind_scheduled)
            return;
        _rebind_scheduled = true;
        if (!post_event(&_flush_rebind, getTime(), EventPriority.bulk))
            _rebind_scheduled = false; // queue overflow; the next creation re-arms
    }

    private void _flush_rebind(MonoTime)
    {
        _rebind_scheduled = false;
        foreach (device; devices.values)
            device.try_bind_pending();
    }

    private bool _rebind_scheduled;

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


private:

    struct PendingEvent
    {
        EventHandler handler;
        MonoTime     when;
    }

    // Zero-ref profiles are retained: element descs, samplers, and expressions
    // on surviving devices borrow the profile's string caches, so freeing needs
    // device-side ownership first. TODO: free when the last borrower dies.
    struct ProfileCacheEntry
    {
        Profile* profile;
        uint refs;
    }

    Map!(String, ProfileCacheEntry) _profiles;

    Array!WallclockHandler _wallclock_handlers;

    Array!MonoTime _timer_when;
    Array!TimerHandler _timer_handler;

    Reactor _wake_event;

    MpscQueue!(PendingEvent, 32)  _priority_events;
    MpscQueue!(PendingEvent, 256) _bulk_events;
    shared uint _priority_events_posted;
    shared uint _bulk_events_posted;
    shared uint _priority_events_processed;
    shared uint _bulk_events_processed;
    shared uint _priority_event_overflows;
    shared uint _bulk_event_overflows;

    void log_event_flush(MonoTime flush_start, Duration worst_event_dur, Duration worst_event_age,
                         const(char)[] worst_event_queue, size_t worst_event_func,
                         size_t worst_event_ctx, uint priority_count, uint bulk_count,
                         uint passes, uint slices, bool sliced)
    {
        import urt.atomic : atomicLoad, MemoryOrder;
        import urt.log : writeWarning;

        uint priority_posted = atomicLoad!(MemoryOrder.relaxed)(_priority_events_posted);
        uint bulk_posted = atomicLoad!(MemoryOrder.relaxed)(_bulk_events_posted);
        uint priority_processed = atomicLoad!(MemoryOrder.relaxed)(_priority_events_processed);
        uint bulk_processed = atomicLoad!(MemoryOrder.relaxed)(_bulk_events_processed);
        Duration total = getTime() - flush_start;
        writeWarning("event-flush: ", total.as!"msecs", "ms priority=", priority_count,
                     " bulk=", bulk_count, " passes=", passes, " slices=", slices,
                     sliced ? " sliced" : " drained",
                     " queued(priority=", priority_posted - priority_processed,
                     " bulk=", bulk_posted - bulk_processed, ")",
                     " overflows(priority=", atomicLoad!(MemoryOrder.relaxed)(_priority_event_overflows),
                     " bulk=", atomicLoad!(MemoryOrder.relaxed)(_bulk_event_overflows), ")",
                     " worst=", worst_event_queue, ":", worst_event_dur.as!"msecs",
                     "ms age=", worst_event_age.as!"msecs", "ms handler=", worst_event_func,
                     " ctx=", worst_event_ctx);
    }

    void _timer_remove(size_t i)
    {
        _timer_when.removeSwapLast(i);
        _timer_handler.removeSwapLast(i);
    }

    // legacy 20Hz update poll; slated for removal once its remaining supports migrate off it
    void tick(MonoTime scheduled)
    {
        update();

        MonoTime next = scheduled + msecs(1000 / update_rate_hz);
        MonoTime now = getTime();
        if (next <= now)
            next = now + msecs(1000 / update_rate_hz);
        schedule(next, &tick);
    }

    void heartbeat(MonoTime scheduled)
    {
        MonoTime now = getTime();
        foreach (handler; _heartbeat_handlers)
            handler(now);

        version (Embedded)
        {
            import urt.log : writeInfo;
            import urt.system : get_cpu_load;
            writeInfo("hb=", ++_heartbeats, " load=", get_cpu_load(), "%");
        }

        MonoTime next = scheduled + 1.seconds;
        now = getTime();
        if (next <= now) // stalled: skip missed beats but hold the 1s grid
            next += ((now - next).as!"seconds" + 1).seconds;
        schedule(next, &heartbeat);
    }

    Array!HeartbeatHandler _heartbeat_handlers;
    version (Embedded)
        uint _heartbeats;
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

Variant intrin_shim_1(alias fn)(Variant[] args)
{
    if (args.length != 1 || !args[0].isNumber)
        return Variant();
    return Variant(fn(args[0].asDouble()));
}

Variant intrin_shim_2(alias fn)(Variant[] args)
{
    if (args.length != 2 || !args[0].isNumber || !args[1].isNumber)
        return Variant();
    return Variant(fn(args[0].asDouble(), args[1].asDouble()));
}

Variant apparent(Variant[] args)
    => reactive_shift(args, true);

Variant reactive(Variant[] args)
    => reactive_shift(args, false);

Variant reactive_shift(Variant[] args, bool add)
{
    import urt.math : sqrt;
    if (args.length != 2 || !args[0].isNumber || !args[1].isNumber)
        return Variant();
    VarQuantity a = args[0].asQuantity();
    VarQuantity b = args[1].asQuantity();
    Unit unit = a.unit.unit;
    if (!a.isCompatible(b) || (unit.pack != 0 && unit != Watt))
        return Variant();
    double an = a.normalise().value, bn = b.normalise().value;
    an *= an; bn *= bn;
    double r = sqrt(add ? an + bn : an - bn);
    return Variant(VarQuantity(r, ScaledUnit(unit)));
}
