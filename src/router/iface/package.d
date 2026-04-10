module router.iface;

import urt.conv;
import urt.map;
import urt.lifetime;
import urt.mem.ring;
import urt.mem.string;
import urt.si.unit;
import urt.si.quantity;
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
public static import router.iface.ethernet;
public static import router.iface.vlan;
public static import router.iface.wifi;
public static import router.iface.zigbee;

nothrow @nogc:

alias Milliseconds = Quantity!(float, ScaledUnit(Second, -3));

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

enum MessageState
{
    queued,
    in_flight,
    complete,
    failed,
    aborted,
    timeout,
    expired,
    dropped
}

alias MessageCallback = void delegate(int msg_handle, MessageState state) nothrow @nogc;


struct TagAllocator
{
nothrow @nogc pure:
    int alloc()
    {
        foreach (_; 0 .. 255)
        {
            ++_next;
            if (_next == 0)
                _next = 1;
            if (!(_in_use[_next / _tag_bits] & (size_t(1) << (_next % _tag_bits))))
            {
                _in_use[_next / _tag_bits] |= size_t(1) << (_next % _tag_bits);
                return _next;
            }
        }
        return -1;
    }

    void free(ubyte tag)
    {
        _in_use[tag / _tag_bits] &= ~(size_t(1) << (tag % _tag_bits));
    }

private:
    enum _tag_bits = size_t.sizeof * 8;

    ubyte _next;
    size_t[256 / _tag_bits] _in_use;
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
    __gshared Property[24] Properties = [ Property.create!("actual-mtu", actual_mtu, null, "d")(),
                                          Property.create!("mtu", mtu, null, "d")(),
                                          Property.create!("l2mtu", l2mtu)(),
                                          Property.create!("max-l2mtu", max_l2mtu, null, "d")(),
                                          Property.create!("pcap", pcap)(),
                                          Property.create!("last_status_change_time", last_status_change_time, "status")(),
                                          Property.create!("connected", connected, "status", "d")(),
                                          Property.create!("link_status", link_status, "status", "d")(),
                                          Property.create!("link_downs", link_downs, "status")(),
                                          Property.create!("tx_link_speed", tx_link_speed, "status")(),
                                          Property.create!("rx_link_speed", rx_link_speed, "status")(),
                                          Property.create!("tx_bytes", tx_bytes, "traffic", "d")(),
                                          Property.create!("rx_bytes", rx_bytes, "traffic", "d")(),
                                          Property.create!("tx_packets", tx_packets, "traffic", "d")(),
                                          Property.create!("rx_packets", rx_packets, "traffic", "d")(),
                                          Property.create!("tx_dropped", tx_dropped, "traffic", "d")(),
                                          Property.create!("rx_dropped", rx_dropped, "traffic", "d")(),
                                          Property.create!("tx_rate", tx_rate, "traffic", "d")(),
                                          Property.create!("rx_rate", rx_rate, "traffic", "d")(),
                                          Property.create!("tx_rate_max", tx_rate_max, "traffic")(),
                                          Property.create!("rx_rate_max", rx_rate_max, "traffic")(),
                                          Property.create!("avg_queue_time", avg_queue_time, "traffic")(),
                                          Property.create!("avg_service_time", avg_service_time, "traffic")(),
                                          Property.create!("max_service_time", max_service_time, "traffic")() ];
nothrow @nogc:

    enum type_name = "interface";
    enum collection_id = CollectionType.interface_;

    MACAddress mac;
    Map!(MACAddress, BaseInterface) macTable;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);

        mac = generate_mac_address();
        add_address(mac, this);
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
    ulong tx_bytes() const => _status.tx_bytes;
    ulong rx_bytes() const => _status.rx_bytes;
    ulong tx_packets() const => _status.tx_packets;
    ulong rx_packets() const => _status.rx_packets;
    ulong tx_dropped() const => _status.tx_dropped;
    ulong rx_dropped() const => _status.rx_dropped;
    ulong rx_rate() const => _status.rx_rate;
    ulong tx_rate() const => _status.tx_rate;
    ulong tx_rate_max() const => _status.tx_rate_max;
    ulong rx_rate_max() const => _status.rx_rate_max;
    Milliseconds avg_queue_time() const => Milliseconds(float(_status.avg_queue_us) / 1000);
    Milliseconds avg_service_time() const => Milliseconds(float(_status.avg_service_us) / 1000);
    Milliseconds max_service_time() const => Milliseconds(float(_status.max_service_us) / 1000);

    // API...

    ref const(IfStatus) status() const pure
        => _status;

    final void reset_counters()
    {
        _status.link_downs = 0;
        _status.tx_bytes = 0;
        _status.rx_bytes = 0;
        _status.tx_packets = 0;
        _status.rx_packets = 0;
        _status.tx_dropped = 0;
        _status.rx_dropped = 0;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        _status.tx_rate_max = 0;
        _status.rx_rate_max = 0;
        _status.avg_queue_us = 0;
        _status.avg_service_us = 0;
        _status.max_service_us = 0;
        _last_tx_bytes = 0;
        _last_rx_bytes = 0;
        _last_bitrate_sample = getTime();
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    BaseInterface set_master(BaseInterface master, byte slave_id) pure
    {
        if (_master)
            return _master;
        _master = master;
        _slave_id = slave_id;
        _flags |= ObjectFlags.slave;
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

    int send(MACAddress dest, const(void)[] message, EtherType type, MessageCallback callback = null)
    {
        Packet p;
        ref eth = p.init!Ethernet(message);
        eth.src = mac;
        eth.dst = dest;
        eth.ether_type = type;
        return forward(p, callback);
    }

    int forward(ref Packet packet, MessageCallback callback = null)
    {
        if (!running)
        {
            if (callback)
                callback(-1, MessageState.failed);
            return -1;
        }

        foreach (ref subscriber; _subscribers[0.._num_subscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.outgoing) && subscriber.filter.match(packet))
                subscriber.recv_packet(packet, this, PacketDirection.outgoing, subscriber.user_data);
        }

        int result = transmit(packet, callback);
        if (result <= 0 && callback)
            callback(result, result == 0 ? MessageState.complete : MessageState.failed);
        return result;
    }

    void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle > 0, "Invalid message handle");
        assert(false, "Interface does not support message cancellation");
    }

    MessageState msg_state(int msg_handle) const
    {
        assert(msg_handle == 0, "Invalid message handle");
        return MessageState.complete;
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
    IfStatus _status;
    ushort _pvid;
    ushort _mtu;        // 0 = auto
    ushort _l2mtu;
    ushort _max_l2mtu;  // 0 = unspecified/unknown

    BufferOverflowBehaviour _send_behaviour;
    BufferOverflowBehaviour _recv_behaviour;

    MonoTime _last_bitrate_sample;
    ulong _last_tx_bytes;
    ulong _last_rx_bytes;

    override void update()
    {
        assert(_status.link_status == LinkStatus.up, "Interface is not online, it shouldn't be in Running state!");

        MonoTime now = getTime();
        if ((now - _last_bitrate_sample) >= 1.seconds)
        {
            ulong elapsed_us = (now - _last_bitrate_sample).as!"usecs";
            _status.tx_rate = (_status.tx_bytes - _last_tx_bytes) * 1_000_000 / elapsed_us;
            _status.rx_rate = (_status.rx_bytes - _last_rx_bytes) * 1_000_000 / elapsed_us;

            if (_status.tx_rate > _status.tx_rate_max)
                _status.tx_rate_max = _status.tx_rate;
            if (_status.rx_rate > _status.rx_rate_max)
                _status.rx_rate_max = _status.rx_rate;

            _last_tx_bytes = _status.tx_bytes;
            _last_rx_bytes = _status.rx_bytes;
            _last_bitrate_sample = now;
        }
    }

    override void online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        _last_bitrate_sample = getTime();
        _last_tx_bytes = _status.tx_bytes;
        _last_rx_bytes = _status.rx_bytes;
    }

    override void offline()
    {
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        _status.avg_queue_us = 0;
        _status.avg_service_us = 0;
        _status.max_service_us = 0;
    }

    abstract int transmit(ref Packet packet, MessageCallback callback = null);

    final void dispatch(ref Packet packet)
    {
        ++_status.rx_packets;
        _status.rx_bytes += packet.length;

        if (packet.type == PacketType.ethernet && !packet.eth.src.is_multicast)
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

    void slave_incoming(ref Packet packet, byte child_id)
    {
        assert(false, "Override this method to implement a _master interface");
    }

    bool bind_vlan(BaseInterface vlan_interface, bool remove)
    {
        // Override this method for interfaces supporting vlan's, and return true to indicate that vlan sub-interfaces are accepted
        return false;
    }

    final MACAddress generate_mac_address() pure
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

    // TODO: this package section should be refactored out of existence!
package:
    BaseInterface _master;
    byte _slave_id;

    Packet[] _send_queue;

//private:
protected: // TODO: should probably be private?
    InterfaceSubscriber[4] _subscribers;
    ubyte _num_subscribers;
}


class InterfaceModule : Module
{
    mixin DeclareModule!"interface";
nothrow @nogc:

    override void pre_init()
    {
        g_app.register_enum!ConnectionStatus();
        g_app.register_enum!LinkStatus();

        g_app.console.register_collection!BaseInterface("/interface");
    }

    override void init()
    {
        g_app.console.register_collection!VLANInterface("/interface/vlan");
    }

    override void update()
    {
        Collection!BaseInterface().update_all();
    }

    final String add_interface_name(Session session, const(char)[] name, const(char)[] default_name_prefix)
    {
        if (name.empty)
            name = Collection!BaseInterface().generate_name(default_name_prefix);
        else if (Collection!BaseInterface().get(name))
        {
            session.write_line("Interface '", name, " already exists");
            return String();
        }

        return name.makeString(g_app.allocator);
    }

    import urt.meta.nullable;

/+ // TODO: generic print does this now, but we need to improve generic print to show the right columns!!
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
                rx_len = max(rx_len, iface.status.rx_bytes.format_int(null));
                tx_len = max(tx_len, iface.status.tx_bytes.format_int(null));
                rp_len = max(rp_len, iface.status.rx_packets.format_int(null));
                tp_len = max(tp_len, iface.status.tx_packets.format_int(null));
                rd_len = max(rd_len, iface.status.rx_dropped.format_int(null));
                td_len = max(td_len, iface.status.tx_dropped.format_int(null));
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
                                iface.status.rx_bytes, rx_len, iface.status.tx_bytes, tx_len,
                                iface.status.rx_packets, rp_len, iface.status.tx_packets, tp_len,
                                iface.status.rx_dropped, rd_len, iface.status.tx_dropped, td_len);
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
+/
}


private:
