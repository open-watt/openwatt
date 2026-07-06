module manager.signal;

import urt.mem.temp : tconcat;
import urt.result : StringResult;
import urt.time : MonoTime, SysTime;
import urt.variant : Variant;

nothrow @nogc:


// signal event handed to a subscriber, surfaced by the automation engine as $trigger.*
struct SignalEvent
{
    const(char)[] source;
    Variant value;   // the datum that fired, for providers that have one; null for value-less signals (time)
}

// Parsed signal URI: [provider:|@]body[?k=v&k=v]. `@body` is sugar for `element:body`.
struct SignalUri
{
    const(char)[] scheme;
    const(char)[] body;
    const(char)[] query;    // raw "k=v&k=v", parsed by the provider
}

alias SignalSink = void delegate(MonoTime when, ref const SignalEvent ev) nothrow @nogc;

abstract class SignalSub
{
nothrow @nogc:
    ISignalProvider provider();
}

interface ISignalProvider
{
nothrow @nogc:
    StringResult validate(ref const SignalUri uri) const;
    StringResult subscribe(ref const SignalUri uri, SignalSink sink, out SignalSub handle);
    void unsubscribe(SignalSub handle);
    SysTime next_run(SignalSub handle) const;
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
