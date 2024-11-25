module manager.device;

import urt.array;
import urt.log;
import urt.string;
import urt.time;

import manager.component;
import manager.element;
import manager.sampler;
import manager.value;

import router.modbus.message;
import router.modbus.profile;

nothrow @nogc:



struct Device
{
nothrow @nogc:

	String id;
	String name;
	Array!(Component*) components;

	Array!Sampler samplers;

//	Server[] servers;

    this(this) @disable;

    void addComponent(Component* component) // TODO: include sampler here...
    {
        foreach (Component* c; components)
        {
            if (c.name[] == component.name[])
            {
                debug assert(false, "Component '" ~ component.name ~ "' already exists in device '" ~ name ~ "'");
                assert(false, "Already exists");
                return;
            }
        }
        components.pushBack(component);
    }

    Component* findComponent(const(char)[] name)
    {
        foreach (Component* c; components)
        {
            if (c.name[] == name[])
                return c;
        }
        return null;
    }

	bool finalise()
	{
//		// walk all elements in all components and collect the sampler components into a list, sorted by update frequency
//		foreach (c; components)
//		{
//			foreach (ref Element e; c.elements)
//			{
//				if (e.method == Element.Method.Sample)
//					sampleElements ~= &e;
//			}
//		}
//
//		lastPoll = getTime();

		return true;
	}

	void update()
	{
		foreach (s; samplers)
			s.update();

//		MonoTime now = getTime();
//		Duration elapsed = now - lastPoll;
//		lastPoll = now;
//
//		// gather all elements that need to be sampled
//		Element*[] elements;
//		foreach (Element* e; sampleElements)
//		{
//			if (e.sampler.updateIntervalMs == 0)
//			{
//				// sample constants just once
//				if (!e.sampler.constantSampled && !e.sampler.inFlight)
//					elements ~= e;
//				continue;
//			}
//			else
//			{
//				// sample regular values
//				e.sampler.nextSample -= elapsed;
//				if (e.sampler.nextSample <= Duration.zero && !e.sampler.inFlight)
//					elements ~= e;
//			}
//		}
//
//		if (!elements)
//			return;
//
//		// sort the elements by server and register
//		auto work = elements.sort!((a, b) {
//			Sampler* as = a.sampler;
//			Sampler* bs = b.sampler;
//			if (as.server !is bs.server)
//				return as.server < bs.server;
//			if (as.lessThan)
//				return as.lessThan(as, bs);
//			return a.id < b.id;
//		}).chunkBy!((a, b) => a.sampler.server is b.sampler.server);
//
//		// issue requests
//		foreach (serverElements; work)
//		{
//			assert(!serverElements.empty);
//
//			// TODO: i'd love it if this module didn't reference the router!
////			Server server = serverElements.front.sampler.server;
////			server.requestElements(serverElements.array);
//		}
	}

	Array!(Element*) sampleElements;
	MonoTime lastPoll;
}
