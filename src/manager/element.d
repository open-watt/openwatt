module manager.element;

import manager.component;
import manager.device;
import manager.subscriber;
import manager.units;
import manager.value;

import urt.string;

nothrow @nogc:


enum Access : ubyte
{
	Read,
	Write,
	ReadWrite
}

enum PageBits = 8;
enum PageSize = 1 << PageBits;

__gshared Element*[PageSize] elementPool;
__gshared ubyte numPages = 0;
__gshared ubyte pageOffset = 0;


struct ElementRef
{
	alias getElement this;

	ref inout(Element) getElement() inout nothrow @nogc
	{
		return *cast(inout(Element)*)&elementPool[_el >> PageBits][_el & (PageSize - 1)];
	}

private:
	ushort _el;
}


struct Element
{
nothrow @nogc:

	static ElementRef create()
	{
		ubyte page = numPages;
		ubyte index = pageOffset;
		if (index == 0)
		{
			import urt.mem.alloc;
			elementPool[numPages++] = (cast(Element[])alloc(Element.sizeof * PageSize))[0 .. PageSize].ptr;
		}
		elementPool[page][pageOffset++] = Element();
		return ElementRef(_el: (page << 8) | index);
	}

	enum Method : ubyte
	{
		Constant,
		Calculate,
		Sample,
	}

	String id;
	String name;
	String unit;
	Method method;
	Value.Type type;
	ushort arrayLen;

	Value latest;

	Access access;

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

    void setValue(T)(auto ref T v)
    {
        import urt.traits;

        static if (is(T == int))
        {
            if (latest.asInt() != v)
            {
                latest = Value(v);
                // TODO: signal subscribers...
            }
        }
        else static if (is(T == float))
        {
            if (latest.asFloat() != v)
            {
                latest = Value(v);
                // TODO: signal subscribers...
            }
        }
        else static if (is(T : const(char)[]))
        {
            if (latest.asString() != v[])
            {
                latest = Value(v);
                // TODO: signal subscribers...
            }
        }
        else static if (is(T E == enum) && isSomeInt!E)
            setValue(cast(int)v);
        else static if (isSomeInt!T)
            setValue(cast(int)v);
        else static if (isSomeFloat!T)
            setValue(cast(float)v);
        else
            static assert(false, "Not implemented");
    }

	union
	{
		Value function(Device* device, Component* component) calcFun;
		SamplerData* sampler;
	}

	ubyte numSubscribers;
	Subscriber subscribers;
}

struct SamplerData
{
	void* server; // Server
	void* samplerData;
	void* dbRef;
	UnitDef convert;
	int updateIntervalMs;
	bool function(SamplerData* a, SamplerData* b) lessThan;

	//...
	import urt.time;
	Duration nextSample;
	bool inFlight;
	bool constantSampled;
}
