module protocol.tesla.sampler;

import urt.array;
import urt.si.quantity;
import urt.time;
import urt.variant;

import manager;
import manager.element;
import manager.sampler;
import manager.subscriber;

import protocol.tesla;
import protocol.tesla.master;

import router.iface.mac;

nothrow @nogc:


class TeslaTWCSampler : Sampler
{
nothrow @nogc:

    this(ushort charger_id, MACAddress mac)
    {
        this.charger_id = charger_id;
        this.mac = mac;
    }

    final override void update()
    {
        if (!master)
        {
            auto tesla_mod = get_module!TeslaProtocolModule;
            outer: foreach (twc; tesla_mod.twc_masters.values)
            {
                foreach (i, ref c; twc.chargers)
                {
                    if (charger_id == c.id || mac == c.mac)
                    {
                        master = twc;
                        charger_index = cast(ubyte)i;
                        break outer;
                    }
                }
            }
        }
        if (!master)
            return;

        TeslaTWCMaster.Charger* charger = &master.chargers[charger_index];

        // we'll just update the element values by name
        // TODO: user can write to target_current, and we should update it here...
        foreach (e; elements)
        {
            switch (e.id[])
            {
                case "target_current":
                    // TODO: user can write to target_current...
                    e.value(CentiAmps(charger.target_current));
                    break;
                case "state":           e.value(charger.charger_state);                                 break;
                case "twc_state":       e.value(charger.state);                                         break;
                case "max_current":     e.value(CentiAmps(charger.max_current));                        break;
                case "current":         e.value(CentiAmps((charger.flags & 2) ? charger.current : 0));  break;
                case "voltage1":        e.value(Volts((charger.flags & 2) ? charger.voltage1 : 0));     break;
                case "voltage2":        e.value(Volts((charger.flags & 2) ? charger.voltage2 : 0));     break;
                case "voltage3":        e.value(Volts((charger.flags & 2) ? charger.voltage3 : 0));     break;
                case "power":           e.value(Watts((charger.flags & 2) ? charger.total_power : 0));  break;
                case "power1":          e.value(Watts((charger.flags & 2) ? charger.power1 : 0));       break;
                case "power2":          e.value(Watts((charger.flags & 2) ? charger.power2 : 0));       break;
                case "power3":          e.value(Watts((charger.flags & 2) ? charger.power3 : 0));       break;
                case "import":
                case "lifetime_energy":
                    // TODO: could that multiply realistically overflow?
                    e.value(WattHours((charger.flags & 2) ? ulong(charger.lifetime_energy) * 1000 : 0));
                    break;
                case "serial_number":    e.value((charger.flags & 4) ? charger.serial_number : "");      break;
                case "vin":             e.value((charger.flags & 0xF0) == 0xF0 ? charger.vin : "");     break;
                default:
                    assert(false, "Invalid element for Tesla TWC");
            }
        }
    }

    final void add_element(Element* element)
    {
        if (!elements[].contains(element))
        {
            elements ~= element;
            if (element.access != Access.read)
                element.add_subscriber(this);
        }
    }

    final override void remove_element(Element* element)
    {
        if (element.access != Access.read)
            element.remove_subscriber(this);
        elements.removeFirstSwapLast(element);
    }

    void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber who_made_change)
    {
        if (!master) // if not bound, we can't apply any values
            return;

        if (e.id[] == "target_current")
        {
            TeslaTWCMaster.Charger* charger = &master.chargers[charger_index];
            charger.target_current = (cast(CentiAmps)val.asQuantity()).value;

            import urt.log;
            writeDebug("Set target current: ", charger.target_current);
        }
    }

    TeslaTWCMaster master;
    ubyte charger_index;
    ushort charger_id;
    MACAddress mac;

    Array!(Element*) elements;
}
