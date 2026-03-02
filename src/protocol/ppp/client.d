module protocol.ppp.client;

import urt.array;
import urt.lifetime;
import urt.string;
import urt.time;

import manager.base;

import protocol.ppp;

import router.iface;
import router.stream;

nothrow @nogc:


class PPPClient : BaseInterface
{
    __gshared Property[3] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("protocol", protocol)() ];
nothrow @nogc:

    enum type_name = "ppp";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PPPClient, name.move, flags);

        // Default protocol is PPP
        mtu = 1500;
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => _protocol < TunnelProtocol.PPPoE ? _stream : null;
    final const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _stream = value;
        restart();
        return null;
    }

    final TunnelProtocol protocol() const pure
        => _protocol;
    final const(char)[] protocol(TunnelProtocol value)
    {
        if (value >= TunnelProtocol.PPPoE)
            return "invalid PPP client protocol";
        if (value == _protocol)
            return null;
        _protocol = value;
        restart();
        return null;
    }

    // API...

    override bool validate() const pure
        => (_protocol < TunnelProtocol.PPPoE && _stream !is null);

    final override CompletionStatus startup()
    {
        if (_protocol < TunnelProtocol.PPPoE && _stream.running)
        {
            assert(false, "TODO: begin PPP handshake...");

            return CompletionStatus.complete;
        }
        return CompletionStatus.continue_;
    }

    final override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update()
    {
        ubyte[2048] buffer = void;
        SysTime now = getSysTime();

        const ubyte FRAME_END = (_protocol == TunnelProtocol.PPP) ? 0x7E : 0xC0;

        if (!_stream)
            restart();

        // check for data
        ptrdiff_t frameStart = 0;
        ptrdiff_t offset = 0;
        ptrdiff_t length = 0;
        read_loop: while (true)
        {
            ptrdiff_t r = _stream.read(buffer[offset .. $]);
            if (r < 0)
            {
                // TODO: do we care what causes read to fail?
                restart();
                return;
            }
            if (r == 0)
            {
                // if there were no extra bytes available, stash the tail until later
                assert(false);
                break read_loop;
            }
            length = offset + r;

            for (size_t i = 0; i < length; ++i)
            {
                ubyte b = buffer[frameStart + i];
                if (b == FRAME_END)
                {
                    if (offset > frameStart)
                    {
                        if (_protocol == TunnelProtocol.PPP)
                        {
                            assert(false, "TODO");

                            // validate MTU...

                            // validate the CRC...

                            // check frame type...
                        }
                        else
                        {
                            assert(false, "TODO");

                            // validate MTU...

                            // SLIP transmits IP frames...
                            assert(false, "TODO: what do we do with an IP frame...");
                        }

                        frameStart = offset + 1;
                    }
                }
                else if (b == 0xDB)
                {
                    // handle escape byte
                    if (i + 1 < length)
                    {
                        b = buffer[++i];
                        if (b == 0xDC)
                            buffer[offset++] = FRAME_END;
                        else if (b == 0xDD)
                            buffer[offset++] = 0xDB;
                        else
                            assert(false, "TODO: invalid frame... drop this one");
                    }
                }
                else if (i > offset)
                    buffer[offset] = b;
                ++offset;
            }

            assert(false, "TODO");
            // shuffle buffer[frameStart .. offset] to the front

            // and start over...
        }
    }

protected:
    override int transmit(ref const Packet packet, MessageCallback)
    {
        assert(false, "TODO: frame and transmit");
    }

private:
    ObjectRef!Stream _stream;
    TunnelProtocol _protocol;
    Array!ubyte _tail;
}


class PPPoEClient : BaseInterface
{
    __gshared Property[3] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("protocol", protocol)() ];
nothrow @nogc:

    enum type_name = "pppoe";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PPPoEClient, name.move, flags);

        // Default protocol is PPPoE
        mtu = 1492; // TODO: what about 'baby jumbo' (RFC 4638) which supports 1500 inside pppoe?
    }

    ~this()
    {
        if (_interface)
            _interface.unsubscribe(&incoming_packet);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure
        => _protocol >= TunnelProtocol.PPPoE ? _interface : null;
    final const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_interface is value)
            return null;
        if (_interface)
            _interface.unsubscribe(&incoming_packet);

        _interface = value;
        _interface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.pppoes, ether_type_2: EtherType.pppoed), null);

        restart();
        return null;
    }

    final TunnelProtocol protocol() const pure
        => _protocol;
    final const(char)[] protocol(TunnelProtocol value)
    {
        if (value < TunnelProtocol.PPPoE)
            return "invalid PPPoE client protocol";
        if (value == _protocol)
            return  null;
        _protocol = value;
        restart();
        return null;
    }

    // API...

    override bool validate() const pure
        => (_protocol >= TunnelProtocol.PPPoE && _interface !is null);

    final override CompletionStatus startup()
    {
        if (_protocol >= TunnelProtocol.PPPoE && _interface.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    final override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_interface)
            restart();
    }

protected:
    override int transmit(ref const Packet packet, MessageCallback)
    {
        assert(false, "TODO: frame and transmit");
    }

private:
    ObjectRef!BaseInterface _interface;
    TunnelProtocol _protocol;

    void incoming_packet(ref const Packet packet, BaseInterface srcInterface, PacketDirection dir, void* user_data)
    {
        assert(false, "TODO: Listen for PPPoE Discovery and Session packets");
    }
}
