module manager.pcap;

import urt.array;
import urt.file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.string;
import urt.system;
import urt.time;
import urt.util : align_up, swap;

import manager.plugin;
import manager.console;

import router.iface;

nothrow @nogc:


enum LinkType : ushort
{
    ETHERNET = 1, // IEEE 802.3 Ethernet
    RAW = 101, // Raw IP; the packet begins with an IPv4 or IPv6 header, with the version field of the header indicating whether it's an IPv4 or IPv6 header
    IPV4 = 228, // Raw IPv4; the packet begins with an IPv4 header
    IPV6 = 229, // Raw IPv6; the packet begins with an IPv6 header
    IEEE802_11 = 105, // IEEE 802.11 wireless LAN
    IEEE802_11_RADIOTAP = 127, // Radiotap link-layer information followed by an 802.11 header
    IEEE802_15_4_WITHFCS = 195, // IEEE 802.15.4 Low-Rate Wireless Networks, with each packet having the FCS at the end of the frame
    IEEE802_15_4_NONASK_PHY = 215, // IEEE 802.15.4 Low-Rate Wireless Networks, with each packet having the FCS at the end of the frame, and with the PHY-level data for the O-QPSK, BPSK, GFSK, MSK, and RCC DSS BPSK PHYs (4 octets of 0 as preamble, one octet of SFD, one octet of frame length + reserved bit) preceding the MAC-layer data (starting with the frame control field)
    IEEE802_15_4_NOFCS = 230, // IEEE 802.15.4 Low-Rate Wireless Network, without the FCS at the end of the frame
    IEEE802_15_4_TAP = 283, // IEEE 802.15.4 Low-Rate Wireless Networks, with a pseudo-header (https://github.com/jkcko/ieee802.15.4-tap/blob/master/IEEE%20802.15.4%20TAP%20Link%20Type%20Specification.pdf) containing TLVs with metadata preceding the 802.15.4 header
    CAN20B = 190, // Controller Area Network (CAN) v. 2.0B
    CAN_SOCKETCAN = 227, // CAN (Controller Area Network) frames, with a pseudo-header (https://www.tcpdump.org/linktypes/LINKTYPE_CAN_SOCKETCAN.html) followed by the frame payload
    I2C_LINUX = 209, // Linux I2C packets (https://www.tcpdump.org/linktypes/LINKTYPE_I2C_LINUX.html)
    LORATAP = 270 // LoRaTap pseudo-header (https://github.com/eriknl/LoRaTap/blob/master/README.md), followed by the payload, which is typically the PHYPayload from the LoRaWan specification
}

struct PcapInterface
{
nothrow @nogc:

    bool openFile(const char[] filename, bool overwrite = false)
    {
        if (pcapFile.is_open)
            return false;

        // open file
        Result r = pcapFile.open(filename, overwrite ? FileOpenMode.WriteTruncate : FileOpenMode.WriteAppend, FileOpenFlags.Sequential);
        if (r != Result.success)
            return false;

        startOffset = pcapFile.get_pos();

        // write section header...
        auto buffer = Array!ubyte(Reserve, 256);

        SectionHeaderBlock shb;
        buffer ~= shb.asBytes;

        SystemInfo sysInfo = get_sysinfo();
        buffer.writeOption(2, sysInfo.processor); // shb_hardware
        buffer.writeOption(3, sysInfo.os_name); // shb_os
        buffer.writeOption(4, "OpenWatt"); // shb_userappl
        buffer.writeOption(0, null);

        buffer.writeBlockLen();
        write(buffer[]);

        return true;
    }

    bool openRemote(const char[] remotehost)
    {
        return false;
    }

    void close()
    {
        // update section header length
        ulong endOffset = pcapFile.get_pos();
        pcapFile.set_pos(startOffset + SectionHeaderBlock.sectionLength.offsetof);
        size_t written;
        pcapFile.write((endOffset - startOffset).asBytes, written);
        assert(written == 8);

        // close file
        pcapFile.close();
    }

    bool enable(bool enable)
        => enabled.swap(enable);

    void setBufferParams(Duration maxTime = 0.seconds, size_t maxBytes = 0)
    {
        maxBufferTime = maxTime;
        maxBufferBytes = maxBytes;
    }

    void subscribeInterface(BaseInterface iface)
    {
        auto filter = PacketFilter(direction: cast(PacketDirection)(PacketDirection.Incoming | PacketDirection.Outgoing));

        iface.subscribe(&packetHandler, filter);
    }

    void flush()
    {
        lastUpdate = getTime();

        foreach (ref InterfacePacketBuffer ib; packetBuffers.values)
        {
            if (ib.packetBuffer.empty)
                continue;

            write(ib.packetBuffer[]);
            ib.packetBuffer.clear();
        }
    }

    void write(const void[] data)
    {
        // TODO: should we actually just bail? maybe something more particular?
        if (!pcapFile.is_open)
            return;

        size_t written;
        pcapFile.write(data, written);
        assert(written == data.length, "Write length wrong! ... what to do?");
        // TODO: what to do? try again?
    }

    void update()
    {
        if (getTime() - lastUpdate < maxBufferTime)
            return;
        flush();
    }

private:

    String name;
    Map!(BaseInterface, InterfacePacketBuffer) packetBuffers;

    ulong startOffset;
    MonoTime lastUpdate;

    File pcapFile;

    uint nextInterfaceIndex = 0;
    bool enabled = true;

    Duration maxBufferTime;
    size_t maxBufferBytes;

    struct InterfacePacketBuffer
    {
        BaseInterface iface;
        int index = -1;
        ushort linkType;

        Array!ubyte packetBuffer;
    }

    void packetHandler(ref const Packet p, BaseInterface i, PacketDirection dir, void*)
    {
        writePacket(p, i, dir);
    }

    void writePacket(ref const Packet p, BaseInterface i, PacketDirection dir)
    {
        import router.iface.zigbee;

        if (!enabled)
            return;

        InterfacePacketBuffer* ib = packetBuffers.get(i);
        if (!ib)
        {
            ib = packetBuffers.insert(i, InterfacePacketBuffer(i, nextInterfaceIndex++, i.pcapType()));

            // write IDB header...
            auto buffer = Array!ubyte(Reserve, 256);

            InterfaceDescriptionBlock idb;
            idb.linkType = ib.linkType;
            buffer ~= idb.asBytes;
            buffer.writeOption(2, i.name[]); // if_name
            if (auto z = cast(ZigbeeInterface)i)
                buffer.writeOption(7, z.eui.b[]); // if_EUIaddr
            else
                buffer.writeOption(6, i.mac.b[]); // if_MACaddr
            ubyte ts = 9; // 6 = microseconds, 9 = nanoseconds
            buffer.writeOption(9, (&ts)[0..1]); // if_tsresol
            buffer.writeOption(0, null);
            buffer.writeBlockLen();

            write(buffer[]);
            buffer.clear();
        }

        size_t packetOffset = ib.packetBuffer.length;
        ulong timestamp = unixTimeNs(p.creationTime);

        // write packet block...
        EnhancedPacketBlock epb;
        epb.interfaceID = ib.index;
        epb.timestampHigh = timestamp >> 32;
        epb.timestampLow = cast(uint)timestamp;
//        epb.capturedLength = cast(uint)p.data.length; // write it later
//        epb.originalLength = cast(uint)p.data.length;
        ib.packetBuffer ~= epb.asBytes;
        size_t capturedLengthOffset = ib.packetBuffer.length - 8;

        uint packetLen;
        i.pcapWrite(p, dir, (const void[] packetData) {
            packetLen += cast(uint)packetData.length;
            ib.packetBuffer ~= cast(const ubyte[])packetData;
        });
        ib.packetBuffer.alignBlock();

        // write capture length...
        ib.packetBuffer[][capturedLengthOffset .. capturedLengthOffset + 4] = packetLen.asBytes;
        ib.packetBuffer[][capturedLengthOffset + 4 .. capturedLengthOffset + 8] = packetLen.asBytes;

        // write packet flags:
        uint flags = (dir == PacketDirection.Incoming) ? 1 : 2; // 01 = inbound, 10 = outbound

        // 2-4 Reception type (000 = not specified, 001 = unicast, 010 = multicast, 011 = broadcast, 100 = promiscuous)
        if (p.dst.isBroadcast)
            flags |= 3 << 2;
        else if (p.dst.isMulticast)
            flags |= 2 << 2;
        else
            flags |= 1 << 2;
        ib.packetBuffer.writeOption(2, flags.asBytes); // epb_flags

        // epb_dropcount
        // epb_packetid

        ib.packetBuffer.writeOption(0, null);
        ib.packetBuffer.writeBlockLen(packetOffset);

        if (ib.packetBuffer.length > maxBufferBytes)
            flush();
    }
}

struct PcapServer
{
    // TODO: host a pcap server that other devices can remote in to
    // forward the pcap stream to a PcapInterface...

    // this is for tiny devices with no storage to log packet captures to a central device
}


class PcapModule : Module
{
    mixin DeclareModule!"manager.pcap";
nothrow @nogc:

    Array!(PcapInterface*) interfaces;

    PcapInterface* findInterface(const(char)[] name)
    {
        foreach (PcapInterface* pcap; interfaces)
            if (pcap.name == name)
                return pcap;
        return null;
    }

    override void init()
    {
        g_app.console.registerCommand!add("/tools/pcap", this);
    }

    override void postUpdate()
    {
        foreach (PcapInterface* pcap; interfaces)
            pcap.update();
    }

    import urt.meta.nullable;

    // /tools/pcap/add command
    void add(Session session, const(char)[] name, const(char)[] file)
    {
        if (name.empty)
        {
            session.writeLine("PCAP interface must have a name");
            return;
        }
        foreach (PcapInterface* pcap; interfaces)
        {
            if (pcap.name == name)
            {
                session.writeLine("PCAP interface '", name, "' already exists");
                return;
            }
        }
        String n = name.makeString(g_app.allocator);

        PcapInterface* pcap = g_app.allocator.allocT!PcapInterface();
        pcap.name = n.move;

        if (!pcap.openFile(file))
        {
            writeInfo("Couldn't open PCAP file '", file, "'");
            g_app.allocator.freeT(pcap);
            return;
        }

        interfaces ~= pcap;

        writeInfo("Create PCAP interface '", name, "' to file: ", file);
    }
}


private:

struct SectionHeaderBlock
{
    uint type = 0x0A0D0D0A;
    uint blockLength = 0;
    uint byteOrderMagic = 0x1A2B3C4D;
    ushort majorVersion = 1;
    ushort minorVersion = 0;
    ulong sectionLength = -1;
}
static assert(SectionHeaderBlock.sizeof == 24);

struct InterfaceDescriptionBlock
{
    uint type = 0x00000001;
    uint blockLength = 0;
    ushort linkType;
    ushort reserved = 0;
    uint snapLength = 0;
}
static assert(InterfaceDescriptionBlock.sizeof == 16);

struct EnhancedPacketBlock
{
    uint type = 0x00000006;
    uint blockLength = 0;
    uint interfaceID;
    uint timestampHigh;
    uint timestampLow;
    uint capturedLength;
    uint originalLength;
}
static assert(EnhancedPacketBlock.sizeof == 28);

ubyte[T.sizeof] asBytes(T)(auto ref const T data)
    => *cast(ubyte[T.sizeof]*)&data;

void writeOption(ref Array!ubyte buffer, ushort option, const void[] data)
{
    buffer ~= option.asBytes;
    buffer ~= (cast(ushort)data.length).asBytes;
    buffer ~= cast(ubyte[])data;
    buffer.alignBlock();
}

void writeBlockLen(ref Array!ubyte buffer, size_t startOffset = 0)
{
    uint len = cast(uint)((buffer.length - startOffset) + 4);
    buffer ~= len.asBytes;
    buffer[][startOffset + 4 .. startOffset + 8] = len.asBytes; // TODO: what is wrong with array indexing?
    assert(buffer.length - startOffset == len);
}

void alignBlock(ref Array!ubyte buffer)
{
    buffer.resize(buffer.length.align_up!4);
}
