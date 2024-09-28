module router.iface.bridge;

import urt.log;
import urt.mem;
import urt.string;

import manager.console;
import manager.instance;
import manager.plugin;

import router.iface;


class BridgeInterface : BaseInterface
{
	this(InterfaceModule.Instance m, String name)  nothrow @nogc
	{
		super(m, name, StringLit!"bridge");

		macTable = MACTable(16, 256, 60);
	}

	bool addMember(BaseInterface iface)
	{
		assert(iface !is this, "Cannot add a bridge to itself!");
		assert(members.length < 256, "Too many members in the bridge!");

        ubyte port = cast(ubyte)members.length;

		foreach (member; members)
		{
			if (iface is member)
				return false;
		}
		members ~= iface;

		iface.subscribe(&incomingPacket, PacketFilter(), cast(void*)port);

        import router.iface.modbus;
        ModbusInterface mb = cast(ModbusInterface)iface;
        if (mb)
        {
            ushort vlan = 0;

            if (!mb.isBusMaster)
                macTable.insert(mb.masterMac, port, vlan);

            auto mod = mod_iface.app.moduleInstance!ModbusInterfaceModule;
            if (mod)
            {
                foreach (addr, ref map; mod.remoteServers)
                {
                    if (map.iface is iface)
                        macTable.insert(map.mac, port, vlan);
                }
            }
        }

		return true;
	}

	bool removeMember(size_t index)
	{
		if (index >= members.length)
			return false;

		members = members[0 .. index] ~ members[index + 1 .. $];

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

	override bool forward(ref const Packet packet) nothrow @nogc
	{
		send(packet);
		return true;
	}

protected:
	BaseInterface[] members;
	MACTable macTable;

	void incomingPacket(ref const Packet packet, BaseInterface srcInterface, void* userData) nothrow @nogc
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


class BrudgeInterfaceModule : Plugin
{
	mixin RegisterModule!"interface.bridge";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		override void init()
		{
			app.console.registerCommand!add("/interface/bridge", this);
			app.console.registerCommand!port_add("/interface/bridge/port", this, "add");
		}

		// /interface/modbus/add command
		// TODO: protocol enum!
		void add(Session session, const(char)[] name)
		{
			auto mod_if = app.moduleInstance!InterfaceModule;

			if (name.empty)
				name = mod_if.generateInterfaceName("bridge");
			String n = name.makeString(defaultAllocator());

			BridgeInterface iface = defaultAllocator.allocT!BridgeInterface(mod_if, n.move);
			mod_if.addInterface(iface);

			import urt.log;
			debug writeDebugf("Create bridge interface {0} - '{1}'", iface.mac, name);

//			// HACK: we'll print packets that we receive...
//			iface.subscribe((ref const Packet p, BaseInterface i) nothrow @nogc {
//				import urt.io;
//				writef("{0}: packet received: ({1} -> {2} )  [{3}]\n", i.name, p.src, p.dst, p.data);
//			}, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
		}

		void port_add(Session session, const(char)[] bridge, const(char)[] _interface)
		{
			auto mod_if = app.moduleInstance!InterfaceModule;

			BaseInterface b = mod_if.findInterface(bridge);
			if (b is null)
			{
				session.writeLine("Bridge interface '", bridge, "' not found.");
				return;
			}
			BaseInterface i = mod_if.findInterface(_interface);
			if (i is null)
			{
				session.writeLine("Interface not found.");
				return;
			}

			BridgeInterface bi = cast(BridgeInterface)b;
			if (!bi)
			{
				session.writeLine("Interface '", bridge, "' is not a bridge.");
				return;
			}

			if (!bi.addMember(i))
			{
				session.writeLine("Interface '", _interface, "' already a member of bridge '", bridge, "'.");
				return;
			}
		}
	}
}
