module manager.component;

import manager.device;
import manager.element;
import manager.units;

import router.server;

struct Component
{
	string id;
	string name;
	Element[] elements;
	Element*[string] elementsById;
}

Component* createComponentForModbusServer(string id, string name, int serverId, Server server)
{
	import router.modbus.profile;

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

	return component;
}


private:

import router.modbus.profile : RecordType;

immutable Element.Type[] modbusRegTypeToElementTypeMap = [
	Element.Type.Float, // NOTE: seems crude to cast all numeric values to float...
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Float,
	Element.Type.Integer,
	Element.Type.Integer,
	Element.Type.Integer,
	Element.Type.Integer,
	Element.Type.String
];

static assert(modbusRegTypeToElementTypeMap.length == RecordType.max + 1);
