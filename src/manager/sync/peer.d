module manager.sync.peer;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.sync;
import manager.sync.encoder;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class SyncPeer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("transport", transport),
                                 Prop!("encoder",   encoder));
nothrow @nogc:

    enum type_name = "peer";
    enum path = "/sync/peer";
    enum collection_id = CollectionType.sync_peer;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SyncPeer, id, flags);
    }

    // Properties

    final inout(BaseInterface) transport() inout pure
        => _transport;
    final void transport(BaseInterface value)
    {
        if (_transport is value)
            return;
        detach_transport();
        _transport = value;
        restart();
    }

    final SyncEncoderKind encoder() const pure
        => _encoder;
    final void encoder(SyncEncoderKind value)
    {
        if (_encoder == value)
            return;
        _encoder = value;
        restart();
    }

    // API

    void transmit_frame(const(ubyte)[] frame, bool is_text = false)
    {
        if (!_transport || !_transport.running)
            return;
        Packet p;
        ref hdr = p.init!RawFrame(frame);
        hdr.is_text = is_text;
        _transport.forward(p);
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _transport !is null;

    override CompletionStatus startup()
    {
        if (!_transport || !_transport.running)
            return CompletionStatus.continue_;

        _transport.subscribe(&on_transport_packet,
                             PacketFilter(PacketType.raw, PacketDirection.incoming));
        _transport.subscribe(&on_transport_state);
        _transport_subscribed = true;

        get_module!SyncModule.attach_peer(this);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        get_module!SyncModule.detach_peer(this);
        detach_transport();
        return CompletionStatus.complete;
    }

package:
    Array!String     _subscriptions;
    Array!BaseObject _bound;             // objects we've sent bind{...} to this peer
    Array!BaseObject _authoritative;     // proxies we hold on this peer's behalf
    SyncEncoderKind  _encoder;

private:
    ObjectRef!BaseInterface _transport;
    bool                    _transport_subscribed;

    void detach_transport()
    {
        if (!_transport_subscribed)
            return;
        _transport.unsubscribe(&on_transport_packet);
        _transport.unsubscribe(&on_transport_state);
        _transport_subscribed = false;
    }

    void on_transport_packet(ref const Packet p, BaseInterface, PacketDirection, void*) nothrow @nogc
    {
        encoder_for(_encoder).decode_and_dispatch(this, cast(const(ubyte)[])p.data);
    }

    void on_transport_state(ActiveObject, StateSignal sig) nothrow @nogc
    {
        if (sig == StateSignal.offline)
            restart();
    }
}
