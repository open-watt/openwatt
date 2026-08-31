module router.stream.duplex;

import urt.mem.page;
import urt.mem.temp;
import urt.string;
import urt.string.format;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.stream;

nothrow @nogc:


class DuplexStream : Stream
{
    alias Properties = AliasSeq!(Prop!("tx", tx),
                                 Prop!("rx", rx));
nothrow @nogc:

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
        if (_tx_ready_subscribed)
        {
            _tx.release_tx_ready_handler(&tx_ready);
            _tx_ready_subscribed = false;
        }
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

    override size_t tx_backlog() const
        => _tx ? _tx.tx_backlog : 0;

    override size_t tx_request() const
        => _tx ? _tx.tx_request : 0;

    override bool supports_tx_pages() const
        => _tx && _tx.supports_tx_pages;

    override void tx_ready_handler(TxReadyHandler handler)
    {
        _tx_observer = handler;
    }

    override void release_tx_ready_handler(TxReadyHandler handler)
    {
        if (_tx_observer is handler)
            _tx_observer = null;
    }

    override ptrdiff_t read(void[] buffer)
    {
        if (!_rx || !_rx.running)
            return 0;
        ptrdiff_t n = _rx.read(buffer);
        if (n > 0)
        {
            add_rx_bytes(n);
            if (_logging)
                write_to_log(true, buffer[0 .. n]);
        }
        return n;
    }

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

    override ptrdiff_t pending()
        => (_rx && _rx.running) ? _rx.pending() : 0;

    override ptrdiff_t flush()
        => (_rx && _rx.running) ? _rx.flush() : 0;

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
            if (_tx.supports_tx_pages)
            {
                _tx.tx_ready_handler(&tx_ready);
                _tx_ready_subscribed = true;
            }
        }
        if (_rx)
        {
            _rx.subscribe(&stream_state_change);
            _rx_subscribed = true;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe();
        return CompletionStatus.complete;
    }

    override bool queue_tx_page(Page* page)
    {
        if (_logging)
            return super.queue_tx_page(page);

        Stream stream = _tx.get;
        size_t length = page.length;
        if (!stream || !stream.submit_tx_page(page))
            return false;
        add_tx_bytes(length);
        return true;
    }

private:
    ObjectRef!Stream _tx;
    ObjectRef!Stream _rx;
    TxReadyHandler _tx_observer;
    bool _tx_subscribed;
    bool _rx_subscribed;
    bool _tx_ready_subscribed;

    void tx_ready(Stream)
    {
        notify_tx_ready();
        if (_tx_observer)
            _tx_observer(this);
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
        if (_tx_ready_subscribed)
        {
            _tx.release_tx_ready_handler(&tx_ready);
            _tx_ready_subscribed = false;
        }
        if (_tx_subscribed)
        {
            _tx.unsubscribe(&stream_state_change);
            _tx_subscribed = false;
        }
        if (_rx_subscribed)
        {
            _rx.unsubscribe(&stream_state_change);
            _rx_subscribed = false;
        }
    }
}


class DuplexStreamModule : Module
{
    mixin DeclareModule!"stream.duplex";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!DuplexStream();
    }
}
