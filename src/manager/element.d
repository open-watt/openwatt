module manager.element;

import manager.component;
import manager.device;
import manager.units;
import manager.value;


struct Element
{

	enum Method : ubyte
	{
		Constant,
		Calculate,
		Sample,
	}

	string id;
	string name;
	string unit;
	Method method;
	Value.Type type;
	int arrayLen;

	Value latest;

	inout(Value) currentValue() inout
	{
		return latest;
	}

	Value[] recentValues(/* recent duration in ms */) const
	{
		return null;
	}

	Value[] valueRange(/* from time to time */) const
	{
		return null;
	}

	union
	{
		Value function(Device* device, Component* component) calcFun;
		Sampler* sampler;
	}
}

struct Sampler
{
	int serverId;
	void* samplerData;
	void* dbRef;
	UnitDef convert;
	int updateIntervalMs;
}
