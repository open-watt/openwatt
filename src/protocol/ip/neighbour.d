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
    MonoTime last_confirmed;
    MonoTime last_request;      // when we last sent a resolution request
    ubyte retry_count;
    Packet* pending;            // single-slot queue; replaced on overflow
}

struct NeighbourCache(IP)
{
nothrow @nogc:

    alias SendRequestDg = void delegate(IP target, BaseInterface iface) nothrow @nogc;
    alias DrainDg       = void delegate(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr) nothrow @nogc;

    enum uint  retry_interval_ms       = 1000;
    enum ubyte max_retries             = 3;
    enum uint  reachable_time_ms       = 30_000;
    enum uint  stale_probe_interval_ms = 5_000;
    enum ubyte max_stale_probes        = 3;
    enum uint  failed_lifetime_ms      = 60_000;

    SendRequestDg send_request;
    DrainDg       drain;

    // Insert or refresh an entry from observed traffic (ARP reply, ND NA, gratuitous, etc).
    // If the entry was incomplete and had a queued packet, drain it.
    void learn(IP ip, BaseInterface iface, const(ubyte)[] link_addr)
    {
        if (link_addr.length == 0 || link_addr.length > 16)
            return;

        MonoTime now = getTime();

        foreach (ref e; _entries[])
        {
            if (e.iface is iface && e.ip == ip)
            {
                e.link_addr[0 .. link_addr.length] = link_addr[];
                e.link_addr_len  = cast(ubyte)link_addr.length;
                e.state          = NeighbourState.reachable;
                e.last_confirmed = now;
                e.retry_count    = 0;
                drain_pending(e);
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

    // Lookup; returns link_addr if reachable, null otherwise.
    // On miss, creates an incomplete entry, queues `pending`, kicks off resolution.
    // On in-flight, replaces the queued packet (single-slot).
    const(ubyte)[] resolve(IP ip, BaseInterface iface, ref Packet pending)
    {
        if (auto e = find(ip, iface))
        {
            final switch (e.state) with (NeighbourState)
            {
                case reachable:
                case stale:
                    return e.link_addr[0 .. e.link_addr_len];
                case failed:
                    // peer may have come back -- restart resolution
                    e.state        = NeighbourState.incomplete;
                    e.last_request = getTime();
                    e.retry_count  = 1;
                    queue_pending(*e, pending);
                    if (send_request)
                        send_request(ip, iface);
                    return null;
                case incomplete:
                    queue_pending(*e, pending);
                    return null;
            }
        }

        NeighbourEntry!IP n;
        n.ip            = ip;
        n.iface         = iface;
        n.state         = NeighbourState.incomplete;
        n.last_request  = getTime();
        n.retry_count   = 1;
        n.pending       = pending.clone();
        _entries ~= n;

        if (send_request)
            send_request(ip, iface);

        return null;
    }

    void tick(MonoTime now)
    {
        foreach (ref e; _entries[])
        {
            final switch (e.state) with (NeighbourState)
            {
                case incomplete:
                    if (now - e.last_request < retry_interval_ms.msecs)
                        break;
                    if (e.retry_count >= max_retries)
                    {
                        e.state = NeighbourState.failed;
                        e.last_confirmed = now;     // repurposed as failure timestamp
                        free_pending(e);
                        break;
                    }
                    ++e.retry_count;
                    e.last_request = now;
                    if (send_request)
                        send_request(e.ip, e.iface);
                    break;

                case reachable:
                    if (now - e.last_confirmed >= reachable_time_ms.msecs)
                    {
                        e.state        = NeighbourState.stale;
                        e.last_request = now;       // arm probe interval
                        e.retry_count  = 0;
                    }
                    break;

                case stale:
                    if (now - e.last_request < stale_probe_interval_ms.msecs)
                        break;
                    if (e.retry_count >= max_stale_probes)
                    {
                        e.state          = NeighbourState.failed;
                        e.last_confirmed = now;
                        break;
                    }
                    ++e.retry_count;
                    e.last_request = now;
                    if (send_request)
                        send_request(e.ip, e.iface);
                    break;

                case failed:
                    break;
            }
        }

        // GC failed entries past their lifetime; iterate in reverse for swap-remove safety
        for (size_t i = _entries.length; i > 0; --i)
        {
            size_t idx = i - 1;
            auto e = &_entries[idx];
            if (e.state == NeighbourState.failed
                && now - e.last_confirmed >= failed_lifetime_ms.msecs)
            {
                free_pending(*e);
                _entries.removeSwapLast(idx);
            }
        }
    }

    auto entries() inout pure
        => _entries[];

private:
    void queue_pending(ref NeighbourEntry!IP e, ref Packet pkt)
    {
        free_pending(e);
        e.pending = pkt.clone();
    }

    void free_pending(ref NeighbourEntry!IP e)
    {
        if (!e.pending)
            return;
        e.pending.free_clone();
        e.pending = null;
    }

    void drain_pending(ref NeighbourEntry!IP e)
    {
        if (!e.pending || !drain)
        {
            free_pending(e);
            return;
        }
        drain(*e.pending, e.iface, e.link_addr[0 .. e.link_addr_len]);
        free_pending(e);
    }

    Array!(NeighbourEntry!IP) _entries;
}
