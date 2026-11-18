module urt_config;

import urt.mem.page : PageClass, page_required_capacity;

import router.iface.packet : Packet, packet_headroom;

nothrow @nogc:

// a default packet holding a full Modbus PDU, or a 1500-byte datagram
static immutable PageClass[2] page_classes = [PageClass(packet_page(253), 8, 4), PageClass(packet_page(1500), 4, 2)];

private:

ushort packet_page(size_t payload)
    => cast(ushort)page_required_capacity(payload, size_t.sizeof, Packet.sizeof + packet_headroom, 0);
