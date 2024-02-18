module manager.component;

import std.stdio;

import manager.device;
import manager.element;
import manager.units;
import manager.value;

import router.modbus.profile;
import router.server;

import util.log;

struct Component
{
	string id;
	string name;
	Element[] elements;
	Element*[string] elementsById;

private:
	void modbusSnoopBusHandler(Response response, void[] userData)
	{
		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		string name = response.server.name;

		Response.KVP[string] values = response.values;
/+
		if (!modbusResponse.profile)
		{
			import std.algorithm : sort;
			import std.array : array;
			// HACK: no profile; we'll just print the data for diagnostic...
			foreach (v; values.byValue.array.sort!((a, b) => a.element[] < b.element[]))
				writeln(v.element, ": ", v.value);
			return;
		}
+/
		foreach (ref e; elements)
		{
			Response.KVP* kvp = e.id in values;
			if (kvp)
			{
				e.latest = kvp.value;
				switch (e.latest.type)
				{
					case Value.Type.Integer:
						if (e.type == Value.Type.Integer)
							break;
						assert(0);
					case Value.Type.Float:
						if (e.type == Value.Type.Integer)
							e.latest = Value(cast(long)e.latest.asFloat);
						else if (e.type == Value.Type.Float)
							break;
						else if (e.type == Value.Type.Bool)
							e.latest = Value(e.latest.asFloat != 0);
						assert(0);
					case Value.Type.String:
						if (e.type == Value.Type.String)
							break;
						assert(0);
					default:
						assert(0);
				}

				writeDebug("Modbus - ", name, '.', e.id, ": ", e.latest, e.unit);
			}
		}
	}
}

Component* createComponentForModbusServer(string id, string name, int serverId, Server server)
{
	static immutable uint[Frequency.max + 1] updateIntervalMap = [
		50,		// realtime
		1000,	// high
		10000,	// medium
		60000,	// low
		0,		// constant
		0,		// configuration
	];

	ModbusServer modbusServer = cast(ModbusServer)server;
	if (!modbusServer)
		return null;

	Component* component = new Component;
	component.id = id;
	component.name = name;

	if (modbusServer.profile)
	{
		// Create elements for each modbus register
		Element[] elements = new Element[modbusServer.profile.registers.length];
		component.elements = elements;

		foreach (size_t i, ref const ModbusRegInfo reg; modbusServer.profile.registers)
		{
			elements[i].id = reg.name;
			elements[i].name = reg.desc;
			elements[i].unit = reg.displayUnits;
			elements[i].method = Element.Method.Sample;
			elements[i].type = modbusRegTypeToElementTypeMap[reg.type]; // maybe some numeric values should remain integer?
			elements[i].arrayLen = 0;
			elements[i].sampler = new Sampler(serverId, cast(void*)&reg);
			elements[i].sampler.convert = unitConversion(reg.units, reg.displayUnits);
			elements[i].sampler.updateIntervalMs = updateIntervalMap[reg.updateFrequency];
		}

		// populate the id lookup table
		foreach (ref Element element; component.elements)
			component.elementsById[element.id] = &element;
	}

	if (modbusServer.isBusSnooping())
		modbusServer.snoopBusMessageHandler = &component.modbusSnoopBusHandler;

	return component;
}


private:

import router.modbus.profile : RecordType;

immutable Value.Type[] modbusRegTypeToElementTypeMap = [
	Value.Type.Float, // NOTE: seems crude to cast all numeric values to float...
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.String
];

static assert(modbusRegTypeToElementTypeMap.length == RecordType.max + 1);
