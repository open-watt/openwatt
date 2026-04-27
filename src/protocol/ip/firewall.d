module protocol.ip.firewall;

import urt.array;

import router.iface.packet;

nothrow @nogc:


enum HookPoint : ubyte
{
    prerouting,     // just after ingress, before route lookup (DNAT, mangle)
    input,          // routed to us, before deliver_local
    forward,        // routed through us, before egress
    output,         // locally generated, before route lookup
    postrouting,    // after route, before frame_and_send (SNAT, mangle)
    _count,
}


enum Verdict : ubyte
{
    accept,
    drop,
    // TODO: queue (defer to userspace / async), repeat, stolen
}


// A single rule: match + action. Match terms are TODO (5-tuple, iface, mark, ...).
struct Rule
{
    // TODO: PacketMatch match;
    // TODO: Action action;  // accept/drop/jump/nat/mark
}


struct Chain
{
    Array!Rule rules;
    Verdict policy = Verdict.accept;
}


struct FirewallChains
{
nothrow @nogc:

    Verdict run(HookPoint where, ref Packet pkt)
    {
        // TODO: walk chains[where].rules, return on first terminal verdict
        return Verdict.accept;
    }

private:
    Chain[HookPoint._count] chains;
}
