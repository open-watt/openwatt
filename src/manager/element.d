module manager.element;

import manager.component;
import manager.device;

struct Value
{
	bool asBool() const { return b; }
	long asInt() const { return b; }
	double asFloat() const { return b; }
	const(char)[] asString() const { return (cast(const(char)*)p)[0..len]; }
	Component* asComponent() const { return cast(Component*)p; }
	bool[] asBoolArray() const { return (cast(bool*)p)[0..len]; }
	long[] asIntArray() const { return (cast(long*)p)[0..len]; }
	double[] asFloatArray() const { return (cast(double*)p)[0..len]; }
	Component*[] asComponentArray() const { return (cast(Component**)p)[0..len]; }

private:
	union
	{
		bool b;
		long i;
		double f;
		void* p;
	}
	size_t len;
}

struct Element
{
	enum Type : ubyte
	{
		Bool,
		Integer,
		Float,
		String,
		Component,
	}

	enum Method : ubyte
	{
		Constant,
		Calculate,
		Sample,
	}

	string id;
	string name;
	string unit;
	Type type;
	Method method;
	int arrayLen;

	Value currentValue() const
	{
		return Value();
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
		Value constant;
		Value function(Device* device, Component* component) calcFun;
		Sampler sampler;
	}

	struct Sampler
	{
		void* dbRef;
		void* samplerData;
		int updateInterval; // milliseconds
	}
}

class Sampler
{

}

class ModbusSampler : Sampler
{
	
}


struct ElementDef
{
	string id;
	string name;
	string unit;

	this(string id, Sampler sampler) {}

}


//ElementDef[] elements = [
//	ElementDef(id: "current", sampler: 0),
//	ElementDef("current"),
//	ElementDef("current"),
//];
