module protocol.ble;

import urt.log;
import urt.map;
import urt.mem.allocator;
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
import protocol.ble.binding;

nothrow @nogc:


class BLEModule : Module
{
    mixin DeclareModule!"protocol.ble";
nothrow @nogc:

    alias log = Log!"ble";

    Map!(MACAddress, BLEAdvEntry*) devices;

    override void init()
    {
        register_frame_handler(PacketType.ble, &on_ble_frame);

        g_app.console.register_collection!BLEClient();
        g_app.console.register_collection!BLEClientBinding();
        g_app.console.register_command!print_devices("/protocol/ble/device", this, "print");
        g_app.console.register_command!cmd_read("/protocol/ble/client", this, "read");
    }

    override void update()
    {
        Collection!BLEClient().update_all();
        expire_devices();
    }

    void request_service()
    {
        import urt.atomic : cas;
        if (cas(&_service_pending, 0u, 1u))
            g_app.post_event(&service_radios, getTime(), EventPriority.bulk);
    }

    void on_ble_frame(ref Packet p, BaseInterface iface)
    {
        ref f = p.hdr!BLEFrame;

        if (f.kind == BLEFrameKind.advert)
        {
            switch (f.code)
            {
                case BLEAdvPDU.adv_ind:
                case BLEAdvPDU.adv_nonconn_ind:
                case BLEAdvPDU.adv_scan_ind:
                case BLEAdvPDU.adv_direct_ind:
                case BLEAdvPDU.scan_rsp:
                    on_advert(f.src, f.rssi,
                        f.code == BLEAdvPDU.adv_ind,
                        f.code == BLEAdvPDU.scan_rsp,
                        cast(const(ubyte)[])p.data);
                    break;
                default:
                    // connect_ind targets an advertisement source, not a client
                    break;
            }
            return;
        }

        foreach (c; Collection!BLEClient().values)
        {
            if (c.local_mac == f.dst)
            {
                c.incoming_frame(p, iface);
                return;
            }
        }
    }

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

        // always parse - ADV_IND and SCAN_RSP carry different data
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

    void cmd_read(Session session, BLEClient client, ushort handle)
    {
        if (!client.running)
        {
            session.write_line("client not connected");
            return;
        }
        client.read(handle);
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

    void service_radios(MonoTime)
    {
        import urt.atomic : atomicStore;
        atomicStore(_service_pending, 0u);
        foreach (radio; Collection!BLEInterface().values)
            radio.service();
    }

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

// HACK: not a member of BLEModule to avoid weird compile error!
__gshared shared(uint) _service_pending;
