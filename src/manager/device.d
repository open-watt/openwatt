module manager.device;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager.component;
import manager.element;
import manager.sampler;

import router.modbus.message;
import router.modbus.profile;

nothrow @nogc:



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

