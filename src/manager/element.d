module manager.element;

import urt.array;
import urt.lifetime : forward;
import urt.mem.string;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
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

enum SamplingMode : ubyte
{
    manual,
    constant,

    // these signal how samplers intend to interact with the element
    poll,
    report,
    on_demand,
    config
}


struct Element
{
nothrow @nogc:

    private Variant latest;

    String id;
    String name;
    String desc;
    String display_unit;

    SysTime last_update;

    Array!Subscriber subscribers;
    ushort subscribers_dirty;

    Access access;
    SamplingMode sampling_mode;

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

    double normalised_value() const
    {
        return value.asQuantity().normalise().value;
    }

    double scaled_value(ScaledUnit unit)() const
    {
        import urt.si.quantity : Quantity;
        return Quantity!(double, unit)(value.asQuantity()).value;
    }

    double scaled_value(ScaledUnit unit) const
    {
        return value.asQuantity().adjust_scale(unit).value;
    }

    ref inout(Variant) value() @property inout
    {
        return latest;
    }

    void value(T)(auto ref T v, SysTime timestamp = getSysTime()) @property
    {
        last_update = timestamp;

        if (latest != v)
        {
            latest = forward!v;
            signal(latest, timestamp, null); // TODO: who made the change? so we can break cycles...
        }
    }

    void signal(ref const Variant v, SysTime timestamp, Subscriber who)
    {
        foreach (s; subscribers)
            s.on_change(&this, v, timestamp, who);
    }
}
