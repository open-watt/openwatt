module router.stream.bridge;

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.pagepool : Page;
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

protected:
    // a member with no room drops the frame whole; a fan-out holds no backlog per member
    override void queue_tx_page(Page* frame)
    {
        for (Page* p = frame; p; p = p.next)
            sent(p.data);
        foreach (ref stream; m_streams[])
        {
            Stream member = stream;
            if (!member || !member.tx_request)
                continue;
            Page* copy;
            TxWriter writer = TxWriter(copy, chain_bytes(frame));
            if (!writer)
                continue;
            for (Page* p = frame; p; p = p.next)
                writer.put(p.data);
            member.send(copy);
        }
        free_tx_chain(frame);
    }

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
            Stream member = stream;
            if (member && member !is source && member.tx_request)
                member.send_bytes(data);
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
        override size_t tx_request() const
            => full ? 0 : super.tx_request();
        override ptrdiff_t transmit(const(void)[] data)
        {
            if (fail)
                return -1;
            if (stall)
                return 0;
            output ~= cast(const(char)[])data;
            return data.length;
        }
        void open()
        {
            stall = false;
            drain_tx();
        }
        void feed(const(char)[] text)
        {
            incoming(text, MonoTime());
        }
        Array!char output;
        bool full;
        bool fail;
        bool stall;
    protected:
        override Duration tx_retry_interval() const
            => Duration.zero;
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
    assert(bridge.send_bytes("w") && a.output[] == "w" && b.output[] == "x" && b.tx_queued == 0);
    b.full = false;

    // a member whose line fails restarts the bridge while it relays
    b.fail = true;
    assert(bridge.send_bytes("v") && a.output[] == "wv" && !b.running && !bridge.running);
    b.fail = false;
    settle();
    assert(bridge.running && b.running);

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

    // a frame goes to a member whole or not at all
    char[5000] big = void;
    foreach (i, ref c; big)
        c = cast(char)('a' + i % 26);
    b.output.clear();
    b.stall = true;
    assert(bridge.send_bytes(big[]) && b.tx_queued == big.length && again.output[1 .. $] == big[]);
    assert(bridge.send_bytes(big[]) && b.tx_queued == big.length, "a member past its watermark drops the frame whole");
    b.open();
    assert(b.output[] == big[]);
}
