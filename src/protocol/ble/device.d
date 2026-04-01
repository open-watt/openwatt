module protocol.ble.device;

import urt.array;
import urt.string;
import urt.time;

import router.iface.mac;

nothrow @nogc:


// BLE AD type codes (Bluetooth Assigned Numbers)
enum ADType : ubyte
{
    flags                       = 0x01,
    incomplete_16bit_uuids      = 0x02,
    complete_16bit_uuids        = 0x03,
    incomplete_32bit_uuids      = 0x04,
    complete_32bit_uuids        = 0x05,
    incomplete_128bit_uuids     = 0x06,
    complete_128bit_uuids       = 0x07,
    shortened_local_name        = 0x08,
    complete_local_name         = 0x09,
    tx_power_level              = 0x0A,
    slave_conn_interval_range   = 0x12,
    service_solicitation_16     = 0x14,
    service_solicitation_128    = 0x15,
    service_data_16             = 0x16,
    appearance                  = 0x19,
    service_data_32             = 0x20,
    service_data_128            = 0x21,
    manufacturer_specific       = 0xFF,
}

// flags byte
enum ADFlags : ubyte
{
    le_limited_discoverable  = 0x01,
    le_general_discoverable  = 0x02,
    bredr_not_supported      = 0x04,
    le_bredr_controller      = 0x08,
    le_bredr_host            = 0x10,
}

// parsed AD structure from advertisement
struct ADSection
{
    ubyte type;
    const(ubyte)[] data;
}


enum ble_advert_ttl = 20;

struct BLEAdvEntry
{
    this(this) @disable;

    MACAddress addr;
    short rssi;
    byte tx_power = -128;
    ubyte ad_flags;
    bool connectable;
    MonoTime last_seen;
    String name;
    ushort company_id;
    bool has_company;
    Array!ushort service_uuids_16;

    void parse_ad_payload(const(ubyte)[] payload) nothrow @nogc
    {
        import urt.endian;

        uint offset = 0;
        while (offset < payload.length)
        {
            if (offset + 1 >= payload.length) break;
            ubyte len = payload[offset++];
            if (len == 0 || offset + len > payload.length) break;
            ubyte ad_type = payload[offset];
            const(ubyte)[] ad_data = payload[offset + 1 .. offset + len];
            offset += len;

            switch (ad_type)
            {
                case ADType.complete_local_name:
                case ADType.shortened_local_name:
                    if (name.empty && ad_data.length > 0)
                    {
                        import urt.mem.allocator : defaultAllocator;
                        name = (cast(const(char)[])ad_data).makeString(defaultAllocator());
                    }
                    break;

                case ADType.flags:
                    if (ad_data.length >= 1)
                        ad_flags = ad_data[0];
                    break;

                case ADType.tx_power_level:
                    if (ad_data.length >= 1)
                        tx_power = cast(byte)ad_data[0];
                    break;

                case ADType.manufacturer_specific:
                    if (ad_data.length >= 2)
                    {
                        company_id = ad_data.ptr[0..2].littleEndianToNative!ushort;
                        has_company = true;
                    }
                    break;

                case ADType.complete_16bit_uuids:
                case ADType.incomplete_16bit_uuids:
                    for (size_t i = 0; i + 1 < ad_data.length; i += 2)
                    {
                        ushort uuid = (ad_data.ptr + i)[0..2].littleEndianToNative!ushort;
                        bool found = false;
                        foreach (existing; service_uuids_16[])
                        {
                            if (existing == uuid) { found = true; break; }
                        }
                        if (!found)
                            service_uuids_16 ~= uuid;
                    }
                    break;

                default:
                    break;
            }
        }
    }
}
