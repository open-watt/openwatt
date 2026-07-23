module apps.energy.session;

import urt.map;
import urt.mem : defaultAllocator;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.meter : MeterField;
import apps.energy.topology;
import apps.energy.vehicle : vehicle_for;

import manager.collection;
import manager.component;
import manager.element;

nothrow @nogc:


// Tracks energy delivered to each VIN-identified car while it is paired with an
// EVSE, and publishes a pessimistic SOC lower bound as the policy witness for
// soc(N) goals when the car can't report real SOC.
//
// Delivered energy is an incremental accumulation of the delivering EVSE's
// import counter (device-persistent, so charging while we're down still counts
// within a session), not our own power integration. The estimate seeds at zero
// on plug-in and dies on unplug: "assume the battery may be near-empty and
// count what we've delivered since".
struct ChargeSessionTracker
{
nothrow @nogc:

    // AC-side energy overstates what lands in the pack; scale down so soc_floor
    // stays a true lower bound
    enum float charge_efficiency = 0.88;

    // a counter step larger than this in one tick is a glitch/reset, not charge
    enum float max_step_kwh = 50;

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
                // not paired with a metered EVSE; any running session is over
                if (s && s.active)
                {
                    s.active = false;
                    publish(a, float.nan, float.nan);
                }
                continue;
            }

            if (s is null)
            {
                sessions[a.vin.makeString(defaultAllocator())] = Session.init;
                s = a.vin in sessions;
            }

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
    }

    Map!(String, Session) sessions;

    // The car's bus is its VIN circuit; an EVSE that read the same VIN joins it
    // with a car-role port. The delivering energy counter is on the EVSE's other
    // (grid-side) port.
    float delivering_import_kwh(ref TopologyGraph graph, Appliance car)
    {
        Port* car_port;
        foreach (p; graph.ports[])
        {
            if (p.owner is car)
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
                if (p2.owner is p.owner && p2 !is p && p2.meter_data.has(MeterField.total_import_active))
                    return p2.meter_data.total_import_active[0];
            }
        }
        return float.nan;
    }

    float capacity_kwh(Appliance car)
    {
        // empirical estimate (fed by real SOC sessions) wins over configured capacity
        if (Component v = vehicle_for(car.vin))
        {
            if (Element* e = v.find_element("battery.full_capacity"))
            {
                if (e.value.isNumber)
                {
                    float kwh = e.value.asFloat;
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
        v.find_or_create_element("battery.session_delivered").value = delivered_kwh;
        v.find_or_create_element("battery.soc_floor").value = soc_floor;
    }
}
