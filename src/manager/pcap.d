module manager.pcap;

import urt.array;
import urt.endian;
import urt.file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.socket : InetAddress, AddressFamily;
import urt.string;
import urt.system;
import urt.time;
import urt.util : align_up, swap;

import manager;
import manager.collection;
import manager.plugin;
import manager.console;

import router.iface;
import router.stream.tcp;

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

    bool open_file(const char[] filename, bool overwrite = false)
    {
        if (pcap_file.is_open)
            return false;

        // open file
        Result r = pcap_file.open(filename, overwrite ? FileOpenMode.WriteTruncate : FileOpenMode.WriteAppend, FileOpenFlags.Sequential);
        if (r != Result.success)
            return false;

        start_offset = pcap_file.get_pos();

        // write section header...
        auto buffer = Array!ubyte(Reserve, 256);

        SectionHeaderBlock shb;
        buffer ~= shb.as_bytes;

        SystemInfo sysInfo = get_sysinfo();
        buffer.write_option(2, sysInfo.processor); // shb_hardware
        buffer.write_option(3, sysInfo.os_name); // shb_os
        buffer.write_option(4, "OpenWatt"); // shb_userappl
        buffer.write_option(0, null);

        buffer.write_block_len();
        write(buffer[]);

        return true;
    }

    bool open_remote(const char[] remotehost)
    {
        return false;
    }

    void close()
    {
        // update section header length
        ulong endOffset = pcap_file.get_pos();
        pcap_file.set_pos(start_offset + SectionHeaderBlock.sectionLength.offsetof);
        size_t written;
        pcap_file.write((endOffset - start_offset).as_bytes, written);
        assert(written == 8);

        // close file
        pcap_file.close();
    }

    bool enable(bool enable)
        => enabled.swap(enable);

    void set_buffer_params(Duration max_time = 0.seconds, size_t max_bytes = 0)
    {
        max_buffer_time = max_time;
        max_buffer_bytes = max_bytes;
    }

    void subscribe_interface(BaseInterface iface)
    {
        auto filter = PacketFilter(type: PacketType.unknown, direction: cast(PacketDirection)(PacketDirection.incoming | PacketDirection.outgoing));

        iface.subscribe(&packet_handler, filter);
    }

    void flush()
    {
        last_update = getTime();

        foreach (ref InterfacePacketBuffer ib; packet_buffers.values)
        {
            if (ib.packet_buffer.empty)
                continue;

            write(ib.packet_buffer[]);
            ib.packet_buffer.clear();
        }
    }

    void write(const void[] data)
    {
        // TODO: should we actually just bail? maybe something more particular?
        if (!pcap_file.is_open)
            return;

        size_t written;
        pcap_file.write(data, written);
        assert(written == data.length, "Write length wrong! ... what to do?");
        // TODO: what to do? try again?
    }

    void update()
    {
        if (getTime() - last_update < max_buffer_time)
            return;
        flush();
    }

private:

    String name;
    Map!(BaseInterface, InterfacePacketBuffer) packet_buffers;

    ulong start_offset;
    MonoTime last_update;

    File pcap_file;

    uint next_interface_index = 0;
    bool enabled = true;

    Duration max_buffer_time;
    size_t max_buffer_bytes;

    struct InterfacePacketBuffer
    {
        BaseInterface iface;
        int index = -1;
        ushort linkType;

        Array!ubyte packet_buffer;
    }

    void packet_handler(ref const Packet p, BaseInterface i, PacketDirection dir, void*)
    {
        write_packet(p, i, dir);
    }

    void write_packet(ref const Packet p, BaseInterface i, PacketDirection dir)
    {
        import router.iface.zigbee;

        if (!enabled)
            return;

        InterfacePacketBuffer* ib = packet_buffers.get(i);
        if (!ib)
        {
            ib = packet_buffers.insert(i, InterfacePacketBuffer(i, next_interface_index++, i.pcap_type()));

            // write IDB header...
            auto buffer = Array!ubyte(Reserve, 256);

            InterfaceDescriptionBlock idb;
            idb.linkType = ib.linkType;
            buffer ~= idb.as_bytes;
            buffer.write_option(2, i.name[]); // if_name
            if (cast(ZigbeeInterface)i is null)
                buffer.write_option(6, i.mac.b[]); // if_MACaddr
            ubyte ts = 9; // 6 = microseconds, 9 = nanoseconds
            buffer.write_option(9, (&ts)[0..1]); // if_tsresol
            buffer.write_option(0, null);
            buffer.write_block_len();

            write(buffer[]);
            buffer.clear();
        }

        size_t packetOffset = ib.packet_buffer.length;
        ulong timestamp = unixTimeNs(p.creation_time);

        // write packet block...
        EnhancedPacketBlock epb;
        epb.interfaceID = ib.index;
        epb.timestampHigh = timestamp >> 32;
        epb.timestampLow = cast(uint)timestamp;
//        epb.capturedLength = cast(uint)p.data.length; // write it later
//        epb.originalLength = cast(uint)p.data.length;
        ib.packet_buffer ~= epb.as_bytes;
        size_t capturedLengthOffset = ib.packet_buffer.length - 8;

        uint packetLen;
        i.pcap_write(p, dir, (const void[] packetData) {
            packetLen += cast(uint)packetData.length;
            ib.packet_buffer ~= cast(const ubyte[])packetData;
        });
        ib.packet_buffer.align_block();

        // write capture length...
        ib.packet_buffer[][capturedLengthOffset .. capturedLengthOffset + 4] = packetLen.as_bytes;
        ib.packet_buffer[][capturedLengthOffset + 4 .. capturedLengthOffset + 8] = packetLen.as_bytes;

        // write packet flags:
        uint flags = (dir == PacketDirection.incoming) ? 1 : 2; // 01 = inbound, 10 = outbound

        // 2-4 Reception type (000 = not specified, 001 = unicast, 010 = multicast, 011 = broadcast, 100 = promiscuous)
        if (p.eth.dst.isBroadcast)
            flags |= 3 << 2;
        else if (p.eth.dst.is_multicast)
            flags |= 2 << 2;
        else
            flags |= 1 << 2;
        ib.packet_buffer.write_option(2, flags.as_bytes); // epb_flags

        // epb_dropcount
        // epb_packetid

        ib.packet_buffer.write_option(0, null);
        ib.packet_buffer.write_block_len(packetOffset);

        if (ib.packet_buffer.length > max_buffer_bytes)
            flush();
    }
}

class PCAPServer : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("port", port)(),
                                         Property.create!("allow-anonymous", allow_anonymous)() ];
nothrow @nogc:

    alias TypeName = StringLit!"pcap-server";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PCAPServer, name.move, flags);
    }

    // Properties...

    ushort port() const pure
        => _port;
    const(char)[] port(ushort value)
    {
        if (_port == value)
            return null;
        if (value == 0)
            return "port must be non-zero";
        _port = value;

        if (_server)
            _server.port = _port;
        return null;
    }

    bool allow_anonymous() const pure
        => _allow_anonymous;
    void allow_anonymous(bool value)
    {
        _allow_anonymous = value;
    }

    // API...

protected:

    override CompletionStatus startup()
    {
        const(char)[] server_name = get_module!TCPStreamModule.tcp_servers.generate_name(name);
        _server = get_module!TCPStreamModule.tcp_servers.create(server_name.makeString(defaultAllocator), ObjectFlags.dynamic, NamedArgument("port", _port));
        if (!_server)
            return CompletionStatus.error;

        _server.set_connection_callback(&accept_connection, null);
        writeInfo(type, ": '", name, "' listening on port ", _port, "...");

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        while (!_sessions.empty)
        {
            Session* s = _sessions.popBack();
            s.close();
            defaultAllocator().freeT(s);
        }

        if (_server)
        {
            _server.destroy();
            _server = null;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        for (size_t i = 0; i < _sessions.length; )
        {
            int result = _sessions[i].update();
            if (result < 0)
            {
                defaultAllocator().freeT(_sessions[i]);
                _sessions.remove(i);
            }
            else
                ++i;
        }
    }

private:

    ushort _port = 2002;
    bool _allow_anonymous;
    TCPServer _server;
    Array!(Session*) _sessions;

    void accept_connection(Stream stream, void*)
    {
        writeInfo("RPCAP: new connection from ", stream.remote_name);
        _sessions.pushBack(defaultAllocator().allocT!Session(this, stream));
    }

    struct Session
    {
    nothrow @nogc:
        PCAPServer server;
        TCPServer data_server;
        Stream stream;
        Stream data_stream;

        BaseInterface opened_iface;
        uint packet_ordinal;
        bool authenticated;
        bool capturing;

        Array!ubyte tail;

        this(PCAPServer server, Stream stream)
        {
            this.server = server;
            this.stream = stream;
            stream.subscribe(&stream_destroyed);
        }

        void close()
        {
            writeInfo("RPCAP: session closed");

            if (capturing && opened_iface)
            {
                opened_iface.unsubscribe(&packet_handler);
                capturing = false;
            }
            opened_iface = null;

            if (data_stream)
            {
                data_stream.unsubscribe(&stream_destroyed);
                data_stream.destroy();
                data_stream = null;
            }
            else if (data_server)
            {
                data_server.destroy();
                data_server = null;
            }

            if (stream)
            {
                stream.unsubscribe(&stream_destroyed);
                stream.destroy();
                stream = null;
            }
        }

        int update()
        {
            if (!stream)
                return -1;

            ubyte[1024] buffer = void;
            size_t buf_len = 0;

            if (!tail.empty)
            {
                buf_len = tail.length;
                buffer[0 .. buf_len] = tail[];
                tail.clear();
            }

            while (buf_len < buffer.length)
            {
                ptrdiff_t n = stream.read(buffer[buf_len .. $]);
                if (n <= 0)
                    break;
                buf_len += n;
            }

            ubyte[] buf = buffer[0 .. buf_len];
            while (buf.length >= RpcapHeader.sizeof)
            {
                auto hdr = buf.takeFront!(RpcapHeader.sizeof).bigEndianToNative!RpcapHeader;

                if (buf.length < hdr.plen)
                    break;
                ubyte[] payload = buf.takeFront(hdr.plen);

                switch (hdr.type)
                {
                    case RPCAP_MSG_AUTH_REQ:
                        handle_auth(payload);
                        break;
                    case RPCAP_MSG_FINDALLIF_REQ:
                        handle_findallif();
                        break;
                    case RPCAP_MSG_OPEN_REQ:
                        handle_open(payload);
                        break;
                    case RPCAP_MSG_STARTCAP_REQ:
                        handle_startcap(payload);
                        break;
                    case RPCAP_MSG_UPDATEFILTER_REQ:
                        // Accept any filter (we don't do server-side filtering)
                        send_reply(RPCAP_MSG_UPDATEFILTER_REQ, null);
                        break;
                    case RPCAP_MSG_ENDCAP_REQ:
                        handle_endcap();
                        break;
                    case RPCAP_MSG_CLOSE:
                        handle_close();
                        break;
                    case RPCAP_MSG_STATS_REQ:
                        handle_stats();
                        break;
                    default:
                        send_error("Unknown message type");
                }
            }

            if (!buf.empty)
                tail = buf[];

            return 0;
        }

        void handle_auth(ubyte[] payload)
        {
            if (payload.length >= RpcapAuth.sizeof)
            {
                auto auth = payload.takeFront!(RpcapAuth.sizeof).bigEndianToNative!RpcapAuth;

                if (auth.type == RPCAP_RMTAUTH_NULL)
                {
                    if (!server.allow_anonymous)
                    {
                        send_error("Anonymous authentication not allowed");
                        return;
                    }
                    authenticated = true;
                    send_reply(RPCAP_MSG_AUTH_REQ, null);
                    writeInfo("RPCAP: client authenticated (anonymous)");
                    return;
                }
                else if (auth.type == RPCAP_RMTAUTH_PWD)
                {
                    size_t offset = RpcapAuth.sizeof;
                    if (payload.length < auth.user_len + auth.pass_len)
                    {
                        send_error("Invalid auth payload");
                        return;
                    }

                    const(char)[] username = cast(char[])payload.takeFront(auth.user_len);
                    const(char)[] password = cast(char[])payload.takeFront(auth.pass_len);

                    AuthResult auth_result;
                    bool completed = g_app.validate_login(username, password, "rpcap", (AuthResult result, const(char)[] profile) {
                        auth_result = result;
                    });
                    if (completed)
                    {
                        if (auth_result == AuthResult.accepted)
                        {
                            authenticated = true;
                            send_reply(RPCAP_MSG_AUTH_REQ, null);
                            writeInfo("RPCAP: client '", username, "' authenticated");
                        }
                        else
                        {
                            goto fail;

                            // TODO: should we terminate the session on an auth fail?
                        }
                    }
                    else
                    {
                        // TODO: deferred authentication...
                        assert(false, "TODO");
                    }
                    return;
                }
            }

        fail:
            send_error("Authentication failed");
        }

        void handle_findallif()
        {
            if (!authenticated)
            {
                send_error("Not authenticated");
                return;
            }

            ref ifaces = get_module!InterfaceModule.interfaces;
            uint iface_count = ifaces.item_count;

            ubyte[2048] buffer = void;
            size_t len = 0;

            foreach (iface; ifaces.values)
            {
                if (len + RpcapFindAllIfReply.sizeof + iface.name.length > buffer.length)
                    break;

                RpcapFindAllIfReply if_reply = {
                    namelen: cast(ushort)iface.name.length,
                    desclen: 0,
                    flags: iface.running ? PCAP_IF_UP : 0,
                    naddr: 0,
                    dummy: 0,
                };
                buffer[len .. len + RpcapFindAllIfReply.sizeof] = if_reply.nativeToBigEndian;
                len += RpcapFindAllIfReply.sizeof;

                buffer[len .. len + iface.name.length] = cast(ubyte[])iface.name[];
                len += iface.name.length;
            }

            send_reply_with_value(RPCAP_MSG_FINDALLIF_REQ, cast(ushort)iface_count, buffer[0 .. len]);
        }

        void handle_open(ubyte[] payload)
        {
            if (!authenticated)
            {
                send_error("Not authenticated");
                return;
            }

            if (capturing && opened_iface)
            {
                opened_iface.unsubscribe(&packet_handler);
                capturing = false;
            }

            const(char)[] iface_name = cast(const(char)[])payload;
            opened_iface = get_module!InterfaceModule.interfaces.get(iface_name);
            if (!opened_iface)
            {
                send_error("Interface not found");
                return;
            }

            RpcapOpenReply reply = {
                linktype: cast(uint)opened_iface.pcap_type,
                tzoff: 0,
            };
            send_reply(RPCAP_MSG_OPEN_REQ, reply.nativeToBigEndian);

            writeInfo("RPCAP: opened interface '", iface_name, "'");
        }

        void handle_startcap(ubyte[] payload)
        {
            if (!authenticated)
            {
                send_error("Not authenticated");
                return;
            }

            if (!opened_iface)
            {
                send_error("No interface opened");
                return;
            }

            if (payload.length < RpcapStartCapReq.sizeof)
            {
                send_error("Invalid startcap request");
                return;
            }

            auto req = payload[0 .. RpcapStartCapReq.sizeof].bigEndianToNative!RpcapStartCapReq;

            writeInfo("RPCAP: startcap flags=", req.flags, " portdata=", req.portdata, " snaplen=", req.snaplen);

            ushort reply_portdata = 0;

            // RPCAP_STARTCAPREQ_FLAG_SERVEROPEN = 0x01 means use separate data connection
            // (client connects to server on a new port for data)
            bool separate_data_conn = (req.flags & 1) != 0;
            ushort data_port = 0;

            if (separate_data_conn)
            {
                // create a TCP server for the data connection
                // use portdata from request if specified, otherwise pick an ephemeral port
                data_port = req.portdata;
                if (data_port == 0)
                    data_port = cast(ushort)(server._port + 1);  // HACK: we should use a proper ephemeral port allocator here!

                const(char)[] server_name = get_module!TCPStreamModule.tcp_servers.generate_name("rpcap-data");
                data_server = get_module!TCPStreamModule.tcp_servers.alloc(server_name.makeString(defaultAllocator), cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
                if (!data_server)
                {
                    send_error("Failed to create data server");
                    return;
                }

                data_server.port = data_port;
                data_server.set_connection_callback(&data_connection_callback, null);
                get_module!TCPStreamModule.tcp_servers.add(data_server);

                writeInfo("RPCAP: listening for data connection on port ", data_port);
            }

            opened_iface.subscribe(&packet_handler, PacketFilter(type: PacketType.unknown, direction: cast(PacketDirection)(PacketDirection.incoming | PacketDirection.outgoing)), &this);
            capturing = true;
            packet_ordinal = 1;

            // portdata in reply: 0 = use same connection, non-zero = port client should connect to
            RpcapStartCapReply reply = {
                bufsize: 64 * 1024,  // 64KB buffer
                portdata: data_port,
                dummy: 0,
            };
            send_reply(RPCAP_MSG_STARTCAP_REQ, reply.nativeToBigEndian);

            writeInfo("RPCAP: started capture on '", opened_iface.name, "'");
        }

        void handle_endcap()
        {
            if (capturing && opened_iface)
            {
                opened_iface.unsubscribe(&packet_handler);
                capturing = false;
                writeInfo("RPCAP: stopped capture");
            }

            if (data_stream)
            {
                data_stream.unsubscribe(&stream_destroyed);
                data_stream.destroy();
                data_stream = null;
            }
            else if (data_server)
            {
                data_server.destroy();
                data_server = null;
            }

            send_reply(RPCAP_MSG_ENDCAP_REQ, null);
        }

        void handle_close()
        {
            send_reply(RPCAP_MSG_CLOSE, null);
            writeInfo("RPCAP: closed interface");

            close();
        }

        void handle_stats()
        {
            RpcapStats stats = {
                ifrecv: opened_iface ? cast(uint)opened_iface.status.recv_packets : 0,
                ifdrop: opened_iface ? cast(uint)opened_iface.status.recv_dropped : 0,
                krnldrop: 0,
                svrcapt: packet_ordinal,
            };
            send_reply(RPCAP_MSG_STATS_REQ, stats.nativeToBigEndian);
        }

        void data_connection_callback(Stream new_stream, void*)
        {
            data_stream = new_stream;
            data_stream.subscribe(&stream_destroyed);

            data_server.destroy();
            data_server = null;

            writeInfo("RPCAP: data connection established");
        }

        void packet_handler(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data)
        {
            if (!capturing)
                return;
            if (data_server && !data_stream)
                return; // client hasn't connected yet

            Stream out_stream = data_stream ? data_stream : stream;
            if (!out_stream || !out_stream.running)
                return;

            ubyte[2048] buffer = void;
            uint len = RpcapPktHdr.sizeof;

            iface.pcap_write(p, dir, (const void[] data) {
                size_t n = data.length;
                if (len + n > buffer.length)
                    n = buffer.length - len;  // truncate if too large
                if (n > 0)
                {
                    buffer[len .. len + n] = cast(ubyte[])data[0 .. n];
                    len += n;
                }
            });

            uint pkt_len = cast(uint)(len - RpcapPktHdr.sizeof);

            ulong timestamp = unixTimeNs(p.creation_time);
            RpcapPktHdr pkt_hdr = {
                timestamp_sec: cast(uint)(timestamp / 1_000_000_000),
                timestamp_usec: cast(uint)((timestamp % 1_000_000_000) / 1000),
                caplen: pkt_len,
                len: pkt_len,
                npkt: packet_ordinal++,
            };
            buffer[0 .. RpcapPktHdr.sizeof] = pkt_hdr.nativeToBigEndian;

            RpcapHeader hdr = {
                ver: RPCAP_VERSION,
                type: RPCAP_MSG_PACKET,
                value: 0,
                plen: len,
            };
            out_stream.write(hdr.nativeToBigEndian);
            out_stream.write(buffer[0 .. len]);
        }

        void send_reply(ubyte msg_type, const void[] payload)
        {
            send_reply_with_value(msg_type, 0, payload);
        }

        void send_reply_with_value(ubyte msg_type, ushort value, const void[] payload)
        {
            write_header(RPCAP_VERSION, msg_type | RPCAP_MSG_IS_REPLY, value, payload.length);
            if (payload.length > 0)
                stream.write(payload);
        }

        void send_error(const(char)[] message)
        {
            write_header(RPCAP_VERSION, RPCAP_MSG_ERROR, 0, message.length);
            stream.write(cast(const void[])message);

            writeWarning("RPCAP error: ", message);
        }

        void write_header(ubyte ver, ubyte type, ushort value, size_t plen)
        {
            stream.write(RpcapHeader(ver: ver, type: type, value: value, plen: cast(uint)plen).nativeToBigEndian);
        }

        void stream_destroyed(BaseObject object, StateSignal signal)
        {
            if (signal == StateSignal.destroyed)
            {
                if (object is stream)
                {
                    writeInfo("RPCAP: control connection closed");

                    // terminate the session
                    close();
                }
                else if (object is data_stream)
                {
                    writeInfo("RPCAP: data connection closed");

                    data_stream = null;

                    // if we lose the data stream, we should stop capturing
                    if (capturing && opened_iface)
                    {
                        opened_iface.unsubscribe(&packet_handler);
                        capturing = false;
                    }
                }
            }
        }
    }
}


class PcapModule : Module
{
    mixin DeclareModule!"manager.pcap";
nothrow @nogc:

    Collection!PCAPServer servers;
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
        g_app.console.register_command!add("/tools/pcap", this);
        g_app.console.register_collection("/tools/pcap/server", servers);
    }

    override void update()
    {
        servers.update_all();
    }

    override void post_update()
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
            session.write_line("PCAP interface must have a name");
            return;
        }
        foreach (PcapInterface* pcap; interfaces)
        {
            if (pcap.name == name)
            {
                session.write_line("PCAP interface '", name, "' already exists");
                return;
            }
        }
        String n = name.makeString(g_app.allocator);

        PcapInterface* pcap = g_app.allocator.allocT!PcapInterface();
        pcap.name = n.move;

        if (!pcap.open_file(file))
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

ubyte[T.sizeof] as_bytes(T)(auto ref const T data)
    => *cast(ubyte[T.sizeof]*)&data;

void write_option(ref Array!ubyte buffer, ushort option, const void[] data)
{
    buffer ~= option.as_bytes;
    buffer ~= (cast(ushort)data.length).as_bytes;
    buffer ~= cast(ubyte[])data;
    buffer.align_block();
}

void write_block_len(ref Array!ubyte buffer, size_t start_offset = 0)
{
    uint len = cast(uint)((buffer.length - start_offset) + 4);
    buffer ~= len.as_bytes;
    buffer[][start_offset + 4 .. start_offset + 8] = len.as_bytes; // TODO: what is wrong with array indexing?
    assert(buffer.length - start_offset == len);
}

void align_block(ref Array!ubyte buffer)
{
    buffer.resize(buffer.length.align_up!4);
}


// from RPCAP headers...

enum RPCAP_VERSION = 0;

enum : ubyte
{
    RPCAP_MSG_ERROR             = 0x01,
    RPCAP_MSG_FINDALLIF_REQ     = 0x02,
    RPCAP_MSG_OPEN_REQ          = 0x03,
    RPCAP_MSG_STARTCAP_REQ      = 0x04,
    RPCAP_MSG_UPDATEFILTER_REQ  = 0x05,
    RPCAP_MSG_CLOSE             = 0x06,
    RPCAP_MSG_PACKET            = 0x07,
    RPCAP_MSG_AUTH_REQ          = 0x08,
    RPCAP_MSG_STATS_REQ         = 0x09,
    RPCAP_MSG_ENDCAP_REQ        = 0x0A,
    RPCAP_MSG_SETSAMPLING_REQ   = 0x0B,

    RPCAP_MSG_IS_REPLY          = 0x80,
}

enum : ushort
{
    RPCAP_RMTAUTH_NULL = 0,
    RPCAP_RMTAUTH_PWD  = 1,
}

enum : uint
{
    PCAP_IF_LOOPBACK = 0x01,
    PCAP_IF_UP       = 0x02,
    PCAP_IF_RUNNING  = 0x04,
}

struct RpcapHeader
{
    ubyte ver;
    ubyte type;
    ushort value;
    uint plen;
}
static assert(RpcapHeader.sizeof == 8);

struct RpcapAuth
{
    ushort type;
    ushort dummy;
    ushort user_len;
    ushort pass_len;
    // followed by username and password strings
}
static assert(RpcapAuth.sizeof == 8);

struct RpcapFindAllIfReply
{
    ushort namelen;
    ushort desclen;
    uint flags;
    ushort naddr;
    ushort dummy;
    // followed by: name, description, then naddr address structures
}
static assert(RpcapFindAllIfReply.sizeof == 12);

struct RpcapOpenReply
{
    uint linktype;
    uint tzoff;
}
static assert(RpcapOpenReply.sizeof == 8);

struct RpcapStartCapReq
{
    uint snaplen;
    uint read_timeout;  // ms
    ushort flags;
    ushort portdata;    // port for data connection, 0 = same connection
    ushort filterlen;   // BPF filter length
    ushort dummy;
    // followed by BPF filter if filterlen > 0
}
static assert(RpcapStartCapReq.sizeof == 16);

// Start capture reply
struct RpcapStartCapReply
{
    uint bufsize;
    ushort portdata;  // data port, 0 = same connection
    ushort dummy;
}
static assert(RpcapStartCapReply.sizeof == 8);

struct RpcapPktHdr
{
    uint timestamp_sec;
    uint timestamp_usec;
    uint caplen;
    uint len;
    uint npkt;
}
static assert(RpcapPktHdr.sizeof == 20);

struct RpcapStats
{
    uint ifrecv;
    uint ifdrop;
    uint krnldrop;
    uint svrcapt;
}
static assert(RpcapStats.sizeof == 16);
