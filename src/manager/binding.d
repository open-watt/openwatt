module manager.binding;

import urt.log;
import urt.map;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.result;
import urt.string;
import urt.variant;

import manager;
import manager.base;
import manager.component;
import manager.device;
import manager.element;
import manager.profile;

nothrow @nogc:


abstract class ProtocolBinding : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("device", device));
nothrow @nogc:

    enum type_name = "binding";
    enum path = "/binding";
    enum collection_id = CollectionType.binding;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
    }

    final ref const(String) device() const pure
        => _device;
    final void device(String value)
    {
        if (value == _device)
            return;
        _device = value.move;
        mark_set!(typeof(this), "device")();
        if (!_device.empty && _device[] !in g_app.devices)
        {
            Device d = g_app.allocator.allocT!Device(_device[].makeString(g_app.allocator));
            g_app.devices.insert(d.id[], d);
        }
        restart();
    }

protected:
    String _device;

    // build the binding device tree
    bool materialise()
    {
        return true;
    }
}


abstract class ProfileBinding : ProtocolBinding
{
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
    }

    final const(char)[] get_param(const(char)[] name) const pure
    {
        if (auto p = name in _params)
            return (*p)[];
        return null;
    }

protected:
    Profile* _profile_data;
    Map!(String, String) _params;

    abstract const(char)[] profile_dir() const pure;
    abstract const(char)[] profile_name() const pure;
    abstract const(char)[] model_name() const pure;
    abstract void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte index);

    override StringResult set_unknown_property(scope const(char)[] property, ref const Variant value)
    {
        if (!value.isString)
            return StringResult(tconcat("Profile parameter '", property, "' must be a string"));
        String key = property.makeString(g_app.allocator);
        String val = value.asString().makeString(g_app.allocator);
        _params[key.move] = val.move;
        restart();
        return StringResult.success;
    }

    override bool materialise()
    {
        if (_profile_data)
            return true;

        const(char)[] pname = profile_name();
        if (!pname)
        {
            writeWarning(name, ": no profile specified");
            return false;
        }

        import urt.file : load_file;

        void[] file = load_file(tconcat(profile_dir(), pname, ".conf"), g_app.allocator);
        if (!file)
        {
            writeWarning(name, ": failed to load profile '", pname, "'");
            return false;
        }
        _profile_data = parse_profile(cast(char[])file, g_app.allocator);
        if (!_profile_data)
        {
            writeWarning(name, ": failed to parse profile '", pname, "'");
            return false;
        }

        bool bad = false;
        foreach (declared; _profile_data.get_parameters())
        {
            if (declared[] !in _params)
            {
                writeWarning(name, ": missing required parameter '", declared, "' for profile '", pname, "'");
                bad = true;
            }
        }
        foreach (k; _params.keys)
        {
            bool declared = false;
            foreach (d; _profile_data.get_parameters())
            {
                if (d[] == k[])
                {
                    declared = true;
                    break;
                }
            }
            if (!declared)
            {
                writeWarning(name, ": unknown parameter '", k[], "' for profile '", pname, "'");
                bad = true;
            }
        }
        if (bad)
            return false;

        Device device = create_device_from_profile(*_profile_data, model_name(), _device[], null, &add_handler);
        if (!device)
        {
            writeWarning(name, ": failed to materialise device '", _device, "'");
            return false;
        }

        return true;
    }

    override CompletionStatus shutdown()
    {
        if (_profile_data)
        {
            g_app.allocator.freeT(_profile_data);
            _profile_data = null;
        }
        return CompletionStatus.complete;
    }
}
