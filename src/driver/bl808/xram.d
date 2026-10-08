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
        return super.shutdown();
    }

private:

    uint _epoch;
    ubyte _channel;

    static void notify(uint channel)
    {
        ring_from_isr(_doorbell);
    }

    static void service_links(MonoTime when)
    {
        foreach (link; _links)
            if (link !is null)
                link.service(when);
    }
    __gshared XramInterface[xram_channels] _links;
    __gshared ubyte _doorbell;

    void service(MonoTime when)
    {
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
        XramInterface._doorbell = register_doorbell(&XramInterface.service_links, EventPriority.bulk);
    }
}
