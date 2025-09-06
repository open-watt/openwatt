module router.iface.bridge;

import urt.array;
import urt.endian;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;

nothrow @nogc:


class BridgeInterface : BaseInterface
{
    __gshared Property[4] Properties = [ Property.create!("vlan-filtering", vlan_filtering)(),
                                         Property.create!("pvid", pvid)(),
                                         Property.create!("ingress-filtering", ingress_filtering)(),
                                         Property.create!("untagged-egress", untagged_egress)() ];
nothrow @nogc:

    alias TypeName = StringLit!"bridge";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!BridgeInterface, name.move, flags);
        _mac_table = MACTable(16, 256, 60);
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

        // check is interface is already a slave
        if (iface.master)
            return false;

        ubyte port = cast(ubyte)_members.length;
        _members ~= BridgePort(iface, pvid, ingress_filtering, untagged_egress);
        iface.master = this;

        iface.subscribe(&incoming_packet, PacketFilter(), cast(void*)port);

        // TODO: move this logic into the modbus interface...
        // For modbus member interfaces, we'll pre-populate the MAC table with known device addresses...
        import router.iface.modbus;
        ModbusInterface mb = cast(ModbusInterface)iface;
        if (mb)
        {
            ushort vlan = 0;

            if (!mb.master)
                _mac_table.insert(mb.masterMac, vlan, port);

            auto mod_mb = getModule!ModbusInterfaceModule;
            foreach (ref map; mod_mb.remoteServers.values)
            {
                if (map.iface is iface)
                    _mac_table.insert(map.mac, vlan, port);
            }
        }

        return true;
    }

    bool remove_member(size_t index)
    {
        if (index >= _members.length)
            return false;

        _members[index].iface.master = null;
        _members.remove(index);

        // TODO: update the MAC table to adjust all the port numbers!
        assert(false);

        // TODO: all the subscriber user_data's are wrong!!!
        //       we need to unsubscribe and resubscribe all the _members...
        assert(false);

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

    override void update()
    {
        _mac_table.update();
    }

    protected override bool transmit(ref Packet packet)
    {
        // this is a packet entering the bridge from the bridge interface...

        if (_vlan_filtering)
        {
            ushort src_vlan;

            if (packet.type == PacketType.Ethernet && packet.eth.ether_type == EtherType.VLAN)
            {
                if (packet.vlan != 0)
                {
                    debug assert(false, "packet with pre-processed vlan shouldn't carry vlan tag!");
                    return false;
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
                    ++_status.sendDropped;
                    return false;
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

        send(packet);

        ++_status.sendPackets;
        _status.sendBytes += packet.data.length;

        return true;
    }

protected:
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

    bool _vlan_filtering;
    BridgePort _bridge_port;
    Array!BridgePort _members;
    MACTable _mac_table;

    void incoming_packet(ref Packet packet, BaseInterface src_interface, PacketDirection dir, void* user_data)
    {
        // this is for packets entering the bridge from member interfaces...

        debug assert(running, "Shouldn't receive packets while not running...?");

        ubyte src_port = cast(ubyte)cast(size_t)user_data;
        ref const BridgePort port = _members[src_port];

        // check for link-local frames (bridges must not forward link-local frames)
        if (packet.eth.dst.is_link_local && packet.type == PacketType.Ethernet)
        {
            // STP/LACP/EAPOL/LLDP... should we support these?
            // TODO...
            return;
        }

        ushort src_vlan = 0;
        if (_vlan_filtering)
        {
            // check and strip vlan tag...
            if (packet.type == PacketType.Ethernet && packet.eth.ether_type == EtherType.VLAN)
            {
                if (packet.data.length < 4)
                    return;

                auto data = cast(const(ubyte)*)packet.data.ptr;
                src_vlan = data[0..2].bigEndianToNative!ushort;
                if ((src_vlan & 0x0FFF) == 0)
                    src_vlan = (src_vlan & 0xF000) | port.pvid;
                else if (port.ingress_filtering)
                {
                    // TODO: check if port is a member of tag_vlan...
                    assert(false, "TODO");
                }

                packet.eth.ether_type = data[2..4].bigEndianToNative!ushort;
                if (packet.eth.ether_type == EtherType.OW)
                {
                    if (packet.data.length < 6)
                        return;
                    packet.eth.ow_sub_type = data[4..6].bigEndianToNative!ushort;
                    packet.data = packet.data[6..$];
                }
                else
                    packet.data = packet.data[4..$];
            }
            else
                src_vlan = port.pvid;

            // port is configured to drop untagged frames...
            if (src_vlan == 0)
                return;
            packet.vlan = src_vlan;
        }

        if (!packet.eth.src.isMulticast)
            _mac_table.insert(packet.eth.src, src_vlan, src_port);

        if (packet.eth.dst == mac)
        {
            // we're the destination!
            // we don't need to forward it, just deliver it to the upper layer...

            if (_vlan_filtering)
            {
                if ((packet.vlan & 0x0FFF) == _bridge_port.pvid)
                {
                    if (_bridge_port.untagged_egress)
                        packet.vlan &= 0xF000; // should we leave the pcp bits in-tact?
                }
                else
                {
                    // check if bridge port is a vlan member?
                    assert(false);
                }
            }

            dispatch(packet);
        }
        else
        {
            send(packet, src_port);

            debug
            {
                byte dst_port;
                if (_mac_table.get(packet.eth.dst, packet.vlan, dst_port))
                {
                    if (dst_port != src_port)
                        writeDebug(name, ": forward: ", src_interface.name, "(", packet.eth.src, ") -> ", _members[dst_port].iface.name, "(", packet.eth.dst, ") [", packet.data, "]");
                }
                else
                    writeDebug(name, ": broadcast: ", src_interface.name, "(", packet.eth.src, ") -> * [", packet.data, "]");
            }
        }
    }

    void send(ref Packet packet, int src_port = -1) nothrow @nogc
    {
        if (!running)
            return;

        if (!packet.eth.dst.isMulticast)
        {
            byte dst_port;
            if (_mac_table.get(packet.eth.dst, packet.vlan, dst_port))
            {
                // we don't send it back the way it came...
                if (dst_port == src_port)
                    return;

                // forward the message
                if (_members[dst_port].iface.running)
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
                            // check if bridge port is a vlan member?
                            assert(false);
                        }
                    }

                    _members[dst_port].iface.forward(packet);
                }
                return;
            }
        }

        // we don't know who it belongs to!
        // we just broadcast it, and maybe we'll catch the dst mac when the remote replies...
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

                member.iface.forward(packet);
            }
        }
    }
}


class BridgeInterfaceModule : Module
{
    mixin DeclareModule!"interface.bridge";
nothrow @nogc:

    Collection!BridgeInterface bridges;

    override void init()
    {
        g_app.console.registerCollection("/interface/bridge", bridges);
        g_app.console.registerCommand!port_add("/interface/bridge/port", this, "add");
    }

    override void update()
    {
        bridges.updateAll();
    }

    void port_add(Session session, BridgeInterface bridge, BaseInterface _interface, Nullable!ushort pvid, Nullable!bool ingress_filtering, Nullable!bool untagged_egress)
    {
        if (bridge is _interface)
        {
            session.writeLine("Can't add a bridge to itself.");
            return;
        }
        if (_interface.master)
        {
            session.writeLine("Interface '", _interface.name[], "' is already a slave to '", _interface.master.name[], "'.");
            return;
        }

        if (!bridge.add_member(_interface, pvid ? pvid.value : 1, ingress_filtering ? ingress_filtering.value : true, untagged_egress ? untagged_egress.value : true))
        {
            session.writeLine("Failed to add interface '", _interface.name[], "' to bridge '", bridge.name[], "'.");
            return;
        }

        writeInfo("Bridge port add - bridge: ", bridge.name[], "  interface: ", _interface.name[]);
    }
}
