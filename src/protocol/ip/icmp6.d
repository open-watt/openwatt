module protocol.ip.icmp6;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.endian;
import urt.hash;

import router.iface;
import router.iface.packet;

import protocol.ip : IPProtocol, IPv6Header, pseudo_header_checksum_v6;
import protocol.ip.mld;
import protocol.ip.stack;

nothrow @nogc:


enum Icmp6Type : ubyte
{
    listener_query  = 130,
    listener_report = 131,
    listener_done   = 132,
}

struct Icmp6Header
{
    ubyte type;
    ubyte code;
    ubyte[2] checksum;
}
static assert(Icmp6Header.sizeof == 4);


void icmp6_input(ref IPStack stack, ref Packet packet, size_t offset, BaseInterface iface)
{
    if (packet.data.length < offset + Icmp6Header.sizeof)
        return;

    const ip = cast(const IPv6Header*)packet.data.ptr;
    size_t datagram_end = IPv6Header.sizeof + ip.payload_length.bigEndianToNative!ushort;
    if (datagram_end > packet.data.length || datagram_end < offset + Icmp6Header.sizeof)
        return;

    const(ubyte)[] message = (cast(const(ubyte)*)packet.data.ptr)[offset .. datagram_end];
    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message.length, IPProtocol.icmp6);
    if (internet_checksum(message, pseudo) != 0)
        return;

    switch (message[0])
    {
        case Icmp6Type.listener_query:
        case Icmp6Type.listener_report:
        case Icmp6Type.listener_done:
            mld_input(packet, offset, iface);
            break;
        default:
            break;
    }
}
