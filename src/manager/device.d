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
import manager.sampler;

nothrow @nogc:


alias CreateElementHandler = void delegate(Device device, Element* e, ref const ElementDesc desc, ubyte index) nothrow @nogc;

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
        clear_expression_elements();
        if (profile)
            g_app.allocator.freeT(profile);
    }

    Profile* profile;
    Array!ExpressionElement expressions;
    Array!SumElement sums;
    Array!Sampler samplers;

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

    void clear_expression_elements()
    {
        foreach (ref e; expressions)
        {
            bool have_var_refs;
            Array!(const(char)[]) refs = e.expression.get_element_refs(have_var_refs);
            foreach (r; refs)
            {
                Element* el = find_element(r);
                el.remove_subscriber(&e.element_updated);
            }
            e.expression.free_expression();
        }
        expressions.clear();
    }

    void update()
    {
        foreach (s; samplers)
            s.update();

        SysTime now = getSysTime();
        foreach (ref sum; sums)
        {
            Element* src = sum.source;
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

private:

    struct ExpressionElement
    {
        Device device;
        Element* element;
        Expression* expression;

    nothrow @nogc:
        void element_updated(ref Element, ref const Variant, SysTime timestamp, ref const Variant, SysTime)
        {
            EvalContext ctx;
            ctx.root = device;
            Variant r = expression.evaluate(ctx);
            element.value(r.move, timestamp);
        }
    }

    struct SumElement
    {
        Device device;
        Element* element;
        Element* source;
        SumType type;

    nothrow @nogc:
        void element_updated(ref Element, ref const Variant next_sample, SysTime timestamp, ref const Variant prev_sample, SysTime prev_timestamp)
        {
            import urt.si.quantity;
            import urt.si.unit;

            if (!next_sample.isNumber)
                return; // we can't accumulate non-numbers...?
            VarQuantity sample = next_sample.asQuantity;

            if (type != SumType.sum)
            {
                enum Seconds = ScaledUnit(Second);

                Duration t = timestamp - prev_timestamp;
                ulong ns = t.as!"nsecs";
                if (ns == 0)
                    return;
                auto dt = VarQuantity(ns / 1_000_000_000.0, Seconds);

                if (type == SumType.right)
                    sample = sample * dt;
                else
                {
                    if (!prev_sample.isNumber)
                        return; // we can't accumulate non-numbers...?
                    VarQuantity prev = prev_sample.asQuantity;

                    if (type == SumType.negative_trapezoid)
                        sample = -sample, prev = -prev;

                    auto zero = VarQuantity(0, sample.unit);

                    if (type == SumType.trapezoid || (sample >= zero && prev >= zero))
                        sample = (prev + sample) * (dt * 0.5);
                    else if(sample < zero && prev < zero)
                        sample = VarQuantity(0, sample.unit * Seconds);
                    else if (prev > zero) // + to -
                        sample = prev * (prev / (prev - sample)) * (dt * 0.5);
                    else // - to +
                        sample = sample * (sample / (sample - prev)) * (dt * 0.5);
                }
            }

            Variant value = element.value;
            if (!value.isNumber)
                element.value(Variant(sample), timestamp);
            else
                element.value(Variant(value.asQuantity + sample), timestamp);
        }
    }
}

Device create_device_from_profile(ref Profile profile, const(char)[] model, const(char)[] id, const(char)[] name, scope CreateElementHandler create_element_handler)
{
    import urt.mem.allocator;
    import manager;

    if (id in g_app.devices)
    {
        writeWarning("Device '", id, "' already exists");
        return null;
    }

    DeviceTemplate* device_template = profile.get_model_template(model);
    if (!device_template)
    {
        writeWarning("No device template for model '", model, "'");
//        session.write_line("No device template for model '", model, "' in profile '", profileName, "'");
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

    Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
    if (name)
        device.name = name.makeString(g_app.allocator);

    Component create_component(ref ComponentTemplate ct)
    {
        Component c = g_app.allocator.allocT!Component(ct.get_id(profile).makeString(defaultAllocator()));
        c.template_ = ct.get_template().makeString(defaultAllocator());

        foreach (ref child; ct.components(profile))
        {
            if ((ct._model_mask & model_bit) == 0)
                continue;

            Component child_component = create_component(child);
            c.components ~= child_component;
        }

        foreach (ref el; ct.elements(profile))
        {
            if ((el._model_mask & model_bit) == 0)
                continue;

            Element* e = g_app.allocator.allocT!Element();
            e.id = el.get_id(profile).makeString(defaultAllocator());
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

            final switch (el.type) with (ElementTemplate.Type)
            {
                case expression:
                    Expression* expr;
                    const(char)[] expr_str = el.get_expression(profile);
                    try
                        expr = parse_expression(expr_str);
                    catch (Exception e)
                    {
                        writeWarning("Failed to parse expression: ", expr_str);
                        goto fail;
                    }

                    bool have_var_refs;
                    Array!(const(char)[]) refs = expr.get_element_refs(have_var_refs);
                    if (have_var_refs)
                    {
                        writeWarning("Element expressions can't have variable references: ", expr_str);
                        goto fail;
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
                        device.expressions ~= Device.ExpressionElement(device, e, expr);
                        e.sampling_mode = SamplingMode.dependent;
                    }
                    break;

                case map:
                    create_element_handler(device, e, el.get_element_desc(profile), el.index);
                    break;

                case sum:
                    const(char)* src = el.get_source(profile);
                    device.sums ~= Device.SumElement(device, e, cast(Element*)src, cast(SumType)el.index);
                    e.sampling_mode = SamplingMode.dependent;
                    break;
            }

            c.elements ~= e;
            continue;

        fail:
            g_app.allocator.freeT(e);
        }

        return c;
    }

    // create a bunch of components from the profile template
    foreach (ref ct; device_template.components(profile))
    {
        if ((ct._model_mask & model_bit) == 0)
            continue;

        Component c = create_component(ct);
        device.components ~= c;
    }

    // hookup expressions
    outer: foreach (ref expr; device.expressions)
    {
        bool _;
        Array!(const(char)[]) refs = expr.expression.get_element_refs(_);
        foreach (r; refs)
        {
            if (!device.find_element(r))
            {
                writeWarning("Failed to resolve element references in expression: @", r);
                break outer;
            }
        }
        foreach (r; refs)
        {
            Element* e = device.find_element(r);
            e.add_subscriber(&expr.element_updated);

            // allow the expression to initialise by calling with the reference init values
            expr.element_updated(*e, e.latest, e.last_update, e.prev, e.prev_update);
        }
    }

    // hookup sum samplers
    foreach (ref sum; device.sums)
    {
        const(char)[] src = as_dstring(cast(const char*)sum.source);
        Element* e = device.find_element(src);
        if (!e)
        {
            writeWarning("Failed to find source element for sum element");
            continue;
        }
        e.add_subscriber(&sum.element_updated);
        sum.source = e;
    }

    g_app.devices.insert(device.id[], device);

    return device;
}
