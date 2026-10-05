module driver.bl808.xram;

version (BL808):

import urt.atomic;
import urt.meta;
import urt.time;
import urt.driver.bl808.xram;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

import driver.bl808.ipc_ids;
import router.iface;

nothrow @nogc:


// Raw frames to the other BL808 core over an XRAM frame channel, built and read in place, delivered in order
// and never lost once accepted. Each core adds one per channel; the link is up while both ends are, and
// bounces when the other end restarts.
final class XramInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("channel", channel));
nothrow @nogc:

    ~this() {}

    enum type_name = "xram";
    enum path = "/interface/xram";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!XramInterface, id, flags);
        _caps = cast(InterfaceCaps)(InterfaceCaps.reliable | InterfaceCaps.ordered);
        set_l2mtu(cast(ushort)xram_mtu());
    }

    // Properties

    final ubyte channel() const pure
        => _channel;
    final void channel(ubyte value)
    {
        if (value == _channel)
            return;
        _channel = value;
        mark_set!(typeof(this), "channel")();
        restart();
    }

    // API

    // A payload of up to max_length bytes to build in XRAM and send with tx_commit; null when the link has no
    // room, and tx_ready invites again once it does.
    final void[] tx_reserve(size_t max_length)
        => link_up ? xram_reserve(_channel, max_length) : null;

    final bool tx_commit(size_t length)
    {
        if (!xram_post(_channel, length))
            return false;
        add_tx_frame(length);
        return true;
    }

    final void tx_abandon()
    {
        xram_abandon(_channel);
    }

    // Leaves room in the ring for a frame that cannot wait for it.
    override bool tx_ready() const
        => link_up && xram_writable(_channel);

    // The ring is the queue: a frame it cannot take is dropped.
    override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        if (packet.type != PacketType.raw)
            return -1;
        auto payload = cast(const(ubyte)[])packet.data();
        if (link_up && payload.length != 0)
        {
            if (void[] frame = xram_reserve(_channel, payload.length))
            {
                (cast(ubyte[])frame)[] = payload[];
                if (tx_commit(payload.length))
                    return 0;
            }
        }
        add_tx_drop();
        return -1;
    }

    // Only a notify the full event queue refused reaches this.
    override void heartbeat(MonoTime now)
    {
        if (atomicExchange(&_retry, 0u))
            service(now);
        super.heartbeat(now);
    }

protected:

    override bool validate() const pure
        => _channel < xram_channels;

    override bool carrier() const
        => _epoch != 0;

    // the peer can answer the open before this returns, so the link registers first
    override CompletionStatus startup()
    {
        if (_links[_channel] !is null)
            return CompletionStatus.error;
        _links[_channel] = this;
        if (xram_open(_channel, IpcId.xram_frame, IpcId.xram_space, &notify))
            return CompletionStatus.complete;
        _links[_channel] = null;
        return CompletionStatus.error;
    }

    override void online()
    {
        super.online();
        service(getTime());
    }

    // the channel opened, not the property, which may already name another
    override CompletionStatus shutdown()
    {
        foreach (i, ref link; _links)
        {
            if (link is this)
            {
                xram_close(cast(uint)i);
                link = null;
            }
        }
        _epoch = 0;
        atomicStore(_queued, 0u);
        return super.shutdown();
    }

private:

    shared uint _queued;
    shared uint _retry;
    uint _epoch;
    ubyte _channel;

    static void notify(uint channel)
    {
        XramInterface link = _links[channel];
        if (link is null || g_app is null)
            return;
        bool queued;
        if (!cas(&link._queued, 0u, 1u))
            return;
        g_app.post_event_from_isr(&_sweep.event, EventPriority.bulk, queued);
        if (!queued)
        {
            atomicStore(link._queued, 0u);
            atomicStore(link._retry, 1u);
        }
    }

    // Queued events bind this stable trampoline, so a link destroyed while one is in flight is simply absent.
    static struct Sweep
    {
        void event(MonoTime when) nothrow @nogc
        {
            foreach (link; _links)
                if (link !is null)
                    link.service(when);
        }
    }
    __gshared Sweep _sweep;
    __gshared XramInterface[xram_channels] _links;

    void service(MonoTime when)
    {
        atomicStore(_queued, 0u);
        if (!running)
            return;
        immutable uint epoch = xram_link(_channel);
        if (epoch != _epoch)
        {
            if (_epoch)
                set_link(false);
            _epoch = epoch;
            if (epoch)
                set_link(true);
        }
        while (const(void)[] frame = xram_receive(_channel))
        {
            Packet p;
            p.init!RawFrame(frame, when);
            incoming_packet(p);
            xram_release(_channel);
        }
        if (tx_ready)
            invite_tx();
    }
}


final class XramModule : Module
{
    mixin DeclareModule!"interface.xram";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!XramInterface();
    }
}
