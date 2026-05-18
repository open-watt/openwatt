module router.pcap_server;

import manager.features;
static if (has_ip):

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.expression : NamedArgument;

import router.iface;
import router.stream;

import protocol.ip.tcp_stream : TCPServer;

nothrow @nogc:


class PCAPServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port),
                                 Prop!("allow-anonymous", allow_anonymous));
nothrow @nogc:

    enum type_name = "pcap-server";
    enum path = "/tools/pcap/server";
    enum collection_id = CollectionType.pcap_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PCAPServer, id, flags);
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
        const(char)[] server_name = Collection!TCPServer().generate_name(name[]);
        _server = Collection!TCPServer().create(server_name, ObjectFlags.dynamic, NamedArgument("port", _port));
        if (!_server)
            return CompletionStatus.error;

        _server.set_connection_callback(&accept_connection, null);
        log.info("listening on port ", _port, "...");

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
        log.info("new connection from ", stream.remote_name);
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
            server.log.info("session closed");

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
                    server.log.info("client authenticated (anonymous)");
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
                            server.log.info("client '", username, "' authenticated");
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

            auto ifaces = Collection!BaseInterface();
            uint iface_count = 0;

            ubyte[2048] buffer = void;
            size_t len = 0;

            foreach (iface; ifaces.values)
            {
                if (iface.pcap_type() == 0)
                    continue;
                if (len + RpcapFindAllIfReply.sizeof + iface.name.length > buffer.length)
                    break;

                ++iface_count;

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
            opened_iface = Collection!BaseInterface().get(iface_name);
            if (!opened_iface)
            {
                send_error("Interface not found");
                return;
            }
            if (opened_iface.pcap_type() == 0)
            {
                opened_iface = null;
                send_error("Interface does not support packet capture");
                return;
            }

            RpcapOpenReply reply = {
                linktype: cast(uint)opened_iface.pcap_type,
                tzoff: 0,
            };
            send_reply(RPCAP_MSG_OPEN_REQ, reply.nativeToBigEndian);

            server.log.info("opened interface '", iface_name, "'");
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

            server.log.info("startcap flags=", req.flags, " portdata=", req.portdata, " snaplen=", req.snaplen);

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

                const(char)[] server_name = Collection!TCPServer().generate_name("rpcap-data");
                data_server = Collection!TCPServer().alloc(server_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
                if (!data_server)
                {
                    send_error("Failed to create data server");
                    return;
                }

                data_server.port = data_port;
                data_server.set_connection_callback(&data_connection_callback, null);
                Collection!TCPServer().add(data_server);

                server.log.info("listening for data connection on port ", data_port);
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

            server.log.info("started capture on '", opened_iface.name, "'");
        }

        void handle_endcap()
        {
            if (capturing && opened_iface)
            {
                opened_iface.unsubscribe(&packet_handler);
                capturing = false;
                server.log.info("stopped capture");
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
            server.log.info("closed interface");

            close();
        }

        void handle_stats()
        {
            RpcapStats stats = {
                ifrecv: opened_iface ? cast(uint)opened_iface.status.rx_packets : 0,
                ifdrop: opened_iface ? cast(uint)opened_iface.status.rx_dropped : 0,
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

            server.log.info("data connection established");
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

            server.log.warning("error: ", message);
        }

        void write_header(ubyte ver, ubyte type, ushort value, size_t plen)
        {
            stream.write(RpcapHeader(ver: ver, type: type, value: value, plen: cast(uint)plen).nativeToBigEndian);
        }

        void stream_destroyed(ActiveObject object, StateSignal signal)
        {
            if (signal == StateSignal.destroyed)
            {
                if (object is stream)
                {
                    server.log.info("control connection closed");

                    // terminate the session
                    close();
                }
                else if (object is data_stream)
                {
                    server.log.info("data connection closed");

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

private:

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
