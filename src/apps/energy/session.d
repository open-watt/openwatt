module apps.energy.session;

import urt.map;
import urt.mem : defaultAllocator;
import urt.string;
import urt.si.quantity : Quantity;
import urt.si.unit : KilowattHour, Percent;
import urt.time;

import apps.energy.appliance;
import apps.energy.meter : MeterField;
import apps.energy.model : read_in_unit;
import apps.energy.topology;
import apps.energy.vehicle : vehicle_for;

import manager.collection;
import manager.component;
import manager.element;

nothrow @nogc:


// A device-persistent EVSE counter provides a pessimistic SOC witness when the
// vehicle cannot report SOC itself.
struct ChargeSessionTracker
{
nothrow @nogc:

    // Discount AC-side energy so soc_floor remains a lower bound.
    enum float charge_efficiency = 0.88;

    enum float max_step_kwh = 50;

    enum session_gap_grace = dur!"seconds"(15);

    void tick(ref TopologyGraph graph)
    {
        foreach (Appliance a; Collection!Appliance().values)
        {
            if (a.vin.length == 0)
                continue;
            if (a.kind[] != "car" && a.kind[] != "vehicle")
                continue;

            float import_kwh = delivering_import_kwh(graph, a);

            Session* s = a.vin in sessions;
            if (import_kwh != import_kwh)
            {
                // A persistent counter recovers after transient telemetry gaps.
                if (s && s.active)
                {
                    MonoTime now = getTime();
                    if (s.nan_since == MonoTime.init)
                        s.nan_since = now;
                    else if (now - s.nan_since >= session_gap_grace)
                    {
                        s.active = false;
                        s.nan_since = MonoTime.init;
                        publish(a, float.nan, float.nan);
                    }
                }
                continue;
            }

            if (s is null)
            {
                sessions[a.vin.makeString(defaultAllocator())] = Session.init;
                s = a.vin in sessions;
            }

            s.nan_since = MonoTime.init;
            if (!s.active)
            {
                s.active = true;
                s.delivered_kwh = 0;
                s.last_import_kwh = import_kwh;
            }
            else
            {
                float step = import_kwh - s.last_import_kwh;
                if (step > 0 && step < max_step_kwh)
                    s.delivered_kwh += step;
                s.last_import_kwh = import_kwh;
            }

            float soc_floor = float.nan;
            float capacity = capacity_kwh(a);
            if (capacity == capacity && capacity > 0)
            {
                soc_floor = s.delivered_kwh * charge_efficiency / capacity * 100;
                if (soc_floor > 100)
                    soc_floor = 100;
            }
            publish(a, s.delivered_kwh, soc_floor);
        }
    }

private:
    struct Session
    {
        bool active;
        float last_import_kwh = float.nan;
        float delivered_kwh = 0;
        MonoTime nan_since;
    }

    Map!(String, Session) sessions;

    // The delivering counter is on the EVSE's grid-side port.
    float delivering_import_kwh(ref TopologyGraph graph, Appliance car)
    {
        Port* car_port;
        foreach (p; graph.ports[])
        {
            if (p.owner is car && p.bus !is null)
            {
                car_port = p;
                break;
            }
        }
        if (car_port is null || car_port.bus is null)
            return float.nan;

        foreach (p; car_port.bus.ports[])
        {
            if (p.owner is null || p.owner is car || p.role != PortRole.car)
                continue;
            foreach (p2; graph.ports[])
            {
                if (p2.owner is p.owner && p2 !is p && p2.bus !is null &&
                    p2.meter_data.has(MeterField.total_import_active))
                    return p2.meter_data.total_import_active[0];
            }
        }
        return float.nan;
    }

    float capacity_kwh(Appliance car)
    {
        if (Component v = vehicle_for(car.vin))
        {
            if (Element* e = v.find_element("battery.full_capacity"))
            {
                if (e.value.isNumber)
                {
                    float kwh = read_in_unit(e, KilowattHour);
                    if (kwh == kwh && kwh > 0)
                        return kwh;
                }
            }
        }
        return car.capacity;
    }

    void publish(Appliance car, float delivered_kwh, float soc_floor)
    {
        Component v = vehicle_for(car.vin);
        if (v is null)
            return;
        v.set_element("battery.session_delivered", delivered_kwh);
        // Bare 0..100 values are ratios, so synthetic SOC must retain Percent.
        v.set_element("battery.soc_floor", Quantity!(double, Percent)(soc_floor));
    }
}
