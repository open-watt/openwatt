module protocol.ppp.server;

import urt.lifetime;
import urt.string;

import manager.base;

import protocol.ppp;

import router.iface;
import router.stream;

nothrow @nogc:


class PPPServer : BaseInterface
{
    __gshared Property[2] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("protocol", protocol)() ];
nothrow @nogc:
    alias TypeName = StringLit!"ppp-server";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!PPPServer, name.move, flags);

        // Default protocol is PPP
        mtu = 1500;
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => _stream;
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

    TunnelProtocol protocol() const pure
        => _protocol;
    const(char)[] protocol(TunnelProtocol value)
    {
        if (value == _protocol)
            return null;
        if (value >= TunnelProtocol.PPPoE)
            return "invalid PPP server protocol";
        _protocol = value;

        restart();
        return null;
    }

    // API...

    override bool validate() const pure
        => _stream !is null;

    final override CompletionStatus startup()
    {
        if (!_stream.running)
            return CompletionStatus.Continue;
        return CompletionStatus.Complete;
    }

    final override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
        if (!_stream)
            restart();

        // listen for incoming PPP discovery...
        assert(false, "TODO");
    }

protected:
    override bool transmit(ref const Packet packet)
    {
        assert(false, "TODO: frame and transmit");
    }

private:
    ObjectRef!Stream _stream;
    TunnelProtocol _protocol;
}


class PPPoEServer : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("protocol", protocol)() ];
nothrow @nogc:

    alias TypeName = StringLit!"pppoe-server";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!PPPoEServer, name.move, flags);
    }

    ~this()
    {
        if (_interface)
            _interface.unsubscribe(&incomingPacket);
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
            _interface.unsubscribe(&incomingPacket);

        _interface = value;
        _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.PPPoES, etherType2: EtherType.PPPoED), null);

        restart();
        return null;
    }

    TunnelProtocol protocol() const pure
        => _protocol;
    const(char)[] protocol(TunnelProtocol value)
    {
        if (value == _protocol)
            return null;
        if (value < TunnelProtocol.PPPoE)
            return "invalid PPPoE server protocol";
        _protocol = value;

        restart();
        return null;
    }

    // API...

    override bool validate() const pure
        => _interface !is null;

    final override CompletionStatus startup()
    {
        if (!_interface.running)
            return CompletionStatus.Continue;
        return CompletionStatus.Continue;
    }

    final override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
        if (!_interface)
            restart();
    }

private:
    ObjectRef!BaseInterface _interface;
    TunnelProtocol _protocol;

    void incomingPacket(ref const Packet packet, BaseInterface srcInterface, PacketDirection dir, void* userData)
    {
        assert(false, "TODO: Listen for PPPoE Discovery and Session packets");
    }
}
