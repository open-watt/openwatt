module driver.linux.bridge;

version (KernelMirror):

// Kernel-bridge offload (docs/LINUX_DATAPLANE.md Phase 3). When an OpenWatt
// BridgeInterface has >=2 kernel-netdev members (LinuxRawEthernet), build a real
// Linux bridge br-<name>, enslave those members so the KERNEL switches them in
// the data plane, idle their userspace RX, and keep one AF_PACKET "CPU port" on
// br-<name> as OpenWatt's window for L3 / management / sniffing. OpenWatt is the
// control plane; the kernel is the data plane.
//
// Non-netdev members (Modbus/CAN ...) stay software-switched on the bridge; they
// live in disjoint PacketType address sub-domains, so today nothing crosses
// between the kernel ethernet segment and those members (a non-ethernet frame
// can't be emitted on an ethernet port yet). The cross-domain forwarding shape is
// reserved (the CPU-port flood seam in bridge.d) but inert.
//
// Ownership discipline (mirrors RTPROT_OPENWATT for routes): we only ever delete
// br-* we created and only detach members we enslaved -- tracked in the ledger.

import urt.array;
import urt.endian;
import urt.log;
import urt.mem;
import urt.result;
import urt.time;

import manager.base;
import manager.features;
import manager.plugin;

import router.iface;
import router.iface.bridge;
import router.iface.ethernet : EthernetInterface;

import driver.linux.ethernet : LinuxRawEthernet;
import driver.linux.netlink_write;
import driver.linux.raw;

static if (has_ip)
    import protocol.ip.linux_mirror : mirror_refresh_interface;

nothrow @nogc:


class LinuxBridgeOffloadModule : Module
{
    mixin DeclareModule!"interface.bridge.linux";
nothrow @nogc:

    override void init()
    {
        register_object_state_handler(&on_object_state);
        register_bridge_offload_hooks(&on_member_added, &on_cpu_promisc_changed);
    }

    override void update()
    {
        foreach (o; _offloads[])
        {
            if (!o.engaged || !o.cpu.valid)
                continue;
            drain_cpu(o);
        }
    }

private:

    struct Offload
    {
    nothrow @nogc:
        BridgeInterface bridge;
        int br_ifindex;
        RawAdapter cpu;
        Array!LinuxRawEthernet netdevs;
        bool engaged;

        // CpuPortSink: frame an ethernet packet to the wire and push it into the
        // kernel-switched segment. Non-ethernet sub-domains can't traverse a kernel
        // bridge (yet), so they're dropped here -- this is the egress half of the
        // inert cross-domain seam.
        int inject(ref Packet packet)
        {
            if (packet.type != PacketType.ethernet)
                return -1;

            // Mirror EthernetInterface.send (ethernet case). TODO: factor out a
            // shared framing helper so this isn't a second copy.
            ubyte[1518] buffer = void;
            Ethernet* eth = cast(Ethernet*)buffer.ptr;
            eth.dst = packet.eth.dst;
            eth.src = packet.eth.src;
            ushort* ethertype = &eth.ether_type;
            if (packet.vlan)
            {
                storeBigEndian(ethertype++, ushort(EtherType.vlan));
                storeBigEndian(ethertype++, packet.vlan);
            }
            storeBigEndian(ethertype++, packet.eth.ether_type);

            ubyte* payload = cast(ubyte*)ethertype;
            size_t avail = buffer.sizeof - (payload - buffer.ptr);
            if (packet.data.length > avail)
                return -1;
            payload[0 .. packet.data.length] = cast(const(ubyte)[])packet.data[];
            size_t frame_len = (payload + packet.data.length) - buffer.ptr;

            return cpu.send(buffer[0 .. frame_len]) ? 0 : -1;
        }
    }

    Array!(Offload*) _offloads;

    Offload* find(BridgeInterface bridge)
    {
        foreach (o; _offloads[])
            if (o.bridge is bridge)
                return o;
        return null;
    }

    void on_object_state(ActiveObject obj, StateSignal sig)
    {
        BridgeInterface bridge = cast(BridgeInterface)obj;
        if (!bridge)
            return;

        final switch (sig)
        {
            case StateSignal.online:
                engage(bridge);
                break;
            case StateSignal.offline:
            case StateSignal.destroyed:
                disengage(bridge);
                break;
        }
    }

    void on_member_added(BridgeInterface bridge, BaseInterface member)
    {
        Offload* o = find(bridge);
        if (o && o.engaged)
        {
            if (LinuxRawEthernet eth = cast(LinuxRawEthernet)member)
                enslave(o, eth);
            else if (cast(EthernetInterface)member)
            {
                // the kernel segment can't forward to a software ethernet member;
                // fall back to full software bridging
                log_info(ModuleName, "bridge '", bridge.name[], "': software ethernet member '", member.name[], "' added; tearing down kernel offload");
                disengage(bridge);
                return;
            }
            // a netdev or new software member can change the promisc requirement
            cpu_set_promisc(o);
            return;
        }

        // Not yet offloaded: a newly-added netdev member may now make the bridge
        // qualify (>=2 netdev members). engage() re-checks and is a no-op otherwise.
        engage(bridge);
    }

    void on_cpu_promisc_changed(BridgeInterface bridge)
    {
        if (Offload* o = find(bridge))
            cpu_set_promisc(o);
    }

    void engage(BridgeInterface bridge)
    {
        if (find(bridge))
            return;     // already engaged

        if (bridge.vlan_filtering)
        {
            log_info(ModuleName, "bridge '", bridge.name[], "': VLAN-filtering bridges are not offloaded yet");
            return;
        }

        // qualify: >=2 netdev members, and no software ethernet members -- the
        // kernel segment can't forward to those (the CPU port only dispatches
        // locally), so offloading would silently split the bridge
        size_t netdev_members = 0;
        foreach (i; 0 .. bridge.member_count)
        {
            BaseInterface m = bridge.member_iface(i);
            if (cast(LinuxRawEthernet)m)
                ++netdev_members;
            else if (cast(EthernetInterface)m)
            {
                log_info(ModuleName, "bridge '", bridge.name[], "': software ethernet member '", m.name[], "' prevents kernel offload");
                return;
            }
        }
        if (netdev_members < 2)
            return;

        char[15] nb = void;
        const(char)[] brname = make_br_name(bridge.name[], nb);

        int r = netlink_add_bridge(brname, bridge.mac.b);
        if (r != 0 && r != -17 /* -EEXIST: adopt a leftover from a prior run */)
        {
            log_error(ModuleName, "bridge '", bridge.name[], "': failed to create kernel bridge ", brname, " (", r, ")");
            return;
        }

        int br_ifindex = netlink_ifindex(brname);
        if (br_ifindex == 0)
        {
            log_error(ModuleName, "bridge '", bridge.name[], "': created ", brname, " but can't resolve its ifindex");
            return;
        }

        Offload* o = defaultAllocator.allocT!Offload();
        o.bridge = bridge;
        o.br_ifindex = br_ifindex;
        _offloads ~= o;

        foreach (i; 0 .. bridge.member_count)
        {
            if (LinuxRawEthernet eth = cast(LinuxRawEthernet)bridge.member_iface(i))
                enslave(o, eth);
        }

        netlink_set_link_up(br_ifindex, true);

        StringResult or = o.cpu.open(brname, false);   // non-promisc; sniffers flip it on demand
        if (or.failed)
        {
            // kernel switching still works; we just have no CPU window. Log and run degraded.
            log_error(ModuleName, "bridge '", bridge.name[], "': CPU port open(", brname, ") failed: ", or.message);
        }
        else
        {
            cpu_set_promisc(o);
            bridge.attach_cpu_port(&o.inject);
        }

        o.engaged = true;

        // The bridge now owns a kernel netdev; let the IP mirror place its IP/routes
        // on br-<name> (they exist already and won't otherwise re-trigger a push).
        bridge.set_kernel_ifindex(br_ifindex);
        static if (has_ip)
            mirror_refresh_interface(bridge);

        log_info(ModuleName, "bridge '", bridge.name[], "' offloaded to kernel ", brname, " (", netdev_members, " ports)");
    }

    void disengage(BridgeInterface bridge)
    {
        size_t idx = size_t.max;
        Offload* o;
        foreach (i, e; _offloads[])
        {
            if (e.bridge is bridge)
            {
                o = e;
                idx = i;
                break;
            }
        }
        if (!o)
            return;

        bridge.detach_cpu_port();
        bridge.set_kernel_ifindex(0);
        o.cpu.close();

        foreach (eth; o.netdevs[])
        {
            int mi = netlink_ifindex(eth.adapter);
            if (mi != 0)
                netlink_set_master(mi, 0);
            bridge.set_member_offloaded(eth, false);
            eth.set_enslaved(false);
        }

        // Deleting the bridge netdev reaps its kernel addresses/routes, so no
        // explicit mirror withdraw is needed; set_kernel_ifindex(0) above means a
        // later edit (or re-engage) resolves correctly.
        netlink_del_link(o.br_ifindex);

        o.netdevs.clear();
        _offloads.removeSwapLast(idx);
        defaultAllocator.freeT(o);

        log_info(ModuleName, "bridge '", bridge.name[], "' offload torn down");
    }

    void enslave(Offload* o, LinuxRawEthernet eth)
    {
        int mi = netlink_ifindex(eth.adapter);
        if (mi == 0)
        {
            log_error(ModuleName, "can't resolve ifindex for member ", eth.adapter, "; not enslaved");
            return;
        }
        int r = netlink_set_master(mi, o.br_ifindex);
        if (r != 0)
        {
            // RX-idling a member the kernel isn't switching would blackhole it
            log_error(ModuleName, "failed to enslave ", eth.adapter, " (", r, "); member stays software-switched");
            return;
        }
        netlink_set_link_up(mi, true);
        eth.set_enslaved(true);
        o.bridge.set_member_offloaded(eth, true);
        o.netdevs ~= eth;
    }

    void cpu_set_promisc(Offload* o)
    {
        if (o.cpu.valid)
            o.cpu.set_promisc(o.bridge.cpu_port_wants_promisc());
    }

    void drain_cpu(Offload* o)
    {
        while (true)
        {
            const(ubyte)[] data;
            uint wire_len;
            MonoTime ts;
            ubyte pkttype;
            int res = o.cpu.poll_ll(data, wire_len, ts, pkttype);
            if (res <= 0)
                break;

            // Drop our own injected frames the kernel echoes back to the socket.
            if (pkttype == PACKET_OUTGOING)
                continue;
            if (data.length < 14)
                continue;

            // Parse the ethernet header (mirror EthernetInterface.incoming_ethernet_frame
            // but without touching the package-private _offset: hand the L3 payload to
            // init!Ethernet and set the header fields from the wire).
            ref mac_hdr = *cast(const Ethernet*)data.ptr;
            Packet packet;
            ref eth = packet.init!Ethernet(data[14 .. $], ts);
            eth.dst = mac_hdr.dst;
            eth.src = mac_hdr.src;
            eth.ether_type = loadBigEndian(&mac_hdr.ether_type);

            o.bridge.cpu_port_incoming(packet);
        }
    }

    // "br-" + the bridge name, capped to IFNAMSIZ-1 (15) chars.
    static const(char)[] make_br_name(const(char)[] name, ref char[15] buf)
    {
        size_t n = 0;
        buf[n++] = 'b';
        buf[n++] = 'r';
        buf[n++] = '-';
        foreach (c; name)
        {
            if (n >= buf.length)
                break;
            buf[n++] = c;
        }
        return buf[0 .. n];
    }
}
