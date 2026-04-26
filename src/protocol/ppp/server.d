module protocol.ppp.server;

import urt.lifetime;
import urt.string;

import manager.base;
import manager.collection : RekeyHandler;

import protocol.ppp;

import router.iface;
import router.stream;

nothrow @nogc:


class PPPServer : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("protocol", protocol));
nothrow @nogc:

    enum type_name = "ppp-server";
    enum path = "/protocol/ppp/server";
    enum collection_id = CollectionType.ppp_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PPPServer, id, flags);

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

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _stream !is null;

    final override CompletionStatus startup()
    {
        if (!_stream.running)
            return CompletionStatus.continue_;
        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        if (!_stream)
            restart();

        // listen for incoming PPP discovery...
        assert(false, "TODO");
    }

    override int transmit(ref const Packet packet, MessageCallback)
    {
        assert(false, "TODO: frame and transmit");
    }

private:
    ObjectRef!Stream _stream;
    TunnelProtocol _protocol;
}


class PPPoEServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("protocol", protocol));
nothrow @nogc:

    enum type_name = "pppoe-server";
    enum path = "/protocol/pppoe/server";
    enum collection_id = CollectionType.pppoe_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PPPoEServer, id, flags);
    }

    ~this()
    {
        if (_interface)
            _interface.unsubscribe(&incoming_packet);
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
        _interface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.pppoes, ether_type_2: EtherType.pppoed), null);

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
            return CompletionStatus.continue_;
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
    mixin RekeyHandler;

private:
    ObjectRef!BaseInterface _interface;
    TunnelProtocol _protocol;

    void incoming_packet(ref const Packet packet, BaseInterface srcInterface, PacketDirection dir, void* user_data)
    {
        assert(false, "TODO: Listen for PPPoE Discovery and Session packets");
    }
}
