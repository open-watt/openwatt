module router.port.serial;

import urt.string;

import manager.instance;

import router.port;


class SerialPort : Port
{
	this(ApplicationInstance instance, String name)
	{
		super(instance, name, StringLit!"serial");
	}
}
