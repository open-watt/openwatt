module manager.binding;

import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.result;
import urt.string;
import urt.time;
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
    alias Properties = AliasSeq!(Prop!("device", device),
                                 Prop!("offline-timeout", offline_timeout));
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
        detach_device();
        _device = value.move;
        mark_set!(typeof(this), "device")();
        restart();
    }

    // silence longer than this marks the device offline; zero disables the watchdog
    final Duration offline_timeout() const pure
        => _quiet_limit;
    final void offline_timeout(Duration value)
    {
        _quiet_limit = value;
        mark_set!(typeof(this), "offline-timeout")();
        if (_quiet_armed)
        {
            g_app.cancel(&quiet_check);
            _quiet_armed = false;
        }
        if (running && _last_activity != MonoTime.init)
            arm_quiet();
    }

protected:
    enum offline_after = 3;                     // consecutive poll failures
    enum offline_grace = dur!"seconds"(30);     // and no successful sample within this window

    String _device;
    Device _bound_device;
    Duration _quiet_limit;
    MonoTime _last_activity;
    ubyte _poll_failures;
    bool _quiet_armed;

    bool materialise()
    {
        return true;
    }

    // an element this binding samples or writes: shaped in the builder's scope, owned by this binding
    final Element* bind_element(ref DeviceBuilder b, Component parent, const(char)[] id, FormatId format = FormatId.init, manager.element.Access access = manager.element.Access.read)
    {
        Element* e = b.element(parent, id, format);
        b.device.attach_binding(this, e, access);
        return e;
    }

    final void note_activity()
    {
        _last_activity = getTime();
        set_device_online(true);
        arm_quiet();
    }

    final void report_poll(bool success)
    {
        if (success)
        {
            _poll_failures = 0;
            note_activity();
        }
        else
        {
            if (_poll_failures != ubyte.max)
                ++_poll_failures;
            if (_poll_failures >= offline_after && getTime() - _last_activity >= offline_grace)
                set_device_online(false);
        }
    }

    final void set_device_online(bool online)
    {
        if (_bound_device)
            _bound_device.set_online(cast(void*)this, online);
    }

    override CompletionStatus shutdown()
    {
        detach_device();
        return CompletionStatus.complete;
    }

    void detach_device()
    {
        if (_quiet_armed)
        {
            g_app.cancel(&quiet_check);
            _quiet_armed = false;
        }
        _poll_failures = 0;
        _last_activity = MonoTime.init;
        if (!_bound_device)
            return;
        _bound_device.remove_online_source(cast(void*)this);
        _bound_device.detach_binding(this);
        _bound_device = null;
    }

private:
    void arm_quiet()
    {
        if (!g_app || _quiet_limit <= Duration.zero || _quiet_armed)
            return;
        g_app.schedule(_last_activity + _quiet_limit, &quiet_check);
        _quiet_armed = true;
    }

    void quiet_check(MonoTime)
    {
        _quiet_armed = false;
        if (_quiet_limit <= Duration.zero)
            return;
        MonoTime deadline = _last_activity + _quiet_limit;
        MonoTime now = getTime();
        if (now < deadline)
        {
            g_app.schedule(deadline, &quiet_check);
            _quiet_armed = true;
            return;
        }
        set_device_online(false);
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

    abstract const(char)[] profile_name() const pure;
    abstract const(char)[] model_name() const pure;
    abstract FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte index);

    final FormatId attach_element(Device device, Element* element, ref const ElementDesc desc, ubyte index)
    {
        FormatId format = add_handler(device, element, desc, index);
        if (format.valid)
        {
            if (_bound_device && _bound_device !is device)
                detach_device();
            _bound_device = device;
            device.attach_binding(this, element, cast(manager.element.Access)desc.access);
        }
        return format;
    }

    override StringResult set_unknown_property(scope const(char)[] property, ref const Variant value)
    {
        if (!value.isString)
            return StringResult(tconcat("Profile parameter '", property, "' must be a string"));
        String key = property.make_string();
        String val = value.asString().make_string();
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
        Device device = create_device_from_profile(*_profile_data, model_name(), _device[], null, &attach_element);
        if (!device)
        {
            writeWarning(name, ": failed to materialise device '", _device, "'");
            detach_device();
            g_app.release_profile(_profile_data);
            _profile_data = null;
            return false;
        }

        return true;
    }

    override CompletionStatus shutdown()
    {
        detach_device();
        // release, don't free: the registry retains the parse (element descs and
        // expressions on surviving devices borrow its strings), and the next startup
        // re-acquires the live copy and re-materialises subclass element state
        if (_profile_data)
        {
            g_app.release_profile(_profile_data);
            _profile_data = null;
        }
        return super.shutdown();
    }
}

unittest
{
    import manager.collection : collection_type_info, item_table;

    static final class TestBinding : ProtocolBinding
    {
        enum type_name = "liveness-test-binding";
        enum collection_id = cast(CollectionType)0;
    nothrow @nogc:

        Device target;
        uint startups, fail_first;

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestBinding, id, flags);
        }

        override CompletionStatus startup()
        {
            ++startups;
            if (fail_first)
            {
                --fail_first;
                return CompletionStatus.error;
            }
            _bound_device = target;
            return CompletionStatus.complete;
        }

        override CompletionStatus shutdown()
        {
            detach_device();
            return super.shutdown();
        }

        void heard()
            => note_activity();
    }

    DeviceTable devices;
    DeviceBuilder b = devices.create("liveness-binding-test");
    Device dev = b.device;
    b.commit();

    auto table = &item_table(0);
    TestBinding binding = alloc!TestBinding(table.allocate("liveness-b", 0));
    table.bind(binding.id, binding);
    binding.target = dev;
    binding.fail_first = 1;
    binding.do_update();
    assert(binding.startups == 1 && !binding.running);
    binding.do_update();
    assert(binding.startups == 2 && binding.running);
    binding.heard();
    assert(dev.online_status == OnlineStatus.online);

    binding.restart();
    assert(dev.online_status == OnlineStatus.offline && binding._bound_device is null);
    binding.do_update();
    assert(binding.running && dev.online_status == OnlineStatus.offline);
    binding.heard();
    assert(dev.online_status == OnlineStatus.online);

    int other;
    dev.set_online(&other, true);
    binding.disabled = true;
    binding.do_update();
    assert(dev.online_status == OnlineStatus.online && binding._bound_device is null);
    dev.remove_online_source(&other);
    assert(dev.online_status == OnlineStatus.offline);
    binding.disabled = false;
    binding.do_update();
    binding.heard();
    assert(dev.online_status == OnlineStatus.online);

    binding.device = StringLit!"replacement";
    assert(dev.online_status == OnlineStatus.offline && binding._last_activity == MonoTime.init);
    binding.do_update();
    binding.heard();
    binding.fail_first = 1;
    binding.restart();
    binding.do_update();
    assert(!binding.running && dev.online_status == OnlineStatus.offline);
    binding.destroy();
    assert(!binding._quiet_armed);
    table.free_pending();

    binding = alloc!TestBinding(table.allocate("liveness-disabled", 0));
    table.bind(binding.id, binding);
    binding.target = dev;
    binding.do_update();
    binding.heard();
    binding.fail_first = 1;
    binding.restart();
    binding.do_update();
    binding.disabled = true;
    assert(dev.online_status == OnlineStatus.offline && binding._bound_device is null);
    binding.destroy();
    table.free_pending();
}
