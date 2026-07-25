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
import manager.sample;

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

    // subscribe this to whatever the binding reads from: the state machine backs off and retries
    final void restart_on_offline(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }
}


abstract class ProfileBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    final const(char)[] get_param(const(char)[] name) const pure
    {
        if (auto p = name in _params)
            return (*p)[];
        return null;
    }

    override bool validate() const pure
        => !_profile_name.empty && !_device.empty;

protected:
    String _profile_name;
    String _model_name;
    Profile* _profile_data;
    Map!(String, String) _params;

    // the configured names, unless the binding resolves them elsewhere (modbus reads its slave map)
    const(char)[] profile_name() const pure
        => _profile_name[];
    const(char)[] model_name() const pure
        => _model_name[];

    abstract FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte index);

    // give a freshly materialised element its format and a typed zero, so it reads as its own
    // type before the first sample lands; an invalid result means the spelling never compiled
    final SampleDesc init_element_sample(Element* e, ushort desc_index)
    {
        if (desc_index == ushort.max)
            return SampleDesc.init;

        SampleDesc sd = desc_by_index(desc_index);
        e.format = sd.format;
        if (sd.fmt.is_scalar)
        {
            Scalar zero;
            zero.raw[] = 0;
            e.value = box_record(zero.raw.ptr, *sd.fmt);
        }
        return sd;
    }

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
        // set only on full success; startup() may poll materialise() while
        // waiting on dependencies, and must not repeat the work
        if (_profile_data)
            return true;

        const(char)[] pname = profile_name();
        if (!pname)
        {
            writeWarning(name, ": no profile specified");
            return false;
        }

        Profile* profile = g_app.acquire_profile(pname);
        if (!profile)
        {
            writeWarning(name, ": failed to load profile '", pname, "'");
            return false;
        }

        bool bad = false;
        foreach (k; _params.keys)
        {
            bool declared = false;
            foreach (d; profile.get_parameters())
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
        {
            g_app.release_profile(profile);
            return false;
        }

        // add_handler reads _profile_data during device creation
        _profile_data = profile;
        Device device = create_device_from_profile(*_profile_data, model_name(), _device[], null, &add_handler);
        if (!device)
        {
            writeWarning(name, ": failed to materialise device '", _device, "'");
            g_app.release_profile(_profile_data);
            _profile_data = null;
            return false;
        }

        return true;
    }

    override CompletionStatus shutdown()
    {
        // release, don't free: the registry retains the parse (element descs and
        // expressions on surviving devices borrow its strings), and the next startup
        // re-acquires the live copy and re-materialises subclass element state
        if (_profile_data)
        {
            g_app.release_profile(_profile_data);
            _profile_data = null;
        }
        return CompletionStatus.complete;
    }
}
