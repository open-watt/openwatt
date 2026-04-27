module protocol.ip.neighbour;

import urt.array;
import urt.inet;
import urt.time;

import router.iface;
import router.iface.packet;

nothrow @nogc:


enum NeighbourState : ubyte
{
    incomplete,     // resolution in flight (ARP request / NS sent)
    reachable,      // confirmed within reachable_time
    stale,          // unconfirmed, use but probe on next send
    failed,         // resolution gave up -> drop queued packets
}


struct NeighbourEntry
{
    IPAddr ip;
    ubyte[16] link_addr;        // MAC (6) or 802.15.4 EUI64 (8) etc.
    ubyte link_addr_len;
    BaseInterface iface;
    NeighbourState state;
    SysTime last_confirmed;
    // TODO: small queue of packets pending resolution
}


struct NeighbourCache
{
nothrow @nogc:

    // Lookup or kick off resolution. Returns null while pending.
    const(ubyte)[] resolve(IPAddr ip, BaseInterface iface, ref Packet pending)
    {
        // TODO: hash lookup; if reachable -> return link_addr
        // TODO: if missing -> create incomplete entry, queue pending, send_request
        // TODO: if incomplete -> just queue pending
        return null;
    }

    void on_arp(ref const Packet pkt, BaseInterface iface)
    {
        // TODO: parse ARP; respond to who-has for our IPs; update cache from replies
        // TODO: drain pending packets for any newly-reachable entry
    }

    void on_neighbour_advert(ref const Packet pkt, BaseInterface iface)
    {
        // TODO: IPv6 ND NA handling
    }

    void tick(SysTime now)
    {
        // TODO: age entries, retry incompletes (max ~3), expire stale -> failed
    }

private:
    void send_arp_request(IPAddr target, BaseInterface iface)
    {
        // TODO: build + send ARP who-has via iface
    }

    void send_neighbour_solicit(IPAddr target, BaseInterface iface)
    {
        // TODO: build + send ICMPv6 NS via iface
    }

    Array!NeighbourEntry _entries;
}
