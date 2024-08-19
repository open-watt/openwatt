module manager.value;

import manager.component : Component;

import std.conv;


struct Value
{
	enum Type : ubyte
	{
		Bool,
		Integer,
		Float,
		String,
		TString, // a string in a temp buffer, which should be copied if it needs to be kept
		Element,
		Component,
		Time,
	}

	this(float f)
	{
		type = Type.Float;
		this.f = f;
	}
	this(int i)
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
		debug assert(s.length <= 0x0FFFFFFF);
		type = Type.String;
		this.length = cast(uint)s.length;
		this.p = cast(void*)s.ptr;
	}
	this(float[] arr)
	{
		debug assert(arr.length <= 0x0FFFFFFF);
		type = Type.Float;
		this.length = cast(uint)arr.length;
		this.p = cast(void*)arr.ptr;
	}
	this(int[] arr)
	{
		debug assert(arr.length <= 0x0FFFFFFF);
		type = Type.Integer;
		this.length = cast(uint)arr.length;
		this.p = cast(void*)arr.ptr;
	}

	Type type() const @property nothrow @nogc { return cast(Type)(len_ty >> 28); }
	size_t length() const @property nothrow @nogc { return len_ty & 0x0FFFFFFF; }

	bool asBool() const nothrow @nogc { return i != 0; }
	long asInt() const nothrow @nogc { return i; }
	double asFloat() const nothrow @nogc { return f; }
	const(char)[] asString() const nothrow @nogc { return (cast(const(char)*)p)[0..length]; }
	Component* asComponent() const nothrow @nogc { return cast(Component*)p; }
	bool[] asBoolArray() const nothrow @nogc { return (cast(bool*)p)[0..length]; }
	long[] asIntArray() const nothrow @nogc { return (cast(long*)p)[0..length]; }
	double[] asFloatArray() const nothrow @nogc { return (cast(double*)p)[0..length]; }
	Component*[] asComponentArray() const nothrow @nogc { return (cast(Component**)p)[0..length]; }

	import urt.string.format;
	ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const nothrow @nogc
	{
		switch (type)
		{
			case Type.Bool:
				return format(buffer, "{0,@1}", asBool(), fmt).length;
			case Type.Integer:
				if (length)
					return format(buffer, "{0,@1}", asIntArray(), fmt).length;
				else
					return format(buffer, "{0,@1}", asInt(), fmt).length;
			case Type.Float:
				if (length)
					return format(buffer, "{0,@1}", asFloatArray(), fmt).length;
				else
					return format(buffer, "{0,@1}", asFloat(), fmt).length;
			case Type.String:
				return format(buffer, "{0,@1}", asString(), fmt).length;
			case Type.Component:
				return format(buffer, "{0,@1}", *asComponent(), fmt).length;
			default:
				assert(false);
		}
	}

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
	uint len_ty = 0;
	union
	{
		void* p = null;
		int i;
		float f;
	}

	void type(Type ty) @property { len_ty = (len_ty & 0x0FFFFFFF) | (cast(uint)ty << 28); }
	void length(size_t len) @property { debug assert(len <= 0x0FFFFFFF); len_ty = (len & 0x0FFFFFFF) | (len_ty & 0xF0000000); }
}
