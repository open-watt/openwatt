module manager.value;


struct Value
{
nothrow @nogc:

	enum Type : ubyte
	{
		Null,
		Bool,
		Integer,
		Float,
		String,
		TString, // a string in a temp buffer, which should be copied if it needs to be kept
		Element,
		Time,
	}

	this(typeof(null))
	{
		type = Type.Null;
		this.p = null;
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
	bool[] asBoolArray() const nothrow @nogc { return (cast(bool*)p)[0..length]; }
	long[] asIntArray() const nothrow @nogc { return (cast(long*)p)[0..length]; }
	double[] asFloatArray() const nothrow @nogc { return (cast(double*)p)[0..length]; }

	import urt.string.format;
	ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const nothrow @nogc
	{
		switch (type)
		{
			case Type.Null:
				return 0;
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
			default:
				assert(false);
		}
	}

    bool fromString(const(char)[] s, size_t* taken = null)
    {
        if (s.length == 0)
        {
            len_ty = Type.Null;
            p = null;
            return true;
        }
        bool isQuotes = false;
        if (s[0] == '"' || s[0] == '\"' || s[0] == '`')
            isQuotes = true;
        else
        {
            // try and handle non-string cases

            // maybe bool?

            // maybe float?

            // maybe int?

            //...
        }

        import urt.mem.allocator;
        import urt.string;

        // accept it as a string...
        debug assert(s.length <= 0x0FFFFFFF);

        // TODO: Value's don't own their memory, but they should...
        //       for now, we just dup and leak!
        char[] mem = cast(char[])defaultAllocator.alloc(s.length);
        if (isQuotes)
            mem = s.unQuote(mem);
        else
            mem[] = s[];

        type = Type.String;
        length = cast(uint)mem.length;
        p = cast(void*)mem.ptr;

        return true;
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
