module manager;

import urt.array;
import urt.conv : parse_float;
import urt.lifetime : move;
import urt.log : writeWarning;
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

version (Windows)
{
    import urt.internal.sys.windows;
    import urt.internal.sys.windows.winbase;
    import urt.internal.sys.windows.winnt;
    import urt.string.uni : uni_convert;
}
else version (Posix)
{
    import urt.internal.sys.posix : stat, stat_t;
}

import manager.binding;
import manager.collection;
import manager.component;
import manager.console;
import manager.device;
import manager.element;
import manager.id;
import manager.plugin;
import manager.profile : Profile, load_profile;
import manager.reactor;
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
        a.elem.subscribe(&element_updated);
        b.elem.subscribe(&element_updated);
        if (a.elem.last_update > b.elem.last_update)
        {
            Variant value = a.elem.value;
            b.elem.value(value, a.elem.last_update);
        }
        else if (b.elem.last_update > a.elem.last_update)
        {
            Variant value = b.elem.value;
            a.elem.value(value, b.elem.last_update);
        }
    }

    void unlink()
    {
        if (resolved)
        {
            a.elem.unsubscribe(&element_updated);
            b.elem.unsubscribe(&element_updated);
        }
        a.release();
        b.release();
    }

    void element_updated(ref const SampleUpdate update)
    {
        if (propagating || !update.value_ready)
            return;
        propagating = true;
        Element* dest;
        if (update.element is a.elem)
            dest = b.elem;
        else if (update.element is b.elem)
            dest = a.elem;
        if (dest)
            dest.value(update.value, update.timestamp, &element_updated);
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

    void on_change(ref const SampleUpdate update)
    {
        if (update.element !is element || !update.value_ready)
            return;
        SignalEvent ev = { source: path[] };
        ev.value = update.value;
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

    ref const(String) profile_path() const pure
        => _profile_path;

    Array!(ElementLink*) links;

    Map!(String, RegisteredType) types;

    // database...

    this()
    {
        import urt.mem;

        allocator = defaultAllocator;
        temp_allocator = temp_allocator;

        assert(!g_app, "Application already created!");
        g_app = this;

        _wake_event.init();
        _priority_events.init();
        _bulk_events.init();

        import urt.time : subscribe_clock_change;
        subscribe_clock_change(&notify_wallclock_change);

        register_enum!Boolean();
        register_bitfield!ObjectFlags();
        register_enum!HashFunction();

        register_signal_provider(StringLit!"element", this);

        register_intrinsic(StringLit!"select", &select);
        register_intrinsic(StringLit!"to_int", &to_int);
        register_intrinsic(StringLit!"to_float", &to_float);
        register_intrinsic(StringLit!"to_bool", &to_bool);
        register_intrinsic(StringLit!"to_string", &to_string);
        register_intrinsic(StringLit!"is_number", &is_number);
        register_intrinsic(StringLit!"abs", &intrinsic_abs);
        register_intrinsic(StringLit!"round", &intrinsic_round);
        register_intrinsic(StringLit!"min", &intrinsic_min);
        register_intrinsic(StringLit!"max", &intrinsic_max);
        register_intrinsic(StringLit!"is_null", &intrinsic_is_null);
        register_intrinsic(StringLit!"truthy", &intrinsic_truthy);
        register_intrinsic(StringLit!"lower", &intrinsic_lower);
        register_intrinsic(StringLit!"upper", &intrinsic_upper);
        register_intrinsic(StringLit!"trim", &intrinsic_trim);
        register_intrinsic(StringLit!"length", &intrinsic_length);
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
        console.register_command!set_profile_path("/system", this, "profile-path");
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

        import manager.sample.codec : register_builtin_encodings;
        register_builtin_encodings();

        register_modules(this);

        foreach (m; modules)
            m.pre_init();

        foreach (m; modules)
            m.init();

        foreach (m; modules)
            m.post_init();

        console.freeze();

        MonoTime now = getTime();
        schedule(now, &tick);
        schedule(now + 1.seconds, &heartbeat);
    }

    ~this()
    {
        import manager.sample.codec : clear_encoding_registry;
        import urt.time : unsubscribe_clock_change;
        unsubscribe_clock_change(&notify_wallclock_change);
        _wake_event.destroy();
        clear_encoding_registry();
        g_app = null;
    }

    void set_update_rate(Session, Quantity!(uint, Hertz) rate)
    {
        update_rate_hz = rate.value;
    }

    void set_profile_path(Session session, const(char)[] path)
    {
        if (_profile_path_overridden)
        {
            session.write_line("Profile path remains '", _profile_path, "' (command-line override)");
            return;
        }
        if (!apply_profile_path(path))
            session.write_line("Profile path must be set before profiles are loaded and cannot be empty");
    }

    bool override_profile_path(const(char)[] path)
    {
        if (!apply_profile_path(path))
            return false;
        _profile_path_overridden = true;
        return true;
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
        import manager.sample : register_enum_info;
        register_enum_info(StringLit!(E.stringof)[], enum_info!E.make_void(), false);
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
        e.subscribe(&s.on_change);
        handle = s;
        return StringResult.success;
    }

    void unsubscribe(SignalSub handle)
    {
        ElementSignalSub s = cast(ElementSignalSub)handle;
        if (s.element)
            s.element.unsubscribe(&s.on_change);
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
        bool watch_io(OsFile file, IoDataHandler on_data, IoErrorHandler on_error, bool eof_on_zero = false)
            => _wake_event.watch_io(file, on_data, on_error, eof_on_zero);

        void unwatch_io(OsFile file)
        {
            _wake_event.unwatch_io(file);
        }

        // direct access for subsystems using the layer under watch_io (IoOp / watch_fd)
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


    // Shared profile registry: one parse per name, shared by every consumer.
    // Restarting objects release on shutdown and re-acquire on startup, binding
    // to the live parse with no file reload.
    Profile* acquire_profile(const(char)[] name)
    {
        const(char)[] basename = profile_basename(name);
        if (!basename)
        {
            writeWarning("Invalid profile name '", name, "': expected a basename");
            return null;
        }
        if (ProfileCacheEntry* e = basename in _profiles)
        {
            ++e.refs;
            return e.profile;
        }

        String filename = resolve_profile_path(_profile_path[], basename, allocator);
        if (filename.empty)
            return null;
        Profile* p = load_profile(filename[], allocator);
        if (!p)
            return null;
        _profiles.insert(basename.makeString(allocator), ProfileCacheEntry(p, 1));
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
        import manager.profile : ElementDesc;
        import manager.device : create_device_from_profile;
        import manager.element : Element;

        if (id in devices)
        {
            session.write_line("Device '", id, "' already exists");
            return;
        }

        // acquired for the device's lifetime; never released
        Profile* profile = acquire_profile(_profile);
        if (!profile)
        {
            session.write_line("Failed to load profile '", _profile, "'");
            return;
        }

        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null,
            (Device, Element* e, ref const ElementDesc desc, ubyte) {
                session.write_line("Element '", e.id, "' is protocol-coupled (", desc.kind, "); not allowed in a naked device profile");
                return FormatId.invalid;
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

    // Zero-ref profiles are retained: element descs and expressions
    // on surviving devices borrow the profile's string caches, so freeing needs
    // device-side ownership first. TODO: free when the last borrower dies.
    struct ProfileCacheEntry
    {
        Profile* profile;
        uint refs;
    }

    Map!(String, ProfileCacheEntry) _profiles;
    String _profile_path = StringLit!"conf/profiles";
    bool _profile_path_overridden;

    bool apply_profile_path(const(char)[] path)
    {
        if (path.length == 0 || !_profiles.empty)
            return false;
        _profile_path = path.makeString(allocator);
        return true;
    }

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

        schedule(getTime() + msecs(1000 / update_rate_hz), &tick);
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

enum MaxProfilePath = 1024;

struct ProfileSearch
{
nothrow @nogc:
    const(char)[] target;
    NoGCAllocator allocator;
    String first;
    String second;
    bool incomplete;
    bool overflow;

    void found(const(char)[] path)
    {
        if (first.empty)
            first = path.makeString(allocator);
        else if (second.empty)
            second = path.makeString(allocator);
    }
}

const(char)[] profile_basename(const(char)[] name) pure
{
    if (name.length >= 5 && name[$ - 5 .. $] == ".conf")
        name = name[0 .. $ - 5];
    if (name.length == 0)
        return null;
    foreach (c; name)
    {
        if (c == '/' || c == '\\' || c == '\0')
            return null;
    }
    return name;
}

String resolve_profile_path(const(char)[] root, const(char)[] basename, NoGCAllocator allocator)
{
    if (root.length == 0 || root.length >= MaxProfilePath)
    {
        writeWarning("Invalid profile path '", root, "'");
        return String(null);
    }

    ProfileSearch search;
    search.target = tconcat(basename, ".conf");
    search.allocator = allocator;

    char[MaxProfilePath] path = void;
    path[0 .. root.length] = root[];
    path[root.length] = '\0';
    if (!walk_profile_directory(search, path, root.length))
        search.incomplete = true;

    if (search.overflow)
    {
        writeWarning("Profile catalogue contains a path longer than ", MaxProfilePath - 1, " bytes");
        return String(null);
    }
    if (search.incomplete)
    {
        writeWarning("Profile catalogue '", root, "' could not be searched completely");
        return String(null);
    }
    if (!search.second.empty)
    {
        writeWarning("Profile name '", basename, "' is ambiguous: ", search.first, " and ", search.second);
        return String(null);
    }
    if (search.first.empty)
    {
        writeWarning("Profile '", basename, "' was not found beneath '", root, "'");
        return String(null);
    }
    return search.first;
}

bool append_profile_path(ref char[MaxProfilePath] path, ref size_t length, const(char)[] name)
{
    size_t new_length = length + 1 + name.length;
    if (new_length >= path.length)
        return false;
    path[length] = '/';
    path[length + 1 .. new_length] = name[];
    path[new_length] = '\0';
    length = new_length;
    return true;
}

version (Windows)
{
    bool walk_profile_directory(ref ProfileSearch search, ref char[MaxProfilePath] path, size_t length)
    {
        char[MaxProfilePath] pattern = void;
        if (length + 2 >= pattern.length)
        {
            search.overflow = true;
            return false;
        }
        pattern[0 .. length] = path[0 .. length];
        pattern[length .. length + 3] = "/*\0";

        WIN32_FIND_DATAW data;
        HANDLE handle = FindFirstFileW(pattern[0 .. length + 2].twstringz, &data);
        if (handle == INVALID_HANDLE_VALUE)
            return false;
        scope(exit) FindClose(handle);

        bool more = true;
        while (more && search.second.empty)
        {
            char[MaxProfilePath] name_buffer = void;
            size_t wide_length;
            while (wide_length < data.cFileName.length && data.cFileName[wide_length] != 0)
                ++wide_length;
            size_t name_length = data.cFileName[0 .. wide_length].uni_convert(name_buffer[]);
            if (name_length != 0)
            {
                const(char)[] name = name_buffer[0 .. name_length];
                if (name != "." && name != ".." && name != ".git")
                {
                    bool reparse = (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                    if (!reparse)
                    {
                        size_t child_length = length;
                        if (!append_profile_path(path, child_length, name))
                            search.overflow = true;
                        else if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                        {
                            if (!walk_profile_directory(search, path, child_length))
                                search.incomplete = true;
                        }
                        else if (name == search.target)
                            search.found(path[0 .. child_length]);
                        path[length] = '\0';
                    }
                }
            }
            more = FindNextFileW(handle, &data) != 0;
        }
        return true;
    }
}
else version (Posix)
{
    bool walk_profile_directory(ref ProfileSearch search, ref char[MaxProfilePath] path, size_t length)
    {
        DIR* dir = opendir(path.ptr);
        if (dir is null)
            return false;
        scope(exit) closedir(dir);

        while (search.second.empty)
        {
            dirent* entry = readdir(dir);
            if (entry is null)
                break;
            size_t name_length;
            while (name_length < entry.d_name.length && entry.d_name[name_length] != 0)
                ++name_length;
            if (name_length == 0)
                continue;
            const(char)[] name = entry.d_name[0 .. name_length];
            if (name == "." || name == ".." || name == ".git" || entry.d_type == DT_LNK)
                continue;

            size_t child_length = length;
            if (!append_profile_path(path, child_length, name))
            {
                search.overflow = true;
                continue;
            }

            bool is_directory = entry.d_type == DT_DIR;
            bool is_file = entry.d_type == DT_REG;
            if (entry.d_type == DT_UNKNOWN)
            {
                stat_t info;
                if (stat(path.ptr, &info) != 0)
                    search.incomplete = true;
                else
                {
                    is_directory = (info.st_mode & S_IFMT) == S_IFDIR;
                    is_file = (info.st_mode & S_IFMT) == S_IFREG;
                }
            }

            if (is_directory)
            {
                if (!walk_profile_directory(search, path, child_length))
                    search.incomplete = true;
            }
            else if (is_file && name == search.target)
                search.found(path[0 .. child_length]);
            path[length] = '\0';
        }
        return true;
    }

    extern(C) nothrow @nogc
    {
        struct DIR;
        struct dirent
        {
            ulong d_ino;
            long d_off;
            ushort d_reclen;
            ubyte d_type;
            char[256] d_name;
        }

        DIR* opendir(const(char)* name);
        int closedir(DIR* dir);
        dirent* readdir(DIR* dir);
    }

    enum DT_UNKNOWN = 0;
    enum DT_DIR = 4;
    enum DT_REG = 8;
    enum DT_LNK = 10;
    enum S_IFMT = 0xF000;
    enum S_IFDIR = 0x4000;
    enum S_IFREG = 0x8000;
}
else
{
    bool walk_profile_directory(ref ProfileSearch, ref char[MaxProfilePath], size_t)
    {
        return false;
    }
}

enum Boolean : ubyte
{
    true_ = 0,
    false_ = 1
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

Variant to_int(Variant[] args)
{
    if (args.length < 1 || args.length > 2)
        return Variant();
    if (args[0].isBool)
        return Variant(cast(ubyte)args[0].asBool);
    if (args[0].isNumber)
    {
        // quantities yield their value in their own scale; the unit is the caller's context
        if (args[0].isQuantity)
            return Variant(cast(long)args[0].asQuantity!double().value);
        return Variant(cast(long)args[0].asDouble);
    }
    if (args[0].isString)
    {
        const(char)[] text = args[0].asString.trim();
        size_t taken;
        double value = text.parse_float(&taken);
        if (!text.empty && taken == text.length)
            return Variant(cast(long)value);
    }
    return args.length == 2 ? args[1] : Variant();
}

Variant to_float(Variant[] args)
{
    if (args.length < 1 || args.length > 2)
        return Variant();
    if (args[0].isBool)
        return Variant(args[0].asBool ? 1.0 : 0.0);
    if (args[0].isNumber)
    {
        if (args[0].isQuantity)
            return Variant(args[0].asQuantity!double().value);
        if (args[0].isDouble)
            return args[0];
        return Variant(args[0].asDouble);
    }
    if (args[0].isString)
    {
        const(char)[] text = args[0].asString.trim();
        size_t taken;
        double value = text.parse_float(&taken);
        if (!text.empty && taken == text.length)
            return Variant(value);
    }
    return args.length == 2 ? args[1] : Variant();
}

Variant to_bool(Variant[] args)
{
    if (args.length < 1 || args.length > 2)
        return Variant();
    if (args[0].isBool)
        return args[0];
    if (args[0].isNumber && !args[0].isQuantity)
    {
        double value = args[0].asDouble;
        if (value == 0 || value == 1)
            return Variant(value != 0);
    }
    else if (args[0].isString)
    {
        import urt.string.ascii : cmp;
        const(char)[] text = args[0].asString.trim();
        if (!cmp!true(text, "true") || !cmp!true(text, "yes") ||
            !cmp!true(text, "on") || !cmp!true(text, "enable") || text == "1")
            return Variant(true);
        if (!cmp!true(text, "false") || !cmp!true(text, "no") ||
            !cmp!true(text, "off") || !cmp!true(text, "disable") || text == "0")
            return Variant(false);
    }
    return args.length == 2 ? args[1] : Variant();
}

Variant to_string(Variant[] args)
{
    if (args.length != 1)
        return Variant();
    if (args[0].isString)
        return args[0];
    MutableString!0 text;
    text.format("{0}", args[0]);
    return Variant(String(text.move));
}

Variant is_number(Variant[] args)
{
    if (args.length != 1)
        return Variant(false);
    if (args[0].isNumber)
    {
        double value = args[0].asDouble;
        return Variant(value == value && value != double.infinity && value != -double.infinity);
    }
    if (!args[0].isString)
        return Variant(false);
    const(char)[] text = args[0].asString.trim();
    size_t taken;
    double value = text.parse_float(&taken);
    return Variant(!text.empty && taken == text.length && value == value && value != double.infinity && value != -double.infinity);
}

Variant intrinsic_abs(Variant[] args)
{
    if (args.length != 1 || !args[0].isNumber || args[0].is_enum)
        return Variant();
    import urt.math : fabs;
    if (args[0].isUlong)
        return args[0];
    if (args[0].isLong)
    {
        const q = args[0].asQuantity!long;
        ulong value = ulong(-q.value); // handle the case of long.min
        return Variant(Quantity!ulong(value, q.unit));
    }
    VarQuantity value = args[0].asQuantity;
    value.value = fabs(value.value);
    return Variant(value);
}

Variant intrinsic_round(Variant[] args)
{
    if (args.length < 1 || args.length > 4 ||
        (args.length >= 2 && !args[1].isLong))
        return Variant();

    double value;
    if (args[0].isNumber)
        value = args[0].asDouble;
    else if (args[0].isString)
    {
        const(char)[] text = args[0].asString.trim();
        size_t taken;
        value = text.parse_float(&taken);
        if (text.empty || taken != text.length)
            return args.length == 4 ? args[3] : Variant();
    }
    else
        return args.length == 4 ? args[3] : Variant();

    int precision = args.length >= 2 ? args[1].asInt : 0;
    if (precision < -15 || precision > 15)
        return Variant();
    double scale = 1;
    foreach (_; 0 .. (precision < 0 ? -precision : precision))
        scale *= 10;
    double scaled = precision < 0 ? value / scale : value * scale;

    const(char)[] method = "common";
    if (args.length >= 3)
    {
        if (!args[2].isString)
            return Variant();
        method = args[2].asString;
    }
    if (method == "half")
        scaled *= 2;

    long truncated = cast(long)scaled;
    if (method == "common" || method == "half")
    {
        import urt.math : fabs;
        double remainder = fabs(scaled - truncated);
        if (remainder > 0.5 || (remainder == 0.5 && (truncated & 1)))
            truncated += scaled < 0 ? -1 : 1;
    }
    else if (method == "floor")
    {
        if (scaled < truncated)
            --truncated;
    }
    else if (method == "ceil")
    {
        if (scaled > truncated)
            ++truncated;
    }
    else
        return Variant();

    double result = precision < 0 ? truncated * scale : truncated / scale;
    if (method == "half")
        result /= 2;
    return Variant(result);
}

Variant intrinsic_min(Variant[] args)
    => numeric_extreme(args, false);

Variant intrinsic_max(Variant[] args)
    => numeric_extreme(args, true);

Variant numeric_extreme(Variant[] args, bool greatest)
{
    Variant[] values = args;
    if (args.length == 1 && args[0].isArray)
        values = args[0].asArray[];
    if (values.empty || !values[0].isNumber || values[0].is_enum)
        return Variant();
    size_t best;
    VarQuantity extreme = values[0].asQuantity;
    foreach (i; 1 .. values.length)
    {
        if (!values[i].isNumber || values[i].is_enum)
            return Variant();
        VarQuantity value = values[i].asQuantity;
        if (!value.isCompatible(extreme))
            return Variant();
        if ((greatest && value > extreme) || (!greatest && value < extreme))
        {
            best = i;
            extreme = value;
        }
    }
    return values[best];
}

Variant intrinsic_is_null(Variant[] args)
{
    return Variant(args.length == 1 && args[0].isNull);
}

Variant intrinsic_truthy(Variant[] args)
{
    if (args.length != 1)
        return Variant(false);
    ref Variant value = args[0];
    if (value.isBool)
        return Variant(value.asBool);
    if (value.isNumber)
        return Variant(value.asDouble != 0);
    if (value.isString || value.isArray || value.isObject || value.isBuffer)
        return Variant(value.length != 0);
    return Variant(false);
}

Variant intrinsic_lower(Variant[] args)
{
    if (args.length != 1 || !args[0].isString)
        return Variant();
    import urt.string.ascii : to_lower;
    MutableString!0 result = MutableString!0(args[0].asString);
    result[].to_lower;
    return Variant(String(result.move));
}

Variant intrinsic_upper(Variant[] args)
{
    if (args.length != 1 || !args[0].isString)
        return Variant();
    import urt.string.ascii : to_upper;
    MutableString!0 result = MutableString!0(args[0].asString);
    result[].to_upper;
    return Variant(String(result.move));
}

Variant intrinsic_trim(Variant[] args)
{
    if (args.length != 1 || !args[0].isString)
        return Variant();
    return Variant(args[0].asString.trim());
}

Variant intrinsic_length(Variant[] args)
{
    if (args.length != 1 ||
        !(args[0].isString || args[0].isArray || args[0].isObject || args[0].isBuffer))
        return Variant();
    return Variant(args[0].length);
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
