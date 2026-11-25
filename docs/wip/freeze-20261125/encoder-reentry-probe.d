

unittest
{
    import urt.io : writeln_err;
    import urt.lifetime : move;
    import manager : create_application, shutdown_application;
    import manager.sync.binary_encoder : BinaryEncoder;
    import router.iface;

    static final class Capture : BaseInterface
    {
        enum type_name = "encoder-reentry-audit";
    nothrow @nogc:
        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Capture, id, flags);
            _state = State.running;
            set_link(true);
        }
        override int transmit(Packet* packet, MessageCallback, const(QueuePolicy)*)
        {
            scope(exit) packet_free(packet);
            Array!ubyte frame;
            frame ~= cast(const(ubyte)[])packet.data;
            frames ~= frame.move;
            return 0;
        }
        Array!(Array!ubyte) frames;
    }

    struct Nested
    {
        SyncEncoder encoder;
        SyncPeer peer;
        bool active;
        void outgoing(const(Packet)*, BaseInterface, PacketDirection, void*) nothrow @nogc
        {
            if (active)
                return;
            active = true;
            encoder.encode_error(peer, 22, "inner");
            active = false;
        }
    }

    create_application();
    scope(exit) shutdown_application();
    Capture link = Collection!Capture().create("encoder-reentry-audit");
    scope(exit)
    {
        link.destroy();
        Collection!Capture().table.free_pending();
    }
    SyncPeer peer = alloc!SyncPeer(CID(9000));
    scope(exit) free(peer);
    peer.transport = link;
    bool all_intact = true;
    foreach (kind; [SyncEncoderKind.json, SyncEncoderKind.binary])
    {
        SyncEncoder encoder;
        if (kind == SyncEncoderKind.json)
            encoder = alloc!JsonEncoder(null);
        else
            encoder = alloc!BinaryEncoder(null);
        scope(exit) free(encoder);
        link.frames.clear();
        encoder.encode_error(peer, 11, "outer");
        assert(link.frames.length == 1);
        Array!ubyte control;
        control ~= link.frames[0][];
        link.frames.clear();
        Nested nested;
        nested.encoder = encoder;
        nested.peer = peer;
        PacketFilter filter = PacketFilter(PacketType.raw, PacketDirection.outgoing);
        link.subscribe(&nested.outgoing, filter);
        scope(exit) link.unsubscribe(&nested.outgoing);
        encoder.encode_error(peer, 11, "outer");
        bool intact = link.frames.length == 2 && link.frames[1][] == control[];
        writeln_err("encoder=", uint(kind), " captures=", link.frames.length, " outer_intact=", intact);
        if (kind == SyncEncoderKind.json)
        {
            writeln_err("control: ", cast(const(char)[])control[]);
            foreach (ref frame; link.frames[])
                writeln_err("captured: ", cast(const(char)[])frame[]);
        }
        all_intact &= intact;
    }
    assert(all_intact, "nested outgoing callback changed the outer encoder frame");
}
