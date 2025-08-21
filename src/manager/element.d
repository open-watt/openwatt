module manager.element;

import urt.array;
import urt.string;

import manager.component;
import manager.device;
import manager.subscriber;
import manager.units;
import manager.value;

nothrow @nogc:


enum Access : ubyte
{
    Read,
    Write,
    ReadWrite
}


struct Element
{
nothrow @nogc:

    String id;
    String name;
    String unit;

    Value latest;

    Access access;

    Value.Type type;
    ushort arrayLen;

    Array!Subscriber subscribers;

    this(this) @disable;

    void addSubscriber(Subscriber s)
    {
        if (subscribers[].findFirst(s) == subscribers.length)
            subscribers ~= s;
    }

    void removeSubscriber(Subscriber s)
    {
        subscribers.removeFirstSwapLast(s);
    }

    float normalisedValue() const
    {
        if (unit)
        {
            UnitDef conv = getUnitConv(unit);
            float val = value.asFloat();
            return conv.normalise(val);
        }
        else
            return value.asFloat();
    }

    ref const(Value) value() const
    {
        return latest;
    }

    void value(T)(auto ref T v)
    {
        import urt.traits;

        static if (is(T == int))
        {
            if (latest.getInt() != v)
            {
                latest = Value(v);
                signal(latest, null); // TODO: who made the change? so we can break cycles...
            }
        }
        else static if (is(T == float))
        {
            if (latest.getFloat() != v)
            {
                latest = Value(v);
                signal(latest, null); // TODO: who made the change? so we can break cycles...
            }
        }
        else static if (is(T : const(char)[]))
        {
            if (latest.getString() != v[])
            {
                latest = Value(v);
                signal(latest, null); // TODO: who made the change? so we can break cycles...
            }
        }
        else static if (is(T E == enum) && is_some_int!E)
            value(cast(int)v);
        else static if (is_some_int!T)
            value(cast(int)v);
        else static if (is_some_float!T)
            value(cast(float)v);
        else
            static assert(false, "Not implemented");
    }

    void signal(ref const Value v, Subscriber who)
    {
        foreach (s; subscribers)
            s.onChange(&this, v, who);
    }
}
