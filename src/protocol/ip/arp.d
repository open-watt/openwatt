module protocol.ip.arp;

import urt.inet;

import manager.collection;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ip.address;
import protocol.ip.neighbour;

nothrow @nogc:


enum ArpOp : ushort
{
    request = 1,
    reply   = 2,
}

enum ArpHType : ushort
{
    ethernet = 1,
}


struct ArpV4Packet
{
align(1):
    ubyte[2] htype;     // big-endian, 1 = Ethernet
    ubyte[2] ptype;     // big-endian, 0x0800 = IPv4
    ubyte    hlen;      // 6
    ubyte    plen;      // 4
    ubyte[2] op;        // big-endian, 1 = request, 2 = reply
    MACAddress sha;     // sender hardware
    IPAddr     spa;     // sender protocol (IPv4)
    MACAddress tha;     // target hardware
    IPAddr     tpa;     // target protocol
}
static assert(ArpV4Packet.sizeof == 28);


// Send an ARP who-has request for `target` out `iface`.
// Source IP is the first IPAddress we own on `iface`; if none, sent as 0.0.0.0 (probe-style).
void send_arp_request(IPAddr target, BaseInterface iface)
{
    IPAddr our_ip;
    foreach (a; Collection!IPAddress().values)
    {
        if (cast(BaseInterface)a.iface is iface)
        {
            our_ip = a.address.addr;
            break;
        }
    }

    ArpV4Packet req;
    set_be_u16(req.htype, ArpHType.ethernet);
    set_be_u16(req.ptype, EtherType.ip4);
    req.hlen = 6;
    req.plen = 4;
    set_be_u16(req.op, ArpOp.request);
    req.sha = iface.mac;
    req.spa = our_ip;
    // tha left zero (unknown)
    req.tpa = target;

    iface.send(MACAddress.broadcast, (cast(const(ubyte)*)&req)[0 .. ArpV4Packet.sizeof], EtherType.arp);
}


// Parse incoming ARP frame, learn from observed traffic, and reply to who-has-our-IP.
void on_arp(ref const Packet pkt, BaseInterface iface, ref NeighbourCache!IPAddr cache)
{
    const data = pkt.data;
    if (data.length < ArpV4Packet.sizeof)
        return;

    const a = cast(const(ArpV4Packet)*)data.ptr;
    if (be_u16(a.htype) != ArpHType.ethernet) return;
    if (be_u16(a.ptype) != EtherType.ip4)     return;
    if (a.hlen != 6 || a.plen != 4)           return;

    ushort op = be_u16(a.op);

    // Learn from any frame carrying a sender pair (request, reply, gratuitous).
    // Skip ARP probes (spa == 0) and zero-MAC senders.
    if (a.spa != IPAddr.any && a.sha)
        cache.learn(a.spa, iface, a.sha.b[]);

    if (op != ArpOp.request)
        return;

    if (!is_our_ip(a.tpa, iface))
        return;

    ArpV4Packet reply;
    set_be_u16(reply.htype, ArpHType.ethernet);
    set_be_u16(reply.ptype, EtherType.ip4);
    reply.hlen = 6;
    reply.plen = 4;
    set_be_u16(reply.op, ArpOp.reply);
    reply.sha = iface.mac;
    reply.spa = a.tpa;
    reply.tha = a.sha;
    reply.tpa = a.spa;

    iface.send(a.sha, (cast(const(ubyte)*)&reply)[0 .. ArpV4Packet.sizeof], EtherType.arp);
}


private:

ushort be_u16(const ref ubyte[2] x) pure
    => cast(ushort)((x[0] << 8) | x[1]);

void set_be_u16(ref ubyte[2] x, ushort v) pure
{
    x[0] = cast(ubyte)(v >> 8);
    x[1] = cast(ubyte)v;
}

bool is_our_ip(IPAddr ip, BaseInterface iface)
{
    foreach (a; Collection!IPAddress().values)
        if (cast(BaseInterface)a.iface is iface && a.address.addr == ip)
            return true;
    return false;
}

