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
import manager.value;

public import manager.collection : collection_type_info, collection_for,CollectionTypeInfo;

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
        prop.flags = (flags.contains('h') ? 1 : 0); // hidden

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
    __gshared Property[7] Properties = [ Property.create!("name", name)(),
                                         Property.create!("type", type)(),
                                         Property.create!("disabled", disabled, null, "h")(),
                                         Property.create!("comment", comment, null, "h")(),
                                         Property.create!("running", running, null, "h")(),
                                         Property.create!("flags", flags)(),
                                         Property.create!("status", status_message)() ];
nothrow @nogc:

    // TODO: delete this constructor!!!
    this(String name, const(char)[] type)
    {
        assert(name !is null, "`name` must not be empty");

        _typeInfo = null;
        _type = type.addString();
        _name = name.move;
    }

    this(const CollectionTypeInfo* type_info, String name, ObjectFlags flags = ObjectFlags.none)
    {
        assert((flags & ~(ObjectFlags.dynamic | ObjectFlags.temporary | ObjectFlags.disabled)) == 0,
               "`flags` may only contain Dynamic, Temporary, or Disabled flags");

        _typeInfo = type_info;
        _type = type_info.type[].addString();
        _name = name.move;
        _flags = flags;

        if (_flags & ObjectFlags.disabled)
        {
            _flags ^= ObjectFlags.disabled;
            _state = State.disabled;
        }
    }


    // Properties...

    final const(char)[] type() const pure
        => _type;

    final ref const(String) name() const pure
        => _name;
    final const(char)[] name(ref String value)
    {
        if (value.empty)
            return "`name` must not be empty";

        assert(false, "TODO: check name is not already in use...");

        _name = value.move;
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
        _state |= _disabled;
        _state &= ~_start;
        if (_state & _valid)
            _state |= _stop;
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

        writeInfo(_type[], " '", _name, "' destroyed");

        _state |= _disabled | _destroyed;
        _state &= ~_start;
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
        _subscribers ~= handler;
    }

    final void unsubscribe(StateSignalHandler handler) pure
    {
        _subscribers.removeFirstSwapLast(handler);
    }

    int opCmp(const BaseObject rhs) const pure
    {
        import urt.algorithm : compare;
        auto r = compare(_type[], rhs._type[]);
        if (r != 0)
            return r;
        return compare(_name, rhs._name);
    }

    bool opEquals(const BaseObject rhs) const pure
        => _name == rhs._name && type[] == rhs.type[];

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

    const CollectionTypeInfo* _typeInfo;
    size_t _props_set;
    State _state = State.validate;
    ObjectFlags _flags;

    final void set_state(State new_state)
    {
        assert(_state != State.destroyed, "Cannot change state of a destroyed object!");

        if (new_state == _state)
            return;

        State old = _state;
        _state = new_state;

        debug version (DebugStateFlow)
            if (!DebugType || _type[] == DebugType)
                writeDebug(_type[], " '", _name, "' state change: ", old, " -> ", new_state);

        if (old == State.running)
            set_offline();

        switch (new_state)
        {
            case State.init_failed:
                debug version (DebugStateFlow)
                    if (!DebugType || _type[] == DebugType)
                        writeDebug(_type[], " '", _name, "' init fail - try again in ", _backoff_ms, "ms");
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

    CompletionStatus validating()
        => validate() ? CompletionStatus.complete : CompletionStatus.error;

    CompletionStatus startup()
        => CompletionStatus.complete;

    CompletionStatus shutdown()
        => CompletionStatus.complete;

    void update()
    {
    }

    void set_online()
    {
        writeInfo(_type[], " '", _name, "' online");
        signal_state_change(StateSignal.online);
    }

    void set_offline()
    {
        writeInfo(_type[], " '", _name, "' offline");
        signal_state_change(StateSignal.offline);
    }

    // sends a signal to all clients
    final void signal_state_change(StateSignal signal)
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

private:
    const CacheString _type; // TODO: DELETE THIS MEMBER!!!
    String _name;
    String _comment;
    Array!StateSignalHandler _subscribers;
    MonoTime _last_init_attempt;
    ushort _backoff_ms = 0;

    package bool do_update()
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
                CompletionStatus s = validating();
                debug assert(s != CompletionStatus.continue_, "validating() should return Success or Failure");
                if (s == CompletionStatus.complete)
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
}


struct ObjectRef(Type)
{
nothrow @nogc:
    static assert (is(Type : BaseObject), "Type must be a subclass of BaseObject");

    alias get this;

    this(Type object)
    {
        _object = object;
        _object.subscribe(&destroy_handler);
    }

    ~this()
    {
        release();
    }

    void opAssign(Type object)
    {
        if (_object is object)
            return;
        if (_object !is null)
            release(); // release the old object
        _object = object; // assign the new one
        if (_object !is null)
            _object.subscribe(&destroy_handler);
    }

    inout(Type) get() inout pure
    {
        if (_ptr & 1)
            return null; // object has been destroyed, so return null
        return _object;
    }

    String name() const pure
    {
        if (_ptr & 1)
        {
            size_t t = _ptr ^ 1;
            return *cast(String*)&t;
        }
        return _object ? _object.name : String();
    }

    bool detached() const pure
        => _ptr & 1;

    bool try_reattach()
    {
        if (!detached)
            return true;
        if (Type obj = collection_for!Type.get(name))
        {
            this = obj;
            return true;
        }
        return false;
    }

    void release()
    {
        // if we hold a string, we must destroy it...
        if (_ptr & 1)
        {
            _ptr ^= 1;
            _name = null;
        }
        else if (_object !is null)
        {
            _object.unsubscribe(&destroy_handler);
            _object = null;
        }
    }

private:
    union
    {
        Type _object;
        String _name;
        size_t _ptr;
    }

    void destroy_handler(BaseObject object, StateSignal signal)
    {
        assert(object is _object, "Object reference mismatch!");
        if (signal != StateSignal.destroyed)
            return;
        _name = _object.name;
        assert((_ptr & 1) == 0, "Objects and strings should never have the 1-bit of their pointers set!?");
        _ptr |= 1;
    }
}


const(Property*)[] all_properties(Type)()
{
    alias AllProps = all_properties_impl!(Type, 0);
    enum Count = typeof(AllProps()).length;
    __gshared const(Property*)[Count] props = AllProps();
    return props[];
}


private:

auto all_properties_impl(Type, size_t allocCount)()
{
    import urt.traits : Unqual;

    static if (is(Type S == super) && !is(Unqual!S == Object))
    {
        alias Super = Unqual!S;
        static if (!is(typeof(Type.Properties) == typeof(Super.Properties)) || &Type.Properties !is &Super.Properties)
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
        result[result.length - allocCount - PropCount + i] = &Type.Properties[i];
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
        return Variant(to_variant(__traits(child, instance, Getter)()));
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
