module protocol.tesla.sampler;

import urt.array;
import urt.log;
import urt.mem.string : addString;
import urt.meta : AliasSeq;
import urt.si;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;

import protocol.tesla;
import protocol.tesla.master;

import router.iface.mac;

version = DebugTWCBinding;

nothrow @nogc:


class TeslaTWCBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("slave_id", slave_id),
                                 Prop!("mac", mac));
nothrow @nogc:

    enum type_name = "twc-binding";
    enum path = "/binding/tesla/twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaTWCBinding, id, flags);
    }

    final ushort slave_id() const pure
        => _slave_id;
    final void slave_id(ushort value)
    {
        if (_slave_id == value)
            return;
        _slave_id = value;
        restart();
    }

    final MACAddress mac() const pure
        => _mac;
    final void mac(MACAddress value)
    {
        if (_mac == value)
            return;
        _mac = value;
        restart();
    }

    final override bool validate() const pure
    {
        return !_device.empty && (_slave_id != 0 || _mac != MACAddress());
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        if (!_master)
        {
            auto tesla_mod = get_module!TeslaProtocolModule;
            outer: foreach (twc; tesla_mod.twc_masters.values)
            {
                foreach (i, ref c; twc.chargers)
                {
                    if ((_slave_id != 0 && _slave_id == c.id) || (_mac != MACAddress() && _mac == c.mac))
                    {
                        _master = twc;
                        _charger_index = cast(ubyte)i;
                        break outer;
                    }
                }
            }
            if (!_master)
                return CompletionStatus.continue_;
        }

        if (_target_current && _target_current.access != Access.read)
        {
            _target_current.add_subscriber(&on_target_current_change);
            _subscribed = true;
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _target_current.remove_subscriber(&on_target_current_change);
            _subscribed = false;
        }
        _master = null;
        _target_current = null;
        _elements.clear();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_master)
            return;

        TeslaTWCMaster.Charger* charger = &_master.chargers[_charger_index];

        // TODO: user can write to target_current; we just push the master's view here
        foreach (e; _elements)
        {
            switch (e.id[])
            {
                case "target_current":  e.value(CentiAmps(charger.target_current));                                       break;
                case "state":           e.value(charger.charger_state);                                                   break;
                case "twc_state":       e.value(charger.state);                                                           break;
                case "max_current":     e.value(CentiAmps(charger.max_current));                                          break;
                case "current":         e.value(CentiAmps((charger.flags & 2) ? charger.current : 0));                    break;
                case "voltage1":        e.value(Volts((charger.flags & 2) ? charger.voltage1 : 0));                       break;
                case "voltage2":        e.value(Volts((charger.flags & 2) ? charger.voltage2 : 0));                       break;
                case "voltage3":        e.value(Volts((charger.flags & 2) ? charger.voltage3 : 0));                       break;
                case "power":           e.value(Watts((charger.flags & 2) ? charger.total_power : 0));                    break;
                case "power1":          e.value(Watts((charger.flags & 2) ? charger.power1 : 0));                         break;
                case "power2":          e.value(Watts((charger.flags & 2) ? charger.power2 : 0));                         break;
                case "power3":          e.value(Watts((charger.flags & 2) ? charger.power3 : 0));                         break;
                case "import":
                case "lifetime_energy":
                    e.value(WattHours((charger.flags & 2) ? ulong(charger.lifetime_energy) * 1000 : 0));
                    break;
                case "serial_number":   e.value((charger.flags & 4) ? charger.serial_number : "");                        break;
                case "vin":             e.value((charger.flags & 0xF0) == 0xF0 ? charger.vin : "");                       break;
                default:
                    assert(false, "Invalid element for Tesla TWC");
            }
        }
    }

protected:
    override bool materialise()
    {
        if (_built)
            return true;

        Device device;
        if (Device* existing = _device[] in g_app.devices)
            device = *existing;
        else
        {
            device = g_app.allocator.allocT!Device(_device);
            g_app.devices.insert(device.id[], device);
        }

        Component info = find_or_create_component(device, "info", "DeviceInfo");
        set_constant(find_or_create_element(info, "type"), "evse");
        set_constant(find_or_create_element(info, "name"), "Tesla Wall Charger Gen2");
        _elements ~= find_or_create_element(info, "serial_number");
        _elements ~= find_or_create_element(info, "lifetime_energy");
        _elements ~= find_or_create_element(info, "vin");

        Component cc = find_or_create_component(device, "charge_control", "ChargeControl");
        _elements ~= find_or_create_element(cc, "state");
        _elements ~= find_or_create_element(cc, "twc_state");
        _target_current = find_or_create_element(cc, "target_current", Access.read_write);
        _elements ~= _target_current;
        _elements ~= find_or_create_element(cc, "max_current");

        Component meter = find_or_create_component(device, "meter", "EnergyMeter");
        set_constant(find_or_create_element(meter, "type"), "three-phase");
        _elements ~= find_or_create_element(meter, "voltage1");
        _elements ~= find_or_create_element(meter, "voltage2");
        _elements ~= find_or_create_element(meter, "voltage3");
        _elements ~= find_or_create_element(meter, "current");
        _elements ~= find_or_create_element(meter, "power1");
        _elements ~= find_or_create_element(meter, "power2");
        _elements ~= find_or_create_element(meter, "power3");
        _elements ~= find_or_create_element(meter, "power");
        _elements ~= find_or_create_element(meter, "import");

        _built = true;
        return true;
    }

private:

    ushort _slave_id;
    MACAddress _mac;

    TeslaTWCMaster _master;
    ubyte _charger_index;

    bool _subscribed;
    bool _built;

    Element* _target_current;
    Array!(Element*) _elements;

    Component find_or_create_component(Component parent, const(char)[] id, const(char)[] template_)
    {
        foreach (c; parent.components)
            if (c.id[] == id)
                return c;
        Component c = g_app.allocator.allocT!Component(String(id.addString()));
        c.template_ = template_.addString();
        c.parent = parent;
        parent.components ~= c;
        return c;
    }

    Element* find_or_create_element(Component parent, const(char)[] id, Access access = Access.read)
    {
        foreach (e; parent.elements)
            if (e.id[] == id)
                return e;
        Element* e = g_app.allocator.allocT!Element();
        e.parent = parent;
        e.id = id.addString();
        e.access = access;
        parent.elements ~= e;
        g_app.notify_element_created(e);
        return e;
    }

    void set_constant(T)(Element* e, T value)
    {
        if (e.sampling_mode != SamplingMode.constant)
        {
            e.value(value);
            e.sampling_mode = SamplingMode.constant;
        }
    }

    void on_target_current_change(ref Element e, ref const Variant val, SysTime ts, ref const Variant prev, SysTime prev_ts)
    {
        if (!_master)
            return;
        TeslaTWCMaster.Charger* charger = &_master.chargers[_charger_index];
        charger.target_current = (cast(CentiAmps)val.asQuantity()).value;
        version (DebugTWCBinding)
            log.trace("set target current: ", charger.target_current);
    }
}
