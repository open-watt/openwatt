module manager.component;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.string;
import urt.time;

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

    bool hidden;

    Array!(Component) components;
    Array!(Element*) elements;

    // extern(C++) has no dynamic cast: cast(Device) always "succeeds", so test this before painting
    bool is_device() const pure
        => false;

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
        // Same iteration shape as BaseObject.signal_state_change — handlers may
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

    Element* find_or_create_element(const(char)[] name, FormatId format)
    {
        assert(format.valid, "an element requires a format");
        const(char)[] id = name.split!'.';
        if (!name.empty)
        {
            foreach (Component c; components)
            {
                if (c.id[] == id[])
                    return c.find_or_create_element(name, format);
            }

            Component c = alloc!Component(id.make_string());
            c.parent = this;
            components ~= c;
            return c.find_or_create_element(name, format);
        }

        foreach (Element* e; elements)
        {
            if (e.id[] == id[])
            {
                assert(e.format == format || value_compatible(*format_info(format), *e.data_format),
                       "element path reused with an incompatible format");
                return e;
            }
        }

        Element* e = alloc_element();
        e.format = format;
        e.parent = this;
        elements ~= e;
        e.id = id.make_string();
        g_app.notify_element_created(e);
        return e;
    }

    Element* set_element(T)(const(char)[] name, auto ref T value,
                            SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        Element* e = find_element(name);
        if (!e)
            e = find_or_create_element(name, register_value_format(value));
        e.value(value, timestamp, who);
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


