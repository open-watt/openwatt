module protocol.ble.att;

// ATT/GATT protocol description: wire-level enums, attribute types, UUID
// conversions, and the discovered-table record types. The ATT client state
// machine itself lives in BLEClient (protocol/ble/client.d); the smart-backend
// ATT server emulation (driver/baremetal/ble.d) shares these definitions.

import urt.endian;
import urt.time;
import urt.uuid;

nothrow @nogc:


enum ATTError : ubyte
{
    none                  = 0x00,
    invalid_handle        = 0x01,
    read_not_permitted    = 0x02,
    write_not_permitted   = 0x03,
    invalid_pdu           = 0x04,
    insufficient_authn    = 0x05,
    request_not_supported = 0x06,
    invalid_offset        = 0x07,
    insufficient_authz    = 0x08,
    prepare_queue_full    = 0x09,
    attribute_not_found   = 0x0A,
    attribute_not_long    = 0x0B,
    insufficient_key_size = 0x0C,
    invalid_value_length  = 0x0D,
    unlikely_error        = 0x0E,
    insufficient_encrypt  = 0x0F,
    unsupported_group     = 0x10,
    insufficient_resource = 0x11,

    // local (not over-the-air) failure codes
    timeout               = 0xFE,
    send_failed           = 0xFF,
}

enum GattAttributeType : ushort
{
    primary_service   = 0x2800,
    secondary_service = 0x2801,
    include           = 0x2802,
    characteristic    = 0x2803,
    cccd              = 0x2902,
}

// ATT characteristic property bits (the over-the-air u8)
enum GattProps : ubyte
{
    broadcast              = 0x01,
    read                   = 0x02,
    write_without_response = 0x04,
    write                  = 0x08,
    notify                 = 0x10,
    indicate               = 0x20,
    authenticated_writes   = 0x40,
    extended_properties    = 0x80,
}

struct GattService
{
    ushort start;
    ushort end;
    GUID uuid;
}

struct GattChar
{
    ushort decl;          // declaration handle
    ushort value_handle;  // handle for read/write/notify
    ushort cccd;          // Client Characteristic Config descriptor (0 = none)
    ubyte props;          // GattProps
    ushort service;       // index into the services table
    GUID uuid;
}

alias ATTResponseDelegate = void delegate(const(ubyte)[] value, ATTError error) nothrow @nogc;

enum Duration att_transaction_timeout = 30.seconds;


// --- UUID helpers ---

// 0000xxxx-0000-1000-8000-00805F9B34FB
enum ubyte[8] bt_base_uuid_tail = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];

GUID uuid16_to_guid(ushort uuid) pure
{
    GUID g;
    g.data1 = uuid;
    g.data2 = 0x0000;
    g.data3 = 0x1000;
    g.data4 = bt_base_uuid_tail;
    return g;
}

// ATT carries UUIDs as the 128-bit value in little-endian byte order, which
// is the byte-reverse of the canonical string form.
GUID att_uuid_to_guid(const(ubyte)[] le)
{
    if (le.length == 2)
        return uuid16_to_guid(le.ptr[0 .. 2].littleEndianToNative!ushort);

    debug assert(le.length == 16);
    GUID g;
    ubyte[16] be = void;
    foreach (i; 0 .. 16)
        be[i] = le[15 - i];
    g.data1 = be[0 .. 4].bigEndianToNative!uint;
    g.data2 = be[4 .. 6].bigEndianToNative!ushort;
    g.data3 = be[6 .. 8].bigEndianToNative!ushort;
    g.data4 = be[8 .. 16];
    return g;
}

void guid_to_att_uuid(ref const GUID g, ref ubyte[16] le)
{
    ubyte[16] be = void;
    be[0 .. 4] = g.data1.nativeToBigEndian;
    be[4 .. 6] = g.data2.nativeToBigEndian;
    be[6 .. 8] = g.data3.nativeToBigEndian;
    be[8 .. 16] = g.data4;
    foreach (i; 0 .. 16)
        le[i] = be[15 - i];
}
