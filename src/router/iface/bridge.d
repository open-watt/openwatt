module router.iface.bridge;

import urt.string;

import manager.instance;
import manager.plugin;

import router.iface;


class BridgeInterface : BaseInterface
{
	BaseInterface[] members;

	this(InterfaceModule.Instance m, String name)
	{
		super(m, name, StringLit!"bridge");
	}

	bool addMember(BaseInterface iface)
	{
		foreach (member; members)
		{
			if (iface is member || iface.name[] == member.name[])
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

	void incomingPacket(ref const Packet packet, BaseInterface srcInterface) nothrow @nogc
	{
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
//			app.console.registerCommand("/interface", new InterfaceCommand(app.console, this));
		}
	}
}
