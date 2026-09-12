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
    materialised,   // tree is populated/ready for consumers
    online,         // backing source reachable
    offline,        // backing source unreachable
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
        _id = id.move;
    }

    final ref const(String) id() const pure
        => _id;

    String name;
    String template_;
    Component parent;

    bool hidden;

    final inout(Component)[] components() inout pure
        => _components[];
    final inout(Element*)[] elements() inout pure
        => _elements[];

    // extern(C++) has no dynamic cast: cast(Device) always "succeeds", so test this before painting
    bool is_device() const pure
        => false;

    final inout(Device) root_device() inout pure
    {
        if (parent)
            return parent.root_device();
        return is_device ? cast(inout(Device))this : null;
    }

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
        if (event == ComponentEvent.tree_changed && parent)
            parent.notify(event);
    }

    // mutators, reached only through DeviceBuilder
    final package(manager) Component find_or_create_component(const(char)[] path, const(char)[] template_ = null)
    {
        const(char)[] seg = path.split!'.';
        Component c;
        foreach (Component existing; _components)
        {
            if (existing.id[] == seg[])
            {
                c = existing;
                break;
            }
        }
        if (c is null)
        {
            c = alloc!Component(seg.make_string());
            c.parent = this;
            _components ~= c;
            mutated(null);
        }
        if (!path.empty)
            return c.find_or_create_component(path, template_);
        if (template_.length && c.template_[] != template_)
        {
            c.template_ = template_.make_string();
            mutated(null);
        }
        return c;
    }

    final package(manager) void attach_element(Element* e)
    {
        assert(e && e.id.length, "element needs an id");
        debug assert(find_element(e.id[]) is null, "element already exists");
        e.parent = this;
        _elements ~= e;
        mutated(e);
    }

    final inout(Component) find_component(const(char)[] name) inout pure nothrow @nogc
    {
        const(char)[] id = name.split!'.';
        foreach (inout Component c; components)
        {
            if (c.id[] == id[])
                return name.empty ? c : c.find_component(name);
        }
        return null;
    }

    final inout(Element)* find_element(const(char)[] name) inout pure nothrow @nogc
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

    final package(manager) Element* find_or_create_element(const(char)[] name, FormatId format = FormatId.init)
    {
        const(char)[] id = name.split!'.';
        if (!name.empty)
            return find_or_create_component(id).find_or_create_element(name, format);

        foreach (Element* e; _elements)
        {
            if (e.id[] == id[])
            {
                if (!e.format.valid)
                    e.format = format;
                else if (format.valid)
                {
                    import urt.mem.temp : tconcat;
                    debug assert(e.format == format || value_compatible(*format_info(format), *e.data_format), tconcat("element '", id[], ".", e.id[], "' reused with an incompatible format"));
                }
                return e;
            }
        }

        Element* e = alloc_element();
        e.format = format;
        e.id = id.make_string();
        attach_element(e);
        return e;
    }

    // a value write to a declared element; the tree is not the writer's to grow
    Element* write_element(T)(const(char)[] name, auto ref T value, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        Element* e = find_element(name);
        if (e)
            e.value(value, timestamp, who);
        else
        {
            debug assert(false, "write to an undeclared element");
            writeWarning("element '", name, "' is not declared in '", id[], "'");
        }
        return e;
    }

    package(manager) Element* set_element(T)(const(char)[] name, auto ref T value, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        Element* e = find_element(name);
        if (!e)
            e = find_or_create_element(name, register_value_format(value));
        e.value(value, timestamp, who);
        return e;
    }

    final inout(Component) get_first_component_by_template(const char[] template_name) inout pure nothrow @nogc
    {
        foreach (inout Component c; components)
            if (c.template_[] == template_name[])
                return c;
        return null;
    }

    final inout(Component) find_first_component_by_template_recursive(const char[] template_name) inout pure nothrow @nogc
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

    final ptrdiff_t full_path(char[] buf) const nothrow @nogc
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
    final ptrdiff_t toString(char[] buffer, const(char)[] fmt, const(FormatArg)[] format_args) const
    {
        return format(buffer, "Component({0}, \"{1}\", ...)", id, name).length;
    }

private:
    String _id;
    Array!(Component) _components;
    Array!(Element*) _elements;
    Array!ComponentSubscriber _subscribers;

    void mutated(Element* created)
    {
        if (Device d = root_device())
        {
            if (d._editing)
            {
                d._dirty = true;
                if (created)
                    d._created ~= created;
                return;
            }
            if (d.cid)
            {
                debug assert(false, "device tree mutated outside a DeviceBuilder");
                writeWarning("device '", d.id[], "' mutated outside a DeviceBuilder");
            }
        }
        if (created && g_app)
            g_app.notify_element_created(created);
        notify(ComponentEvent.tree_changed);
    }
}


unittest
{
    Component component = alloc!Component(StringLit!"component");
    Element* element = alloc_element();
    element.id = StringLit!"value";
    component.attach_element(element);

    FormatId format = register_value_format!uint();
    assert(!element.format.valid);
    assert(component.find_or_create_element("value", format) is element);
    assert(element.format == format);

    static struct Changes
    {
        Component root;
        uint count;

        void changed(Component source, ComponentEvent event) nothrow @nogc
        {
            assert(source is root && event == ComponentEvent.tree_changed);
            ++count;
        }
    }

    Changes changes = Changes(component);
    component.subscribe(&changes.changed);
    Component child = component.find_or_create_component("child");
    scope(exit) free(child);
    assert(changes.count == 1);
    Component nested = child.find_or_create_component("nested");
    scope(exit) free(nested);
    assert(changes.count == 2);
    nested.notify(ComponentEvent.tree_changed);
    assert(changes.count == 3);
    nested.notify(ComponentEvent.offline);
    assert(changes.count == 3);
    component.unsubscribe(&changes.changed);
    nested.notify(ComponentEvent.tree_changed);
    assert(changes.count == 3);
}
