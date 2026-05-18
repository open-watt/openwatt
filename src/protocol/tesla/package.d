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
import protocol.tesla.sampler;

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
        register_address_extractor(PacketType.tesla_twc, &extract_twc_src_address, &extract_twc_dst_address);

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_command!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.register_command!twc_set("/protocol/tesla/twc", this, "set");
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

}

ulong extract_twc_src_address(ref const Packet p) pure
{
    ulong addr = p.hdr!TWCFrame().src;
    addr |= ulong(addr == 0xFFFF) << 63; // is FFFF the broadcast, or 0000?
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.tesla_twc) << 60;
    return addr;
}

ulong extract_twc_dst_address(ref const Packet p) pure
{
    ulong addr = p.hdr!TWCFrame().dst;
    addr |= ulong(addr == 0xFFFF) << 63; // is FFFF the broadcast, or 0000?
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.tesla_twc) << 60;
    return addr;
}
