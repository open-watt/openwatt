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

public import manager.collection : collection_type_info, collection_for,CollectionTypeInfo;

//version = DebugStateFlow;
enum DebugType = null;

nothrow @nogc:


enum ObjectFlags : ubyte
{
    None        = 0,
    Dynamic     = 1 << 0, // D
    Temporary   = 1 << 1, // T
    Disabled    = 1 << 2, // X
    Invalid     = 1 << 3, // I
    Running     = 1 << 4, // R
    Slave       = 1 << 5, // S
    LinkPresent = 1 << 6, // L
    Hardware    = 1 << 7, // H
}

enum CompletionStatus
{
    Continue,
    Complete,
    Error = -1,
}

enum StateSignal
{
    Online,
    Offline,
    Destroyed
}

alias StateSignalHandler = void delegate(BaseObject object, StateSignal signal) nothrow @nogc;


struct Property
{
    alias GetFun = Variant function(BaseObject i) nothrow @nogc;
    alias SetFun = StringResult function(ref const Variant value, BaseObject i) nothrow @nogc;
    alias ResetFun = void function(BaseObject i) nothrow @nogc;
    alias SuggestFun = Array!String function(const(char)[] arg) nothrow @nogc;

    String name;
    GetFun get;
    SetFun set;
    ResetFun reset;
    SuggestFun suggest;

    static Property create(string name, alias member)()
    {
        alias Type = __traits(parent, member);
        static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

        Property prop;
        prop.name = StringLit!name;

        // synthesise getter
        alias Getters = FilterOverloads!(IsGetter, member);
        static if (Getters.length > 0)
            prop.get = &SynthGetter!Getters;

        // synthesise setter
        alias Setters = FilterOverloads!(IsSetter, member);
        static if (Setters.length > 0)
            prop.set = &SynthSetter!Setters;

        // synthesise suggest
        alias Suggests = FilterOverloads!(HasSuggest, member);
        static if (Suggests.length > 0)
            prop.suggest = &SynthSuggest!Suggests;

        return prop;
    }
}


class BaseObject
{
    __gshared Property[7] Properties = [ Property.create!("type", type)(),
                                         Property.create!("name", name)(),
                                         Property.create!("disabled", disabled)(),
                                         Property.create!("comment", comment)(),
                                         Property.create!("running", running)(),
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

    this(const CollectionTypeInfo* type_info, String name, ObjectFlags flags = ObjectFlags.None)
    {
        assert((flags & ~(ObjectFlags.Dynamic | ObjectFlags.Temporary | ObjectFlags.Disabled)) == 0,
               "`flags` may only contain Dynamic, Temporary, or Disabled flags");

        _typeInfo = type_info;
        _type = type_info.type[].addString();
        _name = name.move;
        _flags = flags;

        if (_flags & ObjectFlags.Disabled)
        {
            _flags ^= ObjectFlags.Disabled;
            _state = State.Disabled;
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
        => _state & _Disabled;
    final void disabled(bool value)
    {
        _state |= _Disabled;
        _state &= ~_Start;
        if (_state & _Valid)
            _state |= _Stop;
    }

    // TODO: PUT FINAL BACK WHEN EVERYTHING PORTED!
    /+final+/ bool running() const pure
        => _state == State.Running;

    ObjectFlags flags() const
    {
        return cast(ObjectFlags)(_flags |
                                 ((_state & _Valid) || validate() ? ObjectFlags.None : ObjectFlags.Invalid) |
                                 ((_state & _Disabled) ? ObjectFlags.Disabled :
                                 _state == State.Running ? ObjectFlags.Running : ObjectFlags.None));
    }

    // give a helpful status string, e.g. "Ready", "Disabled", "Error: <message>"
    const(char)[] status_message() const pure
    {
        switch (_state)
        {
            case State.Disabled:
            case State.Stopping:
                return "Disabled";
            case State.Destroying:
            case State.Destroyed:
                return "Destroyed";
            case State.InitFailed:
            case State.Failure:
                return "Failed";
            case State.Validate:
                return "Invalid";
            case State.Starting:
                return "Starting";
            case State.Restarting:
                return "Restarting";
            case State.Running:
                return "Running";
            default:
                assert(false, "Invalid state!");
        }
    }


    // Object API...

    final void restart()
    {
        if (_state & _Valid)
        {
            _state &= ~_Start;
            _state |= _Stop;
        }
    }

    final void destroy()
    {
        writeInfo(_type[], " '", _name, "' destroyed...");

        _state |= _Disabled | _Destroyed;
        _state &= ~_Start;
        if (_state & _Valid)
            _state |= _Stop;

        signal_state_change(StateSignal.Destroyed);
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

    // get the whole config
    final Variant get_config() const
        => Variant();

    final MutableString!0 export_config() const pure
    {
        // TODO: this should return a string that contains the command which would recreate this object...
        return MutableString!0();
    }

    final void subscribe(StateSignalHandler handler)
    {
        assert(!_subscribers[].exists(handler), "Already registered");
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
    enum ubyte _Disabled   = 1 << 0;
    enum ubyte _Destroyed  = 1 << 1;
    enum ubyte _Start      = 1 << 2;
    enum ubyte _Stop       = 1 << 3;
    enum ubyte _Valid      = 1 << 4;
    enum ubyte _Fail       = 1 << 5;

    enum State : ubyte
    {
        Validate    = 0,
        InitFailed  = _Fail,
        Disabled    = _Disabled,
        Destroyed   = _Disabled | _Destroyed,
        Running     = _Valid,
        Starting    = _Start | _Valid,
        Restarting  = _Stop | _Valid,
        Failure     = _Fail | _Stop | _Valid,
        Stopping    = _Disabled | _Stop | _Valid,
        Destroying  = _Disabled | _Destroyed | _Stop | _Valid,
    }

    const CollectionTypeInfo* _typeInfo;
    size_t _props_set;
    State _state = State.Validate;
    ObjectFlags _flags;

    final void set_state(State new_state)
    {
        assert(_state != State.Destroyed, "Cannot change state of a destroyed object!");

        if (new_state == _state)
            return;

        State old = _state;
        _state = new_state;

        debug version (DebugStateFlow)
            if (!DebugType || _type[] == DebugType)
                writeDebug(_type[], " '", _name, "' state change: ", old, " -> ", new_state);

        switch (new_state)
        {
            case State.InitFailed:
                debug version (DebugStateFlow)
                    if (!DebugType || _type[] == DebugType)
                        writeDebug(_type[], " '", _name, "' init fail - try again in ", _backoff_ms, "ms");
                goto case;
            case State.Disabled:
            case State.Destroyed:
                break;

            case State.Running:
                _backoff_ms = 0;
                set_online();
                goto do_update;

            case State.Validate:
                goto do_update;

            case State.Starting:
                _last_init_attempt = getTime();
                goto do_update;

            case State.Restarting:
            case State.Destroying:
            case State.Stopping:
            case State.Failure:
                if (old == State.Running)
                    set_offline();
                goto do_update;

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
        => validate() ? CompletionStatus.Complete : CompletionStatus.Error;

    CompletionStatus startup()
        => CompletionStatus.Complete;

    CompletionStatus shutdown()
        => CompletionStatus.Complete;

    void update()
    {
    }

    void set_online()
    {
        writeInfo(_type[], " '", _name, "' online...");
        signal_state_change(StateSignal.Online);
    }

    void set_offline()
    {
        writeInfo(_type[], " '", _name, "' offline...");
        signal_state_change(StateSignal.Offline);
    }

    // sends a signal to all clients
    final void signal_state_change(StateSignal signal)
    {
        foreach (handler; _subscribers)
            handler(this, signal);
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
            case State.Destroyed:
                return true;

            case State.Disabled:
                // do nothing...
                break;

            case State.InitFailed:
                if (getTime() - _last_init_attempt >= _backoff_ms.msecs)
                {
                    _backoff_ms = cast(ushort)(_backoff_ms == 0 ? 100 : min(_backoff_ms * 2, 60_000));
                    set_state(State.Validate);
                }
                break;

            case State.Validate:
                CompletionStatus s = validating();
                debug assert(s != CompletionStatus.Continue, "validating() should return Success or Failure");
                if (s == CompletionStatus.Complete)
                    set_state(State.Starting);
                break;

            case State.Starting:
                CompletionStatus s = startup();
                if (s == CompletionStatus.Complete)
                    set_state(State.Running);
                else if (s == CompletionStatus.Error)
                    set_state(State.Failure);
                break;

            case State.Restarting:
            case State.Stopping:
            case State.Destroying:
            case State.Failure:
                CompletionStatus s = shutdown();
                debug assert(s != CompletionStatus.Error, "shutdown() should not fail; just clear/reset the state!");
                if (s == CompletionStatus.Complete)
                    set_state(cast(State)(_state & ~(_Stop | _Valid)));
                break;

            case State.Running:
                update();
                break;

            default:
                assert(false, "Invalid state!");
        }
        return _state == State.Destroyed;
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
        if (signal != StateSignal.Destroyed)
            return;
        _name = _object.name;
        assert((_ptr & 1) == 0, "Objects and strings should never have the 1-bit of their pointers set!?");
        _ptr |= 1;
    }
}


const(Property*)[] allProperties(Type)()
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
        enum HasSuggest = is(typeof(suggestCompletion!(Args[0])));
    else
        enum HasSuggest = false;
}


Variant SynthGetter(Getters...)(BaseObject item) nothrow @nogc
{
    static assert(Getters.length == 1, "Only one getter overload is allowed for a property");
    alias Getter = Getters[0];

    alias Type = __traits(parent, Getter);
    Type instance = cast(Type)item;

    auto r = __traits(child, instance, Getter)();
    assert(false, "TODO: convert to Variant...");
    return Variant(/+...+/);
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
        error = convertVariant(value, arg);
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

template SynthSuggest(Setters...)
{
    // synth suggest function only if there's more than one.
    static if (Setters.length == 1)
    {
        alias PropType = Parameters!(Setters[0])[0];
        alias SynthSuggest = suggestCompletion!PropType;
    }
    else
    {
        Array!String SynthSuggest(const(char)[] arg) nothrow @nogc
        {
            Array!String tokens;
            static foreach (Setter; Setters)
            {{
                alias PropType = Parameters!Setter[0];
                static if (is(typeof(suggestCompletion!PropType)))
                    tokens ~= suggestCompletion!PropType(arg);

                // TODO: also support types with a suggest member function...
            }}

            // TODO: sort and de-duplicate the tokens...

            return tokens;
        }
    }
}
