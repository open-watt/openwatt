module manager.collection;

import urt.array;
import urt.attribute : fast_data;
import urt.lifetime;
import urt.mem.allocator;
import urt.result;
import urt.string;
import urt.time : Duration, MonoTime, getTime;

import manager.id;

public import manager.base;
public import manager.expression : NamedArgument;

nothrow @nogc:


alias CID = ID!6;

enum CollectionType : ubyte
{
    aa55,
    api,
    binding, // all protocol bindings
    ble_client,
    certificate,
    dhcp_client,
    dhcp_lease,
    dhcp_option,
    dhcp_server,
    dns_server,
    esphome,
    ezsp,
    http_client,
    http_server,
    http_static,
    interface_, // all interfaces
    interface_group,
    ip_address,
    ip_pool,
    ip_pool6,
    ip_route,
    mb_node,
    mqtt_broker,
    mqtt_client,
    ntp_client,
    ota,
    pcap_server,
    ppp_server,
    pppoe_server,
    recorder,
    secret,
    snmp_agent,
    snmp_client,
    spinel,
    stream, // all streams
    sync_channel,
    sync_peer,
    sync_ws_server,
    tcp_server,
    tls_server,
    ws_server,
    zb_controller,
    zb_endpoint,
    zigbee, // node, router, coordinator
    automation,
    device, // NOT BaseObjects: the device type's table is g_app.devices, sharing the CID space
    count
}

const(char)[] get_id_dstring(CID id) pure
    => item_table(id.type_index).name_of(id);

String get_id(CID id) pure
    => item_table(id.type_index).name_string(id);

BaseObject get_item(CID id) pure
{
    return item_table(id.type_index).get(id);
}

Item get_item(Item : BaseObject)(CID id) pure
    if (!is(Item == BaseObject))
{
    assert(id.type_index == Item.collection_id);
    BaseObject item = item_table(Item.collection_id).get(id);
    return cast(Item)item; // TODO: this is a D dynamic cast, but we could check our own typeinfo
}

Item get_item_by_name(Item : BaseObject)(const(char)[] id) pure
    if (!is(Item == BaseObject))
{
    BaseObject item = item_table(Item.collection_id).get_by_name(id, Item.collection_id);
    return cast(Item)item; // TODO: this is a D dynamic cast, but we could check our own typeinfo
}

private const(CollectionTypeInfo)* collection_super_getter(Type)() nothrow @nogc
    => collection_type_info!Type();

const(CollectionTypeInfo)* collection_type_info(Type)() nothrow @nogc
{
    static if (!is(typeof(Type.type_name)))
        return null; // Type.type_name must be defined
    else
    {
        import urt.mem.allocator;

        static if (__traits(isAbstractClass, Type))
            enum create_instance = null;
        else
        {
            static create(ref BaseCollection c, CID id, ObjectFlags flags)
            {
                return defaultAllocator.allocT!Type(id, flags);
            }
            enum create_instance = &create;
        }

        alias Root = CollectionRoot!Type;
        static if (!is(Type == Root))
            enum CollectionTypeInfo.GetSuperFn get_super_fn = &collection_super_getter!(CollectionSuper!Type);
        else
            enum CollectionTypeInfo.GetSuperFn get_super_fn = null;

        static if (is(typeof(Type.path) : const(char)[]))
            enum _path = Type.path;
        else
            enum _path = null;

        static if (is(typeof(Type.syncable) : bool))
            enum bool _syncable = Type.syncable;
        else
            enum bool _syncable = true;

        __gshared const CollectionTypeInfo ti = CollectionTypeInfo(StringLit!(Type.type_name),
                                                                   StringLit!_path,
                                                                   Type.collection_id,
                                                                   all_properties!Type(),
                                                                   create_instance,
                                                                   get_super_fn,
                                                                   _syncable);
        return &ti;
    }
}

struct CollectionTypeInfo
{
    alias CreateFun = BaseObject function(ref BaseCollection collection, CID id, ObjectFlags flags = ObjectFlags.none) nothrow @nogc;
    alias GetSuperFn = const(CollectionTypeInfo)* function() nothrow @nogc;

    String type;
    String path;
    CollectionType collection_id;
    const(Property*)[] properties;
    CreateFun create;
    GetSuperFn get_super;
    bool syncable = true;

    bool is_abstract() const pure nothrow @nogc
        => create is null;
}

struct BaseCollection
{
nothrow @nogc:
    const CollectionTypeInfo* type_info;

    CID allocate_id(const(char)[] name)
        => item_table(type_info.collection_id).allocate(name, type_info.collection_id);

    BaseObject create(const(char)[] name, ObjectFlags flags = ObjectFlags.none, in NamedArgument[] named_args...)
    {
        BaseObject item = alloc(name, flags);
        if (!item)
            return null;

        foreach (ref arg; named_args)
        {
            debug assert(arg.name[] != "name", "Can't set name via named argument");
            StringResult result = item.set(arg.name, arg.value);
            if (!result)
            {
                defaultAllocator.freeT(item);
                return null;
            }
        }
        add(item);

        // HACK: advance the state machine synchronously so subsequent script lines
        // have a chance to work when the early startup creates things.
        // this should be removed, and replaced by a more comprehensive latent startup tolerance.
        if (auto active = cast(ActiveObject)item)
            active.do_update();

        return item;
    }

    ref CollectionTable table() pure
        => item_table(type_info.collection_id);

    uint item_count()
    {
        ref t = table;
        uint n = 0;
        for (uint slot = 1; slot <= t.slot_count; ++slot)
        {
            BaseObject o = t.at(slot);
            if (o !is null && type_matches(type_info, o._typeInfo))
                ++n;
        }
        return n;
    }

    void update_all()
    {
        assert(type_info.get_super is null, "update_all should only be called on root collections");

        enum SlowObjectUpdateMs = 50;
        ref t = table;
        // slots are stable and append-only, so items added mid-update are reached too
        for (uint slot = 1; slot <= t.slot_count; ++slot)
        {
            if (auto active = cast(ActiveObject)t.at(slot))
            {
                MonoTime start = getTime();
                active.do_update();
                Duration d = getTime() - start;
                if (d.as!"msecs" >= SlowObjectUpdateMs)
                {
                    import urt.log : writeWarning;
                    writeWarning("collection.update.", type_info.type[], ".", active.name[],
                                 ": ", d.as!"msecs", "ms");
                }
            }
        }

        t.free_pending();
    }

    BaseObject alloc(const(char)[] name, ObjectFlags flags = ObjectFlags.none)
    {
        assert(type_info, "Can't create into a base collection!");
        if (!name)
            name = generate_name(type_info.type[]);
        CID id = allocate_id(name);
        if (!id)
            return null;
        // Note: entry.value stays null until add() installs and announces.
        return type_info.create(this, id, flags);
    }

    void add(BaseObject item)
    {
        assert(cast(bool)item._id, "item must have a valid CID");
        table.bind(item._id, item);
        signal_object_lifecycle(item, ObjectLifecycleEvent.created);
    }

    void remove(BaseObject item)
    {
        if (item._id)
            table.remove(item._id);
    }

    BaseObject get(const(char)[] name)
    {
        BaseObject obj = table.get_by_name(name, type_info.collection_id);
        if (obj !is null && !type_matches(type_info, obj._typeInfo))
            return null;
        return obj;
    }

    auto keys()
    {
        struct Range
        {
        nothrow @nogc:
            CollectionTable* table;
            const(CollectionTypeInfo)* filter;
            uint slot;
            bool empty() const pure => slot > table.slot_count;
            String front() => table.name_at(slot);
            void popFront() { ++slot; advance(); }
            private void advance()
            {
                for (; slot <= table.slot_count; ++slot)
                {
                    BaseObject o = table.at(slot);
                    if (o !is null && type_matches(filter, o._typeInfo))
                        return;
                }
            }
        }
        auto r = Range(&table(), type_info, 1);
        r.advance();
        return r;
    }

    auto values()
    {
        struct Range
        {
        nothrow @nogc:
            CollectionTable* table;
            const(CollectionTypeInfo)* filter;
            uint slot;
            bool empty() const pure => slot > table.slot_count;
            BaseObject front() pure => table.at(slot);
            void popFront() { ++slot; advance(); }
            private void advance()
            {
                for (; slot <= table.slot_count; ++slot)
                {
                    BaseObject o = table.at(slot);
                    if (o !is null && type_matches(filter, o._typeInfo))
                        return;
                }
            }
        }
        auto r = Range(&table(), type_info, 1);
        r.advance();
        return r;
    }

    const(char)[] generate_name(const(char)[] prefix)
    {
        import urt.mem.temp : tconcat;

        assert(prefix !is null);

        ref t = table;
        if (t.get_by_name(prefix, type_info.collection_id) is null)
            return prefix;
        for (size_t i = 1; i < ushort.max; i++)
        {
            const(char)[] name = tconcat(prefix, i);
            if (t.get_by_name(name, type_info.collection_id) is null)
                return name;
        }
        return null;
    }
}

struct Collection(Type)
{
nothrow @nogc:
    static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

    @property BaseCollection _base() const nothrow @nogc
        => BaseCollection(collection_type_info!Type());
    alias _base this;

    Type create(const(char)[] name, ObjectFlags flags = ObjectFlags.none, in NamedArgument[] named_args...)
    {
        return cast(Type)_base.create(name, flags, named_args);
    }

    Type alloc(const(char)[] name, ObjectFlags flags = ObjectFlags.none)
    {
        return cast(Type)_base.alloc(name, flags);
    }

    void add(Type item)
        => _base.add(item);

    Type get(const(char)[] name)
        => cast(Type)_base.get(name);

    // iterate live objects of Type and all derived types
    auto values()
    {
        struct Range
        {
        nothrow @nogc:
            CollectionTable* table;
            const(CollectionTypeInfo)* filter;
            uint slot;

            bool empty() const pure
                => slot > table.slot_count;

            Type front() pure
                => cast(Type)cast(void*)table.at(slot);

            void popFront()
            {
                ++slot;
                advance();
            }

            void advance()
            {
                for (; slot <= table.slot_count; ++slot)
                {
                    BaseObject o = table.at(slot);
                    if (o !is null && type_matches(filter, o._typeInfo))
                        return;
                }
            }
        }

        auto r = Range(&_base.table(), _base.type_info, 1);
        r.advance();
        return r;
    }

    static if (is(Type : ActiveObject) && is(typeof((Type t) => t.heartbeat(MonoTime.init))))
    {
        void heartbeat(MonoTime now)
        {
            foreach (obj; values)
                if (obj.running)
                    obj.heartbeat(now);
        }
    }
}

bool type_matches(const(CollectionTypeInfo)* filter, const(CollectionTypeInfo)* element_type) nothrow @nogc
{
    for (const(CollectionTypeInfo)* ti = element_type; ti !is null; ti = ti.get_super ? ti.get_super() : null)
        if (ti is filter)
            return true;
    return false;
}

private template BaseClassOf(T)
{
    static if (is(T Bases == super))
        alias BaseClassOf = Bases[0];
    else
        alias BaseClassOf = void;
}

template CollectionRoot(T)
{
    alias Super = BaseClassOf!T;
    static if (!is(Super == BaseObject) && !is(Super == void) && is(typeof(Super.collection_id)) && Super.collection_id == T.collection_id)
        alias CollectionRoot = CollectionRoot!Super;
    else
        alias CollectionRoot = T;
}

template CollectionSuper(T)
{
    alias Super = BaseClassOf!T;
    static if (!is(Super == BaseObject) && !is(Super == void) && is(typeof(Super.collection_id)) && Super.collection_id == T.collection_id)
        alias CollectionSuper = Super;
    else
        static assert(false, T.stringof ~ " has no collection super type");
}


enum ObjectLifecycleEvent : ubyte
{
    created,
    destroyed,
}

alias ObjectLifecycleHandler = void delegate(BaseObject obj, ObjectLifecycleEvent event) nothrow @nogc;

void register_object_lifecycle_handler(ObjectLifecycleHandler handler) nothrow @nogc
{
    _on_object_lifecycle ~= handler;
}

void foreach_object(scope void delegate(BaseObject obj) nothrow @nogc fn)
{
    foreach (ref table; g_item_tables)
        for (uint slot = 1; slot <= table.slot_count; ++slot)
            if (BaseObject o = table.at(slot))
                fn(o);
}


private:

// HACK: is this satisfactory?
__gshared Array!ObjectLifecycleHandler _on_object_lifecycle;

@fast_data __gshared CollectionTable[CollectionType.count] g_item_tables;

package void signal_object_lifecycle(BaseObject obj, ObjectLifecycleEvent event) nothrow @nogc
{
    foreach (h; _on_object_lifecycle[])
        h(obj, event);
}

package ref CollectionTable item_table(uint collection) pure
{
    static CollectionTable* hack(uint i) => &g_item_tables[i];
    return *(cast(CollectionTable* function(uint i) pure nothrow @nogc)&hack)(collection);
}

struct CollectionTable
{
nothrow @nogc:

    inout(BaseObject) get(CID id) inout pure
        => _machine.get(id.slot);

    BaseObject deref(ref CID id)
    {
        uint slot = id.slot;
        BaseObject o = _machine.deref(slot);
        if (slot != id.slot)
            id = make_cid(id.type_index, slot);
        return o;
    }

    inout(BaseObject) get_by_name(const(char)[] name, ubyte type_idx) inout pure
        => _machine.get(_machine.find(name));

    CID get_id(const(char)[] name, ubyte type_idx) const pure
    {
        uint slot = _machine.find(name);
        return slot ? make_cid(type_idx, slot) : CID.invalid;
    }

    CID reserve(const(char)[] name, ubyte type_idx)
        => make_cid(type_idx, _machine.reserve(name));

    CID allocate(const(char)[] name, ubyte type_idx)
    {
        uint slot = _machine.reserve(name);
        if (_machine.get(slot) !is null)
            return CID.invalid;
        return make_cid(type_idx, slot);
    }

    package void bind(CID id, BaseObject value)
        => _machine.bind(id.slot, value);

    bool rename(CID id, const(char)[] old_name, const(char)[] new_name)
        => _machine.rename(id.slot, old_name, new_name);

    bool remove(CID id)
    {
        uint slot = id.slot;
        if (_machine.deref(slot) is null)
            return false;
        _machine.release(slot);
        return true;
    }

    const(char)[] name_of(CID id) const pure
        => _machine.name_of(id.slot);

    String name_string(CID id) const pure
        => _machine.name_string(id.slot);

    uint slot_count() const pure
        => _machine.slot_count();

    inout(BaseObject) at(uint slot) inout pure
        => _machine.at(slot);

    String name_at(uint slot) const pure
        => _machine.name_string(slot);

    package void defer_free(BaseObject item)
    {
        uint slot = item._id.slot;
        debug assert(_machine.get(slot) is item, "defer_free on stray or already-freed object");
        _machine.release(slot);
        _pending_free ~= item;
    }

    package void free_pending()
    {
        foreach (item; _pending_free)
            defaultAllocator.freeT(item);
        _pending_free.clear();
    }

private:
    IdAllocator!BaseObject _machine;
    Array!BaseObject _pending_free;
}

package(manager) CID make_cid(uint type_idx, uint slot) pure
{
    debug assert(slot && slot <= CID.id_mask, "invalid collection slot");
    return CID((type_idx << CID.id_bits) | slot);
}
