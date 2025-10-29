module protocol.zigbee.zcl;

import urt.endian;

nothrow @nogc:

enum ZCLControlFlags : ubyte
{
    frame_type_mask = 0x3,
    frame_type_global = 0x0,
    frame_type_cluster = 0x1,

    manufacturer_specific = 0x4,
    response = 0x8,
    disable_default_response = 0x10,
}

enum ZCLCommand : ubyte
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
}

struct ZCLHeader
{
    ubyte control;
    ushort manufacturer_code;
    ubyte seq;
    ZCLCommand command;
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
