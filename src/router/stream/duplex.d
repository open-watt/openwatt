module router.stream.duplex;

import urt.mem.page;
import urt.mem.temp;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.stream;

nothrow @nogc:


final class DuplexStream : Stream
{
    alias Properties = AliasSeq!(Prop!("tx", tx),
                                 Prop!("rx", rx));
nothrow @nogc:

    ~this() {}

    enum type_name = "duplex";
    enum path = "/stream/duplex";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DuplexStream, id, flags, StreamOptions.none);
    }

    // Properties

    final inout(Stream) tx() inout pure => _tx;
    final void tx(Stream value)
    {
        if (_tx is value)
            return;
        if (_tx)
            _tx.release_tx_handler(&provide_tx_page);
        if (_tx_subscribed)
        {
            _tx.unsubscribe(&stream_state_change);
            _tx_subscribed = false;
        }
        _tx = value;
        mark_set!(typeof(this), "tx")();
        restart();
    }

    final inout(Stream) rx() inout pure => _rx;
    final void rx(Stream value)
    {
        if (_rx is value)
            return;
        if (_rx_subscribed)
        {
            _rx.release_rx_handler(&inner_rx);
            _rx.unsubscribe(&stream_state_change);
            _rx_subscribed = false;
        }
        _rx = value;
        mark_set!(typeof(this), "rx")();
        restart();
    }

    // API

    override ulong tx_link_speed() const
        => _tx ? _tx.tx_link_speed : 0;
    override ulong rx_link_speed() const
        => _rx ? _rx.rx_link_speed : 0;

    override size_t tx_request() const
        => _tx ? _tx.tx_request : 0;


    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!_tx || !_tx.running)
            return 0;
        ptrdiff_t n = _tx.write(data);
        if (n > 0)
        {
            add_tx_bytes(n);
            if (_logging)
            {
                size_t remain = n;
                foreach (d; data)
                {
                    if (remain == 0)
                        break;
                    size_t chunk = d.length < remain ? d.length : remain;
                    write_to_log(false, d[0 .. chunk]);
                    remain -= chunk;
                }
            }
        }
        return n;
    }

protected:

    override bool validate() const pure
        => _tx !is null || _rx !is null;

    override CompletionStatus startup()
    {
        if (_tx && !_tx.running)
            return CompletionStatus.continue_;
        if (_rx && !_rx.running)
            return CompletionStatus.continue_;

        if (_tx)
        {
            _tx.subscribe(&stream_state_change);
            _tx_subscribed = true;
            tx_handler_changed();
        }
        if (_rx)
        {
            _rx.subscribe(&stream_state_change);
            _rx_subscribed = true;
            rx_handler_changed();
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe();
        return CompletionStatus.complete;
    }

    // the rx stream holds its bytes until this stream has a consumer for them
    override void rx_handler_changed()
    {
        if (!_rx_subscribed)
            return;
        if (rx_handler)
            _rx.rx_handler(&inner_rx);
        else
            _rx.release_rx_handler(&inner_rx);
    }

    override void tx_handler_changed()
    {
        Stream stream = _tx.get;
        if (!stream || !stream.running)
            return;
        if (tx_handler)
            stream.tx_handler(&provide_tx_page);
        else
            stream.release_tx_handler(&provide_tx_page);
    }

private:
    ObjectRef!Stream _tx;
    ObjectRef!Stream _rx;
    bool _tx_subscribed;
    bool _rx_subscribed;

    Page* provide_tx_page(ref const TxRequest req, out TxStatus status)
    {
        Page* page = request_tx_page(req, status);
        if (!page)
            return null;
        add_tx_bytes(page.length);
        if (_logging)
            write_to_log(false, page.data);
        return page;
    }

    void inner_rx(Stream, const(void)[] data, MonoTime rx_time)
    {
        incoming(data, rx_time);
    }

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            unsubscribe();
            restart();
        }
    }

    void unsubscribe()
    {
        if (_tx)
            _tx.release_tx_handler(&provide_tx_page);
        if (_tx_subscribed)
        {
            _tx.unsubscribe(&stream_state_change);
            _tx_subscribed = false;
        }
        if (_rx_subscribed)
        {
            _rx.release_rx_handler(&inner_rx);
            _rx.unsubscribe(&stream_state_change);
            _rx_subscribed = false;
        }
    }
}


final class DuplexStreamModule : Module
{
    mixin DeclareModule!"stream.duplex";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!DuplexStream();
    }
}
