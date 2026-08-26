module router.iface.ethernet;

import urt.array;
import urt.endian;
import urt.log;
import urt.map;
import urt.rand : rand;
import urt.time;
import urt.util : min;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.endpoint : ether_neighbour_learn;

//version = DebugEthernetFlow;

nothrow @nogc:


size_t encode_ethernet_header(ref const Packet packet, ubyte[] buffer)
{
    VlanTag tag = packet.vlan_tag;
    if (tag == VlanTag.none && packet.vid != 0 && !packet.has_inline_vlan_tag)
        tag = VlanTag._8100;
    size_t required = 14 + (tag != VlanTag.none ? 4 : 0);
    if (packet.type != PacketType.ethernet || buffer.length < required)
        return 0;

    Ethernet* eth = cast(Ethernet*)buffer.ptr;
    eth.dst = packet.eth.dst;
    eth.src = packet.eth.src;
    ushort* ether_type = &eth.ether_type;
    if (tag != VlanTag.none)
    {
        storeBigEndian(ether_type++, vlan_tpid(tag));
        storeBigEndian(ether_type++, packet.vlan);
    }
    storeBigEndian(ether_type, packet.eth.ether_type);
    return required;
}


abstract class EthernetStation : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("cfm-level", cfm_level),
                                 Elem!("mac", MACAddress, Check!mac_check));
nothrow @nogc:

    final MACAddress mac() const
        => prop_read!(EthernetStation, "mac")();

    final const(char)[] mac_check(ref MACAddress value)
        => is_remote ? null : apply_mac(value);

    final int send(MACAddress dest, const(void)[] message, EtherType type, MessageCallback callback = null)
    {
        Packet p;
        ref eth = p.init!Ethernet(message);
        eth.src = mac;
        eth.dst = dest;
        eth.ether_type = type;
        return forward(p, callback);
    }

    // 802.1ag loopback at our maintenance level; the pending entry expires quietly after 10s unless cancelled
    final uint ping(MACAddress dst, MacPingHandler handler)
    {
        uint txid = _next_ping_txid++;
        ubyte[9] lbm = void;
        lbm[0] = cast(ubyte)(_cfm_level << 5);
        lbm[1] = cfm_opcode_lbm;
        lbm[2] = 0;
        lbm[3] = 4;  // first TLV offset: past the transaction id
        lbm[4 .. 8] = txid.nativeToBigEndian;
        lbm[8] = 0;  // End TLV
        _pending_pings ~= PendingPing(txid, getTime(), handler);
        send(dst, lbm, EtherType.cfm);
        return txid;
    }

    // txid comes from mac_discover_begin(); 0 sweeps for neighbour state with no reply correlation
    final void discover(uint txid, PacketType type = PacketType.unknown)
    {
        ubyte[6] query = void;
        query[0 .. 4] = txid.nativeToBigEndian;
        query[4 .. 6] = ushort(type).nativeToBigEndian;
        station_send_control(OWControl.addr_query, MACAddress.broadcast, query);
    }

    // Properties...

    ubyte cfm_level() const
        => _cfm_level;
    const(char)[] cfm_level(ubyte value)
    {
        if (value > 7)
            return "cfm level must be 0-7";
        _cfm_level = value;
        mark_set!(typeof(this), "cfm-level")();
        return null;
    }

    // OW announce: broadcast a peering beacon carrying this node's identity TLVs.
    // Received announces are delivered to the registered sink (set_announce_sink).
    final void announce(scope const(ubyte)[] tlv)
    {
        station_send_control(OWControl.announce, MACAddress.broadcast, tlv);
    }

protected:

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
        _caps |= InterfaceCaps.ethernet;
        mark_set!(typeof(this), "caps")();
    }

    // A station wears its driver's address: adopt_mac is how a driver reports one,
    // and a station with no hardware behind it synthesises one instead.
    final void adopt_mac(MACAddress value)
    {
        if (mac == value)
            return;
        const(char)[] error = prop_element(prop_index!(EthernetStation, "mac")).try_write(value);
        debug assert(error is null, error);
        if (error is null)
            mark_assigned!(EthernetStation, "mac")();
    }

    final void adopt_generated_mac()
    {
        adopt_mac(generate_mac_address(name[]));
    }

    // Push an operator-assigned address down to the driver; refusing it here
    // would leave the station addressed differently to the medium.
    const(char)[] apply_mac(ref MACAddress value)
    {
        return null;
    }

    // Egress seam toward the segment; takes a fully-formed ethernet packet.
    abstract void medium_tx(ref Packet packet);

    // Where locally-decapped exotic traffic enters: standalone = local delivery;
    // Bridge redirects this into its exotic switching domain.
    void station_deliver(ref Packet inner)
    {
        dispatch(inner);
    }

    override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        switch (packet.type)
        {
            case PacketType.ethernet:
                medium_tx(packet);
                return 0;

            case PacketType._6lowpan:
                assert(false, "TODO: reframe as ipv6?");

            default:
                // exotic frames are OW-encapsulated for transit across the segment
                if (!station_egress(packet))
                    add_tx_drop();
                return 0;
        }
    }

    override void ingress(ref Packet packet)
    {
        if (!packet.consume_priority_tags())
        {
            add_rx_drop();
            return;
        }
        if (packet.type == PacketType.ethernet && packet.vlan_tag == VlanTag.none && packet.eth.ether_type == EtherType.ow)
        {
            if (packet.eth.src == mac)
                return; // capture echo of our own transmission
            if (packet.eth.dst != mac && !packet.eth.dst.is_multicast)
                return; // unicast for another station
            if (!station_ingress(packet))
                add_rx_drop();
            return;
        }
        if (packet.type == PacketType.ethernet && packet.vlan_tag == VlanTag.none && packet.eth.ether_type == EtherType.cfm && packet.eth.src != mac)
        {
            if (packet.eth.dst == mac || packet.eth.dst.is_multicast)
                cfm_ingress(packet);
            // fall through: cfm frames stay visible to subscribers/bridging either way
        }
        dispatch(packet);
    }

    override void online()
    {
        super.online();

        // prime the neighbour table: ask the segment for everyone's exotic addresses
        station_link_up();
    }

    override CompletionStatus shutdown()
    {
        // station state is segment-derived; it dies with the link
        _neighbours.clear();
        _local_addresses.clear();
        _who_has_sent.clear();
        _pending_reports.clear();
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        if (!_pending_reports.empty)
        {
            MonoTime now = getTime();
            for (size_t i = _pending_reports.length; i-- > 0; )
            {
                if (now >= _pending_reports[i].due)
                {
                    send_addr_report(_pending_reports[i].dst, _pending_reports[i].txid, _pending_reports[i].type);
                    _pending_reports.removeSwapLast(i);
                }
            }
        }
    }

    // Local-address knowledge for answering who_has/addr_query. The default is the
    // egress-learned set: complete for a standalone interface, where every outbound
    // exotic packet passes through station_egress. The bridge overrides with its
    // address table, which also knows pre-populated and never-crossed addresses.
    bool station_owns(ulong address)
        => (address in _local_addresses) !is null;

    void station_list(PacketType type, scope void delegate(ulong address) nothrow @nogc sink)
    {
        foreach (ref kvp; _local_addresses)
        {
            if (type != PacketType.unknown && cast(PacketType)(kvp.key >> 60) != type)
                continue;
            sink(kvp.key);
        }
    }

    final MACAddress station_of(ulong address) const
    {
        if (!is_network_multicast_address(address))
        {
            if (auto r = address in _neighbours)
                return *r;
        }
        return MACAddress.broadcast;
    }

    final void station_link_up()
    {
        // txid 0: prime the neighbour table only, not part of any discovery sweep
        discover(0);
    }

    // Encapsulate an exotic packet and transmit it across the segment.
    final bool station_egress(ref const Packet packet)
    {
        const(PacketCodec)* codec = get_ow_codec(packet.type);
        if (!codec)
        {
            log.trace("no ow codec for packet type ", cast(ushort)packet.type, "; frame dropped");
            return false;
        }

        // by construction, the inner src is an address on our side
        ulong src = get_network_src_address(packet);
        if (!is_network_multicast_address(src))
            _local_addresses[src] = getTime();

        ubyte[1518] buffer = void;
        ptrdiff_t len = build_ow_payload(packet, *codec, buffer);
        if (len <= 0)
            return false;

        Packet wrapped;
        ref eth = wrapped.init!Ethernet(buffer[0 .. len], packet.creation_time);
        eth.src = mac;
        eth.dst = resolve(get_network_dst_address(packet));
        eth.ether_type = EtherType.ow;
        wrapped.vlan = packet.vlan;
        wrapped.vlan_tag = packet.vlan_tag;
        medium_tx(wrapped);
        return true;
    }

    // Decapsulate an OW frame addressed to this station (caller pre-filtered outer src/dst).
    final bool station_ingress(ref Packet packet)
    {
        const(ubyte)[] content = cast(const(ubyte)[])packet.data;
        if (content.length < 5)
            return false;

        // any ow frame proves its sender is reachable via this station
        ether_neighbour_learn(packet.eth.src, this);
        ushort wire_type = loadBigEndian(cast(const(ushort)*)content.ptr);
        ushort data_len = loadBigEndian(cast(const(ushort)*)(content.ptr + 2));
        ubyte hdr_len = content[4];

        if (wire_type & ow_control_flag)
        {
            if (content.length < 5 + data_len)
                return false;
            add_rx_frame(packet.length);
            station_control(cast(OWControl)wire_type, content[5 .. 5 + data_len], packet.eth.src, !packet.eth.dst.is_multicast);
            return true;
        }

        if (content.length < 5 + hdr_len + data_len)
            return false;

        const(PacketCodec)* codec = wire_type < PacketType.count ? get_ow_codec(cast(PacketType)wire_type) : null;
        if (!codec)
        {
            log.trace("ow frame with unknown packet type ", wire_type, "; dropped");
            return false;
        }

        Packet inner;
        inner.creation_time = packet.creation_time;
        inner.vlan = packet.vlan;
        inner.vlan_tag = packet.vlan_tag;
        inner.data = content[5 + hdr_len .. 5 + hdr_len + data_len];
        if (codec.decode(inner, content[5 .. 5 + hdr_len]) <= 0)
            return false;

        // learn the station carrying the inner src so replies can unicast
        learn(get_network_src_address(inner), packet.eth.src);

        // the inner packet accounts where it terminates; the encap overhead counts here
        _status.rx_bytes += packet.length - inner.length;
        station_deliver(inner);
        return true;
    }

    // [type:u16][data_len:u16][hdr_len:u8][header][payload]; <= 0 on failure.
    // data_len is explicit because short frames gain padding on the wire (60-byte minimum).
    static ptrdiff_t build_ow_payload(ref const Packet packet, ref const PacketCodec codec, ubyte[] buffer)
    {
        if (buffer.length < 5)
            return -1;
        storeBigEndian(cast(ushort*)buffer.ptr, ushort(packet.type));
        storeBigEndian(cast(ushort*)(buffer.ptr + 2), cast(ushort)packet.data.length);

        size_t offset = 5;
        ptrdiff_t hl = codec.encode(packet, buffer[offset .. min(buffer.length, offset + 255)]);
        if (hl <= 0)
            return -1;
        buffer[4] = cast(ubyte)hl;
        offset += hl;

        if (packet.data.length > buffer.length - offset)
            return -1;
        buffer[offset .. offset + packet.data.length] = cast(const(ubyte)[])packet.data[];
        return offset + packet.data.length;
    }

    override ushort pcap_type() const
        => 1; // LINKTYPE_ETHERNET

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
    {
        if (packet.type == PacketType.ethernet)
        {
            ubyte[18] header = void;
            size_t header_len = encode_ethernet_header(packet, header[]);
            if (header_len == 0)
                return;
            sink(header[0 .. header_len]);
            sink(packet.data);
            return;
        }

        // exotic packets appear on the wire OW-encapsulated; synthesize the same frame
        const(PacketCodec)* codec = get_ow_codec(packet.type);
        if (!codec)
            return;

        bool outgoing = dir == PacketDirection.outgoing;
        MACAddress remote = station_of(outgoing ? get_network_dst_address(packet) : get_network_src_address(packet));

        ubyte[18] hdr = void;
        Packet wrapped;
        ref eth = wrapped.init!Ethernet(null, packet.creation_time);
        eth.dst = outgoing ? remote : mac;
        eth.src = outgoing ? mac : remote;
        eth.ether_type = EtherType.ow;
        wrapped.vlan = packet.vlan;
        wrapped.vlan_tag = packet.vlan_tag;
        size_t header_len = encode_ethernet_header(wrapped, hdr[]);
        if (header_len == 0)
            return;
        sink(hdr[0 .. header_len]);

        ubyte[1518] buffer = void;
        ptrdiff_t len = build_ow_payload(packet, *codec, buffer);
        if (len <= 0)
            return;
        sink(buffer[0 .. len]);

        if (packet.type == PacketType.modbus)
        {
            // wireshark wants RTU packets for its decoder, so we need to append the crc...
            import urt.crc;
            ushort crc = packet.data[3..$].calculate_crc!(Algorithm.crc16_modbus)();
            sink(crc.nativeToLittleEndian());
        }
    }

private:
    enum resolve_interval = 5.seconds;
    enum report_capacity = 432;     // address bytes per report; head + addresses must fit the control frame
    enum report_jitter_ms = 250;

    struct PendingReport
    {
        MACAddress dst;
        uint txid;
        PacketType type;
        MonoTime due;
    }

    ubyte _cfm_level = 7;   // maintenance level we claim; conventional for customer/edge equipment

    // exotic address -> ethernet station carrying it, learned from OW-encap ingress
    Map!(ulong, MACAddress) _neighbours;
    // exotic addresses on our side, learned from encap egress
    Map!(ulong, MonoTime) _local_addresses;
    // who_has rate limiting
    Map!(ulong, MonoTime) _who_has_sent;
    // jittered replies to broadcast addr_query
    Array!PendingReport _pending_reports;

    void learn(ulong address, MACAddress station)
    {
        if (is_network_multicast_address(address))
            return;
        _neighbours[address] = station;
        _who_has_sent.remove(address);
    }

    // an unknown unicast also fires who_has; the frame still floods, so delivery never waits on the reply
    MACAddress resolve(ulong address)
    {
        // mac-transport addresses ARE wire addresses; identity, no resolution needed
        if (address >> 60 == ulong(PacketType.ether_transport))
            return MACAddress.from_ul(address);
        if (is_network_multicast_address(address))
            return MACAddress.broadcast;
        if (auto r = address in _neighbours)
            return *r;

        MonoTime now = getTime();
        MonoTime* last = address in _who_has_sent;
        if (!last || now - *last >= resolve_interval)
        {
            if (last)
                *last = now;
            else
                _who_has_sent[address] = now;
            ubyte[8] request = address.nativeToBigEndian;
            station_send_control(OWControl.who_has, MACAddress.broadcast, request);
        }
        return MACAddress.broadcast;
    }

    // 802.1ag LBM (opcode 3) is answered with an LBR (opcode 2) echoing the PDU, with a Sender ID TLV prepended
    // LBMs at other levels belong to someone else's maintenance domain; answering them would corrupt it
    void cfm_ingress(ref const Packet packet)
    {
        const(ubyte)[] pdu = cast(const(ubyte)[])packet.data;
        if (pdu.length < 8)
            return;
        if ((pdu[0] & 0x1F) != 0)
            return;     // CFM version != 0
        ubyte level = pdu[0] >> 5;

        switch (pdu[1])
        {
            case cfm_opcode_lbm:
            {
                if (level != _cfm_level)
                    return;
                if (packet.eth.dst != mac && packet.eth.dst != cfm_class_multicast(level))
                    return;
                size_t tlv_offset = 4 + pdu[3];
                if (pdu[3] < 4 || tlv_offset > pdu.length)
                    return;

                ubyte[1500] reply = void;
                reply[0 .. tlv_offset] = pdu[0 .. tlv_offset];
                reply[1] = cfm_opcode_lbr;
                size_t len = tlv_offset + write_sender_id_tlv(reply[tlv_offset .. $]);
                size_t echo = min(pdu.length - tlv_offset, reply.length - len);
                reply[len .. len + echo] = pdu[tlv_offset .. tlv_offset + echo];
                len += echo;
                if (echo == 0 && len < reply.length)
                    reply[len++] = 0;   // LBM carried no TLVs; supply the End TLV ourselves
                send(packet.eth.src, reply[0 .. len], EtherType.cfm);
                return;
            }

            case cfm_opcode_lbr:
            {
                uint txid = pdu[4 .. 8].bigEndianToNative!uint;
                foreach (ref p; _pending_pings[])
                {
                    if (p.txid != txid)
                        continue;
                    Duration rtt = getTime() - p.sent;
                    p.handler(packet.eth.src, rtt, cfm_sender_identity(pdu));
                    return;    // the entry stays; it collects further replies until it expires
                }
                return;
            }

            default:
                return;
        }
    }

    // chassis id subtype 7 (locally assigned): the mac is already in the frame header, so subtype 4 adds nothing
    static size_t write_sender_id_tlv(ubyte[] buffer)
    {
        import manager.system : hostname;

        const(char)[] name = hostname[];
        if (name.length > 63)
            name = name[0 .. 63];
        if (buffer.length < 5 + name.length)
            return 0;
        buffer[0] = cfm_tlv_sender_id;
        buffer[1 .. 3] = (cast(ushort)(2 + name.length)).nativeToBigEndian;
        buffer[3] = cast(ubyte)name.length;     // chassis id length (excludes the subtype octet)
        buffer[4] = 7;                          // chassis id subtype: locally assigned
        buffer[5 .. 5 + name.length] = cast(const(ubyte)[])name[];
        return 5 + name.length;
    }

    // Extract the responder's name from an LBR's Sender ID TLV, if it carries a textual chassis id.
    static const(char)[] cfm_sender_identity(const(ubyte)[] pdu)
    {
        size_t offset = 4 + pdu[3];
        if (pdu[3] < 4)
            return null;
        while (offset + 3 <= pdu.length)
        {
            const(ubyte)[] tlv = pdu[offset .. $];
            if (tlv[0] == 0)
                return null;    // End TLV
            ushort len = tlv[1 .. 3].bigEndianToNative!ushort;
            if (3 + len > tlv.length)
                return null;
            if (tlv[0] == cfm_tlv_sender_id && len >= 2)
            {
                const(ubyte)[] value = tlv[3 .. 3 + len];
                ubyte chassis_len = value[0];
                if (chassis_len >= 1 && 2 + chassis_len <= value.length && value[1] != 4)
                    return cast(const(char)[])value[2 .. 2 + chassis_len];  // subtype 4 = mac address, not text
                return null;
            }
            offset += 3 + len;
        }
        return null;
    }

    static MACAddress cfm_class_multicast(ubyte level) pure
        => MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, cast(ubyte)(0x30 | level));

    void station_send_control(OWControl msg, MACAddress dst, scope const(ubyte)[] content)
    {
        ubyte[512] buffer = void;
        if (content.length + 5 > buffer.length)
            return;
        storeBigEndian(cast(ushort*)buffer.ptr, ushort(msg));
        storeBigEndian(cast(ushort*)(buffer.ptr + 2), cast(ushort)content.length);
        buffer[4] = 0; // control messages carry no packet header
        buffer[5 .. 5 + content.length] = content[];

        Packet wrapped;
        ref eth = wrapped.init!Ethernet(buffer[0 .. 5 + content.length]);
        eth.src = mac;
        eth.dst = dst;
        eth.ether_type = EtherType.ow;
        medium_tx(wrapped);
    }

    void station_control(OWControl msg, const(ubyte)[] content, MACAddress src, bool unicast)
    {
        switch (msg)
        {
            case OWControl.who_has:
            {
                if (content.length < 8)
                    return;
                ulong address = content[0 .. 8].bigEndianToNative!ulong;
                if (!station_owns(address))
                    return;
                ubyte[5 + 63 + 8] report = void;
                size_t offset = write_report_head(report, 0);
                report[offset .. offset + 8] = content[0 .. 8];
                station_send_control(OWControl.addr_report, src, report[0 .. offset + 8]);
                return;
            }

            case OWControl.addr_query:
            {
                if (content.length < 6)
                    return;
                uint txid = content[0 .. 4].bigEndianToNative!uint;
                ushort type = content[4 .. 6].bigEndianToNative!ushort;
                if (type != PacketType.unknown && type >= PacketType.count)
                    return;
                if (unicast)
                    send_addr_report(src, txid, cast(PacketType)type);
                else
                {
                    // jitter broadcast replies so a populated segment doesn't answer in one synchronised burst
                    _pending_reports ~= PendingReport(src, txid, cast(PacketType)type, getTime() + (rand() % report_jitter_ms).msecs);
                }
                return;
            }

            case OWControl.addr_report:
            {
                if (content.length < 5)
                    return;
                uint txid = content[0 .. 4].bigEndianToNative!uint;
                ubyte name_len = content[4];
                if (content.length < 5 + name_len)
                    return;
                const(char)[] name = cast(const(char)[])content[5 .. 5 + name_len];
                content = content[5 + name_len .. $];

                ulong[report_capacity / 8] addresses = void;
                size_t count = 0;
                while (content.length >= 8)
                {
                    ulong address = content[0 .. 8].bigEndianToNative!ulong;
                    content = content[8 .. $];
                    if (cast(PacketType)(address >> 60) >= PacketType.count)
                        continue;
                    learn(address, src);
                    if (count < addresses.length)
                        addresses[count++] = address;
                }
                if (txid)
                    sweep_reply(txid, src, name, addresses[0 .. count]);
                return;
            }

            case OWControl.announce:
                if (_announce_sink && src != mac)
                    _announce_sink(this, src, content);
                return;

            default:
                return;
        }
    }

    void send_addr_report(MACAddress dst, uint txid, PacketType type)
    {
        ubyte[5 + 63 + report_capacity] report = void;   // TODO: segment reports that exceed one frame
        size_t offset = write_report_head(report, txid);
        size_t len = offset;
        station_list(type, (ulong address) {
            if (len + 8 <= report.length)
            {
                report[len .. len + 8] = address.nativeToBigEndian;
                len += 8;
            }
        });
        if (len > offset || txid)
            station_send_control(OWControl.addr_report, dst, report[0 .. len]);
    }

    // [txid:u32][name_len:u8][name]; returns the offset where addresses begin
    static size_t write_report_head(ubyte[] buffer, uint txid)
    {
        import manager.system : hostname;

        const(char)[] name = hostname[];
        if (name.length > 63)
            name = name[0 .. 63];
        buffer[0 .. 4] = txid.nativeToBigEndian;
        buffer[4] = cast(ubyte)name.length;
        buffer[5 .. 5 + name.length] = cast(const(ubyte)[])name[];
        return 5 + name.length;
    }
}


enum ubyte cfm_opcode_lbr = 2;
enum ubyte cfm_opcode_lbm = 3;
enum ubyte cfm_tlv_sender_id = 1;

alias MacPingHandler = void delegate(MACAddress from, Duration rtt, scope const(char)[] identity) nothrow @nogc;
alias MacDiscoverHandler = void delegate(MACAddress from, scope const(char)[] identity, scope const(ulong)[] addresses) nothrow @nogc;
alias AnnounceSink = void delegate(EthernetStation station, MACAddress src, scope const(ubyte)[] tlv) nothrow @nogc;

// One consumer: the peering/discovery service. Announces arriving before (or without)
// registration are dropped at the station.
void set_announce_sink(AnnounceSink sink)
{
    _announce_sink = sink;
}

void mac_ping_cancel(uint txid)
{
    foreach (i, ref p; _pending_pings[])
    {
        if (p.txid == txid)
        {
            _pending_pings.removeSwapLast(i);
            return;
        }
    }
}

// pass the returned txid to discover() on each participating station; reports correlate back until expiry
uint mac_discover_begin(MacDiscoverHandler handler)
{
    uint txid = _next_sweep_txid++;
    if (_next_sweep_txid == 0)
        ++_next_sweep_txid;
    _pending_sweeps ~= PendingSweep(txid, getTime(), handler);
    return txid;
}

void mac_discover_cancel(uint txid)
{
    foreach (i, ref s; _pending_sweeps[])
    {
        if (s.txid == txid)
        {
            _pending_sweeps.removeSwapLast(i);
            return;
        }
    }
}

package void expire_mac_probes()
{
    MonoTime now = getTime();
    for (size_t i = _pending_pings.length; i-- > 0; )
    {
        if (now - _pending_pings[i].sent >= 10.seconds)
            _pending_pings.removeSwapLast(i);
    }
    for (size_t i = _pending_sweeps.length; i-- > 0; )
    {
        if (now - _pending_sweeps[i].begun >= 10.seconds)
            _pending_sweeps.removeSwapLast(i);
    }
}

private void sweep_reply(uint txid, MACAddress from, scope const(char)[] identity, scope const(ulong)[] addresses)
{
    foreach (ref s; _pending_sweeps[])
    {
        if (s.txid != txid)
            continue;
        s.handler(from, identity, addresses);
        return;
    }
}

private struct PendingPing
{
    uint txid;
    MonoTime sent;
    MacPingHandler handler;
}

private struct PendingSweep
{
    uint txid;
    MonoTime begun;
    MacDiscoverHandler handler;
}

private __gshared Array!PendingPing _pending_pings;
private __gshared uint _next_ping_txid = 1;
private __gshared Array!PendingSweep _pending_sweeps;
private __gshared uint _next_sweep_txid = 1;
private __gshared AnnounceSink _announce_sink;


abstract class EthernetInterface : EthernetStation
{
nothrow @nogc:

protected:

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);

        // TODO: proper values?
//        _mtu = 1500;
//        _max_l2mtu = _mtu;
//        _l2mtu = 1500;

//        mark_set!(typeof(this), "max-l2mtu")();
    }

    final void incoming_ethernet_frame(const(ubyte)[] data, MonoTime ts, ushort vlan_tci = 0, ushort vlan_tpid = 0)
    {
        if (data.length < 14)
        {
            log.trace("drop degenerate ethernet frame: ", data.length, " < 14 bytes!");
            add_rx_drop();
            return;
        }

        Packet packet;
        ref eth = packet.init!Ethernet(data, ts);
        eth.dst = MACAddress(data[0 .. 6]);
        eth.src = MACAddress(data[6 .. 12]);
        eth.ether_type = data[12 .. 14].bigEndianToNative!ushort;
        packet._offset = 14;

        if (vlan_tpid != 0)
        {
            if (!packet.set_vlan_tag(vlan_tpid))
            {
                add_rx_drop();
                return;
            }
            packet.vlan = vlan_tci;
        }

        if (packet.vlan_tag == VlanTag.none && eth.ether_type == 0x88E5) // MACsec
        {
            // TODO: handle MACsec frames?
            //       is this handled at the interface, or forwarded to a bridge if we are slave?
            add_rx_drop();
            return;
        }

        // the packet accounts only payload bytes; account the link-layer overhead here
        _status.rx_bytes += data.length - packet.length + (vlan_tpid != 0 ? 4 : 0);
        incoming_packet(packet);
    }

    // The medium is the wire: frame the packet and push it via wire_send.
    final override void medium_tx(ref Packet packet)
    {
        debug assert(packet.type == PacketType.ethernet, "medium_tx expects an ethernet packet");

        ubyte[1522] buffer = void;

        size_t header_len = encode_ethernet_header(packet, buffer[]);
        if (header_len == 0)
        {
            add_tx_drop();
            return;
        }

        ubyte* payload = buffer.ptr + header_len;
        if (packet.data.length > buffer.sizeof - (payload - buffer.ptr))
        {
            log.warning("egress buffer too small: payload=", packet.data.length, " avail=", buffer.sizeof - (payload - buffer.ptr),
                        " vlan=", packet.vlan, " etype=", packet.eth.ether_type);
            add_tx_drop();
            return;
        }
        payload[0 .. packet.data.length] = cast(const(ubyte)[])packet.data[];
        size_t packet_len = (payload + packet.data.length) - buffer.ptr;

        if (wire_send(buffer[0 .. packet_len]) != 0)
            add_tx_drop();
        else
            add_tx_frame(packet_len);
    }

    // Subclass hook: push a fully-framed ethernet frame onto the wire.
    // Return 0 on success, non-zero on failure (already logged by the subclass).
    abstract int wire_send(const(ubyte)[] frame);
}


unittest
{
    import manager.system : hostname;

    ubyte[96] pdu = void;
    pdu[0] = 7 << 5;
    pdu[1] = cfm_opcode_lbr;
    pdu[2] = 0;
    pdu[3] = 4;
    pdu[4 .. 8] = 0;
    size_t len = 8 + EthernetStation.write_sender_id_tlv(pdu[8 .. $]);
    assert(len > 8);
    pdu[len++] = 0;
    assert(EthernetStation.cfm_sender_identity(pdu[0 .. len]) == hostname[]);

    // a mac-address chassis id is not a textual identity
    ubyte[16] mac_pdu = [7 << 5, cfm_opcode_lbr, 0, 4,  0, 0, 0, 0,  cfm_tlv_sender_id, 0, 5,  3, 4, 0xAA, 0xBB, 0];
    assert(EthernetStation.cfm_sender_identity(mac_pdu[]) == null);

    // a report head round-trips through the addr_report field layout
    ubyte[76] report = void;
    size_t offset = EthernetStation.write_report_head(report, 0x12345678);
    assert(report[0 .. 4].bigEndianToNative!uint == 0x12345678);
    assert(report[4] == hostname.length);
    assert(cast(const(char)[])report[5 .. offset] == hostname[]);

    Packet tagged;
    ref eth = tagged.init!Ethernet(null);
    eth.dst = MACAddress.broadcast;
    eth.src = MACAddress(0, 1, 2, 3, 4, 5);
    eth.ether_type = EtherType.ip4;
    tagged.vlan = 0xA003;
    tagged.vlan_tag = VlanTag._88a8;
    ubyte[18] header = void;
    assert(encode_ethernet_header(tagged, header[]) == 18);
    assert(header[12 .. 18] == [0x88, 0xA8, 0xA0, 0x03, 0x08, 0x00]);

    tagged.vlan = 0;
    tagged.vlan_tag = VlanTag._8100;
    assert(encode_ethernet_header(tagged, header[]) == 18);
    assert(header[12 .. 18] == [0x81, 0x00, 0, 0, 0x08, 0x00]);

    tagged.vlan = 3;
    tagged.vlan_tag = VlanTag.none;
    assert(encode_ethernet_header(tagged, header[]) == 18);
    assert(header[12 .. 18] == [0x81, 0x00, 0, 3, 0x08, 0x00]);
}
