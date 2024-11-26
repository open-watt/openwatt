module protocol.tesla.sampler;

import urt.array;

import manager.element;
import manager.sampler;
import manager.subscriber;
import manager.value;

import protocol.tesla;
import protocol.tesla.master;

import router.iface.mac;

nothrow @nogc:


class TeslaTWCSampler : Sampler
{
nothrow @nogc:

    this(TeslaProtocolModule.Instance tesla_mod, ushort chargerId, MACAddress mac)
    {
        this.tesla_mod = tesla_mod;
        this.chargerId = chargerId;
        this.mac = mac;
    }

    final override void update()
    {
        if (!master)
        {
            outer: foreach (twc; tesla_mod.twcMasters)
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
                    e.value(charger.targetCurrent);
                    break;
                case "state":           e.value(charger.chargerState);                               break;
                case "maxCurrent":      e.value(charger.maxCurrent);                                 break;
                case "current":         e.value((charger.flags & 2) ? charger.current : 0);          break;
                case "voltage1":        e.value((charger.flags & 2) ? charger.voltage1 : 0);         break;
                case "voltage2":        e.value((charger.flags & 2) ? charger.voltage2 : 0);         break;
                case "voltage3":        e.value((charger.flags & 2) ? charger.voltage3 : 0);         break;
                case "totalPower":      e.value((charger.flags & 2) ? charger.totalPower : 0);       break;
                case "activePower1":    e.value((charger.flags & 2) ? charger.power1 : 0);           break;
                case "activePower2":    e.value((charger.flags & 2) ? charger.power2 : 0);           break;
                case "activePower3":    e.value((charger.flags & 2) ? charger.power3 : 0);           break;
                case "lifetimeEnergy":  e.value((charger.flags & 2) ? charger.lifetimeEnergy : 0);   break;
                case "serialNumber":    e.value((charger.flags & 4) ? charger.serialNumber : "");    break;
                case "vin":             e.value((charger.flags & 0xF0) == 0xF ? charger.vin : "");   break;
                default:
                    assert(false, "Invalid element for Tesla TWC");
            }
        }
    }

    final void addElement(Element* element)
    {
        if (!elements[].exists(element))
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

    void onChange(Element* e, ref const Value val, Subscriber whoMadeChange)
    {
        if (!master) // if not bound, we can't apply any values
            return;

        if (e.id[] == "targetCurrent")
        {
            TeslaTWCMaster.Charger* charger = &master.chargers[chargerIndex];
            charger.targetCurrent = cast(ushort)val.asFloat();

            import urt.log;
            writeDebug("Set target current: ", charger.targetCurrent);
        }
    }

    TeslaProtocolModule.Instance tesla_mod;
    TeslaTWCMaster master;
    ubyte chargerIndex;
    ushort chargerId;
    MACAddress mac;

    Array!(Element*) elements;

//    struct SampleElement
//    {
//        Element* element;
//        //...
//    }
}
