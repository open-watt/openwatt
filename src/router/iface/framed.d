module router.iface.framed;

import urt.array;
import urt.encoding : cobs_decode, cobs_encode, cobs_encode_length;
import urt.mem.page;
import urt.mem.pagepool : page_alloc;
import urt.meta;
import urt.time;

import manager.base;
import manager.collection;

import router.iface;
import router.stream;

nothrow @nogc:


// One raw packet per frame over a byte stream: COBS, then a zero delimiter. A pipe carries no
// connection state, so frames sent while the far end is not listening are lost; a receiver that
// attaches mid-frame discards up to the next delimiter.
final class FramedInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream));
nothrow @nogc:

    enum type_name = "framed";
    enum path = "/interface/framed";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!FramedInterface, id, flags);
    }

    // Properties

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream value)
    {
        if (_stream is value)
            return;
        if (_subscribed)
            unbind();
        _stream = value;
        mark_set!(typeof(this), "stream")();
        restart();
    }

    // API

    // A frame that does not fit the stream waits in the backlog; the next one waits for it to drain.
    override bool tx_ready() const
        => _tx.length == 0;

    override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        if (packet.type != PacketType.raw || !_subscribed)
            return -1;
        const(void)[] payload = packet.data();
        size_t at = _tx.length;
        size_t limit = cobs_encode_length(payload.length) + 1;
        if (payload.length > max_frame || at + limit > max_backlog)
        {
            add_tx_drop();
            return -1;
        }

        _tx.resize(at + limit);
        size_t n = cobs_encode(payload, _tx[at .. $ - 1]);
        _tx[][at + n] = 0;
        _tx.resize(at + n + 1);
        if (at == 0)
            push();

        add_tx_frame(payload.length);
        return 0;
    }

protected:

    override bool validate() const pure
        => _stream !is null;

    override CompletionStatus startup()
    {
        Stream s = _stream;
        if (!s || !s.running)
            return CompletionStatus.continue_;
        s.rx_handler = &on_bytes;
        s.subscribe(&stream_state_change);
        _subscribed = true;
        _hunting = true;
        _tx ~= ubyte(0);
        push();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
            unbind();
        _rx.clear();
        _tx.clear();
        return super.shutdown();
    }

private:

    enum size_t max_frame = ushort.max;
    enum size_t max_encoded = cobs_encode_length(max_frame);
    enum size_t max_backlog = 2 * (max_encoded + 1);
    enum size_t supply_chunk = 1024;

    ObjectRef!Stream _stream;
    Array!ubyte _rx;
    Array!ubyte _tx;
    bool _subscribed;
    bool _hunting;

    void unbind()
    {
        _stream.release_rx_handler(&on_bytes);
        _stream.release_tx_handler(&supply);
        _stream.unsubscribe(&stream_state_change);
        _subscribed = false;
    }

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void push()
    {
        ptrdiff_t put = _stream.write(_tx[]);
        if (put > 0)
            _tx.remove(0, put);
        if (_tx.length)
            _stream.tx_handler(&supply);
    }

    Page* supply(Stream, size_t requested)
    {
        if (_tx.length == 0)
        {
            invite_tx();
            return null;
        }
        size_t n = requested < _tx.length ? requested : _tx.length;
        if (n > supply_chunk)
            n = supply_chunk;
        Page* page = page_alloc(n);
        if (!page)
            return null;
        (cast(ubyte[])page.data)[] = _tx[0 .. n];
        _tx.remove(0, n);
        return page;
    }

    void on_bytes(Stream, const(void)[] data, MonoTime rx_time)
    {
        auto bytes = cast(const(ubyte)[])data;
        while (bytes.length)
        {
            size_t end = 0;
            while (end < bytes.length && bytes[end])
                ++end;
            if (!_hunting)
            {
                if (_rx.length + end > max_encoded)
                {
                    add_rx_drop();
                    _rx.clear();
                    _hunting = true;
                }
                else
                    _rx ~= bytes[0 .. end];
            }
            if (end == bytes.length)
                return;
            if (!_hunting)
                deliver(rx_time);
            _rx.clear();
            _hunting = false;
            bytes = bytes[end + 1 .. $];
        }
    }

    void deliver(MonoTime rx_time)
    {
        if (_rx.length == 0)
            return;
        ptrdiff_t n = cobs_decode(_rx[], _rx[]);
        if (n < 0)
            add_rx_drop();
        if (n <= 0)
            return;
        Packet p;
        p.init!RawFrame(_rx[0 .. n], rx_time);
        incoming_packet(p);
    }
}
