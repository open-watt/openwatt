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


struct NeighbourEntry(IP)
{
    IP ip;
    BaseInterface iface;
    ubyte[16] link_addr;        // MAC (6) or EUI-64 (8) etc.
    ubyte link_addr_len;
    NeighbourState state;
    SysTime last_confirmed;
    // TODO: small queue of packets pending resolution
}


struct NeighbourCache(IP)
{
nothrow @nogc:

    // Insert or refresh an entry from observed traffic (ARP reply, ND NA, gratuitous, etc).
    void learn(IP ip, BaseInterface iface, const(ubyte)[] link_addr)
    {
        if (link_addr.length == 0 || link_addr.length > 16)
            return;

        SysTime now = getSysTime();

        foreach (ref e; _entries[])
        {
            if (e.iface is iface && e.ip == ip)
            {
                e.link_addr[0 .. link_addr.length] = link_addr[];
                e.link_addr_len  = cast(ubyte)link_addr.length;
                e.state          = NeighbourState.reachable;
                e.last_confirmed = now;
                return;
            }
        }

        NeighbourEntry!IP n;
        n.ip                       = ip;
        n.iface                    = iface;
        n.link_addr[0..link_addr.length] = link_addr[];
        n.link_addr_len            = cast(ubyte)link_addr.length;
        n.state                    = NeighbourState.reachable;
        n.last_confirmed           = now;
        _entries ~= n;
    }

    NeighbourEntry!IP* find(IP ip, BaseInterface iface)
    {
        foreach (ref e; _entries[])
            if (e.iface is iface && e.ip == ip)
                return &e;
        return null;
    }

    // Lookup; returns link_addr if reachable, null if missing/incomplete.
    const(ubyte)[] resolve(IP ip, BaseInterface iface, ref Packet pending)
    {
        auto e = find(ip, iface);
        if (e && e.state == NeighbourState.reachable)
            return e.link_addr[0 .. e.link_addr_len];
        // TODO: kick off active resolution, queue `pending`, send request
        return null;
    }

    void tick(SysTime now)
    {
        // TODO: age entries, retry incompletes (max ~3), expire stale -> failed
    }

    auto entries() inout pure
        => _entries[];

private:
    Array!(NeighbourEntry!IP) _entries;
}
