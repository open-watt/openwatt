module manager.device;

import std.algorithm;
import std.array;
import std.datetime : Duration, MonoTime, msecs;
import std.stdio;
import std.string : stripRight;

import manager.component;
import manager.element;

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
		import router.modbus.coding;

		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		ModbusReqElement[] thisReq = cast(ModbusReqElement[])userData;
		ushort first = thisReq[0].regInfo.reg;

		void[512] temp = void;
		ModbusMessageData data;
		if (response.status == RequestStatus.Success)
		{
			data = parseModbusMessage(RequestType.Response, modbusResponse.pdu, temp);
		}

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

			int i = e.regInfo.reg - first;
			final switch (e.regInfo.type)
			{
				case RecordType.uint16:
					e.element.latest = Value(data.rw.values[i] * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.int16:
					e.element.latest = Value(cast(short)data.rw.values[i] * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.uint32:
					e.element.latest = Value((data.rw.values[i] << 16 | data.rw.values[i + 1]) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.int32:
					e.element.latest = Value(cast(int)(data.rw.values[i] << 16 | data.rw.values[i + 1]) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.uint8H:
					e.element.latest = Value((data.rw.values[i] >> 8) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.uint8L:
					e.element.latest = Value((data.rw.values[i] & 0xFF) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.int8H:
					e.element.latest = Value(cast(byte)(data.rw.values[i] >> 8) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.int8L:
					e.element.latest = Value(cast(byte)(data.rw.values[i] & 0xFF) * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.exp10:
					assert(false);
				case RecordType.float32:
					uint f = data.rw.values[i] << 16 | data.rw.values[i + 1];
					e.element.latest = Value(*cast(float*)&f * e.sampler.convert.scale + e.sampler.convert.offset);
					break;
				case RecordType.bf16:
				case RecordType.enum16:
					e.element.latest = Value(data.rw.values[i]);
					break;
				case RecordType.bf32:
				case RecordType.enum32:
					e.element.latest = Value(data.rw.values[i] << 16 | data.rw.values[i + 1]);
					break;
				case RecordType.str:
					const(char)[] str = cast(const(char)[])data.rw.values[i .. i + e.regInfo.seqLen];
					e.element.latest = Value(str.stripRight.idup);
					break;
			}
			final switch (e.regInfo.type)
			{
				case RecordType.uint16:
				case RecordType.int16:
				case RecordType.uint32:
				case RecordType.int32:
				case RecordType.uint8H:
				case RecordType.uint8L:
				case RecordType.int8H:
				case RecordType.int8L:
				case RecordType.exp10:
				case RecordType.float32:
					if (e.element.type == Element.Type.Integer)
						e.element.latest = Value(cast(long)e.element.latest.asFloat);
					else if (e.element.type == Element.Type.Float)
						break;
					else if (e.element.type == Element.Type.Bool)
						e.element.latest = Value(e.element.latest.asFloat != 0);
					assert(false);
				case RecordType.enum16:
				case RecordType.enum32:
				case RecordType.bf16:
				case RecordType.bf32:
					if (e.element.type == Element.Type.Integer)
						break;
					assert(false);
				case RecordType.str:
					if (e.element.type == Element.Type.String)
						break;
					assert(0);
			}

			writeln(e.element.id, ": ", e.element.latest, e.element.unit);
		}
	}
}

