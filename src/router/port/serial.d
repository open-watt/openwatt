module router.port.serial;

import urt.string;

import manager;

import router.port;


class SerialPort : Port
{
	this(ApplicationInstance instance, String name)
	{
		super(instance, name, StringLit!"serial");
	}
}
