module manager.device;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager.component;
import manager.element;
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

    void update()
    {
        foreach (s; samplers)
            s.update();

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
//                if (!e.sampler.constantSampled && !e.sampler.inFlight)
//                    elements ~= e;
//                continue;
//            }
//            else
//            {
//                // sample regular values
//                e.sampler.nextSample -= elapsed;
//                if (e.sampler.nextSample <= Duration.zero && !e.sampler.inFlight)
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
//        session.writeLine("No device template for model '", model, "' in profile '", profileName, "'");
        return null;
    }

    Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
    if (name)
        device.name = name.makeString(g_app.allocator);

    Component create_component(ref ComponentTemplate ct)
    {
        Component c = g_app.allocator.allocT!Component(ct.get_id(profile).makeString(defaultAllocator()));
        c.template_ = ct.get_template().makeString(defaultAllocator());

        foreach (ref child; ct.components(profile))
        {
            Component child_component = create_component(child);
            c.components ~= child_component;
        }

        foreach (ref el; ct.elements(profile))
        {
            Element* e = g_app.allocator.allocT!Element();
            e.id = el.get_id(profile).makeString(defaultAllocator());

            final switch (el.type) with (ElementTemplate.Type)
            {
                case constant:
                    // TODO: we should parse the value string with the expression parser...
                    const(char)[] value = el.get_constant_value(profile);
                    e.latest.fromString(value);
                    break;

                case map:
                    create_element_handler(device, e, el.get_element_desc(profile), el.index);
                    break;
            }

            c.elements ~= e;
        }

        return c;
    }

    // create a bunch of components from the profile template
    foreach (ref ct; device_template.components(profile))
    {
        Component c = create_component(ct);
        device.components ~= c;
    }

    g_app.devices.insert(device.id, device);

    return device;
}
