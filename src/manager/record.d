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
import manager.record_io;

nothrow @nogc:

public import manager.record_io : Sample, QueryMode;

alias log = Log!"record";

private __gshared RecordIO g_record_io;

struct RecordStream
{
nothrow @nogc:

    Recorder owner;
    ElementCursor cursor;
    RecordFileId file;
    String path;            // data-model path: "device.component.element"

    this(this) @disable;

    void flush()
    {
        if (_write_ticket || (_retry_at && getTime() < _retry_at))
            return;
        if (!cursor.pending)
            return;

        RecordBlock block = cursor.next(256);
        if (!block.count)
            return;
        ulong first = block.first_index;
        ulong end = first + block.count;
        uint ticket = g_record_io.write(file, block, &write_complete);
        cursor.seek(first);
        if (!ticket)
        {
            _retry_at = getTime() + 1.seconds;
            return;
        }
        _write_ticket = ticket;
        _write_end = end;
    }

    uint query(ulong from, ulong to, uint max_points, QueryMode mode,
               RecordQueryCallback callback)
    {
        Array!Sample live;
        collect_memory(cursor.eid.deref, from, to, live);
        return g_record_io.query(file, from, to, max_points, mode, live[], callback);
    }

    void close()
    {
        if (_write_ticket)
            g_record_io.cancel_write(_write_ticket);
        cursor.close();
        g_record_io.close(file);
        file = invalid_record_file;
        _write_ticket = 0;
    }

private:
    uint _write_ticket;
    ulong _write_end;
    MonoTime _retry_at;
    MonoTime _last_warning;

    void write_complete(uint ticket, bool success)
    {
        if (ticket != _write_ticket)
            return;
        if (success)
            cursor.seek(_write_end);
        else
        {
            MonoTime now = getTime();
            _retry_at = now + 1.seconds;
            if (!_last_warning || now - _last_warning >= 10.seconds)
            {
                log.warning("failed to write record stream '", path[], "'");
                _last_warning = now;
            }
        }
        _write_ticket = 0;
    }
}

private void collect_memory(Element* element, ulong from, ulong to, ref Array!Sample result)
{
    if (!element)
        return;
    ulong index = element.index_for_time(from_unix_time_ns(from));
    for (; index != ulong.max;)
    {
        RecordBlock block = element.read_records(index, 256);
        if (!block.count)
            break;
        bool past;
        foreach (i; 0 .. block.count)
        {
            ulong time = unixTimeNs(block.time(i));
            if (time > to)
            {
                past = true;
                break;
            }
            double value;
            Variant boxed = block.box(i);
            if (sample_to_double(boxed, value))
                result ~= Sample(time, value);
        }
        if (past)
            break;
        index += block.count;
    }
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
        if (!g_record_io.create_directory(_dir[]))
            return CompletionStatus.continue_;
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
        String filename = make_filename(path, ".owsig");
        rs.file = g_record_io.open(filename[]);
        if (rs.file == invalid_record_file)
        {
            rs.cursor.close();
            defaultAllocator().freeT(rs);
            return;
        }
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
    Array!uint tickets;
    Array!(Array!Sample) data;  // per-series samples
    ulong t0, t1;
    uint max_points;
    QueryMode mode;
    MonoTime started;
    uint outstanding;
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
        tickets.resize(n);
        data.resize(n);
        foreach (i; 0 .. n)
        {
            RecordStream* rs = streams[i];
            labels[][i] = rs.path[].makeString(defaultAllocator());
            tickets[][i] = 0;
            data[][i].clear();
            uint ticket = rs.query(t0, t1, max_points, mode, &query_complete);
            if (ticket)
            {
                tickets[][i] = ticket;
                ++outstanding;
            }
        }
        started = getTime();
        active = n > 0;
    }

    bool done()
    {
        if (!active || !outstanding)
            return true;
        if (getTime() - started <= 5.seconds)
            return false;
        cancel();
        return true;
    }

    void reset()
    {
        cancel();
        active = false;
        labels.clear();
        tickets.clear();
        data.clear();
    }

private:
    void query_complete(uint ticket, scope const(Sample)[] samples, bool)
    {
        foreach (i; 0 .. tickets.length)
        {
            if (tickets[i] != ticket)
                continue;
            data[][i] = samples;
            tickets[][i] = 0;
            if (outstanding)
                --outstanding;
            break;
        }
    }

    void cancel()
    {
        if (g_record_io)
            foreach (ticket; tickets[])
                if (ticket)
                    g_record_io.cancel_query(ticket);
        outstanding = 0;
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


// Base for record commands that render after the storage worker answers.
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
        g_record_io = defaultAllocator().allocT!RecordIO();
        if (!g_record_io.startup())
            log.error("record storage worker is unavailable");
        g_app.console.register_collection!Recorder();
        g_app.console.register_command!query_cmd("/record", this, "query");
        g_app.console.register_command!graph_cmd("/record", this, "graph");
    }

    override void deinit()
    {
        if (!g_record_io)
            return;
        g_record_io.shutdown();
        defaultAllocator().freeT(g_record_io);
        g_record_io = null;
    }

    override void update()
    {
        g_record_io.update();
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

    void cancel_query(uint ticket)
    {
        if (g_record_io)
            g_record_io.cancel_query(ticket);
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
