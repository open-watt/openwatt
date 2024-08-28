module protocol.tesla.master;

import urt.string;

import router.iface;


class TeslaTWCMaster
{
	String name;
	BaseInterface iface;

	this(String name, BaseInterface iface)
	{
		import core.lifetime;

		this.name = name.move;
		this.iface = iface;
	}

}
