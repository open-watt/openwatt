module manager.value;

import manager.component : Component;

import std.conv;


struct Value
{
	enum Type : ubyte
	{
		Integer,
		Float,
		Bool,
		String,
		Component,
	}

	this(double f)
	{
		type = Type.Float;
		this.f = f;
	}
	this(long i)
	{
		type = Type.Integer;
		this.i = i;
	}
	this(bool b)
	{
		type = Type.Bool;
		this.i = b ? 1 : 0;
	}
	this(const(char)[] s)
	{
		type = Type.String;
		this.length = s.length;
		this.p = cast(void*)s.ptr;
	}
	this(double[] arr)
	{
		type = Type.Float;
		this.length = arr.length;
		this.p = cast(void*)arr.ptr;
	}
	this(long[] arr)
	{
		type = Type.Integer;
		this.length = arr.length;
		this.p = cast(void*)arr.ptr;
	}

	Type type() const @property { return cast(Type)(len_ty >> 60); }
	size_t length() const @property { return len_ty & 0x0FFFFFFFFFFFFFFF; }

	bool asBool() const { return i != 0; }
	long asInt() const { return i; }
	double asFloat() const { return f; }
	const(char)[] asString() const { return (cast(const(char)*)p)[0..length]; }
	Component* asComponent() const { return cast(Component*)p; }
	bool[] asBoolArray() const { return (cast(bool*)p)[0..length]; }
	long[] asIntArray() const { return (cast(long*)p)[0..length]; }
	double[] asFloatArray() const { return (cast(double*)p)[0..length]; }
	Component*[] asComponentArray() const { return (cast(Component**)p)[0..length]; }

	const(char)[] toString() const
	{
		switch (type)
		{
			case Type.Bool:
				return asBool() ? "true" : "false";
			case Type.Integer:
				if (length)
					return to!string(asIntArray());
				else
					return to!string(asInt());
			case Type.Float:
				if (length)
					return to!string(asFloatArray());
				else
					return to!string(asFloat());
			case Type.String:
				return asString();
			case Type.Component:
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

	void type(Type ty) @property { len_ty = (len_ty & 0x0FFFFFFFFFFFFFFF) | (cast(size_t)ty << 60); }
	void length(size_t len) @property { len_ty = (len & 0x0FFFFFFFFFFFFFFF) | (len_ty & 0xF000000000000000); }
}
