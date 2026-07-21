module db.engine;

// The storage engine: per-series append-only files plus range queries.
//
// This runs ONLY on the database worker (its own thread today, possibly its own
// core later); it never touches the frontend data model. Open file handles are
// pooled in LRU order and capped: one descriptor per series would exhaust the
// process fd table once there are ~1000 series. Reopening a cold series on its
// next write is cheap here since this isn't the main loop.
//
// The on-disk format is the stop-gap inherited from the recorder: one file per
// series, a 16-byte header followed by packed (timestamp, value) records, with
// strictly-increasing timestamps so ranges are found by binary search. A future
// store will re-encode this into tighter time blocks behind the same engine API.

import urt.array;
import urt.file;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.util : min;
import urt.atomic;

import db.defs;

nothrow @nogc:


// Native-endian (all supported targets are little-endian).
struct RecordFileHeader
{
    char[4] magic = "OWRS";
    uint version_ = 1;
    ulong reserved;
}


// Streaming time-bucket aggregator: emits one mean-value sample per bucket,
// stamped with the bucket's last real timestamp. bucket_width == 0 passes
// samples through unmodified.
struct SampleAggregator
{
nothrow @nogc:

    Array!Sample* sink;
    ulong from;
    ulong bucket_width;

    void put(ref const Sample s)
    {
        if (!bucket_width)
        {
            *sink ~= s;
            return;
        }
        ulong b = (s.time - from) / bucket_width;
        if (b != _bucket)
        {
            emit();
            _bucket = b;
        }
        _sum += s.value;
        _last_time = s.time;
        ++_n;
    }

    void finish()
    {
        emit();
    }

private:
    ulong _bucket = ulong.max;
    double _sum = 0;
    ulong _last_time;
    uint _n;

    void emit()
    {
        if (!_n)
            return;
        *sink ~= Sample(_last_time, _sum / _n);
        _sum = 0;
        _n = 0;
    }
}


// Sample-and-hold interval downsampler for graphs. Each emitted point is the
// time-weighted mean value over one visible time bucket, which avoids the
// aliasing/jitter caused by picking or averaging only change events.
struct GraphIntervalSampler
{
nothrow @nogc:

    Array!Sample* sink;
    ulong from;
    ulong to;
    ulong bucket_width;

    void seed(ref const Sample s)
    {
        _last_time = from;
        _last_value = s.value;
        _has_value = true;
        _seeded = true;
    }

    void put(ref const Sample s)
    {
        if (!bucket_width)
        {
            *sink ~= s;
            return;
        }

        ulong t = s.time;
        if (t < from)
            return;
        if (t > to)
            t = to;

        if (_has_value)
            accumulate(_last_time, t, _last_value);

        _last_time = t;
        _last_value = s.value;
        _has_value = true;
    }

    void finish()
    {
        if (!bucket_width)
            return;
        if (_has_value)
            accumulate(_last_time, to, _last_value);
        emit();
    }

private:
    ulong _bucket = ulong.max;
    ulong _bucket_time;
    double _sum;
    ulong _duration;
    ulong _last_time;
    double _last_value;
    bool _has_value;
    bool _seeded;
    bool _emitted;

    void accumulate(ulong start, ulong end, double value)
    {
        if (end <= start)
            return;
        if (start < from)
            start = from;
        if (end > to)
            end = to;

        while (start < end)
        {
            ulong b = (start - from) / bucket_width;
            if (b != _bucket)
            {
                emit();
                _bucket = b;
                ulong bucket_start = from + b * bucket_width;
                _bucket_time = (_seeded || _emitted || start <= bucket_start)
                    ? bucket_start : start;
            }

            ulong bucket_end = from + (b + 1) * bucket_width;
            ulong stop = end < bucket_end ? end : bucket_end;
            ulong dt = stop - start;
            _sum += value * cast(double)dt;
            _duration += dt;
            start = stop;
        }
    }

    void emit()
    {
        if (!_duration)
            return;
        *sink ~= Sample(_bucket_time, _sum / cast(double)_duration);
        _sum = 0;
        _duration = 0;
        _emitted = true;
    }
}


unittest
{
    // bucketed downsample: mean value, stamped with the bucket's last time
    Array!Sample result;
    SampleAggregator agg;
    agg.sink = &result;
    agg.from = 0;
    agg.bucket_width = 10;
    agg.put(Sample(1, 1));
    agg.put(Sample(5, 3));
    agg.put(Sample(12, 10));
    agg.finish();
    assert(result.length == 2);
    assert(result[0].time == 5 && result[0].value == 2);
    assert(result[1].time == 12 && result[1].value == 10);

    // sample-and-hold: time-weighted mean per bucket, seeded at the left edge
    result.clear();
    GraphIntervalSampler graph_agg;
    graph_agg.sink = &result;
    graph_agg.from = 0;
    graph_agg.to = 100;
    graph_agg.bucket_width = 25;
    Sample seed = Sample(0, 10);
    graph_agg.seed(seed);
    graph_agg.put(Sample(40, 20));
    graph_agg.put(Sample(90, 30));
    graph_agg.finish();
    assert(result.length == 4);
    assert(result[0].time == 0);
    assert(result[1].time == 25);
    assert(result[2].time == 50);
    assert(result[3].time == 75);
}


unittest
{
    // full storage round-trip: open -> ingest -> flush -> query, against a real file
    import urt.file : get_temp_filename, delete_file;

    char[320] buf = void;
    char[] fn = buf[];
    assert(get_temp_filename(fn, "", "owrtest"));

    DbEngine eng;
    enum SeriesId s = 1;
    eng.open_series(s, fn);
    foreach (i; 0 .. 100)
        eng.ingest(s, (i + 1) * 1_000_000UL, i * 1.0);
    eng.flush();

    // monotonic guard: an old timestamp is ignored
    eng.ingest(s, 500_000UL, 999.0);
    eng.flush();

    Array!Sample all;
    QueryReq q = QueryReq(1, s, 0, 200_000_000UL, 0);
    eng.query(q, all);
    assert(all.length == 100);
    assert(all[0].value == 0 && all[99].value == 99);

    // inclusive sub-range
    Array!Sample sub;
    QueryReq q2 = QueryReq(2, s, 10_000_000UL, 20_000_000UL, 0);
    eng.query(q2, sub);
    assert(sub.length == 11);
    assert(sub[0].value == 9 && sub[10].value == 19);

    eng.shutdown();

    // data survives a fresh engine (resume by binary search over the file)
    DbEngine eng2;
    eng2.open_series(s, fn);
    Array!Sample again;
    eng2.query(q, again);
    assert(again.length == 100);
    eng2.shutdown();

    delete_file(fn);
}


unittest
{
    // graph-mode query seeds the left edge with the value held before `from`
    import urt.file : get_temp_filename, delete_file;

    char[320] buf = void;
    char[] fn = buf[];
    assert(get_temp_filename(fn, "", "owrgraph"));

    DbEngine eng;
    enum SeriesId s = 1;
    eng.open_series(s, fn);
    eng.ingest(s, 10, 10.0); // a step: 10 before t=50, then 20
    eng.ingest(s, 50, 20.0);
    eng.flush();

    // querying [20, 60] has no sample at the left edge, so the held value (10)
    // in effect at t=20 is seeded as the first point
    Array!Sample seeded;
    QueryReq g = QueryReq(1, s, 20, 60, 0, QueryMode.graph);
    eng.query(g, seeded);
    assert(seeded.length == 2);
    assert(seeded[0].time == 20 && seeded[0].value == 10);
    assert(seeded[1].time == 50 && seeded[1].value == 20);

    eng.shutdown();
    delete_file(fn);
}


unittest
{
    // LRU fd pool: more series than the open cap must still round-trip, and the
    // engine must never hold more than `max_open` files open at once.
    import urt.file : get_temp_filename, delete_file;

    enum n = 5;
    char[320][n] bufs = void;
    char[][n] fns;
    foreach (i; 0 .. n)
    {
        fns[i] = bufs[i][];
        assert(get_temp_filename(fns[i], "", "owrlru"));
    }

    DbEngine eng;
    eng.max_open = 2;
    foreach (i; 0 .. n)
    {
        eng.open_series(cast(SeriesId)(i + 1), fns[i]);
        eng.ingest(cast(SeriesId)(i + 1), 1_000_000UL, i * 10.0);
    }
    eng.flush();
    assert(eng._open_count <= eng.max_open);

    foreach (i; 0 .. n)
    {
        Array!Sample got;
        QueryReq q = QueryReq(1, cast(SeriesId)(i + 1), 0, 2_000_000UL, 0);
        eng.query(q, got);
        assert(got.length == 1 && got[0].value == i * 10.0);
    }
    assert(eng._open_count <= eng.max_open);

    eng.shutdown();
    foreach (i; 0 .. n)
        delete_file(fns[i]);
}


struct DbSeries
{
nothrow @nogc:
    this(this) @disable;

    String filename;
    File file;
    bool file_open;
    bool file_failed;  // file is unusable; ingest/query give up on it
    ulong last_time;   // most recent recorded timestamp (unix ns)
    Array!Sample pending; // accumulated this drain, not yet written
    DbSeries* lru_prev;   // open-file LRU; linked only while file_open
    DbSeries* lru_next;
}


struct DbEngine
{
nothrow @nogc:

    // The engine reports problems by handing text back to the frontend, which
    // logs it on the main thread. Worker code must not touch the log sinks.
    void delegate(const(char)[]) nothrow @nogc on_notice;

    // Cap on simultaneously-open record files.
    size_t max_open = 2048;

    // LRU evictions so far (32-bit, wraps; per-second deltas stay valid).
    // A sustained nonzero rate means the actively-written series set exceeds the cap.
    shared uint evictions;

    void open_series(SeriesId id, const(char)[] filename)
    {
        if (id in _series)
            return;
        DbSeries* s = defaultAllocator().allocT!DbSeries();
        s.filename = filename.makeString(defaultAllocator());
        seed_last_time(s);
        _series.insert(id, s);
    }

    void close_series(SeriesId id)
    {
        if (DbSeries** ps = id in _series)
        {
            DbSeries* s = *ps;
            flush_series(s);
            close_file(s);
            s.pending.clear();
            s.filename = null;
            defaultAllocator().freeT(s);
            _series.remove(id);
        }
    }

    void ingest(SeriesId id, ulong time, double value)
    {
        DbSeries** ps = id in _series;
        if (!ps)
            return;
        DbSeries* s = *ps;
        if (s.file_failed || time <= s.last_time)
            return;
        s.pending ~= Sample(time, value);
        s.last_time = time;
    }

    // Ingest a run of in-order samples. The monotonic guard is a safety net --
    // the producer is expected to send only already-ordered, settled blocks.
    void ingest_block(SeriesId id, scope const(Sample)[] samples)
    {
        DbSeries** ps = id in _series;
        if (!ps)
            return;
        DbSeries* s = *ps;
        if (s.file_failed)
            return;
        foreach (ref sm; samples)
        {
            if (sm.time <= s.last_time)
                continue;
            s.pending ~= sm;
            s.last_time = sm.time;
        }
    }

    // Write everything accumulated since the last flush.
    void flush()
    {
        foreach (s; _series.values)
            flush_series(s);
    }

    void query(ref const QueryReq req, ref Array!Sample result)
    {
        if (req.to <= req.from)
            return;
        DbSeries** ps = req.series in _series;
        if (!ps)
            return;
        DbSeries* s = *ps;
        flush_series(s); // the file must hold everything before we read it
        if (s.file_failed)
            return;

        File tmp;
        File* f = &s.file;
        if (!s.file_open)
        {
            if (!tmp.open(s.filename[], FileOpenMode.ReadExisting, FileOpenFlags.Sequential))
                return; // nothing on disk yet
            f = &tmp;
        }
        scope(exit) if (f is &tmp)
            tmp.close();

        ulong bucket_width = req.max_points ? (req.to - req.from) / req.max_points + 1 : 0;

        final switch (req.mode)
        {
            case QueryMode.raw:
                SampleAggregator agg;
                agg.sink = &result;
                agg.from = req.from;
                agg.bucket_width = bucket_width;
                read_range(*f, req.from, req.to, agg);
                agg.finish();
                break;

            case QueryMode.graph:
                // seed the left edge with the value already in effect at `from`,
                // so the line/area starts at the window edge rather than the
                // first change event inside it
                Sample held;
                ulong hold_limit = bucket_width ? bucket_width : req.to - req.from;
                bool has_held = read_sample_before(*f, req.from, held) && req.from - held.time <= hold_limit;

                if (!bucket_width)
                {
                    if (has_held)
                        result ~= Sample(req.from, held.value);
                    SampleAggregator pass; // bucket_width 0 -> passthrough
                    pass.sink = &result;
                    read_range(*f, req.from, req.to, pass);
                }
                else
                {
                    GraphIntervalSampler g;
                    g.sink = &result;
                    g.from = req.from;
                    g.to = req.to;
                    g.bucket_width = bucket_width;
                    if (has_held)
                        g.seed(held);
                    read_range(*f, req.from, req.to, g);
                    g.finish();
                }
                break;
        }
    }

    void shutdown()
    {
        foreach (s; _series.values)
        {
            flush_series(s);
            close_file(s);
            s.pending.clear();
            s.filename = null;
            defaultAllocator().freeT(s);
        }
        _series.clear();
        _lru_head = _lru_tail = null;
        _open_count = 0;
    }

private:
    Map!(SeriesId, DbSeries*) _series;

    DbSeries* _lru_head;   // most-recently used
    DbSeries* _lru_tail;   // least-recently used; evicted first
    size_t _open_count;

    void flush_series(DbSeries* s)
    {
        if (s.pending.empty || s.file_failed)
            return;
        if (!ensure_open(s))
        {
            s.pending.clear();
            return;
        }
        write_pending(s);
    }

    void write_pending(DbSeries* s)
    {
        size_t written;
        if (s.file.get_size() == 0)
        {
            RecordFileHeader hdr;
            if (!s.file.write((&hdr)[0 .. 1], written) || written != RecordFileHeader.sizeof)
            {
                file_error(s, "write");
                s.pending.clear();
                return;
            }
        }

        const(Sample)[] span = s.pending[];
        if (!s.file.write(span, written) || written != span.length * Sample.sizeof)
            file_error(s, "write");
        s.pending.clear();
    }

    bool ensure_open(DbSeries* s)
    {
        if (s.file_open)
        {
            lru_touch(s);
            return true;
        }
        while (_open_count >= max_open && _lru_tail)
            evict(_lru_tail);
        if (!s.file.open(s.filename[], FileOpenMode.ReadWriteAppend, FileOpenFlags.Sequential))
        {
            file_error(s, "open");
            return false;
        }
        s.file_open = true;
        lru_push_front(s);
        ++_open_count;
        return true;
    }

    void evict(DbSeries* s)
    {
        if (!s.pending.empty && !s.file_failed)
            write_pending(s);
        close_file(s);
        atomicFetchAdd!(MemoryOrder.relaxed)(evictions, 1);
    }

    void close_file(DbSeries* s)
    {
        if (!s.file_open)
            return;
        s.file.close();
        s.file_open = false;
        lru_remove(s);
        --_open_count;
    }

    void lru_push_front(DbSeries* s)
    {
        s.lru_prev = null;
        s.lru_next = _lru_head;
        if (_lru_head)
            _lru_head.lru_prev = s;
        _lru_head = s;
        if (!_lru_tail)
            _lru_tail = s;
    }

    void lru_remove(DbSeries* s)
    {
        if (s.lru_prev)
            s.lru_prev.lru_next = s.lru_next;
        else
            _lru_head = s.lru_next;
        if (s.lru_next)
            s.lru_next.lru_prev = s.lru_prev;
        else
            _lru_tail = s.lru_prev;
        s.lru_prev = null;
        s.lru_next = null;
    }

    void lru_touch(DbSeries* s)
    {
        if (_lru_head is s)
            return;
        lru_remove(s);
        lru_push_front(s);
    }

    // Resume appending after a restart: monotonic timestamps must continue from
    // wherever the file left off.
    void seed_last_time(DbSeries* s)
    {
        File f;
        if (!f.open(s.filename[], FileOpenMode.ReadExisting))
            return; // no file yet
        scope(exit) f.close();

        ulong size = f.get_size();
        if (size < RecordFileHeader.sizeof)
            return;

        RecordFileHeader hdr;
        size_t bytes;
        if (!f.read_at((&hdr)[0 .. 1], 0, bytes) || bytes != RecordFileHeader.sizeof ||
            hdr.magic != RecordFileHeader.init.magic)
        {
            notice("'", s.filename[], "' is not a record stream file - recording disabled");
            s.file_failed = true;
            return;
        }

        ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;
        if (!num)
            return;
        Sample last;
        if (f.read_at((&last)[0 .. 1], RecordFileHeader.sizeof + (num - 1) * Sample.sizeof, bytes) &&
            bytes == Sample.sizeof)
            s.last_time = last.time;
    }

    void read_range(A)(ref File f, ulong from, ulong to, ref A agg)
    {
        ulong size = f.get_size();
        if (size < RecordFileHeader.sizeof + Sample.sizeof)
            return;
        ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;

        ulong lo = first_at_or_after(f, num, from);
        if (lo == ulong.max)
            return;

        Sample[256] buf = void;
        for (ulong i = lo; i < num; )
        {
            size_t want = cast(size_t)min(num - i, buf.length);
            size_t bytes;
            if (!f.read_at(buf[0 .. want], RecordFileHeader.sizeof + i * Sample.sizeof, bytes))
                return;
            size_t got = bytes / Sample.sizeof;
            if (!got)
                return;
            foreach (ref sm; buf[0 .. got])
            {
                if (sm.time > to)
                    return;
                agg.put(sm);
            }
            i += got;
        }
    }

    // The sample held at the left edge of a graph window: the record just before
    // `time`. Returns false if nothing precedes it.
    bool read_sample_before(ref File f, ulong time, out Sample result)
    {
        if (time == 0)
            return false;
        ulong size = f.get_size();
        if (size < RecordFileHeader.sizeof + Sample.sizeof)
            return false;
        ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;

        ulong lo = first_at_or_after(f, num, time);
        if (lo == ulong.max || lo == 0)
            return false;

        size_t bytes;
        return f.read_at((&result)[0 .. 1], RecordFileHeader.sizeof + (lo - 1) * Sample.sizeof, bytes) &&
            bytes == Sample.sizeof;
    }

    // Binary search for the index of the first record with time >= `time`
    // (== `num` when every record precedes it). Returns ulong.max on a read
    // failure so callers give up rather than act on a misread index.
    ulong first_at_or_after(ref File f, ulong num, ulong time)
    {
        ulong lo = 0, hi = num;
        while (lo < hi)
        {
            ulong mid = lo + (hi - lo) / 2;
            Sample sm;
            size_t bytes;
            if (!f.read_at((&sm)[0 .. 1], RecordFileHeader.sizeof + mid * Sample.sizeof, bytes) || bytes != Sample.sizeof)
                return ulong.max;
            if (sm.time < time)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    void file_error(DbSeries* s, const(char)[] op)
    {
        notice("'", s.filename[], "': file ", op, " failed - recording disabled");
        s.file_failed = true;
    }

    void notice(Args...)(auto ref Args args)
    {
        if (!on_notice)
            return;
        import urt.mem.temp : tconcat;
        on_notice(tconcat(args)); // tconcat uses the worker's thread-local temp
    }
}
