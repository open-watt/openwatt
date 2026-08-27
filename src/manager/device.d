module manager.device;

import urt.algorithm;
import urt.array;
import urt.hash;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection : CID, CollectionType, CollectionTypeInfo, DynTypeInfo, make_cid;
import manager.component;
import manager.element;
import manager.expression;
import manager.id : EID, IdAllocator, IndexTable;
import manager.profile;

nothrow @nogc:


alias CreateElementHandler = FormatId delegate(Device device, Element* e, ref const ElementDesc desc, ubyte index) nothrow @nogc;

// null create: devices are not BaseObjects; their table is g_app.devices, not g_item_tables
__gshared const CollectionTypeInfo device_type_info = CollectionTypeInfo(DynTypeInfo(StringLit!"device", null), StringLit!"/device", CollectionType.device, null, null, true, false);

struct DeviceTable
{
nothrow @nogc:

    Device* opBinaryRight(string op : "in")(const(char)[] name)
        => _machine.lookup(name);

    Device find(const(char)[] name, ulong peer_id) pure
    {
        if (!peer_id)
            return _machine.get(_machine.find(name));
        ulong hash = identity_hash(name, peer_id);
        for (size_t index = binary_search!(compare_local_device, true)(_local_devices[], hash); index < _local_devices.length && _local_devices[index].hash == hash; ++index)
        {
            Device device = _local_devices[index].device;
            if (device.peer_id == peer_id && device.id[] == name)
                return device;
        }
        return null;
    }

    void insert(Device device)
    {
        debug assert(device);
        const(char)[] name = device.id[];
        debug assert(device.peer_id || !device.private_);
        debug assert(find(name, device.peer_id) is null, "device identity already in use");

        uint slot;
        if (device.peer_id)
        {
            slot = _machine.claim_unindexed(name, device);
            ulong hash = identity_hash(name, device.peer_id);
            size_t index = binary_search!(compare_local_device, true)(_local_devices[], hash);
            _local_devices.insert(index, LocalDevice(hash, device));
        }
        else
            slot = _machine.claim(name, device);
        debug assert(slot, "device identity already in use");
        device.cid = make_cid(CollectionType.device, slot);
    }

    inout(Element)* resolve(EID eid) inout pure
    {
        if (eid.container.type_index != CollectionType.device)
            return null;
        inout Device d = _machine.get(eid.container.slot);
        return d ? d.element_ids.get(eid.index) : null;
    }

    inout(Device) container(CID cid) inout pure
    {
        if (cid.type_index != CollectionType.device)
            return null;
        return _machine.get(cid.slot);
    }

    auto values() => _machine.values();
    auto keys() => _machine.names();

    size_t length()
    {
        size_t n = 0;
        foreach (device; _machine.values())
            ++n;
        return n;
    }

package:
    IdAllocator!Device _machine;

private:
    struct LocalDevice
    {
        ulong hash;
        Device device;
    }

    static ulong identity_hash(const(char)[] name, ulong peer_id) pure
        => fnv1a64(cast(const(ubyte)[])name, peer_id);

    static int compare_local_device(ref LocalDevice device, ulong hash) pure
        => device.hash < hash ? -1 : device.hash > hash ? 1 : 0;

    Array!LocalDevice _local_devices;
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
        struct { ElementLink* link; const(char)* alias_source; }
    }

    void element_updated(ref const SampleUpdate update)
    {
        if (update.event != SeriesEvent.none)
            return; // TODO: gap events should reset accumulator integration

        final switch (kind) with (ComputationKind)
        {
            case expression:
                evaluate_expression(update.timestamp);
                break;

            case accumulator:
                if (update.element !is source)
                    break;
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

    FormatId infer_expression_format()
    {
        EvalContext ctx;
        ctx.root = device;
        return expression.infer_format(ctx);
    }

    FormatId infer_accumulator_format(Element* element)
    {
        const(DataFormat)* source_format = element.data_format;
        if (source_format.type.value_class == ValueClass.exact ||
            source_format.desc == DataFormat.Desc.enum_)
            return FormatId.invalid;

        ScaledUnit unit = source_format.desc == DataFormat.Desc.quantity
            ? source_format.unit : ScaledUnit();
        if (sum_type != SumType.sum)
        {
            import urt.si.unit : Second;
            unit = unit * ScaledUnit(Second);
        }
        return register_format(DataFormat(ValueType.f64, SeriesKind.held, unit));
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

    this(String id, ulong peer_id = 0, bool private_ = false)
    {
        assert(peer_id || !private_);
        super(id.move);
        _peer_id = peer_id;
        _private = private_;
    }

    override bool is_device() const pure
        => true;

    ulong peer_id() const pure
        => _peer_id;

    bool global() const pure
        => _peer_id == 0;

    bool local() const pure
        => _peer_id != 0;

    bool private_() const pure
        => _private;

    ~this()
    {
        clear_computations();
    }

    CID cid;                            // unset until DeviceTable.insert stamps it
    bool remote;                        // materialized from a sync peer; never announced back
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
            if (!c.bound && c.target)
                free(c.target);
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
            FormatId format = c.infer_expression_format();
            if (!format.valid)
                continue;
            attach_computation(c.target, format);
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
            FormatId format = c.infer_accumulator_format(e);
            if (!format.valid)
                continue;
            attach_computation(c.target, format);
            e.subscribe(&c.element_updated);
            c.source = e;
            c.bound = true;
            ++newly_bound;
        }

        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.alias_)
                continue;
            const(char)[] src = as_dstring(c.alias_source);
            Element* source = resolve_ref(src);
            if (!source)
                continue;
            attach_computation(c.target, source.format);
            c.link = g_app.create_link(c.target, null, source, null, true);
            c.bound = true;
            ++newly_bound;
        }

        return newly_bound;
    }

    void attach_computation(Element* element, FormatId format)
    {
        assert(element && format.valid && element.parent);
        element.format = format;
        element.parent.elements ~= element;
        g_app.notify_element_created(element);
        apply_default_retention(element.parent);
    }

private:
    ulong _peer_id;
    bool _private;
}

Device create_device_from_profile(ref Profile profile, const(char)[] model, const(char)[] id, const(char)[] name, scope CreateElementHandler create_element_handler, ulong peer_id = 0, bool private_ = false)
{
    import urt.mem;
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
    if (Device existing = g_app.devices.find(id, peer_id))
    {
        device = existing;
        assert(device.private_ == private_, "device visibility conflict");
        if (!device.name && name)
            device.name = name.make_string();
    }
    else
    {
        device = alloc!Device(id.make_string(), peer_id, private_);
        if (name)
            device.name = name.make_string();
        g_app.devices.insert(device);
    }

    bool has_computation(Element* target, ComputationKind kind)
    {
        foreach (ref computation; device.computations)
            if (computation.target is target && computation.kind == kind)
                return true;
        return false;
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
            c = alloc!Component(comp_id.make_string());
            c.template_ = ct.get_template(profile).make_string();
            c.hidden = ct.is_hidden();
            c.parent = parent;
            parent.components ~= c;
        }
        else
        {
            if (!c.template_)
                c.template_ = ct.get_template(profile).make_string();
            if (ct.is_hidden())
                c.hidden = true;
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
                e = alloc!Element();
                e.parent = c;
                e.id = el_id.make_string();
                e.name = el.get_name(profile).make_string();
                e.desc = el.get_desc(profile).make_string();
                e.display_unit = el.get_display_units(profile).make_string();
                e.access = cast(manager.element.Access)el.access;
            }
            else
            {
                e.access = cast(manager.element.Access)(e.access | cast(manager.element.Access)el.access);
                if (!e.name)
                    e.name = el.get_name(profile).make_string();
                if (!e.desc)
                    e.desc = el.get_desc(profile).make_string();
                if (!e.display_unit)
                    e.display_unit = el.get_display_units(profile).make_string();
            }
            e.sampling_mode = el.update_frequency.freq_to_element_mode;
            if (!e.name || !e.desc || !e.display_unit)
            {
                if (const KnownElementTemplate* et = find_known_element(c.template_[], e.id[]))
                {
                    if (!e.display_unit)
                        e.display_unit = et.units.make_string();
                    if (!e.name)
                        e.name = et.name.make_string();
                    if (!e.desc)
                        e.desc = et.desc.make_string();
                }
            }

            final switch (el.type) with (ElementTemplate.Type)
            {
                case expression:
                    if (has_computation(e, ComputationKind.expression))
                        break;
                    const(char)[] expr_str = el.get_expression(profile);
                    Expression* expr = parse_expression(expr_str);
                    if (!expr)
                    {
                        writeWarning("Failed to parse expression: ", expr_str);
                        if (is_new_element)
                            free(e);
                        continue;
                    }

                    bool have_var_refs;
                    Array!(const(char)[]) refs = expr.get_element_refs(have_var_refs);
                    if (have_var_refs)
                    {
                        writeWarning("Element expressions can't have variable references: ", expr_str);
                        expr.free_expression();
                        if (is_new_element)
                            free(e);
                        continue;
                    }

                    if (refs.empty)
                    {
                        EvalContext ctx;
                        Variant value = expr.evaluate(ctx);
                        FormatId expression_format = expr.infer_format(ctx);
                        if (!expression_format.valid || value.isNull)
                        {
                            writeWarning("Element expression has no stable format: ", expr_str);
                            expr.free_expression();
                            if (is_new_element)
                                free(e);
                            continue;
                        }
                        if (is_new_element)
                            e.format = expression_format;
                        else
                            assert(e.format == expression_format || value_compatible(*format_info(expression_format), *e.data_format), "element path reused with an incompatible format");
                        if (e.record_update() == SysTime())
                            e.value = value.move;
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
                    FormatId mapped_format;
                    foreach (ai; profile.element_aliases(el.element_index))
                    {
                        ref const(ElementDesc) alias_desc = profile.element_desc(ai);
                        e.access = cast(manager.element.Access)(
                            e.access | cast(manager.element.Access)alias_desc.access);
                        const(char)[] alias_units = alias_desc.get_display_units(profile);
                        if (is_new_element && !(el.explicit & ElementTemplate.Explicit.units) && alias_units.length)
                            e.display_unit = alias_units.make_string();
                        if (!(el.explicit & ElementTemplate.Explicit.frequency))
                            e.sampling_mode = alias_desc.update_frequency.freq_to_element_mode;
                        mapped_format = create_element_handler(device, e, alias_desc, el.index);
                        if (mapped_format.valid)
                            break;
                    }
                    if (mapped_format.valid)
                    {
                        if (is_new_element)
                            e.format = mapped_format;
                        else
                            assert(e.format == mapped_format || value_compatible(*format_info(mapped_format), *e.data_format), "element path reused with an incompatible format");
                    }
                    else if (is_new_element)
                    {
                        free(e);
                        continue;
                    }
                    break;

                case sum:
                    if (has_computation(e, ComputationKind.accumulator))
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
                    if (has_computation(e, ComputationKind.alias_))
                        break;
                    Computation comp;
                    comp.kind = ComputationKind.alias_;
                    comp.device = device;
                    comp.target = e;
                    comp.alias_source = el.get_source(profile);
                    device.computations ~= comp;
                    e.sampling_mode = SamplingMode.dependent;
                    break;
            }

            if (is_new_element && e.format.valid)
            {
                c.elements ~= e;
                g_app.notify_element_created(e);
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

    apply_default_retention(device);

    g_app.request_rebind();

    device.notify(ComponentEvent.tree_changed);
    device.notify(ComponentEvent.online);

    return device;
}

// recording intent default: every element that isn't a constant or config value gets history;
// profiles will grow explicit record/retention overrides (grammar TODO)
void apply_default_retention(Component c)
{
    import urt.time : seconds;

    enum default_min_records = 256;      // rendering floor even when older than the window
    enum default_max_records = 16_384;   // RAM ceiling; laps stalled consumers
    enum default_window = 3600.seconds;

    foreach (Element* e; c.elements)
    {
        assert(e.format.valid, "attached element has no data format");
        if (e.has_history)
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
    import urt.mem;
    import urt.string : make_string;
    import urt.time : from_unix_time_ns;

    Device d = alloc!Device(StringLit!"testdev");
    Component c = alloc!Component(StringLit!"child");
    c.parent = d;
    d.components ~= c;
    assert(!c.is_device);
    Component as_comp = d;
    assert(as_comp.is_device);

    // element identity: indices allocate lazily against the device's table once it registers
    DeviceTable table;
    table.insert(d);
    assert(d.cid);

    Device local_device = alloc!Device(StringLit!"testdev", 0xA1);
    Device private_device = alloc!Device(StringLit!"testdev", 0xB2, true);
    table.insert(local_device);
    table.insert(private_device);
    assert(table.length == 3);
    assert(*("testdev" in table) is d);
    assert(table.find("testdev", 0xA1) is local_device);
    assert(table.find("testdev", 0xB2) is private_device);
    assert(table.find("testdev", 0xC3) is null);
    assert(d.global && !d.local && !d.private_);
    assert(!local_device.global && local_device.local && !local_device.private_);
    assert(private_device.local && private_device.private_);
    assert(d.cid != local_device.cid && local_device.cid != private_device.cid);

    Component local_component = alloc!Component(StringLit!"child");
    local_component.parent = local_device;
    Element* local_element = alloc!Element();
    local_element.parent = local_component;
    EID local_handle = local_element.ensure_eid();
    assert(local_handle.container == local_device.cid);

    Element* e = alloc!Element();
    e.parent = c;
    assert(!e.eid);
    EID handle = e.ensure_eid();
    assert(handle && handle.container == d.cid && handle.index == 1);
    assert(e.ensure_eid() == handle);
    assert(table.resolve(handle) is e);
    assert(table.resolve(EID(d.cid, 2)) is null);

    // unmounted elements have no identity to allocate
    Element* stray = alloc!Element();
    assert(stray.ensure_eid() == EID.invalid);

    // deref follows element-level forwards and heals the held EID
    Element* e2 = alloc!Element();
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
    target.format = source.format;
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
