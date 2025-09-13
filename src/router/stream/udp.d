module router.stream.udp;

import urt.io;
import urt.lifetime;
import urt.socket;
import urt.string;
import urt.string.format;

import manager.plugin;

public import router.stream;


class UDPStream : Stream
{
nothrow @nogc:

    alias TypeName = StringLit!"udp";

    this(String name, ushort remotePort, const char[] remoteHost = "255.255.255.255", ushort localPort = 0, const char[] localHost = "0.0.0.0", StreamOptions options = StreamOptions.None)
    {
        super(name.move, TypeName, options);

        // TODO: if remoteHost is a broadcast address and options doesn't have `AllowBroadcast`, make a warning...

        this.localHost = localHost.makeString(defaultAllocator());
        this.localPort = localPort;
        this.remoteHost = remoteHost.makeString(defaultAllocator());
        this.remotePort = remotePort;

        AddressInfoResolver resolve;
        Result r = localHost.get_address_info(tconcat(localPort), null, resolve);
        assert(r, "What do we even do about fails like this?");

        AddressInfo addr;
        while (resolve.next_address(addr))
        {
            local = addr.address;
            break; // TODO: what do we even do with multiple addresses?
        }

        r = remoteHost.get_address_info(tconcat(remotePort), null, resolve);
        assert(r, "What do we even do about fails like this?");

        while (resolve.next_address(addr))
        {
            remote = addr.address;
            break; // TODO: what do we even do with multiple addresses?
        }

        _status.linkStatus = Status.Link.Up;
    }

    override bool running() const pure
        => status.linkStatus == Status.Link.Up;

    override const(char)[] remoteName()
    {
        return remoteHost[];
    }

    override ptrdiff_t read(void[] buffer) nothrow @nogc
    {
        // TODO: if a packet doesn't fill buffer, we should loop...
        size_t bytes;
        Result r = socket.recvfrom(buffer, MsgFlags.none, null, &bytes);
        if (!r)
        {
            if (r.socket_result() == SocketResult.would_block)
                return 0;
            assert(0);
        }
        if (logging)
            writeToLog(true, buffer[0 .. bytes]);
        return bytes;
    }

    override ptrdiff_t write(const void[] data) nothrow @nogc
    {
        // TODO: fragment on MTU...?
        size_t bytes;
        Result r = socket.sendto(data, MsgFlags.none, &remote, &bytes);
        if (!r)
            assert(0);
        if (logging)
            writeToLog(true, data[0 .. bytes]);
        return bytes;
    }

    ptrdiff_t recvfrom(ubyte[] msgBuffer, out InetAddress srcAddr)
    {
        size_t bytes;
        Result r = socket.recvfrom(msgBuffer, MsgFlags.none, &srcAddr, &bytes);
        if (!r)
        {
            // TODO?
            assert(0);
        }
        return bytes;
    }

    ptrdiff_t sendto(const ubyte[] data, InetAddress destAddr)
    {
        size_t sent;
        Result r = socket.sendto(data, MsgFlags.none, &destAddr, &sent);
        if (!r)
        {
            // TODO?
            assert(0);
        }
        return sent;
    }

    override ptrdiff_t pending()
    {
//        if (!connected())
//        {
//            if (options & StreamOptions.KeepAlive)
//            {
//                connect();
//                return 0;
//            }
//            else
//                return -1;
//        }
//
//        long r = socket.receive(null, SocketFlags.PEEK);
//        if (r == 0 || r == Socket.ERROR)
//        {
//            socket.close();
//            socket = null;
//        }
//        return cast(size_t) r;
        return 0;
    }

    override ptrdiff_t flush()
    {
        // TODO: read until can't read no more?
        assert(0);
    }

private:
    Socket socket;
    String localHost;
    String remoteHost;
    ushort localPort;
    ushort remotePort;
    InetAddress local;
    InetAddress remote;
}


class UDPStreamModule : Module
{
    mixin DeclareModule!"stream.udp";

//    Collection!UDPStream udp_streams;
//
//    override void init()
//    {
//        g_app.console.registerCollection("/stream/udp-client", udp_streams);
//    }
//
//    override void pre_update()
//    {
//        udp_streams.update_all();
//    }
}
