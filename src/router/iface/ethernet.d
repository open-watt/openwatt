module router.iface.ethernet;

import urt.array;
import urt.endian;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;
import urt.fibre;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.vlan;

//version = DebugEthernetFlow;

nothrow @nogc:


abstract class EthernetInterface : BaseInterface
{
nothrow @nogc:

    protected override int transmit(ref const Packet packet, MessageCallback)
    {
        send(packet);
        return 0;
    }

protected:

    override ushort pcap_type() const
        => 1; // LINKTYPE_ETHERNET

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
    {
        import urt.endian;

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
        MACAddress remote = ow_station_mac(outgoing ? get_network_dst_address(packet) : get_network_src_address(packet));

        ubyte[1518] buffer = void;
        size_t len = frame_ow(packet, *codec, outgoing ? mac : remote, outgoing ? remote : mac, buffer);
        if (len == 0)
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

    final void incoming_ethernet_frame(const(ubyte)[] data, SysTime ts)
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

        // OW-encapsulated exotic frames unwrap at ingress so subscribers and bridges
        // see the inner packet natively; peek through a single 802.1Q tag if present
        ushort ow_ether_type = eth.ether_type;
        size_t ow_offset = 14;
        ushort tci = 0;
        if (eth.ether_type == EtherType.vlan && data.length >= 18)
        {
            tci = data[14 .. 16].bigEndianToNative!ushort;
            ow_ether_type = data[16 .. 18].bigEndianToNative!ushort;
            ow_offset = 18;
        }
        if (ow_ether_type == EtherType.ow)
        {
            incoming_ow_frame(data, ow_offset, tci, eth.src, eth.dst, ts);
            return;
        }

        if (eth.ether_type == 0x88E5) // MACsec
        {
            // TODO: handle MACsec frames?
            //       is this handled at the interface, or forwarded to a bridge if we are slave?
            add_rx_drop();
            return;
        }

        // dispatch counts only payload bytes; account for the link-layer overhead here
        _status.rx_bytes += data.length - packet.length;
        dispatch(packet);
    }

    void send(ref const Packet packet) nothrow @nogc
    {
        ubyte[1518] buffer = void; // 1500 IP + 14 ETH + 4 VLAN. TODO: jumbos / double-tag.
        size_t packet_len;

        switch (packet.type)
        {
            case PacketType.ethernet:
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
                payload[0 .. packet.data.length] = cast(ubyte[])packet.data[];
                packet_len = (payload + packet.data.length) - buffer.ptr;
                break;

            case PacketType._6lowpan:
                assert(false, "TODO: reframe as ipv6?");

            default:
                // exotic frames are OW-encapsulated for transit across the ethernet segment
                const(PacketCodec)* codec = get_ow_codec(packet.type);
                if (!codec)
                {
                    log.trace("no ow codec for packet type ", cast(ushort)packet.type, "; frame dropped");
                    add_tx_drop();
                    return;
                }
                packet_len = frame_ow(packet, *codec, mac, ow_station_mac(get_network_dst_address(packet)), buffer);
                if (packet_len == 0)
                {
                    add_tx_drop();
                    return;
                }
                break;
        }

        if (wire_send(buffer[0 .. packet_len]) != 0)
            add_tx_drop();

        add_tx_frame(packet_len);
    }

    // Subclass hook: push a fully-framed ethernet frame onto the wire.
    // Return 0 on success, non-zero on failure (already logged by the subclass).
    abstract int wire_send(const(ubyte)[] frame);

    override CompletionStatus shutdown()
    {
        _ow_neighbours.clear();
        return super.shutdown();
    }

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);

        // TODO: proper values?
//        _mtu = 1500;
//        _max_l2mtu = _mtu;
//        _l2mtu = 1500;

//        mark_set!(typeof(this), "max-l2mtu")();
    }

private:
    // exotic address -> ethernet station carrying it, learned from OW-encap ingress
    Map!(ulong, MACAddress) _ow_neighbours;

    MACAddress ow_station_mac(ulong address) const
    {
        if (!is_network_multicast_address(address))
        {
            if (auto r = address in _ow_neighbours)
                return *r;
        }
        return MACAddress.broadcast;
    }

    // Frame an exotic packet as [eth hdr][vlan?][0x88B5][type:u16][data_len:u16][hdr_len:u8][header][payload].
    // data_len is explicit because short frames gain padding on the wire (60-byte ethernet minimum).
    // Returns the total frame length, or 0 if the packet can't be encapsulated.
    size_t frame_ow(ref const Packet packet, ref const PacketCodec codec, MACAddress src, MACAddress dst, ubyte[] buffer) const
    {
        import urt.util : min;

        Ethernet* eth = cast(Ethernet*)buffer.ptr;
        eth.dst = dst;
        eth.src = src;
        ushort* ethertype = &eth.ether_type;
        if (packet.vlan)
        {
            storeBigEndian(ethertype++, ushort(EtherType.vlan));
            storeBigEndian(ethertype++, packet.vlan);
        }
        storeBigEndian(ethertype++, ushort(EtherType.ow));
        storeBigEndian(ethertype++, ushort(packet.type));
        storeBigEndian(ethertype++, cast(ushort)packet.data.length);

        ubyte* p = cast(ubyte*)ethertype;
        ubyte* hdr_len = p++;

        size_t avail = buffer.length - (p - buffer.ptr);
        ptrdiff_t hl = codec.encode(packet, p[0 .. min(avail, 255)]);
        if (hl <= 0)
            return 0;
        *hdr_len = cast(ubyte)hl;
        p += hl;

        if (packet.data.length > buffer.length - (p - buffer.ptr))
            return 0;
        p[0 .. packet.data.length] = cast(const(ubyte)[])packet.data[];
        return (p - buffer.ptr) + packet.data.length;
    }

    // Ingress for an OW-encapsulated frame: unwrap and dispatch the inner packet natively.
    void incoming_ow_frame(const(ubyte)[] frame, size_t offset, ushort tci, MACAddress src, MACAddress dst, SysTime ts)
    {
        if (src == mac)
            return; // capture echo of our own transmission
        if (dst != mac && !dst.is_multicast)
            return; // unicast for another station

        if (frame.length >= offset + 5)
        {
            ushort wire_type = loadBigEndian(cast(const(ushort)*)(frame.ptr + offset));
            ushort data_len = loadBigEndian(cast(const(ushort)*)(frame.ptr + offset + 2));
            ubyte hdr_len = frame[offset + 4];
            offset += 5;

            if (wire_type & ow_control_flag)
            {
                // OW control-plane message (agent_discover, etc)
                // TODO: nothing implemented yet
                return;
            }

            if (frame.length >= offset + hdr_len + data_len)
            {
                const(PacketCodec)* codec = wire_type < PacketType.count ? get_ow_codec(cast(PacketType)wire_type) : null;
                if (codec)
                {
                    Packet packet;
                    packet.creation_time = ts;
                    packet.vlan = tci;
                    packet.data = frame[offset + hdr_len .. offset + hdr_len + data_len];
                    if (codec.decode(packet, frame[offset .. offset + hdr_len]) > 0)
                    {
                        // learn the station carrying the inner src so replies can unicast
                        ulong inner_src = get_network_src_address(packet);
                        if (!is_network_multicast_address(inner_src))
                            _ow_neighbours[inner_src] = src;

                        _status.rx_bytes += frame.length - packet.length;
                        dispatch(packet);
                        return;
                    }
                }
                else
                    log.trace("ow frame with unknown packet type ", wire_type, "; dropped");
            }
        }
        add_rx_drop();
    }
}
