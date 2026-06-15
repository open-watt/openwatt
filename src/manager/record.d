module manager.record;

// Element history recording ("record streams").
//
// Each recorded element gets a RecordStream: a ring of recent samples in
// memory, backed by an append-only file of fixed-size records so history
// survives restarts. A Recorder walks the device tree and attaches a stream
// to every element whose data-model path matches its filter.
//
// The on-disk format is a stop-gap: one file per element, a 16-byte header
// followed by packed (timestamp, value) records. Timestamps are strictly
// increasing within a file, so time ranges are located by binary search.
// A future permanent store will re-encode this data into time blocks with
// tighter encodings; this format only needs to be good enough to accumulate
// data until then.
//
// Values are recorded as doubles: quantities are normalised to base SI scale,
// bools as 0/1. Non-numeric values (strings, maps) are not recorded.

import urt.array;
import urt.file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.util : min;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.console;
import manager.console.bitmap;
import manager.console.graph;
import manager.console.live_view;
import manager.device;
import manager.element;
import manager.plugin;

nothrow @nogc:


struct Sample
{
    ulong time;   // unix ns
    double value;
}

// Native-endian (all supported targets are little-endian).
struct RecordFileHeader
{
    char[4] magic = "OWRS";
    uint version_ = 1;
    ulong reserved;
}

bool sample_value(ref const Variant v, out double value)
{
    if (v.isBool)
        value = v.asBool ? 1 : 0;
    else if (v.isQuantity)
        value = v.asQuantity!double().normalise().value;
    else if (v.isNumber)
        value = v.asDouble;
    else
        return false;
    return value == value; // don't record NaN
}

struct RecordStream
{
nothrow @nogc:

    Recorder owner;
    Element* element;
    String path;       // data-model path: "device.component.element"
    String filename;
    Array!Sample ring; // circular; oldest at `head`
    uint head;
    uint count;
    uint unflushed;    // the newest `unflushed` ring entries are not yet on disk
    ulong last_time;   // most recent recorded timestamp (unix ns)
    bool file_failed;  // warn-once latch; also set when the file is unusable

    this(this) @disable;

    ref const(Sample) at(uint i) const pure
        => ring[(head + i) % cast(uint)ring.length];

    ulong oldest_time() const pure
        => count ? at(0).time : ulong.max;

    void on_change(ref Element e, ref const Variant val, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp)
    {
        record(val, timestamp);
    }

    void record(ref const Variant val, SysTime timestamp)
    {
        ulong t = unixTimeNs(timestamp);
        if (t <= last_time)
            return;
        Duration throttle = owner.min_period;
        if (throttle > Duration.zero && t - last_time < cast(ulong)throttle.as!"nsecs")
            return;
        double v;
        if (!sample_value(val, v))
            return;
        push(Sample(t, v));
        last_time = t;
    }

    void push(ref const Sample s)
    {
        uint cap = cast(uint)ring.length;
        if (count == cap)
        {
            if (unflushed == count)
            {
                // about to overwrite a sample that never reached disk
                owner.flush_stream(this);
                if (unflushed == count)
                    --unflushed; // no filesystem or write failure; the sample is lost
            }
            ring[][head] = s;
            head = (head + 1) % cap;
            ++unflushed;
        }
        else
        {
            ring[][(head + count) % cap] = s;
            ++count;
            ++unflushed;
        }
    }
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

// Recall samples in [from_ns, to_ns] (inclusive). Anything older than the
// in-memory ring is read from the stream's file; the ring serves the rest
// (the file also holds the flushed portion of the ring, so the file read is
// capped at the ring's oldest sample to avoid duplicates). If max_points is
// non-zero the result is downsampled to at most that many bucket means.
void query_stream(ref RecordStream rs, ulong from_ns, ulong to_ns, uint max_points, ref Array!Sample result)
{
    if (to_ns <= from_ns)
        return;

    SampleAggregator agg;
    agg.sink = &result;
    agg.from = from_ns;
    agg.bucket_width = max_points ? (to_ns - from_ns) / max_points + 1 : 0;

    ulong ring_oldest = rs.oldest_time();
    if (from_ns < ring_oldest && !rs.file_failed)
        read_file_range(rs, from_ns, min(to_ns + 1, ring_oldest), agg);

    foreach (i; 0 .. rs.count)
    {
        ref const Sample s = rs.at(i);
        if (s.time < from_ns)
            continue;
        if (s.time > to_ns)
            break;
        agg.put(s);
    }
    agg.finish();
}

// Graphs render record streams as sample-and-hold signals. Seed the result
// with the value already in effect at the left edge of the window.
void query_stream_for_graph(ref RecordStream rs, ulong from_ns, ulong to_ns, uint max_points, ref Array!Sample result)
{
    if (to_ns <= from_ns)
        return;

    ulong bucket_width = max_points ? (to_ns - from_ns) / max_points + 1 : 0;
    Sample held;
    ulong hold_limit = bucket_width ? bucket_width : to_ns - from_ns;
    bool has_held = find_sample_before(rs, from_ns, held) && from_ns - held.time <= hold_limit;

    if (!max_points)
    {
        if (has_held)
            result ~= Sample(from_ns, held.value);
        query_stream(rs, from_ns, to_ns, 0, result);
        return;
    }

    GraphIntervalSampler sampler;
    sampler.sink = &result;
    sampler.from = from_ns;
    sampler.to = to_ns;
    sampler.bucket_width = bucket_width;
    if (has_held)
        sampler.seed(held);

    ulong ring_oldest = rs.oldest_time();
    if (from_ns < ring_oldest && !rs.file_failed)
        read_file_range(rs, from_ns, min(to_ns + 1, ring_oldest), sampler);

    foreach (i; 0 .. rs.count)
    {
        ref const Sample s = rs.at(i);
        if (s.time < from_ns)
            continue;
        if (s.time > to_ns)
            break;
        sampler.put(s);
    }
    sampler.finish();
}


unittest
{
    // ring push: fill, wrap, and unflushed accounting
    RecordStream rs;
    rs.ring.resize(4);
    foreach (i; 0 .. 6)
    {
        if (i == 4)
            rs.unflushed = 0; // simulate a flush so a full ring never needs the owner
        rs.push(Sample(i + 1, i * 10.0));
    }
    assert(rs.count == 4);
    assert(rs.unflushed == 2);
    assert(rs.at(0).time == 3);
    assert(rs.at(3).time == 6);

    // in-memory range query (no file behind this stream)
    Array!Sample result;
    query_stream(rs, 4, 5, 0, result);
    assert(result.length == 2);
    assert(result[0].time == 4 && result[1].time == 5);

    // bucketed downsample: mean value, stamped with the bucket's last time
    result.clear();
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

    // graph query: seed with the held value before the visible range
    result.clear();
    query_stream_for_graph(rs, 4, 5, 0, result);
    assert(result.length == 3);
    assert(result[0].time == 4 && result[0].value == 20);
    assert(result[1].time == 4 && result[1].value == 30);
    assert(result[2].time == 5 && result[2].value == 40);

    result.clear();
    query_stream_for_graph(rs, 3, 3, 0, result);
    assert(result.length == 0);

    result.clear();
    query_stream_for_graph(rs, 100, 101, 0, result);
    assert(result.length == 0);

    RecordStream old_seed;
    old_seed.ring.resize(4);
    old_seed.push(Sample(1, 999));
    old_seed.push(Sample(15, 10));
    result.clear();
    query_stream_for_graph(old_seed, 10, 30, 5, result);
    assert(result.length == 3);
    assert(result[0].time == 15);

    RecordStream late_start;
    late_start.ring.resize(4);
    late_start.push(Sample(1, 999));
    late_start.push(Sample(12, 10));
    result.clear();
    query_stream_for_graph(late_start, 10, 30, 5, result);
    assert(result.length == 4);
    assert(result[0].time == 12);

    result.clear();
    query_stream_for_graph(rs, 3, 7, 4, result);
    assert(result.length == 2);
    assert(result[0].time == 3);
    assert(result[1].time == 5);

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


class Recorder : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("dir", dir),
                                 Prop!("filter", filter),
                                 Prop!("depth", depth),
                                 Prop!("flush-interval", flush_interval),
                                 Prop!("min-period", min_period));
nothrow @nogc:

    enum type_name = "recorder";
    enum path = "/record";
    enum collection_id = CollectionType.recorder;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Recorder, id, flags);
    }

    // Properties

    final const(char)[] dir() const pure
        => _dir[];
    final void dir(const(char)[] value)
    {
        if (_dir[] == value)
            return;
        _dir = value.makeString(g_app.allocator);
        restart();
    }

    final const(char)[] filter() const pure
        => _filter[];
    final void filter(const(char)[] value)
    {
        if (_filter[] == value)
            return;
        _filter = value.makeString(g_app.allocator);
        restart();
    }

    final uint depth() const pure
        => _depth;
    final void depth(uint value)
    {
        if (_depth == value)
            return;
        _depth = value;
        restart();
    }

    final Duration flush_interval() const pure
        => _flush_interval;
    final void flush_interval(Duration value)
    {
        _flush_interval = value;
    }

    final Duration min_period() const pure
        => _min_period;
    final void min_period(Duration value)
    {
        _min_period = value;
    }

    // API

    final RecordStream* find_stream(const(char)[] path)
    {
        if (RecordStream** rs = path in _streams)
            return *rs;
        return null;
    }

    final int opApply(scope int delegate(ref RecordStream) nothrow @nogc dg)
    {
        foreach (rs; _streams.values)
            if (auto r = dg(*rs))
                return r;
        return 0;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => !_dir.empty && _depth >= 2;

    override CompletionStatus startup()
    {
        create_directory(_dir[]); // best effort; file opens warn if it didn't work
        scan();
        _last_flush = getTime();
        _last_scan = _last_flush;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        foreach (rs; _streams.values)
        {
            rs.element.remove_subscriber(&rs.on_change);
            flush_stream(*rs);
            defaultAllocator().freeT(rs);
        }
        _streams.clear();
        return CompletionStatus.complete;
    }

    override void update()
    {
        MonoTime now = getTime();

        // elements are created via several paths with no common creation hook,
        // so sweep the device tree for new arrivals
        if (now - _last_scan >= 1.seconds)
        {
            scan();
            _last_scan = now;
        }

        bool flush_all = now - _last_flush >= _flush_interval;
        foreach (rs; _streams.values)
        {
            if (rs.unflushed && (flush_all || rs.unflushed >= _depth / 2))
                flush_stream(*rs);
        }
        if (flush_all)
            _last_flush = now;
    }

package:
    void flush_stream(ref RecordStream rs)
    {
        if (!rs.unflushed || rs.file_failed)
            return;

        File f;
        if (!f.open(rs.filename[], FileOpenMode.WriteAppend, FileOpenFlags.Sequential))
        {
            file_error(rs, "open");
            return;
        }
        scope(exit) f.close();

        size_t written;
        if (f.get_size() == 0)
        {
            RecordFileHeader hdr;
            if (!f.write((&hdr)[0 .. 1], written) || written != RecordFileHeader.sizeof)
            {
                file_error(rs, "write");
                return;
            }
        }

        uint cap = cast(uint)rs.ring.length;
        uint start = (rs.head + rs.count - rs.unflushed) % cap;
        while (rs.unflushed)
        {
            uint n = min(rs.unflushed, cap - start);
            const(Sample)[] span = rs.ring[start .. start + n];
            if (!f.write(span, written) || written != n * Sample.sizeof)
            {
                file_error(rs, "write");
                return;
            }
            rs.unflushed -= n;
            start = 0;
        }
    }

private:
    String _dir = StringLit!"records";
    String _filter = StringLit!"*";
    uint _depth = 256;
    Duration _flush_interval = 10.seconds;
    Duration _min_period;

    Map!(const(char)[], RecordStream*) _streams; // keyed by the stream's own path string
    MonoTime _last_flush;
    MonoTime _last_scan;

    void scan()
    {
        Array!(Element*) elements = g_app.find_elements(_filter[]);
        char[256] buf = void;
        foreach (e; elements[])
        {
            ptrdiff_t len = e.full_path(buf);
            if (len <= 0 || len > buf.length)
                continue;
            const(char)[] path = buf[0 .. len];
            if (path !in _streams)
                attach(e, path);
        }
    }

    void attach(Element* e, const(char)[] path)
    {
        RecordStream* rs = defaultAllocator().allocT!RecordStream();
        rs.owner = this;
        rs.element = e;
        rs.path = path.makeString(defaultAllocator());
        rs.filename = make_filename(path);
        rs.ring.resize(_depth);
        seed_last_time(*rs);
        e.add_subscriber(&rs.on_change);
        _streams.insert(rs.path[], rs);

        // capture the element's standing value, if it has one
        if (e.last_update)
            rs.record(e.value, e.last_update);
    }

    String make_filename(const(char)[] path)
    {
        MutableString!0 fn;
        fn.append(_dir[], '/');
        foreach (char c; path)
        {
            if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' ||
                c == '"' || c == '<' || c == '>' || c == '|')
                fn ~= '_';
            else
                fn ~= c;
        }
        fn ~= ".owr";
        return fn[].makeString(defaultAllocator());
    }

    // Resume appending after a restart: monotonic timestamps must continue
    // from wherever the file left off.
    void seed_last_time(ref RecordStream rs)
    {
        File f;
        if (!f.open(rs.filename[], FileOpenMode.ReadExisting))
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
            log.warning("'", rs.path[], "': '", rs.filename[], "' is not a record stream file - recording disabled");
            rs.file_failed = true;
            return;
        }

        ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;
        if (!num)
            return;
        Sample last;
        if (f.read_at((&last)[0 .. 1], RecordFileHeader.sizeof + (num - 1) * Sample.sizeof, bytes) &&
            bytes == Sample.sizeof)
            rs.last_time = last.time;
    }

    void file_error(ref RecordStream rs, const(char)[] op)
    {
        log.warning("'", rs.path[], "': file ", op, " failed for '", rs.filename[], "' - recording disabled");
        rs.file_failed = true;
    }
}

class RecordModule : Module
{
    mixin DeclareModule!"record";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!Recorder();
        g_app.console.register_command!query_cmd("/record", this, "query");
        g_app.console.register_command!graph_cmd("/record", this, "graph");
    }

    override void update()
    {
        Collection!Recorder().update_all();
    }

    RecordStream* find_stream(const(char)[] path)
    {
        foreach (rec; Collection!Recorder().values)
        {
            if (RecordStream* rs = rec.find_stream(path))
                return rs;
        }
        return null;
    }

    import urt.meta.nullable;
    import manager.console.command : CommandState;

    // expand element path patterns (wildcards and comma-lists allowed) into
    // record streams; capped at the graph palette size
    void find_streams(scope const(char)[][] patterns, ref Array!(RecordStream*) result)
    {
        static void add_unique(ref Array!(RecordStream*) arr, RecordStream* rs)
        {
            foreach (e; arr[])
                if (e is rs)
                    return;
            arr ~= rs;
        }

        Array!(Element*) elements;
        foreach (pattern; patterns)
        {
            const(char)[] rest = pattern;
            while (!rest.empty)
            {
                const(char)[] tok = rest.split!',';
                if (!tok.empty)
                    g_app.find_elements(tok, elements);
            }
        }

        char[256] buf = void;
        foreach (e; elements[])
        {
            ptrdiff_t len = e.full_path(buf);
            if (len <= 0 || len > buf.length)
                continue;
            if (RecordStream* rs = find_stream(buf[0 .. len]))
                add_unique(result, rs);
        }
        if (result.length > graph_palette.length)
            result.resize(graph_palette.length);
    }

    // shared by the static command and the live view: query every matched
    // stream over [t0, t1] and render. `panels` mode renders one chart per
    // series, stacked vertically with a shared time range.
    void render_paths(ref Array!(MutableString!0) lines, scope const(char)[][] paths, ulong t0, ulong t1, uint cols, uint rows, ref GraphOptions opt)
    {
        lines.clear();

        Array!(RecordStream*) streams;
        find_streams(paths, streams);
        if (streams.empty)
        {
            lines.pushBack() ~= "no record streams match";
            return;
        }

        uint n = cast(uint)streams.length;
        Array!(Array!Sample) data;
        data.resize(n);
        Array!(GraphSeries!Sample) series;
        foreach (i; 0 .. n)
        {
            query_stream_for_graph(*streams[i], t0, t1, cols * 2, data[][i]);
            series ~= GraphSeries!Sample(data[][i][], 0, streams[i].path[]);
        }

        if (opt.mode == GraphMode.panels && n > 1)
        {
            uint per = rows / n;
            if (per < 5)
            {
                lines.pushBack() ~= "graph: too many panels for the area";
                return;
            }

            Array!(MutableString!0) sub;
            foreach (i; 0 .. n)
            {
                bool last_panel = i + 1 == n;
                uint panel_rows = per - 1 + (last_panel ? rows % n : 0);
                Pixel c = graph_palette[i % graph_palette.length];

                ref MutableString!0 title = lines.pushBack();
                title.append("\x1b[38;2;", (c >> 16) & 0xFF, ';', (c >> 8) & 0xFF, ';', c & 0xFF, 'm');
                append_utf8(title, 0x25A0);
                title.append("\x1b[0m ", streams[i].path[]);

                GraphOptions po = opt;
                po.mode = GraphMode.overlay;
                po.legend = false;
                po.x_axis = last_panel;
                po.color = c;
                render_graph(sub, series[i].samples, t0, t1, cols, panel_rows, po);
                foreach (ref l; sub[])
                    lines ~= l.move;
            }
            return;
        }

        render_graph(lines, series[], t0, t1, cols, rows, opt);
    }

    // /record/graph path=<elem>[,<elem>...] [last=][from=][to=] [mode=] [style=] [height=] [live=yes]
    CommandState graph_cmd(Session session, const(char)[][] path, Nullable!Duration last,
                           Nullable!SysTime from, Nullable!SysTime to, Nullable!GraphMode mode,
                           Nullable!bool live, Nullable!GraphStyle style, Nullable!uint height)
    {
        GraphOptions opt;
        if (style)
            apply_style(opt, style.value);
        if (mode)
            opt.mode = mode.value;

        if (live && live.value)
        {
            Duration span = last ? last.value : 120.seconds;
            Array!String paths;
            foreach (p; path)
                paths ~= p.makeString(defaultAllocator());
            return defaultAllocator().allocT!GraphViewState(session, this, paths.move, span, opt, height ? height.value : 0);
        }

        ulong t1 = unixTimeNs(to ? to.value : getSysTime());
        ulong span_ns = cast(ulong)(last ? last.value : 3600.seconds).as!"nsecs";
        ulong t0 = from ? unixTimeNs(from.value) : (t1 > span_ns ? t1 - span_ns : 0);

        uint w = session.width();
        if (w == 0)
            w = 80;
        uint h = height ? height.value : 16;

        Array!(MutableString!0) lines;
        render_paths(lines, path, t0, t1, w, h, opt);
        foreach (ref l; lines[])
            session.write_line(l[]);
        return null;
    }

    void query_cmd(Session session, const(char)[] path, Nullable!Duration last, Nullable!uint max)
    {
        RecordStream* rs = find_stream(path);
        if (!rs)
        {
            session.write_line("No record stream for '", path, "'");
            return;
        }

        ulong now = unixTimeNs(getSysTime());
        ulong span = cast(ulong)(last ? last.value : 3600.seconds).as!"nsecs";
        uint max_points = max ? max.value : 24;

        Array!Sample samples;
        query_stream(*rs, now > span ? now - span : 0, now, max_points, samples);
        foreach (ref s; samples[])
            session.write_line(getDateTime(from_unix_time_ns(s.time)), "  ", s.value);
        session.write_line(samples.length, " samples");
    }
}

// Live graph: re-queries a sliding [now - span, now] window a few times a
// second, so short spans scroll in realtime. +/- halve/double the span.
class GraphViewState : LiveViewState
{
    import urt.mem.temp : tconcat;
    import manager.console.command : CommandCompletionState;
nothrow @nogc:

    this(Session session, RecordModule mod, Array!String paths, Duration span, GraphOptions opt, uint height)
    {
        super(session, null, height ? LiveViewMode.inline_ : LiveViewMode.fullscreen);
        _mod = mod;
        _paths = paths.move;
        _span = span;
        _opt = opt;
        _height = height;
    }

    override uint content_height()
        => cast(uint)_lines.length;

    override void render_content(uint offset, uint count, uint width)
    {
        foreach (i; offset .. offset + count)
        {
            session.write_output("\r", false);
            if (i < _lines.length)
                session.write_output(_lines[i][], false);
            session.write_output("\x1b[K\r\n", false);
        }
    }

protected:
    override bool continuous_redraw()
        => false;

    override void poll()
    {
        MonoTime now = getTime();
        if (!_last_build || now - _last_build >= 250.msecs)
        {
            rebuild();
            request_redraw();
            _last_build = now;
        }
    }

    override bool handle_key(const(char)[] seq)
    {
        if (seq[] == "+" || seq[] == "=")
        {
            if (_span > 10.seconds)
            {
                _span = (_span.as!"msecs" / 2).msecs;
                rebuild();
                _last_build = getTime();
            }
            return true;
        }
        if (seq[] == "-")
        {
            if (_span < 86_400.seconds)
            {
                _span = (_span.as!"msecs" * 2).msecs;
                rebuild();
                _last_build = getTime();
            }
            return true;
        }
        return false;
    }

    override const(char)[] status_text()
    {
        const(char)[] first = _paths.length ? _paths[0][] : null;
        if (_paths.length > 1)
            return tconcat(first, " +", _paths.length - 1, " | span=", _span, " | +/- zoom");
        return tconcat(first, " | span=", _span, " | +/- zoom");
    }

private:
    RecordModule _mod;
    Array!String _paths;
    Duration _span;
    GraphOptions _opt;
    uint _height;
    MonoTime _last_build;
    Array!(MutableString!0) _lines;

    void rebuild()
    {
        uint w = session.width();
        uint h = session.height();
        if (w == 0)
            w = 80;
        if (h == 0)
            h = 24;
        uint rows = _height ? _height : (h > 2 ? h - 1 : 1);

        ulong t1 = unixTimeNs(getSysTime());
        ulong span_ns = cast(ulong)_span.as!"nsecs";
        ulong t0 = t1 > span_ns ? t1 - span_ns : 0;

        Array!(const(char)[]) pats;
        foreach (ref p; _paths[])
            pats ~= p[];
        _mod.render_paths(_lines, pats[], t0, t1, w, rows, _opt);
    }
}

private bool find_sample_before(ref RecordStream rs, ulong time, out Sample result)
{
    if (time == 0)
        return false;

    for (uint i = rs.count; i > 0; --i)
    {
        ref const Sample s = rs.at(i - 1);
        if (s.time < time)
        {
            result = s;
            return true;
        }
    }

    return read_file_sample_before(rs, time, result);
}

private bool read_file_sample_before(ref RecordStream rs, ulong time, out Sample result)
{
    if (rs.file_failed || time == 0)
        return false;

    File f;
    if (!f.open(rs.filename[], FileOpenMode.ReadExisting, FileOpenFlags.Sequential))
        return false;
    scope(exit) f.close();

    ulong size = f.get_size();
    if (size < RecordFileHeader.sizeof + Sample.sizeof)
        return false;
    ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;

    // Binary search for the first record with time >= `time`; the previous
    // record is the held value at the left edge of a graph window.
    ulong lo = 0, hi = num;
    while (lo < hi)
    {
        ulong mid = lo + (hi - lo) / 2;
        Sample s;
        size_t bytes;
        if (!f.read_at((&s)[0 .. 1], RecordFileHeader.sizeof + mid * Sample.sizeof, bytes) || bytes != Sample.sizeof)
            return false;
        if (s.time < time)
            lo = mid + 1;
        else
            hi = mid;
    }

    if (lo == 0)
        return false;

    size_t bytes;
    return f.read_at((&result)[0 .. 1], RecordFileHeader.sizeof + (lo - 1) * Sample.sizeof, bytes) &&
        bytes == Sample.sizeof;
}

private void read_file_range(A)(ref RecordStream rs, ulong from, ulong end, ref A agg)
{
    File f;
    if (!f.open(rs.filename[], FileOpenMode.ReadExisting, FileOpenFlags.Sequential))
        return;
    scope(exit) f.close();

    ulong size = f.get_size();
    if (size < RecordFileHeader.sizeof + Sample.sizeof)
        return;
    ulong num = (size - RecordFileHeader.sizeof) / Sample.sizeof;

    // binary search for the first record with time >= from
    ulong lo = 0, hi = num;
    while (lo < hi)
    {
        ulong mid = lo + (hi - lo) / 2;
        Sample s;
        size_t bytes;
        if (!f.read_at((&s)[0 .. 1], RecordFileHeader.sizeof + mid * Sample.sizeof, bytes) || bytes != Sample.sizeof)
            return;
        if (s.time < from)
            lo = mid + 1;
        else
            hi = mid;
    }

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
        foreach (ref s; buf[0 .. got])
        {
            if (s.time >= end)
                return;
            agg.put(s);
        }
        i += got;
    }
}
