module router.stream;

import urt.array;
import urt.conv;
import urt.file;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.alloc : default_alignment;
import urt.mem.pagepool;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.string.format;
import urt.time;

import manager : g_app;
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
enum size_t min_tx_request = 128;

// A pump's turn; a sink with room left after it takes its next turn behind the other bulk work.
enum Duration tx_slice = msecs(5);

// bytes bound the whole page, framing included; headroom and tailroom are what the filters above the producer
// write around its payload, in place
struct TxRequest
{
    size_t bytes;
    MonoTime deadline;  // the producer returns at its next yield point once this has passed
    size_t headroom;
    size_t tailroom;
}

enum TxStatus : ubyte
{
    more,       // further pages follow; a null page with more is a contract violation
    yield,      // the deadline passed; the pull returns what it has, and the next turn pulls again
    idle,       // nothing more for now; the producer re-arms with tx_handler()
    starved,    // page_alloc failed; the sink waits for a free page and pulls again
    end,        // complete; a page returned with it is the last
    abort,      // failed; the producer's owner terminates the stream
}

// A returned page transfers to the sink. A producer never exceeds req.bytes, and leaves req.headroom and req.tailroom
// free around the payload.
alias SendHandler = Page* delegate(ref const TxRequest req, out TxStatus status) nothrow @nogc;

Page* alloc_tx_page(ref const TxRequest req, size_t bytes, ref TxStatus status)
{
    debug assert(bytes <= req.bytes);
    Page* page = page_alloc(bytes, default_alignment, req.headroom, req.tailroom);
    if (!page)
        status = TxStatus.starved;
    return page;
}

// hands out at most req.bytes from the front of chain; a head that is longer, or lacks the room, is copied out
Page* take_tx_page(ref Page* chain, ref const TxRequest req, ref TxStatus status)
{
    Page* head = chain;
    bool whole = head.length <= req.bytes;
    if (whole && head.headroom >= req.headroom && head.tailroom >= req.tailroom)
    {
        chain = head.next;
        head.next = null;
        return head;
    }
    size_t n = whole ? head.length : req.bytes;
    Page* page = alloc_tx_page(req, n, status);
    if (!page)
        return null;
    page.data[] = head.data[0 .. n];
    if (whole)
    {
        chain = head.next;
        page_free(head);
    }
    else
    {
        head.offset += cast(ushort)n;
        head.length -= cast(ushort)n;
    }
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
        debug assert(status != TxStatus.yield || getTime() >= req.deadline, "producer yielded before its deadline");
        if (slot is handler)
        {
            if (status != TxStatus.more && status != TxStatus.yield && status != TxStatus.starved)
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
        arm_rx_poll();
    }

    final override void offline()
    {
        page_unwait(&_tx_waiter);
        release_tx_queue();
        cancel_tx_continuation();
        if (_rx_polling)
        {
            _rx_polling = false;
            g_app.cancel(&rx_poll_due);
        }
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
        mark_set!(typeof(this), [ "link-status", "last-status-change-time", "link-downs", "tx-rate", "rx-rate" ])();
    }

    // bytes that arrive with no handler installed are not kept
    final void rx_handler(RecvHandler handler)
    {
        _incoming = handler;
        rx_handler_changed();
        arm_rx_poll();
    }
    final RecvHandler rx_handler() const pure
        => _incoming;

    final void release_rx_handler(RecvHandler handler)
    {
        if (_incoming !is handler)
            return;
        _incoming = null;
        rx_handler_changed();
        arm_rx_poll();
    }

    final void tx_handler(SendHandler handler)
    {
        _outgoing = handler;
        tx_handler_changed();
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

    abstract ptrdiff_t write(const(void[])[] data...);

    // a stream that takes pages itself overrides this with queue_tx_page; the rest queue them here for transmit()
    size_t tx_request() const
    {
        size_t queued = tx_queued();
        return running && queued < tx_queue_limit ? tx_queue_limit - queued : 0;
    }

    // what the base queue holds for the line
    final size_t tx_queued() const
    {
        size_t bytes;
        for (const(Page)* page = _tx_queue; page; page = (cast(Page*)page).next)
            bytes += page.length;
        return bytes;
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

    // a source with no receive event is read through poll_rx, at this interval, while a handler takes its bytes
    Duration rx_poll_interval() const
        => Duration.zero;

    void poll_rx(MonoTime now)
    {
    }

    void rx_handler_changed()
    {
    }

    void tx_handler_changed()
    {
        invite_tx();
    }

    // a pull already running, or a continuation queued, takes the room itself
    final void invite_tx()
    {
        if (_outgoing && !_pumping_tx && !_tx_continuing)
            pump_tx();
    }

    final Page* request_tx_page(ref const TxRequest req, out TxStatus status)
        => pull_tx_page(_outgoing, req, status);

    final void pump_tx()
    {
        _pumping_tx = true;
        scope (exit) _pumping_tx = false;

        MonoTime deadline = getTime() + tx_slice;
        while (_outgoing)
        {
            TxRequest req = TxRequest(tx_request(), deadline);
            if (req.bytes < min_tx_request)
                break;
            uint generation = page_free_generation();
            TxStatus status;
            Page* page = request_tx_page(req, status);
            if (page && page.length == 0)
            {
                debug assert(false, "producer returned an empty page");
                page_free(page);
                _outgoing = null;
                break;
            }
            if (page)
                queue_tx_page(page);
            if (status == TxStatus.starved)
            {
                _tx_waiter.wake = &pump_tx;
                if (page_wait(&_tx_waiter, generation))
                    break;
            }
            if (status == TxStatus.yield || getTime() >= deadline)
            {
                if (_outgoing && tx_request() >= min_tx_request)
                    continue_tx();
                break;
            }
        }
    }

    enum size_t tx_queue_limit = 2048;
    enum size_t tx_page_payload = 1600;

    void queue_tx_page(Page* page)
    {
        if (!running)
        {
            while (page)
            {
                Page* next = page.next;
                page_free(page);
                page = next;
            }
            return;
        }
        append_tx_chain(_tx_queue, page);
        drain_tx();
    }

    // what the line takes of data now; a failed line returns -1
    ptrdiff_t transmit(const(void)[] data)
        => write(data);

    // a line that raises nothing when it has room again is retried at this interval while it holds a backlog
    Duration tx_retry_interval() const
        => msecs(2);

    // a filter stream serves what was written to it through its own pull, rather than pushing it to a line
    final Page* take_queued_tx(ref const TxRequest req, out TxStatus status)
    {
        if (!_tx_queue)
        {
            status = TxStatus.idle;
            return null;
        }
        return take_tx_page(_tx_queue, req, status);
    }

    // copies data behind what is queued, up to a page past the queue's limit, so one write of a frame fits whole; short
    // writes fill the last page before another is taken
    final size_t queue_copy(const(void[])[] data...)
    {
        size_t total = hold_copy(data);
        drain_tx();
        return total;
    }

    // copies as queue_copy does, but leaves the queue for a filter's own pull; nothing is pumped or drained
    final size_t hold_copy(const(void[])[] data...)
    {
        if (!running)
            return 0;
        size_t queued = tx_queued();
        size_t room = queued < tx_queue_limit + tx_page_payload ? tx_queue_limit + tx_page_payload - queued : 0;
        size_t total;
        Page* tail = _tx_queue;
        while (tail && tail.next)
            tail = tail.next;
        copy: foreach (d; data)
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])d;
            while (bytes.length && total < room)
            {
                if (!tail || !tail.tailroom || !page_unique(tail))
                {
                    size_t want = bytes.length < tx_page_payload ? bytes.length : tx_page_payload;
                    Page* page = page_alloc(want < room - total ? want : room - total);
                    if (!page)
                        break copy;
                    page.length = 0;
                    append_tx_chain(_tx_queue, page);
                    tail = page;
                }
                size_t n = bytes.length < tail.tailroom ? bytes.length : tail.tailroom;
                if (n > room - total)
                    n = room - total;
                (cast(ubyte*)tail)[tail.offset + tail.length .. tail.offset + tail.length + n] = bytes[0 .. n];
                tail.length += cast(ushort)n;
                bytes = bytes[n .. $];
                total += n;
            }
        }
        return total;
    }

    // the line has room again
    final void drain_tx()
    {
        while (_tx_queue)
        {
            size_t length = _tx_queue.length;
            ptrdiff_t n = transmit(_tx_queue.data);
            if (n < 0)
                return restart();
            if (n == 0)
                break;
            consume_tx(n);
            if (n < length)
                break;
        }
        if (_tx_queue && tx_retry_interval != Duration.zero && !_tx_retrying)
        {
            _tx_retrying = true;
            g_app.schedule(getTime() + tx_retry_interval, &tx_retry);
        }
        invite_tx();
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

    RecvHandler _incoming;
    Array!TapHandler _taps;

    final void incoming(const(void)[] data, MonoTime rx_time)
    {
        if (data.length == 0)
            return;
        add_rx_bytes(data.length);
        write_to_log(true, data);
        if (_incoming)
            _incoming(this, data, rx_time);
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
    Page* _tx_queue;    // for the line, oldest first; the head's offset advances as the line takes it
    bool _pumping_tx;
    bool _tx_retrying;
    bool _tx_continuing;
    bool _rx_polling;

    void consume_tx(size_t n)
    {
        Page* head = _tx_queue;
        head.offset += cast(ushort)n;
        head.length -= cast(ushort)n;
        if (head.length)
            return;
        _tx_queue = head.next;
        page_free(head);
    }

    void tx_retry(MonoTime)
    {
        _tx_retrying = false;
        if (running)
            drain_tx();
    }

    final void release_tx_queue()
    {
        if (_tx_retrying)
        {
            g_app.cancel(&tx_retry);
            _tx_retrying = false;
        }
        while (_tx_queue)
        {
            Page* next = _tx_queue.next;
            page_free(_tx_queue);
            _tx_queue = next;
        }
    }

    // one continuation per sink, on the next loop pass, after that pass's I/O and events, so busy sinks share the thread
    final void continue_tx()
    {
        if (_tx_continuing)
            return;
        _tx_continuing = true;
        g_app.schedule(getTime(), &tx_continue);
    }

    void tx_continue(MonoTime)
    {
        _tx_continuing = false;
        invite_tx();
    }

    final void cancel_tx_continuation()
    {
        if (!_tx_continuing)
            return;
        _tx_continuing = false;
        g_app.cancel(&tx_continue);
    }

    final void arm_rx_poll()
    {
        bool want = _incoming && running && rx_poll_interval != Duration.zero;
        if (want == _rx_polling)
            return;
        _rx_polling = want;
        if (want)
            g_app.schedule(getTime() + rx_poll_interval, &rx_poll_due);
        else
            g_app.cancel(&rx_poll_due);
    }

    void rx_poll_due(MonoTime)
    {
        _rx_polling = false;
        if (!_incoming || !running)
            return;
        poll_rx(getTime());
        arm_rx_poll();
    }
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

        void live(bool on)
        {
            _state = on ? State.running : State.disabled;
        }

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

    protected:
        override void queue_tx_page(Page* page)
        {
            output ~= cast(const(ubyte)[])page.data;
            _space = page.length < _space ? _space - page.length : 0;
            page_free(page);
        }

    private:
        size_t _space;
    }

    // takes what its room allows per write, as a line with a small buffer does
    class ShortStream : Stream
    {
    nothrow @nogc:

        ~this() {}

        enum type_name = "test-short-stream";

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!ShortStream, id, flags);
            _state = State.running;
        }

        override ptrdiff_t write(const(void[])[] data...)
        {
            if (broken)
                return -1;
            size_t total;
            foreach (d; data)
            {
                size_t n = d.length < room ? d.length : room;
                output ~= (cast(const(ubyte)[])d)[0 .. n];
                room -= n;
                total += n;
                if (n < d.length)
                    break;
            }
            return total;
        }

        void open(size_t bytes)
        {
            room = bytes;
            drain_tx();
        }

        void halt()
        {
            _state = State.disabled;
        }

        Array!ubyte output;
        size_t room;
        bool broken;

    protected:
        override Duration tx_retry_interval() const
            => Duration.zero;
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
            if (out_of_time && getTime() >= req.deadline)
            {
                out_of_time = false;
                status = TxStatus.yield;
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
        bool out_of_time;
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
    TestTxProducer paced = TestTxProducer(min_tx_request + min_tx_request / 2);
    stream.grant(min_tx_request);
    stream.tx_handler(&paced.produce);
    assert(paced.calls == 1 && paced.remaining == min_tx_request / 2 && stream.output.length == min_tx_request);
    stream.grant(min_tx_request);
    assert(paced.calls == 2 && paced.remaining == 0 && stream.output.length == min_tx_request + min_tx_request / 2);
    stream.grant(min_tx_request);
    assert(paced.calls == 3 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer bounded = TestTxProducer(min_tx_request + 36);
    stream.grant(min_tx_request - 1);
    stream.tx_handler(&bounded.produce);
    assert(bounded.calls == 0);
    stream.grant(1);
    assert(bounded.calls == 1 && stream.output.length == min_tx_request);
    stream.grant(min_tx_request);
    assert(bounded.calls == 2 && bounded.remaining == 0 && stream.output.length == min_tx_request + 36);

    stream.reset();
    TestTxProducer finishing = TestTxProducer(5);
    finishing.finish = true;
    stream.grant(min_tx_request);
    stream.tx_handler(&finishing.produce);
    assert(finishing.calls == 1 && stream.output.length == 5 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer failing;
    failing.fail = true;
    stream.grant(min_tx_request);
    stream.tx_handler(&failing.produce);
    assert(failing.calls == 1 && stream.output.length == 0 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer starving = TestTxProducer(4);
    starving.starve = true;
    stream.grant(2 * min_tx_request);
    stream.tx_handler(&starving.produce);
    assert(starving.calls == 1 && stream.output.length == 0 && stream.tx_handler !is null);
    page_pool_wake();
    assert(starving.calls == 3 && stream.output.length == 4 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer racing = TestTxProducer(4);
    racing.starve = true;
    racing.freed_meanwhile = true;
    stream.grant(2 * min_tx_request);
    stream.tx_handler(&racing.produce);
    assert(racing.calls == 3 && stream.output.length == 4 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer replacement = TestTxProducer(3);
    TestTxProducer replacing;
    replacing.stream = stream;
    replacing.replacement = &replacement.produce;
    stream.grant(min_tx_request);
    stream.tx_handler(&replacing.produce);
    assert(replacing.calls == 1 && replacement.calls == 1 && stream.output.length == 3);
    stream.grant(min_tx_request);
    assert(replacement.calls == 2 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer releasing = TestTxProducer(2);
    releasing.stream = stream;
    releasing.release = true;
    stream.grant(min_tx_request);
    stream.tx_handler(&releasing.produce);
    assert(releasing.calls == 1 && stream.output.length == 2 && stream.tx_handler is null);

    stream.reset();
    TestTxProducer sleeping;
    stream.grant(min_tx_request);
    stream.tx_handler(&sleeping.produce);
    assert(sleeping.calls == 1 && stream.tx_handler is null);
    stream.grant(min_tx_request);
    assert(sleeping.calls == 1);
    sleeping.remaining = 1;
    stream.tx_handler(&sleeping.produce);
    assert(sleeping.calls == 3 && stream.output.length == 1 && stream.tx_handler is null);

    // bytes held for a filter's own pull start no pump: the producer waits for the line, however much room it has
    stream.reset();
    TestTxProducer held = TestTxProducer(1000);
    stream.tx_handler(&held.produce);
    stream._space = 8192;
    stream.live(true);
    ubyte[1] one = [1];
    assert(stream.hold_copy(one[]) == 1 && held.calls == 0 && stream.tx_queued == 1);
    stream.release_tx_handler(&held.produce);
    stream.release_tx_queue();
    stream.live(false);

    // a short-writing line keeps what it did not take and stays armed; the bytes arrive whole and in order
    {
        ShortStream line = alloc!ShortStream(CID(2));
        scope(exit)
        {
            line.halt();
            free(line);
        }
        TestTxProducer slow = TestTxProducer(5000);
        slow.stream = line;
        line.tx_handler(&slow.produce);
        assert(line.output.length == 0 && line.tx_request == 0 && line.tx_handler !is null, "a line that takes nothing holds the queue's worth");
        foreach (step; [1000, 1, 700, 3000])
            line.open(step);
        line.open(10_000);
        assert(line.output.length == 5000 && line.tx_handler is null);
        foreach (i, b; line.output[])
            assert(b == cast(ubyte)i);
    }

    // a copy stops a page past the queue's limit, and a line that fails drops its queue
    {
        ShortStream line = alloc!ShortStream(CID(3));
        scope(exit)
        {
            line.halt();
            free(line);
        }
        ubyte[5000] bytes;
        foreach (i, ref b; bytes)
            b = cast(ubyte)i;
        size_t taken = line.queue_copy(bytes[]);
        assert(taken == Stream.tx_queue_limit + Stream.tx_page_payload, "a copy is bounded");
        assert(line.queue_copy(bytes[]) == 0, "a full queue takes nothing");
        line.open(10_000);
        assert(line.output.length == taken && line.output[] == bytes[0 .. taken]);

        line.room = 0;
        line.queue_copy(bytes[0 .. 100]);
        assert(line.tx_queued() == 100);
        line.broken = true;
        line.open(10);
        assert(!line.running && line.tx_queued() == 0, "a failed line restarts and drops what it held");
    }

    // a producer past its deadline yields and stays armed, and makes progress on the next turn
    {
        TestTxProducer yielding;
        yielding.out_of_time = true;
        yielding.remaining = 10;
        SendHandler slot = &yielding.produce;
        TxRequest req = TxRequest(100, getTime());
        TxStatus status;
        assert(pull_tx_page(slot, req, status) is null && status == TxStatus.yield && slot !is null);
        req.deadline = getTime() + tx_slice;
        Page* page = pull_tx_page(slot, req, status);
        assert(page && page.length == 10 && status == TxStatus.more && slot !is null);
        page_free(page);
    }

    Page* chain = page_alloc(100);
    foreach (i, ref b; cast(ubyte[])chain.data)
        b = cast(ubyte)i;
    append_tx_chain(chain, page_alloc(10));
    TxRequest small = TxRequest(64);
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

    // a page that keeps the room a filter asked for passes through as it stands; one that lacks it is copied out
    {
        TxRequest framed = TxRequest(min_tx_request, MonoTime(), 8, 16);
        Page* roomy = page_alloc(20, default_alignment, 8, 16);
        chain = roomy;
        front = take_tx_page(chain, framed, status);
        assert(front is roomy && chain is null);
        page_free(front);

        Page* bare = page_alloc(20);
        (cast(ubyte[])bare.data)[] = 7;
        chain = bare;
        front = take_tx_page(chain, framed, status);
        assert(front !is bare && chain is null && front.length == 20 && front.headroom >= 8 && front.tailroom >= 16);
        foreach (b; cast(const(ubyte)[])front.data)
            assert(b == 7);
        page_free(front);
    }
}
