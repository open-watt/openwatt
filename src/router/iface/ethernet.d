module router.iface.ethernet;

import urt.endian;
import urt.log;
import urt.map;
import urt.time;
import urt.util : min;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;

//version = DebugEthernetFlow;

nothrow @nogc:


abstract class EthernetStation : BaseInterface
{
nothrow @nogc:

    MACAddress mac;

    final int send(MACAddress dest, const(void)[] message, EtherType type, MessageCallback callback = null)
    {
        Packet p;
        ref eth = p.init!Ethernet(message);
        eth.src = mac;
        eth.dst = dest;
        eth.ether_type = type;
        return forward(p, callback);
    }

protected:

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
        _caps |= InterfaceCaps.ethernet;
        mac = generate_mac_address(name[]);
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
        // vlan-tagged OW frames are not intercepted here: a VLAN sub-interface is the
        // station for its vlan, and the vlan demux in dispatch() routes tagged frames
        // to it. No sub-interface configured = not attached to that segment.
        if (packet.type == PacketType.ethernet && packet.eth.ether_type == EtherType.ow)
        {
            if (packet.eth.src == mac)
                return; // capture echo of our own transmission
            if (packet.eth.dst != mac && !packet.eth.dst.is_multicast)
                return; // unicast for another station
            if (!station_ingress(packet))
                add_rx_drop();
            return;
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
        return super.shutdown();
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
        ubyte[2] query = ushort(PacketType.unknown).nativeToBigEndian;
        station_send_control(OWControl.addr_query, MACAddress.broadcast, query);
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
        medium_tx(wrapped);
        return true;
    }

    // Decapsulate an OW frame addressed to this station (caller pre-filtered outer src/dst).
    final bool station_ingress(ref Packet packet)
    {
        const(ubyte)[] content = cast(const(ubyte)[])packet.data;
        if (content.length < 5)
            return false;
        ushort wire_type = loadBigEndian(cast(const(ushort)*)content.ptr);
        ushort data_len = loadBigEndian(cast(const(ushort)*)(content.ptr + 2));
        ubyte hdr_len = content[4];

        if (wire_type & ow_control_flag)
        {
            if (content.length < 5 + data_len)
                return false;
            add_rx_frame(packet.length);
            station_control(cast(OWControl)wire_type, content[5 .. 5 + data_len], packet.eth.src);
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
            struct Header
            {
                MACAddress dst;
                MACAddress src;
                ubyte[2] type;
            }
            Header h;
            h.dst = packet.eth.dst;
            h.src = packet.eth.src;
            h.type = nativeToBigEndian(packet.eth.ether_type);
            sink((cast(ubyte*)&h)[0 .. Header.sizeof]);
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
        Ethernet* eth = cast(Ethernet*)hdr.ptr;
        eth.dst = outgoing ? remote : mac;
        eth.src = outgoing ? mac : remote;
        ushort* ethertype = &eth.ether_type;
        if (packet.vlan)
        {
            storeBigEndian(ethertype++, ushort(EtherType.vlan));
            storeBigEndian(ethertype++, packet.vlan);
        }
        storeBigEndian(ethertype++, ushort(EtherType.ow));
        sink(hdr[0 .. cast(ubyte*)ethertype - hdr.ptr]);

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
    enum max_report_entries = 180; // TODO: segment larger reports

    // exotic address -> ethernet station carrying it, learned from OW-encap ingress
    Map!(ulong, MACAddress) _neighbours;
    // exotic addresses on our side, learned from encap egress
    Map!(ulong, MonoTime) _local_addresses;
    // who_has rate limiting
    Map!(ulong, MonoTime) _who_has_sent;

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

    void station_control(OWControl msg, const(ubyte)[] content, MACAddress src)
    {
        switch (msg)
        {
            case OWControl.who_has:
                if (content.length < 8)
                    return;
                ulong address = content[0 .. 8].bigEndianToNative!ulong;
                if (station_owns(address))
                    station_send_control(OWControl.addr_report, src, content[0 .. 8]);
                return;

            case OWControl.addr_query:
                if (content.length < 2)
                    return;
                ushort type = content[0 .. 2].bigEndianToNative!ushort;
                if (type != PacketType.unknown && type >= PacketType.count)
                    return;
                ubyte[max_report_entries * 8] entries = void;
                size_t len = 0;
                station_list(cast(PacketType)type, (ulong address) {
                    if (len + 8 <= entries.length)
                    {
                        entries[len .. len + 8] = address.nativeToBigEndian;
                        len += 8;
                    }
                });
                if (len)
                    station_send_control(OWControl.addr_report, src, entries[0 .. len]);
                return;

            case OWControl.addr_report:
                while (content.length >= 8)
                {
                    ulong address = content[0 .. 8].bigEndianToNative!ulong;
                    content = content[8 .. $];
                    if (cast(PacketType)(address >> 60) >= PacketType.count)
                        continue;
                    learn(address, src);
                }
                return;

            default:
                return;
        }
    }
}


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

    final void incoming_ethernet_frame(const(ubyte)[] data, MonoTime ts)
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

        if (eth.ether_type == 0x88E5) // MACsec
        {
            // TODO: handle MACsec frames?
            //       is this handled at the interface, or forwarded to a bridge if we are slave?
            add_rx_drop();
            return;
        }

        // the packet accounts only payload bytes; account the link-layer overhead here
        _status.rx_bytes += data.length - packet.length;
        incoming_packet(packet);
    }

    // The medium is the wire: frame the packet and push it via wire_send.
    final override void medium_tx(ref Packet packet)
    {
        debug assert(packet.type == PacketType.ethernet, "medium_tx expects an ethernet packet");

        ubyte[1518] buffer = void; // 1500 IP + 14 ETH + 4 VLAN. TODO: jumbos / double-tag.

        Ethernet* eth = cast(Ethernet*)buffer.ptr;
        eth.dst = packet.eth.dst;
        eth.src = packet.eth.src;
        ushort* ethertype = &eth.ether_type;

        // if there should be a vlan header
        if (packet.vlan)
        {
            storeBigEndian(ethertype++, ushort(EtherType.vlan));
            storeBigEndian(ethertype++, packet.vlan);
        }
        storeBigEndian(ethertype++, packet.eth.ether_type);

        // write the payload...
        ubyte* payload = cast(ubyte*)ethertype;
        if (packet.data.length > buffer.sizeof - (payload - buffer.ptr))
        {
            log.warning("egress buffer too small: payload=", packet.data.length, " avail=", buffer.sizeof - (payload - buffer.ptr), " vlan=", packet.vlan, " etype=", packet.eth.ether_type);
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
