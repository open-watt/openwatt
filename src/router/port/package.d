module router.port;

import urt.string;

import manager;

class Port
{
	Application instance;

	String name;
	String type;

	this(Application instance, String name, String type)
	{
		import urt.lifetime;

		this.instance = instance;
		this.name = name.move;
		this.type = type.move;
	}
}
