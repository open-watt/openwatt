module manager.device;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection : CID, CollectionType, make_cid;
import manager.component;
import manager.element;
import manager.expression;
import manager.id : EID, IdMachine, IndexTable;
import manager.profile;

nothrow @nogc:


alias CreateElementHandler = void delegate(Device device, Element* e, ref const ElementDesc desc, ubyte index) nothrow @nogc;

// The device type's table in the container id space: devices register as a type WITHOUT
// becoming BaseObjects (no state machine; passive containers materialized by bindings).
// Map-flavoured surface so lookup sites read naturally; slots are the device CIDs-to-be
// (CollectionType.device carries the type bits).
struct DeviceTable
{
nothrow @nogc:

    Device* opBinaryRight(string op : "in")(const(char)[] name)
        => _machine.lookup(name);

    void insert(const(char)[] name, Device device)
    {
        uint slot = _machine.claim(name, device);
        debug assert(slot, "device name already in use");
        device.cid = make_cid(CollectionType.device, slot);
    }

    // index 0 is the device itself: that resolves through the container level, not here
    inout(Element)* resolve(EID eid) inout pure
    {
        if (eid.container.type_index != CollectionType.device)
            return null;
        inout Device d = _machine.get(eid.container.slot);
        return d ? d.element_ids.get(eid.index) : null;
    }

    auto values() => _machine.values();
    auto keys() => _machine.names();

    size_t length()
    {
        size_t n = 0;
        foreach (d; _machine.values())
            ++n;
        return n;
    }

package:
    IdMachine!Device _machine;
}

// the element-level deref surface: follows forwards at both levels and heals the held EID
Element* deref(ref EID eid)
{
    if (!g_app || eid.container.type_index != CollectionType.device)
        return null;
    uint slot = eid.container.slot;
    Device d = g_app.devices._machine.deref(slot);
    if (!d)
        return null;
    ushort index = eid.index;
    Element* e = d.element_ids.deref(index);
    if (e && (slot != eid.container.slot || index != eid.index))
        eid = EID(make_cid(CollectionType.device, slot), index);
    return e;
}

enum ComputationKind : ubyte
{
    expression,
    accumulator,
    alias_
}

struct Computation
{
nothrow @nogc:

    Device device;
    Element* target;
    ComputationKind kind;
    bool bound;

    union
    {
        Expression* expression;
        struct { Element* source; SumType sum_type; }
        ElementLink* link;
    }

    void element_updated(ref const SampleCommit samples)
    {
        final switch (kind) with (ComputationKind)
        {
            case expression:
                SysTime timestamp;
                foreach (ref update; samples.updates)
                    if (update.timestamp > timestamp)
                        timestamp = update.timestamp;
                evaluate_expression(timestamp);
                break;

            case accumulator:
                foreach (ref update; samples.updates)
                {
                    if (update.element !is source)
                        continue;
                    Variant previous = update.previous;
                    SysTime previous_timestamp = update.previous_timestamp;
                    foreach (i; 0 .. update.count)
                    {
                        Variant value = update.box(i);
                        SysTime timestamp = update.time(i);
                        accumulate(value, timestamp, previous, previous_timestamp);
                        previous = value.move;
                        previous_timestamp = timestamp;
                    }
                }
                break;

            case alias_:
                // ElementLink manages its own subscribers
                break;
        }
    }

    void evaluate_expression(SysTime timestamp)
    {
        EvalContext ctx;
        ctx.root = device;
        Variant result = expression.evaluate(ctx);
        target.value(result.move, timestamp, &element_updated);
    }

    void accumulate(ref const Variant new_value, SysTime timestamp,
                    ref const Variant previous_value, SysTime previous_timestamp)
    {
        import urt.si.quantity;
        import urt.si.unit;

        if (!new_value.isNumber)
            return;
        VarQuantity sample = new_value.asQuantity;

        if (sum_type != SumType.sum)
        {
            enum Seconds = ScaledUnit(Second);
            Duration t = timestamp - previous_timestamp;
            ulong ns = t.as!"nsecs";
            if (ns == 0)
                return;
            auto dt = VarQuantity(ns / 1_000_000_000.0, Seconds);

            if (sum_type == SumType.right)
                sample = sample * dt;
            else
            {
                if (!previous_value.isNumber)
                    return;
                VarQuantity previous = previous_value.asQuantity;

                if (sum_type == SumType.negative_trapezoid)
                    sample = -sample, previous = -previous;

                auto zero = VarQuantity(0, sample.unit);

                if (sum_type == SumType.trapezoid || (sample >= zero && previous >= zero))
                    sample = (previous + sample) * (dt * 0.5);
                else if (sample < zero && previous < zero)
                    sample = VarQuantity(0, sample.unit * Seconds);
                else if (previous > zero)
                    sample = previous * (previous / (previous - sample)) * (dt * 0.5);
                else
                    sample = sample * (sample / (sample - previous)) * (dt * 0.5);
            }
        }

        Variant value = target.value;
        if (!value.isNumber)
            target.value(Variant(sample), timestamp, &element_updated);
        else
            target.value(Variant(value.asQuantity + sample), timestamp, &element_updated);
    }
}


extern(C++)
class Device : Component
{
extern(D):
nothrow @nogc:

    this(String id)
    {
        super(id.move);
    }

    override bool is_device() const pure
        => true;

    ~this()
    {
        clear_computations();
    }

    CID cid;                            // unset until DeviceTable.insert stamps it
    IndexTable!(Element*) element_ids;

    Array!Computation computations;

    void clear_computations()
    {
        foreach (ref c; computations)
        {
            final switch (c.kind) with (ComputationKind)
            {
                case expression:
                    if (c.bound)
                    {
                        bool have_var_refs;
                        Array!(const(char)[]) refs = c.expression.get_element_refs(have_var_refs);
                        foreach (r; refs)
                        {
                            Element* el = resolve_ref(r);
                            if (el)
                                el.unsubscribe(&c.element_updated);
                        }
                    }
                    c.expression.free_expression();
                    break;

                case accumulator:
                    if (c.bound && c.source)
                        c.source.unsubscribe(&c.element_updated);
                    break;

                case alias_:
                    if (c.link)
                        g_app.destroy_link(c.link);
                    break;
            }
        }
        computations.clear();
    }

    Element* resolve_ref(const(char)[] r)
    {
        if (r.length > 0 && r[0] == '.')
            return g_app.find_element(r[1 .. $]);
        return find_element(r);
    }

    void update()
    {
        SysTime now = getSysTime();
        foreach (ref c; computations)
        {
            if (c.kind != ComputationKind.accumulator || !c.bound)
                continue;
            Element* src = c.source;
            // force an element update to progress accumulation
            if (now - src.last_update >= 1.seconds)
                src.force_update(now);
        }

    }

package:
    int try_bind_pending()
    {
        int newly_bound = 0;
        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.expression)
                continue;
            bool _;
            Array!(const(char)[]) refs = c.expression.get_element_refs(_);
            bool all_resolved = true;
            foreach (r; refs)
            {
                if (!resolve_ref(r))
                {
                    all_resolved = false;
                    break;
                }
            }
            if (!all_resolved)
                continue;
            foreach (r; refs)
            {
                Element* e = resolve_ref(r);
                e.subscribe(&c.element_updated);
            }
            c.evaluate_expression(getSysTime());
            c.bound = true;
            ++newly_bound;
        }

        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.accumulator)
                continue;
            const(char)[] src = as_dstring(cast(const char*)c.source);
            Element* e = resolve_ref(src);
            if (!e)
                continue;
            e.subscribe(&c.element_updated);
            c.source = e;
            c.bound = true;
            ++newly_bound;
        }

        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.alias_)
                continue;
            // ElementLink manages its own lifecycle via g_app
            c.bound = true;
            ++newly_bound;
        }

        return newly_bound;
    }

}

Device create_device_from_profile(ref Profile profile, const(char)[] model, const(char)[] id, const(char)[] name, scope CreateElementHandler create_element_handler)
{
    import urt.mem.allocator;
    import manager;

    DeviceTemplate* device_template = profile.get_model_template(model);
    if (!device_template)
    {
        writeWarning("No device template for model '", model, "'");
        return null;
    }

    ModelMask model_bit;
    if (model)
    {
        foreach (i; 0 .. device_template.num_models)
        {
            if (device_template.get_model(i, profile).wildcard_match_i(model))
            {
                model_bit = cast(ModelMask)(1 << i);
                break;
            }
        }
    }
    else
        model_bit = ModelMask.max;

    Device device;
    bool is_new_device = false;
    if (Device* existing = id in g_app.devices)
        device = *existing;
    else
    {
        device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        if (name)
            device.name = name.makeString(g_app.allocator);
        is_new_device = true;
    }

    Component find_or_create_component(Component parent, ref ComponentTemplate ct)
    {
        const(char)[] comp_id = ct.get_id(profile);

        Component c;
        foreach (Component existing; parent.components)
        {
            if (existing.id[] == comp_id)
            {
                c = existing;
                break;
            }
        }
        if (c is null)
        {
            c = g_app.allocator.allocT!Component(comp_id.makeString(defaultAllocator()));
            c.template_ = ct.get_template().makeString(defaultAllocator());
            c.hidden = ct.is_hidden();
            c.parent = parent;
            parent.components ~= c;
        }

        foreach (ref child; ct.components(profile))
        {
            if ((child._model_mask & model_bit) == 0)
                continue;
            find_or_create_component(c, child);
        }

        foreach (ref el; ct.elements(profile))
        {
            if ((el._model_mask & model_bit) == 0)
                continue;

            const(char)[] el_id = el.get_id(profile);

            Element* e;
            foreach (Element* existing; c.elements)
            {
                if (existing.id[] == el_id)
                {
                    e = existing;
                    break;
                }
            }
            bool is_new_element = (e is null);
            if (is_new_element)
            {
                e = g_app.allocator.allocT!Element();
                e.parent = c;
                e.id = el_id.makeString(defaultAllocator());
                e.name = el.get_name(profile).makeString(defaultAllocator());
                e.desc = el.get_desc(profile).makeString(defaultAllocator());
                e.display_unit = el.display_units;
                e.sampling_mode = el.update_frequency.freq_to_element_mode;
                e.access = cast(manager.element.Access)el.access;

                if (!e.name || !e.desc || !e.display_unit)
                {
                    if (const KnownElementTemplate* et = find_known_element(c.template_[], e.id[]))
                    {
                        if (!e.display_unit)
                            e.display_unit = et.units.makeString(defaultAllocator());
                        if (!e.name)
                            e.name = et.name.makeString(defaultAllocator());
                        if (!e.desc)
                            e.desc = et.desc.makeString(defaultAllocator());
                    }
                }
                c.elements ~= e;
            }

            final switch (el.type) with (ElementTemplate.Type)
            {
                case expression:
                    if (!is_new_element)
                        break;
                    Expression* expr;
                    const(char)[] expr_str = el.get_expression(profile);
                    try
                        expr = parse_expression(expr_str);
                    catch (Exception ex)
                    {
                        writeWarning("Failed to parse expression: ", expr_str);
                        c.elements.removeFirstSwapLast(e);
                        g_app.allocator.freeT(e);
                        break;
                    }

                    bool have_var_refs;
                    Array!(const(char)[]) refs = expr.get_element_refs(have_var_refs);
                    if (have_var_refs)
                    {
                        writeWarning("Element expressions can't have variable references: ", expr_str);
                        c.elements.removeFirstSwapLast(e);
                        g_app.allocator.freeT(e);
                        break;
                    }

                    if (refs.empty)
                    {
                        EvalContext ctx;
                        e.value = expr.evaluate(ctx);
                        e.sampling_mode = SamplingMode.constant;
                        expr.free_expression();
                    }
                    else
                    {
                        Computation comp;
                        comp.kind = ComputationKind.expression;
                        comp.device = device;
                        comp.target = e;
                        comp.expression = expr;
                        device.computations ~= comp;
                        e.sampling_mode = SamplingMode.dependent;
                    }
                    break;

                case map:
                    if (!is_new_element)
                        break;
                    create_element_handler(device, e, el.get_element_desc(profile), el.index);
                    break;

                case sum:
                    if (!is_new_element)
                        break;
                    Computation comp;
                    comp.kind = ComputationKind.accumulator;
                    comp.device = device;
                    comp.target = e;
                    comp.source = cast(Element*)el.get_source(profile);  // path string until try_bind_pending resolves
                    comp.sum_type = cast(SumType)el.index;
                    device.computations ~= comp;
                    e.sampling_mode = SamplingMode.dependent;
                    break;

                case alias_:
                    if (!is_new_element)
                        break;
                    import urt.mem.temp : tconcat;
                    const(char)[] target_path = as_dstring(el.get_source(profile));
                    Element* target = device.resolve_ref(target_path);
                    const(char)[] link_path = (target_path.length > 0 && target_path[0] == '.') ? target_path[1 .. $] : tconcat(device.id, ".", target_path);
                    Computation comp;
                    comp.kind = ComputationKind.alias_;
                    comp.device = device;
                    comp.target = e;
                    comp.link = g_app.create_link(e, null, target, link_path);
                    device.computations ~= comp;
                    e.sampling_mode = SamplingMode.dependent;
                    break;
            }
        }

        return c;
    }

    foreach (ref ct; device_template.components(profile))
    {
        if ((ct._model_mask & model_bit) == 0)
            continue;
        find_or_create_component(device, ct);
    }

    if (is_new_device)
        g_app.devices.insert(device.id[], device);

    apply_default_retention(device);

    g_app.request_rebind();

    device.notify(ComponentEvent.tree_changed);
    device.notify(ComponentEvent.online);

    return device;
}

// recording intent default: every element with a typed series that isn't a constant or config
// value gets history; profiles will grow explicit record/retention overrides (grammar TODO)
void apply_default_retention(Component c)
{
    import urt.time : seconds;

    enum default_min_records = 256;      // rendering floor even when older than the window
    enum default_max_records = 16_384;   // RAM ceiling; laps stalled consumers
    enum default_window = 3600.seconds;

    foreach (Element* e; c.elements)
    {
        if (!e.has_typed_series || e.has_history)
            continue;
        if (e.sampling_mode == SamplingMode.constant || e.sampling_mode == SamplingMode.config)
            continue;
        e.retention(default_min_records, default_max_records);
        e.retention(default_window);
    }
    foreach (Component child; c.components)
        apply_default_retention(child);
}

unittest
{
    import urt.mem : defaultAllocator;
    import urt.string : makeString;
    import urt.time : from_unix_time_ns;

    Device d = defaultAllocator.allocT!Device("testdev".makeString(defaultAllocator()));
    Component c = defaultAllocator.allocT!Component("child".makeString(defaultAllocator()));
    c.parent = d;
    assert(!c.is_device);
    Component as_comp = d;
    assert(as_comp.is_device);

    // element indices allocate lazily against the device's table once it registers
    DeviceTable table;
    table.insert(d.id[], d);
    assert(d.cid);

    Element* e = defaultAllocator.allocT!Element();
    e.parent = c;
    assert(!e.eid);
    EID handle = e.ensure_eid();
    assert(handle && handle.container == d.cid && handle.index == 1);
    assert(e.ensure_eid() == handle);
    assert(table.resolve(handle) is e);
    assert(table.resolve(EID(d.cid, 2)) is null);

    // unmounted elements have no identity to allocate
    Element* stray = defaultAllocator.allocT!Element();
    assert(stray.ensure_eid() == EID.invalid);

    // deref follows element-level forwards and heals the held EID
    Element* e2 = defaultAllocator.allocT!Element();
    e2.parent = c;
    EID handle2 = e2.ensure_eid();
    assert(handle2.index == 2);
    d.element_ids.release(1);
    d.element_ids.forward(1, 2);
    ushort idx = handle.index;          // a stale holder still at index 1
    assert(d.element_ids.deref(idx) is e2 && idx == 2);

    // A committed batch reaches an accumulator as every sample, not only the tip.
    static immutable DataFormat f64_sampled = DataFormat(ValueType.f64, SeriesKind.sampled);
    Element source;
    Element target;
    source.format = register_format(f64_sampled);
    Computation sum;
    sum.kind = ComputationKind.accumulator;
    sum.source = &source;
    sum.target = &target;
    sum.sum_type = SumType.sum;
    source.subscribe(&sum.element_updated);
    double[3] values = [1.0, 2.0, 3.0];
    SysTime[3] times = [from_unix_time_ns(100), from_unix_time_ns(200),
                        from_unix_time_ns(300)];
    source.write_samples(values[], times[]);
    assert(target.value.asDouble == 6.0);
    source.unsubscribe(&sum.element_updated);
    source.teardown();
}
