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

        bool is_ow = packet.eth.ether_type == EtherType.ow;

        // write ethernet header...
        struct Header
        {
            MACAddress dst;
            MACAddress src;
            ubyte[2] type;
            ubyte[2] subtype;
        }
        Header h;
        h.dst = packet.eth.dst;
        h.src = packet.eth.src;
        h.type = nativeToBigEndian(packet.eth.ether_type);
        if (is_ow)
            h.subtype = nativeToBigEndian(packet.eth.ow_sub_type);
        sink((cast(ubyte*)&h)[0 .. (is_ow ? Header.sizeof : Header.subtype.offsetof)]);

        // write packet data
        sink(packet.data);

        if (is_ow && packet.eth.ow_sub_type == OW_SubType.modbus)
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
            add_rx_drop();
            return;
        }

        ref mac_hdr = *cast(const Ethernet*)data.ptr;

        Packet packet;
        ref eth = packet.init!Ethernet(data, ts);
        eth.dst = mac_hdr.dst;
        eth.src = mac_hdr.src;
        eth.ether_type = loadBigEndian(&mac_hdr.ether_type);
        packet._offset = 14;

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
                assert(false, "TODO: reframe other protocols as open-watt ethernet...");
                add_tx_drop();
                return;
        }

        if (wire_send(buffer[0 .. packet_len]) != 0)
            add_tx_drop();

        add_tx_frame(packet_len);
    }

    // Subclass hook: push a fully-framed ethernet frame onto the wire.
    // Return 0 on success, non-zero on failure (already logged by the subclass).
    abstract int wire_send(const(ubyte)[] frame);

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);

        // TODO: proper values?
//        _mtu = 1500;
//        _max_l2mtu = _mtu;
//        _l2mtu = 1500;

//        mark_set!(typeof(this), "max-l2mtu")();
    }
}
