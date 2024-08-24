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
		this.instance = instance;
		this.name = name;
		this.type = type;
	}
}
