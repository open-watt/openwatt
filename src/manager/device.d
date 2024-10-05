module manager.device;

import std.algorithm;
import std.array;

import manager.component;
import manager.element;
import manager.value;

import router.modbus.message;
import router.modbus.profile;

import urt.log;
import urt.string;
import urt.time;


struct Device
{
	String id;
	String name;
	Component*[String] components;

//	Server[] servers;

	void addComponent(Component* component)
	{
		components[component.id] = component;
	}

	bool finalise()
	{
		// walk all elements in all components and collect the sampler components into a list, sorted by update frequency
		foreach (String id, Component* c; components)
		{
			foreach (ref Element e; c.elements)
			{
				if (e.method == Element.Method.Sample)
					sampleElements ~= &e;
			}
		}

		lastPoll = getTime();

		return true;
	}

	void update()
	{
		MonoTime now = getTime();
		Duration elapsed = now - lastPoll;
		lastPoll = now;

		// gather all elements that need to be sampled
		Element*[] elements;
		foreach (Element* e; sampleElements)
		{
			if (e.sampler.updateIntervalMs == 0)
			{
				// sample constants just once
				if (!e.sampler.constantSampled && !e.sampler.inFlight)
					elements ~= e;
				continue;
			}
			else
			{
				// sample regular values
				e.sampler.nextSample -= elapsed;
				if (e.sampler.nextSample <= Duration.zero && !e.sampler.inFlight)
					elements ~= e;
			}
		}

		if (!elements)
			return;

		// sort the elements by server and register
		auto work = elements.sort!((a, b) {
			Sampler* as = a.sampler;
			Sampler* bs = b.sampler;
			if (as.server !is bs.server)
				return as.server < bs.server;
			if (as.lessThan)
				return as.lessThan(as, bs);
			return a.id < b.id;
		}).chunkBy!((a, b) => a.sampler.server is b.sampler.server);

		// issue requests
		foreach (serverElements; work)
		{
			assert(!serverElements.empty);

			// TODO: i'd love it if this module didn't reference the router!
//			Server server = serverElements.front.sampler.server;
//			server.requestElements(serverElements.array);
		}
	}

private:
	Element*[] sampleElements;
	MonoTime lastPoll;
}
