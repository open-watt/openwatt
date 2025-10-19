module protocol.tesla.sampler;

import urt.array;
import urt.si.quantity;
import urt.variant;

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

    this(TeslaProtocolModule tesla_mod, ushort chargerId, MACAddress mac)
    {
        this.tesla_mod = tesla_mod;
        this.chargerId = chargerId;
        this.mac = mac;
    }

    final override void update()
    {
        if (!master)
        {
            outer: foreach (twc; tesla_mod.twcMasters.values)
            {
                foreach (i, ref c; twc.chargers)
                {
                    if (chargerId == c.id || mac == c.mac)
                    {
                        master = twc;
                        chargerIndex = cast(ubyte)i;
                        break outer;
                    }
                }
            }
        }
        if (!master)
            return;

        TeslaTWCMaster.Charger* charger = &master.chargers[chargerIndex];

        // we'll just update the element values by name
        // TODO: user can write to targetCurrent, and we should update it here...
        foreach (e; elements)
        {
            switch (e.id[])
            {
                case "targetCurrent":
                    // TODO: user can write to targetCurrent...
                    e.value(CentiAmps(charger.targetCurrent));
                    break;
                case "state":           e.value(charger.chargerState);                                  break;
                case "maxCurrent":      e.value(CentiAmps(charger.maxCurrent));                         break;
                case "current":         e.value(CentiAmps((charger.flags & 2) ? charger.current : 0));  break;
                case "voltage1":        e.value(Volts((charger.flags & 2) ? charger.voltage1 : 0));     break;
                case "voltage2":        e.value(Volts((charger.flags & 2) ? charger.voltage2 : 0));     break;
                case "voltage3":        e.value(Volts((charger.flags & 2) ? charger.voltage3 : 0));     break;
                case "power":           e.value(Watts((charger.flags & 2) ? charger.totalPower : 0));   break;
                case "power1":          e.value(Watts((charger.flags & 2) ? charger.power1 : 0));       break;
                case "power2":          e.value(Watts((charger.flags & 2) ? charger.power2 : 0));       break;
                case "power3":          e.value(Watts((charger.flags & 2) ? charger.power3 : 0));       break;
                case "totalImportActiveEnergy":
                case "lifetimeEnergy":
                    // TODO: could that multiply realistically overflow?
                    e.value(WattHours((charger.flags & 2) ? ulong(charger.lifetimeEnergy) * 1000 : 0));
                    break;
                case "serialNumber":    e.value((charger.flags & 4) ? charger.serialNumber : "");       break;
                case "vin":             e.value((charger.flags & 0xF0) == 0xF0 ? charger.vin : "");     break;
                default:
                    assert(false, "Invalid element for Tesla TWC");
            }
        }
    }

    final void addElement(Element* element)
    {
        if (!elements[].contains(element))
        {
            elements ~= element;
            if (element.access != Access.Read)
                element.addSubscriber(this);
        }
    }

    final override void removeElement(Element* element)
    {
        if (element.access != Access.Read)
            element.removeSubscriber(this);
        elements.removeFirstSwapLast(element);
    }

    void on_change(Element* e, ref const Variant val, Subscriber who_made_change)
    {
        if (!master) // if not bound, we can't apply any values
            return;

        if (e.id[] == "targetCurrent")
        {
            TeslaTWCMaster.Charger* charger = &master.chargers[chargerIndex];
            charger.targetCurrent = (cast(CentiAmps)val.asQuantity()).value;

            import urt.log;
            writeDebug("Set target current: ", charger.targetCurrent);
        }
    }

    TeslaProtocolModule tesla_mod;
    TeslaTWCMaster master;
    ubyte chargerIndex;
    ushort chargerId;
    MACAddress mac;

    Array!(Element*) elements;
}
