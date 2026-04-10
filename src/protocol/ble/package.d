module protocol.ble;

import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.util;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;
import protocol.ble.sampler;
public static import protocol.ble.winrt;

nothrow @nogc:

alias log = Log!"ble";


class BLEModule : Module
{
    mixin DeclareModule!"protocol.ble";
nothrow @nogc:

    Map!(MACAddress, BLEAdvEntry*) devices;

    override void init()
    {
        g_app.console.register_collection!BLEInterface("/interface/ble");
        g_app.console.register_collection!BLEClient("/protocol/ble/client");
        g_app.console.register_command!device_add("/protocol/ble/device", this, "add");
        g_app.console.register_command!print_devices("/protocol/ble/device", this, "print");
        g_app.console.register_command!cmd_read("/protocol/ble/client", this, "read");
    }

    override void update()
    {
        Collection!BLEClient().update_all();
        expire_devices();
    }

    // called from BLEInterface.on_incoming when an advert packet is dispatched
    void on_advert(MACAddress addr, short rssi, bool connectable, bool is_scan_response, const(ubyte)[] payload)
    {
        MonoTime now = getTime();

        BLEAdvEntry** pp = addr in devices;
        BLEAdvEntry* dev = pp ? *pp : null;

        bool is_new = dev is null;
        if (is_new)
        {
            dev = defaultAllocator().allocT!BLEAdvEntry;
            dev.addr = addr;
            devices[addr] = dev;
        }

        bool had_name = !dev.name.empty;
        dev.rssi = rssi;
        dev.last_seen = now;
        if (connectable)
            dev.connectable = true;

        // always parse — ADV_IND and SCAN_RSP carry different data
        dev.parse_ad_payload(payload);

        if (is_new)
        {
            if (!dev.name.empty)
                log.debug_("discovered ", addr, " '", dev.name[], "'");
            else if (dev.has_company)
                log.debugf("discovered {0} mfr:{1,04x}", addr, dev.company_id);
            else
                log.debug_("discovered ", addr);
        }
        else if (!had_name && !dev.name.empty)
            log.debug_("identified ", addr, " as '", dev.name[], "'");
    }

    import manager.console.session : Session;
    import manager.profile;

    void device_add(Session session, const(char)[] id, BLEClient client, Nullable!(const(char)[]) name, Nullable!(const(char)[]) _profile, Nullable!(const(char)[]) model)
    {
        import manager.device;
        import manager.element;
        import manager.sampler;
        import urt.file;
        import urt.mem.allocator;
        import urt.string.format;

        if (!_profile)
        {
            session.write_line("No profile specified");
            return;
        }
        const(char)[] profile_name = _profile.value;

        void[] file = load_file(tconcat("conf/ble_profiles/", profile_name, ".conf"), g_app.allocator);
        if (!file)
        {
            session.write_line("Failed to load profile '", profile_name, "'");
            return;
        }
        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);

        auto ble_iface = cast(BLEInterface)client.iface;
        if (ble_iface is null)
        {
            session.write_line("Client has no BLE interface");
            return;
        }

        BLESampler sampler = g_app.allocator.allocT!BLESampler(ble_iface, client);

        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            assert(desc.type == ElementType.ble);
            ref const ElementDesc_BLE ble = profile.get_ble(desc.element);

            ubyte[256] tmp = void;
            tmp[0 .. ble.value_desc.data_length] = 0;
            e.value = sample_value(tmp.ptr, ble.value_desc);

            sampler.add_element(e, desc, ble);
            device.sample_elements ~= e;
        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            return;
        }
        device.samplers ~= sampler;
    }

    void cmd_read(Session session, BLEClient client, ushort handle)
    {
        if (!client.running)
        {
            session.write_line("client not connected");
            return;
        }
        client.read_characteristic(handle);
        session.write_line("read submitted");
    }

    void print_devices(Session session)
    {
        if (devices.length == 0)
        {
            session.write_line("No BLE devices discovered");
            return;
        }

        session.writef("{0} devices\n\n", devices.length);

        size_t name_len = 4;
        foreach (dev; devices.values)
            name_len = max(name_len, dev.name.length);

        session.writef(" {0, -17}  {1, 5}  {2, -*3}  {4}\n", "ADDRESS", "RSSI", "NAME", name_len, "INFO");

        foreach (dev; devices.values)
        {
            session.writef(" {0}  {1, 5}  {2, -*3} ", dev.addr, dev.rssi, dev.name[], name_len);

            if (dev.connectable)
                session.write(" conn");
            if (dev.has_company)
                session.writef(" mfr:{0,04x}", dev.company_id);
            foreach (svc; dev.service_uuids_16[])
                session.writef(" svc:{0,04x}", svc);

            session.write_line("");
        }
    }

private:

    void expire_devices()
    {
        MonoTime now = getTime();
        // can't remove during iteration, collect keys first
        MACAddress[32] expired = void;
        uint num_expired;

        foreach (dev; devices.values)
        {
            if (now - dev.last_seen > ble_advert_ttl.seconds)
            {
                if (num_expired < expired.length)
                    expired[num_expired++] = dev.addr;
            }
        }

        foreach (i; 0 .. num_expired)
        {
            if (auto pp = expired[i] in devices)
            {
                auto dev = *pp;
                if (!dev.name.empty)
                    log.debug_("lost ", expired[i], " '", dev.name[], "'");
                else
                    log.debug_("lost ", expired[i]);
                defaultAllocator().freeT(dev);
            }
            devices.remove(expired[i]);
        }
    }
}
