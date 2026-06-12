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
import manager.device;
import manager.element;
import manager.plugin;

nothrow @nogc:


alias log = Log!"record";


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
        MutableString!0 prefix;

        void walk(Component c)
        {
            size_t reset = prefix.length;
            scope(exit) prefix.erase(reset, prefix.length - reset);
            if (reset)
                prefix ~= '.';
            prefix ~= c.id[];

            foreach (Element* e; c.elements)
            {
                size_t e_reset = prefix.length;
                scope(exit) prefix.erase(e_reset, prefix.length - e_reset);
                prefix.append('.', e.id[]);
                if (prefix[] !in _streams && wildcard_match(_filter[], prefix[]))
                    attach(e, prefix[]);
            }

            foreach (Component child; c.components)
                walk(child);
        }

        foreach (device; g_app.devices.values)
            walk(device);
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


private void read_file_range(ref RecordStream rs, ulong from, ulong end, ref SampleAggregator agg)
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
