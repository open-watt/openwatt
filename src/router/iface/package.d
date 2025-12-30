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
    DropOldest, // drop oldest data in buffer
    DropNewest, // drop newest data in buffer (or don't add new data to full buffer)
    Fail        // cause the call to fail
}

enum PacketDirection : ubyte
{
    Incoming = 1,
    Outgoing = 2
}

struct PacketFilter
{
nothrow @nogc:
    PacketType type = PacketType.Ethernet;
    PacketDirection direction = PacketDirection.Incoming;
    MACAddress src;
    MACAddress dst;
    ushort etherType;
    union {
        ushort owSubType; // if etherType == EtherType.OW
        ushort etherType2;
    }
    ushort vlan;

    bool match(ref const Packet p)
    {
        if (type != PacketType.Unknown)
        {
            if (type != p.type)
                return false;
            if (type == PacketType.Ethernet)
            {
                if (etherType)
                {
                    if (p.eth.ether_type != etherType)
                    {
                        if (!etherType2 || etherType == EtherType.OW)
                            return false;
                        if (p.eth.ether_type != etherType2)
                            return false;
                    }
                    else if (etherType == EtherType.OW)
                    {
                        if (owSubType && p.eth.ow_sub_type != owSubType)
                            return false;
                    }
                }
                else
                    debug assert(etherType2 == 0, "etherType must be set if etherType 2 is set!");
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
    PacketHandler recvPacket;
    void* userData;
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
    __gshared Property[5] Properties = [ Property.create!("mtu", mtu)(),
                                         Property.create!("actual-mtu", actual_mtu)(),
                                         Property.create!("l2mtu", l2mtu)(),
                                         Property.create!("max-l2mtu", max_l2mtu)(),
                                         Property.create!("pcap", pcap)() ];
nothrow @nogc:

    MACAddress mac;
    Map!(MACAddress, BaseInterface) macTable;

    this(const CollectionTypeInfo* typeInfo, String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(typeInfo, name.move, flags);

        assert(!get_module!InterfaceModule.interfaces.exists(this.name), "HOW DID THIS HAPPEN?");
        get_module!InterfaceModule.interfaces.add(this);

        mac = generateMacAddress();
        addAddress(mac, this);
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

    final const(char)[] pcap() const pure
    {
        assert(false, "TODO: we need to store the pcap thing!");
    }
    final const(char)[] pcap(const(char)[] value)
    {
        // TODO: unsubscribe from old pcap interface, if any...
        import manager.pcap;
        PcapInterface* cap = get_module!PcapModule.findInterface(value);
        if (!cap)
            return tconcat("Failed to attach pcap interface '", value, "' to '", name, "'; doesn't exist");
        else
            cap.subscribeInterface(this);
        return null;
    }


    // API...

    ref const(Status) status() const pure
        => _status;

    final void resetCounters() pure
    {
        _status.linkDowns = 0;
        _status.sendBytes = 0;
        _status.recvBytes = 0;
        _status.sendPackets = 0;
        _status.recvPackets = 0;
        _status.sendDropped = 0;
        _status.recvDropped = 0;
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

    void subscribe(InterfaceSubscriber.PacketHandler packetHandler, ref const PacketFilter filter, void* userData = null)
    {
        subscribers[numSubscribers++] = InterfaceSubscriber(filter, packetHandler, userData);
    }

    void unsubscribe(InterfaceSubscriber.PacketHandler packetHandler)
    {
        foreach (i, ref sub; subscribers[0..numSubscribers])
        {
            if (sub.recvPacket is packetHandler)
            {
                // remove this subscriber
                if (i < --numSubscribers)
                    sub = subscribers[numSubscribers];
                return;
            }
        }
    }

    bool send(MACAddress dest, const(void)[] message, EtherType type, OW_SubType subType = OW_SubType.Unspecified)
    {
        if (!running)
            return false;

        Packet p;
        ref eth = p.init!Ethernet(message);
        eth.src = mac;
        eth.dst = dest;
        eth.ether_type = type;
        eth.ow_sub_type = subType;
        return forward(p);
    }

    final bool forward(ref Packet packet)
    {
        if (!running)
            return false;

        foreach (ref subscriber; subscribers[0..numSubscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.Outgoing) && subscriber.filter.match(packet))
                subscriber.recvPacket(packet, this, PacketDirection.Outgoing, subscriber.userData);
        }

        return transmit(packet);
    }

    final void addAddress(MACAddress mac, BaseInterface iface)
    {
        assert(mac !in macTable, "MAC address already in use!");
        macTable[mac] = iface;
    }

    final void removeAddress(MACAddress mac)
    {
        macTable.remove(mac);
    }

    final BaseInterface findMacAddress(MACAddress mac)
    {
        BaseInterface* i = mac in macTable;
        if (i)
            return *i;
        return null;
    }

    ushort pcapType() const
        => 1; // LINKTYPE_ETHERNET

    void pcapWrite(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packetData) nothrow @nogc sink) const
    {
        import urt.endian;

        bool isOW = packet.eth.ether_type == EtherType.OW;

        // write ethernet header...
        struct Header
        {
            MACAddress dst;
            MACAddress src;
            ubyte[2] type;
            ubyte[2] subType;
        }
        Header h;
        h.dst = packet.eth.dst;
        h.src = packet.eth.src;
        h.type = nativeToBigEndian(packet.eth.ether_type);
        if (isOW)
            h.subType = nativeToBigEndian(packet.eth.ow_sub_type);
        sink((cast(ubyte*)&h)[0 .. (isOW ? Header.sizeof : Header.subType.offsetof)]);

        // write packet data
        sink(packet.data);

        if (isOW && packet.eth.ow_sub_type == OW_SubType.Modbus)
        {
            // wireshark wants RTU packets for its decoder, so we need to append the crc...
            import urt.crc;
            ushort crc = packet.data[3..$].calculate_crc!(Algorithm.crc16_modbus)();
            sink(crc.nativeToLittleEndian());
        }
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
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

    BufferOverflowBehaviour sendBehaviour;
    BufferOverflowBehaviour recvBehaviour;

    override void update()
    {
        assert(_status.linkStatus == Status.Link.Up, "Interface is not online, it shouldn't be in Running state!");
    }

    override void set_online()
    {
        _status.linkStatus = Status.Link.Up;
        _status.linkStatusChangeTime = getSysTime();
        super.set_online();
    }

    override void set_offline()
    {
        super.set_offline();
        _status.linkStatus = Status.Link.Down;
        _status.linkStatusChangeTime = getSysTime();
        ++_status.linkDowns;
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

    Packet[] sendQueue;

    MACAddress generateMacAddress() pure
    {
        import urt.crc;
        alias crcFun = calculate_crc!(Algorithm.crc32_iso_hdlc);

        enum ushort MAGIC = 0x1337;

        uint crc = crcFun(name);
        MACAddress addr = MACAddress(0x02, MAGIC >> 8, MAGIC & 0xFF, crc & 0xFF, (crc >> 8) & 0xFF, crc >> 24);
        if (addr.b[5] < 100 || addr.b[5] >= 240)
            addr.b[5] ^= 0x80;
        return addr;
    }

    void dispatch(ref Packet packet)
    {
        // update the stats
        ++_status.recvPackets;
        _status.recvBytes += packet.length;

        // check if we ever saw the sender before...
        if (!packet.eth.src.is_multicast)
        {
            if (findMacAddress(packet.eth.src) is null)
                addAddress(packet.eth.src, this);
        }

        if (_master)
            _master.slave_incoming(packet, _slave_id);
        else
        {
            foreach (ref subscriber; subscribers[0..numSubscribers])
            {
                if ((subscriber.filter.direction & PacketDirection.Incoming) && subscriber.filter.match(packet))
                    subscriber.recvPacket(packet, this, PacketDirection.Incoming, subscriber.userData);
            }
        }
    }

//private:
protected: // TODO: should probably be private?
    InterfaceSubscriber[4] subscribers;
    ubyte numSubscribers;
}


class InterfaceModule : Module
{
    mixin DeclareModule!"interface";
nothrow @nogc:

    Collection!BaseInterface interfaces;
    Collection!VLANInterface vlan_interfaces;

    override void init()
    {
        // HACK: BaseInterface collection is not a natural collection, so we'll init it here...
        ref Collection!BaseInterface* c = collection_for!BaseInterface();
        assert(c is null, "Collection has been registered before!");
        c = &interfaces;

        g_app.console.registerCollection("/interface/vlan", vlan_interfaces);
        g_app.console.registerCommand!print("/interface", this);
    }

    override void update()
    {
        vlan_interfaces.update_all();
    }

    final String addInterfaceName(Session session, const(char)[] name, const(char)[] defaultNamePrefix)
    {
        if (name.empty)
            name = interfaces.generate_name(defaultNamePrefix);
        else if (interfaces.exists(name))
        {
            session.writeLine("Interface '", name, " already exists");
            return String();
        }

        return name.makeString(g_app.allocator);
    }

    import urt.meta.nullable;

    // /interface/print command
    void print(Session session, Nullable!bool stats)
    {
        import urt.util;

        size_t nameLen = 4;
        size_t typeLen = 4;
        foreach (iface; interfaces.values)
        {
            nameLen = max(nameLen, iface.name.length);
            typeLen = max(typeLen, iface.type.length);

            // TODO: MTU stuff?
        }

        session.writeLine("Flags: R - RUNNING; S - SLAVE");
        if (stats)
        {
            size_t rxLen = 7;
            size_t txLen = 7;
            size_t rpLen = 9;
            size_t tpLen = 9;
            size_t rdLen = 7;
            size_t tdLen = 7;

            foreach (iface; interfaces.values)
            {
                rxLen = max(rxLen, iface.status.recvBytes.format_int(null));
                txLen = max(txLen, iface.status.sendBytes.format_int(null));
                rpLen = max(rpLen, iface.status.recvPackets.format_int(null));
                tpLen = max(tpLen, iface.status.sendPackets.format_int(null));
                rdLen = max(rdLen, iface.status.recvDropped.format_int(null));
                tdLen = max(tdLen, iface.status.sendDropped.format_int(null));
            }

            session.writef(" ID     {0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {12, *13}\n",
                            "NAME", nameLen,
                            "RX-BYTE", rxLen, "TX-BYTE", txLen,
                            "RX-PACKET", rpLen, "TX-PACKET", tpLen,
                            "RX-DROP", rdLen, "TX-DROP", tdLen);

            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {1}{2}  {3, -*4}  {5, *6}  {7, *8}  {9, *10}  {11, *12}  {13, *14}  {15, *16}\n",
                                i, iface.status.linkStatus ? 'R' : ' ', iface._master ? 'S' : ' ',
                                iface.name, nameLen,
                                iface.status.recvBytes, rxLen, iface.status.sendBytes, txLen,
                                iface.status.recvPackets, rpLen, iface.status.sendPackets, tpLen,
                                iface.status.recvDropped, rdLen, iface.status.sendDropped, tdLen);
                ++i;
            }
        }
        else
        {
            session.writef(" ID     {0, -*1}  {2, -*3}  MAC-ADDRESS\n", "NAME", nameLen, "TYPE", typeLen);
            size_t i = 0;
            foreach (iface; interfaces.values)
            {
                session.writef("{0, 3} {6}{7}  {1, -*2}  {3, -*4}  {5}\n", i, iface.name, nameLen, iface.type, typeLen, iface.mac, iface.status.linkStatus ? 'R' : ' ', iface._master ? 'S' : ' ');
                ++i;
            }
        }
    }
}


private:
