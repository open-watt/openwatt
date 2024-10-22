module manager.component;

import urt.array;
import urt.log;
import urt.map;
import urt.string;

import manager.device;
import manager.element;
import manager.units;
import manager.value;

import router.modbus.profile;

nothrow @nogc:


struct FieldTemplate
{
    String name;
    String unit;
    ubyte flags; // mandatory, hidden
    // default value or default value expression (using related values)
}

struct ComponentTempalte
{
    String name;
    FieldTemplate[] fields;
}


struct Component
{
nothrow @nogc:
	String id;
	String name;
	String template_;
	Array!(Element*) elements;

	import urt.string.format;
	ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const
	{
		return format(buffer, "Component({0}, \"{1}\", ...)", id, name).length;
	}
}


Map!(const(char)[], FieldTemplate*) componentTemplates;
//__gshared immutable FieldTemplate[] templates = [
//    FieldTemplate("switch");
//];

