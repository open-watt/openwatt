module router.iface;

import urt.conv;
import urt.map;
import urt.mem.ring;
import urt.mem.string;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console;
import manager.plugin;

public import router.iface.packet;

// package modules...
public static import router.iface.bridge;
public static import router.iface.can;
public static import router.iface.modbus;
public static import router.iface.tesla;
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
    alias FilterCallback = bool delegate(ref const Packet p) nothrow @nogc;

    MACAddress src;
    MACAddress dst;
    ushort etherType;
    ushort enmsSubType;
    ushort vlan;
    FilterCallback customFilter;
    PacketDirection direction = PacketDirection.Incoming;

    bool match(ref const Packet p)
    {
        if (etherType && p.etherType != etherType)
            return false;
        if (enmsSubType && p.etherSubType != enmsSubType)
            return false;
        if (vlan && p.vlan != vlan)
            return false;
        if (src && p.src != src)
            return false;
        if (dst && p.dst != dst)
            return false;
        if (customFilter)
            return customFilter(p);
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

struct InterfaceStatus
{
    SysTime linkStatusChangeTime;
    bool linkStatus;
    int linkDowns;

    ulong sendBytes;
    ulong recvBytes;
    uint sendPackets;
    uint recvPackets;
    uint sendDropped;
    uint recvDropped;
}

// MAC: 02:xx:xx:ra:nd:yy
//      02:13:37:xx:xx:yy
//      02:AC:1D:xx:xx:yy
//      02:C0:DE:xx:xx:yy
//      02:BA:BE:xx:xx:yy
//      02:DE:AD:xx:xx:yy
//      02:FE:ED:xx:xx:yy
//      02:B0:0B:xx:xx:yy

class BaseInterface
{
nothrow @nogc:

    InterfaceModule mod_iface;

    String name;
    CacheString type;

    MACAddress mac;
    Map!(MACAddress, BaseInterface) macTable;

    InterfaceSubscriber[4] subscribers;
    ubyte numSubscribers;


    InterfaceStatus status;

    BufferOverflowBehaviour sendBehaviour;
    BufferOverflowBehaviour recvBehaviour;

    BaseInterface master;

    this(InterfaceModule m, String name, const(char)[] type)
    {
        import urt.lifetime;

        this.mod_iface = m;
        this.name = name.move;
        this.type = type.addString();

        mac = generateMacAddress();
        addAddress(mac, this);
    }

    void update()
    {
    }

    ref const(InterfaceStatus) getStatus() const
        => status;

    void subscribe(InterfaceSubscriber.PacketHandler packetHandler, ref const PacketFilter filter, void* userData = null)
    {
        subscribers[numSubscribers++] = InterfaceSubscriber(filter, packetHandler, userData);
    }

    bool send(MACAddress dest, const(void)[] message, EtherType type, ENMS_SubType subType = ENMS_SubType.Unspecified)
    {
        Packet p = Packet(message);
        p.src = mac;
        p.dst = dest;
        p.vlan = 0; // TODO: if this is a vlan interface?
        p.etherType = type;
        p.etherSubType = subType;
        p.creationTime = getSysTime();
        return forward(p);
    }

    final bool forward(ref const Packet packet)
    {
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

    void pcapWrite(ref const Packet packet, PacketDirection dir, scope void delegate(const void[] packetData) nothrow @nogc sink) const
    {
        import urt.endian;

        bool isEnms = packet.etherType == EtherType.ENMS;

        // write ethernet header...
        struct Header
        {
            MACAddress dst;
            MACAddress src;
            ubyte[2] type;
            ubyte[2] subType;
        }
        Header h;
        h.dst = packet.dst;
        h.src = packet.src;
        h.type = nativeToBigEndian(packet.etherType);
        if (isEnms)
            h.subType = nativeToBigEndian(packet.etherSubType);
        sink((cast(ubyte*)&h)[0 .. (isEnms ? Header.sizeof : Header.subType.offsetof)]);

        // write packet data
        sink(packet.data);

        if (isEnms && packet.etherSubType == ENMS_SubType.Modbus)
        {
            // wireshark wants RTU packets for its decoder, so we need to append the crc...
            import urt.crc;
            ushort crc = packet.data[3..$].calculateCRC!(Algorithm.CRC16_MODBUS)();
            sink(crc.nativeToLittleEndian());
        }
    }

    int opCmp(const BaseInterface rh) const
        => name[] < rh.name[] ? -1 : name[] > rh.name[] ? 1 : 0;

package:
    Packet[] sendQueue;

    MACAddress generateMacAddress() pure
    {
        import urt.crc;
        alias crcFun = calculateCRC!(Algorithm.CRC32_ISO_HDLC);

        enum ushort MAGIC = 0x1337;

        uint crc = crcFun(name);
        MACAddress addr = MACAddress(0x02, MAGIC >> 8, MAGIC & 0xFF, crc & 0xFF, (crc >> 8) & 0xFF, crc >> 24);
        if (addr.b[5] < 100 || addr.b[5] >= 240)
            addr.b[5] ^= 0x80;
        return addr;
    }

    void dispatch(ref const Packet packet)
    {
        // update the stats
        ++status.recvPackets;
        status.recvBytes += packet.length;

        // check if we ever saw the sender before...
        if (!packet.src.isMulticast)
        {
            if (findMacAddress(packet.src) is null)
                addAddress(packet.src, this);
        }

        foreach (ref subscriber; subscribers[0..numSubscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.Incoming) && subscriber.filter.match(packet))
                subscriber.recvPacket(packet, this, PacketDirection.Incoming, subscriber.userData);
        }
    }

protected:
    abstract bool transmit(ref const Packet packet);
}


class InterfaceModule : Module
{
    mixin DeclareModule!"interface";
nothrow @nogc:

    Map!(const(char)[], BaseInterface) interfaces;

    override void init()
    {
        app.console.registerCommand!print("/interface", this);
    }

    override void update()
    {
        foreach (i; interfaces)
            i.update();
    }

    const(char)[] generateInterfaceName(const(char)[] prefix)
    {
        if (prefix !in interfaces)
            return prefix;
        for (size_t i = 0; i < ushort.max; i++)
        {
            const(char)[] name = tconcat(prefix, i);
            if (name !in interfaces)
                return name;
        }
        return null;
    }

    final String addInterfaceName(Session session, const(char)[] name, const(char)[] defaultName)
    {
        if (name.empty)
            name = generateInterfaceName(defaultName);
        else if (name in interfaces)
        {
            session.writeLine("Interface '", name, " already exists");
            return String();
        }

        return name.makeString(app.allocator);
    }

    final bool addInterface(Session session, BaseInterface iface, const(char)[] pcap)
    {
        interfaces[iface.name[]] = iface;

        if (!pcap.empty)
        {
            import manager.pcap;

            auto mod_pcap = app.moduleInstance!PcapModule;
            PcapInterface* cap = mod_pcap.findInterface(pcap);
            if (!cap)
                session.writeLine("Failed to attach pcap interface '", pcap, "' to '", iface.name, "'; doesn't exist");
            else
                cap.subscribeInterface(iface);
        }

        import urt.log;
        writeInfo("Create ", iface.type, " interface '", iface.name, "' - ", iface.mac);

        return true;
    }

    final void removeInterface(BaseInterface iface)
    {
        assert(iface.name in interfaces, "Interface not found");
        interfaces.remove(iface.name);
    }

    final BaseInterface findInterface(const(char)[] name)
    {
        foreach (i; interfaces)
            if (i.name[] == name[])
                return i;
        return null;
    }

    import urt.meta.nullable;

    // /interface/print command
    void print(Session session, Nullable!bool stats)
    {
        import urt.util;

        size_t nameLen = 4;
        size_t typeLen = 4;
        foreach (i, iface; interfaces)
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

            foreach (i, iface; interfaces)
            {
                rxLen = max(rxLen, iface.getStatus.recvBytes.formatInt(null));
                txLen = max(txLen, iface.getStatus.sendBytes.formatInt(null));
                rpLen = max(rpLen, iface.getStatus.recvPackets.formatInt(null));
                tpLen = max(tpLen, iface.getStatus.sendPackets.formatInt(null));
                rdLen = max(rdLen, iface.getStatus.recvDropped.formatInt(null));
                tdLen = max(tdLen, iface.getStatus.sendDropped.formatInt(null));
            }

            session.writef(" ID     {0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {12, *13}\n",
                            "NAME", nameLen,
                            "RX-BYTE", rxLen, "TX-BYTE", txLen,
                            "RX-PACKET", rpLen, "TX-PACKET", tpLen,
                            "RX-DROP", rdLen, "TX-DROP", tdLen);

            size_t i = 0;
            foreach (iface; interfaces)
            {
                session.writef("{0, 3} {1}{2}  {3, -*4}  {5, *6}  {7, *8}  {9, *10}  {11, *12}  {13, *14}  {15, *16}\n",
                                i, iface.getStatus.linkStatus ? 'R' : ' ', iface.master ? 'S' : ' ',
                                iface.name, nameLen,
                                iface.getStatus.recvBytes, rxLen, iface.getStatus.sendBytes, txLen,
                                iface.getStatus.recvPackets, rpLen, iface.getStatus.sendPackets, tpLen,
                                iface.getStatus.recvDropped, rdLen, iface.getStatus.sendDropped, tdLen);
                ++i;
            }
        }
        else
        {
            session.writef(" ID     {0, -*1}  {2, -*3}  MAC-ADDRESS\n", "NAME", nameLen, "TYPE", typeLen);
            size_t i = 0;
            foreach (iface; interfaces)
            {
                session.writef("{0, 3} {6}{7}  {1, -*2}  {3, -*4}  {5}\n", i, iface.name, nameLen, iface.type, typeLen, iface.mac, iface.getStatus.linkStatus ? 'R' : ' ', iface.master ? 'S' : ' ');
                ++i;
            }
        }
    }
}


private:
