module protocol.tesla;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.session;
import manager.plugin;

import protocol.tesla.iface;
import protocol.tesla.master;
import protocol.tesla.binding;
import protocol.tesla.twc;
import protocol.tesla.vehicle;

import router.iface;

nothrow @nogc:


class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    Map!(const(char)[], TeslaTWCMaster) twc_masters;

    override void init()
    {
        register_packet_codec!TWCFrame();
        g_app.register_enum!(TeslaTWCMaster.ChargerState)();
        g_app.register_enum!TWCState();

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_collection!TeslaVehicleScanner();
        g_app.console.register_collection!TeslaVehicleSession();
        g_app.console.register_command!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.register_command!twc_set("/protocol/tesla/twc", this, "set");
        g_app.console.register_command!vehicle_get_charge("/protocol/tesla/session", this, "get-charge");
        g_app.console.register_command!vehicle_get_climate("/protocol/tesla/session", this, "get-climate");
        g_app.console.register_command!vehicle_charge_start("/protocol/tesla/session", this, "charge-start");
        g_app.console.register_command!vehicle_charge_stop("/protocol/tesla/session", this, "charge-stop");
        g_app.console.register_command!vehicle_set_amps("/protocol/tesla/session", this, "set-amps");
        g_app.console.register_command!vehicle_climate("/protocol/tesla/session", this, "climate");
        g_app.console.register_command!vehicle_set_temperature("/protocol/tesla/session", this, "set-temperature");
        g_app.console.register_command!vehicle_schedule_charging("/protocol/tesla/session", this, "schedule-charging");
    }

    override void update()
    {
        // TeslaInterface update handled by base interface collection
        foreach(m; twc_masters.values)
            m.update();

        // Vehicle sessions are spawned at runtime (not via console `add`), so
        // they never get the synchronous do_update() kick, so tick them here to
        // drive their connect, session-info, ready state machine. The scanner
        // is ticked too for its housekeeping update() (out-of-range teardown).
        Collection!TeslaVehicleScanner().update_all();
        Collection!TeslaVehicleSession().update_all();
    }

    void twc_add(Session session, const(char)[] name, const(char)[] _interface, ushort id, float max_current)
    {
        BaseInterface i = Collection!BaseInterface().get(_interface);
        if(i is null)
        {
            session.write_line("Interface '", _interface, "' not found");
            return;
        }

        TeslaTWCMaster master;
        foreach (m; twc_masters.values)
        {
            if (m.iface is i)
            {
                master = m;
                break;
            }
        }
        if (!master)
        {
            String n = tconcat(_interface, "_twc").makeString(defaultAllocator());

            master = defaultAllocator().allocT!TeslaTWCMaster(this, n.move, i);
            twc_masters[master.name[]] = master;
        }

        String n = name.makeString(defaultAllocator());

        master.add_charger(n.move, id, cast(ushort)(max_current * 100));
    }

    void twc_set(Session session, const(char)[] name, float target_current)
    {
        foreach (m; twc_masters.values)
        {
            if (m.set_target_current(name, cast(ushort)(target_current * 100)) >= 0)
                return;
        }
    }

    void vehicle_get_charge(Session session, TeslaVehicleSession vehicle)
    {
        if (!vehicle.is_ready)
        {
            session.write_line("session '", vehicle.name[], "' not ready (state: ", vehicle.session_state, ")");
            return;
        }
        if (!vehicle.refresh_charge_state())
        {
            session.write_line("failed to send charge state request");
            return;
        }
        // Show what we already have cached; the new response will arrive async.
        ref const cs = vehicle.charge_state;
        if (!cs.valid)
        {
            session.write_line("request sent - no cached state yet, response pending");
            return;
        }
        if (cs.has_battery_level)
            session.writef("battery_level: {0}%\n", cs.battery_level);
        if (cs.has_usable_battery_level)
            session.writef("usable: {0}%\n", cs.usable_battery_level);
        if (cs.has_charging_state)
            session.writef("charging_state: {0}\n", cs.charging_state);
        if (cs.has_charging_amps)
            session.writef("charging_amps: {0}\n", cs.charging_amps);
        if (cs.has_charger_voltage)
            session.writef("charger_voltage: {0}V\n", cs.charger_voltage);
        if (cs.has_charger_actual_current)
            session.writef("charger_actual_current: {0}A\n", cs.charger_actual_current);
        if (cs.has_charger_power)
            session.writef("charger_power: {0}kW\n", cs.charger_power);
        if (cs.has_charge_energy_added)
            session.writef("charge_energy_added: {0}kWh\n", cs.charge_energy_added);
        if (cs.has_charge_current_request_max)
            session.writef("max_current: {0}A\n", cs.charge_current_request_max);
        if (cs.has_minutes_to_full_charge)
            session.writef("minutes_to_full: {0}\n", cs.minutes_to_full_charge);
        session.write_line("(refresh requested - values above are last cached)");
    }

    void vehicle_charge_start(Session session, TeslaVehicleSession vehicle)
    {
        if (!vehicle.charging_start())
            session.write_line("failed to send charging_start");
        else
            session.write_line("charging_start sent");
    }

    void vehicle_charge_stop(Session session, TeslaVehicleSession vehicle)
    {
        if (!vehicle.charging_stop())
            session.write_line("failed to send charging_stop");
        else
            session.write_line("charging_stop sent");
    }

    void vehicle_set_amps(Session session, TeslaVehicleSession vehicle, int amps)
    {
        if (!vehicle.set_charging_amps(amps))
            session.write_line("failed to send set_charging_amps");
        else
            session.writef("set_charging_amps({0}A) sent\n", amps);
    }

    void vehicle_get_climate(Session session, TeslaVehicleSession vehicle)
    {
        if (!vehicle.refresh_climate_state())
        {
            session.write_line("failed to send climate state request");
            return;
        }
        ref const climate = vehicle.climate_state;
        if (!climate.valid)
        {
            session.write_line("request sent - no cached climate state yet, response pending");
            return;
        }
        if (climate.has_inside_temperature)
            session.writef("inside_temperature: {0}C\n", climate.inside_temperature);
        if (climate.has_outside_temperature)
            session.writef("outside_temperature: {0}C\n", climate.outside_temperature);
        if (climate.has_driver_temperature)
            session.writef("driver_temperature: {0}C\n", climate.driver_temperature);
        if (climate.has_passenger_temperature)
            session.writef("passenger_temperature: {0}C\n", climate.passenger_temperature);
        if (climate.has_fan_speed)
            session.writef("fan_speed: {0}\n", climate.fan_speed);
        if (climate.has_climate_on)
            session.writef("climate_on: {0}\n", climate.climate_on);
        if (climate.has_preconditioning)
            session.writef("preconditioning: {0}\n", climate.preconditioning);
        session.write_line("(refresh requested - values above are last cached)");
    }

    void vehicle_climate(Session session, TeslaVehicleSession vehicle, bool enabled)
    {
        if (!vehicle.climate_power(enabled))
            session.write_line("failed to send climate command");
        else
            session.write_line(enabled ? "climate on sent" : "climate off sent");
    }

    void vehicle_set_temperature(Session session, TeslaVehicleSession vehicle, float celsius)
    {
        if (!vehicle.climate_temperature(celsius))
            session.write_line("failed to send climate temperature");
        else
            session.writef("climate temperature {0}C sent\n", celsius);
    }

    void vehicle_schedule_charging(Session session, TeslaVehicleSession vehicle,
                                   bool enabled, Nullable!TimeOfDay start)
    {
        if (enabled && !start)
        {
            session.write_line("start is required when enabling the charging schedule");
            return;
        }
        TimeOfDay start_time = start ? start.value : TimeOfDay.init;
        if (!vehicle.schedule_charging(enabled, start_time))
            session.write_line("failed to send charging schedule");
        else if (enabled)
            session.writef("daily charging schedule for {0} sent\n", start_time);
        else
            session.write_line("charging schedule disable sent");
    }

}
