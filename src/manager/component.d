module manager.component;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.string;

import manager.device;
import manager.element;

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

extern(C++)
class Component
{
extern(D):
nothrow @nogc:

    this(String id)
    {
        this.id = id.move;
    }

    String id;
    String name;
    String template_;

    Array!(Component) components;
    Array!(Element*) elements;

    void add_component(Component component) // TODO: include sampler here...
    {
        foreach (Component c; components)
        {
            if (c.name[] == component.name[])
            {
                debug assert(false, "Component '" ~ component.name ~ "' already exists in device '" ~ name ~ "'");
                assert(false, "Already exists");
                return;
            }
        }
        components.pushBack(component);
    }

    inout(Component) find_component(const(char)[] name) inout pure nothrow @nogc
    {
        const(char)[] id = name.split!'.';
        foreach (inout Component c; components)
        {
            if (c.id[] == id[])
                return name.empty ? c : c.find_component(name);
        }
        return null;
    }

    inout(Element)* find_element(const(char)[] name) inout pure nothrow @nogc
    {
        const(char)[] id = name.split!'.';
        if (!name.empty)
        {
            foreach (inout Component c; components)
            {
                if (c.id[] == id[])
                    return c.find_element(name);
            }
        }
        else
        {
            foreach (inout(Element)* e; elements)
            {
                if (e.id[] == id[])
                    return e;
            }
        }
        return null;
    }

    Component get_first_component_by_template(const char[] template_name)
    {
        foreach (Component c; components)
            if (c.template_[] == template_name[])
                return c;
        return null;
    }

    Array!Component find_components_by_template(const char[] template_name)
    {
        Array!Component result;
        foreach (Component c; components)
            if (c.template_[] == template_name[])
                result ~= c;
        return result;
    }

    import urt.string.format;
    ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] formatArgs) const
    {
        return format(buffer, "Component({0}, \"{1}\", ...)", id, name).length;
    }
}


//__gshared Map!(const(char)[], FieldTemplate*) g_component_templates;
//__gshared immutable FieldTemplate[] templates = [
//    FieldTemplate("switch");
//];

