module protocol.ble;

import urt.conv;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.time;
import urt.uuid;
import urt.util;

import manager;
import manager.collection;
import manager.config : ConfItem;
import manager.console;
import manager.plugin;
import manager.profile;
import manager.sample.spec : stream_le_context;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;
import protocol.ble.binding;

nothrow @nogc:


package __gshared uint ble_section_kind;

class BLEModule : Module, ProfileSections
{
    mixin DeclareModule!"protocol.ble";
nothrow @nogc:

    alias log = Log!"ble";

    Map!(MACAddress, BLEAdvEntry*) devices;

    override void init()
    {
        register_packet_codec!BLEFrame();
        register_frame_handler(PacketType.ble, &on_ble_frame);

        ble_section_kind = register_profile_section("ble", this);

        g_app.console.register_collection!BLEClient();
        g_app.console.register_collection!BLEClientBinding();
        g_app.console.register_command!print_devices("/protocol/ble/device", this, "print");
        g_app.console.register_command!cmd_read("/protocol/ble/client", this, "read");
    }

    uint element_size(uint)
        => cast(uint)ElementDesc_BLE.sizeof;

    void count_element(uint, ref const ConfItem, ref ProfileSize) {}

    bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        const(char)[] tail = item.value;
        ElementDesc_BLE* ble = cast(ElementDesc_BLE*)slot.ptr;
        *ble = ElementDesc_BLE.init;

        const(char)[] service = tail.split!',';
        const(char)[] char_field = tail.split!',';
        const(char)[] char_uuid = char_field.split!'(';
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] units = tail.split!','.unQuote;

        if (!parse_ble_uuid(service, ble.service_uuid))
        {
            writeWarning("Invalid BLE service UUID: ", service);
            return false;
        }
        if (!parse_ble_uuid(char_uuid, ble.char_uuid))
        {
            writeWarning("Invalid BLE characteristic UUID: ", char_uuid);
            return false;
        }

        if (char_field.length)
        {
            if (char_field[$-1] != ')')
            {
                writeWarning("Invalid BLE characteristic offset: ", char_field);
                return false;
            }
            char_field = char_field[0 .. $-1].trimBack;
            size_t taken;
            ulong offset = char_field.parse_uint_with_base(&taken);
            if (taken != char_field.length || offset > ubyte.max)
            {
                writeWarning("Invalid BLE characteristic offset: ", char_field);
                return false;
            }
            ble.offset = cast(ubyte)offset;
        }

        if (!b.compile_value(type, units, stream_le_context, ble.desc, ble.length))
            return false;
        if (ble.length == 0)
        {
            writeWarning("Unsized string requires a framed BLE profile hook: ", b.element_id);
            ble.desc = ushort.max;
            return false;
        }
        return true;
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

private:

bool parse_ble_uuid(const(char)[] str, out GUID guid) pure
{
    if (guid.fromString(str) == 36)
        return str.length == 36;

    const(char)[] hex = str;
    if (hex.length >= 2 && hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X'))
        hex = hex[2 .. $];

    size_t taken;
    ulong value = parse_uint(hex, &taken, 16);
    if ((taken != 4 && taken != 8) || taken != hex.length)
        return false;

    guid.data1 = cast(uint)value;
    guid.data2 = 0x0000;
    guid.data3 = 0x1000;
    guid.data4 = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    return true;
}

unittest
{
    GUID guid;
    assert(parse_ble_uuid("180F", guid) && guid.data1 == 0x180F);
    assert(parse_ble_uuid("0x2A19", guid) && guid.data1 == 0x2A19);
    assert(!parse_ble_uuid("180G", guid));
}
