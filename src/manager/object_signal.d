module manager.object_signal;

import urt.mem;
import urt.mem.temp : tconcat;
import urt.result : StringResult;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;
import manager.signal;

nothrow @nogc:


class ObjectSignalModule : Module, ISignalProvider
{
    mixin DeclareModule!"object-signal";
nothrow @nogc:

    override void init()
    {
        g_app.register_signal_provider(StringLit!"object", this);
    }

    override StringResult validate(ref const SignalUri uri) const
    {
        if (uri.body.length == 0)
            return StringResult("object signal needs an instance name");
        const(char)[] state = uri_param(uri.query, "state");
        if (state != "online" && state != "offline" && state != "destroyed")
            return StringResult("object signal state must be online, offline, or destroyed");
        return StringResult.success;
    }

    override StringResult subscribe(ref const SignalUri uri, SignalSink sink, out SignalSub handle)
    {
        StringResult valid = validate(uri);
        if (!valid)
            return valid;

        BaseObject found;
        bool ambiguous;
        foreach_object((BaseObject object)
        {
            if (object.name[] != uri.body)
                return;
            if (found)
                ambiguous = true;
            else
                found = object;
        });
        if (ambiguous)
            return StringResult(tconcat("object name is ambiguous: ", uri.body));
        ActiveObject object = cast(ActiveObject)found;
        if (!object)
            return StringResult(tconcat("active object not found: ", uri.body));

        ObjectSignalSub s = alloc!ObjectSignalSub();
        s.sink = sink;
        s.source = tconcat("object:", uri.body).make_string();
        s.object_id = object.id;
        switch (uri_param(uri.query, "state"))
        {
            case "online": s.state = StateSignal.online; break;
            case "offline": s.state = StateSignal.offline; break;
            case "destroyed": s.state = StateSignal.destroyed; break;
            default: assert(false);
        }
        object.subscribe(&s.on_state);
        s.subscribed = true;
        handle = s;

        if (s.state == StateSignal.online && object.running)
        {
            g_app.schedule(getTime(), &s.on_initial);
            s.initial_scheduled = true;
        }
        return StringResult.success;
    }

    override void unsubscribe(SignalSub handle)
    {
        ObjectSignalSub s = cast(ObjectSignalSub)handle;
        if (s.initial_scheduled)
            g_app.cancel(&s.on_initial);
        if (s.subscribed)
        {
            if (auto object = cast(ActiveObject)get_item(s.object_id))
                object.unsubscribe(&s.on_state);
            s.subscribed = false;
        }
        free(s);
    }

    override SysTime next_run(SignalSub) const
        => SysTime();
}


private:

class ObjectSignalSub : SignalSub
{
nothrow @nogc:
    SignalSink sink;
    String source;
    CID object_id;
    StateSignal state;
    bool subscribed;
    bool initial_scheduled;

    override ISignalProvider provider()
        => get_module!ObjectSignalModule;

    void on_state(ActiveObject, StateSignal value)
    {
        // any real transition supersedes the deferred initial notification
        if (initial_scheduled)
        {
            g_app.cancel(&on_initial);
            initial_scheduled = false;
        }
        if (value != state)
            return;
        SignalEvent event = { source: source[] };
        sink(getTime(), event);
    }

    void on_initial(MonoTime when)
    {
        initial_scheduled = false;
        if (!subscribed)
            return;
        ActiveObject object = cast(ActiveObject)get_item(object_id);
        if (!object || !object.running)
            return;
        SignalEvent event = { source: source[] };
        sink(when, event);
    }
}
