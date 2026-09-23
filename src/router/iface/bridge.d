module router.iface.bridge;

import urt.array;
import urt.log;
import urt.map;
import urt.mem;
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
alias PortsChangedHook = void delegate(BridgeInterface bridge) nothrow @nogc;
alias CpuPromiscHook = void delegate(BridgeInterface bridge) nothrow @nogc;

__gshared PortsChangedHook g_bridge_ports_changed;
__gshared CpuPromiscHook g_bridge_cpu_promisc_changed;

void register_bridge_offload_hooks(PortsChangedHook ports_changed, CpuPromiscHook promisc_changed)
{
    g_bridge_ports_changed = ports_changed;
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
    final bool vlan_filtering() const
        => _vlan_filtering;
    final void vlan_filtering(bool value)
    {
        _vlan_filtering = value;
        mark_set!(typeof(this), "vlan-filtering")();
        ports_changed();
    }

    final ushort pvid() const
        => _bridge_port.pvid;
    final void pvid(typeof(null))
    {
        _bridge_port.pvid = 0;
        mark_set!(typeof(this), "pvid")();
    }
    final const(char)[] pvid(ushort value)
    {
        if (value == 0 || value > 4094)
            return "invalid vlan id";
        _bridge_port.pvid = value;
        mark_set!(typeof(this), "pvid")();
        return null;
    }

    final bool ingress_filtering() const
        => _bridge_port.ingress_filtering;
    final void ingress_filtering(bool value)
    {
        _bridge_port.ingress_filtering = value;
        mark_set!(typeof(this), "ingress-filtering")();
    }

    final bool untagged_egress() const
        => _bridge_port.untagged_egress;
    final void untagged_egress(bool value)
    {
        _bridge_port.untagged_egress = value;
        mark_set!(typeof(this), "untagged-egress")();
    }

    // API...

    // --- kernel-bridge offload seam (driver.linux.bridge drives this) ---

    final size_t member_count() const
        => _members.length;

    final BaseInterface member_iface(size_t i)
        => _members[i].iface;

    // Mark/unmark a member as kernel-offloaded (by identity, not removal -- the
    // member stays in _members, keeping port indices and the address table stable).
    final void set_member_offloaded(BaseInterface iface, bool offloaded)
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

    final void attach_cpu_port(CpuPortSink sink)
    {
        _cpu.send = sink;
        _cpu.active = true;
    }

    final void detach_cpu_port()
    {
        _cpu.active = false;
        _cpu.send = null;
    }

    // Ingress from the kernel-switched ethernet segment (the offload module drains
    // the CPU-port socket and feeds frames here). This is a switching ingress like
    // any member port, with src = _cpu_port.
    final void cpu_port_incoming(ref Packet packet)
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
    final bool cpu_port_wants_promisc() const
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
                    if (pt.tag > 0 && pt.iface)
                        pt.iface.abort(pt.tag, reason);
                }
                recycle_tracking(entry);
                if (cb)
                    cb(msg_handle, reason);
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
                    return entry.port_tags[0].iface ? entry.port_tags[0].iface.msg_state(entry.port_tags[0].tag) : MessageState.aborted;
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
            if (!m.iface)
                continue;
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
                if (pt.tag > 0 && pt.iface)
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
    final override void station_deliver_exotic(ref Packet inner)
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
        BridgePort port = _members[src_port];
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

    void attach_port(BridgePort member)
    {
        foreach (i, m; _members)
            if (m is member)
            {
                member.iface.set_master(ObjectRef!BaseInterface(this), cast(byte)i);
                ports_changed();
                return;
            }
        assert(_members.length < _cpu_port);
        ubyte port = cast(ubyte)_members.length;
        BaseInterface iface = member.iface;
        _members ~= ObjectRef!BridgePort(member);
        iface.set_master(ObjectRef!BaseInterface(this), cast(byte)port);
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

        ports_changed();
        if (running && (iface.caps & InterfaceCaps.ethernet))
            station_link_up();
    }

    void detach_port(BridgePort member)
    {
        foreach (i, m; _members)
        {
            if (m !is member)
                continue;
            _members.remove(i);
            _address_table.remove_port(cast(ubyte)i, _cpu_port);
            foreach (j; i .. _members.length)
                if (auto iface = _members[j].iface)
                    iface.set_master(ObjectRef!BaseInterface(this), cast(byte)j);
            cancel_port(member.iface);
            ports_changed();
            return;
        }
    }

    void cancel_port(BaseInterface iface)
    {
        for (TagTracking* entry = _tracking_active; entry;)
        {
            bool affected;
            foreach (ref pt; entry.port_tags[])
                affected |= pt.iface is iface;
            if (affected)
            {
                abort(entry.bridge_tag);
                entry = _tracking_active;
            }
            else
                entry = entry.next;
        }
    }

    void ports_changed()
    {
        if (running)
        {
            update_link_speed();
            if (g_bridge_ports_changed)
                g_bridge_ports_changed(this);
        }
    }

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

    struct PortTag
    {
        ObjectRef!BaseInterface iface;
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
    BridgePortConfig _bridge_port = BridgePortConfig(1, false, true);
    Array!(ObjectRef!BridgePort) _members;
    AddressTable _address_table;

    TagTracking* _tracking_free;
    TagTracking* _tracking_active;
    TagAllocator _bridge_tags;

    bool classify_vlan(Port)(ref Packet packet, auto ref const Port port)
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
            return false;
        return true;
    }

    bool prepare_egress(Port)(ref Packet packet, auto ref const Port port)
    {
        if (packet.vid != port.pvid)
            return false;
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
        return port < _members.length && _members[port].iface && !(_members[port].iface.caps & InterfaceCaps.ethernet);
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
                tracking.port_tags.pushBack(PortTag(ObjectRef!BaseInterface(_members[dst_port].iface), tag));
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
                tracking.port_tags.pushBack(PortTag(ObjectRef!BaseInterface(member.iface), tag));
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
                if (pt.iface)
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


private struct BridgePortConfig
{
    ushort pvid = 1;
    bool ingress_filtering = true;
    bool untagged_egress = true;
}

final class BridgePort : BaseObject
{
    alias Properties = AliasSeq!(Prop!("bridge", bridge),
                                 Prop!("interface", interface_name),
                                 Prop!("pvid", pvid),
                                 Prop!("ingress-filtering", ingress_filtering),
                                 Prop!("untagged-egress", untagged_egress));
nothrow @nogc:

    enum type_name = "bridge-port";
    enum path = "/interface/bridge/port";
    enum collection_id = CollectionType.bridge_port;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BridgePort, id, flags);
    }

    final const(char)[] bridge() const pure
        => _bridge.name[];

    override ObjectFlags flags() const
    {
        ObjectFlags value = super.flags;
        if ((_bridge && (_bridge.flags & ObjectFlags.dynamic)) || (_iface && (_iface.flags & ObjectFlags.dynamic)))
            value |= ObjectFlags.dynamic;
        return value;
    }

    final const(char)[] bridge(const(char)[] value)
    {
        if (auto obj = Collection!BaseInterface().get(value))
            if (!dyn_cast!BridgeInterface(obj))
                return "master must be a bridge";
        if (auto error = check_membership(value, interface_name))
            return error;
        unbind();
        _bridge = ObjectRef!BridgeInterface(value);
        mark_set!(typeof(this), [ "bridge", "flags" ])();
        return null;
    }

    final const(char)[] interface_name() const pure
        => _iface.name[];

    final const(char)[] interface_name(const(char)[] value)
    {
        if (auto obj = Collection!BaseInterface().get(value))
            if (obj.flags & ObjectFlags.temporary)
                return "temporary interfaces cannot be bridge ports";
        if (auto error = check_membership(bridge, value))
            return error;
        unbind();
        _iface = ObjectRef!BaseInterface(value);
        mark_set!(typeof(this), [ "interface", "flags" ])();
        return null;
    }

    final ushort pvid() const pure
        => _config.pvid;

    final const(char)[] pvid(ushort value)
    {
        if (value == 0 || value > 4094)
            return "invalid vlan id";
        _config.pvid = value;
        mark_set!(typeof(this), "pvid")();
        return null;
    }

    final bool ingress_filtering() const pure
        => _config.ingress_filtering;

    final void ingress_filtering(bool value)
    {
        _config.ingress_filtering = value;
        mark_set!(typeof(this), "ingress-filtering")();
    }

    final bool untagged_egress() const pure
        => _config.untagged_egress;

    final void untagged_egress(bool value)
    {
        _config.untagged_egress = value;
        mark_set!(typeof(this), "untagged-egress")();
    }

protected:
    override bool validate() const
        => bridge.length && interface_name.length;

private:
    ObjectRef!BridgeInterface _bridge;
    ObjectRef!BaseInterface _iface;
    BridgePortConfig _config;
    bool offloaded;

    BaseInterface iface()
        => _iface;

    BridgeInterface bridge_object()
        => dyn_cast!BridgeInterface(cast(BaseInterface)_bridge.get);

    const(char)[] check_membership(const(char)[] master, const(char)[] member)
    {
        if (!member.length)
            return null;
        foreach (p; Collection!BridgePort().values)
            if (p !is this && p.interface_name == member)
                return "interface already has a bridge port";
        const(char)[] ancestor = master;
        for (uint depth = 0; ancestor.length; ++depth)
        {
            if (ancestor == member || depth > Collection!BridgePort().item_count)
                return "bridge membership would form a cycle";
            const(char)[] next;
            foreach (p; Collection!BridgePort().values)
                if (p !is this && p.interface_name == ancestor)
                {
                    next = p.bridge;
                    break;
                }
            ancestor = next;
        }
        uint count;
        foreach (p; Collection!BridgePort().values)
            if (p !is this && p.bridge == master)
                ++count;
        return count >= BridgeInterface._cpu_port ? "too many bridge ports" : null;
    }

    void unbind()
    {
        if (auto b = bridge_object())
            b.detach_port(this);
        if (_iface && _iface._master.name[] == bridge)
            _iface.set_master(ObjectRef!BaseInterface.init, 0);
        offloaded = false;
    }

    void endpoint_created()
    {
        mark_set!(typeof(this), "flags")();
    }

    void reconcile()
    {
        if (disabled || !validate())
        {
            unbind();
            return;
        }
        if (!_iface)
            return;
        if (auto b = bridge_object())
            b.attach_port(this);
        else
            _iface.set_master(ObjectRef!BaseInterface(bridge), 0);
    }
}

final class BridgeInterfaceModule : Module
{
    mixin DeclareModule!"interface.bridge";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BridgeInterface();
        g_app.console.register_collection!BridgePort();
        Collection!BridgePort().subscribe(&ports_changed);
        register_object_lifecycle_handler(&endpoint_changed);
    }

    override void update()
    {
        Collection!BridgePort().update_all();
    }

    override void deinit()
    {
        Collection!BridgePort().unsubscribe(&ports_changed);
        unregister_object_lifecycle_handler(&endpoint_changed);
    }

private:
    void ports_changed(BaseObject obj, CollectionEvent event)
    {
        auto port = cast(BridgePort)obj;
        if (event == CollectionEvent.removed)
            port.unbind();
        else
            port.reconcile();
    }

    void endpoint_changed(BaseObject obj, ObjectLifecycleEvent event)
    {
        auto iface = dyn_cast!BaseInterface(obj);
        if (!iface)
            return;
        foreach (port; Collection!BridgePort().values)
        {
            if (port._iface !is iface && cast(BaseInterface)port._bridge.get !is iface)
                continue;
            if (event == ObjectLifecycleEvent.created)
                port.endpoint_created();
            else if (iface.flags & ObjectFlags.dynamic)
                port.destroy();
            else
            {
                if (auto b = port.bridge_object())
                    b.detach_port(port);
                port.offloaded = false;
            }
        }
    }
}

unittest
{
    final class TestPort : BaseInterface
    {
        enum type_name = "bridge-test-port";
    nothrow @nogc:
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestPort, id, flags);
            _caps |= InterfaceCaps.ethernet;
        }

        void start()
        {
            if (!running)
                set_state(State.validate);
            set_state(State.starting);
        }

        override int transmit(ref Packet, MessageCallback callback, const(QueuePolicy)*)
        {
            pending = callback;
            return callback ? 17 : 0;
        }

        override void abort(int, MessageState reason)
        {
            auto callback = pending;
            pending = null;
            if (callback)
                callback(17, reason);
        }

        MessageCallback pending;
    }

    auto module_ = alloc!BridgeInterfaceModule(null);
    Collection!BridgePort().subscribe(&module_.ports_changed);
    register_object_lifecycle_handler(&module_.endpoint_changed);
    scope(exit)
    {
        Collection!BridgePort().unsubscribe(&module_.ports_changed);
        unregister_object_lifecycle_handler(&module_.endpoint_changed);
        free(module_);
    }

    struct Observer
    {
        uint first_calls, second_calls, third_calls;
    nothrow @nogc:
        void first(BaseObject, CollectionEvent event)
        {
            ++first_calls;
            if (event == CollectionEvent.added)
            {
                Collection!BridgePort().unsubscribe(&second);
                Collection!BridgePort().subscribe(&third);
            }
        }

        void second(BaseObject, CollectionEvent)
        {
            ++second_calls;
        }

        void third(BaseObject, CollectionEvent)
        {
            ++third_calls;
        }
    }
    Observer observer;
    Collection!BridgePort().subscribe(&observer.first);
    Collection!BridgePort().subscribe(&observer.second);
    auto unpublished = Collection!BridgePort().alloc("bridge-test-notifications");
    assert(unpublished.pvid(42) is null);
    assert(observer.first_calls == 0);
    Collection!BridgePort().add(unpublished);
    assert(observer.first_calls == 1 && observer.second_calls == 0 && observer.third_calls == 0);
    assert(unpublished.pvid(43) is null);
    assert(observer.first_calls == 2 && observer.third_calls == 1);
    Collection!BridgePort().remove(unpublished);
    assert(observer.first_calls == 3 && observer.third_calls == 2);
    free(unpublished);
    Collection!BridgePort().unsubscribe(&observer.first);
    Collection!BridgePort().unsubscribe(&observer.third);

    auto member = Collection!TestPort().create("bridge-test-member");
    auto port = Collection!BridgePort().alloc("bridge-test-membership");
    assert(port.bridge("bridge-test-master") is null);
    assert(port.interface_name(member.name[]) is null);
    Collection!BridgePort().add(port);
    member.start();
    assert(!member.running && (member.flags & ObjectFlags.slave));
    auto master = Collection!BridgeInterface().create("bridge-test-master");
    member.start();
    assert(master.running && member.running && master.member_count == 1);
    master.disabled = true;
    assert(!member.running && (member.flags & ObjectFlags.slave));
    master.destroy();
    assert(Collection!BridgePort().get(port.name[]) is port);
    master = Collection!BridgeInterface().create("bridge-test-master");
    member.start();
    assert(master.running && member.running && master.member_count == 1);

    member.disabled = true;
    assert(master.running);
    member.destroy();
    assert(master.running && master.member_count == 0);
    assert(Collection!BridgePort().get(port.name[]) is port);
    member = Collection!TestPort().create("bridge-test-member");
    assert(member.running && master.member_count == 1);

    struct Completion
    {
        uint calls;
        MessageState state;
        void completed(int, MessageState value) nothrow @nogc
        {
            ++calls;
            state = value;
        }
    }
    Completion completion;
    register_packet_codec!Ethernet();
    Packet packet;
    ref frame = packet.init!Ethernet(null);
    frame.dst = MACAddress(0xff, 0xff, 0xff, 0xff, 0xff, 0xff);
    packet.vlan_tag = VlanTag._8100;
    packet.vlan = 42;
    assert(!master.classify_vlan(packet, port));
    assert(!master.prepare_egress(packet, port));
    assert(port.pvid(42) is null);
    assert(master.classify_vlan(packet, port));
    assert(master.prepare_egress(packet, port));
    packet.vlan = 0;
    int tag = master.transmit(packet, &completion.completed, null);
    assert(tag > 0 && member.pending);
    port.destroy();
    assert(!member.pending && completion.calls == 1 && completion.state == MessageState.aborted);
    assert(master.running && master.member_count == 0);
    assert(!(member.flags & ObjectFlags.slave));
    master.destroy();

    auto dynamic_master = Collection!BridgeInterface().create("bridge-test-dynamic", ObjectFlags.dynamic);
    port = Collection!BridgePort().alloc("bridge-test-dynamic-membership");
    assert(port.bridge(dynamic_master.name[]) is null);
    assert(port.interface_name(member.name[]) is null);
    Collection!BridgePort().add(port);
    assert(port.flags & ObjectFlags.dynamic);
    dynamic_master.destroy();
    assert(Collection!BridgePort().get("bridge-test-dynamic-membership") is null);
    assert(!(member.flags & ObjectFlags.slave));
    member.destroy();
}
