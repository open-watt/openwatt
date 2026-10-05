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

// A sink never asks for less; below this a producer cannot make progress through its framing.
enum size_t min_tx_request = 64;

struct TxRequest
{
    size_t bytes;
}

enum TxStatus : ubyte
{
    more,       // further pages follow; a null page with more is a contract violation
    idle,       // nothing more for now; the producer re-arms with tx_handler()
    starved,    // page_alloc failed; the sink waits for a free page and pulls again
    end,        // complete; a page returned with it is the last
    abort,      // failed; the producer's owner terminates the stream
}

// A returned page transfers to the sink. A producer never exceeds req.bytes.
alias SendHandler = Page* delegate(ref const TxRequest req, out TxStatus status) nothrow @nogc;

Page* alloc_tx_page(ref const TxRequest req, size_t bytes, ref TxStatus status)
{
    debug assert(bytes <= req.bytes);
    Page* page = page_alloc(bytes);
    if (!page)
        status = TxStatus.starved;
    return page;
}

// hands out at most req.bytes from the front of chain, copying the front of a longer head into a fresh page
Page* take_tx_page(ref Page* chain, ref const TxRequest req, ref TxStatus status)
{
    Page* head = chain;
    if (head.length <= req.bytes)
    {
        chain = head.next;
        head.next = null;
        return head;
    }
    Page* page = alloc_tx_page(req, req.bytes, status);
    if (!page)
        return null;
    page.data[] = head.data[0 .. req.bytes];
    head.offset += cast(ushort)req.bytes;
    head.length -= cast(ushort)req.bytes;
    return page;
}

void append_tx_chain(ref Page* chain, Page* pages)
{
    if (!chain)
    {
        chain = pages;
        return;
    }
    Page* tail = chain;
    while (tail.next)
        tail = tail.next;
    tail.next = pages;
}

// a producer that installs a replacement and returns nothing is followed by a pull from the replacement
Page* pull_tx_page(ref SendHandler slot, ref const TxRequest req, out TxStatus status)
{
    while (slot)
    {
        SendHandler handler = slot;
        Page* page = handler(req, status);
        if (!page && status == TxStatus.more)
        {
            debug assert(false, "producer returned no page with more");
            status = TxStatus.idle;
        }
        if (slot is handler)
        {
            if (status != TxStatus.more && status != TxStatus.starved)
                slot = null;
            return page;
        }
        if (page || !slot || status != TxStatus.idle)
            return page;
    }
    status = TxStatus.idle;
    return null;
}


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

    final SysTime last_status_change_time() const => _status.link_status_change_time;
    final LinkStatus link_status() const => _status.link_status;
    final ulong link_downs() const => _status.link_downs;
    final ulong tx_bytes() const => _status.tx_bytes;
    final ulong rx_bytes() const => _status.rx_bytes;
    final ulong tx_rate() const => _status.tx_rate;
    final ulong rx_rate() const => _status.rx_rate;
    final ulong tx_rate_max() const => _status.tx_rate_max;
    final ulong rx_rate_max() const => _status.rx_rate_max;
    ulong tx_link_speed() const => 0;
    ulong rx_link_speed() const => 0;


    // API...

    final ref const(StreamStatus) status() const pure
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

    final void heartbeat(MonoTime now)
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

    final override void online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        _last_bitrate_sample = MonoTime.init;   // next heartbeat establishes the rate baseline
        mark_set!(typeof(this), [ "link-status", "last-status-change-time" ])();
        tx_handler_changed();
    }

    final override void offline()
    {
        page_unwait(&_tx_waiter);
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
        tx_handler_changed();
        return true;
    }
    final SendHandler tx_handler() const pure
        => _outgoing;

    final void release_tx_handler(SendHandler handler)
    {
        if (_outgoing is handler)
        {
            _outgoing = null;
            tx_handler_changed();
        }
    }

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

    size_t tx_request() const
        => 0;

    bool supports_tx_pages() const
        => false;

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

    final void set_log_file(const(char)[] base_filename)
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

protected:

    void tx_handler_changed()
    {
        if (_outgoing && !_pumping_tx)
            pump_tx();
    }

    final Page* request_tx_page(ref const TxRequest req, out TxStatus status)
        => pull_tx_page(_outgoing, req, status);

    final void pump_tx()
    {
        _pumping_tx = true;
        scope (exit) _pumping_tx = false;

        while (_outgoing)
        {
            TxRequest req = TxRequest(tx_request());
            if (req.bytes < min_tx_request)
                break;
            uint generation = page_free_generation();
            TxStatus status;
            Page* page = request_tx_page(req, status);
            if (page && (page.length == 0 || !queue_tx_page(page)))
            {
                debug assert(page.length != 0);
                page_free(page);
                _outgoing = null;
                break;
            }
            if (status == TxStatus.starved)
            {
                _tx_waiter.wake = &pump_tx;
                if (page_wait(&_tx_waiter, generation))
                    break;
            }
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
    PageWaiter _tx_waiter;
    bool _pumping_tx;
}

final class StreamModule : Module
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

        ~this() {}

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

        void grant(size_t space)
        {
            _space += space;
            pump_tx();
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
    }

    struct TestTxProducer
    {
    nothrow @nogc:

        Page* produce(ref const TxRequest req, out TxStatus status)
        {
            ++calls;
            if (replacement)
            {
                SendHandler handler = replacement;
                replacement = null;
                stream.tx_handler(handler);
                status = TxStatus.idle;
                return null;
            }
            if (starve)
            {
                starve = false;
                if (freed_meanwhile)
                    page_free(page_alloc(1));
                status = TxStatus.starved;
                return null;
            }
            if (fail)
            {
                status = TxStatus.abort;
                return null;
            }
            if (remaining == 0)
            {
                status = TxStatus.idle;
                return null;
            }

            size_t n = remaining < req.bytes ? remaining : req.bytes;
            if (n > max_page)
                n = max_page;
            Page* page = alloc_tx_page(req, n, status);
            if (!page)
                return null;
            foreach (i; 0 .. n)
                (cast(ubyte[])page.data)[i] = next++;
            remaining -= n;
            if (finish && remaining == 0)
                status = TxStatus.end;
            if (release)
                stream.release_tx_handler(&produce);
            return page;
        }

        size_t remaining;
        size_t calls;
        size_t max_page = 1600;
        Stream stream;
        ubyte next;
        bool release;
        bool finish;
        bool starve;
        bool freed_meanwhile;
        bool fail;
        SendHandler replacement;
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
    TestTxProducer paced = TestTxProducer(150);
    stream.grant(100);
    stream.tx_handler(&paced.produce);
    assert(paced.calls == 1 && paced.remaining == 50 && stream.output.length == 100);
    stream.grant(64);
    assert(paced.calls == 2 && paced.remaining == 0 && stream.output.length == 150);
    stream.grant(64);
    assert(paced.calls == 3 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer bounded = TestTxProducer(100);
    stream.grant(63);
    stream.tx_handler(&bounded.produce);
    assert(bounded.calls == 0);
    stream.grant(1);
    assert(bounded.calls == 1 && stream.output.length == 64);
    stream.grant(64);
    assert(bounded.calls == 2 && bounded.remaining == 0 && stream.output.length == 100);

    stream.reset();
    TestTxProducer finishing = TestTxProducer(5);
    finishing.finish = true;
    stream.grant(100);
    stream.tx_handler(&finishing.produce);
    assert(finishing.calls == 1 && stream.output.length == 5 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer failing;
    failing.fail = true;
    stream.grant(100);
    stream.tx_handler(&failing.produce);
    assert(failing.calls == 1 && stream.output.length == 0 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer starving = TestTxProducer(4);
    starving.starve = true;
    stream.grant(100);
    stream.tx_handler(&starving.produce);
    assert(starving.calls == 1 && stream.output.length == 0 && stream.tx_handler !is null);
    page_pool_wake();
    assert(starving.calls == 3 && stream.output.length == 4 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer racing = TestTxProducer(4);
    racing.starve = true;
    racing.freed_meanwhile = true;
    stream.grant(100);
    stream.tx_handler(&racing.produce);
    assert(racing.calls == 3 && stream.output.length == 4 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer replacement = TestTxProducer(3);
    TestTxProducer replacing;
    replacing.stream = stream;
    replacing.replacement = &replacement.produce;
    stream.grant(64);
    stream.tx_handler(&replacing.produce);
    assert(replacing.calls == 1 && replacement.calls == 1 && stream.output.length == 3);
    stream.grant(64);
    assert(replacement.calls == 2 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer releasing = TestTxProducer(2);
    releasing.stream = stream;
    releasing.release = true;
    stream.grant(64);
    stream.tx_handler(&releasing.produce);
    assert(releasing.calls == 1 && stream.output.length == 2 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer sleeping;
    stream.grant(64);
    stream.tx_handler(&sleeping.produce);
    assert(sleeping.calls == 1 && stream.tx_handler is null);
    stream.grant(64);
    assert(sleeping.calls == 1);
    sleeping.remaining = 1;
    stream.tx_handler(&sleeping.produce);
    assert(sleeping.calls == 3 && stream.output.length == 1 && stream.tx_handler is null);

    stream.supported = false;
    assert(!stream.tx_handler(&first.produce));
    assert(stream.tx_handler is null);

    Page* chain = page_alloc(100);
    foreach (i, ref b; cast(ubyte[])chain.data)
        b = cast(ubyte)i;
    append_tx_chain(chain, page_alloc(10));
    TxRequest small = TxRequest(min_tx_request);
    TxStatus status;
    Page* front = take_tx_page(chain, small, status);
    assert(front.length == 64 && (cast(ubyte[])front.data)[63] == 63);
    assert(chain.length == 36 && (cast(ubyte[])chain.data)[0] == 64);
    page_free(front);
    front = take_tx_page(chain, small, status);
    assert(front.length == 36 && chain.length == 10);
    page_free(front);
    front = take_tx_page(chain, small, status);
    assert(front.length == 10 && chain is null);
    page_free(front);
}
