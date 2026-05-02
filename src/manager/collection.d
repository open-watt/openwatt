module manager.collection;

import urt.array;
import urt.lifetime;
import urt.mem.allocator;
import urt.result;
import urt.string;

import manager.id;

public import manager.base;
public import manager.expression : NamedArgument;

nothrow @nogc:


alias CID = ID!6;

enum CollectionType : ubyte
{
    aa55,
    api,
    ble_client,
    certificate,
    cron_job,
    dhcp_client,
    dhcp_lease,
    dhcp_option,
    dhcp_server,
    dns_server,
    esphome,
    ezsp,
    http_client,
    http_server,
    interface_, // all interfaces
    interface_group,
    ip_address,
    ip_pool,
    ip_pool6,
    ip_route,
    mb_client,
    mqtt_broker,
    pcap_server,
    ppp_server,
    pppoe_server,
    secret,
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
    count
}

const(char)[] get_id_dstring(CID id) pure
{
    if (auto e = item_table(id.type_index).find_entry(id))
        return id_table().get_dstring(e.name);
    return null;
}

String get_id(CID id) pure
{
    if (auto e = item_table(id.type_index).find_entry(id))
        return id_table().get_string(e.name);
    return String();
}

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
    BaseObject item = item_table(Item.collection_id).get_by_name(id);
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
        => item_table(type_info.collection_id).insert(name, type_info.collection_id, null);

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

        return item;
    }

    ref CollectionTable table() pure
        => item_table(type_info.collection_id);

    uint item_count()
    {
        uint n = 0;
        foreach (ref e; table._entries)
            if (e.value !is null && type_matches(type_info, e.value._typeInfo))
                ++n;
        return n;
    }

    void update_all()
    {
        assert(type_info.get_super is null, "update_all should only be called on root collections");

        size_t i = 0;
        outer: while (i < table._entries.length)
        {
            CID just_processed = table._entries[i].id;
            if (auto active = cast(ActiveObject)table._entries[i].value)
                active.do_update();

            // skip to the entry after the one we just did (array may have grown)
            while (table._entries[i++].id != just_processed)
            {
                if (i >= table._entries.length)
                    break outer;
            }
        }

        table.free_pending();
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
        auto entry = table.find_entry(item._id);
        assert(entry !is null, "CID not in table");
        debug assert(entry.value is null, "add() called twice!");
        entry.value = item;
        signal_object_created(item);
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
            CollectionTable.Entry[] entries;
            const(CollectionTypeInfo)* filter;
            bool empty() const pure => entries.length == 0;
            String front() => id_table().get_string(entries[0].name);
            void popFront() { entries = entries[1 .. $]; advance(); }
            private void advance()
            {
                while (entries.length > 0 && (entries[0].value is null || !type_matches(filter, entries[0].value._typeInfo)))
                    entries = entries[1 .. $];
            }
        }
        auto r = Range(table._entries[], type_info);
        r.advance();
        return r;
    }

    auto values()
    {
        struct Range
        {
        nothrow @nogc:
            CollectionTable.Entry[] entries;
            const(CollectionTypeInfo)* filter;
            bool empty() const pure => entries.length == 0;
            BaseObject front() pure => entries[0].value;
            void popFront() { entries = entries[1 .. $]; advance(); }
            private void advance()
            {
                while (entries.length > 0 && (entries[0].value is null || !type_matches(filter, entries[0].value._typeInfo)))
                    entries = entries[1 .. $];
            }
        }
        auto r = Range(table._entries[], type_info);
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
            CollectionTable.Entry[] entries;
            const(CollectionTypeInfo)* filter;

            bool empty() const pure
                => entries.length == 0;

            Type front() pure
                => cast(Type)entries[0].value;

            void popFront()
            {
                entries = entries[1 .. $];
                advance();
            }

            void advance()
            {
                while (entries.length > 0 && (entries[0].value is null || !type_matches(filter, entries[0].value._typeInfo)))
                    entries = entries[1 .. $];
            }
        }

        auto r = Range(_base.table._entries[], _base.type_info);
        r.advance();
        return r;
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


void broadcast_rekey(CID old_id, CID new_id)
{
    foreach (ref table; g_item_tables)
        foreach (ref e; table._entries)
            if (e.value !is null)
                e.value.do_rekey(old_id, new_id);
}

alias ObjectLifecycleHandler = void delegate(BaseObject obj) nothrow @nogc;

void register_object_created_handler(ObjectLifecycleHandler handler) nothrow @nogc
{
    _on_object_created ~= handler;
}

void foreach_object(scope void delegate(BaseObject obj) nothrow @nogc fn)
{
    foreach (ref table; g_item_tables)
        foreach (ref e; table._entries)
            if (e.value !is null)
                fn(e.value);
}


mixin template RekeyHandler()
{
    import manager.collection : CID, has_cid, rekey_field;

    protected override void rekey(CID old_id, CID new_id)
    {
        super.rekey(old_id, new_id);

        alias Self = typeof(this);
        static foreach (field; __traits(derivedMembers, Self))
        {
            static if (__traits(compiles, &__traits(getMember, this, field)))
            {{
                alias Ty = typeof(__traits(getMember, this, field));
                static if (has_cid!Ty)
                    __traits(getMember, this, field).rekey_field(old_id, new_id);
            }}
        }
    }
}

template has_cid(T)
{
    static if (is(T == CID))
        enum has_cid = true;
    else static if (is(T == struct))
    {
        alias has = void;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (has_cid!(typeof(T.tupleof[i])))
                has = int;
        }
        enum has_cid = is(has == int);
    }
    else static if (is(T == E[], E))
        enum has_cid = has_cid!E;
    else static if (is(T == Array!E, E))
        enum has_cid = has_cid!E;
    else
        enum has_cid = false;
}

void rekey_field(T)(ref T field, CID old_id, CID new_id)
{
    static if (is(T == CID))
    {
        if (field == old_id)
            field = new_id;
    }
    else static if (is(T == struct))
    {
        static foreach (i; 0 .. T.tupleof.length)
            static if (has_cid!(typeof(T.tupleof[i])))
                rekey_field(field.tupleof[i], old_id, new_id);
    }
    else static if (is(T == E[], E))
    {
        foreach (ref e; field)
            rekey_field(e, old_id, new_id);
    }
    else static if (is(T == Array!E, E))
    {
        foreach (ref e; field[])
            rekey_field(e, old_id, new_id);
    }
}


private:

// HACK: is this satisfactory?
__gshared Array!ObjectLifecycleHandler _on_object_created;

__gshared CollectionTable[CollectionType.count] g_item_tables;

package void init_collections()
{
    foreach (ref t; g_item_tables)
        t.init();
}

void signal_object_created(BaseObject obj) nothrow @nogc
{
    foreach (h; _on_object_created[])
        h(obj);
}

package ref CollectionTable item_table(uint collection) pure
{
    static CollectionTable* hack(uint i) => &g_item_tables[i];
    return *(cast(CollectionTable* function(uint i) pure nothrow @nogc)&hack)(collection);
}

struct CollectionTable
{
    import urt.algorithm : binary_search;
nothrow @nogc:

    struct Entry
    {
        CID id;
        uint name;
        BaseObject value;
    }

    void init()
    {
        insert(0, Entry(CID(0), 2, null));
    }

    inout(BaseObject) get(CID id) inout pure
    {
        if (auto e = find_entry(id))
            return e.value;
        return null;
    }

    inout(BaseObject) get_by_name(const(char)[] name, ubyte type_idx) inout pure
    {
        CID id = hash_id!CID(name, type_idx);
        for (uint d = 0; d <= _max_depth; ++d)
        {
            if (auto e = find_entry(id))
            {
                if (id_table().get_dstring(e.name)[] == name[])
                    return e.value;
            }
            id = rehash(id);
        }
        return null;
    }

    CID get_id(const(char)[] name, ubyte type_idx) const pure
    {
        CID id = hash_id!CID(name, type_idx);
        for (uint d = 0; d <= _max_depth; ++d)
        {
            if (auto e = find_entry(id))
            {
                if (id_table().get_dstring(e.name)[] == name[])
                    return id;
            }
            id = .rehash(id);
        }
        return CID.invalid;
    }

    CID insert(const(char)[] name, ubyte type_idx, BaseObject value)
    {
        CID id = hash_id!CID(name, type_idx);
        uint depth = 0;

        while (true)
        {
            auto idx = find_insert_pos(id);
            if (idx < _entries.length && _entries[idx].id == id)
            {
                if (id_table().get_dstring(_entries[idx].name)[] == name[])
                {
                    assert(_entries[idx].value is null, "Item already exists!");
                    _entries[idx].value = value;
                    return id;
                }

                id = rehash(id);
                ++depth;
                continue;
            }

            insert(idx, Entry(id, id_table().insert(name), value));
            if (depth > _max_depth)
                _max_depth = depth;
            return id;
        }
    }

    bool remove(CID id)
    {
        if (auto e = find_entry(id))
        {
            e.value = null; // tombstone
            return true;
        }
        return false;
    }

    bool rekey(CID old_id, CID new_id)
    {
        assert(old_id.type_index == new_id.type_index, "rekey across different collection types");
        auto idx = binary_search!_cmp_id(_entries[], old_id);
        if (idx >= _entries.length)
            return false;

        Entry e = _entries[idx];
        _entries.remove(idx);
        e.id = new_id;
        auto new_idx = find_insert_pos(new_id);
        insert(new_idx, e);
        return true;
    }

    uint count() const pure => cast(uint)_entries.length;
    uint max_depth() const pure => _max_depth;

    package void defer_free(BaseObject item)
    {
        auto entry = find_entry(item._id);
        assert(entry !is null && entry.value is item, "defer_free on stray or already-freed object");
        entry.value = null;
        _pending_free ~= item;
    }

    package void free_pending()
    {
        foreach (item; _pending_free)
            defaultAllocator.freeT(item);
        _pending_free.clear();
    }

private:
    Array!Entry _entries; // sorted by id
    Array!BaseObject _pending_free;
    uint _max_depth;

    static long _cmp_id(ref const Entry e, CID id) pure
        => e.id.opCmp(id);

    inout(Entry)* find_entry(CID id) inout pure
    {
        auto idx = binary_search!_cmp_id(_entries[], id);
        if (idx < _entries.length)
            return &_entries.ptr[idx];
        return null;
    }

    size_t find_insert_pos(CID id) const pure
        => binary_search!(_cmp_id, true)(_entries[], id);

    void insert(size_t at, ref Entry e)
    {
        import urt.mem : memmove;
        // TODO: add an insert function!
        size_t tail = _entries.length - at;
        _entries.resize(_entries.length + 1);
        if (tail > 0)
            memmove(&_entries[at + 1], &_entries[at], Entry.sizeof * tail);
        _entries.opIndex(at) = e;
    }
}
