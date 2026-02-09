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

version(Windows)
{
    import core.sys.windows.windows;
    import manager.os.npcap;
}

nothrow @nogc:


class EthernetInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("adapter", adapter)() ];
nothrow @nogc:

    enum type_name = "ether";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        this(collection_type_info!EthernetInterface, name.move, flags);
    }

    // Properties...

    const(char)[] adapter() pure
        => _adapter[];
    void adapter(const(char)[] value)
    {
        _adapter = value.makeString(defaultAllocator);
    }

    // API...

    override bool validate() const
        => !_adapter.empty;

    override CompletionStatus startup()
    {
        version(Windows)
        {
            char[PCAP_ERRBUF_SIZE] errbuf = void;

            // TODO: we may not want to open promiscuous unless we're a member of a bridge, or some form of L2 tunnel.
            bool promiscuous = true;
            int timeout_ms = 1; // TODO: we could probably tune this to our program update rate...?

            _pcap_handle = pcap_open_live(_adapter.tstringz, ushort.max, promiscuous, timeout_ms, errbuf.ptr);
            if (_pcap_handle is null)
            {
                writeError("pcap_open_live failed for adapter '", _adapter, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                return CompletionStatus.error;
            }
            if (pcap_setnonblock(_pcap_handle, 1, errbuf.ptr) != 0)
            {
                writeError("pcap_setnonblock failed on adapter '", _adapter, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                pcap_close(_pcap_handle);
                _pcap_handle = null;
                return CompletionStatus.error;
            }
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        version(Windows)
        {
            if (_pcap_handle !is null)
            {
                pcap_close(_pcap_handle);
                _pcap_handle = null;
            }
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        version(Windows)
        {
            pcap_pkthdr* header;
            const(ubyte)* data;
            Packet packet;

            while (true)
            {
                // poll for packets
                int res = pcap_next_ex(_pcap_handle, &header, &data);
                if (res == 0)
                    break;
                if (res <= 0)
                {
                    writeError("pcap_next_ex failed: ", pcap_geterr(_pcap_handle));

                    // TODO: any specific error handling? restart interface?
                    //       we need to know the set of errors we might expect...
                    break;
                }

                if (header.caplen < header.len || header.caplen < 14)
                {
                    ++_status.recv_dropped;
                    continue;
                }

                ref mac_hdr = *cast(const Ethernet*)data;
                const(ushort)* ethertype = &mac_hdr.ether_type;

                // init the packet...
                ref eth = packet.init!Ethernet(data[0 .. header.caplen], timeval_to_systime(header.ts));
                eth.dst = mac_hdr.dst;
                eth.src = mac_hdr.src;
                eth.ether_type = loadBigEndian(ethertype);
                packet._offset = 14;

                if (eth.ether_type == 0x88E5) // MACsec
                {
                    // TODO: handle MACsec frames?
                    ++_status.recv_dropped;
                    continue;
                }

                // subordinate interfaces should forward it directly to their master...
                if (_master)
                {
                    _master.slave_incoming(packet, _slave_id);
                    continue;
                }

                // check for vlan tagged packets...
                if (eth.ether_type == EtherType.vlan)// || eth.ether_type == 0x88A8)
                {
                    if (header.caplen < 18)
                    {
                        ++_status.recv_dropped;
                        continue;
                    }

                    packet.vlan = loadBigEndian(ethertype + 1);
                    eth.ether_type = loadBigEndian(ethertype + 2);
                    packet._offset += 4;
                }

                ushort vlan = packet.vlan & 0xFFF;
                if (vlan != 0)
                {
                    if (VLANInterface* vif = vlan in _vlans)
                    {
                        // TODO: check if vlan is for regular or service tag
                        if (true) // < !!!
                        {
                            vif.vlan_incoming(packet);
                            continue;
                        }
                    }

                    // no vlan sub-interface captured this frame, and it's not for us
                    _status.recv_dropped++;
                    continue;
                }

                switch (eth.ether_type)
                {
                    case EtherType.ow:
                        // de-capsulate open-watt encapsulated packets...
                        switch (mac_hdr.ow_sub_type)
                        {
                            // TODO...
                            default:
                                assert(false, "Unsupported open-watt sub-type!");
                        }
                        break;

                    // TODO: MAC control, LACP, LLDP, MACsec, etc...
                    //       probably already captured/handled by Windows...?

                    default:
                        // dispatch ethernet packet
                        _status.recv_bytes += header.caplen - packet.length; // adjust the recv counter since dispatch only counts payload length
                        dispatch(packet);
                        break;
                }
            }
        }
    }

    protected override bool transmit(ref const Packet packet)
    {
        send(packet);
        return true;
    }

protected:

    void send(ref const Packet packet) nothrow @nogc
    {
        version(Windows)
        {
            ubyte[1500] buffer; // TODO: jumbos?
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
                        // packet is too big! (TODO: but what about jumbos?)
                        _status.send_dropped++;
                        return;
                    }
                    payload[0 .. packet.data.length] = cast(ubyte[])packet.data[];
                    packet_len = (payload + packet.data.length) - buffer.ptr;
                    break;

                case PacketType._6lowpan:
                    assert(false, "TODO: reframe as ipv6?");

                default:
                    assert(false, "TODO: reframe other protocols as open-watt ethernet...");
                    ++_status.send_dropped;
                    return;
            }

            if (pcap_sendpacket(_pcap_handle, buffer.ptr, cast(int)packet_len) != 0)
            {
                writeError("pcap_sendpacket failed: ", pcap_geterr(_pcap_handle));
                // TODO: any specific error handling? restart interface?
                _status.send_dropped++;
            }

            ++_status.send_packets;
            _status.send_bytes += packet_len;
        }
    }

    final override bool bind_vlan(BaseInterface vlan_interface, bool remove)
    {
        VLANInterface vif = cast(VLANInterface)vlan_interface;
        assert(vif, "Not a vlan interface!");

        // add to the vlan table...
        if (remove)
            _vlans.remove(vif.vlan);
        else
        {
            debug assert (!_vlans.exists(vif.vlan), "VLAN already bound!" );
            _vlans.insert(vif.vlan, vif);
        }
        return true;
    }

private:
    this(const CollectionTypeInfo* typeInfo, String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, name.move, flags);

        // TODO: proper values?
//        _mtu = 1500;
//        _max_l2mtu = _mtu;
//        _l2mtu = 1500;
    }

    String _adapter;
    Map!(ushort, VLANInterface) _vlans;

    version(Windows)
    {
        pcap_t* _pcap_handle;
    }
}

class WiFiInterface : EthernetInterface
{
    __gshared Property[1] Properties = [ Property.create!("ssid", ssid)() ];
nothrow @nogc:

    enum type_name = "wifi";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WiFiInterface, name.move, flags);
    }

    // Properties...

    const(char)[] ssid() pure
        => null;
    void ssid(const(char)[] value)
    {
        assert(false);
    }

protected:
    // TODO: wifi details...
    // ssid, signal details, security.
}

class EthernetInterfaceModule : Module
{
    mixin DeclareModule!"interface.ethernet";
nothrow @nogc:

    Collection!EthernetInterface ethernet_interfaces;
    Collection!WiFiInterface wifi_interfaces;

    override void init()
    {
        version(Windows)
        {
            if (!npcap_loaded())
            {
                writeError("NPCap library not loaded, cannot enumerate ethernet interfaces.");
                return;
            }

            pcap_if* interfaces;
            char[PCAP_ERRBUF_SIZE] errbuf = void;
            if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
            {
                writeError("pcap_findalldevs failed: ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                return;
            }
            scope(exit) pcap_freealldevs(interfaces);

            int num_ether_interfaces = 0;
            int num_wifi_interfaces = 0;
            for (auto dev = interfaces; dev; dev = dev.next)
            {
                // Skip loopback interfaces
                if ((dev.flags & 0x00000001) != 0)
                    continue;

                const(char)[] name = dev.name[0..dev.name.strlen];
                const(char)[] description = dev.description[0..dev.description.strlen];

                // Heuristic to skip virtual adapters
                if (description.contains_i("virtual") ||
                    description.contains_i("miniport") ||
                    description.contains_i("hyper-v") ||
                    description.contains_i("bluetooth") ||
                    description.contains_i("wi-fi direct") ||
                    description.contains_i("virtualbox") ||
                    description.contains_i("tunnel") ||
                    description.contains_i("offload") ||
                    description.contains_i("tap"))
                    continue;

                // Check if it's a Wi-Fi interface
                bool is_wifi = (dev.flags & 0x00000008) != 0; // PCAP_IF_WIRELESS
                if (!is_wifi)
                {
                    // Also check description for wireless keywords as a fallback
                    if (description.contains_i("wireless") ||
                        description.contains_i("wi-fi") ||
                        description.contains_i("wifi"))
                        is_wifi = true;
                }

                if (is_wifi)
                {
                    writeInfo("Found wifi interface: \"", description, "\" (", name, ")");
                    auto iface = wifi_interfaces.create(tconcat("wifi", ++num_wifi_interfaces).makeString(defaultAllocator));
                    iface.adapter = name.makeString(defaultAllocator);
                }
                else
                {
                    writeInfo("Found ethernet interface: \"", description, "\" (", name, ")");
                    auto iface = ethernet_interfaces.create(tconcat("ether", ++num_ether_interfaces).makeString(defaultAllocator));
                    iface.adapter = name.makeString(defaultAllocator);
                }

                // TODO: we need to set the MAC for the interface to the NIC MAC address...
            }
        }

        g_app.console.register_collection("/interface/ethernet", ethernet_interfaces);
        g_app.console.register_collection("/interface/wifi", wifi_interfaces);
    }

    override void update()
    {
        ethernet_interfaces.update_all();
        wifi_interfaces.update_all();
    }
}
