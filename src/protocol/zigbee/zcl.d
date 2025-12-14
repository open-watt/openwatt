module protocol.zigbee.zcl;

import urt.endian;
import urt.variant;

nothrow @nogc:

//
// ZCL spec here: https://zigbeealliance.org/wp-content/uploads/2019/12/07-5123-06-zigbee-cluster-library-specification.pdf
//

enum ZCLControlFlags : ubyte
{
    frame_type_mask = 0x3,
    frame_type_global = 0x0,
    frame_type_cluster = 0x1,

    manufacturer_specific = 0x4,
    response = 0x8,
    disable_default_response = 0x10,
}

enum ZCLCommand : ushort
{
    read_attributes = 0x00,
    read_attributes_response = 0x01,
    write_attributes = 0x02,
    write_attributes_undivided = 0x03,
    write_attributes_response = 0x04,
    write_attributes_no_response = 0x05,
    configure_reporting = 0x06,
    configure_reporting_response = 0x07,
    read_reporting_configuration = 0x08,
    read_reporting_configuration_response = 0x09,
    report_attributes = 0x0a,
    default_response = 0x0b,
    discover_attributes = 0x0c,
    discover_attributes_response = 0x0d,
    read_attributes_structured = 0x0e,
    write_attributes_structured = 0x0f,
    write_attributes_structured_response = 0x10,
    discover_commands_received = 0x11,
    discover_commands_received_response = 0x12,
    discover_commands_generated = 0x13,
    discover_commands_generated_response = 0x14,
    discover_attributes_extended = 0x15,
    discover_attributes_extended_response = 0x16,

    // Manufacturer-specific commands can be defined starting from 0x80
}

enum ZCLClusterCommand : ubyte
{
    //...
    unknown = 0,

    // Manufacturer-specific commands can be defined starting from 0x80
}

enum ZCLStatus : ubyte
{
    success = 0x00,
    failure = 0x01,
    not_authorized = 0x7e,
    reserved_field_not_zero = 0x7f,
    malformed_command = 0x80,
    unsup_cluster_command = 0x81,
    unsup_general_command = 0x82,
    unsup_manuf_cluster_command = 0x83,
    unsup_manuf_general_command = 0x84,
    invalid_field = 0x85,
    unsupported_attribute = 0x86,
    invalid_value = 0x87,
    read_only = 0x88,
    insufficient_space = 0x89,
    duplicate_exists = 0x8a,
    not_found = 0x8b,
    unreportable_attribute = 0x8c,
    invalid_data_type = 0x8d,
    invalid_selector = 0x8e,
    write_only = 0x8f,
    inconsistent_startup_state = 0x90,
    defined_out_of_band = 0x91,
    inconsistent = 0x92,
    action_denied = 0x93,
    timeout = 0x94,
    abort = 0x95,
    invalid_image = 0x96,
    wait_for_data = 0x97,
    no_image_available = 0x98,
    require_more_image = 0x99,
    notification_pending = 0x9a,
    hardware_failure = 0xc0,
    software_failure = 0xc1,
    calibration_error = 0xc2,
    unsupported_cluster = 0xc3
}

enum ZCLDataType : ubyte
{
    no_data = 0x00,
    data8 = 0x08,
    data16 = 0x09,
    data24 = 0x0a,
    data32 = 0x0b,
    data40 = 0x0c,
    data48 = 0x0d,
    data56 = 0x0e,
    data64 = 0x0f,
    boolean = 0x10,
    bitmap8 = 0x18,
    bitmap16 = 0x19,
    bitmap24 = 0x1a,
    bitmap32 = 0x1b,
    bitmap40 = 0x1c,
    bitmap48 = 0x1d,
    bitmap56 = 0x1e,
    bitmap64 = 0x1f,
    uint8 = 0x20,
    uint16 = 0x21,
    uint24 = 0x22,
    uint32 = 0x23,
    uint40 = 0x24,
    uint48 = 0x25,
    uint56 = 0x26,
    uint64 = 0x27,
    int8 = 0x28,
    int16 = 0x29,
    int24 = 0x2a,
    int32 = 0x2b,
    int40 = 0x2c,
    int48 = 0x2d,
    int56 = 0x2e,
    int64 = 0x2f,
    enum8 = 0x30,
    enum16 = 0x31,
    semi_prec_float = 0x38,
    single_prec_float = 0x39,
    double_prec_float = 0x3a,
    octet_string = 0x41,
    char_string = 0x42,
    long_octet_string = 0x43,
    long_char_string = 0x44,
    array = 0x48,
    struct_ = 0x4c,
    set = 0x50,
    bag = 0x51,
    time_of_day = 0xe0,
    date = 0xe1,
    utc_time = 0xe2,
    cluster_id = 0xe8,
    attribute_id = 0xe9,
    bacnet_oui = 0xea,
    ieee_address = 0xf0,
    security_key = 0xf1,
    unknown = 0xff
}

enum ZCLAccess : ubyte
{
    unknown = 0,
    read = 1,
    write = 2,
    report = 4,

    read_write = read | write,
    read_report = read | report,
    write_report = write | report,
    read_write_report = read | write | report
}

enum ZCLPowerSource : ubyte
{
    unknown = 0,
    mains_single_phase = 1,
    mains_three_phase = 2,
    battery = 3,
    dc_source = 4,
    emergency_generator = 5,
    emergency_mains_transfer_switch = 6
}

struct ZCLHeader
{
    ubyte control;
    ushort manufacturer_code;
    ubyte seq;
    ubyte command;
}

ptrdiff_t decode_zcl_header(const(void)[] data, out ZCLHeader hdr)
{
    if (data.length < 3)
        return -1;

    auto bytes = cast(const ubyte[])data;
    hdr.control = bytes[0];
    size_t offset = (hdr.control & ZCLControlFlags.manufacturer_specific) ? 2 : 0;
    if (offset)
    {
        if (data.length < 5)
            return -1;
        hdr.manufacturer_code = bytes[1..3].littleEndianToNative!ushort;
    }
    hdr.seq = bytes[1 + offset];
    hdr.command = cast(ZCLCommand)bytes[2 + offset];
    return 3 + offset;
}

ptrdiff_t format_zcl_header(ref ZCLHeader hdr, void[] buffer)
{
    size_t offset = (hdr.control & ZCLControlFlags.manufacturer_specific) ? 2 : 0;
    if (buffer.length < 3 + offset)
        return -1;

    auto bytes = cast(ubyte[])buffer;
    bytes[0] = hdr.control;
    if (offset)
        bytes[1..3] = hdr.manufacturer_code.nativeToLittleEndian;
    bytes[1 + offset] = hdr.seq;
    bytes[2 + offset] = hdr.command;
    return 3 + offset;
}

ptrdiff_t get_zcl_value(ZCLDataType type, const(ubyte)[] data, out Variant r) nothrow @nogc
{
    import urt.array;
    import urt.time;
    import router.iface.mac;

    switch (type) with (ZCLDataType)
    {
        case no_data:
            return 0;

        case boolean:
            if (data.length < 1)
                return -1;
            r = Variant(data[0] != 0);
            return 1;

        case bitmap8,
             uint8,
             int8,
             enum8:
            if (data.length < 1)
                return -1;
            if (type == ZCLDataType.int8)
                r = Variant(cast(int)cast(byte)data[0]);
            else
                r = Variant(cast(uint)data[0]);
            return 1;

        case bitmap16,
             uint16,
             int16,
             enum16:
            if (data.length < 2)
                return -1;
            ushort u16 = data[0..2].littleEndianToNative!ushort;
            if (type == ZCLDataType.int16)
                r = Variant(cast(int)cast(short)u16);
            else
                r = Variant(cast(uint)u16);
            return 2;

        case bitmap24,
             uint24,
             int24:
            if (data.length < 3)
                return -1;
            ushort u24 = data[0..2].littleEndianToNative!ushort;
            if (type == ZCLDataType.int24)
                r = Variant(u24 | (int(data[2] << 24) >> 8));
            else
                r = Variant(uint(u24 | (data[2] << 16)));
            return 3;

        case bitmap32,
             uint32,
             int32: 
            if (data.length < 4)
                return -1;
            uint u32 = data[0..4].littleEndianToNative!uint;
            if (type == ZCLDataType.int32)
                r = Variant(cast(int)u32);
            else
                r = Variant(u32);
            return 4;

        case bitmap40,
             uint40,
             int40:
            if (data.length < 5)
                return -1;
            ulong u40 = data[0..4].littleEndianToNative!uint;
            if (type == ZCLDataType.int40)
                r = Variant(long(u40 | (long(data[4]) << 56 >> 24)));
            else
                r = Variant(u40 | (ulong(data[4]) << 32));
            return 5;

        case bitmap48,
             uint48,
             int48:
            if (data.length < 6)
                return -1;
            ulong u48 = data[0..4].littleEndianToNative!uint | (ulong(data[4..6].littleEndianToNative!ushort) << 32);
            long high_bits = data[4..6].littleEndianToNative!ushort;
            if (type == ZCLDataType.int48)
                r = Variant(long(u48 | (high_bits << 48 >> 16)));
            else
                r = Variant(u48 | (high_bits << 32));
            return 6;

        case bitmap56,
             uint56,
             int56:
            if (data.length < 7)
                return -1;
            ulong u56 = data[0..4].littleEndianToNative!uint | (ulong(data[4..6].littleEndianToNative!ushort) << 32);
            if (type == ZCLDataType.int56)
                r = Variant(long(u56 | (long(data[6]) << 56 >> 8)));
            else
                r = Variant(u56 | (ulong(data[6]) << 48));
            return 7;

        case bitmap64,
             uint64,
             int64:
            if (data.length < 8)
                return -1;
            ulong u64 = data[0..8].littleEndianToNative!ulong;
            if (type == ZCLDataType.int64)
                r = Variant(cast(long)u64);
            else
                r = Variant(u64);
            return 8;

        case semi_prec_float:
            if (data.length < 2)
                return -1;
            assert(false, "TODO: parse half-float");
            return 2;

        case single_prec_float:
            if (data.length < 4)
                return -1;
            r = Variant(data[0..4].littleEndianToNative!float);
            return 4;

        case double_prec_float:
            if (data.length < 8)
                return -1;
            r = Variant(data[0..8].littleEndianToNative!double);
            return 8;

        case char_string:
            if (data.length < 1 || data.length < 1 + data[0])
                return -1;
            r = Variant(cast(const(char)[])data[1 .. 1 + data[0]]);
            return 1 + data[0];

        case long_char_string:
            if (data.length < 2)
                return -1;
            size_t len = data[0..2].littleEndianToNative!ushort;
            if (data.length < 2 + len)
                return -1;
            r = Variant(cast(const(char)[])data[2 .. 2 + len]);
            return 2 + len;

        case data8:
             ..
        case data64:
            size_t len = (type & 7) + 1;
            if (data.length < len)
                return -1;
            r = Variant(cast(const(void)[])data[0 .. len]);
            return len;

        case security_key:
            if (data.length < 16)
                return -1;
            r = Variant(cast(const(void)[])data[0 .. 16]);
            return 16;

        case octet_string:
            if (data.length < 1 || data.length < 1 + data[0])
                return -1;
            r = Variant(cast(const(void)[])data[1 .. 1 + data[0]]);
            return 1 + data[0];

        case long_octet_string:
            if (data.length < 2)
                return -1;
            size_t len = data[0..2].littleEndianToNative!ushort;
            if (data.length < 2 + len)
                return -1;
            r = Variant(cast(const(void)[])data[2 .. 2 + len]);
            return 2 + len;

        case time_of_day:
            if (data.length < 4)
                return -1;
            r = Variant(data[0..4].littleEndianToNative!uint.dur!"seconds");
            return 4;

        case date:
            if (data.length < 4)
                return -1;
            uint val = data[0..4].littleEndianToNative!uint;
            DateTime dt;
            dt.day = val & 0x1f;
            dt.month = cast(Month)((val >> 5) & 0x0f);
            dt.year = (val >> 9) & 0x7f;
            r = Variant(dt.getSysTime());
            return 4;

        case utc_time:
            if (data.length < 4)
                return -1;
            uint val = data[0..4].littleEndianToNative!uint; // seconds since 2000-01-01
            ulong unix_time = (cast(ulong)val + 946684800) * 1_000_000_000; // to nanoseconds since 1970-01-01
            r = Variant(unix_time.from_unix_time_ns());
            return 4;

        case ieee_address:
            if (data.length < 8)
                return -1;
            EUI64 eui;
            eui.ul = data[0..8].bigEndianToNative!ulong;
            r = Variant(eui);
            return 8;

        case array, set, bag:
            if (data.length < 2)
                return -1;

            ZCLDataType element_type = cast(ZCLDataType)data[0];
            size_t count = data[1];
            size_t len = 2;

            ref Array!Variant arr = r.asArray();
            arr.reserve(count);

            foreach (i; 0 .. count)
            {
                ref Variant t = arr.pushBack();
                ptrdiff_t taken = get_zcl_value(element_type, data[len .. $], t);
                if (taken < 0)
                {
                    r = null;
                    return -1;
                }
                len += taken;
            }
            return len;

        case struct_:
            if (data.length < 1)
                return -1;

            size_t count = data[0];
            size_t len = 1;

            ref Array!Variant arr = r.asArray();
            arr.reserve(count);

            foreach (i; 0 .. count)
            {
                if (data.length < len + 1)
                    return -1;
                ZCLDataType element_type = cast(ZCLDataType)data[len++];

                ref Variant t = arr.pushBack();
                ptrdiff_t taken = get_zcl_value(element_type, data[len .. $], t);
                if (taken < 0)
                {
                    r = null;
                    return -1;
                }
                len += taken;
            }
            return len;

        default:
            import urt.mem.temp : tformat;
            assert(false, tformat("Unsupported ZCL data type: {0, 02x}", type));
    }
}
