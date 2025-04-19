module router.port.serial;

import urt.string;

import manager;

import router.port;


class SerialPort : Port
{
	this(Application instance, String name)
	{
		super(instance, name, StringLit!"serial");
	}
}
