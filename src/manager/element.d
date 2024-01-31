module manager.element;

import manager.component;
import manager.device;
import manager.units;

import std.conv;

struct Value
{
	this(double f)
	{
		type = Element.Type.Float;
		this.f = f;
	}
	this(long i)
	{
		type = Element.Type.Integer;
		this.i = i;
	}
	this(bool b)
	{
		type = Element.Type.Bool;
		this.i = b ? 1 : 0;
	}
	this(const(char)[] s)
	{
		type = Element.Type.String;
		this.len = s.length;
		this.p = cast(void*)s.ptr;
	}
	this(double[] arr)
	{
		type = Element.Type.Float;
		this.len = arr.length;
		this.p = cast(void*)arr.ptr;
	}
	this(long[] arr)
	{
		type = Element.Type.Integer;
		this.len = arr.length;
		this.p = cast(void*)arr.ptr;
	}

	bool asBool() const { return i != 0; }
	long asInt() const { return i; }
	double asFloat() const { return f; }
	const(char)[] asString() const { return (cast(const(char)*)p)[0..len]; }
	Component* asComponent() const { return cast(Component*)p; }
	bool[] asBoolArray() const { return (cast(bool*)p)[0..len]; }
	long[] asIntArray() const { return (cast(long*)p)[0..len]; }
	double[] asFloatArray() const { return (cast(double*)p)[0..len]; }
	Component*[] asComponentArray() const { return (cast(Component**)p)[0..len]; }

	const(char)[] toString() const
	{
		switch (type)
		{
			case Element.Type.Bool:
				return asBool() ? "true" : "false";
			case Element.Type.Integer:
				if (len)
					return to!string(asIntArray());
				else
					return to!string(asInt());
			case Element.Type.Float:
				if (len)
					return to!string(asFloatArray());
				else
					return to!string(asFloat());
			case Element.Type.String:
				return asString();
			case Element.Type.Component:
				return (*asComponent()).to!string;
			default:
				assert(false);
		}
	}

private:
	size_t len_ty = 0;
	union
	{
		void* p = null;
		long i;
		double f;
	}

	void len(size_t len) @property { len_ty = (len & 0x0FFFFFFFFFFFFFFF) | (len_ty & 0xF000000000000000); }
	size_t len() const @property { return len_ty & 0x0FFFFFFFFFFFFFFF; }

	void type(Element.Type ty) @property { len_ty = (len_ty & 0x0FFFFFFFFFFFFFFF) | (cast(size_t)ty << 60); }
	Element.Type type() const @property { return cast(Element.Type)(len_ty >> 60); }
}

struct Element
{
	enum Type : ubyte
	{
		Integer,
		Float,
		Bool,
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
	Method method;
	Type type;
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
