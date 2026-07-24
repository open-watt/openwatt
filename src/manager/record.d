module manager.record;

// Element history recording. A Recorder walks the device tree and attaches a
// RecordStream to every element whose data-model path matches its filter. The
// Element's typed SeriesStore is the live source and an owsig container extends
// that history on disk.
// Graph queries convert numeric records to doubles and normalise quantities to
// base SI scale. The container itself retains the element's typed records.

import urt.array;
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
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.graph;
import manager.console.live_view;
import manager.device;
import manager.element;
import manager.owsig;
import manager.plugin;

nothrow @nogc:


alias log = Log!"record";

struct Sample
{
    ulong time;
    double value;
}

enum QueryMode : ubyte
{
    raw,
    graph,
}

private struct SampleAggregator
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

private struct GraphIntervalSampler
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
    double _sum = 0;
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

struct RecordStream
{
nothrow @nogc:

    Recorder owner;
    ElementCursor cursor;
    SeriesContainer container;
    String path;            // data-model path: "device.component.element"

    this(this) @disable;

    void flush()
    {
        if (!cursor.pending)
            return;
        if (!container.is_open && !container.open_(owner.make_filename(path[], ".owsig")[]))
            return; // disk trouble; records stay pinned, retry next flush

        while (cursor.pending)
        {
            RecordBlock blk = cursor.next(256);
            if (blk.count == 0)
                break;
            if (!container.put(blk))
            {
                cursor.seek(blk.first_index); // rewind just this block; earlier puts are on disk
                break;
            }
        }
    }

    void close()
    {
        cursor.close();
        container.close_();
    }
}

bool query_local(ref RecordStream rs, ulong from, ulong to, uint max_points, QueryMode mode, ref Array!Sample result)
{
    Element* e = rs.cursor.eid.deref;
    return query_records(e, rs.container, from, to, max_points, mode, result);
}

private bool query_records(Element* e, ref SeriesContainer container, ulong from, ulong to,
                           uint max_points, QueryMode mode, ref Array!Sample result)
{
    Array!Sample local;
    if (e)
    {
        ulong idx = e.index_for_time(from_unix_time_ns(from));
        for (; idx != ulong.max;)
        {
            RecordBlock blk = e.read_records(idx, 256);
            if (blk.count == 0)
                break;
            bool past = false;
            foreach (i; 0 .. blk.count)
            {
                ulong t = unixTimeNs(blk.time(i));
                if (t > to)
                {
                    past = true;
                    break;
                }
                double v;
                Variant val = blk.box(i);
                if (sample_to_double(val, v))
                    local ~= Sample(t, v);
            }
            if (past)
                break;
            idx += blk.count;
        }
    }

    if ((local.length == 0 || local[0].time > from) && container.is_open && container.dir.length)
    {
        // the container reaches further back than RAM retention
        Array!Sample merged;
        ulong ram_start = local.length ? local[0].time : ulong.max;
        size_t bi = container.find_by_time(from / 1000);
        if (bi == container.dir.length)
            --bi;       // everything ends before `from`: the last block holds the seed
        else if (bi)
            --bi;       // step back one block for held state
        outer: for (; bi < container.dir.length; ++bi)
        {
            if (container.dir[bi].hdr.first_tick * 1000 > to)
                break;
            RecordBlock blk;
            if (!container.load(bi, blk))
                break;
            foreach (i; 0 .. blk.count)
            {
                ulong t = unixTimeNs(blk.time(i));
                if (t >= ram_start || t > to)
                    break outer;
                double v;
                Variant val = blk.box(i);
                if (sample_to_double(val, v))
                    merged ~= Sample(t, v);
            }
        }
        foreach (ref const Sample s; local[])
            merged ~= s;
        local = merged.move;
    }
    if (local.length == 0)
        return false;

    ulong bucket_width = max_points ? (to - from) / max_points + 1 : 0;

    if (mode == QueryMode.graph)
    {
        Sample held;
        bool has_held = false;
        foreach (ref const Sample s; local[])
        {
            if (s.time >= from)
                break;
            held = s;
            has_held = true;
        }
        ulong hold_limit = bucket_width ? bucket_width : to - from;
        has_held = has_held && from - held.time <= hold_limit;

        if (!bucket_width)
        {
            if (has_held)
                result ~= Sample(from, held.value);
            foreach (ref const Sample s; local[])
            {
                if (s.time < from)
                    continue;
                if (s.time > to)
                    break;
                result ~= s;
            }
        }
        else
        {
            GraphIntervalSampler g;
            g.sink = &result;
            g.from = from;
            g.to = to;
            g.bucket_width = bucket_width;
            if (has_held)
                g.seed(held);
            foreach (ref const Sample s; local[])
            {
                if (s.time < from)
                    continue;
                if (s.time > to)
                    break;
                g.put(s);
            }
            g.finish();
        }
        return true;
    }

    SampleAggregator agg;
    agg.sink = &result;
    agg.from = from;
    agg.bucket_width = bucket_width;
    foreach (ref const Sample s; local[])
    {
        if (s.time < from)
            continue;
        if (s.time > to)
            break;
        agg.put(s);
    }
    agg.finish();
    return true;
}


class Recorder : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("dir", dir),
                                 Prop!("filter", filter));
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
        mark_set!(typeof(this), "dir")();
        restart();
    }

    final const(char)[] filter() const pure
        => _filter[];
    final void filter(const(char)[] value)
    {
        if (_filter[] == value)
            return;
        _filter = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "filter")();
        restart();
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

    override bool validate() const pure
        => !_dir.empty;

    override CompletionStatus startup()
    {
        import urt.file : create_directory;
        create_directory(_dir[]); // best effort; each stream retries its open on flush
        scan();
        _last_scan = getTime();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        foreach (rs; _streams.values)
        {
            rs.close();
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

        foreach (rs; _streams.values)
            rs.flush();
    }

private:
    String _dir = StringLit!"records";
    String _filter = StringLit!"*";

    Map!(const(char)[], RecordStream*) _streams; // keyed by the stream's own path string
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
        if (!container_serialisable(*e.data_format))
            return;

        RecordStream* rs = defaultAllocator().allocT!RecordStream();
        rs.owner = this;
        rs.cursor = e.open_cursor(0, true);
        rs.path = path.makeString(defaultAllocator());
        rs.container.open_(make_filename(path, ".owsig")[]);
        _streams.insert(rs.path[], rs);
        // the element self-captures; the first flush ships its standing history
    }

    String make_filename(const(char)[] path, const(char)[] ext)
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
        fn ~= ext;
        return fn[].makeString(defaultAllocator());
    }
}


struct SeriesFetch
{
nothrow @nogc:

    Array!String labels;
    Array!(Array!Sample) data;  // per-series samples
    ulong t0, t1;
    uint max_points;
    QueryMode mode;
    bool active;

    void begin(RecordModule mod, scope const(char)[][] paths, ulong t0, ulong t1,
               uint max_points, QueryMode mode)
    {
        reset();
        this.t0 = t0;
        this.t1 = t1;
        this.max_points = max_points;
        this.mode = mode;

        Array!(RecordStream*) streams;
        mod.find_streams(paths, streams);
        uint n = cast(uint)streams.length;
        labels.resize(n);
        data.resize(n);
        foreach (i; 0 .. n)
        {
            RecordStream* rs = streams[i];
            labels[][i] = rs.path[].makeString(defaultAllocator());
            data[][i].clear();
            query_local(*rs, t0, t1, max_points, mode, data[][i]);
        }
        active = n > 0;
    }

    void reset()
    {
        active = false;
        labels.clear();
        data.clear();
    }
}


// Render already-fetched series into terminal lines. `panels` mode renders one
// chart per series, stacked vertically with a shared time range.
void render_fetch(ref Array!(MutableString!0) lines, ref SeriesFetch f, uint cols, uint rows, ref GraphOptions opt)
{
    lines.clear();
    uint n = cast(uint)f.labels.length;
    if (n == 0)
    {
        lines.pushBack() ~= "no record streams match";
        return;
    }

    Array!(GraphSeries!Sample) series;
    foreach (i; 0 .. n)
        series ~= GraphSeries!Sample(f.data[][i][], 0, f.labels[][i][]);

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
            title.append("\x1b[0m ", f.labels[][i][]);

            GraphOptions po = opt;
            po.mode = GraphMode.overlay;
            po.legend = false;
            po.x_axis = last_panel;
            po.color = c;
            render_graph(sub, series[i].samples, f.t0, f.t1, cols, panel_rows, po);
            foreach (ref l; sub[])
                lines ~= l.move;
        }
        return;
    }

    render_graph(lines, series[], f.t0, f.t1, cols, rows, opt);
}


// Base for record commands that render their fetched data on update.
abstract class RecordFetchCommand : CommandState
{
nothrow @nogc:

    SeriesFetch fetch;

    this(Session session)
    {
        super(session, null);
    }

    override CommandCompletionState update()
    {
        if (_cancel)
        {
            fetch.reset();
            return CommandCompletionState.cancelled;
        }
        render();
        return CommandCompletionState.finished;
    }

    override void request_cancel()
    {
        _cancel = true;
        fetch.reset();
    }

    abstract void render();

private:
    bool _cancel;
}


class RecordQueryCommand : RecordFetchCommand
{
nothrow @nogc:

    this(Session session, const(char)[] path)
    {
        super(session);
        _path = path.makeString(defaultAllocator());
    }

    override void render()
    {
        if (fetch.labels.length == 0)
        {
            session.write_line("No record stream for '", _path[], "'");
            return;
        }
        foreach (ref s; fetch.data[][0][])
            session.write_line(getDateTime(from_unix_time_ns(s.time)), "  ", s.value);
        session.write_line(fetch.data[][0].length, " samples");
    }

private:
    String _path;
}


class RecordGraphCommand : RecordFetchCommand
{
nothrow @nogc:

    this(Session session, uint cols, uint rows, GraphOptions opt)
    {
        super(session);
        _cols = cols;
        _rows = rows;
        _opt = opt;
    }

    override void render()
    {
        Array!(MutableString!0) lines;
        render_fetch(lines, fetch, _cols, _rows, _opt);
        foreach (ref l; lines[])
            session.write_line(l[]);
    }

private:
    uint _cols, _rows;
    GraphOptions _opt;
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

        auto cmd = defaultAllocator().allocT!RecordGraphCommand(session, w, h, opt);
        cmd.fetch.begin(this, path, t0, t1, w * 2, QueryMode.graph);
        return cmd;
    }

    CommandState query_cmd(Session session, const(char)[] path, Nullable!Duration last, Nullable!uint max)
    {
        ulong now = unixTimeNs(getSysTime());
        ulong span = cast(ulong)(last ? last.value : 3600.seconds).as!"nsecs";
        uint max_points = max ? max.value : 24;

        auto cmd = defaultAllocator().allocT!RecordQueryCommand(session, path);
        cmd.fetch.begin(this, (&path)[0 .. 1], now > span ? now - span : 0, now,
                        max_points, QueryMode.raw);
        return cmd;
    }
}


// Live graph: re-fetches a sliding [now - span, now] window a few times a
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
        if (!_fetch.active && (!_last_build || getTime() - _last_build >= 250.msecs))
            start_fetch();
        if (_fetch.active)
        {
            build_lines();
            request_redraw();
            _fetch.active = false;
            _last_build = getTime();
        }
    }

    override CommandCompletionState update()
    {
        CommandCompletionState st = super.update();
        if (st != CommandCompletionState.in_progress)
            _fetch.reset();
        return st;
    }

    override void request_cancel()
    {
        super.request_cancel();
        _fetch.reset();
    }

    override bool handle_key(const(char)[] seq)
    {
        if (seq[] == "+" || seq[] == "=")
        {
            if (_span > 10.seconds)
            {
                _span = (_span.as!"msecs" / 2).msecs;
                start_fetch();
            }
            return true;
        }
        if (seq[] == "-")
        {
            if (_span < 86_400.seconds)
            {
                _span = (_span.as!"msecs" * 2).msecs;
                start_fetch();
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
    uint _cols, _rows;
    MonoTime _last_build;
    SeriesFetch _fetch;
    Array!(MutableString!0) _lines;

    void start_fetch()
    {
        uint w = session.width();
        uint h = session.height();
        if (w == 0)
            w = 80;
        if (h == 0)
            h = 24;
        _cols = w;
        _rows = _height ? _height : (h > 2 ? h - 1 : 1);

        ulong t1 = unixTimeNs(getSysTime());
        ulong span_ns = cast(ulong)_span.as!"nsecs";
        ulong t0 = t1 > span_ns ? t1 - span_ns : 0;

        Array!(const(char)[]) pats;
        foreach (ref p; _paths[])
            pats ~= p[];
        _fetch.begin(_mod, pats[], t0, t1, _cols * 2, QueryMode.graph);
    }

    void build_lines()
    {
        GraphOptions po = _opt;
        render_fetch(_lines, _fetch, _cols, _rows, po);
    }
}


unittest
{
    import urt.time : from_unix_time_ns;

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

    static immutable DataFormat qfmt = DataFormat(ValueType.f64, SeriesKind.held);
    Element en;
    en.format = register_format(qfmt);
    en.ensure_history();
    foreach (i; 0 .. 6)
        en.write_sample(i * 10.0, from_unix_time_ns((i + 1) * 1_000_000UL));

    SeriesContainer container;
    result.clear();
    assert(query_records(&en, container, 4_000_000, 5_000_000, 0, QueryMode.raw, result));
    assert(result.length == 2 && result[0].time == 4_000_000 && result[0].value == 30);
    result.clear();
    assert(query_records(&en, container, 0, 6_000_000, 0, QueryMode.raw, result));
    assert(result.length == 6);
    result.clear();
    assert(query_records(&en, container, 4_000_000, 6_000_000, 0, QueryMode.graph, result));
    assert(result[0].time == 4_000_000 && result[0].value == 20);
    en.teardown();
}
