module protocol.dns.mdns;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.socket;
import urt.string;
import urt.string.format;
import urt.time;

static import manager.system;

import protocol.dns.message;

nothrow @nogc:


enum IPAddr mDNSMulticastAddress = IPAddrLit!"224.0.0.251";
enum ushort mDNSPort = 5353;


class mDNSServer
{
nothrow @nogc:

    String name;
    String hostname;
//    Array!BaseInterface interfaces;

    // TODO: host cache...

    this(String name)//, Array!BaseInterface interfaces)
    {
        this.name = name.move;
//        this.interfaces = interfaces.move;

//        hostname = manager.system.hostname.makeString(defaultAllocator());
        // TODO: gotta get the hostname from the OS...
        hostname = StringLit!"Manu-Win10";
    }

    ~this()
    {
        reset();
    }

    void reset()
    {
        if (state == State.Running)
        {
            writeInfo("mDNS: stopping server '", name, "'...");

            // send goodbye messages
            //...
            // send TTL 0 for all services...
        }
        if (state != State.Disable)
            state = State.Idle;

        socket.close();
        socket = null;
        alreadyComplained = false;
        probeCount = 0;
        numericSuffix = 0;
    }

    void enable(bool enable)
    {
        if (!enable && state != state.Disable)
        {
            reset();
            state = state.Disable;
        }
        else if (enable && state == state.Disable)
            state = State.Idle;
    }

    void update()
    {
        MonoTime now = getTime();

        if (state == State.Idle && now - lastAction >= 10.seconds)
        {
            lastAction = now;

            if (!socket && !create_socket(AddressFamily.IPv4, SocketType.datagram, Protocol.udp, socket))
            {
                if (!alreadyComplained)
                {
                    alreadyComplained = true;
                    writeError("Failed to create socket");
                }
                return;
            }
            if (!socket)
                return;

            Result r = socket.set_socket_option(SocketOption.non_blocking, true);
            if (r)
                socket.set_socket_option(SocketOption.reuse_address, true);
            if (r)
                r = socket.set_socket_option(SocketOption.multicast, MulticastGroup(mDNSMulticastAddress, IPAddr.any));
            // TODO: not sure if this should be present or not...
//            if (r)
//                r = socket.set_socket_option(SocketOption.multicast_loopback, false);
            if (r)
                socket.bind(InetAddress(IPAddr.any, mDNSPort));
            if (!r)
            {
                socket.close();
                socket = null;

                if (!alreadyComplained)
                {
                    alreadyComplained = true;
                    writeError("Failed to bind socket for mDNS multicast: ", r.socket_result());
                }
                return;
            }

            writeInfo("mDNS: starting server '", name, "'...");

            state = state.Negotiating;
            probeCount = 0;
            alreadyComplained = false;
            lastAction = now - 250.msecs;
        }
        if (state <= State.Idle)
            return;

        // monitor for incoming data
        ubyte[1500] buffer = void;
        InetAddress sender;
        size_t recv;
        Result r = socket.recvfrom(buffer, MsgFlags.none, &sender, &recv);
        if (!r && r.socket_result != SocketResult.would_block)
        {
            // TODO: what is this case? should we reset the connection?
            writeError("mDNS: recvfrom failed: ", r.socket_result());
            return;
        }

        DNSMessage message;
        if (buffer[0 .. recv].parseDNSMessage(message))
        {
            if (state == State.Negotiating && message.id == 0 && (message.flags & DNSFlags.QR))
            {
                foreach (a; message.answers)
                {
                    const(char)[] host;
                    if (numericSuffix > 0)
                        host = tconcat(hostname, '-', numericSuffix, ".local");
                    else
                        host = tconcat(hostname, ".local");

                    if ((a.type == DNSType.A || a.type == DNSType.AAAA) && a.name[] == host[])
                    {
                        writeInfo("mDNS: hostname '", host, "' already claimed...");
                        ++numericSuffix;
                        probeCount = 0;
                        lastAction = now - 250.msecs;
                        goto continue_negotiation;
                    }
                }
            }

            // TODO: we got a normal message
            // handle requests, collect responses...
            writeDebug("mDNS: received message from ", sender, ": ID=", message.id);

            foreach (q; message.questions)
                writeDebugf("mDNS:   question {0}, type={1,04x}, class={2,04x}", q.name, q.type, q.class_);

            foreach (a; message.answers)
                writeDebugf("mDNS:   answer {0}, type={1,04x}, class={2,04x}, ttl={3} - {4}", a.name, a.type, a.class_, a.ttl, cast(void[])a.data[]);
        }

        // perform name negotiation
        if (state == State.Negotiating && now - lastAction >= 250.msecs)
        {
            if (probeCount >= 3)
            {
                if (numericSuffix > 0)
                    hostname = tconcat(hostname, '-', numericSuffix).makeString(defaultAllocator());

                DNSMessage goodmorning;
                MutableString!0 host = hostname;
                host ~= ".local";
                // TODO: send the appropriate IP address in goodmorning message!
//                goodmorning.answers ~= DNSAnswer(host, DNSType.A, DNSClass.IN, true, 120, );
//                goodmorning.answers ~= DNSAnswer(host, DNSType.AAAA, DNSClass.IN, true, 120, );

                state = State.Running;
                writeInfo("mDNS: server '", name, "' running. name: '", hostname, ".local'");
            }
            else
            {
            continue_negotiation:
                DNSMessage probe;
                MutableString!0 name = hostname;
                if (numericSuffix > 0)
                    name.append('-', numericSuffix, ".local");
                else
                    name ~= ".local";
                probe.questions ~= DNSQuestion(name.move, DNSType.ANY, DNSClass.IN, true);

                ubyte[] msg = buffer[0 .. probe.formDNSMessage(buffer, false)];

                InetAddress addr = InetAddress(mDNSMulticastAddress, mDNSPort);
                size_t bytes;

                r = socket.sendto(msg, MsgFlags.none, &addr, &bytes);
                if (!r)
                {
                    // TODO: what is this case? should we reset the connection?
                    writeError("mDNS: sendto failed: ", r.socket_result());
                    return;
                }

                writeDebug("mDNS: sent name probe...");

                lastAction = now;
                ++probeCount;
            }
        }
    }

private:
    enum State : byte
    {
        Idle,
        Negotiating,
        Running,

        Disable = -1,
    }
    Socket socket;
    State state;
    ubyte probeCount;
    ubyte numericSuffix;
    bool alreadyComplained;
    MonoTime lastAction;
}
