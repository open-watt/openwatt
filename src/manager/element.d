module manager.element;

import urt.array;
import urt.lifetime;
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
    none = 0,
    read = 1,
    write = 2,
    read_write = 3
}

enum SamplingMode : ubyte
{
    manual,
    constant,
    dependent,

    // these signal how samplers intend to interact with the element
    poll,
    report,
    on_demand,
    config
}

alias OnChangeCallback = void delegate(ref Element e, ref const Variant val, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp) nothrow @nogc;

struct Element
{
nothrow @nogc:

    package Variant latest;
    package Variant prev;

    String id;
    String name;
    String desc;
    String display_unit;

    SysTime last_update;
    SysTime prev_update;

    Array!Subscriber subscribers;
    Array!OnChangeCallback subscribers_2;
    ushort subscribers_dirty;

    Access access;
    SamplingMode sampling_mode;

    this(this) @disable;

    void add_subscriber(Subscriber s)
    {
        if (subscribers[].findFirst(s) == subscribers.length)
            subscribers ~= s;
    }
    void add_subscriber(OnChangeCallback s)
    {
        if (subscribers_2[].findFirst(s) == subscribers_2.length)
            subscribers_2 ~= s;
    }

    void remove_subscriber(Subscriber s)
    {
        subscribers.removeFirstSwapLast(s);
    }
    void remove_subscriber(OnChangeCallback s)
    {
        subscribers_2.removeFirstSwapLast(s);
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
        => latest;

    void value(T)(auto ref T v, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        bool is_newer = timestamp > last_update;
        if (is_newer)
        {
            prev_update = last_update;
            last_update = timestamp;
        }

        if (latest != v)
        {
            if (is_newer)
                prev = latest.move;
            latest = forward!v;
            signal(latest, timestamp, prev, prev_update, who);
        }
    }

    void signal(ref const Variant v, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp, Subscriber who)
    {
        foreach (s; subscribers)
            if (s !is who)
                s.on_change(&this, v, timestamp, who);
        foreach (s; subscribers_2)
            s(this, v, timestamp, prev, prev_timestamp);
    }

    void force_update(SysTime timestamp)
    {
        if (timestamp <= last_update)
            return;
        prev_update = last_update;
        last_update = timestamp;
        prev = latest;
        signal(latest, timestamp, prev, prev_update, null); // TODO: who made the change? so we can break cycles...
    }
}
