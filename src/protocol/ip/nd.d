module protocol.ip.nd;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.temp : tconcat;
import urt.time;

import manager.base;
import manager.collection;
import manager.expression : NamedArgument;
import manager.features : has_gateway;

import router.iface;
import router.iface.endpoint : foreach_ether_station;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip : IPv6Header, IPProtocol, ipv6_multicast_mac, load_ipv6_address, pseudo_header_checksum_v6, store_ipv6_address;
import protocol.ip.address;
import protocol.ip.icmp6 : Icmp6Type;
import protocol.ip.mld;
import protocol.ip.neighbour;
import protocol.ip.route;
import protocol.ip.stack;

//version = DebugND;

private alias log = Log!"nd";

nothrow @nogc:


enum NDOption : ubyte
{
    none             = 0,
    source_link_addr = 1,
    target_link_addr = 2,
    prefix_info      = 3,
    redirected_hdr   = 4,
    mtu              = 5,
}


IPv6Addr solicited_node(IPv6Addr address) pure
    => IPv6Addr(0xFF02, 0, 0, 0, 0, 1, 0xFF00 | (address.s[6] & 0xFF), address.s[7]);

IPv6Addr link_local_for(MACAddress mac) pure
{
    IPv6Addr address;
    address.s[0] = 0xFE80;
    address.s[4] = cast(ushort)((mac.b[0] ^ 0x02) << 8 | mac.b[1]);
    address.s[5] = cast(ushort)(mac.b[2] << 8 | 0xFF);
    address.s[6] = cast(ushort)(0xFE00 | mac.b[3]);
    address.s[7] = cast(ushort)(mac.b[4] << 8 | mac.b[5]);
    return address;
}

IPv6Addr link_local_of(BaseInterface iface)
{
    foreach (address; Collection!IPv6Address().values)
        if (address.iface is iface && address.address.addr.is_link_local)
            return address.address.addr;
    return IPv6Addr.any;
}

bool is_our_ip_v6(IPv6Addr ip, BaseInterface iface)
{
    foreach (address; Collection!IPv6Address().values)
        if (address.iface is iface && address.address.addr == ip)
            return true;
    return false;
}

void send_neighbour_solicit(ref IPStack stack, IPv6Addr target, EthernetStation iface)
{
    IPv6Addr source = source_for_target(target, iface);
    if (source == IPv6Addr.any)
        return;
    IPv6Addr destination = solicited_node(target);

    align(size_t.sizeof) ubyte[IPv6Header.sizeof + 32] buffer = void;
    size_t message_length = build_ns_na(buffer[], Icmp6Type.neighbour_solicit, 0, source, destination, target, iface.mac, NDOption.source_link_addr);

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "solicit who-has ", target, " on ", iface.name, " (src=", source, ")");

    iface.send(ipv6_multicast_mac(destination), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
}

void on_neighbour_solicit(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] message, BaseInterface iface, ref const Packet packet)
{
    EthernetStation station = dyn_cast!EthernetStation(iface);
    if (!station || packet.type != PacketType.ethernet || message.length < 24 || ip.hop_limit != 255 || message[1] != 0)
        return;
    const(ubyte)[] options = message[24 .. $];
    if (!valid_options(options))
        return;

    IPv6Addr target = load_ipv6_address(message.ptr + 8);
    if (target.is_multicast)
        return;
    IPv6Addr source = ip.src_addr;
    const(ubyte)[] source_link_address = find_option(options, NDOption.source_link_addr);
    if (source_link_address.length != 0 && source_link_address.length != 6)
        return;

    version (DebugND)
        write_log(Severity.trace, "nd", null, "rx solicit for ", target, " from ", source, " on ", iface.name);

    if (source == IPv6Addr.any)
    {
        if (ip.dst_addr != solicited_node(target) || source_link_address.length != 0)
            return;
        if (packet.hdr!Ethernet.src == station.mac)
            return;
        if (defeat_dad(stack, target, iface) || slaac_dad_defeat(stack, target, iface))
            return;
        if (is_our_ip_v6(target, iface))
            send_neighbour_advert(stack, target, IPv6Addr.linkLocal_allNodes, station, false, null);
        return;
    }

    if (ip.dst_addr.is_multicast && ip.dst_addr != solicited_node(target))
        return;
    if (ip.dst_addr.is_multicast && source_link_address.length == 0)
        return;
    if (!is_our_ip_v6(target, iface))
        return;
    if (source_link_address.length)
        stack.neighbour_v6_cache.observe(source, iface, source_link_address);

    MACAddress destination = packet.hdr!Ethernet.src;
    send_neighbour_advert(stack, target, source, station, true, &destination);
}

void on_neighbour_advert(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] message, BaseInterface iface)
{
    if (!iface || message.length < 24 || ip.hop_limit != 255 || message[1] != 0 || ip.src_addr == IPv6Addr.any)
        return;
    const(ubyte)[] options = message[24 .. $];
    if (!valid_options(options))
        return;

    IPv6Addr target = load_ipv6_address(message.ptr + 8);
    if (target.is_multicast)
        return;
    uint flags = loadBigEndian(cast(const(uint)*)(message.ptr + 4));
    bool router = (flags & 0x8000_0000) != 0;
    bool solicited = (flags & 0x4000_0000) != 0;
    bool override_ = (flags & 0x2000_0000) != 0;
    if (solicited && ip.dst_addr.is_multicast)
        return;

    const(ubyte)[] target_link_address = find_option(options, NDOption.target_link_addr);
    if (target_link_address.length != 0 && target_link_address.length != 6)
        return;
    if (defeat_dad(stack, target, iface) || slaac_dad_defeat(stack, target, iface))
        return;
    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx advert ", target, target_link_address.length == 6 ? " is-at tlla" : " (no tlla)", " on ", iface.name);

    stack.neighbour_v6_cache.advertise(target, iface, target_link_address, router, solicited, override_);
}

void on_router_advert(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] message, BaseInterface iface)
{
    EthernetStation station = dyn_cast!EthernetStation(iface);
    if (!station || message.length < 16 || message[1] != 0 || ip.hop_limit != 255 || !ip.src_addr.is_link_local)
        return;
    const(ubyte)[] options = message[16 .. $];
    if (!valid_options(options))
        return;
    IPv6Addr router = ip.src_addr;

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx router-advert from ", router, " on ", iface.name);

    MonoTime now = getTime();
    SlaacIface* state = slaac_iface_state(station);
    state.ra_seen = link_local_of(station) != IPv6Addr.any;

    ra_router(station, router, loadBigEndian(cast(const(ushort)*)(message.ptr + 6)), now);

    while (options.length)
    {
        size_t length = options[1] * 8;
        switch (options[0])
        {
            case NDOption.source_link_addr:
                if (length == 8)
                    stack.neighbour_v6_cache.observe(router, iface, options[2 .. 8]);
                break;
            case NDOption.prefix_info:
                if (length == 32)
                    ra_prefix(stack, station, options[0 .. 32], now);
                break;
            default:
                break;
        }
        options = options[length .. $];
    }
}

void slaac_update(ref IPStack stack, MonoTime now)
{
    foreach_ether_station((EthernetStation station) {
        SlaacIface* state = slaac_iface_state(station);
        if (!station.running)
        {
            if (state.online)
                retire_slaac(stack, station);
            state.online = false;
            state.rs_sent = 0;
            state.ra_seen = false;
            return;
        }
        if (!state.online || state.mac != station.mac)
        {
            if (state.online)
                retire_slaac(stack, station);
            state.online = true;
            state.mac = station.mac;
            state.rs_sent = 0;
            state.ra_seen = false;
        }
        IPv6Addr source = link_local_of(station);
        if (source == IPv6Addr.any || state.ra_seen || state.rs_sent >= max_rtr_solicitations)
            return;
        if (state.rs_sent != 0 && now - state.last_rs < rtr_solicitation_interval)
            return;
        ++state.rs_sent;
        state.last_rs = now;
        send_router_solicit(station, source);
    });

    for (size_t i = _slaac_prefixes.length; i > 0; --i)
    {
        ref prefix = _slaac_prefixes[i - 1];
        BaseInterface iface = prefix.iface.get;
        if (!iface || (iface.flags & ObjectFlags.slave) || now >= prefix.valid_until)
        {
            remove_slaac_prefix(stack, i - 1);
            continue;
        }
        if (iface.running && prefix.dad_in_flight && now - prefix.dad_sent >= dad_window)
        {
            prefix.dad_in_flight = false;
            create_slaac_address(prefix);
        }
    }

    for (size_t i = _slaac_routers.length; i > 0; --i)
    {
        ref router = _slaac_routers[i - 1];
        BaseInterface iface = router.iface.get;
        if (!iface || (iface.flags & ObjectFlags.slave) || now >= router.expires)
        {
            if (IPv6Route route = router.route.get)
                route.destroy();
            _slaac_routers.removeSwapLast(i - 1);
        }
    }

    for (size_t i = _slaac_ifaces.length; i > 0; --i)
    {
        EthernetStation station = _slaac_ifaces[i - 1].iface.get;
        if (!station)
            _slaac_ifaces.removeSwapLast(i - 1);
        else if ((station.flags & ObjectFlags.slave) && _slaac_ifaces[i - 1].online)
        {
            retire_slaac(stack, station);
            _slaac_ifaces[i - 1].online = false;
            _slaac_ifaces[i - 1].rs_sent = 0;
            _slaac_ifaces[i - 1].ra_seen = false;
        }
    }
}

void nd_update(ref IPStack stack, MonoTime now)
{
    update_link_locals(stack, now);
    update_address_memberships(stack);
}


private:

enum ubyte max_rtr_solicitations     = 3;
enum Duration rtr_solicitation_interval = 4.seconds;
enum Duration dad_window             = 1.seconds;
enum uint max_lifetime_s             = 0x00FF_FFFF;     // clamp; routers re-advertise long before this

struct SlaacIface
{
    ObjectRef!EthernetStation iface;
    MonoTime last_rs;
    MACAddress mac;
    ubyte rs_sent;
    bool ra_seen;
    bool online;
}

struct SlaacPrefix
{
    IPv6Addr prefix;
    IPv6Addr formed;
    MonoTime valid_until;
    MonoTime dad_sent;
    ObjectRef!BaseInterface iface;
    ObjectRef!IPv6Address address;
    bool dad_in_flight;
    bool duplicate;
    bool joined;
}

struct SlaacRouter
{
    IPv6Addr router;
    MonoTime expires;
    ObjectRef!BaseInterface iface;
    ObjectRef!IPv6Route route;
}

__gshared Array!SlaacIface  _slaac_ifaces;
__gshared Array!SlaacPrefix _slaac_prefixes;
__gshared Array!SlaacRouter _slaac_routers;

SlaacIface* slaac_iface_state(EthernetStation iface)
{
    foreach (ref state; _slaac_ifaces[])
        if (state.iface.get is iface)
            return &state;
    SlaacIface state;
    state.iface = iface;
    _slaac_ifaces ~= state;
    return &_slaac_ifaces[$ - 1];
}

void send_router_solicit(EthernetStation iface, IPv6Addr source)
{
    enum size_t message_length = 16;
    align(size_t.sizeof) ubyte[IPv6Header.sizeof + message_length] buffer = void;

    auto header = cast(IPv6Header*)buffer.ptr;
    header.ver_tc_flow[] = 0;
    header.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)header.payload_length.ptr, ushort(message_length));
    header.next_header = IPProtocol.icmp6;
    header.hop_limit = 255;
    header.src_addr = source;
    header.dst_addr = IPv6Addr.linkLocal_routers;

    ubyte* message = buffer.ptr + IPv6Header.sizeof;
    message[0 .. message_length] = 0;
    message[0] = Icmp6Type.router_solicit;
    message[8] = NDOption.source_link_addr;
    message[9] = 1;
    message[10 .. 16] = iface.mac.b[];

    ushort pseudo = pseudo_header_checksum_v6(header.src, header.dst, uint(message_length), IPProtocol.icmp6);
    storeBigEndian(cast(ushort*)(message + 2), internet_checksum(message[0 .. message_length], pseudo));

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "solicit routers on ", iface.name);

    iface.send(ipv6_multicast_mac(IPv6Addr.linkLocal_routers), buffer[], EtherType.ip6);
}

void ra_router(EthernetStation iface, IPv6Addr router, ushort lifetime, MonoTime now)
{
    foreach (i, ref state; _slaac_routers[])
    {
        if (state.router == router && state.iface.get is iface)
        {
            if (lifetime == 0)
            {
                if (IPv6Route route = state.route.get)
                    route.destroy();
                _slaac_routers.removeSwapLast(i);
            }
            else
            {
                state.expires = now + lifetime.seconds;
                if (!state.route)
                    state.route = create_default_route(iface, router);
            }
            return;
        }
    }
    if (lifetime == 0)
        return;

    SlaacRouter state;
    state.router = router;
    state.iface = iface;
    state.expires = now + lifetime.seconds;
    state.route = create_default_route(iface, router);
    if (!state.route)
    {
        log.error("failed to create dynamic default route");
        return;
    }
    _slaac_routers ~= state;
    log.info("default route via ", router, " on ", iface.name, " (lifetime ", lifetime, "s)");
}

IPv6Route create_default_route(EthernetStation iface, IPv6Addr router)
{
    const(char)[] name = Collection!IPv6Route().generate_name(tconcat(iface.name[], ".ra"));
    return Collection!IPv6Route().create(name, ObjectFlags.dynamic, NamedArgument("destination", IPv6NetworkAddress(IPv6Addr.any, 0)),
                                         NamedArgument("gateway", router), NamedArgument("out-interface", cast(BaseInterface)iface));
}

void ra_prefix(ref IPStack stack, EthernetStation iface, const(ubyte)[] option, MonoTime now)
{
    ubyte prefix_length = option[2];
    if (!(option[3] & 0x40))
        return;
    uint valid = loadBigEndian(cast(const(uint)*)(option.ptr + 4));
    IPv6Addr prefix = load_ipv6_address(option.ptr + 16);
    if (prefix.is_link_local || prefix.is_multicast)
        return;
    if (prefix_length != 64)
    {
        log.warning("ignoring RA prefix ", prefix, "/", prefix_length, ": SLAAC needs a /64 for the interface identifier");
        return;
    }
    if (valid > max_lifetime_s)
        valid = max_lifetime_s;
    foreach (i, ref state; _slaac_prefixes[])
    {
        if (state.prefix != prefix || state.iface.get !is iface)
            continue;
        if (valid == 0)
            remove_slaac_prefix(stack, i);
        else
            state.valid_until = now + valid.seconds;
        return;
    }
    if (valid == 0)
        return;

    IPv6Addr link_local = link_local_of(iface);
    if (link_local == IPv6Addr.any)
        return;
    SlaacPrefix state;
    state.prefix = prefix;
    state.formed = prefix;
    state.formed.s[4 .. 8] = link_local.s[4 .. 8];
    state.valid_until = now + valid.seconds;
    state.dad_sent = now;
    state.iface = iface;
    state.dad_in_flight = true;
    state.joined = mld_join(stack, solicited_node(state.formed), iface);
    if (!state.joined)
        return;
    _slaac_prefixes ~= state;
    send_slaac_dad(iface, state.formed);
}

void send_slaac_dad(EthernetStation iface, IPv6Addr address)
{
    align(size_t.sizeof) ubyte[IPv6Header.sizeof + 24] buffer = void;
    size_t message_length = build_ns_na(buffer[], Icmp6Type.neighbour_solicit, 0, IPv6Addr.any, solicited_node(address), address, MACAddress(), NDOption.none);
    iface.send(ipv6_multicast_mac(solicited_node(address)), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
}

void create_slaac_address(ref SlaacPrefix state)
{
    if (state.duplicate)
        return;
    BaseInterface iface = state.iface.get;
    if (!iface)
        return;
    const(char)[] name = Collection!IPv6Address().generate_name(tconcat(iface.name[], ".slaac"));
    state.address = Collection!IPv6Address().create(name, ObjectFlags.dynamic, NamedArgument("address", IPv6NetworkAddress(state.formed, 64)), NamedArgument("interface", iface));
    if (!state.address)
    {
        state.dad_sent = getTime();
        state.dad_in_flight = true;
        log.error("failed to create dynamic IPv6Address");
        return;
    }
    log.info("SLAAC address ", state.formed, "/64 on ", iface.name);
}

bool slaac_dad_defeat(ref IPStack stack, IPv6Addr target, BaseInterface iface)
{
    foreach (ref state; _slaac_prefixes[])
    {
        if (!state.dad_in_flight || state.formed != target || state.iface.get !is iface)
            continue;
        state.dad_in_flight = false;
        state.duplicate = true;
        if (state.joined)
            mld_leave(stack, solicited_node(target), iface);
        state.joined = false;
        log.warning("DAD: ", target, " already in use on ", iface.name, "; address suppressed");
        return true;
    }
    return false;
}

void remove_slaac_prefix(ref IPStack stack, size_t index)
{
    ref state = _slaac_prefixes[index];
    BaseInterface iface = state.iface.get;
    if (IPv6Address address = state.address.get)
        address.destroy();
    if (state.joined && iface)
        mld_leave(stack, solicited_node(state.formed), iface);
    _slaac_prefixes.removeSwapLast(index);
}

void retire_slaac(ref IPStack stack, EthernetStation iface)
{
    for (size_t i = _slaac_prefixes.length; i > 0; --i)
        if (_slaac_prefixes[i - 1].iface.get is iface)
            remove_slaac_prefix(stack, i - 1);
    for (size_t i = _slaac_routers.length; i > 0; --i)
    {
        if (_slaac_routers[i - 1].iface.get !is iface)
            continue;
        if (IPv6Route route = _slaac_routers[i - 1].route.get)
            route.destroy();
        _slaac_routers.removeSwapLast(i - 1);
    }
}

enum LinkLocalPhase : ubyte
{
    down,
    tentative,
    duplicate,
    assigned,
}

struct LinkLocalState
{
    ObjectRef!EthernetStation iface;
    ObjectRef!IPv6Address address;
    MonoTime dad_started;
    IPv6Addr candidate;
    MACAddress mac;
    LinkLocalPhase phase;
    bool joined;
}

struct AddressMembership
{
    IPv6Addr group;
    ObjectRef!IPv6Address address;
    ObjectRef!BaseInterface iface;
}

__gshared Array!LinkLocalState _link_locals;
__gshared Array!AddressMembership _address_memberships;

void update_link_locals(ref IPStack stack, MonoTime now)
{
    foreach_ether_station((EthernetStation station) {
        LinkLocalState* state = link_local_state(station);
        if (!station.running)
        {
            stop_link_local(stack, *state);
            return;
        }
        if (state.phase == LinkLocalPhase.down || state.mac != station.mac || (state.phase == LinkLocalPhase.assigned && !state.address))
        {
            stop_link_local(stack, *state);
            start_link_local(stack, *state, station, now);
            return;
        }
        if (state.phase == LinkLocalPhase.tentative && now - state.dad_started >= dad_window)
            assign_link_local(*state, station, now);
    });

    for (size_t i = _link_locals.length; i > 0; --i)
    {
        ref state = _link_locals[i - 1];
        EthernetStation station = state.iface.get;
        if (!station)
        {
            if (IPv6Address address = state.address.get)
                address.destroy();
            _link_locals.removeSwapLast(i - 1);
        }
        else if ((station.flags & ObjectFlags.slave) && state.phase != LinkLocalPhase.down)
            stop_link_local(stack, state);
    }
}

LinkLocalState* link_local_state(EthernetStation iface)
{
    foreach (ref state; _link_locals[])
        if (state.iface.get is iface)
            return &state;
    LinkLocalState state;
    state.iface = iface;
    _link_locals ~= state;
    return &_link_locals[$ - 1];
}

void start_link_local(ref IPStack stack, ref LinkLocalState state, EthernetStation iface, MonoTime now)
{
    state.mac = iface.mac;
    state.candidate = link_local_for(iface.mac);
    state.phase = LinkLocalPhase.tentative;
    state.dad_started = now;
    state.joined = mld_join(stack, solicited_node(state.candidate), iface);

    align(size_t.sizeof) ubyte[IPv6Header.sizeof + 24] buffer = void;
    size_t message_length = build_ns_na(buffer[], Icmp6Type.neighbour_solicit, 0, IPv6Addr.any, solicited_node(state.candidate), state.candidate, MACAddress(), NDOption.none);
    iface.send(ipv6_multicast_mac(solicited_node(state.candidate)), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
}

void stop_link_local(ref IPStack stack, ref LinkLocalState state)
{
    EthernetStation iface = state.iface.get;
    if (IPv6Address address = state.address.get)
        address.destroy();
    if (state.joined && iface)
        mld_leave(stack, solicited_node(state.candidate), iface);
    state.address = null;
    state.candidate = IPv6Addr.any;
    state.phase = LinkLocalPhase.down;
    state.joined = false;
}

void assign_link_local(ref LinkLocalState state, EthernetStation iface, MonoTime now)
{
    const(char)[] name = Collection!IPv6Address().generate_name(tconcat(iface.name[], ".ll"));
    state.address = Collection!IPv6Address().create(name, ObjectFlags.dynamic, NamedArgument("address", IPv6NetworkAddress(state.candidate, 64)), NamedArgument("interface", cast(BaseInterface)iface));
    if (!state.address)
    {
        state.dad_started = now;
        log.error("failed to create link-local IPv6Address for ", iface.name);
        return;
    }
    state.phase = LinkLocalPhase.assigned;
}

bool defeat_dad(ref IPStack stack, IPv6Addr target, BaseInterface iface)
{
    foreach (ref state; _link_locals[])
    {
        if (state.phase != LinkLocalPhase.tentative || state.candidate != target || state.iface.get !is iface)
            continue;
        state.phase = LinkLocalPhase.duplicate;
        if (state.joined)
            mld_leave(stack, solicited_node(target), iface);
        state.joined = false;
        log.warning("DAD: ", target, " already in use on ", iface.name, "; address suppressed");
        return true;
    }
    return false;
}

void update_address_memberships(ref IPStack stack)
{
    for (size_t i = _address_memberships.length; i > 0; --i)
    {
        ref membership = _address_memberships[i - 1];
        IPv6Address address = membership.address.get;
        BaseInterface iface = membership.iface.get;
        if (!address || !iface || !iface.running || (iface.flags & ObjectFlags.slave) || address.iface !is iface || solicited_node(address.address.addr) != membership.group)
        {
            if (iface)
                mld_leave(stack, membership.group, iface);
            _address_memberships.removeSwapLast(i - 1);
        }
    }

    foreach (address; Collection!IPv6Address().values)
    {
        BaseInterface iface = address.iface;
        if (!iface || !iface.running || (iface.flags & ObjectFlags.slave) || managed_link_local(address))
            continue;
        bool found;
        foreach (ref membership; _address_memberships[])
        {
            if (membership.address.get is address)
            {
                found = true;
                break;
            }
        }
        if (found)
            continue;

        AddressMembership membership;
        membership.group = solicited_node(address.address.addr);
        membership.address = address;
        membership.iface = iface;
        if (mld_join(stack, membership.group, iface))
            _address_memberships ~= membership;
    }
}

bool managed_link_local(IPv6Address address)
{
    foreach (ref state; _link_locals[])
        if (state.address.get is address)
            return true;
    return false;
}

size_t build_ns_na(ubyte[] buffer, Icmp6Type type, uint flags, IPv6Addr source, IPv6Addr destination, IPv6Addr target, MACAddress link_address, NDOption option)
{
    size_t message_length = option == NDOption.none ? 24 : 32;
    auto header = cast(IPv6Header*)buffer.ptr;
    header.ver_tc_flow[] = 0;
    header.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)header.payload_length.ptr, cast(ushort)message_length);
    header.next_header = IPProtocol.icmp6;
    header.hop_limit = 255;
    header.src_addr = source;
    header.dst_addr = destination;

    ubyte* message = buffer.ptr + IPv6Header.sizeof;
    message[0 .. message_length] = 0;
    message[0] = type;
    storeBigEndian(cast(uint*)(message + 4), flags);
    store_ipv6_address(message + 8, target);
    if (option != NDOption.none)
    {
        message[24] = option;
        message[25] = 1;
        message[26 .. 32] = link_address.b[];
    }

    ushort pseudo = pseudo_header_checksum_v6(header.src, header.dst, cast(uint)message_length, IPProtocol.icmp6);
    storeBigEndian(cast(ushort*)(message + 2), internet_checksum(message[0 .. message_length], pseudo));
    return message_length;
}

void send_neighbour_advert(ref IPStack stack, IPv6Addr target, IPv6Addr destination, EthernetStation iface, bool solicited, const(MACAddress)* direct)
{
    enum uint flag_router = 0x8000_0000;
    enum uint flag_solicited = 0x4000_0000;
    enum uint flag_override = 0x2000_0000;
    uint flags = flag_override | (solicited ? flag_solicited : 0);
    static if (has_gateway)
        flags |= flag_router;

    align(size_t.sizeof) ubyte[IPv6Header.sizeof + 32] buffer = void;
    size_t message_length = build_ns_na(buffer[], Icmp6Type.neighbour_advert, flags, target, destination, target, iface.mac, NDOption.target_link_addr);

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "advert ", target, " is-at ", iface.mac, " on ", iface.name);

    if (destination.is_multicast)
        iface.send(ipv6_multicast_mac(destination), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
    else if (direct)
        iface.send(*direct, buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
    else if (auto entry = stack.neighbour_v6_cache.find(destination, iface))
    {
        if (entry.link_addr_len < MACAddress.sizeof)
            return;
        MACAddress mac;
        mac.b[] = entry.link_addr[0 .. MACAddress.sizeof];
        iface.send(mac, buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
    }
}

IPv6Addr source_for_target(IPv6Addr target, BaseInterface iface)
{
    foreach (address; Collection!IPv6Address().values)
        if (address.iface is iface && address.address.contains(target))
            return address.address.addr;
    return link_local_of(iface);
}

bool valid_options(const(ubyte)[] options) pure
{
    while (options.length)
    {
        if (options.length < 8)
            return false;
        size_t length = options[1] * 8;
        if (length == 0 || length > options.length)
            return false;
        options = options[length .. $];
    }
    return true;
}

const(ubyte)[] find_option(const(ubyte)[] options, NDOption type) pure
{
    while (options.length >= 8)
    {
        size_t length = options[1] * 8;
        if (length == 0 || length > options.length)
            return null;
        if (options[0] == type)
            return options[2 .. length];
        options = options[length .. $];
    }
    return null;
}


unittest
{
    IPv6Addr address = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0x1234, 0x5678);
    assert(solicited_node(address) == IPv6Addr(0xFF02, 0, 0, 0, 0, 1, 0xFF34, 0x5678));

    MACAddress mac = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55);
    assert(link_local_for(mac) == IPv6Addr(0xFE80, 0, 0, 0, 0x0211, 0x22FF, 0xFE33, 0x4455));

    ubyte[24] options;
    options[0] = 14;
    options[1] = 1;
    options[8] = NDOption.target_link_addr;
    options[9] = 1;
    options[10 .. 16] = mac.b[];
    options[16] = NDOption.source_link_addr;
    assert(!valid_options(options[]));
    assert(find_option(options[], NDOption.target_link_addr) == mac.b[]);
}
