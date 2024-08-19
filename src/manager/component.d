module manager.component;

import manager.device;
import manager.element;
import manager.units;
import manager.value;

import router.modbus.profile;
import router.server;

import urt.log;
import urt.string;


struct Component
{
	String id;
	String name;
	Element[] elements;
	Element*[String] elementsById;

	import urt.string.format;
	ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const nothrow @nogc
	{
		return format(buffer, "Component({0}, \"{1}\", ...)", id, name).length;
	}
}
