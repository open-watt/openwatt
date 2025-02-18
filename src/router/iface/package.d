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


enum BufferOverflowBehaviour : byte
{
    DropOldest, // drop oldest data in buffer
    DropNewest, // drop newest data in buffer (or don't add new data to full buffer)
    Fail        // cause the call to fail
}

struct PacketFilter
{
    alias FilterCallback = bool delegate(ref const Packet p) nothrow @nogc;

    MACAddress src;
    MACAddress dst;
    ushort etherType;
    ushort enmsSubType;
    ushort vlan;
    FilterCallback customFilter;

    bool match(ref const Packet p) nothrow @nogc
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
    alias IncomingPacketHandler = void delegate(ref const Packet p, BaseInterface i, void* u) nothrow @nogc;

    PacketFilter filter;
    IncomingPacketHandler recvPacket;
    void* userData;
}

struct InterfaceStatus
{
    MonoTime linkStatusChangeTime;
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

    InterfaceModule.Instance mod_iface;

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

    this(InterfaceModule.Instance m, String name, const(char)[] type) nothrow @nogc
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

    void subscribe(InterfaceSubscriber.IncomingPacketHandler packetHandler, ref const PacketFilter filter, void* userData = null) nothrow @nogc
    {
        subscribers[numSubscribers++] = InterfaceSubscriber(filter, packetHandler, userData);
    }

    bool send(MACAddress dest, const(void)[] message, EtherType type, ENMS_SubType subType = ENMS_SubType.Unspecified) nothrow @nogc
    {
        Packet p = Packet(message);
        p.src = mac;
        p.dst = dest;
        p.vlan = 0; // TODO: if this is a vlan interface?
        p.etherType = type;
        p.etherSubType = subType;
        p.creationTime = getTime();
        return forward(p);
    }

    abstract bool forward(ref const Packet packet) nothrow @nogc;

    final void addAddress(MACAddress mac, BaseInterface iface) nothrow @nogc
    {
        assert(mac !in macTable, "MAC address already in use!");
        macTable[mac] = iface;
    }

    final void removeAddress(MACAddress mac) nothrow @nogc
    {
        macTable.remove(mac);
    }

    final BaseInterface findMacAddress(MACAddress mac) nothrow @nogc
    {
        BaseInterface* i = mac in macTable;
        if (i)
            return *i;
        return null;
    }

package:
    Packet[] sendQueue;

    MACAddress generateMacAddress() pure nothrow @nogc
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

    void dispatch(ref const Packet packet) nothrow @nogc
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
            if (subscriber.filter.match(packet))
                subscriber.recvPacket(packet, this, subscriber.userData);
        }
    }
}


class InterfaceModule : Plugin
{
    mixin RegisterModule!"interface";

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;
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

        final void addInterface(BaseInterface iface)
        {
            assert(iface.name !in interfaces, "Interface already exists");
            interfaces[iface.name] = iface;
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
}


private:
