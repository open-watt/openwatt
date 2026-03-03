module router.iface.bridge;

import urt.array;
import urt.endian;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.address_table;
import router.iface.vlan;

nothrow @nogc:


class BridgeInterface : BaseInterface
{
    __gshared Property[4] Properties = [ Property.create!("vlan-filtering", vlan_filtering)(),
                                         Property.create!("pvid", pvid)(),
                                         Property.create!("ingress-filtering", ingress_filtering)(),
                                         Property.create!("untagged-egress", untagged_egress)() ];
nothrow @nogc:

    enum type_name = "bridge";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BridgeInterface, name.move, flags);
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
            defaultAllocator().freeArray(base[0 .. _tracking_batch_size]);
        }
    }

    // Properties...
    bool vlan_filtering() const
        => _vlan_filtering;
    void vlan_filtering(bool value)
    {
        _vlan_filtering = value;
    }

    ushort pvid() const
        => _bridge_port.pvid;
    void pvid(typeof(null))
    {
        _bridge_port.pvid = 0;
    }
    const(char)[] pvid(ushort value)
    {
        if (value == 0 || value > 4094)
            return "invalid vlan id";
        _bridge_port.pvid = value;
        return null;
    }

    bool ingress_filtering() const
        => _bridge_port.ingress_filtering;
    void ingress_filtering(bool value)
    {
        _bridge_port.ingress_filtering = value;
    }

    bool untagged_egress() const
        => _bridge_port.untagged_egress;
    void untagged_egress(bool value)
    {
        _bridge_port.untagged_egress = value;
    }

    // API...

    bool add_member(BaseInterface iface, ushort pvid = 1, bool ingress_filtering = true, bool untagged_egress = true)
    {
        assert(iface !is this, "Cannot add a bridge to itself!");
        assert(_members.length < 256, "Too many _members in the bridge!");
        assert(!(iface.flags & ObjectFlags.slave), "Interface is already slaved!");

        ubyte port = cast(ubyte)_members.length;
        if (iface.set_master(this, port) !is null)
            return false;
        _members ~= BridgePort(iface, pvid, ingress_filtering, untagged_egress);

        // TODO: move this logic into the modbus interface...
        // For modbus member interfaces, we'll pre-populate the MAC table with known device addresses...
        import protocol.modbus;
        import protocol.modbus.iface;
        ModbusInterface mb = cast(ModbusInterface)iface;
        if (mb)
        {
            ushort vlan = 0;

            if (!mb.master)
                _address_table.insert(mb._master_mac.ul | (ulong(vlan) << 48) | (ulong(PacketType.modbus) << 60), port);

            auto mod_mb = get_module!ModbusProtocolModule;
            foreach (ref map; mod_mb.remote_servers.values)
            {
                if (map.iface is iface)
                    _address_table.insert(map.mac.ul | (ulong(vlan) << 48) | (ulong(PacketType.modbus) << 60), port);
            }
        }

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

    protected override int transmit(ref Packet packet, MessageCallback callback)
    {
        // this is a packet entering the bridge from the bridge interface...

        if (_vlan_filtering)
        {
            ushort src_vlan;

            if (packet.type == PacketType.ethernet && packet.eth.ether_type == EtherType.vlan)
            {
                if (packet.vlan != 0)
                {
                    debug assert(false, "packet with pre-processed vlan shouldn't carry vlan tag!");
                    return -1;
                }

                // parse vlan from frame...
                assert(false, "TODO");
//                packet.vlan = tag;
//                src_vlan = tag & 0x0FFF;
            }
            else
                src_vlan = packet.vlan & 0x0FFF;

            if (src_vlan == 0)
            {
                if (_bridge_port.pvid == 0)
                {
                    // don't admit untagged
                    ++_status.tx_dropped;
                    return -1;
                }
                packet.vlan |= _bridge_port.pvid;
            }
            else if (src_vlan != _bridge_port.pvid && _bridge_port.ingress_filtering)
            {
                // check if bridge port is a vlan member?
                assert(false, "TODO");

                packet.vlan |= src_vlan;
            }
        }

        ulong src = get_network_src_address(packet);
        if (!src.is_multicast_address)
            _address_table.insert(src, _local_port);

        if (callback)
            return send_tracked(packet, callback);

        send(packet, _local_port);

        ++_status.tx_packets;
        _status.tx_bytes += packet.data.length;

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
        return CompletionStatus.complete;
    }

    override void update()
    {
        // TODO: AddressTable needs TTL mechanism...
//        _address_table.update();
    }

    final override bool bind_vlan(BaseInterface vlan_interface, bool remove)
    {
        VLANInterface vif = cast(VLANInterface)vlan_interface;
        assert(vif, "Not a vlan interface!");

        ulong key = vif.mac.ul | (ulong(vif.vlan) << 48) | (ulong(PacketType.ethernet) << 60);

        if (remove)
        {
            _vlans.remove(vif.vlan);
            _address_table.remove(key);
        }
        else
        {
            debug assert(!_vlans.exists(vif.vlan), "VLAN already bound!");
            _vlans.insert(vif.vlan, vif);
            _address_table.insert(key, _local_port);
        }
        return true;
    }

    final override void slave_incoming(ref Packet packet, byte child_id)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        ubyte src_port = cast(ubyte)child_id;
        ref const BridgePort port = _members[src_port];
        ulong src_address;
        ushort src_vlan = 0;

        // check for link-local frames (bridges must not forward link-local frames)
        if (packet.eth.dst.is_link_local && packet.type == PacketType.ethernet)
        {
            // STP/LACP/EAPOL/LLDP... should we support these?
            debug assert(false, "TODO?");
            goto drop_packet;
        }

        if (_vlan_filtering)
        {
            // check and strip vlan tag...
            if (packet.type == PacketType.ethernet && packet.eth.ether_type == EtherType.vlan)
            {
                if (packet.data.length < 4)
                    goto drop_packet;

                // strip the vlan tag
                auto tag = cast(const(ushort)*)packet.data.ptr;
                src_vlan = loadBigEndian(tag++);
                packet.eth.ether_type = loadBigEndian(tag);
                packet._offset += 4;

                if ((src_vlan & 0x0FFF) == 0)
                {
                    // vlan 0 adopts PVID
                    src_vlan = (src_vlan & 0xF000) | port.pvid;
                }
                else if (port.ingress_filtering)
                {
                    // TODO: check if port is a member of tag_vlan...
                    assert(false, "TODO");
                }

                if (packet.eth.ether_type == EtherType.ow)
                {
                    if (packet.data.length < 2)
                        goto drop_packet;
                    packet.eth.ow_sub_type = loadBigEndian(++tag);
                    packet._offset += 2;
                }
            }
            else
            {
                // untagged packets adopt PVID
                src_vlan = port.pvid;
            }

            // port was configured to drop untagged frames (PVID = 0)
            if (src_vlan == 0)
                goto drop_packet;
            packet.vlan = src_vlan;
        }

        src_address = get_network_src_address(packet);
        if (!src_address.is_multicast_address)
            _address_table.insert(src_address, src_port);

        send(packet, src_port);

        debug
        {
            ulong dst_address = get_network_dst_address(packet);
            int dst_port = _address_table.get(dst_address);
            if (dst_port >= 0)
            {
                if (dst_port != src_port && dst_port != _local_port)
                    writeDebug(name, ": forward: ", packet.eth.src, " -> ", _members[dst_port].iface.name, "(", packet.eth.dst, ") [", packet.data, "]");
            }
            else
                writeDebug(name, ": broadcast: ", packet.eth.src, " -> * [", packet.data, "]");
        }
        return;

    drop_packet:
        ++_status.rx_dropped;
    }

private:

    enum ubyte _local_port = 0xFE;
    enum _tracking_batch_size = 4;

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
    Map!(ushort, VLANInterface) _vlans;
    AddressTable _address_table;

    TagTracking* _tracking_free;
    TagTracking* _tracking_active;
    TagAllocator _bridge_tags;

    void local_dispatch(ref Packet packet)
    {
        if (!_vlan_filtering)
        {
            dispatch(packet);
            return;
        }

        ushort vlan = packet.vlan & 0x0FFF;
        if (vlan == _bridge_port.pvid)
        {
            if (_bridge_port.untagged_egress)
                packet.vlan &= 0xF000;
            dispatch(packet);
        }
        else if (VLANInterface* vif = _vlans.get(vlan))
            vif.vlan_incoming(packet);
        // else: not a member of this vlan, drop
    }

    void send(ref Packet packet, ubyte src_port) nothrow @nogc
    {
        if (!running)
            return;

        ulong address = get_network_dst_address(packet);
        if (!address.is_multicast_address)
        {
            int dst_port = _address_table.get(address);
            if (dst_port >= 0)
            {
                if (dst_port == src_port)
                    return;

                if (dst_port == _local_port)
                {
                    local_dispatch(packet);
                }
                else if (_members[dst_port].iface.running)
                {
                    if (_vlan_filtering)
                    {
                        if (packet.vlan == _members[dst_port].pvid)
                        {
                            if (_members[dst_port].untagged_egress)
                                packet.vlan &= 0xF000; // should we leave the pcp bits in-tact?
                        }
                        else
                        {
                            // TODO: check if bridge port is a vlan member?
                            assert(false);
                        }
                    }

                    if (_members[dst_port].iface.forward(packet) < 0)
                        ++_status.tx_dropped;
                }
                return;
            }
        }

        // broadcast, or unknown sender...
        foreach (i, ref member; _members)
        {
            if (i != src_port && member.iface.running)
            {
                if (_vlan_filtering)
                {
                    if (packet.vlan == member.pvid)
                    {
                        if (member.untagged_egress)
                            packet.vlan &= 0xF000; // should we leave the pcp bits in-tact?
                    }
                    else
                    {
                        // check if bridge port is a vlan member?
                        assert(false);
                    }
                }

                if (member.iface.forward(packet) < 0)
                    ++_status.tx_dropped;
            }
        }
        if (src_port != _local_port)
            local_dispatch(packet);
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
        TagTracking[] batch = defaultAllocator().allocArray!TagTracking(_tracking_batch_size);
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

        TagTracking* tracking = alloc_tracking();
        bool any_succeeded = false;

        ulong address = get_network_dst_address(packet);
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

                // unicast to known port
                if (!_members[dst_port].iface.running)
                    return -1;

                if (_vlan_filtering)
                {
                    if (packet.vlan == _members[dst_port].pvid)
                    {
                        if (_members[dst_port].untagged_egress)
                            packet.vlan &= 0xF000;
                    }
                    else
                        assert(false, "TODO");
                }

                int tag = _members[dst_port].iface.forward(packet, &tracking.on_port_callback);
                if (tag <= 0)
                {
                    recycle_tracking(tracking);

                    if (tag == 0)
                    {
                        ++_status.tx_packets;
                        _status.tx_bytes += packet.data.length;
                    }
                    return tag;
                }
                tracking.port_tags.pushBack(PortTag(_members[dst_port].iface, tag));
                tracking.pending = 1;
                goto finalize;
            }
        }

        // broadcast / unknown destination
        foreach (i, ref member; _members)
        {
            if (!member.iface.running)
                continue;

            if (_vlan_filtering)
            {
                if (packet.vlan == member.pvid)
                {
                    if (member.untagged_egress)
                        packet.vlan &= 0xF000;
                }
                else
                    assert(false, "TODO");
            }

            int tag = member.iface.forward(packet, &tracking.on_port_callback);
            if (tag > 0)
            {
                tracking.port_tags.pushBack(PortTag(member.iface, tag));
                ++tracking.pending;
            }
            else if (tag == 0)
                any_succeeded = true;
        }

        if (tracking.pending == 0)
        {
            recycle_tracking(tracking);

            if (any_succeeded)
            {
                ++_status.tx_packets;
                _status.tx_bytes += packet.data.length;
            }
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

        ++_status.tx_packets;
        _status.tx_bytes += packet.data.length;
        return btag;
    }
}


class BridgeInterfaceModule : Module
{
    mixin DeclareModule!"interface.bridge";
nothrow @nogc:

    Collection!BridgeInterface bridges;

    override void init()
    {
        g_app.console.register_collection("/interface/bridge", bridges);
        g_app.console.register_command!port_add("/interface/bridge/port", this, "add");
    }

    override void update()
    {
        bridges.update_all();
    }

    void port_add(Session session, BridgeInterface bridge, BaseInterface _interface, Nullable!ushort pvid, Nullable!bool ingress_filtering, Nullable!bool untagged_egress)
    {
        if (bridge is _interface)
        {
            session.write_line("Can't add a bridge to itself.");
            return;
        }
        if (_interface._master)
        {
            session.write_line("Interface '", _interface.name[], "' is already a slave to '", _interface._master.name[], "'.");
            return;
        }

        if (!bridge.add_member(_interface, pvid ? pvid.value : 1, ingress_filtering ? ingress_filtering.value : true, untagged_egress ? untagged_egress.value : true))
        {
            session.write_line("Failed to add interface '", _interface.name[], "' to bridge '", bridge.name[], "'.");
            return;
        }

        writeInfo("Bridge port add - bridge: ", bridge.name[], "  interface: ", _interface.name[]);
    }
}
