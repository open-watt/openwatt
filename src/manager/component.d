module manager.component;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.device;
import manager.element;

nothrow @nogc:


enum ComponentEvent : ubyte
{
    online,         // tree is populated/ready for consumers
    offline,        // backing source disconnected
    tree_changed,   // structure (children/elements) mutated
    destroyed,
}

alias ComponentSubscriber = void delegate(Component component, ComponentEvent event) nothrow @nogc;


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
    Component parent;

    Array!(Component) components;
    Array!(Element*) elements;

    final void subscribe(ComponentSubscriber handler)
    {
        assert(!_subscribers[].contains(handler), "Already registered");
        _subscribers ~= handler;
    }

    final void unsubscribe(ComponentSubscriber handler) pure
    {
        _subscribers.removeFirstSwapLast(handler);
    }

    final void notify(ComponentEvent event)
    {
        // Same iteration shape as BaseObject.signal_state_change - handlers may
        // unsubscribe themselves during the callback.
        for (size_t i = 0; i < _subscribers.length; )
        {
            auto h = _subscribers[i];
            h(this, event);
            if (i < _subscribers.length && _subscribers[i] is h)
                ++i;
        }
    }

    void add_component(Component component) // TODO: include sampler here...
    {
        import urt.mem.temp : tconcat;
        foreach (Component c; components)
        {
            if (c.id[] == component.id[])
            {
                debug assert(false, tconcat("Component '", component.id[], "' already exists in device '", id[], "'"));
                assert(false, "Already exists");
                return;
            }
        }
        component.parent = this;
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

    Element* find_or_create_element(const(char)[] name)
    {
        const(char)[] id = name.split!'.';
        if (!name.empty)
        {
            foreach (Component c; components)
            {
                if (c.id[] == id[])
                    return c.find_or_create_element(name);
            }

            Component c = g_app.allocator.allocT!Component(id.makeString(defaultAllocator()));
            c.parent = this;
            components ~= c;
            return c.find_or_create_element(name);
        }

        foreach (Element* e; elements)
        {
            if (e.id[] == id[])
                return e;
        }

        Element* e = g_app.allocator.allocT!Element();
        e.parent = this;
        elements ~= e;
        e.id = id.makeString(defaultAllocator());
        g_app.notify_element_created(e);
        return e;
    }

    inout(Component) get_first_component_by_template(const char[] template_name) inout pure nothrow @nogc
    {
        foreach (inout Component c; components)
            if (c.template_[] == template_name[])
                return c;
        return null;
    }

    inout(Component) find_first_component_by_template_recursive(const char[] template_name) inout pure nothrow @nogc
    {
        foreach (inout Component c; components)
        {
            if (c.template_[] == template_name[])
                return c;
            if (inout Component r = c.find_first_component_by_template_recursive(template_name))
                return r;
        }
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

    ptrdiff_t full_path(char[] buf) const nothrow @nogc
    {
        size_t pos;
        if (parent)
        {
            pos = parent.full_path(buf);
            if (pos < buf.length)
                buf[pos] = '.';
            ++pos;
        }
        if (pos + id.length <= buf.length)
            buf[pos .. pos + id.length] = id[];
        return pos + id.length;
    }

    import urt.string.format;
    ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] format_args) const
    {
        return format(buffer, "Component({0}, \"{1}\", ...)", id, name).length;
    }

private:
    Array!ComponentSubscriber _subscribers;
}


//__gshared Map!(const(char)[], FieldTemplate*) g_component_templates;
//__gshared immutable FieldTemplate[] templates = [
//    FieldTemplate("switch");
//];

