module protocol.tesla;

import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console.command;
import manager.console.session;
import manager.plugin;

import protocol.tesla.iface;
import protocol.tesla.master;
import protocol.tesla.binding;
import protocol.tesla.twc;
import protocol.tesla.vehicle_codec;
import protocol.tesla.vehicle_crypto;
import protocol.tesla.vehicle_scanner;
import protocol.tesla.vehicle_session;

import router.iface;

nothrow @nogc:


class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!TWCFrame();
        g_app.register_enum!(TeslaTWCMaster.ChargerState)();
        g_app.register_enum!TWCState();
        g_app.register_enum!TeslaSteeringWheelHeatLevel();

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCMaster();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_collection!TeslaVehicleScanner();
        g_app.console.register_collection!TeslaVehicleSession();

        version (Tiny) {}
        else
        {
            g_app.console.register_command!(vehicle_get_charge, "get-charge")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_get_climate, "get-climate")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_charge_start, "charge-start")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_charge_stop, "charge-stop")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_set_amps, "set-amps")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_climate, "climate")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_set_temperature, "set-temperature")("/protocol/tesla/session", this);
        }
        g_app.console.register_command!(vehicle_schedule_charging, "schedule-charging")("/protocol/tesla/session", this);
        g_app.console.register_command!(vehicle_enrol, "enrol")("/protocol/tesla/session", this);
        g_app.console.register_command!(vehicle_backoff, "backoff")("/protocol/tesla/vehicle-scanner", this);
        g_app.console.register_command!(vehicle_reset_backoff, "reset-backoff")("/protocol/tesla/vehicle-scanner", this);
    }

    override void update()
    {
        Collection!TeslaTWCMaster().update_all();

        Collection!TeslaVehicleScanner().update_all();
        Collection!TeslaVehicleSession().update_all();
    }

    void vehicle_backoff(Session session, TeslaVehicleScanner scanner, const(char)[] vin)
    {
        const(VehicleRetryState)* retry = scanner.retry_state(vin);
        if (!retry)
            session.write_line("VIN is not registered with this scanner");
        else
            session.write_line(retry.status.length ? retry.status[] : "No vehicle back-off");
    }

    void vehicle_reset_backoff(Session session, TeslaVehicleScanner scanner, const(char)[] vin)
    {
        if (scanner.reset_backoff(vin))
            session.write_line("Vehicle back-off cleared; reconnecting when the vehicle is available. Controls are not replayed.");
        else
            session.write_line("VIN is not registered with this scanner");
    }

    version (Tiny) {} else
    {
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
        ref const cs = vehicle.charge_state;
        if (!vehicle.has_charge_state)
        {
            session.write_line("request sent - no cached state yet, response pending");
            return;
        }
        if (cs.battery_level.present)
            session.writef("battery_level: {0}%\n", cs.battery_level.value);
        if (cs.usable_battery_level.present)
            session.writef("usable: {0}%\n", cs.usable_battery_level.value);
        if (cs.charging_state.present)
            session.writef("charging_state: {0}\n", charging_state_kind(cs.charging_state.value));
        if (cs.charging_amps.present)
            session.writef("charging_amps: {0}\n", cs.charging_amps.value);
        if (cs.charger_voltage.present)
            session.writef("charger_voltage: {0}V\n", cs.charger_voltage.value);
        if (cs.charger_actual_current.present)
            session.writef("charger_actual_current: {0}A\n", cs.charger_actual_current.value);
        if (cs.charger_power.present)
            session.writef("charger_power: {0}kW\n", cs.charger_power.value);
        if (cs.charge_energy_added.present)
            session.writef("charge_energy_added: {0}kWh\n", cs.charge_energy_added.value);
        if (cs.charge_current_request_max.present)
            session.writef("max_current: {0}A\n", cs.charge_current_request_max.value);
        if (cs.minutes_to_full_charge.present)
            session.writef("minutes_to_full: {0}\n", cs.minutes_to_full_charge.value);
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
        if (!vehicle.has_climate_state)
        {
            session.write_line("request sent - no cached climate state yet, response pending");
            return;
        }
        if (climate.inside_temperature.present)
            session.writef("inside_temperature: {0}C\n", climate.inside_temperature.value);
        if (climate.outside_temperature.present)
            session.writef("outside_temperature: {0}C\n", climate.outside_temperature.value);
        if (climate.driver_temperature.present)
            session.writef("driver_temperature: {0}C\n", climate.driver_temperature.value);
        if (climate.passenger_temperature.present)
            session.writef("passenger_temperature: {0}C\n", climate.passenger_temperature.value);
        if (climate.fan_speed.present)
            session.writef("fan_speed: {0}\n", climate.fan_speed.value);
        if (climate.climate_on.present)
            session.writef("climate_on: {0}\n", climate.climate_on.value);
        if (climate.preconditioning.present)
            session.writef("preconditioning: {0}\n", climate.preconditioning.value);
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

    }

    void vehicle_schedule_charging(Session session, TeslaVehicleSession vehicle, bool enabled, Nullable!TimeOfDay start)
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

    CommandState vehicle_enrol(Session session, TeslaVehicleSession vehicle, Nullable!TeslaKeyRole role)
    {
        TeslaEnrolCommandState state = alloc!TeslaEnrolCommandState(session, vehicle);
        const(char)[] refused = vehicle.request_enrolment(role ? role.value : TeslaKeyRole.owner, &state.on_result);
        if (refused)
        {
            session.write_line(refused);
            free(state);
            return null;
        }
        session.write_line("enrolment requested; tap an enrolled key card on the console reader");
        return state;
    }

}

// The vehicle answers a refusal at once, but only ever proves success by admitting us to a session.
private class TeslaEnrolCommandState : CommandState
{
nothrow @nogc:

    // The session gives up first; this only bounds a session that stops answering altogether.
    enum Duration answer_timeout = 90.seconds;

    this(Session session, TeslaVehicleSession vehicle)
    {
        super(session);
        _vehicle = vehicle;
        _deadline = getTime() + answer_timeout;
    }

    void on_result(TeslaEnrolResult outcome, uint information)
    {
        if (_completion != CommandCompletionState.in_progress)
            return;

        final switch (outcome)
        {
            case TeslaEnrolResult.waiting:
                return;
            case TeslaEnrolResult.enrolled:
                result = Variant(StringLit!"key enrolled");
                _completion = CommandCompletionState.finished;
                return;
            case TeslaEnrolResult.rejected:
                const(char)[] reason = whitelist_information_reason(information);
                result = reason ? Variant(MutableString!0(Concat, reason))
                                : Variant(MutableString!0(Concat, "vehicle refused enrolment, information ", information));
                _completion = CommandCompletionState.error;
                return;
            case TeslaEnrolResult.abandoned:
                result = Variant(StringLit!"vehicle abandoned the enrolment");
                _completion = CommandCompletionState.error;
                return;
        }
    }

    override CommandCompletionState update()
    {
        if (_completion != CommandCompletionState.in_progress)
            return finish(_completion);
        if (getTime() >= _deadline)
        {
            result = Variant(StringLit!"no answer from the vehicle");
            return finish(CommandCompletionState.timeout);
        }
        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        if (_completion == CommandCompletionState.in_progress)
            _completion = CommandCompletionState.cancelled;
    }

private:
    ObjectRef!TeslaVehicleSession _vehicle;
    MonoTime _deadline;
    CommandCompletionState _completion;

    CommandCompletionState finish(CommandCompletionState state)
    {
        if (_vehicle)
            _vehicle.cancel_enrolment(&on_result);
        return state;
    }
}
