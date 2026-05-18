module manager.device;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.component;
import manager.element;
import manager.expression;
import manager.profile;

nothrow @nogc:


alias CreateElementHandler = void delegate(Device device, Element* e, ref const ElementDesc desc, ubyte index) nothrow @nogc;

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

    void element_updated(ref Element src, ref const Variant new_val, SysTime timestamp, ref const Variant prev_val, SysTime prev_timestamp)
    {
        final switch (kind) with (ComputationKind)
        {
            case expression:
                EvalContext ctx;
                ctx.root = device;
                Variant r = this.expression.evaluate(ctx);
                target.value(r.move, timestamp);
                break;

            case accumulator:
                import urt.si.quantity;
                import urt.si.unit;

                if (!new_val.isNumber)
                    return;
                VarQuantity sample = new_val.asQuantity;

                if (sum_type != SumType.sum)
                {
                    enum Seconds = ScaledUnit(Second);
                    Duration t = timestamp - prev_timestamp;
                    ulong ns = t.as!"nsecs";
                    if (ns == 0)
                        return;
                    auto dt = VarQuantity(ns / 1_000_000_000.0, Seconds);

                    if (sum_type == SumType.right)
                        sample = sample * dt;
                    else
                    {
                        if (!prev_val.isNumber)
                            return;
                        VarQuantity prev = prev_val.asQuantity;

                        if (sum_type == SumType.negative_trapezoid)
                            sample = -sample, prev = -prev;

                        auto zero = VarQuantity(0, sample.unit);

                        if (sum_type == SumType.trapezoid || (sample >= zero && prev >= zero))
                            sample = (prev + sample) * (dt * 0.5);
                        else if (sample < zero && prev < zero)
                            sample = VarQuantity(0, sample.unit * Seconds);
                        else if (prev > zero) // + to -
                            sample = prev * (prev / (prev - sample)) * (dt * 0.5);
                        else // - to +
                            sample = sample * (sample / (sample - prev)) * (dt * 0.5);
                    }
                }

                Variant value = target.value;
                if (!value.isNumber)
                    target.value(Variant(sample), timestamp);
                else
                    target.value(Variant(value.asQuantity + sample), timestamp);
                break;

            case alias_:
                // ElementLink manages its own subscribers
                break;
        }
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

    ~this()
    {
        clear_computations();
        if (profile)
            g_app.allocator.freeT(profile);
    }

    Profile* profile;
    Array!Computation computations;

    bool finalise()
    {
//        // walk all elements in all components and collect the sampler components into a list, sorted by update frequency
//        foreach (c; components)
//        {
//            foreach (ref Element e; c.elements)
//            {
//                if (e.method == Element.Method.Sample)
//                    sample_elements ~= &e;
//            }
//        }
//
//        last_poll = getTime();

        return true;
    }

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
                                el.remove_subscriber(&c.element_updated);
                        }
                    }
                    c.expression.free_expression();
                    break;

                case accumulator:
                    if (c.bound && c.source)
                        c.source.remove_subscriber(&c.element_updated);
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

//        MonoTime now = getTime();
//        Duration elapsed = now - last_poll;
//        last_poll = now;
//
//        // gather all elements that need to be sampled
//        Element*[] elements;
//        foreach (Element* e; sample_elements)
//        {
//            if (e.sampler.updateIntervalMs == 0)
//            {
//                // sample constants just once
//                if (!e.sampler.constantSampled && !e.sampler.in_flight)
//                    elements ~= e;
//                continue;
//            }
//            else
//            {
//                // sample regular values
//                e.sampler.nextSample -= elapsed;
//                if (e.sampler.nextSample <= Duration.zero && !e.sampler.in_flight)
//                    elements ~= e;
//            }
//        }
//
//        if (!elements)
//            return;
//
//        // sort the elements by server and register
//        auto work = elements.sort!((a, b) {
//            Sampler* as = a.sampler;
//            Sampler* bs = b.sampler;
//            if (as.server !is bs.server)
//                return as.server < bs.server;
//            if (as.lessThan)
//                return as.lessThan(as, bs);
//            return a.id < b.id;
//        }).chunkBy!((a, b) => a.sampler.server is b.sampler.server);
//
//        // issue requests
//        foreach (serverElements; work)
//        {
//            assert(!serverElements.empty);
//
//            // TODO: i'd love it if this module didn't reference the router!
////            Server server = serverElements.front.sampler.server;
////            server.requestElements(serverElements.array);
//        }
    }

    Array!(Element*) sample_elements;
    MonoTime last_poll;

package:
    void try_bind_pending()
    {
        // TODO: bind order should be topological by ref-graph; this kind-major split
        // matches the original convention (expressions before sums) but breaks down
        // when expressions chain or when profiles list sums before their source expressions
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
                e.add_subscriber(&c.element_updated);
                c.element_updated(*e, e.latest, e.last_update, e.prev, e.prev_update);
            }
            c.bound = true;
        }

        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.accumulator)
                continue;
            const(char)[] src = as_dstring(cast(const char*)c.source);
            Element* e = resolve_ref(src);
            if (!e)
                continue;
            e.add_subscriber(&c.element_updated);
            c.source = e;
            c.bound = true;
        }

        foreach (ref c; computations)
        {
            if (c.bound || c.kind != ComputationKind.alias_)
                continue;
            // ElementLink manages its own lifecycle via g_app
            c.bound = true;
        }
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

    device.try_bind_pending();

    if (is_new_device)
        g_app.devices.insert(device.id[], device);

    return device;
}
