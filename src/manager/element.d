module manager.element;

import urt.array;
import urt.string;
import urt.variant;

import manager.component;
import manager.device;
import manager.subscriber;

nothrow @nogc:


enum Access : ubyte
{
    read,
    write,
    read_write
}


struct Element
{
nothrow @nogc:

    String id;
    String name;

    Variant latest;
//    ScaledUnit display_unit; // TODO: I think we should probably distinguish the display unit from the sampled unit

    Access access;

    Array!Subscriber subscribers;
    ushort subscribers_dirty;

    this(this) @disable;

    void add_subscriber(Subscriber s)
    {
        if (subscribers[].findFirst(s) == subscribers.length)
            subscribers ~= s;
    }

    void remove_subscriber(Subscriber s)
    {
        subscribers.removeFirstSwapLast(s);
    }

    float normalised_value() const
    {
        return cast(float)value.asQuantity().normalise().value;
    }

    ref const(Variant) value() const
    {
        return latest;
    }

    void value(T)(auto ref T v)
    {
        if (latest != v)
        {
            latest = v;
            signal(latest, null); // TODO: who made the change? so we can break cycles...
        }
    }

    void signal(ref const Variant v, Subscriber who)
    {
        foreach (s; subscribers)
            s.on_change(&this, v, who);
    }
}
