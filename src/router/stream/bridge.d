module router.stream.bridge;

import urt.array;
import urt.log;
import urt.mem;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

public import router.stream;

nothrow @nogc:


final class BridgeStream : Stream
{
    alias Properties = AliasSeq!(Prop!("streams", streams));
nothrow @nogc:

    ~this() {}

    enum type_name = "bridge-stream";
    enum path = "/stream/bridge";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!BridgeStream, id, flags, options);
    }

    // Properties

    inout(ObjectRef!Stream)[] streams() inout
        => m_streams[];
    void streams(Stream[] value...)
    {
        unhook_members();
        m_streams.clear();
        m_streams.reserve(value.length);
        foreach (s; value)
            m_streams.emplaceBack(s);
        mark_set!(typeof(this), "streams")();
        restart();
    }

    // API...

    // a write fans out to every member, so the slowest gates transmission; a read may arrive from
    // any member, so the fastest bounds reception. streams that don't know their rate don't vote.
    override ulong tx_link_speed() const
    {
        ulong slowest = 0;
        foreach (ref s; m_streams[])
        {
            ulong r = s ? s.tx_link_speed : 0;
            if (r != 0 && (slowest == 0 || r < slowest))
                slowest = r;
        }
        return slowest;
    }

    override ulong rx_link_speed() const
    {
        ulong fastest = 0;
        foreach (ref s; m_streams[])
        {
            ulong r = s ? s.rx_link_speed : 0;
            if (r > fastest)
                fastest = r;
        }
        return fastest;
    }

    // a member that takes less than all of it drops the rest; a fan-out holds no backlog per member
    override ptrdiff_t write(const(void[])[] data...)
    {
        foreach (ref stream; m_streams[])
        {
            if (stream && stream.running)
                stream.write(data);
        }
        size_t total = 0;
        foreach (ref d; data)
            total += d.length;
        sent(total, data);
        return total;
    }

protected:

    // a member that goes away restarts the bridge, and its replacement is hooked once it runs
    override CompletionStatus startup()
    {
        foreach (ref stream; m_streams[])
        {
            if (!stream || !stream.running)
                return CompletionStatus.continue_;
        }
        foreach (ref stream; m_streams[])
        {
            stream.rx_handler(&member_rx);
            stream.subscribe(&member_state_change);
        }
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unhook_members();
        return CompletionStatus.complete;
    }

private:
    Array!(ObjectRef!Stream) m_streams;
    bool _subscribed;

    void unhook_members()
    {
        if (!_subscribed)
            return;
        foreach (ref stream; m_streams[])
        {
            if (Stream s = stream)
            {
                s.release_rx_handler(&member_rx);
                s.unsubscribe(&member_state_change);
            }
        }
        _subscribed = false;
    }

    void member_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    // what one member receives goes to every other member, and to this stream's consumer
    void member_rx(Stream source, const(void)[] data, MonoTime rx_time)
    {
        foreach (ref stream; m_streams[])
        {
            if (stream && stream.get !is source && stream.running)
                stream.write(data);
        }
        incoming(data, rx_time);
    }
}


final class BridgeStreamModule : Module
{
    mixin DeclareModule!"stream.bridge";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BridgeStream();
    }
}


unittest
{
    static class Member : Stream
    {
    nothrow @nogc:
        ~this() {}
        enum type_name = "bridge-test-member";
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Member, id, flags);
        }
        override ptrdiff_t write(const(void[])[] data...)
        {
            if (full)
                return 0;
            size_t n;
            foreach (d; data)
            {
                output ~= cast(const(char)[])d;
                n += d.length;
            }
            return n;
        }
        void feed(const(char)[] text)
        {
            incoming(text, MonoTime());
        }
        Array!char output;
        bool full;
    }

    static void settle()
    {
        foreach (_; 0 .. 4)
            Collection!Stream().update_all();
    }

    auto members = Collection!Member();
    Member a = members.create("bridge-test-a");
    Member b = members.create("bridge-test-b");
    BridgeStream bridge = Collection!BridgeStream().create("bridge-test");
    scope (exit)
    {
        bridge.destroy();
        if (Member m = members.get("bridge-test-a"))
            m.destroy();
        b.destroy();
        settle();
    }
    bridge.streams(a, b);
    settle();
    assert(bridge.running && a.rx_handler is &bridge.member_rx && b.rx_handler is &bridge.member_rx);
    a.feed("x");
    assert(b.output[] == "x");

    // a member that refuses does not hold up the others
    b.full = true;
    assert(bridge.write("w") == 1 && a.output[] == "w" && b.output[] == "x");
    b.full = false;

    // a member destroyed and created again under its name is hooked once the replacement runs
    a.destroy();
    settle();
    assert(!bridge.running);
    Member again = members.create("bridge-test-a");
    settle();
    assert(again !is null && bridge.running && again.rx_handler is &bridge.member_rx);
    again.feed("y");
    assert(b.output[] == "xy");
    b.feed("z");
    assert(again.output[] == "z");
}
