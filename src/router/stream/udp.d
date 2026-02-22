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

    enum type_name = "udp";

    this(String name, ushort remote_port, const char[] remote_host = "255.255.255.255", ushort local_port = 0, const char[] local_host = "0.0.0.0", StreamOptions options = StreamOptions.none)
    {
        super(name.move, StringLit!type_name, options);

        // TODO: if remote_host is a broadcast address and options doesn't have `allow_broadcast`, make a warning...

        _local_host = local_host.makeString(defaultAllocator());
        _local_port = local_port;
        _remote_host = remote_host.makeString(defaultAllocator());
        _remote_port = remote_port;

        AddressInfoResolver resolve;
        Result r = local_host.get_address_info(tconcat(local_port), null, resolve);
        assert(r, "What do we even do about fails like this?");

        AddressInfo addr;
        while (resolve.next_address(addr))
        {
            _local = addr.address;
            break; // TODO: what do we even do with multiple addresses?
        }

        r = remote_host.get_address_info(tconcat(remote_port), null, resolve);
        assert(r, "What do we even do about fails like this?");

        while (resolve.next_address(addr))
        {
            _remote = addr.address;
            break; // TODO: what do we even do with multiple addresses?
        }

        _status.link_status = LinkStatus.up;
    }

    override bool running() const pure
        => status.link_status == LinkStatus.up;

    override const(char)[] remote_name()
    {
        return _remote_host[];
    }

    override ptrdiff_t read(void[] buffer) nothrow @nogc
    {
        // TODO: if a packet doesn't fill buffer, we should loop...
        size_t bytes;
        Result r = _socket.recvfrom(buffer, MsgFlags.none, null, &bytes);
        if (!r)
        {
            if (r.socket_result() == SocketResult.would_block)
                return 0;
            assert(0);
        }
        if (_logging)
            write_to_log(true, buffer[0 .. bytes]);
        return bytes;
    }

    override ptrdiff_t write(const void[] data) nothrow @nogc
    {
        // TODO: fragment on MTU...?
        size_t bytes;
        Result r = _socket.sendto(data, MsgFlags.none, &_remote, &bytes);
        if (!r)
            assert(0);
        if (_logging)
            write_to_log(true, data[0 .. bytes]);
        return bytes;
    }

    ptrdiff_t recvfrom(ubyte[] msg_buffer, out InetAddress src_addr)
    {
        size_t bytes;
        Result r = _socket.recvfrom(msg_buffer, MsgFlags.none, &src_addr, &bytes);
        if (!r)
        {
            // TODO?
            assert(0);
        }
        return bytes;
    }

    ptrdiff_t sendto(const ubyte[] data, InetAddress dest_addr)
    {
        size_t sent;
        Result r = _socket.sendto(data, MsgFlags.none, &dest_addr, &sent);
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
    Socket _socket;
    String _local_host;
    String _remote_host;
    ushort _local_port;
    ushort _remote_port;
    InetAddress _local;
    InetAddress _remote;
}


class UDPStreamModule : Module
{
    mixin DeclareModule!"stream.udp";

//    Collection!UDPStream udp_streams;
//
//    override void init()
//    {
//        g_app.console.register_collection("/stream/udp-client", udp_streams);
//    }
//
//    override void pre_update()
//    {
//        udp_streams.update_all();
//    }
}
