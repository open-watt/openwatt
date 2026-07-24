module manager.signal;

import urt.array;
import urt.mem.temp : tconcat;
import urt.result : StringResult;
import urt.string;
import urt.time : MonoTime, SysTime;
import urt.traits : Unqual;
import urt.typereg : UserTypeId;
import urt.variant : Variant;

import manager.component;
import manager.series;

nothrow @nogc:


alias SignalHandler(T) = void delegate(Signal* signal, MonoTime when, ref const T value) nothrow @nogc;
alias VariantSignalHandler = void delegate(Signal* signal, MonoTime when, ref const Variant value) nothrow @nogc;
private alias RawSignalHandler = void delegate(Signal* signal, MonoTime when, const(void)* value) nothrow @nogc;

struct Signal
{
nothrow @nogc:

    String id;
    Component parent;
    FormatId format = FormatId.invalid;

    @disable this(this);

    const(DataFormat)* data_format() const pure
        => format_info(format);

    bool has_subscribers() const pure
        => _subscribers.length != 0;

    ptrdiff_t full_path(char[] buffer) const
    {
        size_t pos;
        if (parent)
        {
            pos = parent.full_path(buffer);
            if (pos < buffer.length)
                buffer[pos] = '.';
            ++pos;
        }
        if (pos + id.length <= buffer.length)
            buffer[pos .. pos + id.length] = id[];
        return pos + id.length;
    }

    bool subscribe(T)(SignalHandler!T handler)
    {
        if (!handler.funcptr || (cast(size_t)handler.ptr & variant_tag) != 0 || !accept_payload!T())
            return false;
        add(erase!T(handler));
        return true;
    }

    bool subscribe(VariantSignalHandler handler)
    {
        if ((!format.valid && _payload_type != 0) || !handler.funcptr || (cast(size_t)handler.ptr & variant_tag) != 0)
            return false;
        add(erase(handler));
        return true;
    }

    void unsubscribe(T)(SignalHandler!T handler)
    {
        remove(erase!T(handler));
    }

    void unsubscribe(VariantSignalHandler handler)
    {
        remove(erase(handler));
    }

    void emit(T)(ref const T value, MonoTime when, SignalHandler!T who = null)
    {
        if (!_subscribers)
            return;
        debug assert(payload_matches!T(), "signal payload type mismatch");
        dispatch(when, &value, erase!T(who));
    }

    void emit_record(const(void)* record, MonoTime when)
    {
        if (!_subscribers)
            return;
        debug assert(format.valid, "an untyped record needs a format");
        dispatch(when, record, RawSignalHandler.init);
    }

    void emit(MonoTime when)
    {
        if (!_subscribers)
            return;
        debug assert(!format.valid && _payload_type == 0, "payload signal emitted without its value");
        dispatch(when, null, RawSignalHandler.init);
    }

private:
    Array!RawSignalHandler _subscribers;
    uint _payload_type;
    ubyte _dispatch_depth;

    bool accept_payload(T)()
    {
        alias U = Unqual!T;
        if (format.valid)
            return record_type_matches!U(format);

        enum uint type_id = UserTypeId!U;
        static assert(type_id != 0, "zero is reserved for a payload-less signal");
        if (_payload_type == 0)
        {
            if (has_variant_subscriber)
                return false;
            _payload_type = type_id;
            return true;
        }
        return _payload_type == type_id;
    }

    bool payload_matches(T)()
    {
        alias U = Unqual!T;
        if (format.valid)
            return record_type_matches!U(format);
        return _payload_type == UserTypeId!U;
    }

    bool has_variant_subscriber() const pure
    {
        foreach (handler; _subscribers)
            if (handler.funcptr && is_variant(handler))
                return true;
        return false;
    }

    void add(RawSignalHandler handler)
    {
        foreach (registered; _subscribers)
            if (registered is handler)
                return;
        _subscribers ~= handler;
    }

    void remove(RawSignalHandler handler)
    {
        foreach (i, registered; _subscribers)
        {
            if (registered is handler)
            {
                if (_dispatch_depth)
                {
                    RawSignalHandler* slot = &_subscribers[i];
                    *slot = RawSignalHandler.init;
                }
                else
                    _subscribers.remove(i);
                return;
            }
        }
    }

    void dispatch(MonoTime when, const(void)* record, RawSignalHandler who)
    {
        Variant boxed;
        bool boxed_ready;

        ++_dispatch_depth;
        size_t count = _subscribers.length;
        foreach (i; 0 .. count)
        {
            RawSignalHandler handler = _subscribers[i];
            if (!handler.funcptr || (who.funcptr && handler is who))
                continue;

            if (!is_variant(handler))
            {
                handler(&this, when, record);
                continue;
            }

            if (!boxed_ready)
            {
                if (format.valid)
                    boxed = box_record(record, *data_format);
                boxed_ready = true;
            }

            VariantSignalHandler variant;
            variant.ptr = untag(handler.ptr);
            variant.funcptr = cast(typeof(variant.funcptr))handler.funcptr;
            variant(&this, when, boxed);
        }
        --_dispatch_depth;

        if (_dispatch_depth == 0)
            discard_removed();
    }

    void discard_removed()
    {
        for (size_t i = 0; i < _subscribers.length; )
        {
            if (!_subscribers[i].funcptr)
                _subscribers.remove(i);
            else
                ++i;
        }
    }
}

// Parsed signal URI: [provider:|@]body[?k=v&k=v]. `@body` is sugar for `element:body`.
struct SignalUri
{
    const(char)[] scheme;
    const(char)[] body;
    const(char)[] query;    // raw "k=v&k=v", parsed by the provider
}

abstract class ProviderSubscription
{
nothrow @nogc:
    ISignalProvider provider();
}

interface ISignalProvider
{
nothrow @nogc:
    StringResult validate(ref const SignalUri uri) const;
    StringResult subscribe(ref const SignalUri uri, VariantSignalHandler handler, out ProviderSubscription subscription);
    void unsubscribe(ProviderSubscription subscription);
    SysTime next_run(ProviderSubscription subscription) const;
}


StringResult parse_signal_uri(const(char)[] uri, out SignalUri result)
{
    if (uri.length == 0)
        return StringResult("empty signal");

    if (uri[0] == '@')
    {
        result.scheme = "element";
        uri = uri[1 .. $];
    }
    else
    {
        size_t colon = 0;
        while (colon < uri.length && uri[colon] != ':')
            ++colon;
        if (colon == 0 || colon == uri.length)
            return StringResult(tconcat("malformed signal (want scheme:id or @id): ", uri));
        result.scheme = uri[0 .. colon];
        uri = uri[colon + 1 .. $];
    }

    size_t q = 0;
    while (q < uri.length && uri[q] != '?')
        ++q;
    result.body = uri[0 .. q];
    result.query = (q < uri.length) ? uri[q + 1 .. $] : null;
    return StringResult.success;
}

// extract a named value from a raw "k=v&k=v" query string
const(char)[] uri_param(const(char)[] query, const(char)[] name) pure
{
    while (query.length)
    {
        size_t amp = 0;
        while (amp < query.length && query[amp] != '&')
            ++amp;
        const(char)[] pair = query[0 .. amp];
        query = (amp < query.length) ? query[amp + 1 .. $] : null;

        size_t eq = 0;
        while (eq < pair.length && pair[eq] != '=')
            ++eq;
        if (eq < pair.length && pair[0 .. eq] == name)
            return pair[eq + 1 .. $];
    }
    return null;
}


private:

// The context low bit tags Variant handlers. Function pointers cannot be tagged on ARM Thumb.
enum size_t variant_tag = 1;

bool is_variant(RawSignalHandler handler) pure
    => (cast(size_t)handler.ptr & variant_tag) != 0;

void* tag(void* context) pure
    => cast(void*)(cast(size_t)context | variant_tag);

void* untag(void* context) pure
    => cast(void*)(cast(size_t)context & ~variant_tag);

RawSignalHandler erase(T)(SignalHandler!T handler) pure
{
    assert((cast(size_t)handler.ptr & variant_tag) == 0, "signal delegate context is not pointer-aligned");
    RawSignalHandler erased;
    erased.ptr = handler.ptr;
    erased.funcptr = cast(typeof(erased.funcptr))handler.funcptr;
    return erased;
}

RawSignalHandler erase(VariantSignalHandler handler) pure
{
    assert((cast(size_t)handler.ptr & variant_tag) == 0, "signal delegate context is not pointer-aligned");
    RawSignalHandler erased;
    erased.ptr = tag(handler.ptr);
    erased.funcptr = cast(typeof(erased.funcptr))handler.funcptr;
    return erased;
}

bool record_type_matches(T)(FormatId id)
{
    static if (__traits(compiles, register_value_format!T()))
    {
        const(DataFormat)* record = format_info(id);
        const(DataFormat)* type = format_info(register_value_format!T());
        if (T.sizeof != record.stride || type.type != record.type ||
            type.count != record.count || type.desc != record.desc)
            return false;
        if (record.type == ValueType.user)
            return type.user_type is record.user_type;
        final switch (record.desc) with (DataFormat.Desc)
        {
            case none:     return true;
            case quantity: return type.unit == record.unit;
            case enum_:    return type.enum_info is record.enum_info;
        }
    }
    else
        return false;
}


unittest
{
    struct Receiver
    {
nothrow @nogc:

        Signal* expected;
        MonoTime expected_when;
        int typed_calls;
        int variant_calls;
        int last_value;
        bool saw_null;

        void typed(Signal* signal, MonoTime when, ref const int value)
        {
            assert(signal is expected);
            assert(when == expected_when);
            ++typed_calls;
            last_value = value;
        }

        void variant(Signal* signal, MonoTime when, ref const Variant value)
        {
            assert(signal is expected);
            assert(when == expected_when);
            ++variant_calls;
            saw_null = value.isNull;
            if (!saw_null)
                last_value = value.asInt;
        }
    }

    static immutable DataFormat point = DataFormat(ValueType.s32, SeriesKind.point);
    Signal signal;
    signal.format = register_format(point);

    Receiver receiver;
    receiver.expected = &signal;
    receiver.expected_when = MonoTime(1);
    signal.subscribe!int(&receiver.typed);
    signal.subscribe(&receiver.variant);

    int value = 42;
    signal.emit!int(value, receiver.expected_when);
    assert(receiver.typed_calls == 1);
    assert(receiver.variant_calls == 1);
    assert(receiver.last_value == 42);
    assert(!receiver.saw_null);

    signal.unsubscribe!int(&receiver.typed);
    signal.unsubscribe(&receiver.variant);
    assert(!signal.has_subscribers);

    static immutable DataFormat u16_point = DataFormat(ValueType.u16, SeriesKind.point);
    Signal mismatch;
    mismatch.format = register_format(u16_point);
    bool accepted = mismatch.subscribe!int(&receiver.typed);
    assert(!accepted);
    assert(!mismatch.has_subscribers);

    Signal empty;
    receiver.expected = &empty;
    receiver.expected_when = MonoTime(2);
    empty.subscribe(&receiver.variant);
    empty.emit(receiver.expected_when);
    assert(receiver.variant_calls == 2);
    assert(receiver.saw_null);

    struct RemovingReceiver
    {
nothrow @nogc:

        int first_calls;
        int second_calls;

        void first(Signal* signal, MonoTime, ref const int)
        {
            ++first_calls;
            signal.unsubscribe!int(&second);
        }

        void second(Signal*, MonoTime, ref const int)
        {
            ++second_calls;
        }
    }

    Signal removing;
    RemovingReceiver rr;
    removing.subscribe!int(&rr.first);
    removing.subscribe!int(&rr.second);
    removing.emit!int(value, MonoTime(3));
    assert(rr.first_calls == 1);
    assert(rr.second_calls == 0);
}
