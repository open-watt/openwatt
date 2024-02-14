module manager.device;

import std.algorithm;
import std.array;
import std.datetime : Duration, MonoTime, msecs;
import std.stdio;
import std.string : stripRight;

import manager.component;
import manager.element;
import manager.value;

import router.modbus.message;
import router.modbus.profile;
import router.server;

struct Device
{
	string id;
	string name;
	Component*[string] components;

	Server[] servers;

	void addComponent(Component* component)
	{
		components[component.id] = component;
	}

	int addServer(Server server)
	{
		servers ~= server;
		return cast(int)(servers.length - 1);
	}

	bool finalise()
	{
		// walk all elements in all components and collect the sampler components into a list, sorted by update frequency
		foreach (string id, Component* c; components)
		{
			foreach (ref Element e; c.elements)
			{
				if (e.method == Element.Method.Sample)
				{
					if (e.sampler.serverId >= servers.length)
						return false;
					sampleElements ~= SampleElement(&e);
				}
			}
		}

		lastPoll = MonoTime.currTime;

		return true;
	}

	void update()
	{
		MonoTime now = MonoTime.currTime;
		Duration elapsed = now - lastPoll;
		lastPoll = now;

		// gather all elements that need to be sampled
		SampleElement*[] elements;
		foreach (ref SampleElement e; sampleElements)
		{
			if (e.element.sampler.updateIntervalMs == 0)
			{
				// sample constants just once
				if (!e.constantSampled && !e.inFlight)
					elements ~= &e;
				continue;
			}
			else
			{
				// sample regular values
				e.nextSample -= elapsed;
				if (e.nextSample <= Duration.zero && !e.inFlight)
					elements ~= &e;
			}
		}

		if (!elements)
			return;

		// sort the elements by server and register
		auto work = elements.sort!((a, b) {
			Sampler* as = a.element.sampler;
			Sampler* bs = b.element.sampler;
			if (as.serverId != bs.serverId)
				return as.serverId < bs.serverId;
			ModbusServer modbus = cast(ModbusServer)servers[as.serverId];
			if (modbus)
			{
				const ModbusRegInfo* areg = cast(ModbusRegInfo*)as.samplerData;
				const ModbusRegInfo* breg = cast(ModbusRegInfo*)bs.samplerData;
				return areg.reg < breg.reg;
			}
			return a.element.id < b.element.id;
		}).chunkBy!((a, b) => a.element.sampler.serverId == b.element.sampler.serverId);

		// issue requests
		foreach (serverElements; work)
		{
			assert(!serverElements.empty);

			Server server = servers[serverElements.front.element.sampler.serverId];

			ModbusServer modbus = cast(ModbusServer)server;
			if (modbus)
			{
				ModbusReqElement[] modbusRequestElements = serverElements.map!(e => ModbusReqElement(e, e.element, e.element.sampler, cast(const(ModbusRegInfo)*)e.element.sampler.samplerData)).array;

				size_t startEl = 0;
				ushort firstReg = modbusRequestElements[0].regInfo.reg;
				ushort prevReg = firstReg;
				for (size_t i = 0; i < modbusRequestElements.length; ++i)
				{
					ushort seqStart = modbusRequestElements[i].regInfo.reg;
					ushort seqEnd = cast(ushort)(seqStart + modbusRequestElements[i].regInfo.seqLen);

					ModbusReqElement[] thisReq = null;

					enum BigGap = 20; // how big is a big gap?
					if (i == modbusRequestElements.length - 1)
						thisReq = modbusRequestElements[startEl .. $];
					else if (seqEnd - firstReg > 120 || seqStart - prevReg > BigGap)
					{
						thisReq = modbusRequestElements[startEl .. i];
						startEl = i;
						firstReg = seqStart;
					}
					prevReg = seqEnd;

					if (thisReq)
					{
						foreach (ref ModbusReqElement e; thisReq)
							e.sampleElement.inFlight = true;

						ushort from = thisReq[0].regInfo.reg;
						ushort count = cast(ushort)(thisReq[$-1].regInfo.reg + thisReq[$-1].regInfo.seqLen - thisReq[0].regInfo.reg);

						ModbusPDU pdu = createMessage_Read(thisReq[0].regInfo.regType, from, count);
						ModbusRequest request = new ModbusRequest(&modbusResponseHandler, &pdu, 0, thisReq);
						server.sendRequest(request);
					}
				}
			}
		}
	}

private:
	SampleElement[] sampleElements;
	MonoTime lastPoll;

	struct SampleElement
	{
		Element* element;
		Duration nextSample;
		bool inFlight;
		bool constantSampled;
	}

	struct ModbusReqElement
	{
		SampleElement* sampleElement;
		Element* element;
		Sampler* sampler;
		const(ModbusRegInfo)* regInfo;
	}

	void modbusResponseHandler(Response response, void[] userData)
	{
		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		ModbusReqElement[] thisReq = cast(ModbusReqElement[])userData;

		Response.KVP[string] values = response.values;

		foreach (ref ModbusReqElement e; thisReq)
		{
			e.sampleElement.inFlight = false;

			if (response.status != RequestStatus.Success)
				continue;

			if (e.sampler.updateIntervalMs == 0)
				e.sampleElement.constantSampled = true;
			else
			{
				do
					e.sampleElement.nextSample += e.sampler.updateIntervalMs.msecs;
				while (e.sampleElement.nextSample <= Duration.zero);
			}

			Response.KVP* kvp = e.regInfo.name in values;
			if (kvp)
			{
				e.element.latest = kvp.value;

				switch (e.element.latest.type)
				{
					case Value.Type.Integer:
						if (e.element.type == Value.Type.Integer)
							break;
						assert(0);
					case Value.Type.Float:
						if (e.element.type == Value.Type.Integer)
							e.element.latest = Value(cast(long)e.element.latest.asFloat);
						else if (e.element.type == Value.Type.Float)
							break;
						else if (e.element.type == Value.Type.Bool)
							e.element.latest = Value(e.element.latest.asFloat != 0);
						assert(0);
					case Value.Type.String:
						if (e.element.type == Value.Type.String)
							break;
						assert(0);
					default:
						assert(0);
				}

				writeln(e.element.id, ": ", e.element.latest, e.element.unit);
			}
		}
	}
}
