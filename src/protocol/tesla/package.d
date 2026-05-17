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
import protocol.tesla.vehicle;

import router.iface;
import router.iface.mac;

nothrow @nogc:


struct DeviceMap
{
    String name;
    MACAddress mac;
    ushort address;
    TeslaInterface iface;
}

class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    Map!(const(char)[], TeslaTWCMaster) twc_masters;
    Map!(ushort, DeviceMap) devices;

    override void init()
    {
        register_address_extractor(PacketType.tesla_twc, &extract_twc_src_address, &extract_twc_dst_address, &is_twc_broadcast);

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_collection!TeslaVehicleScanner();
        g_app.console.register_collection!TeslaVehicleSession();
        g_app.console.register_command!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.register_command!twc_set("/protocol/tesla/twc", this, "set");
        g_app.console.register_command!vehicle_get_charge("/protocol/tesla/session", this, "get-charge");
        g_app.console.register_command!vehicle_charge_start("/protocol/tesla/session", this, "charge-start");
        g_app.console.register_command!vehicle_charge_stop("/protocol/tesla/session", this, "charge-stop");
        g_app.console.register_command!vehicle_set_amps("/protocol/tesla/session", this, "set-amps");
    }

    override void update()
    {
        // TeslaInterface update handled by base interface collection
        foreach(m; twc_masters.values)
            m.update();
    }

        DeviceMap* find_server_by_name(const(char)[] name)
    {
        foreach (ref map; devices.values)
        {
            if (map.name[] == name[])
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_mac(MACAddress mac)
    {
        foreach (ref map; devices.values)
        {
            if (map.mac == mac)
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_address(ushort address)
    {
        return address in devices;
    }

    DeviceMap* add_device(const(char)[] name, TeslaInterface iface, ushort address)
    {
        if (!name)
            name = tformat("{0}.{1,04X}", iface.name[], address);

        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.generate_mac_address();
        map.mac.b[4] = address >> 8;
        map.mac.b[5] = address & 0xFF;
//        while (find_mac_address(map.mac) !is null)
//            ++map.mac.b[5];
        map.iface = iface;

        iface.add_address(map.mac, iface);
        return devices.insert(address, map);
    }

    DeviceMap* add_server(const(char)[] name, BaseInterface iface, ushort address)
    {
        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.mac;
//        map.iface = iface;
        return devices.insert(address, map);
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
            session.write_line("request sent — no cached state yet, response pending");
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
        session.write_line("(refresh requested — values above are last cached)");
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

}

ulong extract_twc_src_address(ref const Packet p) pure
{
    ulong addr = p.hdr!TWCFrame().src;
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.tesla_twc) << 60;
    return addr;
}

ulong extract_twc_dst_address(ref const Packet p) pure
{
    ulong addr = p.hdr!TWCFrame().dst;
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.tesla_twc) << 60;
    return addr;
}

bool is_twc_broadcast(ulong address) pure
    => (address & 0xFFFF) == 0xFFFF;
