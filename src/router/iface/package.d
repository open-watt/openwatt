module router.iface;

import urt.array;
import urt.conv;
import urt.lifetime;
import urt.map;
import urt.mem;
import urt.mem.ring;
import urt.meta.enuminfo : bitfield;
import urt.meta.nullable;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

import router.iface.endpoint;
import router.iface.ethernet;
import router.iface.group;
import router.iface.udp;
import router.iface.vlan;

public import router.iface.packet;
public import router.status;

// package modules...
public static import router.iface.bridge;
public static import router.iface.endpoint;
public static import router.iface.ethernet;
public static import router.iface.group;
public static import router.iface.i2c;
public static import router.iface.udp;
public static import router.iface.vlan;
public static import router.iface.wifi;

nothrow @nogc:

alias Milliseconds = Quantity!(float, ScaledUnit(Second, -3));

enum BufferOverflowBehaviour : byte
{
    drop_oldest,    // drop oldest data in buffer
    drop_newest,    // drop newest data in buffer (or don't add new data to full buffer)
    fail            // cause the call to fail
}

enum PacketDirection : ubyte
{
    incoming = 1,
    outgoing = 2
}

@bitfield enum InterfaceCaps : ushort
{
    none     = 0,
    ethernet = 1 << 0, // attaches to an ethernet segment; marshals exotic packets over the OW ethertype
    reliable = 1 << 1, // delivery is acknowledged and retransmitted; loss surfaces as an error, never silently
    ordered  = 1 << 2, // frames are delivered in transmit order
}

enum MessageState
{
    queued,
    in_flight,
    complete,
    failed,
    aborted,
    timeout,
    expired,
    dropped
}

alias MessageCallback = void delegate(int msg_handle, MessageState state) nothrow @nogc;
alias IncomingPacketHandler = void delegate(ref Packet p, BaseInterface i) nothrow @nogc;


__gshared IncomingPacketHandler[PacketType.count] _frame_handlers;

bool register_frame_handler(PacketType type, IncomingPacketHandler handler)
{
    if (_frame_handlers[type] !is null)
        return false;
    _frame_handlers[type] = handler;
    return true;
}

void unregister_frame_handler(PacketType type)
{
    _frame_handlers[type] = null;
}


struct TagAllocator
{
nothrow @nogc pure:
    int alloc()
    {
        foreach (_; 0 .. 255)
        {
            ++_next;
            if (_next == 0)
                _next = 1;
            if (!(_in_use[_next / _tag_bits] & (size_t(1) << (_next % _tag_bits))))
            {
                _in_use[_next / _tag_bits] |= size_t(1) << (_next % _tag_bits);
                return _next;
            }
        }
        return -1;
    }

    void free(ubyte tag)
    {
        _in_use[tag / _tag_bits] &= ~(size_t(1) << (tag % _tag_bits));
    }

private:
    enum _tag_bits = size_t.sizeof * 8;

    ubyte _next;
    size_t[256 / _tag_bits] _in_use;
}


struct PacketFilter
{
nothrow @nogc:
    PacketType type = PacketType.ethernet;
    PacketDirection direction = PacketDirection.incoming;
    MACAddress src;
    MACAddress dst;
    ushort ether_type;
    ushort ether_type_2;
    ushort vlan;

    bool match(ref const Packet p)
    {
        if (type != PacketType.unknown)
        {
            if (type != p.type)
                return false;
            if (type == PacketType.ethernet)
            {
                if (ether_type)
                {
                    if (p.eth.ether_type != ether_type)
                    {
                        if (!ether_type_2 || p.eth.ether_type != ether_type_2)
                            return false;
                    }
                }
                else
                    debug assert(ether_type_2 == 0, "ether_type must be set if ether_type_2 is set!");
                if (src && p.eth.src != src)
                    return false;
                if (dst && p.eth.dst != dst)
                    return false;
            }
        }
        if (vlan && p.vid != vlan)
            return false;
        return true;
    }
}

struct InterfaceSubscriber
{
    alias PacketHandler = void delegate(ref const Packet p, BaseInterface i, PacketDirection dir, void* u) nothrow @nogc;

    PacketFilter filter;
    PacketHandler recv_packet;
    void* user_data;
}

// MAC: 02:xx:xx:ra:nd:yy
//      02:13:37:xx:xx:yy
//      02:AC:1D:xx:xx:yy
//      02:C0:DE:xx:xx:yy
//      02:BA:BE:xx:xx:yy
//      02:DE:AD:xx:xx:yy
//      02:FE:ED:xx:xx:yy
//      02:B0:0B:xx:xx:yy

MACAddress generate_mac_address(const(char)[] name)
{
    import urt.crc;
    import manager.system : node_id;
    alias crc_fun = calculate_crc!(Algorithm.crc32_iso_hdlc);

    enum ushort MAGIC = 0x1337;

    // seeded by the node id: interfaces share names across nodes ("ether1" everywhere),
    // and two stations on one segment must never derive the same address
    uint crc = crc_fun(name);
    ulong id = node_id();
    crc ^= cast(uint)id ^ cast(uint)(id >> 32);
    MACAddress addr = MACAddress(0x02, MAGIC >> 8, MAGIC & 0xFF, crc & 0xFF, (crc >> 8) & 0xFF, crc >> 24);
    if (addr.b[5] < 100 || addr.b[5] >= 240)
        addr.b[5] ^= 0x80;
    return addr;
}

class BaseInterface : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("caps", caps),
                                 Prop!("actual-mtu", actual_mtu, null, "d"),
                                 Prop!("mtu", mtu, null, "d"),
                                 Prop!("l2mtu", l2mtu),
                                 Prop!("max-l2mtu", max_l2mtu, null, "d"),
                                 Prop!("pcap", pcap),
                                 Prop!("last-status-change-time", last_status_change_time, "status"),
                                 Prop!("connected", connected, "status", "d"),
                                 Prop!("link-status", link_status, "status", "d"),
                                 Prop!("link-downs", link_downs, "status"),
                                 Prop!("tx-link-speed", tx_link_speed, "status"),
                                 Prop!("rx-link-speed", rx_link_speed, "status"),
                                 Prop!("tx-bytes", tx_bytes, "traffic", "d"),
                                 Prop!("rx-bytes", rx_bytes, "traffic", "d"),
                                 Prop!("tx-packets", tx_packets, "traffic", "d"),
                                 Prop!("rx-packets", rx_packets, "traffic", "d"),
                                 Prop!("tx-dropped", tx_dropped, "traffic", "d"),
                                 Prop!("rx-dropped", rx_dropped, "traffic", "d"),
                                 Prop!("tx-rate", tx_rate, "traffic", "d"),
                                 Prop!("rx-rate", rx_rate, "traffic", "d"),
                                 Prop!("tx-rate-max", tx_rate_max, "traffic"),
                                 Prop!("rx-rate-max", rx_rate_max, "traffic"),
                                 Prop!("avg-queue-time", avg_queue_time, "traffic"),
                                 Prop!("avg-service-time", avg_service_time, "traffic"),
                                 Prop!("max-service-time", max_service_time, "traffic"));
nothrow @nogc:

    enum type_name = "interface";
    enum path = "/interface";
    enum collection_id = CollectionType.interface_;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
    }

    // Properties...

    final ushort mtu() const pure
        => _mtu;
    final void mtu(ushort value)
    {
        _mtu = value;
        mark_set!(typeof(this), "mtu")();
        mark_set!(typeof(this), "actual-mtu")();
        on_mtu_changed();
    }
    ushort actual_mtu() const pure
        => _mtu == 0 ? _l2mtu : _mtu;

    // TODO: the L2MTU properties should be available only to actual L2 interfaces...
    final ushort l2mtu() const pure
        => _l2mtu;
    final void l2mtu(ushort value)
    {
        _l2mtu = value;
        mark_set!(typeof(this), "l2mtu")();
        mark_set!(typeof(this), "actual-mtu")();
    }
    final ushort max_l2mtu() const pure
        => _max_l2mtu;

    // TODO: maybe we should make the pcap instance a normal collection item?
//    final const(char)[] pcap() const pure
//    {
//        assert(false, "TODO: we need to store the pcap thing!");
//    }
    final const(char)[] pcap(const(char)[] value)
    {
        // TODO: unsubscribe from old pcap interface, if any...
        import router.pcap;
        PcapInterface* cap = get_module!PcapModule.findInterface(value);
        if (!cap)
            return tconcat("Failed to attach pcap interface '", value, "' to '", name, "'; doesn't exist");
        else
            cap.subscribe_interface(this);
        mark_set!(typeof(this), "pcap")();
        return null;
    }

    SysTime last_status_change_time() const => _status.link_status_change_time;
    ConnectionStatus connected() const => _status.connected;
    LinkStatus link_status() const => _status.link_status;
    ulong link_downs() const => _status.link_downs;
    ulong tx_link_speed() const => _status.tx_link_speed;
    ulong rx_link_speed() const => _status.rx_link_speed;
    ulong tx_bytes() const => _status.tx_bytes;
    ulong rx_bytes() const => _status.rx_bytes;
    ulong tx_packets() const => _status.tx_packets;
    ulong rx_packets() const => _status.rx_packets;
    ulong tx_dropped() const => _status.tx_dropped;
    ulong rx_dropped() const => _status.rx_dropped;
    ulong rx_rate() const => _status.rx_rate;
    ulong tx_rate() const => _status.tx_rate;
    ulong tx_rate_max() const => _status.tx_rate_max;
    ulong rx_rate_max() const => _status.rx_rate_max;
    Milliseconds avg_queue_time() const => Milliseconds(float(_status.avg_queue_us) / 1000);
    Milliseconds avg_service_time() const => Milliseconds(float(_status.avg_service_us) / 1000);
    Milliseconds max_service_time() const => Milliseconds(float(_status.max_service_us) / 1000);

    // API...

    ref const(IfStatus) status() const pure
        => _status;

    final void reset_counters()
    {
        _status.link_downs = 0;
        _status.tx_bytes = 0;
        _status.rx_bytes = 0;
        _status.tx_packets = 0;
        _status.rx_packets = 0;
        _status.tx_dropped = 0;
        _status.rx_dropped = 0;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        _status.tx_rate_max = 0;
        _status.rx_rate_max = 0;
        _status.avg_queue_us = 0;
        _status.avg_service_us = 0;
        _status.max_service_us = 0;
        _last_tx_bytes = 0;
        _last_rx_bytes = 0;
        _last_bitrate_sample = MonoTime.init;

        mark_set!(typeof(this), [ "link-downs", "tx-bytes", "rx-bytes", "tx-packets", "rx-packets", "tx-dropped", "rx-dropped",
                                  "tx-rate", "rx-rate", "tx-rate-max", "rx-rate-max", "avg-queue-time", "avg-service-time", "max-service-time" ]);
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    void heartbeat(MonoTime now)
    {
        if (_last_bitrate_sample == MonoTime.init)
        {
            // first tick after link-up: anchor the baseline at a grid point; defer the
            // rate to the next tick so we never report it over a short partial interval.
            _last_bitrate_sample = now;
            _last_tx_bytes = _status.tx_bytes;
            _last_rx_bytes = _status.rx_bytes;
            return;
        }

        ulong elapsed_us = (now - _last_bitrate_sample).as!"usecs";
        if (elapsed_us == 0)
            return;

        ulong last_tx = _status.tx_rate, last_rx = _status.rx_rate;
        _status.tx_rate = (_status.tx_bytes - _last_tx_bytes) * 1_000_000 / elapsed_us;
        _status.rx_rate = (_status.rx_bytes - _last_rx_bytes) * 1_000_000 / elapsed_us;

        ulong dirty = 0;
        if (_status.tx_rate != last_tx)
            dirty |= ulong(1) << prop_index!(typeof(this), "tx-rate");
        if (_status.rx_rate != last_rx)
            dirty |= ulong(1) << prop_index!(typeof(this), "rx-rate");

        if (_status.tx_rate > _status.tx_rate_max)
        {
            _status.tx_rate_max = _status.tx_rate;
            dirty |= ulong(1) << prop_index!(typeof(this), "tx-rate-max");
        }
        if (_status.rx_rate > _status.rx_rate_max)
        {
            _status.rx_rate_max = _status.rx_rate;
            dirty |= ulong(1) << prop_index!(typeof(this), "rx-rate-max");
        }

        _last_tx_bytes = _status.tx_bytes;
        _last_rx_bytes = _status.rx_bytes;
        _last_bitrate_sample = now;

        if (dirty)
        {
            _props_set |= dirty;
            _mark_dirty(dirty);
        }
    }

    bool set_master(BaseInterface master, byte slave_id) pure
    {
        if (master is null)
        {
            _master = null;
            _slave_id = 0;
            _flags &= ~ObjectFlags.slave;
            return true;
        }
        if (_master !is null)
            return false;
        _master = master;
        _slave_id = slave_id;
        _flags |= ObjectFlags.slave;
        return true;
    }

    // OS netdev ifindex, set by a platform backend (e.g. the Linux kernel-bridge
    // offload) when this interface is backed by a kernel netdev that isn't a
    // LinuxRawEthernet. The IP mirror resolves it via this accessor.
    final int kernel_ifindex() const pure
        => _kernel_ifindex;
    final void set_kernel_ifindex(int idx)
    {
        _kernel_ifindex = idx;
    }

    // alias the base functions into this scope to merge the overload sets
    alias subscribe = typeof(super).subscribe;
    alias unsubscribe = typeof(super).unsubscribe;

    void subscribe(InterfaceSubscriber.PacketHandler packet_handler, ref const PacketFilter filter, void* user_data = null)
    {
        bool was = _num_subscribers != 0;
        _subscribers[_num_subscribers++] = InterfaceSubscriber(filter, packet_handler, user_data);
        if (!was)
            on_subscribers_changed(true);
    }

    void unsubscribe(InterfaceSubscriber.PacketHandler packet_handler)
    {
        foreach (i, ref sub; _subscribers[0.._num_subscribers])
        {
            if (sub.recv_packet is packet_handler)
            {
                // remove this subscriber
                if (i < --_num_subscribers)
                    sub = _subscribers[_num_subscribers];
                if (_num_subscribers == 0)
                    on_subscribers_changed(false);
                return;
            }
        }
    }

    // Fired only on the 0<->1 subscriber transition. Default no-op leaves
    // standalone interfaces untouched; BridgeInterface overrides it to drive
    // CPU-port promisc on demand.
    protected void on_subscribers_changed(bool any)
    {
    }

    int forward(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
    {
        if (!running)
        {
            if (callback)
                callback(-1, MessageState.failed);
            return -1;
        }

        foreach (ref subscriber; _subscribers[0.._num_subscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.outgoing) && subscriber.filter.match(packet))
                subscriber.recv_packet(packet, this, PacketDirection.outgoing, subscriber.user_data);
        }

        int result = transmit(packet, callback, queue_policy);
        if (result <= 0 && callback)
            callback(result, result == 0 ? MessageState.complete : MessageState.failed);
        return result;
    }

    void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle > 0, "Invalid message handle");
        assert(false, "Interface does not support message cancellation");
    }

    MessageState msg_state(int msg_handle) const
    {
        assert(msg_handle == 0, "Invalid message handle");
        return MessageState.complete;
    }

    final InterfaceCaps caps() const pure
        => _caps;

    ushort pcap_type() const
        => 0;

    void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
    {
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const nothrow @nogc
    {
        if (buffer.length < "interface:".length + name.length)
            return -1; // Not enough space
        return buffer.concat("interface:", name[]).length;
    }

protected:
    IfStatus _status;
    InterfaceCaps _caps;
    ushort _mtu;        // 0 = auto
    ushort _l2mtu;
    ushort _max_l2mtu;  // 0 = unspecified/unknown

    BufferOverflowBehaviour _send_behaviour;
    BufferOverflowBehaviour _recv_behaviour;

    MonoTime _last_bitrate_sample;
    ulong _last_tx_bytes;
    ulong _last_rx_bytes;

    void on_mtu_changed() {}

    override void online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        _last_bitrate_sample = MonoTime.init;   // next heartbeat establishes the rate baseline
        mark_set!(typeof(this), [ "link-status", "last-status-change-time" ])();
    }

    override void offline()
    {
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        _status.avg_queue_us = 0;
        _status.avg_service_us = 0;
        _status.max_service_us = 0;
        mark_set!(typeof(this), [ "link-status", "last-status-change-time", "link-downs", "tx-rate", "rx-rate",
                                  "avg-queue-time", "avg-service-time", "max-service-time" ])();

        set_link_speed(0);
    }

    abstract int transmit(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null);

    final void incoming_packet(ref Packet packet)
    {
        if (_master)
        {
            add_rx_frame(packet.length);
            fire_subscribers(packet);
            _master.slave_incoming(packet, _slave_id);
            return;
        }

        ingress(packet);
    }

    // Ingress stage between reception and local delivery: switching and station
    // transforms live here. Default: everything terminates locally.
    void ingress(ref Packet packet)
    {
        dispatch(packet);
    }

    final void dispatch(ref Packet packet)
    {
        debug assert(_master is null, "dispatch() on a slaved interface; ingress must enter via incoming_packet()");

        add_rx_frame(packet.length);

        if (packet.has_inline_vlan_tag && !packet.promote_vlan_tag())
        {
            add_rx_drop();
            return;
        }

        fire_subscribers(packet);

        while (packet.vlan_tag != VlanTag.none)
        {
            ushort vid = packet.vid;
            if (vid == 0)
            {
                packet.consume_vlan_tag();
                if (!packet.has_inline_vlan_tag)
                    break;
                if (!packet.promote_vlan_tag())
                {
                    add_rx_drop();
                    return;
                }
                continue;
            }

            if (_vlans.length > 0)
            {
                auto v = _vlans[].ptr;
                VLANInterface vif = v[0];
                if (vif.vlan == vid && vif.tag == packet.vlan_tag)
                    goto got_vlan;
                foreach (i; 1 .. _vlans.length)
                {
                    vif = v[i];
                    if (vif.vlan == vid && vif.tag == packet.vlan_tag)
                    {
                        v[i] = v[i-1];
                        v[i-1] = vif;
                        goto got_vlan;
                    }
                }
                goto no_vlan;

            got_vlan:
                vif.vlan_incoming(packet);
                return;

            no_vlan:
                add_rx_drop();
                return;
            }
            add_rx_drop();
            return;
        }

        if (auto handler = _frame_handlers[packet.type])
            handler(packet, this);
    }

    void slave_incoming(ref Packet packet, byte slave_id)
    {
        assert(false, "Override this method to implement a _master interface");
    }

    final void fire_subscribers(ref Packet packet)
    {
        if (!_num_subscribers)
            return;
        foreach (ref subscriber; _subscribers[0.._num_subscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.incoming) && subscriber.filter.match(packet))
                subscriber.recv_packet(packet, this, PacketDirection.incoming, subscriber.user_data);
        }
    }

    bool bind_vlan(VLANInterface vlan_interface, bool remove)
    {
        if (remove)
        {
            foreach (i, v; _vlans[])
            {
                if (v is vlan_interface)
                {
                    _vlans.remove(i);
                    return true;
                }
            }
            return false;
        }
        debug
        {
            foreach (v; _vlans[])
                assert(!(v.tag == vlan_interface.tag && v.vlan == vlan_interface.vlan), "VLAN already bound!");
        }
        _vlans ~= vlan_interface;
        return true;
    }

    final void update_service_times(uint wait_us, uint service_us)
    {
        // EWMA: 7/8 * old + 1/8 * new
        _status.avg_queue_us = (_status.avg_queue_us*7 + wait_us) / 8;
        _status.avg_service_us = (_status.avg_service_us*7 + service_us) / 8;

        ulong dirty = ulong(1) << prop_index!(typeof(this), "avg-queue-time") |
                      ulong(1) << prop_index!(typeof(this), "avg-service-time");

        if (service_us > _status.max_service_us)
        {
            _status.max_service_us = service_us;
            dirty |= ulong(1) << prop_index!(typeof(this), "max-service-time");
        }

        _props_set |= dirty;
        _mark_dirty(dirty);
    }

    final void set_link_speed(ulong tx, ulong rx)
    {
        if (_status.tx_link_speed == tx && _status.rx_link_speed == rx)
            return;
        _status.tx_link_speed = tx;
        _status.rx_link_speed = rx;
        mark_set!(typeof(this), [ "tx-link-speed", "rx-link-speed" ])();

        // a tagged interface rides its parent's wire, so it inherits whatever rate we just learned
        foreach (v; _vlans[])
            v.set_link_speed(tx, rx);
        if (_master)
            _master.on_slave_link_speed_changed();
    }

    final void set_link_speed(ulong speed)
        => set_link_speed(speed, speed);

    void on_slave_link_speed_changed() {}

    final void add_tx_frame(size_t bytes)
    {
        ++_status.tx_packets;
        _status.tx_bytes += bytes;
        mark_set!(typeof(this), [ "tx-bytes", "tx-packets" ])();
    }

    final void add_rx_frame(size_t bytes)
    {
        ++_status.rx_packets;
        _status.rx_bytes += bytes;
        mark_set!(typeof(this), [ "rx-bytes", "rx-packets" ])();
    }

    final void add_tx_drop()
    {
        ++_status.tx_dropped;
        mark_set!(typeof(this), [ "tx-dropped" ])();
    }

    final void add_rx_drop()
    {
        ++_status.rx_dropped;
        mark_set!(typeof(this), [ "rx-dropped" ])();
    }

    // TODO: this package section should be refactored out of existence!
package:
    BaseInterface _master;
    byte _slave_id;

    Packet[] _send_queue;

    void queue_update_service_times(uint wait_us, uint service_us)
    {
        update_service_times(wait_us, service_us);
    }

//private:
protected: // TODO: should probably be private?
    InterfaceSubscriber[4] _subscribers;
    ubyte _num_subscribers;
    int _kernel_ifindex;    // OS netdev ifindex when a platform backend backs this interface (0 = none)
    Array!VLANInterface _vlans;
}


class InterfaceModule : Module
{
    mixin DeclareModule!"interface";
nothrow @nogc:

    override void pre_init()
    {
        g_app.register_bitfield!InterfaceCaps();
        g_app.register_enum!ConnectionStatus();
        g_app.register_enum!LinkStatus();
        g_app.register_enum!VlanTag();

        g_app.console.register_collection!BaseInterface();
    }

    override void init()
    {
        version (UseInternalIPStack) {}
        else
            register_frame_handler(PacketType.ethernet, &on_ethernet_frame);

        g_app.console.register_collection!InterfaceGroup();
        g_app.console.register_collection!UDPInterface();
        g_app.console.register_collection!VLANInterface();
    }

    override void post_init()
    {
        // post_init: the platform ethernet collections own the scope by now, so these extend it
        g_app.console.register_command!(mac_ping, "ping")("/interface/ethernet", this);
        g_app.console.register_command!(mac_discover, "discover")("/interface/ethernet", this);
    }

    override void deinit()
    {
        version (UseInternalIPStack) {}
        else
            unregister_frame_handler(PacketType.ethernet);

        close_udp_endpoints();
    }

    override void update()
    {
        Collection!BaseInterface().update_all();
        update_udp_endpoints();
        expire_mac_probes();
    }

    MacPingState mac_ping(Session session, MACAddress address, Nullable!uint count)
    {
        if (!address)
        {
            session.write_line("ping requires a destination mac address");
            return null;
        }
        if (address.is_multicast)
        {
            session.write_line("ping is unicast; use discover to enumerate the segment");
            return null;
        }
        return alloc!MacPingState(session, address, count ? count.value : 4);
    }

    static class MacPingState : CommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.in_progress;

        MACAddress dst;
        uint count;
        uint sent;
        uint replies;
        MonoTime last_send;
        Array!uint txids;

        this(Session session, MACAddress dst, uint count)
        {
            super(session, null);
            this.dst = dst;
            this.count = count ? count : 1;
            send_round();
        }

        override CommandCompletionState update()
        {
            if (state == CommandCompletionState.cancel_requested)
            {
                cancel_round();
                state = CommandCompletionState.cancelled;
                return state;
            }
            if (getTime() - last_send >= 1.seconds)
            {
                cancel_round();
                if (sent >= count)
                {
                    session.write_line(replies, " replies for ", sent, " requests");
                    state = CommandCompletionState.finished;
                }
                else
                    send_round();
            }
            return state;
        }

        override void request_cancel()
        {
            if (state == CommandCompletionState.in_progress)
                state = CommandCompletionState.cancel_requested;
        }

    private:
        void send_round()
        {
            ++sent;
            last_send = getTime();
            foreach_ether_station((EthernetStation s) {
                if (s.running)
                    txids ~= s.ping(dst, &on_reply);
            });
        }

        void cancel_round()
        {
            foreach (t; txids[])
                mac_ping_cancel(t);
            txids.clear();
        }

        void on_reply(MACAddress from, Duration rtt, scope const(char)[] identity)
        {
            ++replies;
            if (identity.length)
                session.write_line("reply from ", from, ": time=", rtt, " \"", identity, "\"");
            else
                session.write_line("reply from ", from, ": time=", rtt);
        }
    }

    MacDiscoverState mac_discover(Session session)
    {
        return alloc!MacDiscoverState(session);
    }

    static class MacDiscoverState : CommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.in_progress;

        uint txid;
        MonoTime begun;
        Array!MACAddress seen;

        this(Session session)
        {
            super(session, null);
            begun = getTime();
            txid = mac_discover_begin(&on_report);
            foreach_ether_station((EthernetStation s) {
                if (s.running)
                    s.discover(txid);
            });
        }

        override CommandCompletionState update()
        {
            if (state == CommandCompletionState.cancel_requested)
            {
                mac_discover_cancel(txid);
                state = CommandCompletionState.cancelled;
                return state;
            }
            if (getTime() - begun >= 2.seconds)
            {
                mac_discover_cancel(txid);
                session.write_line(seen.length, " stations found");
                state = CommandCompletionState.finished;
            }
            return state;
        }

        override void request_cancel()
        {
            if (state == CommandCompletionState.in_progress)
                state = CommandCompletionState.cancel_requested;
        }

    private:
        void on_report(MACAddress from, scope const(char)[] identity, scope const(ulong)[] addresses)
        {
            // stations answer each of our querying stations; report each responder once
            foreach (m; seen[])
            {
                if (m == from)
                    return;
            }
            seen ~= from;

            if (identity.length)
                session.write_line(from, " \"", identity, "\"");
            else
                session.write_line(from);
            foreach (a; addresses)
            {
                import urt.conv : format_uint;
                char[15] hex = void;
                ptrdiff_t len = format_uint(a & 0x0FFF_FFFF_FFFF_FFFF, hex, 16, 15, '0');
                session.write_line("    ", cast(PacketType)(a >> 60), ":", hex[0 .. len]);
            }
        }
    }

    final String add_interface_name(Session session, const(char)[] name, const(char)[] default_name_prefix)
    {
        if (name.empty)
            name = Collection!BaseInterface().generate_name(default_name_prefix);
        else if (Collection!BaseInterface().get(name))
        {
            session.write_line("Interface '", name, " already exists");
            return String();
        }

        return name.make_string();
    }

    import urt.meta.nullable;

/+ // TODO: generic print does this now, but we need to improve generic print to show the right columns!!
    // /interface/print command
    void print(Session session, Nullable!bool stats)
    {
        import urt.util;

        size_t name_len = 4;
        size_t type_len = 4;
        foreach (iface; interfaces.values)
        {
            name_len = max(name_len, iface.name.length);
            type_len = max(type_len, iface.type.length);

            // TODO: MTU stuff?
        }

        session.write_line("Flags: R - RUNNING; S - SLAVE");
        if (stats)
        {
            size_t rx_len = 7;
            size_t tx_len = 7;
            size_t rp_len = 9;
            size_t tp_len = 9;
            size_t rd_len = 7;
            size_t td_len = 7;

            foreach (iface; interfaces.values)
            {
                rx_len = max(rx_len, iface.status.rx_bytes.format_int(null));
                tx_len = max(tx_len, iface.status.tx_bytes.format_int(null));
                rp_len = max(rp_len, iface.status.rx_packets.format_int(null));
                tp_len = max(tp_len, iface.status.tx_packets.format_int(null));
                rd_len = max(rd_len, iface.status.rx_dropped.format_int(null));
                td_len = max(td_len, iface.status.tx_dropped.format_int(null));
            }

            session.writef(" ID     {0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {12, *13}\n",
                            "NAME", name_len,
                            "RX-BYTE", rx_len, "TX-BYTE", tx_len,
                            "RX-PACKET", rp_len, "TX-PACKET", tp_len,
                            "RX-DROP", rd_len, "TX-DROP", td_len);

            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {1}{2}  {3, -*4}  {5, *6}  {7, *8}  {9, *10}  {11, *12}  {13, *14}  {15, *16}\n",
                                i, iface.status.link_status ? 'R' : ' ', iface._master ? 'S' : ' ',
                                iface.name, name_len,
                                iface.status.rx_bytes, rx_len, iface.status.tx_bytes, tx_len,
                                iface.status.rx_packets, rp_len, iface.status.tx_packets, tp_len,
                                iface.status.rx_dropped, rd_len, iface.status.tx_dropped, td_len);
                ++i;
            }
        }
        else
        {
            session.writef(" ID     {0, -*1}  {2, -*3}  MAC-ADDRESS\n", "NAME", name_len, "TYPE", type_len);
            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {6}{7}  {1, -*2}  {3, -*4}  {5}\n", i, iface.name, name_len, iface.type, type_len, iface.mac, iface.status.link_status ? 'R' : ' ', iface._master ? 'S' : ' ');
                ++i;
            }
        }
    }
+/

private:
    void on_ethernet_frame(ref Packet packet, BaseInterface iface)
    {
        if (packet.eth.ether_type == EtherType.ow)
            ether_transport_input(packet, iface);
    }
}


private:
