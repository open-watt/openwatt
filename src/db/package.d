module db;

// The database "world": a transport-agnostic client API in front of a storage
// engine that lives on the far side of a queue.
//
// The frontend treats this exactly like an inter-process / remote database -
// it pushes samples in and issues fetch requests, and never blocks on storage.
// Today the engine runs on a worker thread; the same channels work across a
// physical core, and the POD message types could travel over a wire to a real
// remote endpoint. On a target with no threads the engine is driven
// cooperatively from the main loop via pump(), and the API is unchanged.

import urt.array;
import urt.atomic;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.sync.event;
import urt.sync.spsc;
import urt.thread;
import urt.time;

import manager.plugin;

import db.defs;
import db.engine;

public import db.defs : SeriesId, Sample, invalid_series, QueryMode;

nothrow @nogc:


alias log = Log!"db";

alias QueryCallback = void delegate(uint ticket, scope const(Sample)[] samples) nothrow @nogc;

// Channel depths. Generously sized for desktop; tune down for tiny targets.
private enum uint ingest_capacity = 4096;
private enum uint query_capacity = 256;
private enum uint done_capacity = 256;
private enum uint notice_capacity = 64;


private bool spsc_send(T, uint N)(ref SPSCRing!(T, N) ring, ref T item)
{
    T* slot = ring.reserve();
    if (!slot)
        return false;
    *slot = item;
    ring.commit();
    return true;
}

DbModule database()
    => g_db;


class DbModule : Module
{
    mixin DeclareModule!"db";
nothrow @nogc:

    // --- client API (main thread) ---------------------------------------

    final SeriesId open_series(const(char)[] filename)
    {
        void[] mem = defaultAllocator().alloc(filename.length);
        if (!mem.ptr)
            return invalid_series;
        (cast(char[])mem)[] = filename[];

        SeriesId id = ++_next_series;
        IngestMsg m;
        m.kind = IngestKind.open_series;
        m.series = id;
        m.filename = cast(const(char)*)mem.ptr;
        m.filename_len = filename.length;
        if (!spsc_send(_ingest, m))
        {
            defaultAllocator().free(mem);
            --_next_series;
            return invalid_series;
        }
        return id;
    }

    final void close_series(SeriesId id)
    {
        if (id == invalid_series)
            return;
        IngestMsg m;
        m.kind = IngestKind.close_series;
        m.series = id;
        spsc_send(_ingest, m); // best effort; engine reaps everything at shutdown
    }

    final bool push(SeriesId id, ulong time, double value)
    {
        if (id == invalid_series)
            return false;
        IngestMsg m;
        m.kind = IngestKind.sample;
        m.series = id;
        m.time = time;
        m.value = value;
        return spsc_send(_ingest, m);
    }

    final bool push_block(SeriesId id, scope const(Sample)[] samples)
    {
        if (id == invalid_series || samples.length == 0)
            return false;
        void[] mem = defaultAllocator().alloc(samples.length * Sample.sizeof);
        if (!mem.ptr)
            return false;
        (cast(Sample[])mem)[] = samples[];

        IngestMsg m;
        m.kind = IngestKind.block;
        m.series = id;
        m.samples = cast(const(Sample)*)mem.ptr;
        m.count = samples.length;
        if (!spsc_send(_ingest, m))
        {
            defaultAllocator().free(mem);
            return false;
        }
        return true;
    }

    final uint query(SeriesId id, ulong from, ulong to, uint max_points, QueryMode mode, QueryCallback cb)
    {
        if (id == invalid_series || cb is null)
            return 0;
        uint ticket = ++_next_ticket;
        if (ticket == 0)
            ticket = ++_next_ticket; // 0 is reserved for "no ticket"
        QueryReq q = QueryReq(ticket, id, from, to, max_points, mode);
        if (!spsc_send(_requests, q))
            return 0;
        _pending.insert(ticket, cb);
        wake();
        return ticket;
    }

    final void cancel(uint ticket)
    {
        if (ticket != 0)
            _pending.remove(ticket);
    }

    final void pump()
    {
        if (!_threaded)
            drive();
        else
            wake();
    }

    // --- module lifecycle -----------------------------------------------

    override void init()
    {
        g_db = this;
        _engine.on_notice = &enqueue_notice;

        static if (ThreadsSupported)
        {
            if (_wake.init())
            {
                atomicStore!(MemoryOrder.release)(_stop, false);
                _thread = thread_spawn(&worker_main);
                _threaded = _thread !is null;
                if (!_threaded)
                    _wake.destroy();
            }
        }
    }

    override void deinit()
    {
        static if (ThreadsSupported)
        {
            if (_threaded)
            {
                atomicStore!(MemoryOrder.release)(_stop, true);
                _wake.set();
                thread_join(_thread);
                _thread = null;
                _wake.destroy();
                _threaded = false;
            }
            else
                _engine.flush();
        }
        else
            _engine.flush();

        _engine.shutdown();
        _pending.clear(); // consumers are gone: drop callbacks, just reclaim buffers
        drain_done();
        drain_notices();
        g_db = null;
    }

    override void update()
    {
        if (_threaded)
            wake_if_work();
        else
            drive();
        drain_done();
        drain_notices();
    }

private:
    DbEngine _engine;

    SPSCRing!(IngestMsg, ingest_capacity) _ingest;   // frontend -> worker
    SPSCRing!(QueryReq, query_capacity) _requests;   // frontend -> worker
    SPSCRing!(QueryDone, done_capacity) _done;       // worker -> frontend
    SPSCRing!(DbNotice, notice_capacity) _notices;   // worker -> frontend

    Map!(uint, QueryCallback) _pending; // ticket -> callback, awaiting completion
    SeriesId _next_series;
    uint _next_ticket;

    bool _threaded;
    static if (ThreadsSupported)
    {
        Thread _thread;
        Event _wake;
        shared bool _stop;
    }

    void wake()
    {
        static if (ThreadsSupported)
            if (_threaded)
                _wake.set();
    }

    void wake_if_work()
    {
        static if (ThreadsSupported)
            if (!_ingest.empty || !_requests.empty)
                _wake.set();
    }

    static if (ThreadsSupported)
    void worker_main()
    {
        for (;;)
        {
            _wake.reset();
            bool did = drive();
            if (atomicLoad!(MemoryOrder.acquire)(_stop))
                break;
            if (!did)
                _wake.wait(100.msecs);
        }
        drive(); // final drain after stop
    }

    // Consume pending ingest + requests. Runs on the worker thread (or the main
    // thread cooperatively). Returns true if it did any work.
    bool drive()
    {
        bool did = false;

        IngestMsg[64] ibuf = void;
        for (;;)
        {
            size_t n = _ingest.pop(ibuf[]);
            if (!n)
                break;
            did = true;
            foreach (ref m; ibuf[0 .. n])
                apply_ingest(m);
        }
        _engine.flush();

        QueryReq[16] qbuf = void;
        for (;;)
        {
            size_t n = _requests.pop(qbuf[]);
            if (!n)
                break;
            did = true;
            foreach (ref q; qbuf[0 .. n])
                service_query(q);
        }
        return did;
    }

    void apply_ingest(ref const IngestMsg m)
    {
        final switch (m.kind)
        {
            case IngestKind.sample:
                _engine.ingest(m.series, m.time, m.value);
                break;
            case IngestKind.block:
                _engine.ingest_block(m.series, m.samples[0 .. m.count]);
                defaultAllocator().free(cast(void[])m.samples[0 .. m.count]);
                break;
            case IngestKind.open_series:
                _engine.open_series(m.series, m.filename[0 .. m.filename_len]);
                defaultAllocator().free(cast(void[])m.filename[0 .. m.filename_len]);
                break;
            case IngestKind.close_series:
                _engine.close_series(m.series);
                break;
        }
    }

    void service_query(ref const QueryReq q)
    {
        Array!Sample result;
        _engine.query(q, result);

        QueryDone done;
        done.ticket = q.ticket;
        done.count = cast(uint)result.length;
        if (done.count)
        {
            void[] mem = defaultAllocator().alloc(done.count * Sample.sizeof);
            if (!mem.ptr)
                done.count = 0; // OOM: return an empty result rather than hang
            else
            {
                Sample* buf = cast(Sample*)mem.ptr;
                buf[0 .. done.count] = result[];
                done.data = buf;
            }
        }
        if (!spsc_send(_done, done) && done.data)
            defaultAllocator().free(cast(void[])done.data[0 .. done.count]);
    }

    // worker side (producer of _notices)
    void enqueue_notice(const(char)[] text)
    {
        if (!text.length)
            return;
        void[] mem = defaultAllocator().alloc(text.length);
        if (!mem.ptr)
            return;
        (cast(char[])mem)[] = text[];
        DbNotice n = DbNotice(cast(const(char)*)mem.ptr, cast(uint)text.length);
        if (!spsc_send(_notices, n))
            defaultAllocator().free(mem);
    }

    // main side (consumer of _done / _notices)
    void drain_done()
    {
        QueryDone[32] buf = void;
        for (;;)
        {
            size_t n = _done.pop(buf[]);
            if (!n)
                break;
            foreach (ref d; buf[0 .. n])
            {
                if (QueryCallback* cb = d.ticket in _pending)
                {
                    (*cb)(d.ticket, d.count ? d.data[0 .. d.count] : null);
                    _pending.remove(d.ticket);
                }
                if (d.count)
                    defaultAllocator().free(cast(void[])d.data[0 .. d.count]);
            }
        }
    }

    void drain_notices()
    {
        DbNotice[16] buf = void;
        for (;;)
        {
            size_t n = _notices.pop(buf[]);
            if (!n)
                break;
            foreach (ref nt; buf[0 .. n])
            {
                log.warning(nt.text[0 .. nt.len]);
                defaultAllocator().free(cast(void[])nt.text[0 .. nt.len]);
            }
        }
    }
}


unittest
{
    // full client round-trip across the worker: open -> push -> async query ->
    // result via callback -> clean shutdown (spawns and joins the worker thread).
    import urt.file : get_temp_filename, delete_file;

    static struct Sink
    {
    nothrow @nogc:
        Array!Sample r;
        bool got;
        void on_result(uint, scope const(Sample)[] samples)
        {
            r.clear();
            if (samples.length)
            {
                r.resize(samples.length);
                r[][] = samples[];
            }
            got = true;
        }
    }

    char[320] b = void;
    char[] fn = b[];
    assert(get_temp_filename(fn, "", "owrdb"));

    DbModule db = defaultAllocator().allocT!DbModule(null);
    db.init();

    SeriesId s = db.open_series(fn);
    assert(s != invalid_series);
    foreach (i; 0 .. 50)
        db.push(s, (i + 1) * 1_000_000UL, i * 2.0);

    Sink sink;
    uint tk = db.query(s, 0, 100_000_000UL, 0, QueryMode.raw, &sink.on_result);
    assert(tk != 0);

    foreach (i; 0 .. 2_000_000)
    {
        db.update(); // drains completions and fires the callback
        if (sink.got)
            break;
    }
    assert(sink.got);
    assert(sink.r.length == 50);
    assert(sink.r[0].value == 0 && sink.r[49].value == 98);

    db.deinit();
    defaultAllocator().freeT(db);
    delete_file(fn);
}


private:

__gshared DbModule g_db;
