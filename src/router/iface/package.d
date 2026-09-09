module router.iface;

import urt.array;
import urt.conv;
import urt.inet : AddressFamily, InetAddress, InetScopeProvider, register_inet_scope_provider;
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
    delivery_failed,
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

    // Process-local zone identity: the InetAddress scope id that names this interface.
    // Dense, never reclaimed, and re-claimed by a same-name recreation; see interface_for_scope.
    final uint scope_id() const pure
        => id.slot;

    // OS netdev ifindex, set by a platform backend (e.g. the Linux kernel-bridge
    // offload) when this interface is backed by a kernel netdev that isn't a
    // LinuxRawEthernet. The IP mirror resolves it via this accessor.
    final int kernel_ifindex() const pure
        => _kernel_ifindex;
    // Windows numbers IPv4 and IPv6 bindings separately; everywhere else one index serves both.
    final int kernel_ifindex6() const pure
    {
        version (Windows)
            return _kernel_ifindex6;
        else
            return _kernel_ifindex;
    }
    final void set_kernel_ifindex(int idx, int idx6 = 0)
    {
        _kernel_ifindex = idx;
        version (Windows)
            _kernel_ifindex6 = idx6;
    }

    // alias the base functions into this scope to merge the overload sets
    alias subscribe = typeof(super).subscribe;
    alias unsubscribe = typeof(super).unsubscribe;

    void subscribe(InterfaceSubscriber.PacketHandler packet_handler, ref const PacketFilter filter, void* user_data = null)
    {
        if (_num_subscribers >= _subscribers.length)
        {
            log.error("subscriber table full (", cast(uint)_subscribers.length, " slots); refusing subscription");
            return;
        }
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
    InterfaceSubscriber[8] _subscribers;
    ubyte _num_subscribers;
    int _kernel_ifindex;    // OS netdev ifindex when a platform backend backs this interface (0 = none)
    version (Windows)
        int _kernel_ifindex6;
    Array!VLANInterface _vlans;
}

// Zone ids (InetAddress.scope_id): an OpenWatt interface's collection slot, or foreign_scope | host
// index for a link OpenWatt does not manage. Contract: docs/wip/NETWORKING.draft.md, "Interface scope ids".
enum uint foreign_scope = 0x8000_0000;

BaseInterface interface_for_scope(uint scope_id)
{
    if (scope_id == 0 || scope_id > CID.id_mask)
        return null;
    return get_item!BaseInterface(scope_cid(scope_id));
}

BaseInterface interface_for_kernel_index(AddressFamily family, int index)
{
    if (index == 0)
        return null;
    foreach (iface; Collection!BaseInterface().values)
        if ((family == AddressFamily.ipv6 ? iface.kernel_ifindex6 : iface.kernel_ifindex) == index)
            return iface;
    return null;
}

private bool scope_to_native(AddressFamily family, uint scope_id, out uint native)
{
    if (scope_id & foreign_scope)
    {
        native = scope_id & ~foreign_scope;
        return native != 0;
    }
    BaseInterface iface = interface_for_scope(scope_id);
    if (!iface)
        return false;
    int index = family == AddressFamily.ipv6 ? iface.kernel_ifindex6 : iface.kernel_ifindex;
    if (index == 0)
        return false;
    native = uint(index);
    return true;
}

private uint scope_from_native(AddressFamily family, uint native)
{
    debug assert(native < foreign_scope, "host interface index has no foreign encoding");
    if (BaseInterface iface = interface_for_kernel_index(family, int(native)))
        return iface.scope_id;
    return foreign_scope | native;
}

// the name outlives the object: a destroyed interface's zone still prints as its name
private const(char)[] scope_name(uint scope_id, char[] buffer)
{
    if (scope_id & foreign_scope)
        return (scope_id & ~foreign_scope) ? buffer[0 .. (scope_id & ~foreign_scope).format_uint(buffer)] : null;
    return scope_id <= CID.id_mask ? get_id_dstring(scope_cid(scope_id)) : null;
}

private uint scope_parse(const(char)[] zone)
{
    BaseInterface iface = Collection!BaseInterface().get(zone);
    return iface ? iface.scope_id : 0;
}

private CID scope_cid(uint scope_id) pure
    => CID((uint(BaseInterface.collection_id) << CID.id_bits) | scope_id);

private __gshared immutable InetScopeProvider g_scope_provider = InetScopeProvider(&scope_to_native, &scope_from_native, &scope_name, &scope_parse);


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
        register_inet_scope_provider(&g_scope_provider);
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
        g_app.console.register_command!(ping, "ping")("/", this);
        g_app.console.register_command!(mac_discover, "discover")("/interface/ethernet", this);
    }

    override void deinit()
    {
        version (UseInternalIPStack) {}
        else
            unregister_frame_handler(PacketType.ethernet);

        close_udp_endpoints();
        register_inet_scope_provider(null);
    }

    override void update()
    {
        Collection!BaseInterface().update_all();
        update_udp_endpoints();
        expire_mac_probes();
    }

    CommandState ping(Session session, const(char)[] address, Nullable!uint count, Nullable!BaseInterface iface)
    {
        import urt.inet : InetAddress, AddressFamily;
        InetAddress destination;
        if (!parse_ping_address(address, destination) || destination.addr_any)
        {
            session.write_line("ping requires an IPv4, IPv6 or MAC destination address");
            return null;
        }
        if (destination.family == AddressFamily.ether)
        {
            MACAddress mac;
            mac.b = destination._a.ether.addr;
            return mac_ping(session, mac, count, iface ? iface.value : null);
        }
        BaseInterface selected = iface ? iface.value : null;
        if (destination.family == AddressFamily.ipv6 && destination._a.ipv6.scope_id)
        {
            BaseInterface zone = interface_for_scope(destination._a.ipv6.scope_id);
            if (!zone || (selected && selected !is zone))
            {
                session.write_line(zone ? "zone and iface name different interfaces" : "zone is not an OpenWatt interface");
                return null;
            }
            selected = zone;
        }
        static if (has_ip)
        version (UseInternalIPStack)
        {
            import protocol.ip : IPModule;
            return get_module!IPModule.ping(session, destination, count, selected);
        }
        session.write_line("IP ping is unavailable in this build");
        return null;
    }

    private static bool parse_ping_address(const(char)[] text, out InetAddress address)
    {
        import urt.inet : InetAddress, IPAddr, IPv6Addr;
        if (!text.length)
            return false;
        IPAddr v4;
        if (v4.fromString(text) == text.length)
        {
            address = InetAddress(v4, 0);
            return true;
        }
        IPv6Addr v6;
        ptrdiff_t taken = v6.fromString(text);
        if (taken == text.length)
        {
            address = InetAddress(v6, 0);
            return true;
        }
        if (taken > 0 && text[taken] == '%')
        {
            import urt.inet : inet_scope_parse;
            uint scope_id;
            ptrdiff_t zone = inet_scope_parse(text[taken + 1 .. $], scope_id);
            if (zone > 0 && taken + 1 + zone == text.length)
            {
                address = InetAddress(v6, 0, 0, scope_id);
                return true;
            }
        }
        MACAddress mac;
        if (mac.fromString(text) == text.length)
        {
            address = InetAddress(mac.b, 0);
            return true;
        }
        return false;
    }

    unittest
    {
        import urt.inet : AddressFamily;
        import urt.variant : Variant;
        InetAddress address;
        assert(parse_ping_address("192.0.2.1", address) && address.family == AddressFamily.ipv4);
        assert(parse_ping_address("2001:db8::1", address) && address.family == AddressFamily.ipv6);
        assert(parse_ping_address("fe80::1", address) && address.family == AddressFamily.ipv6);
        assert(parse_ping_address("::1", address) && address.family == AddressFamily.ipv6);
        assert(parse_ping_address("02:13:37:aa:bb:64", address) && address.family == AddressFamily.ether);
        assert(parse_ping_address("021337aabb64", address) && address.family == AddressFamily.ether);
        assert(parse_ping_address("0213:37aa:bb64", address) && address.family == AddressFamily.ether);
        assert(parse_ping_address("fe80::1%3", address) && address._a.ipv6.scope_id == 3);
        foreach (text; ["", "host.example", "192.0.2.1:80", "[::1]:80", "fe80::1%eth0", "fe80::1%", "fe80::1%3:80", "2001:db8::1junk", "02:13:37:aa:bb:64junk"])
            assert(!parse_ping_address(text, address));

        InterfaceModule module_ = alloc!InterfaceModule(null);
        scope(exit) free(module_);
        Console* console = alloc!Console(null, StringLit!"test.ping-dispatch");
        console.register_command!(ping, "ping")("/", module_);
        StringSession session = console.createSession!StringSession();
        scope(exit)
        {
            console.destroy_session(session);
            Collection!Session().update_all();
        }
        Variant result;
        console.execute(session, "/ping address=ff:ff:ff:ff:ff:ff", result);
        assert(session.getOutput().contains("use discover"));
        session.clearOutput();
        console.execute(session, "/ping address=garbage", result);
        assert(session.getOutput().contains("requires an IPv4, IPv6 or MAC destination address"));
    }

    private MacPingState mac_ping(Session session, MACAddress address, Nullable!uint count, BaseInterface iface)
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
        EthernetStation station = dyn_cast!EthernetStation(iface);
        if (iface && !station)
        {
            session.write_line("MAC ping requires an Ethernet station");
            return null;
        }
        return alloc!MacPingState(session, address, count ? count.value : 4, station);
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
        ObjectRef!EthernetStation iface;
        bool subscribed;

        this(Session session, MACAddress dst, uint count, EthernetStation iface)
        {
            super(session, null);
            this.dst = dst;
            this.count = count ? count : 1;
            this.iface = iface;
            if (iface)
            {
                if (!iface.running)
                {
                    request_cancel();
                    return;
                }
                iface.subscribe(&iface_state_change);
                subscribed = true;
            }
            send_round();
        }

        ~this()
        {
            cancel_round();
            release_interface();
        }

        override CommandCompletionState update()
        {
            if (state == CommandCompletionState.cancel_requested)
            {
                cancel_round();
                state = CommandCompletionState.cancelled;
                return state;
            }
            if (state != CommandCompletionState.in_progress)
                return state;
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
            {
                cancel_round();
                release_interface();
                state = CommandCompletionState.cancel_requested;
            }
        }

    private:
        void release_interface()
        {
            if (subscribed)
            {
                if (auto i = iface.get)
                    i.unsubscribe(&iface_state_change);
                subscribed = false;
            }
        }

        void iface_state_change(ActiveObject, StateSignal signal)
        {
            if (signal == StateSignal.offline || signal == StateSignal.destroyed)
                request_cancel();
        }

        void send_round()
        {
            if (subscribed && iface is null)
            {
                request_cancel();
                return;
            }
            ++sent;
            last_send = getTime();
            if (auto i = iface.get)
            {
                txids ~= i.ping(dst, &on_reply);
                return;
            }
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

unittest
{
    import urt.inet : IPv6Addr, inet_scope_from_native, inet_scope_to_native;
    import urt.mem : alloc, free;

    static class Link : EthernetStation
    {
        enum type_name = "scope-test-link";
    nothrow @nogc:
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Link, id, flags);
            _state = State.running;
        }
        override void medium_tx(ref Packet packet) {}
    }

    Link a = Collection!Link().create("scope-test-a");
    Link b = Collection!Link().create("scope-test-b");
    uint sa = a.scope_id, sb = b.scope_id;
    assert(sa && sb && sa != sb && sa < foreign_scope && sb < foreign_scope);
    assert(interface_for_scope(sa) is a && interface_for_scope(sb) is b);
    assert(interface_for_scope(0) is null && interface_for_scope(foreign_scope | sa) is null && interface_for_scope(CID.id_mask) is null);

    // the same link-local bytes on two links are two addresses, each resolving to its own interface
    IPv6Addr ll = IPv6Addr(0xfe80, 0, 0, 0, 0, 0, 0, 1);
    InetAddress on_a = InetAddress(ll, 0, 0, sa), on_b = InetAddress(ll, 0, 0, sb);
    assert(on_a != on_b && on_a.same_addr(on_b));
    assert(interface_for_scope(on_a._a.ipv6.scope_id) is a && interface_for_scope(on_b._a.ipv6.scope_id) is b);

    // native translation follows the kernel index and refuses zones the host stack cannot name
    register_inet_scope_provider(&g_scope_provider);
    scope(exit) register_inet_scope_provider(null);
    uint native;
    assert(!inet_scope_to_native(AddressFamily.ipv6, sa, native));
    a.set_kernel_ifindex(7, 7);
    assert(inet_scope_to_native(AddressFamily.ipv6, sa, native) && native == 7);
    assert(inet_scope_to_native(AddressFamily.ipv4, sa, native) && native == 7);
    assert(inet_scope_from_native(AddressFamily.ipv6, 7) == sa);
    assert(inet_scope_from_native(AddressFamily.ipv6, 99) == (foreign_scope | 99));
    assert(inet_scope_to_native(AddressFamily.ipv6, foreign_scope | 99, native) && native == 99);
    assert(!inet_scope_to_native(AddressFamily.ipv6, sb, native));
    assert(!inet_scope_to_native(AddressFamily.ipv6, CID.id_mask, native));

    // text form: names are OpenWatt interfaces, numbers are host indices
    char[64] tmp;
    assert(tmp[0 .. on_a.toString(tmp, null, null)] == "[fe80::1%scope-test-a]:0");
    InetAddress parsed;
    assert(parsed.fromString("fe80::1%scope-test-b") == 20 && parsed == on_b);
    assert(parsed.fromString("fe80::1%7") == 9 && parsed._a.ipv6.scope_id == sa);
    assert(parsed.fromString("fe80::1%99") == 10 && parsed._a.ipv6.scope_id == (foreign_scope | 99));
    assert(tmp[0 .. parsed.toString(tmp, null, null)] == "[fe80::1%99]:0");
    assert(parsed.fromString("fe80::1%no-such-iface") == -1);
    assert(!inet_scope_to_native(AddressFamily.ipv6, foreign_scope, native));
    parsed._a.ipv6.scope_id = foreign_scope;
    assert(parsed.toString(tmp, null, null) == -1);
    assert(!inet_scope_to_native(AddressFamily.ipv6, foreign_scope, native));
    parsed._a.ipv6.scope_id = foreign_scope;
    assert(parsed.toString(tmp, null, null) == -1);


    // destruction leaves the id dangling; recreation at the same name reclaims it, a new name never does
    Collection!Link().remove(a);
    free(a);
    assert(interface_for_scope(sa) is null);
    assert(!inet_scope_to_native(AddressFamily.ipv6, sa, native));
    assert(tmp[0 .. on_a.toString(tmp, null, null)] == "[fe80::1%scope-test-a]:0");
    assert(parsed.fromString("fe80::1%scope-test-a") == -1);
    Link a2 = Collection!Link().create("scope-test-a");
    Link c = Collection!Link().create("scope-test-c");
    scope(exit)
    {
        Collection!Link().remove(a2);
        Collection!Link().remove(b);
        Collection!Link().remove(c);
        free(a2);
        free(b);
        free(c);
    }
    assert(a2.scope_id == sa && interface_for_scope(sa) is a2);
    assert(c.scope_id != sa && c.scope_id != sb);
}
