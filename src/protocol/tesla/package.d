module protocol.tesla;

import urt.array;
import urt.encoding : HexDecode;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.result;
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

    Map!(const(char)[], TeslaTWCMaster) twc_masters;

    override void init()
    {
        register_packet_codec!TWCFrame();
        g_app.register_enum!(TeslaTWCMaster.ChargerState)();
        g_app.register_enum!TWCState();
        g_app.register_enum!TeslaSteeringWheelHeatLevel();

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_collection!TeslaVehicleScanner();
        g_app.console.register_collection!TeslaVehicleSession();

        g_app.console.register_command!(twc_add, "add")("/protocol/tesla/twc", this);
        g_app.console.register_command!(twc_set, "set")("/protocol/tesla/twc", this);
        version (Tiny) {}
        else
        {
            g_app.console.register_command!(crypto_test, "crypto-test")("/protocol/tesla", this);
            g_app.console.register_command!(vehicle_get_charge, "get-charge")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_get_climate, "get-climate")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_charge_start, "charge-start")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_charge_stop, "charge-stop")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_set_amps, "set-amps")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_climate, "climate")("/protocol/tesla/session", this);
            g_app.console.register_command!(vehicle_set_temperature, "set-temperature")("/protocol/tesla/session", this);
        }
        g_app.console.register_command!(vehicle_schedule_charging, "schedule-charging")("/protocol/tesla/session", this);
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
            String n = tconcat(_interface, "_twc").make_string();

            master = alloc!TeslaTWCMaster(this, n.move, i);
            twc_masters[master.name[]] = master;
        }

        String n = name.make_string();

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

    version (Tiny) {} else
    {
    void crypto_test(Session session)
    {
        import urt.crypto.aes : aes_gcm_encrypt, aes_gcm_decrypt;
        import urt.digest.sha;

        static immutable ubyte[16] K = HexDecode!"1b2fce19967b79db696f909cff89ea9a";
        static immutable ubyte[16] epoch = HexDecode!"4c463f9cc0d3d26906e982ed224adde6";
        static immutable ubyte[6] plaintext = HexDecode!"120452020801";
        static immutable ubyte[12] nonce = HexDecode!"dbf79447fa156674dae1caed";
        static immutable ubyte[6] expect_ct = HexDecode!"38038e8c0f2e";
        static immutable ubyte[16] expect_tag = HexDecode!"8e128da165f162f4d7d2c8da866cf82a";

        Array!ubyte meta = build_signed_command_metadata(TeslaDomain.infotainment, "5YJ30123456789ABC", epoch[], 2655, 7, 0);
        SHA256Context sha;
        sha_init(sha);
        sha_update(sha, meta[]);
        ubyte[32] aad = sha_finalise(sha);

        ubyte[6] ct;
        ubyte[16] tag;
        Result enc = aes_gcm_encrypt(K[], nonce[], aad[], plaintext[], ct[], tag[]);
        session.writef("encrypt (stack): {0}  ct={1} tag={2}\n", enc.succeeded ? "ok" : "ERROR", cast(void[])ct[], cast(void[])tag[]);
        session.write_line("  vector: ", enc.succeeded && ct == expect_ct && tag == expect_tag ? "PASS" : "FAIL");

        Array!ubyte heap_ct;
        heap_ct.resize(plaintext.length);
        ubyte[16] heap_tag;
        Result enc2 = aes_gcm_encrypt(K[], nonce[], aad[], plaintext[], heap_ct[], heap_tag[]);
        session.write_line("encrypt (heap buffer): ", enc2.succeeded && heap_ct[] == expect_ct[] && heap_tag == expect_tag ? "PASS" : "FAIL");

        ubyte[6] back;
        Result dec = aes_gcm_decrypt(K[], nonce[], aad[], expect_ct[], expect_tag[], back[]);
        session.write_line("decrypt reference:      ", dec.succeeded && back == plaintext ? "PASS" : "FAIL");

        ubyte[16] empty_tag;
        Result enc3 = aes_gcm_encrypt(K[], nonce[], aad[], null, null, empty_tag[]);
        Result dec3 = aes_gcm_decrypt(K[], nonce[], aad[], null, empty_tag[], null);
        session.writef("empty payload round trip: {0} (enc {1}, dec {2})\n", enc3.succeeded && dec3.succeeded ? "PASS" : "FAIL", enc3.system_code, dec3.system_code);

        static immutable ubyte[16] zero_key;
        static immutable ubyte[12] zero_iv;
        static immutable ubyte[16] tc1_tag = HexDecode!"58e2fccefa7e3061367f1d57a4e7455a";
        ubyte[16] t;
        Result enc4 = aes_gcm_encrypt(zero_key[], zero_iv[], null, null, null, t[]);
        Result dec4 = aes_gcm_decrypt(zero_key[], zero_iv[], null, null, tc1_tag[], null);
        session.write_line("NIST GCM test case 1:     ", enc4.succeeded && t == tc1_tag ? "PASS" : "FAIL", " / decrypt ", dec4.succeeded ? "PASS" : "FAIL");
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
