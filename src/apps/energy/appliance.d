module apps.energy.appliance;

import urt.array;
import urt.lifetime;
import urt.si.quantity;
import urt.string;
import urt.util;

import apps.energy.circuit;
import apps.energy.manager;
import apps.energy.meter;

import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


enum ControlCapability
{
    None = 0,           // no control capability
    Implicit = 1 << 0,  // will adapt to other appliances
    OnOff = 1 << 1,     // can enable/disable operation
    Linear = 1 << 2,    // can specify target power consumption
    Reverse = 1 << 3,   // can reverse flow to supply energy
}


extern(C++)
class Appliance
{
extern(D):
nothrow @nogc:

    String id;
    string type;
    String name;

    EnergyManager* manager;

    Component info;
    Component config;

    Circuit* circuit;
    Component meter;

    MeterData meter_data;

    bool enabled;
    Watts target_power = Watts(0);

    // HACK: distribute power according to priority...
    int priority;

    this(String id, string type, EnergyManager* manager)
    {
        this.id = id.move;
        this.type = type;
        this.manager = manager;
    }

    void init(Device device) // TODO: rest of cmdline args...
    {
        if (device)
            config = device.get_first_component_by_template("Configuration");
    }

    T as(T)() pure
        if (is(T : Appliance))
    {
        if (type[] == T.Type[])
            return cast(T)this;
        return null;
    }

    // get the power currently being consumed by the appliance
    Watts currentConsumption() const
        => meter_data.active[0] > Watts(0) ? cast(Watts)meter_data.active[0] : Watts(0);

    // returns true if the appliance can be controlled
    bool canControl() const
        => hasControl() != ControlCapability.None;

    // returns the control capabilities of the appliance
    ControlCapability hasControl() const
        => ControlCapability.None;

    // enable/disable the appliance
    void enable(bool on)
    {
        enabled = on;
    }

    // specifies power that the appliance wants to consume
    Watts wantsPower() const
        => Watts(0);

    // offset power to the appliance, returns the amount accepted
    Watts offerPower(Watts watts)
    {
        Watts min, max;
        if (minPowerLimit(min) && watts < min)
            target_power = min;
        else if (maxPowerLimit(max) && watts > max)
            target_power = max;
        else
            target_power = watts;
        return target_power;
    }

    // specifies the minimum power that the appliance can accept
    bool minPowerLimit(out Watts limit) const
        => false;

    // specifies the maximum power that the appliance can accept
    bool maxPowerLimit(out Watts limit) const
        => false;

    void update()
    {
    }
}

class Inverter : Appliance
{
nothrow @nogc:
    enum Type = "inverter";

    Component control;
    Component backup; // meter for the backup circuit, if available...
    Array!(Component) mppt; // solar arrays
    Array!(Component) battery; // batteries

    Component dummyMeter; // this can be used to control the charge/discharge functionality

    Watts ratedPower = Watts(0);

    this(String id, EnergyManager* manager)
    {
        super(id.move, Type, manager);
    }

    final override ControlCapability hasControl() const
    {
        // we need to drill into these components, and see what controls they actually offer...
        if (control || dummyMeter)
            return ControlCapability.OnOff | ControlCapability.Linear | ControlCapability.Reverse;

        // if there are no controls but it's a battery inverter, then it should have implicit control
        if (mppt.length && mppt[0].template_ == "Battery")
            return ControlCapability.Implicit | ControlCapability.Reverse;

        return ControlCapability.Reverse;
    }

    final override Watts wantsPower() const
    {
        // if SOC < 100%, then we want to charge the battery

        // TODO: it would be REALLY great to attenuate the power request based on
        //       the amount of sunlight hours remaining in the day...
        //       we should aim to fill the battery by sun-down, while also not charging faster than necessary

//        return 0;
        // HACK:
        return ratedPower ? ratedPower : Watts(5000); // we should work out how much the battery actually wants!
    }

    final override void update()
    {
        if (info)
        {
            if (Element* rp = info.find_element("ratedPower"))
            {
                if (rp)
                    ratedPower = rp.value.asQuantity;
            }
        }

        if (control)
        {
            // specify control parameters...
        }
        else if (dummyMeter)
        {
            // specify the meter values to influence the inverter...
        }
        else
        {
            // nothing?
        }
    }
}

class EVSE : Appliance
{
nothrow @nogc:
    enum Type = "evse";

    Component control;

    Car connectedCar;

    this(String id, EnergyManager* manager)
    {
        super(id.move, Type, manager);
    }

    final override void init(Device device) // TODO: rest of cmdline args...
    {
        super.init(device);

    }

    final override ControlCapability hasControl() const
    {
        if (control && control.find_element("target_current"))
            return ControlCapability.Linear;
        // on/off control?

        // TODO: maybe we can control the car directly?
        //       which should we prefer?

        return ControlCapability.None;
    }

    final override Watts wantsPower() const
    {
        Watts wants = 0;
        if (connectedCar)
            maxPowerLimit(wants);
        return wants;
    }

    final override bool minPowerLimit(out Watts watts) const
    {
        watts = meter_data.voltage[0] ? cast(Volts)meter_data.voltage[0] * Amps(6) : Volts(230) * Amps(6);
        return true;
    }
    final override bool maxPowerLimit(out Watts watts) const
    {
        watts = meter_data.voltage[0] ? cast(Volts)meter_data.voltage[0] * Amps(32) : Volts(240) * Amps(32);
        return true;
    }

    final override void update()
    {
        if (!info)
            return;

        // check the charger for a connected VIN
        if (Element* e = info.find_element("vin"))
        {
            if (connectedCar)
                connectedCar.evse = null;
            connectedCar = null;

            const(char)[] vin = e.value.asString();
            if (vin.length > 0)
            {
                // find a car with this VIN among our appliances...
                foreach (a; manager.appliances.values)
                {
                    if (a.type != "car")
                        continue;
                    Car car = cast(Car)a;

                    if (car.vin[] != vin[])
                        continue;

                    connectedCar = car;
                    car.evse = this;
                    break;
                }
            }
        }

        Watts target = target_power;
        if (connectedCar)
        {
            if (connectedCar.target_power > Watts(0))
                target = max(target_power, connectedCar.target_power);
        }
        Amps target_current = target / (meter_data.voltage[0] ? cast(Volts)meter_data.voltage[0] : Volts(230));
        if (target_current > Amps(0))
        {
            // set the

            if (control)
            {
                Element* e = control.find_element("target_current");
                if (e)
                    e.value = target_current;
            }

        }
    }
}

class Car : Appliance
{
nothrow @nogc:
    enum Type = "car";

    String vin;
    Component battery;
    Component control;

    EVSE evse;

    this(String id, EnergyManager* manager)
    {
        super(id.move, Type, manager);
    }

    final override ControlCapability hasControl() const
    {
        if (evse)
            return evse.hasControl();

        // some cars can be controlled directly...
        // tesla API?

        return ControlCapability.None;
    }

    final override Watts currentConsumption() const
    {
        if (evse)
            return evse.currentConsumption();
        return Watts(0);
    }

    final override Watts wantsPower() const
    {
        // if it actually wants to charge...

        Watts wants = Watts(0);
        if (evse)
            maxPowerLimit(wants);
        return wants;
    }

    final override bool minPowerLimit(out Watts watts) const
    {
        watts = meter_data.voltage[0] ? cast(Volts)meter_data.voltage[0] * Amps(6) : Volts(230) * Amps(6);
        return true;
    }
    final override bool maxPowerLimit(out Watts watts) const
    {
        watts = meter_data.voltage[0] ? cast(Volts)meter_data.voltage[0] * Amps(32) : Volts(240) * Amps(32);
        return true;
    }

    final override void update()
    {

        if (control)
        {
            // specify control parameters...
        }
    }
}

class AirCon : Appliance
{
nothrow @nogc:
    enum Type = "ac";

    Component control;

    this(String id, EnergyManager* manager)
    {
        super(id.move, Type, manager);
    }

    final override void update()
    {

        if (control)
        {
            // specify control parameters...
        }
    }
}

class WaterHeater : Appliance
{
nothrow @nogc:
    enum Type = "water_heater";

    Component control;

    this(String id, EnergyManager* manager)
    {
        super(id.move, Type, manager);
    }

    final override Watts wantsPower() const
    {
        // we need to check the thermostat to see if temp < target
        //...

        // in the meantime, we probably just offer power any time we have unused excess...

        return Watts(0);
    }

    final override void update()
    {

        // this thing really needs to respond to the thermostat...
        if (control)
        {
            // specify control parameters...
        }
    }
}
