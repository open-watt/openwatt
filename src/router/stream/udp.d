module router.stream.udp;

import urt.io;
import urt.lifetime;
import urt.socket;
import urt.string;
import urt.string.format;

import manager;
import manager.collection;
import manager.plugin;

public import router.stream;

nothrow @nogc:


class UDPStream : Stream
{
    alias Properties = AliasSeq!(Prop!("local-host", local_host),
                                 Prop!("local-port", local_port),
                                 Prop!("remote-host", remote_host),
                                 Prop!("remote-port", remote_port));
nothrow @nogc:

    enum type_name = "udp";
    enum path = "/stream/udp";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!UDPStream, id, flags, StreamOptions.none);
    }

    // Properties

    final ref const(String) local_host() const pure => _local_host;
    final void local_host(String value)
    {
        if (value == _local_host)
            return;
        _local_host = value.move;
        restart();
    }

    final ushort local_port() const pure => _local_port;
    final void local_port(ushort value)
    {
        if (value == _local_port)
            return;
        _local_port = value;
        restart();
    }

    final ref const(String) remote_host() const pure => _remote_host;
    final void remote_host(String value)
    {
        if (value == _remote_host)
            return;
        _remote_host = value.move;
        restart();
    }

    final ushort remote_port() const pure => _remote_port;
    final void remote_port(ushort value)
    {
        if (value == _remote_port)
            return;
        _remote_port = value;
        restart();
    }

protected:
    override bool validate() const pure
        => _remote_port != 0;

    override CompletionStatus startup()
    {
        AddressInfoResolver resolve;
        Result r = _local_host[].get_address_info(tconcat(_local_port), null, resolve);
        if (!r) return CompletionStatus.error;

        AddressInfo addr;
        while (resolve.next_address(addr))
        {
            _local = addr.address;
            break;
        }

        r = _remote_host[].get_address_info(tconcat(_remote_port), null, resolve);
        if (!r) return CompletionStatus.error;

        while (resolve.next_address(addr))
        {
            _remote = addr.address;
            break;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_socket)
        {
            _socket.close();
            _socket = Socket.init;
        }
        return CompletionStatus.complete;
    }

    override const(char)[] remote_name()
        => _remote_host[];

    override ptrdiff_t read(void[] buffer) nothrow @nogc
    {
        size_t bytes;
        Result r = _socket.recvfrom(buffer, MsgFlags.none, null, &bytes);
        if (!r)
        {
            if (r.socket_result() == SocketResult.would_block)
                return 0;
            assert(0);
        }
        add_rx_bytes(bytes);
        if (_logging)
            write_to_log(true, buffer[0 .. bytes]);
        return bytes;
    }

    override ptrdiff_t write(const(void[])[] data...) nothrow @nogc
    {
        size_t bytes;
        Result r = _socket.sendto(&_remote, &bytes, data);
        if (!r)
            assert(0);
        add_tx_bytes(bytes);
        if (_logging)
        {
            import urt.util : min;
            ptrdiff_t remain = bytes;
            for (size_t i = 0; remain > 0; ++i)
            {
                size_t len = min(data[i].length, remain);
                write_to_log(false, data[i][0 .. len]);
                remain -= len;
            }
        }
        return bytes;
    }

    ptrdiff_t recvfrom(ubyte[] msg_buffer, out InetAddress src_addr)
    {
        size_t bytes;
        Result r = _socket.recvfrom(msg_buffer, MsgFlags.none, &src_addr, &bytes);
        if (!r)
            assert(0);
        return bytes;
    }

    ptrdiff_t sendto(const ubyte[] data, InetAddress dest_addr)
    {
        size_t sent;
        Result r = _socket.sendto(data, MsgFlags.none, &dest_addr, &sent);
        if (!r)
            assert(0);
        return sent;
    }

    override ptrdiff_t pending()
        => 0;

    override ptrdiff_t flush()
    {
        assert(0, "TODO");
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
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!UDPStream();
    }
}
