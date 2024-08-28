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
	BaseInterface[] members;

	this(InterfaceModule.Instance m, String name)  nothrow @nogc
	{
		super(m, name, StringLit!"bridge");
	}

	bool addMember(BaseInterface iface)
	{
		foreach (member; members)
		{
			if (iface is member)
				return false;
		}
		members ~= iface;

		iface.subscribe(&incomingPacket, PacketFilter());
		return true;
	}

	bool removeMember(size_t index)
	{
		if (index >= members.length)
			return false;

		members = members[0 .. index] ~ members[index + 1 .. $];
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
	}

	override bool send(ref const Packet packet) nothrow @nogc
	{
		// work out where it's gotta go...
		return false;
	}

	void incomingPacket(ref const Packet packet, BaseInterface srcInterface) nothrow @nogc
	{
		if (packet.dst != MACAddress.broadcast)
		{
			// find the destination...
			foreach (member; members)
			{
				BaseInterface dstInterface = member.findMacAddress(packet.dst);
				if (dstInterface)
				{
					assert(dstInterface is member, "How does an interface hold a mac record for another interface?");

					// we don't send it back the way it came...
					if (dstInterface is srcInterface)
						return;

					// forward the message
					dstInterface.send(packet);

					debug writeDebug(name, ": forward: ", srcInterface.name, "(", packet.src, ") -> ", dstInterface.name, "(", packet.dst, ") [", packet.data, "]");
					return;
				}
			}
		}

		// we don't know who it belongs to!
		// we just broadcast it, and maybe we'll catch the dst mac when the remote replies...
		foreach (member; members)
		{
			if (member !is srcInterface)
				member.send(packet);
		}

		debug writeDebug(name, ": broadcast: ", srcInterface.name, "(", packet.src, ") -> * [", packet.data, "]");
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
