module router.iface;

import urt.conv;
import urt.map;
import urt.lifetime;
import urt.mem.ring;
import urt.mem.string;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface.vlan;

public import router.iface.packet;
public import router.status;

// package modules...
public static import router.iface.bridge;
public static import router.iface.can;
public static import router.iface.ethernet;
public static import router.iface.modbus;
public static import router.iface.tesla;
public static import router.iface.vlan;
public static import router.iface.zigbee;

nothrow @nogc:


enum BufferOverflowBehaviour : byte
{
    drop_oldest,    // drop oldest data in buffer
    drop_newest,    // drop newest data in buffer (or don't add new data to full buffer)
    fail            // cause the call to fail
}

enum PacketDirection : ubyte
{
    incoming = 1,
    outgoing = 2
}

struct PacketFilter
{
nothrow @nogc:
    PacketType type = PacketType.ethernet;
    PacketDirection direction = PacketDirection.incoming;
    MACAddress src;
    MACAddress dst;
    ushort ether_type;
    union {
        ushort ow_subtype; // if ether_type == EtherType.ow
        ushort ether_type_2;
    }
    ushort vlan;

    bool match(ref const Packet p)
    {
        if (type != PacketType.unknown)
        {
            if (type != p.type)
                return false;
            if (type == PacketType.ethernet)
            {
                if (ether_type)
                {
                    if (p.eth.ether_type != ether_type)
                    {
                        if (!ether_type_2 || ether_type == EtherType.ow)
                            return false;
                        if (p.eth.ether_type != ether_type_2)
                            return false;
                    }
                    else if (ether_type == EtherType.ow)
                    {
                        if (ow_subtype && p.eth.ow_sub_type != ow_subtype)
                            return false;
                    }
                }
                else
                    debug assert(ether_type_2 == 0, "ether_type must be set if ether_type_2 is set!");
                if (src && p.eth.src != src)
                    return false;
                if (dst && p.eth.dst != dst)
                    return false;
            }
        }
        if (vlan && p.vlan != vlan)
            return false;
        return true;
    }
}

struct InterfaceSubscriber
{
    alias PacketHandler = void delegate(ref const Packet p, BaseInterface i, PacketDirection dir, void* u) nothrow @nogc;

    PacketFilter filter;
    PacketHandler recv_packet;
    void* user_data;
}

// MAC: 02:xx:xx:ra:nd:yy
//      02:13:37:xx:xx:yy
//      02:AC:1D:xx:xx:yy
//      02:C0:DE:xx:xx:yy
//      02:BA:BE:xx:xx:yy
//      02:DE:AD:xx:xx:yy
//      02:FE:ED:xx:xx:yy
//      02:B0:0B:xx:xx:yy

class BaseInterface : BaseObject
{
    __gshared Property[17] Properties = [ Property.create!("mtu", mtu)(),
                                          Property.create!("actual-mtu", actual_mtu)(),
                                          Property.create!("l2mtu", l2mtu)(),
                                          Property.create!("max-l2mtu", max_l2mtu)(),
                                          Property.create!("pcap", pcap)(),
                                          Property.create!("last_status_change_time", last_status_change_time, "status")(),
                                          Property.create!("connected", connected, "status")(),
                                          Property.create!("link_status", link_status, "status")(),
                                          Property.create!("link_downs", link_downs, "status")(),
                                          Property.create!("tx_link_speed", tx_link_speed, "status")(),
                                          Property.create!("rx_link_speed", rx_link_speed, "status")(),
                                          Property.create!("send_bytes", send_bytes, "traffic")(),
                                          Property.create!("recv_bytes", recv_bytes, "traffic")(),
                                          Property.create!("send_packets", send_packets, "traffic")(),
                                          Property.create!("recv_packets", recv_packets, "traffic")(),
                                          Property.create!("send_dropped", send_dropped, "traffic")(),
                                          Property.create!("recv_dropped", recv_dropped, "traffic")() ];
nothrow @nogc:

    enum type_name = "interface";

    MACAddress mac;
    Map!(MACAddress, BaseInterface) macTable;

    this(const CollectionTypeInfo* type_info, String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, name.move, flags);

        assert(!get_module!InterfaceModule.interfaces.exists(this.name[]), "HOW DID THIS HAPPEN?");
        get_module!InterfaceModule.interfaces.add(this);

        mac = generate_mac_address();
        add_address(mac, this);
    }

    ~this()
    {
        get_module!InterfaceModule.interfaces.remove(this);
    }

    static const(char)[] validate_name(const(char)[] name)
    {
        import urt.mem.temp;
        if (get_module!InterfaceModule.interfaces.exists(name))
            return tconcat("Interface with name '", name[], "' already exists");
        return null;
    }


    // Properties...

    final ushort mtu() const pure
        => _mtu;
    final void mtu(ushort value) pure
    {
        _mtu = value;
    }
    ushort actual_mtu() const pure
        => _mtu == 0 ? _l2mtu : _mtu;

    // TODO: the L2MTU properties should be available only to actual L2 interfaces...
    final ushort l2mtu() const pure
        => _l2mtu;
    void l2mtu(ushort value) pure
    {
        _l2mtu = value;
    }
    final ushort max_l2mtu() const pure
        => _max_l2mtu;

    // TODO: maybe we should make the pcap instance a normal collection item?
//    final const(char)[] pcap() const pure
//    {
//        assert(false, "TODO: we need to store the pcap thing!");
//    }
    final const(char)[] pcap(const(char)[] value)
    {
        // TODO: unsubscribe from old pcap interface, if any...
        import manager.pcap;
        PcapInterface* cap = get_module!PcapModule.findInterface(value);
        if (!cap)
            return tconcat("Failed to attach pcap interface '", value, "' to '", name, "'; doesn't exist");
        else
            cap.subscribe_interface(this);
        return null;
    }

    SysTime last_status_change_time() const => _status.link_status_change_time;
    ConnectionStatus connected() const => _status.connected;
    LinkStatus link_status() const => _status.link_status;
    ulong link_downs() const => _status.link_downs;
    ulong tx_link_speed() const => _status.tx_link_speed;
    ulong rx_link_speed() const => _status.rx_link_speed;
    ulong send_bytes() const => _status.send_bytes;
    ulong recv_bytes() const => _status.recv_bytes;
    ulong send_packets() const => _status.send_packets;
    ulong recv_packets() const => _status.recv_packets;
    ulong send_dropped() const => _status.send_dropped;
    ulong recv_dropped() const => _status.recv_dropped;

    // API...

    ref const(Status) status() const pure
        => _status;

    final void reset_counters() pure
    {
        _status.link_downs = 0;
        _status.send_bytes = 0;
        _status.recv_bytes = 0;
        _status.send_packets = 0;
        _status.recv_packets = 0;
        _status.send_dropped = 0;
        _status.recv_dropped = 0;
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    BaseInterface set_master(BaseInterface master, byte slave_id) pure
    {
        if (_master)
            return _master;
        _master = master;
        _slave_id = slave_id;
        return null;
    }

    // alias the base functions into this scope to merge the overload sets
    alias subscribe = typeof(super).subscribe;
    alias unsubscribe = typeof(super).unsubscribe;

    void subscribe(InterfaceSubscriber.PacketHandler packet_handler, ref const PacketFilter filter, void* user_data = null)
    {
        _subscribers[_num_subscribers++] = InterfaceSubscriber(filter, packet_handler, user_data);
    }

    void unsubscribe(InterfaceSubscriber.PacketHandler packet_handler)
    {
        foreach (i, ref sub; _subscribers[0.._num_subscribers])
        {
            if (sub.recv_packet is packet_handler)
            {
                // remove this subscriber
                if (i < --_num_subscribers)
                    sub = _subscribers[_num_subscribers];
                return;
            }
        }
    }

    bool send(MACAddress dest, const(void)[] message, EtherType type, OW_SubType subtype = OW_SubType.unspecified)
    {
        if (!running)
            return false;

        Packet p;
        ref eth = p.init!Ethernet(message);
        eth.src = mac;
        eth.dst = dest;
        eth.ether_type = type;
        eth.ow_sub_type = subtype;
        return forward(p);
    }

    final bool forward(ref Packet packet)
    {
        if (!running)
            return false;

        foreach (ref subscriber; _subscribers[0.._num_subscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.outgoing) && subscriber.filter.match(packet))
                subscriber.recv_packet(packet, this, PacketDirection.outgoing, subscriber.user_data);
        }

        return transmit(packet);
    }

    final void add_address(MACAddress mac, BaseInterface iface)
    {
        assert(mac !in macTable, "MAC address already in use!");
        macTable[mac] = iface;
    }

    final void remove_address(MACAddress mac)
    {
        macTable.remove(mac);
    }

    final BaseInterface find_mac_address(MACAddress mac)
    {
        BaseInterface* i = mac in macTable;
        if (i)
            return *i;
        return null;
    }

    ushort pcap_type() const
        => 1; // LINKTYPE_ETHERNET

    void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
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

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const nothrow @nogc
    {
        if (buffer.length < "interface:".length + name.length)
            return -1; // Not enough space
        return buffer.concat("interface:", name[]).length;
    }

protected:
    Status _status;
    ushort _pvid;
    ushort _mtu;        // 0 = auto
    ushort _l2mtu;
    ushort _max_l2mtu;  // 0 = unspecified/unknown

    BufferOverflowBehaviour _send_behaviour;
    BufferOverflowBehaviour _recv_behaviour;

    override void update()
    {
        assert(_status.link_status == LinkStatus.up, "Interface is not online, it shouldn't be in Running state!");
    }

    override void set_online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        super.set_online();
    }

    override void set_offline()
    {
        super.set_offline();
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
    }

    abstract bool transmit(ref Packet packet);

    void slave_incoming(ref Packet packet, byte child_id)
    {
        assert(false, "Override this method to implement a _master interface");
    }

    bool bind_vlan(BaseInterface vlan_interface, bool remove)
    {
        // Override this method for interfaces supporting vlan's, and return true to indicate that vlan sub-interfaces are accepted
        return false;
    }

    // TODO: this package section should be refactored out of existence!
package:
    BaseInterface _master;
    byte _slave_id;

    Packet[] _send_queue;

    MACAddress generate_mac_address() pure
    {
        import urt.crc;
        alias crc_fun = calculate_crc!(Algorithm.crc32_iso_hdlc);

        enum ushort MAGIC = 0x1337;

        uint crc = crc_fun(name[]);
        MACAddress addr = MACAddress(0x02, MAGIC >> 8, MAGIC & 0xFF, crc & 0xFF, (crc >> 8) & 0xFF, crc >> 24);
        if (addr.b[5] < 100 || addr.b[5] >= 240)
            addr.b[5] ^= 0x80;
        return addr;
    }

    void dispatch(ref Packet packet)
    {
        // update the stats
        ++_status.recv_packets;
        _status.recv_bytes += packet.length;

        // check if we ever saw the sender before...
        if (!packet.eth.src.is_multicast)
        {
            if (find_mac_address(packet.eth.src) is null)
                add_address(packet.eth.src, this);
        }

        if (_master)
            _master.slave_incoming(packet, _slave_id);
        else
        {
            foreach (ref subscriber; _subscribers[0.._num_subscribers])
            {
                if ((subscriber.filter.direction & PacketDirection.incoming) && subscriber.filter.match(packet))
                    subscriber.recv_packet(packet, this, PacketDirection.incoming, subscriber.user_data);
            }
        }
    }

//private:
protected: // TODO: should probably be private?
    InterfaceSubscriber[4] _subscribers;
    ubyte _num_subscribers;
}


class InterfaceModule : Module
{
    mixin DeclareModule!"interface";
nothrow @nogc:

    Collection!BaseInterface interfaces;
    Collection!VLANInterface vlan_interfaces;

    override void init()
    {
        g_app.register_enum!ConnectionStatus();
        g_app.register_enum!LinkStatus();

//        // HACK: BaseInterface collection is not a natural collection, so we'll init it here...
//        ref Collection!BaseInterface* c = collection_for!BaseInterface();
//        assert(c is null, "Collection has been registered before!");
//        c = &interfaces;
//
//        g_app.register_collection(interfaces, "/interface");

        g_app.console.register_collection("/interface", interfaces);
        g_app.console.register_collection("/interface/vlan", vlan_interfaces);
//        g_app.console.register_command!print("/interface", this);
    }

    override void update()
    {
        vlan_interfaces.update_all();
    }

    final String add_interface_name(Session session, const(char)[] name, const(char)[] default_name_prefix)
    {
        if (name.empty)
            name = interfaces.generate_name(default_name_prefix);
        else if (interfaces.exists(name))
        {
            session.write_line("Interface '", name, " already exists");
            return String();
        }

        return name.makeString(g_app.allocator);
    }

    import urt.meta.nullable;

    // /interface/print command
    void print(Session session, Nullable!bool stats)
    {
        import urt.util;

        size_t name_len = 4;
        size_t type_len = 4;
        foreach (iface; interfaces.values)
        {
            name_len = max(name_len, iface.name.length);
            type_len = max(type_len, iface.type.length);

            // TODO: MTU stuff?
        }

        session.write_line("Flags: R - RUNNING; S - SLAVE");
        if (stats)
        {
            size_t rx_len = 7;
            size_t tx_len = 7;
            size_t rp_len = 9;
            size_t tp_len = 9;
            size_t rd_len = 7;
            size_t td_len = 7;

            foreach (iface; interfaces.values)
            {
                rx_len = max(rx_len, iface.status.recv_bytes.format_int(null));
                tx_len = max(tx_len, iface.status.send_bytes.format_int(null));
                rp_len = max(rp_len, iface.status.recv_packets.format_int(null));
                tp_len = max(tp_len, iface.status.send_packets.format_int(null));
                rd_len = max(rd_len, iface.status.recv_dropped.format_int(null));
                td_len = max(td_len, iface.status.send_dropped.format_int(null));
            }

            session.writef(" ID     {0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {12, *13}\n",
                            "NAME", name_len,
                            "RX-BYTE", rx_len, "TX-BYTE", tx_len,
                            "RX-PACKET", rp_len, "TX-PACKET", tp_len,
                            "RX-DROP", rd_len, "TX-DROP", td_len);

            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {1}{2}  {3, -*4}  {5, *6}  {7, *8}  {9, *10}  {11, *12}  {13, *14}  {15, *16}\n",
                                i, iface.status.link_status ? 'R' : ' ', iface._master ? 'S' : ' ',
                                iface.name, name_len,
                                iface.status.recv_bytes, rx_len, iface.status.send_bytes, tx_len,
                                iface.status.recv_packets, rp_len, iface.status.send_packets, tp_len,
                                iface.status.recv_dropped, rd_len, iface.status.send_dropped, td_len);
                ++i;
            }
        }
        else
        {
            session.writef(" ID     {0, -*1}  {2, -*3}  MAC-ADDRESS\n", "NAME", name_len, "TYPE", type_len);
            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {6}{7}  {1, -*2}  {3, -*4}  {5}\n", i, iface.name, name_len, iface.type, type_len, iface.mac, iface.status.link_status ? 'R' : ' ', iface._master ? 'S' : ' ');
                ++i;
            }
        }
    }
}


private:
