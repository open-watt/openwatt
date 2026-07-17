module manager.record;

// Element history recording.
//
// A Recorder walks the device tree and attaches a RecordStream to every element
// whose data-model path matches its filter. Each RecordStream keeps a *small*
// local ring of recent samples (a hot cache for live graphing) and ships every
// sample into the database world via the db client. The database owns
// persistence and is the authoritative, complete store -- the frontend never
// touches files and never blocks on disk.
//
// Queries are serviced asynchronously by the database. The local ring is only
// consulted as a fast path when it fully covers the requested range (the common
// "scroll the last minute, live" case); anything wider goes to the database.
//
// Values are recorded as doubles: quantities are normalised to base SI scale,
// bools as 0/1. Non-numeric values (strings, maps) are not recorded.

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
import manager.plugin;

import db;
import db.engine : SampleAggregator, GraphIntervalSampler;

public import db : Sample; // re-export: record streams produce db samples

nothrow @nogc:


alias log = Log!"record";

struct RecordStream
{
nothrow @nogc:

    Recorder owner;
    Element* element;
    String path;            // data-model path: "device.component.element"
    SeriesId series;        // handle into the database world
    ulong flush_watermark;  // newest element-sample time examined for the db
    ulong last_flushed;     // time of the last sample shipped (min-period subsampling)

    this(this) @disable;

    void flush()
    {
        Element* e = element;
        ulong newest = e.recent_newest();
        if (e.recent_count == 0 || newest <= flush_watermark)
            return;

        ulong throttle = 0;
        Duration mp = owner.min_period;
        if (mp > Duration.zero)
            throttle = cast(ulong)mp.as!"nsecs";

        Array!Sample block;
        ulong cursor = last_flushed;
        foreach (i; 0 .. e.recent_count)
        {
            ref const ElementSample s = e.recent_at(i);
            ulong t = unixTimeNs(cast(SysTime)s.time);
            if (t <= flush_watermark)
                continue;
            double v;
            if (!sample_to_double(s.value, v))
                continue;
            if (throttle && cursor && t - cursor < throttle)
                continue;
            block ~= Sample(t, v);
            cursor = t;
        }

        if (block.length == 0)
        {
            flush_watermark = newest; // examined everything; min-period dropped it all
            return;
        }
        if (database().push_block(series, block[]))
        {
            flush_watermark = newest;
            last_flushed = cursor;
        }
    }
}

bool query_local(ref RecordStream rs, ulong from, ulong to, uint max_points, QueryMode mode, ref Array!Sample result)
{
    Element* e = rs.element;
    if (e.recent_count == 0 || e.recent_oldest() > from)
        return false;

    Array!Sample local;
    foreach (i; 0 .. e.recent_count)
    {
        ref const ElementSample s = e.recent_at(i);
        double v;
        if (sample_to_double(s.value, v))
            local ~= Sample(unixTimeNs(cast(SysTime)s.time), v);
    }
    if (local.length == 0 || local[0].time > from)
        return false; // no numeric coverage back to `from`; let the db serve it

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


unittest
{
    import urt.time : from_unix_time_ns;

    // an element capturing samples at 1ms .. 6ms (values 0,10,..,50)
    Element e;
    foreach (i; 0 .. 6)
        e.value(Variant(i * 10.0), from_unix_time_ns((i + 1) * 1_000_000UL));

    RecordStream rs;
    rs.element = &e;

    // local query served from the element's recent buffer
    Array!Sample result;
    assert(rs.query_local(4_000_000, 5_000_000, 0, QueryMode.raw, result));
    assert(result.length == 2);
    assert(result[0].time == 4_000_000 && result[1].time == 5_000_000);

    // can't reach back before the oldest sample
    result.clear();
    assert(!rs.query_local(0, 6_000_000, 0, QueryMode.raw, result));

    // graph mode seeds the left edge with the value held before `from`
    result.clear();
    assert(rs.query_local(4_000_000, 6_000_000, 0, QueryMode.graph, result));
    assert(result[0].time == 4_000_000 && result[0].value == 20); // held from the 3ms sample
}


class Recorder : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("dir", dir),
                                 Prop!("filter", filter),
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

    final Duration min_period() const pure
        => _min_period;
    final void min_period(Duration value)
    {
        _min_period = value;
        mark_set!(typeof(this), "min-period")();
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
        create_directory(_dir[]); // best effort; the db warns if writes later fail
        scan();
        _last_scan = getTime();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        foreach (rs; _streams.values)
        {
            database().close_series(rs.series);
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
    Duration _min_period;

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
        SeriesId series = database().open_series(make_filename(path)[]);
        if (series == invalid_series)
            return; // db channel momentarily full; next scan retries

        RecordStream* rs = defaultAllocator().allocT!RecordStream();
        rs.owner = this;
        rs.element = e;
        rs.path = path.makeString(defaultAllocator());
        rs.series = series;
        _streams.insert(rs.path[], rs);
        // the element self-captures; the first flush ships its standing history
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
}


struct SeriesFetch
{
nothrow @nogc:

    Array!String labels;        // path label per series (owned copy; survives the async gap)
    Array!uint tokens;          // db query token per series; 0 == nothing outstanding
    Array!(Array!Sample) data;  // per-series samples
    ulong t0, t1;
    uint max_points;
    QueryMode mode;
    MonoTime started;
    uint outstanding;           // queries still awaiting their callback
    bool active;

    void begin(RecordModule mod, scope const(char)[][] paths, ulong t0, ulong t1, uint max_points, QueryMode mode, bool allow_local)
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
        tokens.resize(n);
        data.resize(n);
        foreach (i; 0 .. n)
        {
            RecordStream* rs = streams[i];
            labels[][i] = rs.path[].makeString(defaultAllocator());
            tokens[][i] = 0;
            data[][i].clear();
            if (allow_local && query_local(*rs, t0, t1, max_points, mode, data[][i]))
                continue;
            data[][i].clear();
            uint tk = database().query(rs.series, t0, t1, max_points, mode, &on_result);
            if (tk)
            {
                tokens[][i] = tk;
                ++outstanding;
            }
        }
        started = getTime();
        active = n > 0;
    }

    // True once every outstanding query has reported (or a timeout fired, so the
    // caller never hangs on a lost completion). Abandons any stragglers.
    bool done()
    {
        if (!active || outstanding == 0)
            return true;
        if (getTime() - started > 5.seconds)
        {
            cancel();
            return true;
        }
        return false;
    }

    // db callback: match the token to its series and copy the samples in.
    void on_result(uint token, scope const(Sample)[] samples)
    {
        foreach (i; 0 .. tokens.length)
        {
            if (tokens[][i] != token)
                continue;
            data[][i].clear();
            if (samples.length)
            {
                data[][i].resize(samples.length);
                data[][i][][] = samples[];
            }
            tokens[][i] = 0;
            if (outstanding)
                --outstanding;
            break;
        }
    }

    // Abandon any in-flight queries (owner torn down, or timed out).
    void cancel()
    {
        if (DbModule db = database())
        {
            foreach (i; 0 .. tokens.length)
            {
                if (tokens[][i])
                {
                    db.cancel(tokens[][i]);
                    tokens[][i] = 0;
                }
            }
        }
        outstanding = 0;
    }

    void reset()
    {
        cancel();
        active = false;
        labels.clear();
        tokens.clear();
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


// Base for the latent (async) record commands: submit a fetch, poll until the
// database answers, then render once.
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
        if (!fetch.done())
            return CommandCompletionState.in_progress;
        render();
        return CommandCompletionState.finished;
    }

    override void request_cancel()
    {
        _cancel = true;
        fetch.cancel(); // a session teardown may freeT us before update() runs again
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
        cmd.fetch.begin(this, path, t0, t1, w * 2, QueryMode.graph, false);
        return cmd;
    }

    CommandState query_cmd(Session session, const(char)[] path, Nullable!Duration last, Nullable!uint max)
    {
        ulong now = unixTimeNs(getSysTime());
        ulong span = cast(ulong)(last ? last.value : 3600.seconds).as!"nsecs";
        uint max_points = max ? max.value : 24;

        auto cmd = defaultAllocator().allocT!RecordQueryCommand(session, path);
        cmd.fetch.begin(this, (&path)[0 .. 1], now > span ? now - span : 0, now, max_points, QueryMode.raw, false);
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
        if (_fetch.active && _fetch.done())
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
            _fetch.cancel(); // the view is ending: abandon any in-flight query
        return st;
    }

    override void request_cancel()
    {
        super.request_cancel();
        _fetch.cancel(); // a session teardown may freeT us before update() runs again
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
        _fetch.begin(_mod, pats[], t0, t1, _cols * 2, QueryMode.graph, true);
    }

    void build_lines()
    {
        GraphOptions po = _opt;
        render_fetch(_lines, _fetch, _cols, _rows, po);
    }
}
