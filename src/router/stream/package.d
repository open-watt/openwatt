module router.stream;

import urt.array;
import urt.conv;
import urt.file;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.pagepool;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.console.session;
import manager.expression : NamedArgument;
import manager.plugin;

public import router.status;

// package modules...
public static import router.stream.bridge;
public static import router.stream.console;
public static import router.stream.duplex;
public static import router.stream.file;
public static import router.stream.memory;
public static import router.stream.serial;
public static import router.stream.usb_serial;

version = SupportLogging;

nothrow @nogc:


alias RecvHandler = void delegate(Stream source, const(void)[] data, MonoTime rx_time) nothrow @nogc;

// Passive observer of a stream's raw byte traffic in both directions; does not consume the data.
alias TapHandler = void delegate(Stream source, bool tx, const(void)[] data, MonoTime time) nothrow @nogc;

// A returned page transfers to the sink; null releases the producer.
alias SendHandler = Page* delegate(Stream sink, size_t requested) nothrow @nogc;
alias TxReadyHandler = void delegate(Stream sink) nothrow @nogc;


enum StreamOptions : ubyte
{
    none = 0,

    reverse_connect = 1 << 0, // For TCP connections where remote will initiate connection
    buffer_data =     1 << 1, // Buffer read/write data when stream is not ready
    allow_broadcast = 1 << 2, // Allow broadcast messages
}

abstract class Stream : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("last-status-change-time", last_status_change_time, "status"),
                                 Prop!("link-status", link_status, "status", "d"),
                                 Prop!("link-downs", link_downs, "status"),
                                 Prop!("tx-link-speed", tx_link_speed, "status"),
                                 Prop!("rx-link-speed", rx_link_speed, "status"),
                                 Prop!("tx-bytes", tx_bytes, "traffic", "d"),
                                 Prop!("rx-bytes", rx_bytes, "traffic", "d"),
                                 Prop!("tx-rate", tx_rate, "traffic", "d"),
                                 Prop!("rx-rate", rx_rate, "traffic", "d"),
                                 Prop!("tx-rate-max", tx_rate_max, "traffic"),
                                 Prop!("rx-rate-max", rx_rate_max, "traffic"));
nothrow @nogc:

    enum type_name = "stream";
    enum path = "/stream";
    enum collection_id = CollectionType.stream;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(type_info, id, flags);

        this._options = options;
    }

    ~this()
    {
        set_log_file(null);
    }

    // Properties...

    SysTime last_status_change_time() const => _status.link_status_change_time;
    LinkStatus link_status() const => _status.link_status;
    ulong link_downs() const => _status.link_downs;
    ulong tx_bytes() const => _status.tx_bytes;
    ulong rx_bytes() const => _status.rx_bytes;
    ulong tx_rate() const => _status.tx_rate;
    ulong rx_rate() const => _status.rx_rate;
    ulong tx_rate_max() const => _status.tx_rate_max;
    ulong rx_rate_max() const => _status.rx_rate_max;
    ulong tx_link_speed() const => 0;
    ulong rx_link_speed() const => 0;


    // API...

    ref const(StreamStatus) status() const pure
        => _status;

    final void reset_counters()
    {
        _status.link_downs = 0;
        _status.tx_bytes = 0;
        _status.rx_bytes = 0;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        _status.tx_rate_max = 0;
        _status.rx_rate_max = 0;
        _last_bitrate_sample = MonoTime.init;

        mark_set!(typeof(this), [ "link-downs", "tx-bytes", "rx-bytes",
                                    "tx-rate", "rx-rate", "tx-rate-max", "rx-rate-max" ])();
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    void heartbeat(MonoTime now)
    {
        if (_last_bitrate_sample == MonoTime.init)
        {
            // first tick after link-up: anchor the baseline at a grid point; defer the
            // rate to the next tick so we never report it over a short partial interval.
            _last_bitrate_sample = now;
            _last_tx_bytes = _status.tx_bytes;
            _last_rx_bytes = _status.rx_bytes;
            return;
        }

        ulong elapsed_us = (now - _last_bitrate_sample).as!"usecs";
        if (elapsed_us == 0)
            return;

        ulong last_tx = _status.tx_rate, last_rx = _status.rx_rate;
        _status.tx_rate = (_status.tx_bytes - _last_tx_bytes) * 1_000_000 / elapsed_us;
        _status.rx_rate = (_status.rx_bytes - _last_rx_bytes) * 1_000_000 / elapsed_us;

        ulong dirty = 0;
        if (_status.tx_rate != last_tx)
            dirty |= ulong(1) << prop_index!(typeof(this), "tx-rate");
        if (_status.rx_rate != last_rx)
            dirty |= ulong(1) << prop_index!(typeof(this), "rx-rate");

        if (_status.tx_rate > _status.tx_rate_max)
        {
            _status.tx_rate_max = _status.tx_rate;
            dirty |= ulong(1) << prop_index!(typeof(this), "tx-rate-max");
        }
        if (_status.rx_rate > _status.rx_rate_max)
        {
            _status.rx_rate_max = _status.rx_rate;
            dirty |= ulong(1) << prop_index!(typeof(this), "rx-rate-max");
        }

        _last_tx_bytes = _status.tx_bytes;
        _last_rx_bytes = _status.rx_bytes;
        _last_bitrate_sample = now;

        if (dirty)
        {
            _props_set |= dirty;
            _mark_dirty(dirty);
        }
    }

    override void online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        _last_bitrate_sample = MonoTime.init;   // next heartbeat establishes the rate baseline
        mark_set!(typeof(this), [ "link-status", "last-status-change-time" ])();
        notify_tx_ready();
    }

    override void offline()
    {
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        mark_set!(typeof(this), [ "link-status", "last-status-change-time", "link-downs", "tx-rate", "rx-rate" ])();
    }

    final void rx_handler(RecvHandler handler)
    {
        _incoming = handler;
        if (_incoming && _rx_buffer.length)
        {
            _incoming(this, _rx_buffer[], getTime());
            _rx_buffer.clear();
        }
    }
    final RecvHandler rx_handler() const pure
        => _incoming;

    final void release_rx_handler(RecvHandler handler)
    {
        if (_incoming is handler)
            _incoming = null;
    }

    final bool tx_handler(SendHandler handler)
    {
        if (handler && !supports_tx_pages)
            return false;
        _outgoing = handler;
        if (_outgoing && !_pumping_tx)
            pump_tx();
        return true;
    }
    final SendHandler tx_handler() const pure
        => _outgoing;

    final void release_tx_handler(SendHandler handler)
    {
        if (_outgoing is handler)
            _outgoing = null;
    }

    void tx_ready_handler(TxReadyHandler handler) {}

    void release_tx_ready_handler(TxReadyHandler handler) {}

    // Passive taps observe raw traffic without consuming it (unlike the single-owner rx_handler),
    // so any number can attach - used by the /stream/tap sniffer.
    final void add_tap(TapHandler h)
    {
        if (_taps[].findFirst(h) == _taps.length)
            _taps ~= h;
    }
    final void remove_tap(TapHandler h)
        => _taps.removeFirstSwapLast(h);
    final bool has_tap() const pure
        => _taps.length != 0;

    ptrdiff_t read(void[] buffer)
    {
        size_t n = _rx_buffer.length < buffer.length ? _rx_buffer.length : buffer.length;
        if (n > 0)
        {
            (cast(ubyte[])buffer)[0 .. n] = _rx_buffer[0 .. n];
            _rx_buffer.remove(0, n);
        }
        return n;
    }

    abstract ptrdiff_t write(const(void[])[] data...);

    // bytes accepted by write() but still queued locally awaiting transmission; poll to pace bulk
    // transfers. Streams that transmit synchronously (or can't tell) report no backlog.
    size_t tx_backlog() const
        => 0;

    size_t tx_request() const
        => 0;

    bool supports_tx_pages() const
        => false;

    package(router) final bool submit_tx_page(Page* page)
        => supports_tx_pages && queue_tx_page(page);

    ptrdiff_t pending()
        => _rx_buffer.length;

    ptrdiff_t flush()
    {
        ptrdiff_t n = _rx_buffer.length;
        _rx_buffer.clear();
        return n;
    }

    TerminalChannel* terminal_channel()
    {
        return null;
    }

    void set_log_file(const(char)[] base_filename)
    {
        version (SupportLogging)
        {
            if (_log[0].is_open())
                _log[0].close();
            if (_log[1].is_open())
                _log[1].close();
            _logging = false;
            if (base_filename)
            {
                // TODO: should we not append, and instead bump a number on the end of the filename and write a new one?
                //       probably want to separate the logs for each session...?
                //       and should we disable buffering? kinda slow, but if we crash, we want to know what crashed it, right?
                _log[0].open(tconcat(base_filename, ".tx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                _log[1].open(tconcat(base_filename, ".rx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                _logging = _log[0].is_open() || _log[1].is_open();
            }
        }
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const nothrow @nogc
    {
        if (buffer.length < "stream:".length + name.length)
            return -1; // Not enough space
        return buffer.concat("stream:", name[]).length;
    }

protected:

    final void notify_tx_ready()
    {
        if (_outgoing && !_pumping_tx)
            pump_tx();
    }

    final void pump_tx()
    {
        _pumping_tx = true;
        scope (exit) _pumping_tx = false;

        size_t requested = tx_request();
        while (_outgoing && requested != 0)
        {
            SendHandler handler = _outgoing;
            Page* page = handler(this, requested);
            if (!page)
            {
                if (_outgoing is handler)
                    _outgoing = null;
                continue;
            }

            debug assert(page.length != 0);
            if (page.length == 0 || !queue_tx_page(page))
            {
                page_free(page);
                if (_outgoing is handler)
                    _outgoing = null;
            }
            else if (page.length >= requested)
                requested = tx_request();
            else
                requested -= page.length;
        }
    }

    bool queue_tx_page(Page* page)
    {
        ptrdiff_t written = write(cast(const(void)[])page.data);
        if (written != page.length)
            return false;
        page_free(page);
        return true;
    }
    StreamStatus _status;
    StreamOptions _options;

    MonoTime _last_bitrate_sample;
    ulong _last_tx_bytes;
    ulong _last_rx_bytes;
    version (SupportLogging)
    {
        bool _logging;
        File[2] _log;
    }
    else
        enum _logging = false;

    uint _buffer_len = 0;
    void[] _send_buffer;

    RecvHandler _incoming;
    Array!ubyte _rx_buffer;
    Array!TapHandler _taps;

    // When no rx_handler is installed, pushed bytes buffer here until a consumer polls read().
    // A stream that is actively drained by a producer (e.g. the serial reader thread) but has no
    // consumer would otherwise grow this without bound, so cap it and drop like a full device FIFO.
    enum max_unread_rx = 256 * 1024;

    final void incoming(const(void)[] data, MonoTime rx_time)
    {
        if (data.length == 0)
            return;
        add_rx_bytes(data.length);
        write_to_log(true, data);
        if (_incoming)
            _incoming(this, data, rx_time);
        else if (_rx_buffer.length < max_unread_rx)
            _rx_buffer ~= cast(const(ubyte)[])data;
    }

    final void add_tx_bytes(size_t bytes)
    {
        _status.tx_bytes += bytes;
        mark_set!(typeof(this), [ "tx-bytes" ])();
    }

    final void add_rx_bytes(size_t bytes)
    {
        _status.rx_bytes += bytes;
        mark_set!(typeof(this), [ "rx-bytes" ])();
    }

    final void write_to_log(bool rx, const void[] buffer)
    {
        // both directions funnel through here (incoming() for rx, subclass write() for tx), so this
        // is the single point taps observe. rx==true here means received, i.e. tx==false for the tap.
        if (_taps.length && buffer.length)
        {
            MonoTime t = getTime();
            foreach (h; _taps[])
                h(this, !rx, buffer, t);
        }

        version (SupportLogging)
        {
            if (!_logging || !_log[rx].is_open)
                return;
            size_t written;
            _log[rx].write(buffer, written);
            // TODO: do we want to assert the write was successful? maybe disk full? should probably not crash the app...
//            assert(written == buffer.length, "Failed to write to log file...?");
        }
    }

private:
    SendHandler _outgoing;
    bool _pumping_tx;
}

class StreamModule : Module
{
    mixin DeclareModule!"stream";
nothrow @nogc:

    override void pre_init()
    {
        g_app.console.register_collection!Stream();
    }

    override void init()
    {
        g_app.console.register_command!(stream_tap, "tap")("/stream", this);
        g_app.console.register_command!(stream_rts, "rts")("/stream", this);
    }

    override void pre_update()
    {
        Collection!Stream().update_all();
    }

    // /stream/tap <name> [on|off] - attach a passive sniffer that logs the raw byte traffic of a
    // stream in both directions. Watch it live with: /log print match=tap
    void stream_tap(Session session, const(char)[] name, Nullable!bool enable)
    {
        Stream s = Collection!Stream().get(name);
        if (!s)
        {
            session.write_line(tconcat("no such stream: ", name));
            return;
        }

        bool on = enable ? enable.value : !s.has_tap;
        if (on)
        {
            s.add_tap(&tap_log);
            session.write_line(tconcat("tapping '", name, "' - watch with: /log print match=tap"));
        }
        else
        {
            s.remove_tap(&tap_log);
            session.write_line(tconcat("stopped tapping '", name, "'"));
        }
    }

    void tap_log(Stream s, bool tx, const(void)[] data, MonoTime time)
    {
        log_infof("tap", "{0} {1} ({2,3}B): {3}", s.name, tx ? "TX" : "RX", data.length, cast(void[])data);
    }

    // /stream/rts <name> <on|off> - drive the RTS line of a serial stream by hand. Used to probe
    // whether asserting RTS actually resets a device (Silabs NCPs wire RTS to nRESET), by watching
    // the link recover (or not) after a manual assert/release cycle.
    void stream_rts(Session session, const(char)[] name, bool assert_line)
    {
        import router.stream.serial : SerialStream;

        SerialStream ss = dyn_cast!SerialStream(Collection!Stream().get(name));
        if (!ss)
        {
            session.write_line(tconcat("no such serial stream: ", name));
            return;
        }

        bool ok = ss.set_rts(assert_line);
        session.write_line(tconcat("RTS ", assert_line ? "asserted" : "released", " on '", name, "': ", ok ? "ok" : "FAILED (hardware flow control?)"));
    }
}

unittest
{
    import urt.mem;

    class TestTxStream : Stream
    {
    nothrow @nogc:

        enum type_name = "test-tx-stream";

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestTxStream, id, flags);
        }

        override ptrdiff_t write(const(void[])[] data...) => 0;

        override size_t tx_request() const
            => _space;

        override bool supports_tx_pages() const
            => supported;

        override void tx_ready_handler(TxReadyHandler handler)
        {
            _observer = handler;
        }

        override void release_tx_ready_handler(TxReadyHandler handler)
        {
            if (_observer is handler)
                _observer = null;
        }

        void grant(size_t space)
        {
            _space += space;
            notify_tx_ready();
            if (_observer)
                _observer(this);
        }

        void reset()
        {
            output.clear();
            _space = 0;
        }

        Array!ubyte output;
        bool supported = true;

    protected:
        override bool queue_tx_page(Page* page)
        {
            output ~= cast(const(ubyte)[])page.data;
            _space = page.length < _space ? _space - page.length : 0;
            page_free(page);
            return true;
        }

    private:
        size_t _space;
        TxReadyHandler _observer;
    }

    struct TestTxProducer
    {
    nothrow @nogc:

        Page* produce(Stream stream, size_t requested)
        {
            ++calls;
            if (replacement)
            {
                SendHandler handler = replacement;
                replacement = null;
                stream.tx_handler(handler);
                return null;
            }
            if (remaining == 0)
                return null;

            size_t n = remaining < requested ? remaining : requested;
            if (block_size != 0)
                n = remaining < block_size ? remaining : block_size;
            else if (n > max_page)
                n = max_page;
            Page* page = page_alloc(n);
            if (!page)
                return null;
            foreach (i; 0 .. n)
                (cast(ubyte[])page.data)[i] = next++;
            remaining -= n;
            if (release)
                stream.release_tx_handler(&produce);
            return page;
        }

        size_t remaining;
        size_t calls;
        size_t max_page = 1600;
        size_t block_size;
        ubyte next;
        bool release;
        SendHandler replacement;
    }

    struct TestTxObserver
    {
    nothrow @nogc:

        void ready(Stream)
        {
            ++calls;
        }

        size_t calls;
    }

    bool owns_pool = page_pool_init();
    scope(exit) if (owns_pool) page_pool_deinit();

    TestTxStream stream = alloc!TestTxStream(CID(1));
    scope(exit) free(stream);

    TestTxProducer first = TestTxProducer(6_000);
    stream.grant(9_000);
    stream.tx_handler(&first.produce);
    assert(first.calls == 5 && first.remaining == 0);
    assert(stream.output.length == 6_000 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer paced = TestTxProducer(15);
    stream.grant(10);
    stream.tx_handler(&paced.produce);
    assert(paced.calls == 1 && paced.remaining == 5 && stream.output.length == 10);
    stream.grant(5);
    assert(paced.calls == 2 && paced.remaining == 0 && stream.output.length == 15);
    stream.grant(1);
    assert(paced.calls == 3 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer granular = TestTxProducer(7);
    granular.block_size = 5;
    stream.grant(3);
    stream.tx_handler(&granular.produce);
    assert(granular.calls == 1 && granular.remaining == 2 && stream.output.length == 5);
    stream.grant(3);
    assert(granular.calls == 3 && granular.remaining == 0);
    assert(stream.output.length == 7 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer replacement = TestTxProducer(3);
    TestTxProducer replacing;
    replacing.replacement = &replacement.produce;
    stream.grant(3);
    stream.tx_handler(&replacing.produce);
    assert(replacing.calls == 1 && replacement.calls == 1 && stream.output.length == 3);
    stream.grant(1);
    assert(replacement.calls == 2 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer releasing = TestTxProducer(2);
    releasing.release = true;
    stream.grant(2);
    stream.tx_handler(&releasing.produce);
    assert(releasing.calls == 1 && stream.output.length == 2 && stream.tx_handler is null);

    TestTxObserver observer;
    stream.tx_ready_handler(&observer.ready);
    stream.grant(1);
    assert(observer.calls == 1);
    stream.release_tx_ready_handler(&observer.ready);

    stream.supported = false;
    assert(!stream.tx_handler(&first.produce));
    assert(stream.tx_handler is null);
}

