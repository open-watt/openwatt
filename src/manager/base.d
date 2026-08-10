module manager.base;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta;
import urt.meta.enuminfo : bitfield;
import urt.mem.alloc : alloc, free;
import urt.mem.string;
import urt.mem.temp;
import urt.variant;
import urt.result;
import urt.string;
import urt.time;
import urt.traits : Parameters, ReturnType, Unqual;
import urt.util : min;

import manager.console.argument;
import manager.element : Access, Element, SampleUpdate, SamplingMode;
import manager.id;
import manager.series : DataFormat, FormatId, register_format, SeriesKind, valid, ValueType;
import manager.value;

public import manager.collection : CID, Collection, CollectionType, collection_type_info, CollectionTypeInfo;

//version = TraceLifetimeSubscriptions;

//version = DebugStateFlow;
enum DebugType = null;

nothrow @nogc:


// ============================================================================
// TODO (high priority): startup-latency / pending-reference system
// ============================================================================
// Today, when startup.conf creates an object on one line and references it on
// the next, the second line will fail unless the first object has already
// reached Running. We currently paper over this in
// `manager/console/collection_commands.d` (CollectionAddCommand.execute) by
// synchronously ticking the state machine of every newly-created ActiveObject
// — see the "HACK: synchronous state-machine tick" block there.
//
// That fix only works for one-tick startups; anything that waits on a
// dependency (return CompletionStatus.continue_ from startup) still races the
// next script line. It also gives every object an extra synchronous tick at
// construction time, which is surprising for code running in startup() or
// update().
//
// The proper fix lives close to ObjectRef and the property/argument plumbing:
// when a property setter takes a name that resolves to nothing, we should
// retain the unresolved name and have the relevant Collection wake the
// pending reference up when the named target is created. ObjectRef already
// supports detached state and try_reattach() — we just need creation to
// notify pending refs rather than relying on synchronous ordering.
//
// Until that lands, do NOT add code paths that depend on construction
// ordering at script-execution time, and do NOT rely on the synchronous tick
// in collection_commands.d as a load-bearing mechanism.
// ============================================================================


@bitfield enum ObjectFlags : ubyte
{
    none         = 0,
    dynamic      = 1 << 0, // D
    temporary    = 1 << 1, // T
    disabled     = 1 << 2, // X
    invalid      = 1 << 3, // I
    running      = 1 << 4, // R
    slave        = 1 << 5, // S
    link_present = 1 << 6, // L
    hardware     = 1 << 7, // H

    remote       = 1 << 4, // HACK for construction
}

enum CompletionStatus
{
    continue_,
    complete,
    error = -1,
}

enum StateSignal
{
    online,
    offline,
    destroyed
}

alias StateSignalHandler = void delegate(ActiveObject object, StateSignal signal) nothrow @nogc;

enum ushort sync_slot_none = ushort.max;


template Prop(string name, alias member, string category = null, string flags = null)
{
    enum n = name;
    alias p = member;
    enum c = category;
    enum f = flags;
}

template Elem(string name, PropType, options...)
{
    enum is_elem = true;
    enum n = name;
    alias T = PropType;
    alias opts = options;
}

// no Step: Constraint.check honours min/max and check_fn only, so a declared step would not validate
template Default(alias v)   { enum kind = "default";   alias value = v; }
template Min(alias v)       { enum kind = "min";       alias value = v; }
template Max(alias v)       { enum kind = "max";       alias value = v; }
template Check(alias f)     { enum kind = "check";     alias fn = f; }
struct ReadOnly             { enum kind = "read_only"; }
template OnChange(alias f)  { enum kind = "on_change"; alias fn = f; }
template Category(string s) { enum kind = "category";  enum value = s; }
template PropFlags(string s){ enum kind = "flags";     enum value = s; }

struct Property
{
    alias GetFun = Variant function(BaseObject i, ref const Property p) nothrow @nogc;
    alias SetFun = StringResult function(ref const Variant value, BaseObject i, ref const Property p) nothrow @nogc;
    alias ResetFun = void function(BaseObject i) nothrow @nogc;
    alias DefaultFun = Variant function() nothrow @nogc;
    alias SuggestFun = Array!String function(const(char)[] arg) nothrow @nogc;
    alias FormatFun = FormatId function() nothrow @nogc;
    alias ChangeFun = void function(BaseObject i, ref const SampleUpdate u) nothrow @nogc;
    alias CheckFun = const(char)[] function(void* value) nothrow @nogc; // value is a `ref T` of the declared type

    String name;
    String[2] type; // up to 2 types (sometimes like enum + string, or enum + int)
    String category;
    GetFun get;
    SetFun set;
    DefaultFun init_val;
    SuggestFun suggest;
    FormatFun elem_format;  // non-null = element-backed; interns the format on first call
    ChangeFun on_change;
    CheckFun check;
    ushort index;           // == element slot in the property block
    ubyte flags;
    // not `set is null` like a legacy read-only property: the owner still writes through it
    bool read_only;

    static Property create(string name, alias member, string category = null, string flags = null)()
    {
        alias Type = __traits(parent, member);
        static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

        Property prop;
        prop.name = StringLit!name;
        prop.category = category ? StringLit!category : String();
        prop.flags = parse_prop_flags(flags);

        alias Getters = FilterOverloads!(IsGetter, member);
        alias Setters = FilterOverloads!(IsSetter, member);
        alias Suggests = FilterOverloads!(HasSuggest, member);

        // synthesise getter
        static if (Getters.length > 0)
        {
            prop.get = &SynthGetter!Getters;

            // if there are no setters, we'll derive the property type from the getter
            static if (Setters.length == 0)
            {{
                enum type = type_for!(ReturnType!(Getters[0]));
                static if (type)
                    prop.type[0] = StringLit!type;
            }}

            // default value reflects what get() returns on a freshly-constructed
            // object, derived from the getter's return type's init value.
            prop.init_val = &SynthDefault!(Getters[0]);
        }

        // synthesise setter
        static if (Setters.length > 0)
        {
            prop.set = &SynthSetter!Setters;

            // collect property types from the setters
            size_t num_types = 0;
            static foreach (Setter; Setters)
            {{
                enum type = type_for!(Parameters!Setter[0]);
                static if (type)
                    prop.type[num_types++] = StringLit!type;
            }}
            debug assert(num_types != 0, "Couldn't determine type for setter overloads of property '" ~ name ~ "'; please specify the type(s) manually");
        }

        // synthesise suggest
        static if (Suggests.length > 0)
            prop.suggest = &SynthSuggest!Suggests;

        return prop;
    }

    static Property create_elem(alias Decl, size_t index)()
    {
        alias T = Decl.T;

        Property prop;
        prop.name = StringLit!(Decl.n);

        alias Cat = FindElemOpt!("category", Decl.opts);
        static if (Cat.length)
            prop.category = StringLit!(Cat[0].value);

        alias Fl = FindElemOpt!("flags", Decl.opts);
        static if (Fl.length)
            prop.flags = parse_prop_flags(Fl[0].value);

        prop.read_only = FindElemOpt!("read_only", Decl.opts).length != 0;

        enum type = type_for!T;
        static if (type)
            prop.type[0] = StringLit!type;

        prop.index = cast(ushort)index;
        prop.get = &elem_get;
        static if (is(T : BaseObject))
        {
            // reference: the boxed door already converts name <-> id at the edge, so the
            // by-name entry forwards the variant straight through
            static assert(FindElemOpt!("default", Decl.opts).length == 0 &&
                          FindElemOpt!("min", Decl.opts).length == 0 &&
                          FindElemOpt!("max", Decl.opts).length == 0 &&
                          FindElemOpt!("check", Decl.opts).length == 0,
                          "reference properties take no Default/Min/Max/Check");
            prop.set = &elem_ref_set;
        }
        else
            prop.set = &elem_set!T;
        prop.init_val = &ElemDefault!Decl;
        prop.elem_format = &ElemFormat!Decl;

        static if (is(typeof(suggest_completion!T)))
            prop.suggest = &suggest_completion!T;

        alias Chk = FindElemOpt!("check", Decl.opts);
        static if (Chk.length)
            prop.check = &CheckShim!(Chk[0].fn, T);

        alias Change = FindElemOpt!("on_change", Decl.opts);
        static if (Change.length)
            prop.on_change = &ElemOnChange!(Change[0].fn);

        return prop;
    }
}

struct SyncState
{
    Object channel;     // opaque owner identity (a SyncPeer, the kernel mirror, ...); compared by `is`, never dereferenced
    ulong props_dirty;
    ushort next;
}


class BaseObject
{
    alias Properties = AliasSeq!(Prop!("name", name, null, "*"),
                                 Prop!("type", type, null, "*"),
                                 Prop!("disabled", disabled, null, "h"),
                                 Prop!("comment", comment, null, "h"),
                                 Prop!("flags", flags, null, "*"));
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        assert(id, "must have a valid CID");
        assert((flags & ~(ObjectFlags.dynamic | ObjectFlags.temporary | ObjectFlags.disabled | ObjectFlags.remote)) == 0,
               "`flags` may only contain Dynamic, Temporary, Disabled, or Remote");

        debug foreach (i, p; type_info.properties)
            foreach (j; 0 .. i)
                assert(type_info.properties[j].name[] != p.name[], tconcat("Property '", p.name[], "' on ", type_info.type[], " shadows a base class property"));

        _typeInfo = type_info;
        _type = type_info.type[].addString();
        _id = id;

        if (flags & ObjectFlags.remote)
        {
            flags ^= ObjectFlags.remote;
            _is_remote = true;
        }
        _flags = flags;

        _props_set |= ulong(1) << prop_index!(typeof(this), "name") |
                      ulong(1) << prop_index!(typeof(this), "type") |
                      ulong(1) << prop_index!(typeof(this), "flags");

        build_prop_elements();
    }

    ~this()
    {
        if (!_prop_elements)
            return;
        foreach (i, p; _typeInfo.properties)
            if (p.elem_format)
                _prop_elements[i].teardown();
        free((cast(void*)_prop_elements)[0 .. _typeInfo.properties.length * Element.sizeof]);
        _prop_elements = null;
    }

    // Properties...

    final CID id() const pure
        => _id;

    final const(char)[] type() const pure
        => _type;

    final String name() const pure
    {
        static String _get_id(CID id)
        {
            import manager.collection : get_id;
            return get_id(id);
        }
        return (cast(String function(CID) pure nothrow @nogc)&_get_id)(_id);
    }
    final const(char)[] name(const(char)[] value)
    {
        import manager.collection : item_table;

        if (value.empty)
            return "`name` must not be empty";

        String old = name();
        if (old[] == value[])
            return null;

        if (!item_table(_typeInfo.collection_id).rename(_id, old[], value))
            return "name already in use";

        return null;
    }

    final ref const(String) comment() const pure
        => _comment;
    final void comment(ref String value)
    {
        _comment = value.move;
        mark_set!(typeof(this), "comment")();
    }

    bool disabled() const pure
        => (_flags & ObjectFlags.disabled) != 0;
    void disabled(bool value)
    {
        if (value)
            _flags |= ObjectFlags.disabled;
        else
            _flags &= ~ObjectFlags.disabled;
        mark_set!(typeof(this), "disabled")();
        mark_set!(typeof(this), "flags")();
    }

    ObjectFlags flags() const
        => cast(ObjectFlags)(_flags | (validate() ? ObjectFlags.none : ObjectFlags.invalid));

    // Object API...

    alias log = ObjectLog!(_type, name);

    final bool is_remote() const pure nothrow @nogc
        => _is_remote;

    void destroy()
    {
        import manager.collection : item_table, signal_object_lifecycle, ObjectLifecycleEvent;
        signal_object_lifecycle(this, ObjectLifecycleEvent.destroyed);
        item_table(_typeInfo.collection_id).defer_free(this);
    }

    // return a list of properties that can be set on this object
    final const(Property*)[] properties() const
        => _typeInfo.properties;

    final ref inout(Element) prop_element(size_t index) inout
    {
        debug assert(_prop_elements && _typeInfo.properties[index].elem_format, "property is not element-backed");
        return _prop_elements[index];
    }

    // element_index is EID-space: 0 is the container, properties claim 1..N
    final inout(Element)* find_prop_element(ushort element_index) inout
    {
        size_t index = size_t(element_index) - 1;
        if (!_prop_elements || index >= _typeInfo.properties.length || !_typeInfo.properties[index].elem_format)
            return null;
        return &_prop_elements[index];
    }

    ElemType!(Type, prop) prop_read(Type, string prop)() const
    {
        alias T = ElemType!(Type, prop);
        static if (is(T : BaseObject))
        {
            import manager.collection : get_item;
            EID eid = EID(prop_element(prop_index!(Type, prop)).read!ulong);
            // dynamic cast: the slot can rebind to a same-named sibling of another class
            return eid ? cast(T)get_item(eid.container) : null;
        }
        else
            return prop_element(prop_index!(Type, prop)).read!T;
    }

    void prop_write(Type, string prop)(auto ref ElemType!(Type, prop) value)
    {
        enum index = prop_index!(Type, prop);
        static if (is(ElemType!(Type, prop) : BaseObject))
        {
            ulong eid = value ? EID(value.id).raw : 0;
            const(char)[] error = prop_element(index).try_write(eid);
            debug assert(error is null, tconcat("write to property '", prop, "' refused: ", error));
            if (error is null)
                _props_set |= ulong(1) << index;
        }
        else
        {
            StringResult r = elem_apply(this, *_typeInfo.properties[index], value);
            debug assert(r, tconcat("write to property '", prop, "' refused: ", r.message));
            if (r)
                _props_set |= ulong(1) << index;
        }
    }

    // get and set and reset (to default) properties
    final Variant get(scope const(char)[] property)
    {
        foreach (p; properties())
        {
            if (p.name[] == property)
            {
                // some properties aren't get-able...
                if (p.get)
                    return p.get(this, *p);
                return Variant();
            }
        }
        // TODO: should we return empty if the property doesn't exist; or should we complain somehow?
        return Variant();
    }

    final StringResult set(scope const(char)[] property, ref const Variant value)
    {
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                if (!p.set || p.read_only)
                    return StringResult(tconcat("Property '", property, "' is read-only"));
                auto r = p.set(value, this, *p);
                if (r)
                {
                    // safety-net tracking for old-style classes; for new-style
                    // the wrapper already did the same mark (idempotent OR).
                    _props_set |= ulong(1) << i;
                    mark_dirty(i);
                }
                return r;
            }
        }
        return set_unknown_property(property, value);
    }

    StringResult set_unknown_property(scope const(char)[] property, ref const Variant value)
    {
        return StringResult(tconcat("No property '", property, "' for ", name[]));
    }

    final package StringResult sync_apply(scope const(char)[] property, ref const Variant value)
    {
        // the authority's echo bypasses the read-only gate: a proxy cannot recompute derived state
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                if (!p.set)
                    return StringResult(tconcat("Property '", property, "' is read-only"));
                auto r = p.set(value, this, *p);
                if (r)
                {
                    _props_set |= ulong(1) << i;
                    mark_dirty(i);
                }
                return r;
            }
        }
        return set_unknown_property(property, value);
    }

    final void reset(scope const(char)[] property)
    {
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                if (p.read_only)
                    return;
                if (p.set && p.init_val)
                    p.set(p.init_val(), this, *p);
                _props_set &= ~(ulong(1) << i);
                mark_dirty(i);
                return;
            }
        }
    }

    final package StringResult sync_reset(scope const(char)[] property)
    {
        foreach (p; properties())
        {
            if (p.name[] == property)
            {
                reset(property);
                return StringResult.success;
            }
        }
        return StringResult(tconcat("No property '", property, "' for ", name[]));
    }

    final Variant gather(scope const(char)[][] patterns...)
    {
        auto props = Array!VariantKVP(Reserve, 16);
        foreach (p; properties)
        {
            if (!p.get)
                continue;

            bool add_item = false;
            if (!patterns)
                add_item = true;
            else foreach (pattern; patterns)
            {
                if (wildcard_match(pattern, p.name[]))
                {
                    add_item = true;
                    break;
                }
            }

            if (add_item)
                props.emplaceBack(p.name[], p.get(this, *p));
        }
        return Variant(props[]);
    }

    // get the whole config
    final Variant get_config()
        => gather();

    final MutableString!0 export_config() const pure
    {
        // TODO: this should return a string that contains the command which would recreate this object...
        return MutableString!0();
    }

    final int opCmp(const BaseObject rhs) const pure
        => cast(int)(cast(long)_id.raw - cast(long)rhs._id.raw);

    final bool opEquals(const BaseObject rhs) const pure
        => _id == rhs._id;

protected:
    package const CollectionTypeInfo* _typeInfo;
    ulong _props_set;   // TODO: I wonder if this should move the sync state? trouble is, this needs to be known for initial sync :/
    ObjectFlags _flags;
    package bool _is_remote;
    package ushort _sync_slot = sync_slot_none;
    package ulong props_set() const pure
        => _props_set;

    // validate configuration is in an operable state
    bool validate() const
        => true;

    void mark_set(T, string[] props)() nothrow @nogc
    {
        enum mask = prop_mask!(T, props);
        _props_set |= mask;
        _mark_dirty(mask);
    }
    void mark_set(T, string prop)() nothrow @nogc
    {
        return mark_set!(T, [ prop ])();
    }

    void mark_assigned(T, string[] props)() nothrow @nogc
    {
        _props_set |= prop_mask!(T, props);
    }
    void mark_assigned(T, string prop)() nothrow @nogc
    {
        return mark_assigned!(T, [ prop ])();
    }

    final void mark_dirty(size_t prop_index) nothrow @nogc
    {
        return _mark_dirty(ulong(1) << prop_index);
    }

    final void _mark_dirty(ulong mask) nothrow @nogc
    {
        for (ushort slot = _sync_slot; slot != sync_slot_none; )
        {
            ref ss = sync_state(slot);
            ss.props_dirty |= mask;
            slot = ss.next;
        }
    }

    public final ushort attach_delta_slot(Object owner) nothrow @nogc
    {
        ushort slot = sync_state_alloc(owner);
        sync_state(slot).next = _sync_slot;
        _sync_slot = slot;
        return slot;
    }

    public final void detach_delta_slot(ushort slot) nothrow @nogc
    {
        if (slot == sync_slot_none)
            return;
        if (_sync_slot == slot)
            _sync_slot = sync_state(slot).next;
        else
        {
            for (ushort prev = _sync_slot; prev != sync_slot_none; )
            {
                ref ps = sync_state(prev);
                if (ps.next == slot)
                {
                    ps.next = sync_state(slot).next;
                    break;
                }
                prev = ps.next;
            }
        }
        sync_state_free(slot);
    }

private:
    const CacheString _type; // TODO: DELETE THIS MEMBER!!!
    package CID _id;
    String _comment;
    Element* _prop_elements;

    void build_prop_elements()
    {
        const(Property*)[] props = _typeInfo.properties;
        bool any = false;
        foreach (p; props)
        {
            if (p.elem_format)
            {
                any = true;
                break;
            }
        }
        if (!any)
            return;

        void[] mem = alloc(props.length * Element.sizeof);
        (cast(ubyte[])mem)[] = 0;
        _prop_elements = cast(Element*)mem.ptr;

        foreach (i, p; props)
        {
            if (!p.elem_format)
                continue;
            ref Element e = _prop_elements[i];
            e.id = p.name;
            e._eid = _id.element(cast(ushort)(i + 1)); // element index 0 is the container
            e.format = p.elem_format();
            e.access = p.read_only ? Access.read : Access.read_write;
            e.sampling_mode = SamplingMode.config;
            if (p.init_val)
            {
                Variant def = p.init_val();
                if (!def.isNull)
                    e.try_set(def);
            }
            e.subscribe(&prop_element_changed); // after the default write: defaults are not changes
        }
    }

    void prop_element_changed(ref const SampleUpdate update)
    {
        size_t index = update.element - _prop_elements;
        ref const Property p = *_typeInfo.properties[index];
        // a proxy's elements carry the authority's echo; reacting locally would drive absent hardware
        if (p.on_change && !_is_remote)
            p.on_change(this, update);
        mark_dirty(index);
    }
}

class ActiveObject : BaseObject
{
    alias Properties = AliasSeq!(Elem!("running", bool, ReadOnly, PropFlags!"h"),
                                 Elem!("status", String, ReadOnly, PropFlags!"d"));
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);

        if (flags & ObjectFlags.disabled)
        {
            _flags ^= ObjectFlags.disabled;
            _state = State.disabled;
        }

        _props_set |= (ulong(1) << prop_index!(typeof(this), "running")) |
                      (ulong(1) << prop_index!(typeof(this), "status"));
        write_status();
    }

    ~this()
    {
        assert(_state & _destroyed, "ActiveObject was not destroyed before destruction!");
    }


    // Properties...

    final override bool disabled() const pure
        => _state & _disabled;
    final override void disabled(bool value)
    {
        if (value)
        {
            _state |= _disabled;
            _state &= ~_start;
            if (_state & _valid)
                _state |= _stop;
        }
        else
            _state &= ~_disabled;
        mark_set!(typeof(this), "disabled")();
        mark_set!(typeof(this), "flags")();
        write_status();
    }

    // TODO: PUT FINAL BACK WHEN EVERYTHING PORTED!
    /+final+/ bool running() const pure
        => _state == State.running;

    final override ObjectFlags flags() const
    {
        return cast(ObjectFlags)(_flags |
                                 ((_state & _valid) || validate() ? ObjectFlags.none : ObjectFlags.invalid) |
                                 ((_state & _disabled) ? ObjectFlags.disabled :
                                 _state == State.running ? ObjectFlags.running : ObjectFlags.none));
    }

    // give a helpful status string, e.g. "Ready", "Disabled", "Error: <message>"
    const(char)[] status_message() const pure
    {
        const(char)[] detail = status_detail();
        if (detail)
            return detail;

        switch (_state)
        {
            case State.disabled:
            case State.stopping:
                return "Disabled";
            case State.destroying:
            case State.destroyed:
                return "Destroyed";
            case State.init_failed:
            case State.failure:
                return _fail_reason ? _fail_reason : "Failed";
            case State.validate:
                return "Invalid";
            case State.starting:
                return "Starting";
            case State.restarting:
                return "Restarting";
            case State.running:
                return "Running";
            default:
                assert(false, "Invalid state!");
        }
    }


    // Object API...

    final void restart()
    {
        assert(!(_state & _destroyed), "Cannot restart a destroyed object!");

        if (is_remote)
            return;

        if (_state == State.init_failed)
        {
            set_state(State.validate);
            return;
        }

        if (_state & _valid)
        {
            State new_state = cast(State)((_state & ~_start) | _stop);
            set_state(new_state);
        }
    }

    final override void destroy()
    {
        assert(!(_state & _destroyed), "destroy() called twice - bookkeeping bug");

        bool was_running = _state == State.running;
        bool was_valid = (_state & _valid) != 0;

        _state |= _disabled | _destroyed;
        _state &= ~(_start | _fail);
        if (was_valid)
            _state |= _stop;    // -> destroying; state machine will run shutdown then transition to destroyed
        write_status();

        if (was_running)
            set_offline();

        log.info("destroyed");

        signal_state_change(StateSignal.destroyed);
        _subscribers.clear();

        if (!was_valid)
            super.destroy();    // no shutdown to run; detach and queue now
    }

    final package void set_remote_state(StateSignal signal)
    {
        final switch (signal)
        {
            case StateSignal.online:
                if (_state == State.running)
                    return;
                _state = State.running;
                write_status();
                set_online();
                break;
            case StateSignal.offline:
                if (_state != State.running)
                    return;
                set_offline();
                _state = State.disabled;
                write_status();
                break;
            case StateSignal.destroyed:
                if (_state & _destroyed)
                    return;
                if (_state == State.running)
                    set_offline();
                _state = State.destroyed;
                write_status();
                signal_state_change(StateSignal.destroyed);
                _subscribers.clear();
                super.destroy();
                break;
        }
    }

    final void subscribe(StateSignalHandler handler)
    {
        assert(!_subscribers[].contains(handler), "Already registered");
        version (TraceLifetimeSubscriptions)
            debug log.trace("new subscriber: ", handler.ptr);
        _subscribers ~= handler;
    }

    final void unsubscribe(StateSignalHandler handler) pure
    {
        version (TraceLifetimeSubscriptions)
            debug log.trace("remove subscriber: ", handler.ptr);
        _subscribers.removeFirstSwapLast(handler);
    }

protected:

    const(char)[] status_detail() const pure
        => null;

    enum ubyte _disabled   = 1 << 0;
    enum ubyte _destroyed  = 1 << 1;
    enum ubyte _start      = 1 << 2;
    enum ubyte _stop       = 1 << 3;
    enum ubyte _valid      = 1 << 4;
    enum ubyte _fail       = 1 << 5;

    enum State : ubyte
    {
        validate    = 0,
        init_failed = _fail,
        disabled    = _disabled,
        destroyed   = _disabled | _destroyed,
        running     = _valid,
        starting    = _start | _valid,
        restarting  = _stop | _valid,
        failure     = _fail | _stop | _valid,
        stopping    = _disabled | _stop | _valid,
        destroying  = _disabled | _destroyed | _stop | _valid,
    }

    State _state = State.validate;

    // set before returning error from startup(); shown through backoff; must be immortal (string literal)
    const(char)[] _fail_reason;

    final void set_state(State new_state)
    {
        assert(_state != State.destroyed, "Cannot change state of a destroyed object!");

        State old = _state;

        if (new_state == _state)
            return;
        _state = new_state;
        // held dedup makes redundant status writes free: an unchanged message stores and notifies nothing
        write_status();

        if (old == State.running)
        {
            set_offline();

            if (_flags & ObjectFlags.temporary)
                destroy();
        }

        debug version (DebugStateFlow)
            if (!DebugType || _type[] == DebugType)
                debug log.trace("state change: ", old, " -> ", _state);

        switch (_state)
        {
            case State.init_failed:
                debug version (DebugStateFlow)
                    if (!DebugType || _type[] == DebugType)
                        debug log.trace("init fail - retry in ", _backoff_ms, "ms");
                goto case;
            case State.disabled:
                break;
            case State.destroyed:
                super.destroy();
                break;

            case State.running:
                _backoff_ms = 0;
                set_online();
                goto do_update;

            case State.starting:
                _last_init_attempt = getTime();
                _fail_reason = null;
                goto do_update;

            case State.validate:
            case State.restarting:
            case State.destroying:
            case State.stopping:
            case State.failure:
            do_update:
                do_update();
                break;

            default:
                assert(false, "Invalid state!");
        }
    }

    CompletionStatus startup()
        => CompletionStatus.complete;

    CompletionStatus shutdown()
        => CompletionStatus.complete;

    void update()
    {
    }

    final void set_online()
    {
        online();
        signal_state_change(StateSignal.online);

        if (!(flags & (ObjectFlags.dynamic | ObjectFlags.temporary)))
            log.notice("online");
        else
            log.trace("online");

        write_running(true);
        mark_set!(typeof(this), "flags")();
    }

    final void set_offline()
    {
        if (!(flags & (ObjectFlags.dynamic | ObjectFlags.temporary)))
            log.notice("offline");
        else
            log.trace("offline");

        signal_state_change(StateSignal.offline);
        offline();

        write_running(false);
        mark_set!(typeof(this), "flags")();
    }

    void online()
    {
    }

    void offline()
    {
    }

    // push the derived views: state transitions (and any subclass state feeding status_message)
    // write the elements the moment they change
    final void write_status()
    {
        prop_element(prop_index!(ActiveObject, "status")).try_write(status_message());
    }

    final void write_running(bool value)
    {
        prop_element(prop_index!(ActiveObject, "running")).try_write(value);
    }


package:
    final void do_update()
    {
        if (is_remote)
            return;

        switch (_state)
        {
            case State.disabled:
                // do nothing...
                break;

            case State.init_failed:
                if (getTime() - _last_init_attempt >= _backoff_ms.msecs)
                {
                    _backoff_ms = cast(ushort)(_backoff_ms == 0 ? 100 : min(_backoff_ms * 2, 60_000));
                    set_state(State.validate);
                }
                break;

            case State.validate:
                if (validate())
                    set_state(State.starting);
                break;

            case State.starting:
                CompletionStatus s = startup();
                if (s == CompletionStatus.complete)
                    set_state(State.running);
                else if (s == CompletionStatus.error)
                    set_state(State.failure);
                break;

            case State.restarting:
            case State.stopping:
            case State.destroying:
            case State.failure:
                CompletionStatus s = shutdown();
                debug assert(s != CompletionStatus.error, "shutdown() should not fail; just clear/reset the state!");
                if (s == CompletionStatus.complete)
                    set_state(cast(State)(_state & ~(_stop | _valid)));
                break;

            case State.running:
                update();
                break;

            default:
                assert(false, "Invalid state!");
        }
    }

private:
    Array!StateSignalHandler _subscribers;
    MonoTime _last_init_attempt;
    ushort _backoff_ms = 0;

    void signal_state_change(StateSignal signal)
    {
        // TODO: there's a potential (yet unlikely) issue here...
        //       if a handler unsubscribes a handler *other than itself* during the callback, and
        //       that handler is before the current index, then some other handler(/s) may be skipped!

        for (size_t i = 0; i < _subscribers.length; )
        {
            auto handler = _subscribers[i];
            handler(this, signal);

            // handlers often un-subscribe during the callback, so check if it's still there before we increment
            if (i < _subscribers.length && _subscribers[i] is handler)
                i++;
        }

        foreach (h; _on_object_state[])
            h(this, signal);
    }
}


struct ObjectRef(Type)
{
    import manager.collection : get_id, get_item;
nothrow @nogc:
    static assert (is(Type : BaseObject), "Type must be a subclass of BaseObject");

    alias get this;

    this(Type object)
    {
        _id = object ? object.id : CID();
    }

    void opAssign(Type object)
    {
        _id = object ? object.id : CID();
    }

    inout(Type) get() inout pure
        => cast(inout(Type))cast(void*)get_item(_id); // void* makes it into a static cast, since we're already confident of the type

    String name() const pure
        => get_id(_id);

    bool detached() const pure
        => get_item(_id) is null;

private:
    CID _id;
}

template ObjectLog(alias tag, alias name)
{
nothrow @nogc:
    void emergency(T...)(ref T args) { write_log(Severity.emergency, tag[], name[], args); }
    void alert(T...)(ref T args) { write_log(Severity.alert, tag[], name[], args); }
    void critical(T...)(ref T args) { write_log(Severity.critical, tag[], name[], args); }
    void error(T...)(ref T args) { write_log(Severity.error, tag[], name[], args); }
    void warning(T...)(ref T args) { write_log(Severity.warning, tag[], name[], args); }
    void notice(T...)(ref T args) { write_log(Severity.notice, tag[], name[], args); }
    void info(T...)(ref T args) { write_log(Severity.info, tag[], name[], args); }
    void debug_(T...)(ref T args) { write_log(Severity.debug_, tag[], name[], args); }
    void trace(T...)(ref T args) { write_log(Severity.trace, tag[], name[], args); }

    void emergencyf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.emergency, tag[], name[], fmt, args); }
    void alertf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.alert, tag[], name[], fmt, args); }
    void criticalf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.critical, tag[], name[], fmt, args); }
    void errorf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.error, tag[], name[], fmt, args); }
    void warningf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.warning, tag[], name[], fmt, args); }
    void noticef(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.notice, tag[], name[], fmt, args); }
    void infof(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.info, tag[], name[], fmt, args); }
    void debugf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.debug_, tag[], name[], fmt, args); }
    void tracef(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.trace, tag[], name[], fmt, args); }
}


template total_prop_count(T)
{
    static if (has_local_properties!T)
        enum num_props = T.Properties.length;
    else
        enum num_props = 0;
    static if (is(T S == super) && !is(S[0] == Object))
        enum total_prop_count = total_prop_count!S + num_props;
    else
        enum total_prop_count = num_props;
}

template prop_index(T, string prop)
{
    static if (is(T S == super) && !is(S[0] == Object))
        enum _parent_index = prop_index!(S[0], prop);
    else
        enum _parent_index = -2;
    static if (_parent_index >= 0)
        enum prop_index = _parent_index;
    else
    {
        static foreach (i, p; T.Properties)
        {
            static if (p.n[] == prop[])
                enum index = i;
        }
        static if (is(typeof(index)))
        {
            static if (_parent_index != -2)
                enum prop_index = total_prop_count!(S[0]) + index;
            else
                enum prop_index = index;
        }
        else
            enum prop_index = -1;
    }
}

enum prop_mask(T, string[] props) = () {
    ulong m = 0;
    static foreach (p; props)
    {{
        enum i = prop_index!(T, p);
        static assert(i >= 0, "Invalid property name '" ~ p ~ "' for type " ~ T.stringof);
        m |= ulong(1) << i;
    }}
    return m;
}();

const(Property*)[] all_properties(Type)()
{
    __gshared const props = all_properties_impl!(Type, 0)();
    return props[];
}

void register_object_state_handler(StateSignalHandler handler) nothrow @nogc
{
    _on_object_state ~= handler;
}

ushort sync_state_alloc(Object channel) nothrow @nogc
{
    ushort slot;
    if (_free_sync_slots.length > 0)
    {
        slot = _free_sync_slots[$ - 1];
        _free_sync_slots.popBack();
    }
    else
    {
        assert(_sync_states.length < sync_slot_none, "too many sync slots");
        slot = cast(ushort)_sync_states.length;
        _sync_states ~= SyncState();
    }
    ref ss = _sync_states[slot];
    ss.channel = channel;
    ss.props_dirty = 0;
    ss.next = sync_slot_none;
    return slot;
}

void sync_state_free(ushort slot) nothrow @nogc
{
    assert(slot < _sync_states.length);
    ref ss = _sync_states[slot];
    ss.channel = null;
    ss.props_dirty = 0;
    ss.next = sync_slot_none;
    _free_sync_slots ~= slot;
}

ref SyncState sync_state(ushort slot) nothrow @nogc
{
    return _sync_states[slot];
}


private:

__gshared Array!StateSignalHandler _on_object_state;

__gshared Array!SyncState _sync_states;
__gshared Array!ushort _free_sync_slots;

enum has_local_properties(Type) = Alias!(_check([__traits(derivedMembers, Type)]));

bool _check(scope string[] members)
{
    assert(__ctfe);
    foreach (m; members)
        if (m == "Properties")
            return true;
    return false;
}

template MaterialProperties(Type)
{
    enum Count = Type.Properties.length;
    auto _make()
    {
        assert(__ctfe);
        Property[Count] r;
        static foreach (i; 0 .. Count)
        {
            static if (is(typeof(Type.Properties[i].is_elem)))
                r[i] = Property.create_elem!(Type.Properties[i], prop_index!(Type, Type.Properties[i].n))();
            else
                r[i] = Property.create!(Type.Properties[i].n, Type.Properties[i].p, Type.Properties[i].c, Type.Properties[i].f)();
        }
        return r;
    }
    __gshared const MaterialProperties = _make();
}

// '*' always, 'd' default, 'h' hidden
ubyte parse_prop_flags(string flags) pure
{
    ubyte r = flags.contains('*') ? 1 : 0;
    r |= flags.contains('d') ? 2 : 0;
    r |= flags.contains('h') ? 4 : 0;
    return r;
}

template FindElemOpt(string kind, Opts...)
{
    alias FindElemOpt = AliasSeq!();
    static foreach (Opt; Opts)
        static if (Opt.kind == kind)
            FindElemOpt = AliasSeq!(FindElemOpt, Opt);
}

template elem_decl(Type, string prop)
{
    static if (has_local_properties!Type)
    {
        static foreach (P; Type.Properties)
            static if (is(typeof(P.is_elem)) && P.n == prop)
                alias local = P;
    }
    static if (is(typeof(local)))
        alias elem_decl = local;
    else static if (is(Type S == super) && !is(S[0] == Object))
        alias elem_decl = elem_decl!(S[0], prop);
    else
        static assert(false, "no element-backed property '" ~ prop ~ "' on " ~ Type.stringof);
}

alias ElemType(Type, string prop) = elem_decl!(Type, prop).T;

auto all_properties_impl(Type, size_t allocCount)()
{
    import urt.traits : Unqual;

    static if (is(Type S == super) && !is(Unqual!S == Object))
    {
        alias Super = Unqual!(S[0]);
        static if (has_local_properties!Type)
            enum PropCount = Type.Properties.length;
        else
            enum PropCount = 0;
        auto result = all_properties_impl!(Super, PropCount + allocCount)();
    }
    else
    {
        enum PropCount = Type.Properties.length;
        const(Property)*[PropCount + allocCount] result;
    }

    static foreach (i; 0 .. PropCount)
        result[result.length - allocCount - PropCount + i] = &MaterialProperties!Type[i];

    return result;
}

template FilterOverloads(alias Filter, alias Symbol)
{
    import urt.meta : AliasSeq;
    alias Parent = __traits(parent, Symbol);
    enum string Identifier = __traits(identifier, Symbol);

    alias FilterOverloads = AliasSeq!();
    static foreach (Overload; __traits(getOverloads, Parent, Identifier))
        static if (Filter!Overload)
            FilterOverloads = AliasSeq!(FilterOverloads, Overload);
}

template IsGetter(alias Func)
{
    static if (is(typeof(&Func) == R function(Args) nothrow @nogc, R, Args...))
        enum IsGetter = Args.length == 0 && !is(R == void);
    else
        enum IsGetter = false;
}

template IsSetter(alias Func)
{
    static if (is(typeof(&Func) == R function(Args) nothrow @nogc, R, Args...))
        enum IsSetter = Args.length == 1;
    else static if (is(typeof(&Func) == R function(Arg...) nothrow @nogc, R, Arg))
        enum IsSetter = true;
    else
        enum IsSetter = false;
}

template HasSuggest(alias Func)
{
    static if (is(typeof(&Func) == R function(Args) nothrow @nogc, R, Args...) && IsSetter!Func)
        enum HasSuggest = is(typeof(suggest_completion!(Args[0])));
    else
        enum HasSuggest = false;
}


Variant SynthGetter(Getters...)(BaseObject item, ref const Property) nothrow @nogc
{
    static assert(Getters.length == 1, "Only one getter overload is allowed for a property");
    alias Getter = Getters[0];

    alias Type = __traits(parent, Getter);
    Type instance = cast(Type)item;

    static if (is(ReturnType!(__traits(child, instance, Getter)) == Variant))
        return __traits(child, instance, Getter)();
    else
        return to_variant(__traits(child, instance, Getter)());
}

StringResult SynthSetter(Setters...)(ref const Variant value, BaseObject item, ref const Property) nothrow @nogc
{
    alias Type = __traits(parent, Setters[0]);
    Type instance = cast(Type)item;

    const(char)[] error;
    static foreach (Setter; Setters)
    {{
        alias PropType = Parameters!Setter[0];
        PropType arg;
        error = from_variant(value, arg);
        if (!error)
        {
            alias RT = ReturnType!Setter;
            static if (is(RT : StringResult))
                return __traits(child, instance, Setter)(arg.move);
            else static if (is(RT : const(char)[]))
                return StringResult(__traits(child, instance, Setter)(arg.move));
            else static if (is(RT == void))
            {
                __traits(child, instance, Setter)(arg.move);
                return StringResult.success;
            }
            else
                static assert(false, "Setter must return void, const(char)[], or StringResult");
        }
    }}
    if (Setters.length == 1)
        return StringResult(error);
    return StringResult(tconcat("Couldn't set property '" ~ __traits(identifier, Setters[0]) ~ "' with value: ", value));
}

// The machinery instantiates per value type, never per property: everything property-specific
// travels as data in the Property. Only a declared Check! costs a per-declaration shim.
Variant elem_get(BaseObject item, ref const Property p) nothrow @nogc
    => item._prop_elements[p.index].value;

StringResult elem_apply(T)(BaseObject item, ref const Property p, auto ref T value) nothrow @nogc
{
    if (p.check)
    {
        if (const(char)[] error = p.check(&value))
            return StringResult(error);
    }
    return StringResult(item._prop_elements[p.index].try_write(value));
}

StringResult elem_set(T)(ref const Variant value, BaseObject item, ref const Property p) nothrow @nogc
{
    T arg;
    if (const(char)[] error = from_variant(value, arg))
        return StringResult(error);
    return elem_apply(item, p, arg.move);
}

StringResult elem_ref_set(ref const Variant value, BaseObject item, ref const Property p) nothrow @nogc
    => StringResult(item._prop_elements[p.index].try_set(value));

const(char)[] CheckShim(alias fn, T)(void* value) nothrow @nogc
    => fn(*cast(T*)value);

Variant ElemDefault(alias Decl)() nothrow @nogc
{
    alias Def = FindElemOpt!("default", Decl.opts);
    static if (Def.length)
        return to_variant(cast(Decl.T)Def[0].value);
    else static if (is(Decl.T : BaseObject))
        return Variant(); // references default to unset
    else static if (__traits(compiles, { Decl.T v = Decl.T.init; return to_variant(v); }))
        return to_variant(Decl.T.init);
    else
        return Variant();
}

FormatId ElemFormat(alias Decl)() nothrow @nogc
{
    __gshared FormatId cached = FormatId.invalid;
    if (cached.valid)
        return cached;

    import manager.sample : register_constraint;
    import manager.series : Constraint, data_format_of, Scalar;

    static if (is(Decl.T : BaseObject))
        DataFormat format = DataFormat(ValueType.u64, SeriesKind.held, collection_type_info!(Decl.T)());
    else
        DataFormat format = data_format_of!(Decl.T)();

    alias Mn = FindElemOpt!("min", Decl.opts);
    alias Mx = FindElemOpt!("max", Decl.opts);
    static if (Mn.length || Mx.length)
    {
        Constraint c;
        static if (Mn.length)
        {
            c.min = Scalar.of(cast(Decl.T)Mn[0].value);
            c.has |= Constraint.Has.min;
        }
        static if (Mx.length)
        {
            c.max = Scalar.of(cast(Decl.T)Mx[0].value);
            c.has |= Constraint.Has.max;
        }
        format.constraint = register_constraint(c);
    }

    cached = register_format(format);
    return cached;
}

void ElemOnChange(alias fn)(BaseObject item, ref const SampleUpdate update) nothrow @nogc
{
    alias Type = __traits(parent, fn);
    Type instance = cast(Type)cast(void*)item; // static cast: the handler only ever binds to its own class
    static if (is(typeof(__traits(child, instance, fn)(update))))
        __traits(child, instance, fn)(update);  // handlers that care receive previous+new
    else
        __traits(child, instance, fn)();
}

Variant SynthDefault(alias Getter)() nothrow @nogc
{
    alias U = Unqual!(ReturnType!Getter);
    static if (is(U == Variant))
        return Variant();
    else static if (__traits(compiles, { U v = U.init; return to_variant(v); }))
        return to_variant(U.init);
    else
        return Variant();   // unsupported; schema reports null
}

template SynthSuggest(Setters...)
{
    // synth suggest function only if there's more than one.
    static if (Setters.length == 1)
    {
        alias PropType = Parameters!(Setters[0])[0];
        alias SynthSuggest = suggest_completion!PropType;
    }
    else
    {
        Array!String SynthSuggest(const(char)[] arg) nothrow @nogc
        {
            Array!String tokens;
            static foreach (Setter; Setters)
            {{
                alias PropType = Parameters!Setter[0];
                static if (is(typeof(suggest_completion!PropType)))
                    tokens ~= suggest_completion!PropType(arg);

                // TODO: also support types with a suggest member function...
            }}

            // TODO: sort and de-duplicate the tokens...

            return tokens;
        }
    }
}


version (unittest)
{
    import urt.si.quantity : Quantity;
    import urt.si.unit : ScaledUnit, Second, Watt;

    private enum TestMode : ubyte { idle, run, fault }

    private final class ElemTestObject : BaseObject
    {
        enum type_name = "elem-test";
        enum collection_id = cast(CollectionType)0;

        alias Properties = AliasSeq!(Elem!("gain", uint, Default!7, Min!1, Max!10, OnChange!bump),
                                     Elem!("mode", TestMode, Default!(TestMode.idle), OnChange!mode_changed),
                                     Elem!("label", String),
                                     Elem!("link", bool, ReadOnly),
                                     Elem!("offset", uint),
                                     Elem!("timeout", Duration, Default!(msecs(800))),
                                     Elem!("power", Quantity!(int, ScaledUnit(Watt))),
                                     Elem!("delay", Quantity!(int, ScaledUnit(Second, -3))),
                                     Elem!("peer", ElemTestObject));
    nothrow @nogc:

        uint changes;
        String last_previous;

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!ElemTestObject(), id, flags);
        }

        void bump()
        {
            ++changes;
        }

        void mode_changed(ref const SampleUpdate update)
        {
            import urt.mem.allocator : defaultAllocator;
            last_previous = update.previous.tstring.makeString(defaultAllocator);
        }
    }
}

unittest
{
    import urt.mem.allocator : defaultAllocator;
    import manager.collection : item_table;

    auto table = &item_table(0);
    ElemTestObject o = defaultAllocator().allocT!ElemTestObject(table.allocate("elem-test-o", 0));
    table.bind(o.id, o);
    enum gain = prop_index!(ElemTestObject, "gain");

    // declared defaults apply at construction and are not "changes"
    assert(o.prop_read!(ElemTestObject, "gain") == 7);
    assert(o.get("gain").asLong == 7);
    assert(o.changes == 0);
    assert(!(o.props_set & (ulong(1) << gain)));

    // console-shaped writes convert, validate, store, and notify
    Variant v = Variant(5);
    assert(o.set("gain", v));
    assert(o.prop_read!(ElemTestObject, "gain") == 5);
    assert(o.changes == 1);
    assert(o.props_set & (ulong(1) << gain));

    // held dedup: an equal write is not a change
    assert(o.set("gain", v));
    assert(o.changes == 1);

    // constraints refuse with their own message; nothing stores, nothing notifies
    Variant big = Variant(20);
    StringResult r = o.set("gain", big);
    assert(r.failed && r.message == "above maximum");
    assert(o.prop_read!(ElemTestObject, "gain") == 5);
    assert(o.changes == 1);

    // enums arrive as strings from the console; change handlers see the previous value
    Variant mode = Variant("run");
    assert(o.set("mode", mode));
    assert(o.prop_read!(ElemTestObject, "mode") == TestMode.run);
    assert(o.last_previous[] == "idle");

    // text properties store through the same path
    Variant label = Variant("charger");
    assert(o.set("label", label));
    assert(o.prop_read!(ElemTestObject, "label") == "charger");

    // typed internal writes ride the same path
    o.prop_write!(ElemTestObject, "gain")(9u);
    assert(o.prop_read!(ElemTestObject, "gain") == 9);
    assert(o.changes == 2);

    // reset restores the declared default through the ordinary write path
    o.reset("gain");
    assert(o.prop_read!(ElemTestObject, "gain") == 7);
    assert(o.changes == 3);
    assert(!(o.props_set & (ulong(1) << gain)));

    // per-T synthesis: same-typed properties share one setter, and the getter is universal
    enum offset = prop_index!(ElemTestObject, "offset");
    assert(o.properties[gain].set is o.properties[offset].set);
    assert(o.properties[gain].set !is o.properties[prop_index!(ElemTestObject, "mode")].set);
    assert(o.properties[gain].get is o.properties[prop_index!(ElemTestObject, "label")].get);

    // read-only: refused at both external entries, still written by the owner
    enum link = prop_index!(ElemTestObject, "link");
    Variant on = Variant(true);
    StringResult ro = o.set("link", on);
    assert(ro.failed && ro.message == "Property 'link' is read-only");
    assert(o.prop_read!(ElemTestObject, "link") == false);
    o.prop_write!(ElemTestObject, "link")(true);
    assert(o.prop_read!(ElemTestObject, "link") == true);
    o.reset("link");
    assert(o.prop_read!(ElemTestObject, "link") == true);
    assert(o.prop_element(link).access == Access.read);
    assert(o.prop_element(gain).access == Access.read_write);

    // Duration round-trips: the declared default applies, strings parse, and the box comes back as a duration
    assert(o.prop_read!(ElemTestObject, "timeout") == msecs(800));
    Variant timeout = Variant("5s");
    assert(o.set("timeout", timeout));
    assert(o.prop_read!(ElemTestObject, "timeout") == seconds(5));
    assert(o.get("timeout").asDuration == seconds(5));
    o.prop_write!(ElemTestObject, "timeout")(msecs(1500));
    assert(o.get("timeout").asDuration == msecs(1500));

    // Quantity round-trips through both doors and boxes with its unit
    o.prop_write!(ElemTestObject, "power")(Quantity!(int, ScaledUnit(Watt))(240));
    assert(o.prop_read!(ElemTestObject, "power").value == 240);
    assert(o.get("power").asQuantity!double().value == 240);
    Variant power = Variant("100W");
    assert(o.set("power", power));
    assert(o.prop_read!(ElemTestObject, "power").value == 100);

    // durations and seconds-dimension quantities interchange at every boundary: a Variant
    // stores a Duration as Quantity!(long, Nanosecond), so the generic paths do the work
    Variant five_s = Variant(Quantity!long(5, ScaledUnit(Second)));
    assert(o.set("timeout", five_s));                       // quantity -> Duration element, scale-adjusted
    assert(o.prop_read!(ElemTestObject, "timeout") == seconds(5));
    Variant dur = Variant(msecs(1500));
    assert(o.set("delay", dur));                            // duration -> millisecond quantity element
    assert(o.prop_read!(ElemTestObject, "delay").value == 1500);
    assert(!o.set("power", dur));                           // the dimension gate still holds

    // property EIDs are (object CID, prop index + 1); resolution indexes the property block
    assert(o.prop_element(gain).eid == o.id.element(cast(ushort)(gain + 1)));
    assert(o.find_prop_element(cast(ushort)(gain + 1)) is &o.prop_element(gain));
    assert(o.find_prop_element(0) is null);                                     // the container, not a property
    assert(o.find_prop_element(1) is null);                                     // legacy property, not element-backed
    assert(o.find_prop_element(cast(ushort)(o.properties.length + 1)) is null); // out of range

    // reference properties: the edge converts name <-> id, storage is an EID
    ElemTestObject target = defaultAllocator().allocT!ElemTestObject(table.allocate("ref-target", 0));
    table.bind(target.id, target);
    Variant peer = Variant("ref-target");
    assert(o.set("peer", peer));
    assert(o.prop_read!(ElemTestObject, "peer") is target);
    assert(o.get("peer").asString == "ref-target");

    // the ref tracks the name's slot: destruction tombstones, recreation at the name rebinds
    table.remove(target.id);
    assert(o.prop_read!(ElemTestObject, "peer") is null);
    ElemTestObject target2 = defaultAllocator().allocT!ElemTestObject(table.allocate("ref-target", 0));
    table.bind(target2.id, target2);
    assert(o.prop_read!(ElemTestObject, "peer") is target2);
    defaultAllocator().freeT(target);

    // a forward reference reserves its id: the write succeeds before the target exists
    Variant later = Variant("ref-later");
    assert(o.set("peer", later));
    assert(o.prop_read!(ElemTestObject, "peer") is null);
    ElemTestObject target3 = defaultAllocator().allocT!ElemTestObject(table.allocate("ref-later", 0));
    table.bind(target3.id, target3);
    assert(o.prop_read!(ElemTestObject, "peer") is target3);

    // the typed door writes the id straight in; null clears
    o.prop_write!(ElemTestObject, "peer")(target2);
    assert(o.get("peer").asString == "ref-target");
    o.prop_write!(ElemTestObject, "peer")(null);
    assert(o.prop_read!(ElemTestObject, "peer") is null);
    assert(o.get("peer").isNull);

    table.remove(target2.id);
    table.remove(target3.id);
    defaultAllocator().freeT(target2);
    defaultAllocator().freeT(target3);

    table.remove(o.id);
    defaultAllocator().freeT(o);

    // a proxy (is_remote) stores echoed values but never runs on_change side effects
    ElemTestObject proxy = defaultAllocator().allocT!ElemTestObject(table.allocate("elem-test-proxy", 0), ObjectFlags.remote);
    table.bind(proxy.id, proxy);
    Variant echoed = Variant(3);
    assert(proxy.set("gain", echoed));
    assert(proxy.prop_read!(ElemTestObject, "gain") == 3);
    assert(proxy.changes == 0);

    // read-only refuses the console but not the authority's echo
    Variant lk = Variant(true);
    assert(!proxy.set("link", lk));
    assert(proxy.sync_apply("link", lk));
    assert(proxy.prop_read!(ElemTestObject, "link") == true);
    table.remove(proxy.id);
    defaultAllocator().freeT(proxy);
}

