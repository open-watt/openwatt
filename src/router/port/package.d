module router.port;

import urt.string;

import manager.instance;

class Port
{
	ApplicationInstance instance;

	String name;
	String type;

	this(ApplicationInstance instance, String name, String type)
	{
		import core.lifetime;

		this.instance = instance;
		this.name = name.move;
		this.type = type.move;
	}
}
