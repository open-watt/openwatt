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
}

nothrow @nogc:


class EthernetInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("adapter", adapter)() ];
nothrow @nogc:

    alias TypeName = StringLit!"ether";

    this(String name, ObjectFlags flags = ObjectFlags.None)
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
                return CompletionStatus.Error;
            }
            if (pcap_setnonblock(_pcap_handle, 1, errbuf.ptr) != 0)
            {
                writeError("pcap_setnonblock failed on adapter '", _adapter, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                pcap_close(_pcap_handle);
                _pcap_handle = null;
                return CompletionStatus.Error;
            }
        }
        return CompletionStatus.Complete;
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
        return CompletionStatus.Complete;
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
                    ++_status.recvDropped;
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
                    ++_status.recvDropped;
                    continue;
                }

                // subordinate interfaces should forward it directly to their master...
                if (_master)
                {
                    _master.slave_incoming(packet, _slave_id);
                    continue;
                }

                // check for vlan tagged packets...
                if (eth.ether_type == EtherType.VLAN)// || eth.ether_type == 0x88A8)
                {
                    if (header.caplen < 18)
                    {
                        ++_status.recvDropped;
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
                    _status.recvDropped++;
                    continue;
                }

                switch (eth.ether_type)
                {
                    case EtherType.OW:
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
                        _status.recvBytes += header.caplen - packet.length; // adjust the recv counter since dispatch only counts payload length
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
                case PacketType.Ethernet:
                    Ethernet* eth = cast(Ethernet*)buffer.ptr;
                    eth.dst = packet.eth.dst;
                    eth.src = packet.eth.src;
                    ushort* ethertype = &eth.ether_type;

                    // if there should be a vlan header
                    if (packet.vlan)
                    {
                        storeBigEndian(ethertype++, ushort(EtherType.VLAN));
                        storeBigEndian(ethertype++, packet.vlan);
                    }
                    storeBigEndian(ethertype++, packet.eth.ether_type);

                    // write the payload...
                    ubyte* payload = cast(ubyte*)ethertype;
                    if (packet.data.length > buffer.sizeof - (payload - buffer.ptr))
                    {
                        // packet is too big! (TODO: but what about jumbos?)
                        _status.sendDropped++;
                        return;
                    }
                    payload[0 .. packet.data.length] = cast(ubyte[])packet.data[];
                    packet_len = (payload + packet.data.length) - buffer.ptr;
                    break;

                case PacketType._6LoWPAN:
                    assert(false, "TODO: reframe as ipv6?");

                default:
                    assert(false, "TODO: reframe other protocols as open-watt ethernet...");
                    ++_status.sendDropped;
                    return;
            }

            if (pcap_sendpacket(_pcap_handle, buffer.ptr, cast(int)packet_len) != 0)
            {
                writeError("pcap_sendpacket failed: ", pcap_geterr(_pcap_handle));
                // TODO: any specific error handling? restart interface?
                _status.sendDropped++;
            }

            ++_status.sendPackets;
            _status.sendBytes += packet_len;
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
    this(const CollectionTypeInfo* typeInfo, String name, ObjectFlags flags = ObjectFlags.None)
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

    alias TypeName = StringLit!"wifi";

    this(String name, ObjectFlags flags = ObjectFlags.None)
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
            _npcap = init_npcap();
            if (!_npcap)
                return;

            if (pcap_findalldevs is null)
                return;

            pcap_if* interfaces;
            char[PCAP_ERRBUF_SIZE] errbuf = void;
            if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
            {
                writeError("pcap_findalldevs failed: ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                return;
            }

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
            }

            if (interfaces !is null)
            {
                if (pcap_freealldevs !is null)
                    pcap_freealldevs(interfaces);
            }
        }

        g_app.console.registerCollection("/interface/ethernet", ethernet_interfaces);
        g_app.console.registerCollection("/interface/wifi", wifi_interfaces);
    }

    override void update()
    {
        ethernet_interfaces.update_all();
        wifi_interfaces.update_all();
    }

private:
    version (Windows)
    {
        HMODULE _npcap;
    }
}


private:

version (Windows)
{
    import core.sys.windows.winsock2 : sockaddr;

    extern(Windows) void* AddDllDirectory(const wchar*);

    SysTime timeval_to_systime(ref const timeval tv) pure nothrow @nogc
    {
        ulong sec = tv.tv_sec + 11644473600UL;
        return SysTime(sec*10000000 + tv.tv_usec*10);
    }

    enum PCAP_ERRBUF_SIZE = 256;

    struct pcap_t {}

    struct pcap_addr {
        pcap_addr* next;
        sockaddr* addr;         // address
        sockaddr* netmask;      // netmask for that address
        sockaddr* broadaddr;    // broadcast address for that address
        sockaddr* dstaddr;      // P2P destination address for that address
    }

    struct pcap_if {
        pcap_if* next;
        char* name;         // name to hand to "pcap_open_live()"
        char* description;  // textual description of interface, or null
        pcap_addr* addresses;
        uint flags;         // PCAP_IF_ interface flags
    }

    struct pcap_pkthdr
    {
        timeval ts;
        uint caplen;
        uint len;
    }

    extern(Windows) int function(pcap_if**, char*) nothrow @nogc pcap_findalldevs;
    extern(Windows) void function(pcap_if* alldevs) nothrow @nogc pcap_freealldevs;
    extern(Windows) pcap_t* function(const(char)* device, int snaplen, int promisc, int to_ms, char* errbuf) nothrow @nogc pcap_open_live;
    extern(Windows) void function(pcap_t* p) nothrow @nogc pcap_close;
    extern(Windows) int function(pcap_t *p, int nonblock, char *errbuf) pcap_setnonblock;
    extern(Windows) int function(pcap_t* p, const void* buf, int size) nothrow @nogc pcap_sendpacket;
    extern(Windows) int function(pcap_t* p, pcap_pkthdr** pkt_header, const ubyte** pkt_data) nothrow @nogc pcap_next_ex;
    extern(Windows) const(char)* function(pcap_t* p) nothrow @nogc pcap_geterr;

    HMODULE init_npcap()
    {
        AddDllDirectory("C:\\Windows\\System32\\Npcap"w.ptr);
        HMODULE lib = LoadLibraryA("wpcap.dll");
        if (lib is null)
        {
            writeWarning("Failed to load npcap dll's. Promiscuous access to ethernet interfaces will be unavailable.");
            return null;
        }

        pcap_findalldevs = cast(typeof(pcap_findalldevs))GetProcAddress(lib, "pcap_findalldevs");
        pcap_freealldevs = cast(typeof(pcap_freealldevs))GetProcAddress(lib, "pcap_freealldevs");
        pcap_open_live = cast(typeof(pcap_open_live))GetProcAddress(lib, "pcap_open_live");
        pcap_close = cast(typeof(pcap_close))GetProcAddress(lib, "pcap_close");
        pcap_setnonblock = cast(typeof(pcap_setnonblock))GetProcAddress(lib, "pcap_setnonblock");
        pcap_sendpacket = cast(typeof(pcap_sendpacket))GetProcAddress(lib, "pcap_sendpacket");
        pcap_next_ex = cast(typeof(pcap_next_ex))GetProcAddress(lib, "pcap_next_ex");
        pcap_geterr = cast(typeof(pcap_geterr))GetProcAddress(lib, "pcap_geterr");

        return lib;
    }
}
