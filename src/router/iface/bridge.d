module router.iface.bridge;

import urt.array;
import urt.log;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.features : has_modbus;
import manager.plugin;

import router.iface;
import router.iface.address_table;
import router.iface.ethernet;
import router.iface.vlan;

nothrow @nogc:


// Kernel-bridge offload seam (docs/LINUX_DATAPLANE.md Phase 3). A platform
// backend (driver.linux.bridge on Linux) installs these so a BridgeInterface
// can drive a kernel bridge without router.iface importing any driver.* module.
// The CPU-port sink injects a frame into the kernel-switched ethernet segment;
// it returns <0 on failure (mirrors BaseInterface.forward's convention).
alias CpuPortSink = int delegate(ref Packet packet) nothrow @nogc;
alias MemberAddedHook = void delegate(BridgeInterface bridge, BaseInterface member) nothrow @nogc;
alias CpuPromiscHook = void delegate(BridgeInterface bridge) nothrow @nogc;

__gshared MemberAddedHook g_bridge_member_added;
__gshared CpuPromiscHook g_bridge_cpu_promisc_changed;

void register_bridge_offload_hooks(MemberAddedHook member_added, CpuPromiscHook promisc_changed)
{
    g_bridge_member_added = member_added;
    g_bridge_cpu_promisc_changed = promisc_changed;
}


// Bridge switches two domains, split by InterfaceCaps.ethernet:
//  - the ethernet domain: ethernet members, the kernel-offloaded segment via the
//    CPU conduit, and the attachment (frames addressed to the bridge itself)
//  - the exotic domain: exotic members, local delivery, and the attachment
//    (exotic packets crossing the ethernet domain OW-encapsulated)
// The attachment appears in both: it is where the domains meet.
class BridgeInterface : EthernetStation
{
    alias Properties = AliasSeq!(Prop!("vlan-filtering", vlan_filtering),
                                 Prop!("pvid", pvid),
                                 Prop!("ingress-filtering", ingress_filtering),
                                 Prop!("untagged-egress", untagged_egress));
nothrow @nogc:

    enum type_name = "bridge";
    enum path = "/interface/bridge";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BridgeInterface, id, flags);
        adopt_generated_mac();
        _address_table = AddressTable(32);
        _address_table.insert(mac.ul | (ulong(PacketType.ethernet) << 60), _local_port);
    }

    ~this()
    {
        assert(_tracking_active is null, "Should be clear from shutdown()");

        while (_tracking_free)
        {
            // find batch base by scanning for ptr - 1 in the list
            TagTracking* base = _tracking_free;
            scan: while (true)
            {
                for (TagTracking* p = _tracking_free; p; p = p.next)
                {
                    if (p is base - 1)
                    {
                        --base;
                        continue scan;
                    }
                }
                break;
            }

            // unlink batch
            TagTracking** pp = &_tracking_free;
            while (*pp)
            {
                if (*pp >= base && *pp < base + _tracking_batch_size)
                    *pp = (*pp).next;
                else
                    pp = &(*pp).next;
            }
            free(base[0 .. _tracking_batch_size]);
        }
    }

    // Properties...
    bool vlan_filtering() const
        => _vlan_filtering;
    void vlan_filtering(bool value)
    {
        _vlan_filtering = value;
        mark_set!(typeof(this), "vlan-filtering")();
    }

    ushort pvid() const
        => _bridge_port.pvid;
    void pvid(typeof(null))
    {
        _bridge_port.pvid = 0;
        mark_set!(typeof(this), "pvid")();
    }
    const(char)[] pvid(ushort value)
    {
        if (value == 0 || value > 4094)
            return "invalid vlan id";
        _bridge_port.pvid = value;
        mark_set!(typeof(this), "pvid")();
        return null;
    }

    bool ingress_filtering() const
        => _bridge_port.ingress_filtering;
    void ingress_filtering(bool value)
    {
        _bridge_port.ingress_filtering = value;
        mark_set!(typeof(this), "ingress-filtering")();
    }

    bool untagged_egress() const
        => _bridge_port.untagged_egress;
    void untagged_egress(bool value)
    {
        _bridge_port.untagged_egress = value;
        mark_set!(typeof(this), "untagged-egress")();
    }

    // API...

    bool add_member(BaseInterface iface, ushort pvid = 1, bool ingress_filtering = true, bool untagged_egress = true)
    {
        assert(iface !is this, "Cannot add a bridge to itself!");
        assert(_members.length < _cpu_port, "Too many _members in the bridge!"); // member indices live below the pseudo-ports
        assert(!(iface.flags & ObjectFlags.slave), "Interface is already slaved!");

        ubyte port = cast(ubyte)_members.length;
        if (!iface.set_master(this, port))
            return false;
        _members ~= BridgePort(iface, pvid, ingress_filtering, untagged_egress);

        static if (has_modbus)
        {
            // TODO: move this logic into the modbus interface...
            // For modbus member interfaces, we'll pre-populate the MAC table with known device addresses...
            import protocol.modbus;
            import protocol.modbus.iface;
            ModbusInterface mb = dyn_cast!ModbusInterface(iface);
            if (mb)
            {
                ushort vlan = 0;

                auto mod_mb = get_module!ModbusProtocolModule;
                foreach (ref map; mod_mb.remote_servers.values)
                {
                    if (map.iface is iface)
                        _address_table.insert(ulong(map.universal_address) | (ulong(vlan) << 48) | (ulong(PacketType.modbus) << 60), port);
                }
            }
        }

        // a new ethernet member extends the segment: re-prime the neighbour table
        if (running && (iface.caps & InterfaceCaps.ethernet))
            station_link_up();

        // Member added to a running bridge: let the backend (re-)evaluate offload --
        // a second netdev member may newly qualify it, or an already-offloaded
        // bridge may need the new netdev enslaved. (Members added before the bridge
        // is running are picked up when it goes online. Removal stays unsupported.)
        if (running && g_bridge_member_added)
            g_bridge_member_added(this, iface);

        if (running)
            update_link_speed();

        return true;
    }

    bool remove_member(size_t index)
    {
        if (index >= _members.length)
            return false;

        _members[index].iface.set_master(null, 0);
        _members.remove(index);

        // TODO: update the MAC table to adjust all the port numbers!
        assert(false);

        // TODO: all the subscriber user_data's are wrong!!!
        //       we need to unsubscribe and resubscribe all the _members...
        assert(false);

        // TODO: scan active TagTracking entries and remove PortTags for the removed
        //       interface, decrementing n_pending for each. If n_pending reaches 0,
        //       fire the upstream callback and recycle the entry.

        return true;
    }

    bool remove_member(const(char)[] name)
    {
        foreach (i, ref m; _members)
        {
            if (m.iface.name[] == name[])
                return remove_member(i);
        }
        return false;
    }

    // --- kernel-bridge offload seam (driver.linux.bridge drives this) ---

    size_t member_count() const
        => _members.length;

    BaseInterface member_iface(size_t i)
        => _members[i].iface;

    // Mark/unmark a member as kernel-offloaded (by identity, not removal -- the
    // member stays in _members, keeping port indices and the address table stable).
    void set_member_offloaded(BaseInterface iface, bool offloaded)
    {
        foreach (ref m; _members)
        {
            if (m.iface is iface)
            {
                m.offloaded = offloaded;
                return;
            }
        }
    }

    void attach_cpu_port(CpuPortSink sink)
    {
        _cpu.send = sink;
        _cpu.active = true;
    }

    void detach_cpu_port()
    {
        _cpu.active = false;
        _cpu.send = null;
    }

    // Ingress from the kernel-switched ethernet segment (the offload module drains
    // the CPU-port socket and feeds frames here). This is a switching ingress like
    // any member port, with src = _cpu_port.
    void cpu_port_incoming(ref Packet packet)
    {
        if (!running || !_cpu.active)
            return;

        // Promisc surfaces frames the kernel already switched among its own ports
        // (a sniffer is attached): feed subscribers, nothing else to do.
        ulong dst = destination_address(packet);
        if (!dst.is_multicast_address)
        {
            int dp = _address_table.get(dst);
            if (dp >= 0 && (dp == _cpu_port || (dp < _members.length && _members[dp].offloaded)))
            {
                fire_subscribers(packet);
                return;
            }
        }

        ulong src = source_address(packet);
        if (!src.is_multicast_address)
            _address_table.insert(src, _cpu_port);

        send(packet, _cpu_port);
    }

    // The CPU port only needs promiscuous mode to feed a sniffer; bridge-addressed
    // and broadcast/multicast frames reach it without it.
    bool cpu_port_wants_promisc() const
        => _num_subscribers != 0;

    protected override void on_subscribers_changed(bool any)
    {
        if (_cpu.active && g_bridge_cpu_promisc_changed)
            g_bridge_cpu_promisc_changed(this);
    }

    protected override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)*)
    {
        // this is a packet entering the bridge from the bridge interface...

        if (_vlan_filtering)
        {
            if (!classify_vlan(packet, _bridge_port))
            {
                add_tx_drop();
                return -1;
            }
        }

        ulong src = source_address(packet);
        if (!src.is_multicast_address)
            _address_table.insert(src, _local_port);

        if (callback)
            return send_tracked(packet, callback);

        send(packet, _local_port);

        add_tx_frame(packet.data.length);

        return 0;
    }

    final override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle > 0, "Invalid message handle");

        TagTracking* entry = _tracking_active;
        while (entry)
        {
            if (entry.bridge_tag == msg_handle)
            {
                auto cb = entry.upstream_cb;
                entry.upstream_cb = null; // suppress on_port_callback firing upstream during abort
                foreach (ref pt; entry.port_tags[])
                {
                    if (pt.tag > 0)
                        pt.iface.abort(pt.tag, reason);
                }
                if (cb)
                    cb(msg_handle, reason);
                recycle_tracking(entry);
                return;
            }
            entry = entry.next;
        }
    }

    final override MessageState msg_state(int msg_handle) const
    {
        const(TagTracking)* entry = _tracking_active;
        while (entry)
        {
            if (entry.bridge_tag == msg_handle)
            {
                if (entry.port_tags.length == 1)
                    return entry.port_tags[0].iface.msg_state(entry.port_tags[0].tag);
                return MessageState.in_flight;
            }
            entry = entry.next;
        }
        return MessageState.complete;
    }

protected:

    override void online()
    {
        super.online();
        update_link_speed();
    }

    override void on_slave_link_speed_changed()
    {
        update_link_speed();
    }

    // a frame leaves by exactly one port, so the fastest member is what the bridge can actually do;
    // members that don't know their rate don't vote
    final void update_link_speed()
    {
        ulong tx = 0, rx = 0;
        foreach (ref m; _members)
        {
            if (m.iface.tx_link_speed > tx)
                tx = m.iface.tx_link_speed;
            if (m.iface.rx_link_speed > rx)
                rx = m.iface.rx_link_speed;
        }
        set_link_speed(tx, rx);
    }

    override CompletionStatus shutdown()
    {
        while (_tracking_active)
        {
            TagTracking* entry = _tracking_active;
            auto cb = entry.upstream_cb;
            entry.upstream_cb = null;
            foreach (ref pt; entry.port_tags[])
            {
                if (pt.tag > 0)
                    pt.iface.abort(pt.tag);
            }
            if (cb)
                cb(entry.bridge_tag, MessageState.aborted);
            recycle_tracking(entry);
        }
        return super.shutdown();
    }

    override const(char)[] apply_mac(ref MACAddress value)
    {
        ulong type = ulong(PacketType.ethernet) << 60;
        _address_table.remove(mac.ul | type);
        _address_table.insert(value.ul | type, _local_port);
        return null;
    }

    override void update()
    {
        super.update();
        // TODO: AddressTable needs TTL mechanism...
//        _address_table.update();
    }

    final override bool bind_vlan(VLANInterface vlan_interface, bool remove)
    {
        if (!super.bind_vlan(vlan_interface, remove))
            return false;
        ulong key = vlan_interface.mac.ul | (ulong(vlan_interface.vlan) << 48) | (ulong(PacketType.ethernet) << 60);
        if (remove)
            _address_table.remove(key);
        else
            _address_table.insert(key, _local_port);
        return true;
    }

    // The medium is the switched ethernet domain: wrapped frames from the station
    // enter switching at the attachment.
    final override void medium_tx(ref Packet packet)
    {
        send(packet, _attach_port);
    }

    // Decapped exotic traffic enters the exotic switching domain at the attachment.
    final override void station_deliver(ref Packet inner)
    {
        ulong src_address = source_address(inner);
        if (!src_address.is_multicast_address)
            _address_table.insert(src_address, _attach_port);

        send(inner, _attach_port);
    }

    final override bool station_owns(ulong address)
    {
        if (cast(PacketType)(address >> 60) == PacketType.ethernet)
            return false;
        int port = _address_table.get(address);
        return port >= 0 && software_domain_port(cast(ubyte)port);
    }

    final override void station_list(PacketType type, scope void delegate(ulong address) nothrow @nogc sink)
    {
        foreach (ulong address, ubyte port; _address_table)
        {
            if (!software_domain_port(port))
                continue;
            PacketType t = cast(PacketType)(address >> 60);
            if (t == PacketType.ethernet)
                continue;
            if (type != PacketType.unknown && t != type)
                continue;
            sink(address);
        }
    }

    final override void slave_incoming(ref Packet packet, byte slave_id)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        ubyte src_port = cast(ubyte)slave_id;
        // Offloaded members are RX-idled (the kernel switches them), so they must
        // not deliver frames up to the software bridge.
        debug assert(!_members[src_port].offloaded, "offloaded member should be RX-idled");
        ref const BridgePort port = _members[src_port];
        ulong src_address;

        // check for link-local frames (bridges must not forward link-local frames)
        if (packet.eth.dst.is_link_local && packet.type == PacketType.ethernet)
        {
            // STP/LACP/EAPOL/LLDP... should we support these?
            debug assert(false, "TODO?");
            goto drop_packet;
        }

        if (_vlan_filtering)
        {
            if (!classify_vlan(packet, port))
                goto drop_packet;
        }

        src_address = source_address(packet);
        if (!src_address.is_multicast_address)
            _address_table.insert(src_address, src_port);

        send(packet, src_port);

        debug
        {
            if (packet.type == PacketType.ethernet)
            {
                ulong dst_address = destination_address(packet);
                int dst_port = _address_table.get(dst_address);
                if (dst_port >= 0)
                {
                    if (dst_port != src_port && dst_port < _members.length)
                        log.trace("forward: ", packet.eth.src, " -> ", _members[dst_port].iface.name, "(", packet.eth.dst, ") [", packet.data, "]");
                }
                else
                    log.trace("broadcast: ", packet.eth.src, " -> * [", packet.data, "]");
            }
        }
        return;

    drop_packet:
        add_rx_drop();
    }

private:

    enum ubyte _local_port  = 0xFE;
    enum ubyte _attach_port = 0xFD; // the station (EthernetStation): where the exotic and ethernet domains meet
    enum ubyte _cpu_port    = 0xFC; // kernel-offloaded ethernet segment, reached via the CPU-port AF_PACKET on br-<name>
    enum _tracking_batch_size = 4;

    struct CpuPort
    {
        CpuPortSink send;
        bool active;
    }
    CpuPort _cpu;

    struct BridgePort
    {
        struct VLANMember
        {
            short first, count;
        }
        BaseInterface iface;
        ushort pvid = 1;
        bool ingress_filtering = false;
        bool untagged_egress = true;
        bool offloaded = false;     // enslaved to a kernel bridge; the kernel switches it, OW skips it
    }

    struct PortTag
    {
        BaseInterface iface;
        int tag;
    }

    struct TagTracking
    {
        nothrow @nogc:
        TagTracking* next;
        BridgeInterface bridge;
        MessageCallback upstream_cb;
        Array!PortTag port_tags;
        ubyte bridge_tag;
        ubyte pending;
        bool any_succeeded;

        void on_port_callback(int port_tag, MessageState state) nothrow @nogc
        {
            if (port_tag <= 0)
                return;

            // handle unicast with higher fidelity
            if (port_tags.length == 1)
            {
                if (upstream_cb)
                {
                    upstream_cb(bridge_tag, state);
                    if (state >= MessageState.complete)
                        bridge.recycle_tracking(&this);
                }
                return;
            }

            if (state < MessageState.complete)
                return;
            if (state == MessageState.complete)
                any_succeeded = true;

            if (--pending == 0)
            {
                if (upstream_cb)
                {
                    upstream_cb(bridge_tag, any_succeeded ? MessageState.complete : MessageState.failed);
                    bridge.recycle_tracking(&this);
                }
                return;
            }

            foreach (ref pt; port_tags[])
            {
                if (pt.tag != port_tag)
                    continue;
                pt.tag = 0;
                break;
            }
        }
    }

    bool _vlan_filtering;
    BridgePort _bridge_port;
    Array!BridgePort _members;
    AddressTable _address_table;

    TagTracking* _tracking_free;
    TagTracking* _tracking_active;
    TagAllocator _bridge_tags;

    bool classify_vlan(ref Packet packet, ref const BridgePort port)
    {
        if (packet.has_inline_vlan_tag && !packet.promote_vlan_tag())
            return false;

        bool tagged = packet.vlan_tag != VlanTag.none;
        ushort vid = packet.vid;
        if (!tagged && vid != 0)
            return true;
        if (!tagged || vid == 0)
        {
            if (port.pvid == 0)
                return false;
            packet.vlan = (packet.vlan & 0xF000) | port.pvid;
            return true;
        }
        if (vid != port.pvid && port.ingress_filtering)
            assert(false, "TODO");
        return true;
    }

    bool prepare_egress(ref Packet packet, ref const BridgePort port)
    {
        if (packet.vid != port.pvid)
        {
            assert(false, "TODO");
            return false;
        }
        if (port.untagged_egress)
            packet.consume_vlan_tag();
        else if (packet.type == PacketType.ethernet && packet.vlan_tag == VlanTag.none)
            packet.vlan_tag = VlanTag._8100;
        return true;
    }

    ulong source_address(ref const Packet packet)
    {
        if (_vlan_filtering || packet.vlan_tag == VlanTag.none)
            return get_network_src_address(packet);
        Packet untagged = packet;
        untagged.vlan &= 0xF000;
        return get_network_src_address(untagged);
    }

    ulong destination_address(ref const Packet packet)
    {
        if (_vlan_filtering || packet.vlan_tag == VlanTag.none)
            return get_network_dst_address(packet);
        Packet untagged = packet;
        untagged.vlan &= 0xF000;
        return get_network_dst_address(untagged);
    }

    // an exotic address is ours if it lives behind a software-domain port (a local
    // endpoint or an exotic member), not across the ethernet domain
    bool software_domain_port(ubyte port)
    {
        if (port == _attach_port || port == _cpu_port)
            return false;
        if (port == _local_port)
            return true;
        return port < _members.length && !(_members[port].iface.caps & InterfaceCaps.ethernet);
    }

    void local_dispatch(ref Packet packet)
    {
        if (!_vlan_filtering)
        {
            incoming_packet(packet);
            return;
        }

        ushort vlan = packet.vlan & 0x0FFF;
        if (vlan == _bridge_port.pvid)
        {
            if (_bridge_port.untagged_egress)
                packet.consume_vlan_tag();
            incoming_packet(packet);
            return;
        }
        // walk inherited _vlans Array for the matching sub-iface
        foreach (vif; _vlans[])
        {
            if (vif.vlan == vlan && (packet.vlan_tag == VlanTag.none || vif.tag == packet.vlan_tag))
            {
                vif.vlan_incoming(packet);
                return;
            }
        }
        // not a member of this vlan, drop
    }

    void send(ref Packet packet, ubyte src_port) nothrow @nogc
    {
        if (!running)
            return;

        bool is_eth = packet.type == PacketType.ethernet;

        ulong address = destination_address(packet);
        if (!address.is_multicast_address)
        {
            int dst_port = _address_table.get(address);
            if (dst_port >= 0)
            {
                if (dst_port == src_port)
                    return;

                if (dst_port == _local_port)
                    local_dispatch(packet);
                else if (dst_port == _attach_port)
                {
                    // exotic packet crossing to the ethernet domain
                    if (!is_eth && !station_egress(packet))
                        add_tx_drop();
                }
                else if (dst_port == _cpu_port)
                {
                    // host across the kernel-switched segment; inject via the CPU port
                    if (_cpu.active && is_eth)
                        _cpu.send(packet);
                }
                else if (_members[dst_port].offloaded)
                {
                    // kernel switches the ethernet segment; inject via the CPU port
                    if (_cpu.active && src_port != _cpu_port)
                        _cpu.send(packet);
                }
                else if (_members[dst_port].iface.running)
                {
                    if (_vlan_filtering)
                    {
                        if (!prepare_egress(packet, _members[dst_port]))
                            return;
                    }

                    if (_members[dst_port].iface.forward(packet) < 0)
                        add_tx_drop();
                }
                return;
            }
        }

        // broadcast, or unknown destination: flood within the packet's switching domain
        foreach (i, ref member; _members)
        {
            if (i == src_port || member.offloaded || !member.iface.running)
                continue;
            bool eth_member = (member.iface.caps & InterfaceCaps.ethernet) != 0;
            if (eth_member != is_eth)
                continue;

            Packet outgoing = packet;
            if (_vlan_filtering)
            {
                if (!prepare_egress(outgoing, member))
                    continue;
            }

            if (member.iface.forward(outgoing) < 0)
                add_tx_drop();
        }

        if (is_eth)
        {
            // flood once into the kernel-switched ethernet segment (split-horizon: not
            // when the frame came from there). The kernel floods among the netdev members.
            if (_cpu.active && src_port != _cpu_port)
                _cpu.send(packet);
            if (src_port != _local_port && src_port != _attach_port)
                local_dispatch(packet);
        }
        else
        {
            // exotic floods cross the attachment once; the wrapped frame floods the ethernet domain
            if (src_port != _attach_port)
                station_egress(packet);
            if (src_port != _local_port)
                local_dispatch(packet);
        }
    }

    TagTracking* alloc_tracking()
    {
        if (_tracking_free)
        {
            TagTracking* entry = _tracking_free;
            _tracking_free = entry.next;
            entry.next = null;
            return entry;
        }

        // batch-allocate
        TagTracking[] batch = alloc_array!TagTracking(_tracking_batch_size);
        assert(batch.ptr, "Out of memory");
        foreach (i; 0 .. _tracking_batch_size)
        {
            if (i == 0)
                continue;
            batch[i].next = _tracking_free;
            _tracking_free = &batch[i];
        }
        return &batch[0];
    }

    void recycle_tracking(TagTracking* entry)
    {
        _bridge_tags.free(entry.bridge_tag);

        TagTracking** pp = &_tracking_active;
        while (*pp)
        {
            if (*pp is entry)
            {
                *pp = entry.next;
                break;
            }
            pp = &(*pp).next;
        }

        entry.upstream_cb = null;
        entry.port_tags.clear();
        entry.bridge_tag = 0;
        entry.pending = 0;
        entry.any_succeeded = false;
        entry.next = _tracking_free;
        _tracking_free = entry;
    }

    void link_active(TagTracking* entry)
    {
        entry.bridge = this;
        entry.next = _tracking_active;
        _tracking_active = entry;
    }

    int send_tracked(ref Packet packet, MessageCallback callback)
    {
        if (!running)
            return -1;

        bool is_eth = packet.type == PacketType.ethernet;

        TagTracking* tracking = alloc_tracking();
        bool any_succeeded = false;

        ulong address = destination_address(packet);
        if (!address.is_multicast_address)
        {
            int dst_port = _address_table.get(address);
            if (dst_port >= 0)
            {
                if (dst_port == _local_port)
                {
                    recycle_tracking(tracking);
                    local_dispatch(packet);
                    return 0;
                }

                if (dst_port == _attach_port)
                {
                    // crossing to the ethernet domain is synchronous
                    recycle_tracking(tracking);
                    if (is_eth || !station_egress(packet))
                        return -1;
                    add_tx_frame(packet.data.length);
                    return 0;
                }

                if (dst_port == _cpu_port || _members[dst_port].offloaded)
                {
                    // kernel switches the ethernet segment; inject via the CPU port
                    // (fire-and-forget -- AF_PACKET sendto has no ack to track).
                    recycle_tracking(tracking);
                    if (_cpu.active)
                        _cpu.send(packet);
                    add_tx_frame(packet.data.length);
                    return 0;
                }

                // unicast to known port
                if (!_members[dst_port].iface.running)
                {
                    recycle_tracking(tracking);
                    return -1;
                }

                if (_vlan_filtering && !prepare_egress(packet, _members[dst_port]))
                {
                    recycle_tracking(tracking);
                    return -1;
                }

                int tag = _members[dst_port].iface.forward(packet, &tracking.on_port_callback);
                if (tag <= 0)
                {
                    recycle_tracking(tracking);

                    if (tag == 0)
                        add_tx_frame(packet.data.length);
                    return tag;
                }
                tracking.port_tags.pushBack(PortTag(_members[dst_port].iface, tag));
                tracking.pending = 1;
                goto finalize;
            }
        }

        // broadcast / unknown destination: flood within the packet's switching domain
        foreach (i, ref member; _members)
        {
            bool eth_member = (member.iface.caps & InterfaceCaps.ethernet) != 0;
            if (!member.iface.running || member.offloaded || eth_member != is_eth)
                continue;

            Packet outgoing = packet;
            if (_vlan_filtering && !prepare_egress(outgoing, member))
                continue;

            int tag = member.iface.forward(outgoing, &tracking.on_port_callback);
            if (tag > 0)
            {
                tracking.port_tags.pushBack(PortTag(member.iface, tag));
                ++tracking.pending;
            }
            else if (tag == 0)
                any_succeeded = true;
        }

        if (is_eth)
        {
            // flood into the kernel-switched ethernet segment (send_tracked is only
            // called for the bridge's own egress, so src is never the CPU port).
            if (_cpu.active)
            {
                _cpu.send(packet);
                any_succeeded = true;
            }
        }
        else
        {
            // exotic floods cross the attachment; the wrapped frame floods the ethernet domain
            if (station_egress(packet))
                any_succeeded = true;
        }

        if (tracking.pending == 0)
        {
            recycle_tracking(tracking);

            if (any_succeeded)
                add_tx_frame(packet.data.length);
            return any_succeeded ? 0 : -1;
        }

        tracking.any_succeeded = any_succeeded;

    finalize:
        int btag = _bridge_tags.alloc();
        if (btag < 0)
        {
            foreach (ref pt; tracking.port_tags[])
                pt.iface.abort(pt.tag);
            recycle_tracking(tracking);
            return -1;
        }
        tracking.bridge_tag = cast(ubyte)btag;
        tracking.upstream_cb = callback;
        link_active(tracking);

        add_tx_frame(packet.data.length);
        return btag;
    }
}


class BridgeInterfaceModule : Module
{
    mixin DeclareModule!"interface.bridge";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BridgeInterface();
        g_app.console.register_command!(port_add, "add")("/interface/bridge/port", this);
    }

    void port_add(Session session, BridgeInterface bridge, BaseInterface _interface, Nullable!ushort pvid, Nullable!bool ingress_filtering, Nullable!bool untagged_egress)
    {
        if (bridge is _interface)
        {
            session.write_line("Can't add a bridge to itself.");
            return;
        }
        if (_interface.flags & ObjectFlags.slave)
        {
            session.write_line("Interface '", _interface.name[], "' is already a slave to '", _interface._master.name[], "'.");
            return;
        }

        if (!bridge.add_member(_interface, pvid ? pvid.value : 1, ingress_filtering ? ingress_filtering.value : true, untagged_egress ? untagged_egress.value : true))
        {
            session.write_line("Failed to add interface '", _interface.name[], "' to bridge '", bridge.name[], "'.");
            return;
        }

        log_info(ModuleName, "bridge port add - bridge: ", bridge.name[], "  interface: ", _interface.name[]);
    }
}
