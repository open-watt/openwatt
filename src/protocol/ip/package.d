module protocol.ip;

import urt.inet;
import urt.mem.temp;
import urt.string;
import urt.log;

import manager.collection;
import manager.console;
import manager.plugin;

import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip.route;
import protocol.ip.stack;

import router.iface;
import router.iface.ethernet;

public import protocol.ip.stack : IPStack;

version(Windows)
{
    import urt.array;
    import urt.internal.sys.windows.winsock2 : AF_INET, sockaddr_in;
    import manager.os.iphlpapi;
    import driver.windows.ethernet : WindowsPcapEthernet;
    import driver.windows.wifi : WindowsWifiRadio, WindowsWlan;
}

nothrow @nogc:


// =============================================================================
// Known limitations / TODOs across the IP stack
// =============================================================================
//
// TCP (protocol/ip/tcp.d)
//   - No congestion control: cwnd is effectively peer's rwnd. No Reno/CUBIC.
//   - No fast retransmit / SACK / DSACK / window scaling / timestamps. Options
//     are parsed but only MSS is honoured.
//   - No Nagle / delayed ACK. Every accepted segment is ACKed individually.
//   - No RTT estimation (Jacobson/Karn). Fixed initial RTO 1s, doubling on
//     retry, capped at 60s, give up after 5 retries.
//   - No out-of-order recv buffer: OOO segments are dropped and re-ACKed.
//   - No FIN_WAIT_2 timeout: bounded leak per stuck half-close.
//   - No zero-window probe: when peer's window closes we just stop sending.
//   - ISS generation is not cryptographic (RFC 6528).
//
// UDP (protocol/ip/udp.d)
//   - Single-slot recv queue cap (16); newest dropped on overflow.
//   - No fragmentation; datagrams larger than MTU are refused at output.
//
// ICMP (protocol/ip/icmp.d)
//   - No rate limiting (RFC 1812 says ~1/sec per type).
//   - No PMTU plumbing (frag_needed errors not generated; received ones not
//     fed to TCP for path-MTU adjustment).
//   - time_exceeded not generated: forwarding TTL decrement isn't wired.
//
// Routing / forwarding
//   - Forwarding TTL decrement and TTL-zero handling not implemented.
//   - No source-address selection per RFC 6724 (we pick the first IPAddress
//     on the egress iface).
//   - Per-egress metric / multipath: model allows it, lookup doesn't.
//   - Implicit-connected fallback in route_lookup_v4_dst is a HACK; we should
//     either keep it or require explicit routes -- decide.
//
// Neighbour cache (protocol/ip/neighbour.d)
//   - Single-slot pending-packet queue per entry (replaces older on overflow).
//   - tick(): no aging of reachable -> stale, no entry expiry.
//   - No NUD probe.
//
// IPv6
//   - ingress_v6 is a stub: no header validation, no extension-header walk,
//     no reassembly, no route lookup, no output, no ND.
//   - 6LoWPAN frame handler not registered (PacketType._6lowpan).
//
// Fragmentation
//   - v4 fragments are dropped at ingress (no reassembly).
//   - Egress doesn't fragment; oversized datagrams are dropped (TCP segments
//     by MSS so this only bites UDP/raw).
//
// Sockets (protocol/ip/socket.d)
//   - DNS / get_address_info stubbed (pure IP-based addressing for now).
//   - No SO_ERROR readback for non-blocking connect completion. Apps poll
//     PollEvents.write to detect connect.
//   - Most SocketOption values are accepted but no-op.
//   - Raw sockets not implemented.
//
// Bridging / VLAN
//   - IP stack and bridges share primary dispatch on a port; bind-time check
//     warns. No automatic rebind to bridge-as-iface flow.
//
// Diagnostics / console
//   - No /protocol/ip/tcp print or /protocol/ip/neighbour print commands.
//   - Route / address tables print via their Collections, but no live socket
//     or PCB introspection.
//
// =============================================================================


class IPModule : Module
{
    mixin DeclareModule!"protocol.ip";
nothrow @nogc:

    override void pre_init()
    {
        version (UseInternalIPStack)
        {
            import protocol.ip.socket : install_socket_backend;
            install_socket_backend(&_stack);
        }
    }

    override void init()
    {
        g_app.console.register_collection!IPAddress();
        g_app.console.register_collection!IPPool();
        g_app.console.register_collection!IPv6Pool();
        g_app.console.register_collection!IPRoute();

        _stack.init_resolvers();

        register_frame_handler(PacketType.ethernet, &_stack.on_packet);
        // TODO: register additional frame handlers when other L3 carriers land
        //       (PacketType._6lowpan, ppp/IPCP frame type, raw_ip tunnels).
    }

    version(Windows)
    void seed_from_windows()
    {
        if (!iphlpapi_loaded() || GetIpForwardTable2 is null)
            return;

        struct IfMapEntry { uint if_index; BaseInterface iface; }
        Array!IfMapEntry if_map;

        enumerate_os_adapters((IP_ADAPTER_ADDRESSES_LH* p) nothrow @nogc {
            const(char)[] guid = adapter_guid(p);
            if (guid.length == 0)
                return;

            BaseInterface iface;
            foreach (e; Collection!WindowsPcapEthernet().values)
            {
                if (parse_npf_guid(e.adapter) == guid)
                {
                    iface = cast(BaseInterface)e;
                    break;
                }
            }
            if (!iface)
            {
                foreach (w; Collection!WindowsWlan().values)
                {
                    auto r = cast(WindowsWifiRadio)w.radio;
                    if (r && parse_npf_guid(r.adapter) == guid)
                    {
                        iface = cast(BaseInterface)w;
                        break;
                    }
                }
            }
            if (!iface)
                return;

            if_map ~= IfMapEntry(p.IfIndex, iface);

            for (auto u = p.FirstUnicastAddress; u !is null; u = u.Next)
            {
                if (u.Address.lpSockaddr is null)
                    continue;
                ushort family = *cast(ushort*)u.Address.lpSockaddr;
                if (family != AF_INET)
                    continue;
                const sockaddr_in* sin = cast(const sockaddr_in*)u.Address.lpSockaddr;

                IPNetworkAddress net_addr;
                net_addr.addr.address = sin.sin_addr.s_addr;
                net_addr.prefix_len   = u.OnLinkPrefixLength;

                IPAddress ip = Collection!IPAddress().create(tconcat(iface.name, ".addr"));
                if (!ip)
                    continue;
                ip.address = net_addr;
                ip.iface   = iface;
            }
        });

        if (if_map.length == 0)
            return;

        enumerate_ipv4_routes((ref const IpForwardRowV4 r) nothrow @nogc {
            if (r.is_loopback)
                return;
            if (IPNetworkAddress.loopback.contains(r.destination.addr))
                return;
            if (IPNetworkAddress.linklocal.contains(r.destination.addr))
                return;
            if (IPNetworkAddress.multicast.contains(r.destination.addr))
                return;
            if (r.destination.prefix_len == 32)
                return;     // host routes (incl. 255.255.255.255) are stack-internal

            BaseInterface iface = null;
            foreach (ref m; if_map[])
            {
                if (m.if_index == r.if_index)
                {
                    iface = m.iface;
                    break;
                }
            }
            if (!iface)
                return;

            IPRoute rt = Collection!IPRoute().create(null);
            if (!rt)
                return;
            rt.destination = r.destination;
            if (r.gateway != IPAddr.any)
                rt.gateway = r.gateway;
            else
                rt.out_interface = iface;
            rt.distance = r.metric > 255 ? cast(ubyte)255 : cast(ubyte)r.metric;
        });
    }

    override void update()
    {
        Collection!IPAddress().update_all();
        Collection!IPPool().update_all();
        Collection!IPv6Pool().update_all();
        Collection!IPRoute().update_all();
        _stack.update();
    }

private:
    IPStack _stack;
}
