module manager.element;

import manager.component;
import manager.device;
import manager.subscriber;
import manager.units;
import manager.value;

import urt.string;

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

	ubyte numSubscribers;
	Subscriber subscribers;
}

struct Sampler
{
	void* server; // Server
	void* samplerData;
	void* dbRef;
	UnitDef convert;
	int updateIntervalMs;
	bool function(Sampler* a, Sampler* b) lessThan;

	//...
	import urt.time;
	Duration nextSample;
	bool inFlight;
	bool constantSampled;
}
