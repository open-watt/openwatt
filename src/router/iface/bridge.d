module router.iface.bridge;

import urt.array;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.console;
import manager.plugin;

import router.iface;


class BridgeInterface : BaseInterface
{
nothrow @nogc:

    alias TypeName = StringLit!"bridge";

    this(String name)
    {
        super(name.move, TypeName);

        macTable = MACTable(16, 256, 60);

        status.linkStatus = Status.Link.Up;
        status.linkStatusChangeTime = getSysTime();
    }

    bool addMember(BaseInterface iface)
    {
        assert(iface !is this, "Cannot add a bridge to itself!");
        assert(members.length < 256, "Too many members in the bridge!");

        ubyte port = cast(ubyte)members.length;

        // check is interface is already a slave
        if (iface.master)
            return false;

        members ~= iface;
        iface.master = this;

        iface.subscribe(&incomingPacket, PacketFilter(), cast(void*)port);

        // For modbus member interfaces, we'll pre-populate the MAC table with known device addresses...
        import router.iface.modbus;
        ModbusInterface mb = cast(ModbusInterface)iface;
        if (mb)
        {
            ushort vlan = 0;

            if (!mb.isBusMaster)
                macTable.insert(mb.masterMac, port, vlan);

            auto mod_mb = getModule!ModbusInterfaceModule;
            foreach (ref map; mod_mb.remoteServers.values)
            {
                if (map.iface is iface)
                    macTable.insert(map.mac, port, vlan);
            }
        }

        return true;
    }

    bool removeMember(size_t index)
    {
        if (index >= members.length)
            return false;

        members[index].master = null;
        members.remove(index);

        // TODO: update the MAC table to adjust all the port numbers!
        assert(false);

        // TODO: all the subscriber userData's are wrong!!!
        //       we need to unsubscribe and resubscribe all the members...
        assert(false);

        return true;
    }

    bool removeMember(const(char)[] name)
    {
        foreach (i, iface; members)
        {
            if (iface.name[] == name[])
                return removeMember(i);
        }
        return false;
    }

    override void update()
    {
        macTable.update();
    }

    protected override bool transmit(ref const Packet packet)
    {
        send(packet);

        ++status.sendPackets;
        status.sendBytes += packet.data.length;

        return true;
    }

protected:
    Array!BaseInterface members;
    MACTable macTable;

    void incomingPacket(ref const Packet packet, BaseInterface srcInterface, PacketDirection dir, void* userData)
    {
        ubyte srcPort = cast(ubyte)cast(size_t)userData;

        // TODO: should we check and strip a vlan tag?
        ushort srcVlan = 0;

        if (!packet.src.isMulticast)
            macTable.insert(packet.src, srcPort, srcVlan);

        if (packet.dst == mac)
        {
            // we're the destination!
            // we don't need to forward it, just deliver it to the upper layer...
            dispatch(packet);
        }
        else
        {
            send(packet, srcPort);

            debug
            {
                ubyte dstPort;
                ushort dstVlan;
                if (macTable.get(packet.dst, dstPort, dstVlan))
                {
                    if (dstPort != srcPort)
                        writeDebug(name, ": forward: ", srcInterface.name, "(", packet.src, ") -> ", members[dstPort].name, "(", packet.dst, ") [", packet.data, "]");
                }
                else
                    writeDebug(name, ": broadcast: ", srcInterface.name, "(", packet.src, ") -> * [", packet.data, "]");
            }
        }
    }

    void send(ref const Packet packet, int srcPort = -1) nothrow @nogc
    {
        if (!packet.dst.isMulticast)
        {
            ubyte dstPort;
            ushort dstVlan;
            if (macTable.get(packet.dst, dstPort, dstVlan))
            {
                // TODO: what should we do about the vlan thing?

                // we don't send it back the way it came...
                if (dstPort == srcPort)
                    return;

                // forward the message
                members[dstPort].forward(packet);
                return;
            }
        }

        // we don't know who it belongs to!
        // we just broadcast it, and maybe we'll catch the dst mac when the remote replies...
        foreach (i, member; members)
        {
            if (i != srcPort)
                member.forward(packet);
        }
    }
}


class BridgeInterfaceModule : Module
{
    mixin DeclareModule!"interface.bridge";
nothrow @nogc:

    override void init()
    {
        g_app.console.registerCommand!add("/interface/bridge", this);
        g_app.console.registerCommand!port_add("/interface/bridge/port", this, "add");
    }

    // /interface/modbus/add command
    // TODO: protocol enum!
    void add(Session session, const(char)[] name, Nullable!(const(char)[]) pcap)
    {
        auto mod_if = getModule!InterfaceModule;
        String n = mod_if.addInterfaceName(session, name, BridgeInterface.TypeName);
        if (!n)
            return;

        BridgeInterface iface = defaultAllocator.allocT!BridgeInterface(n.move);

        mod_if.addInterface(session, iface, pcap ? pcap.value : null);

//        // HACK: we'll print packets that we receive...
//        iface.subscribe((ref const Packet p, BaseInterface i) nothrow @nogc {
//            import urt.io;
//            writef("{0}: packet received: ({1} -> {2} )  [{3}]\n", i.name, p.src, p.dst, p.data);
//        }, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
    }

    void port_add(Session session, BridgeInterface bridge, BaseInterface _interface)
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

        if (!bridge.addMember(_interface))
        {
            session.writeLine("Failed to add interface '", _interface.name[], "' to bridge '", bridge.name[], "'.");
            return;
        }

        writeInfo("Bridge port add - bridge: ", bridge.name[], "  interface: ", _interface.name[]);
    }
}
