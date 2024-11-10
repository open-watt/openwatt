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
                // TODO: signal subscribers...
            }
        }
        else static if (is(T == float))
        {
            if (latest.getFloat() != v)
            {
                latest = Value(v);
                // TODO: signal subscribers...
            }
        }
        else static if (is(T : const(char)[]))
        {
            if (latest.getString() != v[])
            {
                latest = Value(v);
                // TODO: signal subscribers...
            }
        }
        else static if (is(T E == enum) && isSomeInt!E)
            value(cast(int)v);
        else static if (isSomeInt!T)
            value(cast(int)v);
        else static if (isSomeFloat!T)
            value(cast(float)v);
        else
            static assert(false, "Not implemented");
    }
}
