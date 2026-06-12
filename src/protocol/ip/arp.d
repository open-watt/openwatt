module protocol.ip.arp;

version (UseInternalIPStack):

import urt.inet;
import urt.log;
import urt.endian;

import manager.collection;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip.address;
import protocol.ip.neighbour;

//version = DebugARP;

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
    ubyte[2] htype;     // big-endian, 1 = Ethernet
    ubyte[2] ptype;     // big-endian, 0x0800 = IPv4
    ubyte    hlen;      // 6
    ubyte    plen;      // 4
    ubyte[2] op;        // big-endian, 1 = request, 2 = reply
    ubyte[6] sha;       // sender hardware
    ubyte[4] spa;       // sender protocol (IPv4)
    ubyte[6] tha;       // target hardware
    ubyte[4] tpa;       // target protocol
}
static assert(ArpV4Packet.sizeof == 28);


// Send an ARP who-has request for `target` out `iface`.
// Source IP is the first IPAddress we own on `iface`; if none, sent as 0.0.0.0 (probe-style).
void send_arp_request(IPAddr target, EthernetStation iface)
{
    IPAddr our_ip;
    foreach (a; Collection!IPAddress().values)
    {
        if (a.iface is iface)
        {
            our_ip = a.address.addr;
            break;
        }
    }

    ArpV4Packet req;
    req.htype = nativeToBigEndian(ushort(ArpHType.ethernet));
    req.ptype = nativeToBigEndian(ushort(EtherType.ip4));
    req.hlen = 6;
    req.plen = 4;
    req.op = nativeToBigEndian(ushort(ArpOp.request));
    req.sha = iface.mac.b;
    req.spa = our_ip.b;
    // tha left zero (unknown)
    req.tpa = target.b;

    version (DebugARP)
        write_log(Severity.debug_, "arp", null, "request who-has ", target, " on ", iface.name, " (sender=", our_ip, ")");

    iface.send(MACAddress.broadcast, (cast(const(ubyte)*)&req)[0 .. ArpV4Packet.sizeof], EtherType.arp);
}


// Parse incoming ARP frame, learn from observed traffic, and reply to who-has-our-IP.
void on_arp(ref const Packet pkt, EthernetStation iface, ref NeighbourCache!IPAddr cache)
{
    const data = pkt.data;
    if (data.length < ArpV4Packet.sizeof)
    {
        version (DebugARP)
            write_log(Severity.trace, "arp", null, "rx truncated frame on ", iface.name, " len=", data.length);
        return;
    }

    const a = cast(const(ArpV4Packet)*)data.ptr;
    if (a.htype.bigEndianToNative!ushort != ArpHType.ethernet)
        return;
    if (a.ptype.bigEndianToNative!ushort != EtherType.ip4)
        return;
    if (a.hlen != 6 || a.plen != 4)
        return;

    ushort op = a.op.bigEndianToNative!ushort;
    MACAddress sha = MACAddress(a.sha);
    IPAddr spa = IPAddr(a.spa);
    IPAddr tpa = IPAddr(a.tpa);

    version (DebugARP)
        write_log(Severity.trace, "arp", null, "rx ", op == ArpOp.request ? "request" : op == ArpOp.reply ? "reply" : "op?", " from ", sha, "/", spa, " for ", tpa, " on ", iface.name);

    // Learn from any frame carrying a sender pair (request, reply, gratuitous).
    // Skip ARP probes (spa == 0) and zero-MAC senders.
    if (spa != IPAddr.any && sha)
    {
        version (DebugARP)
            write_log(Severity.debug_, "arp", null, "learn ", spa, " -> ", sha, " on ", iface.name);
        cache.learn(spa, iface, sha.b[]);
    }

    if (op != ArpOp.request)
        return;

    if (!is_our_ip(tpa, iface))
        return;

    ArpV4Packet reply;
    reply.htype = nativeToBigEndian(ushort(ArpHType.ethernet));
    reply.ptype = nativeToBigEndian(ushort(EtherType.ip4));
    reply.hlen = 6;
    reply.plen = 4;
    reply.op = nativeToBigEndian(ushort(ArpOp.reply));
    reply.sha = iface.mac.b;
    reply.spa = tpa.b;
    reply.tha = sha.b;
    reply.tpa = spa.b;

    version (DebugARP)
        write_log(Severity.debug_, "arp", null, "reply ", tpa, " is-at ", iface.mac, " to ", sha, "/", spa, " on ", iface.name);

    iface.send(sha, (cast(const(ubyte)*)&reply)[0 .. ArpV4Packet.sizeof], EtherType.arp);
}


bool is_our_ip(IPAddr ip, BaseInterface iface)
{
    foreach (a; Collection!IPAddress().values)
        if (cast(BaseInterface)a.iface is iface && a.address.addr == ip)
            return true;
    return false;
}

