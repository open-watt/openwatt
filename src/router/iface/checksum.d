module router.iface.checksum;

import urt.hash : internet_checksum;

import router.iface.packet : EtherType;

nothrow @nogc:


void complete_checksum(ubyte[] ip_packet, EtherType type) pure
{
    size_t l4;
    ubyte protocol;
    const(ubyte)[] addresses;
    if (type == EtherType.ip4)
    {
        l4 = (ip_packet[0] & 0xF) * 4;
        protocol = ip_packet[9];
        addresses = ip_packet[12 .. 20];
    }
    else
    {
        debug assert(type == EtherType.ip6, "checksum pending on a packet that is not IP");
        l4 = 40;
        protocol = ip_packet[6];
        addresses = ip_packet[8 .. 40];
    }
    debug assert(protocol == protocol_tcp || protocol == protocol_udp, "checksum pending on a packet that is not TCP or UDP");

    ubyte[] segment = ip_packet[l4 .. $];
    ubyte[4] protocol_and_length = [0, protocol, cast(ubyte)(segment.length >> 8), cast(ubyte)segment.length];
    ushort pseudo = internet_checksum(protocol_and_length[], internet_checksum(addresses));

    ubyte[] field = protocol == protocol_tcp ? segment[16 .. 18] : segment[6 .. 8];
    field[] = 0;
    ushort sum = internet_checksum(segment, pseudo);
    // RFC 768: zero on the wire means the sender computed no checksum
    if (sum == 0 && protocol == protocol_udp)
        sum = 0xFFFF;
    field[0] = cast(ubyte)(sum >> 8);
    field[1] = cast(ubyte)sum;
}


private:

enum ubyte protocol_tcp = 6;
enum ubyte protocol_udp = 17;

unittest
{
    // 10.0.0.1:1 -> 10.0.0.2:2, UDP, payload "hi"
    ubyte[30] v4 = [0x45, 0, 0, 30, 0, 0, 0, 0, 64, 17, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2,
                    0, 1, 0, 2, 0, 10, 0, 0, 'h', 'i'];
    complete_checksum(v4[], EtherType.ip4);
    assert(v4[26] != 0 || v4[27] != 0);
    ubyte[12] pseudo4 = [10, 0, 0, 1, 10, 0, 0, 2, 0, 17, 0, 10];
    assert(internet_checksum(v4[20 .. $], internet_checksum(pseudo4[])) == 0);

    // the same over IPv6 as TCP, with the 40-byte pseudo-header of RFC 8200
    ubyte[60] v6;
    v6[0] = 0x60;
    v6[5] = 20;
    v6[6] = 6;
    v6[7] = 64;
    v6[23] = 1;
    v6[39] = 2;
    v6[52] = 0x50;
    complete_checksum(v6[], EtherType.ip6);
    ubyte[40] pseudo6;
    pseudo6[0 .. 32] = v6[8 .. 40];
    pseudo6[35] = 20;
    pseudo6[39] = 6;
    assert(internet_checksum(v6[40 .. $], internet_checksum(pseudo6[])) == 0);
}
