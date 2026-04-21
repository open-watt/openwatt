module manager.base;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta;
import urt.mem.string;
import urt.mem.temp;
import urt.variant;
import urt.result;
import urt.string;
import urt.time;
import urt.traits : Parameters, ReturnType;
import urt.util : min;

import manager.console.argument;
import manager.id;
import manager.value;

public import manager.collection : CID, Collection, CollectionType, collection_type_info, CollectionTypeInfo;

//version = TraceLifetimeSubscriptions;

//version = DebugStateFlow;
enum DebugType = null;

nothrow @nogc:


enum ObjectFlags : ubyte
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

alias StateSignalHandler = void delegate(BaseObject object, StateSignal signal) nothrow @nogc;

template Prop(string name, alias member, string category = null, string flags = null)
{
    enum n = name;
    alias p = member;
    enum c = category;
    enum f = flags;
}

struct Property
{
    alias GetFun = Variant function(BaseObject i) nothrow @nogc;
    alias SetFun = StringResult function(ref const Variant value, BaseObject i) nothrow @nogc;
    alias ResetFun = void function(BaseObject i) nothrow @nogc;
    alias SuggestFun = Array!String function(const(char)[] arg) nothrow @nogc;

    String name;
    String[2] type; // up to 2 types (sometimes like enum + string, or enum + int)
    String category;
    GetFun get;
    SetFun set;
    ResetFun reset;
    SuggestFun suggest;
    ubyte flags;

    static Property create(string name, alias member, string category = null, string flags = null)()
    {
        alias Type = __traits(parent, member);
        static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

        Property prop;
        prop.name = StringLit!name;
        prop.category = category ? StringLit!category : String();
        prop.flags = flags.contains('*') ? 1 : 0; // always
        prop.flags |= flags.contains('d') ? 2 : 0; // default
        prop.flags |= flags.contains('h') ? 4 : 0; // hidden

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

            // synthesise resetter
            prop.reset = &SynthResetter!Setters;
        }

        // synthesise suggest
        static if (Suggests.length > 0)
            prop.suggest = &SynthSuggest!Suggests;

        return prop;
    }
}

class BaseObject
{
    __gshared Property[7] Properties = [ Property.create!("name", name, null, "*")(),
                                         Property.create!("type", type, null, "*")(),
                                         Property.create!("disabled", disabled, null, "h")(),
                                         Property.create!("comment", comment, null, "h")(),
                                         Property.create!("running", running, null, "h")(),
                                         Property.create!("flags", flags, null, "*")(),
                                         Property.create!("status", status_message, null, "d")() ];
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        assert(id, "must have a valid CID");
        assert((flags & ~(ObjectFlags.dynamic | ObjectFlags.temporary | ObjectFlags.disabled)) == 0, "`flags` may only contain Dynamic, Temporary, or Disabled flags");

        debug foreach (i, p; type_info.properties)
            foreach (j; 0 .. i)
                assert(type_info.properties[j].name[] != p.name[], tconcat("Property '", p.name[], "' on ", type_info.type[], " shadows a base class property"));

        _typeInfo = type_info;
        _type = type_info.type[].addString();
        _id = id;
        _flags = flags;

        if (_flags & ObjectFlags.disabled)
        {
            _flags ^= ObjectFlags.disabled;
            _state = State.disabled;
        }
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
        import manager.collection : item_table, broadcast_rekey;

        if (value.empty)
            return "`name` must not be empty";

        ubyte ti = _typeInfo.collection_id;
        ref t = item_table(ti);
        if (t.get_by_name(value, ti) !is null)
            return "name already in use";

        CID old_id = _id;
        CID new_id = t.insert(value, ti, this);
        assert(cast(bool)new_id);

        t.remove(old_id);

        _id = new_id;
        broadcast_rekey(old_id, new_id);

        return null;
    }

    final ref const(String) comment() const pure
        => _comment;
    final void comment(ref String value)
    {
        _comment = value.move;
    }

    final bool disabled() const pure
        => _state & _disabled;
    final void disabled(bool value)
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
    }

    // TODO: PUT FINAL BACK WHEN EVERYTHING PORTED!
    /+final+/ bool running() const pure
        => _state == State.running;

    ObjectFlags flags() const
    {
        return cast(ObjectFlags)(_flags |
                                 ((_state & _valid) || validate() ? ObjectFlags.none : ObjectFlags.invalid) |
                                 ((_state & _disabled) ? ObjectFlags.disabled :
                                 _state == State.running ? ObjectFlags.running : ObjectFlags.none));
    }

    // give a helpful status string, e.g. "Ready", "Disabled", "Error: <message>"
    const(char)[] status_message() const pure
    {
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
                return "Failed";
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

    alias log = ObjectLog!(_type, _name);

    final void restart()
    {
        assert(!(_state & _destroyed), "Cannot restart a destroyed object!");

        if (_state & _valid)
        {
            State new_state = cast(State)((_state & ~_start) | _stop);
            set_state(new_state);
        }
    }

    final void destroy()
    {
        if (_state & _destroyed)
            return; // destroy was already called

        if (_state == State.running)
            set_offline();

        log.info("destroyed");

        _state |= _disabled | _destroyed;
        _state &= ~(_start | _fail);
        if (_state & _valid)
            _state |= _stop;

        signal_state_change(StateSignal.destroyed);
        _subscribers.clear();
    }

    // return a list of properties that can be set on this object
    final const(Property*)[] properties() const
        => _typeInfo.properties;

    // get and set and reset (to default) properties
    final Variant get(scope const(char)[] property)
    {
        foreach (p; properties())
        {
            if (p.name[] == property)
            {
                // some properties aren't get-able...
                if (p.get)
                    return p.get(this);
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
                if (!p.set)
                    return StringResult(tconcat("Property '", property, "' is read-only"));
                return p.set(value, this);
            }
        }
        return StringResult(tconcat("No property '", property, "' for ", name[]));
    }

    final void reset(scope const(char)[] property)
    {
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                _props_set &= ~(1 << i);
                if (p.reset)
                    p.reset(this);
                return;
            }
        }
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
                props.emplaceBack(p.name[], p.get(this));
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

    int opCmp(const BaseObject rhs) const pure
        => cast(int)(cast(long)_id.raw - cast(long)rhs._id.raw);

    bool opEquals(const BaseObject rhs) const pure
        => _id == rhs._id;

protected:
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

    package const CollectionTypeInfo* _typeInfo;
    size_t _props_set;
    State _state = State.validate;
    ObjectFlags _flags;

    final void set_state(State new_state)
    {
        assert(_state != State.destroyed, "Cannot change state of a destroyed object!");

        State old = _state;

        // temporary objects self-destruct when they would shutdown
        if ((_flags & ObjectFlags.temporary) && (new_state & _stop))
        {
            destroy();
            if (_state == old)
                return;
        }
        else
        {
            if (new_state == _state)
                return;
            _state = new_state;

            if (old == State.running)
                set_offline();
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
            case State.destroyed:
                break;

            case State.running:
                _backoff_ms = 0;
                set_online();
                goto do_update;

            case State.starting:
                _last_init_attempt = getTime();
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

    // validate configuration is in an operable state
    bool validate() const
        => true;

    CompletionStatus startup()
        => CompletionStatus.complete;

    CompletionStatus shutdown()
        => CompletionStatus.complete;

    void update()
    {
    }

    void rekey(CID old_id, CID new_id)
    {
        // nothing at this level
    }

    final void set_online()
    {
        online();
        signal_state_change(StateSignal.online);

        if (!(flags & (ObjectFlags.dynamic | ObjectFlags.temporary)))
            log.notice("online");
        else
            log.trace("online");
    }

    final void set_offline()
    {
        if (!(flags & (ObjectFlags.dynamic | ObjectFlags.temporary)))
            log.notice("offline");
        else
            log.trace("offline");

        signal_state_change(StateSignal.offline);
        offline();
    }

    void online()
    {
    }

    void offline()
    {
    }

package:
    final void do_rekey(CID old_id, CID new_id)
    {
        rekey(old_id, new_id);
    }

    final bool do_update()
    {
        switch (_state)
        {
            case State.destroyed:
                return true;

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
        return _state == State.destroyed;
    }

private:
    const CacheString _type; // TODO: DELETE THIS MEMBER!!!
    package CID _id;
    String _comment;

    // redirect for legacy code that references _name directly DELETEME!!
    String _name() const => name();
    Array!StateSignalHandler _subscribers;
    MonoTime _last_init_attempt;
    ushort _backoff_ms = 0;

    // sends a signal to all clients
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

const(Property*)[] all_properties(Type)()
{
    enum num_props = Type.Properties.length;

    static if (is(Type S == super) && !is(S[0] == Object))
        alias s_props = all_properties!(S[0]);
    else
        const(Property*)[0] s_props;

    auto make_props()
    {
        assert(__ctfe);
        Property[num_props] r;
        static foreach (i; 0 .. num_props)
            r[i] = Property.create!(Type.Properties[i].n, Type.Properties[i].p, Type.Properties[i].c, Type.Properties[i].f)();
        return r;
    }
}


private:

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
            r[i] = Property.create!(Type.Properties[i].n, Type.Properties[i].p, Type.Properties[i].c, Type.Properties[i].f)();
        return r;
    }
    __gshared const MaterialProperties = _make();
}

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


Variant SynthGetter(Getters...)(BaseObject item) nothrow @nogc
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

StringResult SynthSetter(Setters...)(ref const Variant value, BaseObject item) nothrow @nogc
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

void SynthResetter(Setters...)(BaseObject item) nothrow @nogc
{
    alias Type = __traits(parent, Setters[0]);
    Type instance = cast(Type)item;

    // reset will write the init value to the first setter
    alias Setter = Setters[0];
    alias PropType = Parameters!Setter[0];
    __traits(child, instance, Setter)(PropType.init);
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
