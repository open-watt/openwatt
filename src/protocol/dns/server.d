module protocol.dns.server;

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta.enuminfo;
import urt.mem.allocator;
import urt.socket;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.system;

import protocol.dns.message;
import protocol.http;
import protocol.http.message;
import protocol.http.server;
import protocol.http.tls;

import router.iface;
import router.stream.tcp;

version = DebugDNSMessageFlow;

nothrow @nogc:


enum IPAddr mDNSMulticastAddress = IPAddrLit!"224.0.0.251";
enum IPAddr LLMNRMulticastAddress = IPAddrLit!"224.0.0.252";
enum IPv6Addr mDNSv6MulticastAddress = IPv6AddrLit!"ff02::fb";
enum IPv6Addr LLMNRv6MulticastAddress = IPv6AddrLit!"ff02::1:3";

enum ushort DNSPort = 53;
enum ushort DoTPort = 853;
enum ushort mDNSPort = 5353;
enum ushort LLMNRPort = 5355;
enum ushort NBNSPort = 137;

enum NSProtocol : ubyte
{
    dns,
    mdns,
    dot,
    doh,
    llmnr,
    nbns, // TODO: respond to old netbios requests?
    wins, //       ""
}

class DNSServer : BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("protocols", protocols)(),
                                         Property.create!("doh-server", doh_server)(),
                                         Property.create!("doh-uri", doh_uri)() ];
nothrow @nogc:

    alias TypeName = StringLit!"dns-server";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DNSServer, name.move, flags);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure
        => _interface;
    final const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_interface is value)
            return null;
        if (_interface)
            _interface.unsubscribe(&incoming_packet);

        _interface = value;
        _interface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ip4, ether_type_2: EtherType.ip6), null);

        restart();
        return null;
    }

    // should we return an array of strings instead of a comma-separated list?
    String protocols() const
    {
        MutableString!0 r;
        foreach (i; 0 .. NSProtocol.max + 1)
        {
            if (_protocols & (1 << i))
            {
                if (r.length)
                    r ~= ',';
                r ~= enum_key_by_decl_index!NSProtocol(i);
            }
        }
        // TODO: we should be able to promote MutableString to String!!
        return r[].makeString(defaultAllocator());
    }
    void protocols(String[] value)
    {
        // populate the bitfield
        foreach (ref v; value)
        {
            const NSProtocol* p = enum_from_key!NSProtocol(v[]);
            if (p)
                _protocols |= 1 << *p;
        }
    }

    inout(HTTPServer) doh_server() inout pure
        => _doh_server;
    const(char)[] doh_server(HTTPServer value)
    {
        if (!value)
            return "doh_server cannot be null";
        if (_doh_server is value)
            return null;

        doh_subscribe(_doh_server, value);
        _doh_server = value;

        return null;
    }

    const(char)[] doh_uri() const pure
        => _doh_uri[];
    const(char)[] doh_uri(const(char)[] value)
    {
        // TODO: property should just accept a String!
        _doh_uri = value.makeString(defaultAllocator);
        doh_subscribe(_doh_server, _doh_server);
        return null;
    }

    // API...

    override CompletionStatus startup()
    {
        static Socket create_listener(AddressFamily af, ushort port, IPAddr ipv4_group = IPAddr.any, IPv6Addr ipv6_group = IPv6Addr.any)
        {
            Socket socket;
            Result r = create_socket(af, SocketType.datagram, Protocol.udp, socket);
            if (!r)
                return Socket.invalid;

            r = socket.set_socket_option(SocketOption.non_blocking, true);
            if (r)
                socket.set_socket_option(SocketOption.reuse_address, true);
            if (r && ipv4_group != IPAddr.any)
            {
                r = socket.set_socket_option(SocketOption.multicast, MulticastGroup(ipv4_group, IPAddr.any));
                // TODO: not sure if this should be present or not...
//                if (r)
//                    r = socket.set_socket_option(SocketOption.multicast_loopback, false);
            }
            if (r)
                socket.bind(InetAddress(IPAddr.any, port));
            if (!r)
            {
                socket.close();
                return Socket.invalid;
            }
            return socket;
        }

        // DNS
        if (_protocols & (1 << NSProtocol.dns) && !((_active | _failed) & (1 << NSProtocol.dns)))
        {
            _udp4_socket = create_listener(AddressFamily.ipv4, DNSPort);
            _udp6_socket = create_listener(AddressFamily.ipv6, DNSPort);

            String new_name = get_module!TCPStreamModule.tcp_servers.generate_name(name).makeString(defaultAllocator());
            _tcp_server = get_module!TCPStreamModule.tcp_servers.create(new_name.move, ObjectFlags.dynamic, NamedArgument("port", DNSPort));
            _tcp_server.set_connection_callback(&new_client, null);

            if (_udp4_socket && _tcp_server) // we can tolerate no ipv6 listener (?)
                _active |= 1 << NSProtocol.dns;
            else
            {
                if (_udp4_socket)
                {
                    _udp4_socket.close();
                    _udp4_socket = null;
                }
                if (_udp6_socket)
                {
                    _udp6_socket.close();
                    _udp6_socket = null;
                }
                if (_tcp_server)
                    _tcp_server.destroy();

                _failed |= 1 << NSProtocol.dns;
            }
        }

        // mDNS
        if ((_protocols & (1 << NSProtocol.mdns)) && !((_active | _failed) & (1 << NSProtocol.mdns)))
        {
            _mdns4_socket = create_listener(AddressFamily.ipv4, mDNSPort, ipv4_group: mDNSMulticastAddress);
            _mdns6_socket = create_listener(AddressFamily.ipv6, mDNSPort, ipv6_group: mDNSv6MulticastAddress);

            if (_mdns4_socket) // we can tolerate no ipv6 listener (?)
            {
                // TODO: send initial mDNS probe...
                _mdns_probe_count = 1;

                _active |= 1 << NSProtocol.mdns;
            }
            else
            {
                if (_mdns4_socket)
                {
                    _mdns4_socket.close();
                    _mdns4_socket = null;
                }
                if (_mdns6_socket)
                {
                    _mdns6_socket.close();
                    _mdns6_socket = null;
                }
                _failed |= 1 << NSProtocol.dns;
            }
        }

        // DoT
        if (_protocols & (1 << NSProtocol.dot) && !((_active | _failed) & (1 << NSProtocol.dot)))
        {
            String new_name = get_module!HTTPModule.tls_servers.generate_name(name).makeString(defaultAllocator());
            _dot_server = get_module!HTTPModule.tls_servers.create(new_name.move, ObjectFlags.dynamic, NamedArgument("port", DoTPort));
            _dot_server.set_connection_callback(&new_client, null);
            if (_dot_server)
                _active |= 1 << NSProtocol.dot;
            else
                _failed |= 1 << NSProtocol.dot;
        }

        // DoH
        if (_protocols & (1 << NSProtocol.doh) && !((_active | _failed) & (1 << NSProtocol.doh)))
        {
            if (_doh_server)
            {
                _active |= 1 << NSProtocol.doh;
                doh_subscribe(null, _doh_server);
            }
            else
                _failed |= 1 << NSProtocol.doh;
        }

        // LLMNR
        if (_protocols & (1 << NSProtocol.llmnr) && !((_active | _failed) & (1 << NSProtocol.llmnr)))
        {
            _llmnr4_socket = create_listener(AddressFamily.ipv4, LLMNRPort, ipv4_group: LLMNRMulticastAddress);
            _llmnr6_socket = create_listener(AddressFamily.ipv6, LLMNRPort, ipv6_group: LLMNRv6MulticastAddress);

            if (_llmnr4_socket) // we can tolerate no ipv6 listener (?)
                _active |= 1 << NSProtocol.llmnr;
            else
            {
                if (_llmnr4_socket)
                {
                    _llmnr4_socket.close();
                    _llmnr4_socket = null;
                }
                if (_llmnr6_socket)
                {
                    _llmnr6_socket.close();
                    _llmnr6_socket = null;
                }
                _failed |= 1 << NSProtocol.llmnr;
            }
        }

        // NBNS / WINS
        ubyte nbns_or_wins = _protocols & nbns_and_wins;
        if (nbns_or_wins && ((_active | _failed) & nbns_or_wins) != nbns_or_wins)
        {
            _nbns_socket = create_listener(AddressFamily.ipv4, NBNSPort);
            if (_nbns_socket)
                _active |= nbns_or_wins;
            else
                _failed |= nbns_or_wins;
        }

        if (_failed == _protocols)
        {
            writeError("DNS server '", name, "' failed to start");
            return CompletionStatus.error;
        }
        return (_active | _failed) == _protocols ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_doh_server)
            doh_subscribe(_doh_server, null);

        if (_tcp_server)
        {
            _tcp_server.destroy();
            _tcp_server = null;
        }
        if (_dot_server)
        {
            _dot_server.destroy();
            _dot_server = null;
        }

        foreach (ref c; _clients)
            c.stream.destroy();
        _clients.clear();

        if (_udp4_socket)
        {
            _udp4_socket.close();
            _udp4_socket = null;
        }
        if (_udp6_socket)
        {
            _udp6_socket.close();
            _udp6_socket = null;
        }
        if (_mdns4_socket)
        {
            // TODO: send goodbye TTL 0

            _mdns4_socket.close();
            _mdns4_socket = null;
        }
        if (_mdns6_socket)
        {
            // TODO: send goodbye TTL 0

            _mdns6_socket.close();
            _mdns6_socket = null;
        }
        if (_llmnr4_socket)
        {
            _llmnr4_socket.close();
            _llmnr4_socket = null;
        }
        if (_llmnr6_socket)
        {
            _llmnr6_socket.close();
            _llmnr6_socket = null;
        }
        if (_nbns_socket)
        {
            // TODO: broadcast RELEASE message
            // TODO: if we recognise a WINS server; send unicast RELEASE (I'm sure we'll never support this!)

            _nbns_socket.close();
            _nbns_socket = null;
        }

        _active = 0;
        _failed = 0;

        return CompletionStatus.complete;
    }

    override void update()
    {
        // check and reattach HTTP server
        if (_doh_server.detached)
        {
            if (HTTPServer srv = get_module!HTTPModule.servers.get(_doh_server.name))
            {
                _doh_server = srv;
                doh_subscribe(null, _doh_server);
            }
        }

        MonoTime now = getTime();

        Result r;
        InetAddress sender;
        size_t bytes;
        ubyte[1500] buffer = void;

        // poll DNS
        if (_udp4_socket && _udp4_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.dns);
        if (_udp6_socket && _udp6_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.dns);

        // poll mDNS
        if (_mdns4_socket && _mdns4_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.mdns);
        if (_mdns6_socket && _mdns6_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.mdns);

        // update mDNS probes and claims
        // TODO: uncomment this when we have a record of our local IP addresses, so we have something to advertise!
/+
        if (ubyte(_mdns_probe_count) < 5 && now - _last_mdns_probe > (_mdns_probe_count < 4 ? 250.msecs : 1.seconds))
        {
            import manager.system : hostname;

            // TODO: for each ipv4/v6 on each subnet...

            DNSMessage probe;
            probe.id = 0;
            probe.flags = _mdns_probe_count < 3 ? 0 : (DNSFlags.QR | DNSFlags.AA);

            String local_name = tconcat(hostname[], ".local").makeString(defaultAllocator());
            String rev4_name = tconcat(v4_addr, ".in-addr.arpa").makeString(defaultAllocator());
            String rev6_name = tconcat(v6_addr, ".ip6.arpa").makeString(defaultAllocator());

            if (_mdns_probe_count < 3)
            {
                ref DNSQuestion name = probe.questions.pushBack();
                name.name = local_name;
                name.type = DNSType.ANY;
                name.class_ = DNSClass.IN;

                ref DNSQuestion rev4 = probe.questions.pushBack();
                rev4.name = rev4_name;
                rev4.type = DNSType.ANY;
                rev4.class_ = DNSClass.IN;

                ref DNSQuestion rev6 = probe.questions.pushBack();
                rev6.name = rev6_name;
                rev6.type = DNSType.ANY;
                rev6.class_ = DNSClass.IN;
            }

            ref DNSRecord r1 = probe.authorities.pushBack();
            r1.name = local_name;
            r1.type = DNSType.A;
            r1.class_ = DNSClass.IN;
            r1.flush_cache = true;
            r1.ttl = 120.seconds;
//            r1.data = IPAddr.any; // TODO: actual ip address...

            ref DNSRecord r2 = probe.authorities.pushBack();
            r2.name = local_name;
            r2.type = DNSType.AAAA;
            r2.class_ = DNSClass.IN;
            r2.flush_cache = true;
            r2.ttl = 120.seconds;
//            r2.data = IPv6Addr.any; // TODO: actual ipv6 address...

            ref DNSRecord r3 = probe.authorities.pushBack();
            r3.name = rev4_name;
            r3.type = DNSType.PTR;
            r3.class_ = DNSClass.IN;
            r3.flush_cache = true;
            r3.ttl = 120.seconds;
            r3.data.resize(local_name.length + 2); // reserve for name encoding
            assert(writeName(local_name[], r3.data[]), "Encoding error?");

            ref DNSRecord r4 = probe.authorities.pushBack();
            r4.name = rev6_name;
            r4.type = DNSType.PTR;
            r4.class_ = DNSClass.IN;
            r4.flush_cache = true;
            r4.ttl = 120.seconds;
            r4.data = r3.data;

            ubyte[512] msg;
            size_t len = formDNSMessage(probe, msg[], false);

            size_t sent;
            if (_mdns4_socket)
            {
                auto addr = InetAddress(mDNSMulticastAddress, mDNSPort);
                _mdns4_socket.sendto(msg[0 .. len], MsgFlags.none, &addr, &sent);
            }
            if (_mdns6_socket)
            {
                auto addr = InetAddress(mDNSv6MulticastAddress, mDNSPort);
                _mdns6_socket.sendto(msg[0 .. len], MsgFlags.none, &addr, &sent);
            }

            ++_mdns_probe_count;
        }
+/
        // poll LLMNR
        if (_llmnr4_socket && _llmnr4_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.llmnr);
        if (_llmnr6_socket && _llmnr6_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
            incoming_request(buffer[0 .. bytes], sender, NSProtocol.llmnr);

        // poll NBNS/WINS
        if (_nbns_socket)
        {
            InetAddress dst;
            if (_nbns_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes))
                incoming_request(buffer[0 .. bytes], sender, NSProtocol.nbns);
        }

        // read from the streams
        for (size_t i = 0; i < _clients.length; )
        {
            ref client = _clients[i];

            if (!client.stream.running || now - client.last_activity >= 30.seconds)
            {
                // if the stream was closed, or timeout, remove the client
                client.stream.destroy();
                _clients.remove(i);
                continue;
            }

            ptrdiff_t read = client.stream.read(buffer);
            if (read > 0)
            {
                client.buffer ~= buffer[0 .. read];
                client.last_activity = now;

                ptrdiff_t taken = incoming_request(client.buffer[], InetAddress(/+ TODO: PASS THROUGH! +/), NSProtocol.dns);
                if (taken < 0)
                    client.buffer.clear(); // malformed message; flush the buffer
                else if (taken > 0)
                    client.buffer.remove(0, taken);
            }
            ++i;
        }
    }


private:
    enum nbns_and_wins = (1 << NSProtocol.nbns) |  (1 << NSProtocol.wins);

    struct Client
    {
        Stream stream;
        Array!ubyte buffer;
        MonoTime last_activity;
    }

    BaseInterface _interface;
    ubyte _protocols;
    ubyte _active;
    ubyte _failed;

    byte _mdns_probe_count;
    MonoTime _last_mdns_probe;

    Socket _udp4_socket;
    Socket _udp6_socket;
    Socket _mdns4_socket;
    Socket _mdns6_socket;
    Socket _llmnr4_socket;
    Socket _llmnr6_socket;
    Socket _nbns_socket;

    TCPServer _tcp_server;
    TLSServer _dot_server;
    Array!Client _clients;

    ObjectRef!HTTPServer _doh_server;
    String _doh_uri;

    // TODO: host cache...

    ptrdiff_t incoming_request(const(void)[] msg, ref InetAddress sender, NSProtocol protocol)
    {
        DNSMessage message;
        ptrdiff_t r = msg.parse_dns_message(message);
        if (r <= 0)
            return r;

        if (protocol == NSProtocol.nbns)
        {
            foreach (ref q; message.questions)
                q.name = decode_nbns_name(q.name[], q.netbios_type);
            foreach (ref a; message.answers)
                a.name = decode_nbns_name(a.name[], a.netbios_type);
            foreach (ref a; message.authorities)
                a.name = decode_nbns_name(a.name[], a.netbios_type);
            foreach (ref a; message.additional)
                a.name = decode_nbns_name(a.name[], a.netbios_type);
            if (message.flags & 0x10)
                protocol = NSProtocol.wins;
        }

//        if (state == State.Negotiating && message.id == 0 && (message.flags & DNSFlags.QR))
//        {
//            foreach (a; message.answers)
//            {
//                const(char)[] host;
//                if (numericSuffix > 0)
//                    host = tconcat(hostname, '-', numericSuffix, ".local");
//                else
//                    host = tconcat(hostname, ".local");
//
//                if ((a.type == DNSType.A || a.type == DNSType.AAAA) && a.name[] == host[])
//                {
//                    writeInfo("mDNS: hostname '", host, "' already claimed...");
//                    ++numericSuffix;
//                    probeCount = 0;
//                    lastAction = now - 250.msecs;
//                    goto continue_negotiation;
//                }
//            }
//        }

        // TODO: we got a normal message
        // handle requests, collect responses...
        version (DebugDNSMessageFlow)
        {
            writeDebug(protocol, ": received message from ", sender, ": ID=", message.id);
            foreach (q; message.questions)
                writeDebugf("    question {0}, type={1,04x}, class={2,04x}", q.name, q.type, q.class_);
            foreach (a; message.answers)
                writeDebugf("    answer {0}, type={1,04x}, class={2,04x}, ttl={3} - {4}", a.name, a.type, a.class_, a.ttl, cast(void[])a.data[]);
        }

        return r;
    }

    void new_client(Stream client, void* user_data)
    {
        _clients ~= Client(client, last_activity: getTime());
    }

    void doh_subscribe(HTTPServer unsub, HTTPServer sub)
    {
        if (!(_active & (1 << NSProtocol.doh)))
            return;

        if (unsub)
        {
            // TODO: unsubscribe from `unsub`
        }
        if (sub)
        {
            sub.add_uri_handler(HTTPMethod.GET, _doh_uri[], &doh_request_handler);
            sub.add_uri_handler(HTTPMethod.POST, _doh_uri[], &doh_request_handler);
        }
    }

    int doh_request_handler(ref const HTTPMessage, ref Stream stream)
    {
        assert(false, "TODO: incoming DoH request...");
        // TODO: handle requests with `Content-Type: application/dns-message` as a DNS request...
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        if (!running)
            return;

        struct UDPHeader
        {
            ushort src_port;
            ushort dst_port;
            ushort length;
            ushort checksum;
        }

        if (p.eth.ether_type == EtherType.ip4)
        {
            struct IPv4Header
            {
                ubyte version_ihl;
                ubyte dscp_ecn;
                ushort total_length;
                ushort identification;
                ushort flags_fragment_offset;
                ubyte ttl;
                ubyte protocol;
                ushort header_checksum;
                IPAddr src_addr;
                IPAddr dst_addr;
            }

            ref IPv4Header ip4 = *cast(IPv4Header*)p.data.ptr;
            if (ip4.protocol != Protocol.udp)
                return;
            ref UDPHeader udp = *cast(UDPHeader*)(p.data.ptr + (ip4.version_ihl & 0x0F) * 4);

            if (ip4.dst_addr == mDNSMulticastAddress)
            {
                // incoming mDNS request...
            }
            else if (ip4.dst_addr != LLMNRMulticastAddress)
            {
                // incoming LLMNR request...
            }
        }
        else
        {
            struct IPv6Header
            {
                ubyte[4] version_tc_flowlabel;
                ushort payload_length;
                ubyte next_header;
                ubyte hop_limit;
                IPv6Addr src_addr;
                IPv6Addr dst_addr;
            }

            ref IPv6Header ip6 = *cast(IPv6Header*)p.data.ptr;
            if (ip6.next_header != Protocol.udp)
                return;
            ref UDPHeader udp = *cast(UDPHeader*)(p.data.ptr + IPv6Header.sizeof);

            if (ip6.dst_addr == mDNSv6MulticastAddress)
            {
            }
            else if (ip6.dst_addr != LLMNRv6MulticastAddress)
            {
            }
        }

        // check things...
        // if it unicast? multicast? maybe llnms? nbns?
    }
}


String decode_nbns_name(const(char)[] name, out NBNSType type)
{
    char[16] tmp;
    if (name.length != 32)
        return String();
    for (size_t i = 0; i < 16; ++i)
        tmp[i] = cast(char)((name[i*2] - 'A') << 4 | (name[i*2 + 1] - 'A'));
    type = cast(NBNSType)tmp[15];
    size_t len = 15;
    while (len > 0 && tmp[len - 1] == ' ')
        --len;
    return tmp[0 .. len].makeString(defaultAllocator());
}
