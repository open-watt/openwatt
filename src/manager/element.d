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
import manager.id;
import manager.subscriber;

nothrow @nogc:


alias EID = ID!0;

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


void init_elements()
{
    element_table().init();
}

String get_id(EID id)
{
    if (auto e = element_table.find_entry(id))
        return id_table().get_string(e.name);
    return String();
}

Element* get_element(EID id) pure
    => element_table().get(id);

Element* get_element_by_name(const(char)[] id) pure
    => element_table().get_by_name(id);


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


private:

__gshared ElementTable g_elem_table;

ref ElementTable element_table() pure
{
    static ElementTable* hack() => &g_elem_table;
    return *(cast(ElementTable* function() pure nothrow @nogc)&hack)();
}


struct ElementTable
{
    import urt.mem;
nothrow @nogc:

    struct Entry
    {
        EID id;
        uint name;  // 0 = empty slot
        Element* value;

        bool empty() const pure nothrow @nogc
            => !name;
    }

    void init()
    {
        // TODO: THIS SHOULD BE ALLOCATED IN FAST MEMORY!
        _slots = cast(Entry*)malloc(16 * Entry.sizeof);
        _slots[0] = Entry(EID(0), 2, null);
        _slots[1 .. 16] = Entry.init;
        _mask = 15;
        ++_count;
    }

    inout(Element)* get(EID id) inout pure
    {
        debug assert(_slots !is null);
        uint idx = id.raw & _mask;
        for (uint i = 0; i <= _mask; ++i)
        {
            if (_slots[idx].empty)
                return null;
            if (_slots[idx].id == id)
                return _slots[idx].value;
            idx = (idx + 1) & _mask;
        }
        return null;
    }

    inout(Element)* get_by_name(const(char)[] name) inout pure
    {
        debug assert(_slots !is null);
        EID id = hash_id!EID(name);
        for (uint d = 0; d <= _max_depth; ++d)
        {
            auto entry = find_entry(id);
            if (entry && id_table.get_dstring(entry.name)[] == name[])
                return entry.value;
            id = rehash(id);
        }
        return null;
    }

    EID get_id(const(char)[] name) const pure
    {
        debug assert(_slots !is null);
        EID id = hash_id!EID(name);
        for (uint d = 0; d <= _max_depth; ++d)
        {
            auto entry = find_entry(id);
            if (entry && id_table.get_dstring(entry.name)[] == name[])
                return id;
            id = rehash(id);
        }
        return EID.invalid;
    }

    EID insert(const(char)[] name, Element* value)
    {
        maybe_grow();

        EID id = hash_id!EID(name);
        uint depth = 0;

        while (true)
        {
            auto entry = find_entry(id);
            if (entry !is null)
            {
                if (id_table.get_dstring(entry.name)[] == name[])
                    return EID.invalid;  // duplicate

                id = .rehash(id);
                ++depth;
                continue;
            }

            uint idx = id.raw & _mask;
            while (!_slots[idx].empty)
                idx = (idx + 1) & _mask;

            _slots[idx] = Entry(id, id_table.insert(name), value);
            ++_count;
            if (depth > _max_depth)
                _max_depth = depth;
            return id;
        }
    }

    bool remove(EID id)
    {
        debug assert(_slots !is null);
        uint idx = id.raw & _mask;
        for (uint i = 0; i <= _mask; ++i)
        {
            if (_slots[idx].empty)
                return false;
            if (_slots[idx].id == id)
            {
                _slots[idx].value = null;
                return true;
            }
            idx = (idx + 1) & _mask;
        }
        return false;
    }

    bool rekey(EID old_id, EID new_id)
    {
        debug assert(_slots !is null);
        uint idx = old_id.raw & _mask;
        for (uint i = 0; i <= _mask; ++i)
        {
            if (_slots[idx].empty)
                return false;
            if (_slots[idx].id == old_id)
            {
                Entry e = _slots[idx];
                remove_and_repair(idx);
                e.id = new_id;
                uint new_idx = new_id.raw & _mask;
                while (!_slots[new_idx].empty)
                    new_idx = (new_idx + 1) & _mask;
                _slots[new_idx] = e;
                return true;
            }
            idx = (idx + 1) & _mask;
        }
        return false;
    }

    uint count() const pure => _count;
    uint max_depth() const pure => _max_depth;

    int opApply(scope int delegate(ref Entry) nothrow @nogc dg)
    {
        foreach (ref e; _slots[0 .. _mask + 1])
            if (!e.empty)
                if (auto r = dg(e))
                    return r;
        return 0;
    }

private:
    Entry* _slots;
    uint _mask;
    uint _count;
    uint _max_depth;

    inout(Entry)* find_entry(EID id) inout pure
    {
        uint idx = id.raw & _mask;
        for (uint i = 0; i <= _mask; ++i)
        {
            if (_slots[idx].empty)
                return null;
            if (_slots[idx].id == id)
                return &_slots[idx];
            idx = (idx + 1) & _mask;
        }
        return null;
    }

    void remove_and_repair(uint idx)
    {
        _slots[idx] = Entry.init;
        uint next = (idx + 1) & _mask;
        while (!_slots[next].empty)
        {
            uint natural = _slots[next].id.raw & _mask;
            if ((next > idx && (natural <= idx || natural > next)) ||
                (next < idx && (natural <= idx && natural > next)))
            {
                _slots[idx] = _slots[next];
                _slots[next] = Entry.init;
                idx = next;
            }
            next = (next + 1) & _mask;
        }
    }

    void maybe_grow()
    {
        if (_count * 10 > (_mask + 1) * 7)
            rebuild((_mask + 1) * 2);
    }

    void rebuild(uint new_size)
    {
        auto old = _slots;
        uint old_size = _mask + 1;
        _slots = cast(Entry*)malloc(new_size * Entry.sizeof);
        _slots[0 .. new_size] = Entry.init;
        _mask = new_size - 1;
        _count = 0;

        foreach (ref e; old[0 .. old_size])
        {
            if (!e.empty)
            {
                uint idx = e.id.raw & _mask;
                while (!_slots[idx].empty)
                    idx = (idx + 1) & _mask;
                _slots[idx] = e;
                ++_count;
            }
        }
        free(old);
    }
}
