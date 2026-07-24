module manager.record_io;

import urt.array;
import urt.atomic;
import urt.map;
import urt.mem.allocator;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.sync.event;
import urt.sync.spsc;
import urt.thread;
import urt.time;
import urt.variant;

import manager.element : sample_to_double;
import manager.owsig;
import manager.series;

nothrow @nogc:


alias RecordFileId = uint;
enum RecordFileId invalid_record_file = 0;

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

alias RecordWriteCallback = void delegate(uint ticket, bool success) nothrow @nogc;
alias RecordQueryCallback = void delegate(uint ticket, scope const(Sample)[] samples, bool available) nothrow @nogc;

version (Windows)       enum record_io_threads = true;
else version (Posix)    enum record_io_threads = true;
else                    enum record_io_threads = false;

private enum uint request_capacity = 4096;
private enum uint completion_capacity = 512;

private enum RequestKind : ubyte
{
    create_directory,
    open,
    write,
    query,
    close,
}

private struct StorageFormat
{
    ValueType type;
    SeriesKind kind;
    ubyte count;
    uint rate;
    ScaledUnit unit;
}

private struct Request
{
    RequestKind kind;
    RecordFileId file;
    uint ticket;

    const(char)* path;
    uint path_length;

    StorageFormat format;
    ulong first_index;
    ulong t0;
    uint count;
    uint offsets_bytes;
    const(void)* payload;
    uint payload_bytes;

    ulong from;
    ulong to;
    uint max_points;
    QueryMode mode;
    const(Sample)* live;
    uint live_count;
}

private enum CompletionKind : ubyte
{
    write,
    query,
}

private struct Completion
{
    CompletionKind kind;
    uint ticket;
    bool success;
    bool available;
    const(Sample)* samples;
    uint count;
}

private struct RecordFile
{
    this(this) @disable;

    RecordFileId id;
    String path;
    SeriesContainer container;
    RecordFile* lru_prev;
    RecordFile* lru_next;
}

class RecordIO
{
nothrow @nogc:

    bool startup()
    {
        static if (!record_io_threads)
            return false;
        else
        {
            if (_running)
                return true;
            if (!_wake.init())
                return false;
            version (linux)
                _max_open = record_open_cap();
            atomicStore!(MemoryOrder.release)(_stop, false);
            _thread = thread_spawn(&worker_main);
            if (!_thread)
            {
                _wake.destroy();
                return false;
            }
            _running = true;
            return true;
        }
    }

    void shutdown()
    {
        if (!_running)
            return;

        _pending_writes.clear();
        _pending_queries.clear();
        _deferred_closes.clear();

        atomicStore!(MemoryOrder.release)(_stop, true);
        _wake.set();
        thread_join(_thread);
        _thread = null;

        drain_completions(false);
        foreach (ref c; _worker_completions[])
            release_completion(c);
        _worker_completions.clear();

        _wake.destroy();
        _running = false;
    }

    bool running() const pure
        => _running;

    bool create_directory(const(char)[] path)
    {
        if (!_running || path.empty)
            return false;

        void[] mem = defaultAllocator().alloc(path.length);
        if (!mem.ptr)
            return false;
        (cast(char[])mem)[] = path[];

        Request r;
        r.kind = RequestKind.create_directory;
        r.path = cast(const(char)*)mem.ptr;
        r.path_length = cast(uint)path.length;
        if (!send(r))
        {
            defaultAllocator().free(mem);
            return false;
        }
        wake();
        return true;
    }

    RecordFileId open(const(char)[] path)
    {
        if (!_running || path.empty)
            return invalid_record_file;

        void[] mem = defaultAllocator().alloc(path.length);
        if (!mem.ptr)
            return invalid_record_file;
        (cast(char[])mem)[] = path[];

        RecordFileId id = ++_next_file;
        if (id == invalid_record_file)
            id = ++_next_file;

        Request r;
        r.kind = RequestKind.open;
        r.file = id;
        r.path = cast(const(char)*)mem.ptr;
        r.path_length = cast(uint)path.length;
        if (!send(r))
        {
            defaultAllocator().free(mem);
            return invalid_record_file;
        }
        wake();
        return id;
    }

    void close(RecordFileId file)
    {
        if (file == invalid_record_file)
            return;
        if (!send_close(file))
            _deferred_closes ~= file;
        wake();
    }

    uint write(RecordFileId file, ref const RecordBlock block, RecordWriteCallback callback)
    {
        if (!_running || file == invalid_record_file || !block.count || callback is null)
            return 0;

        ref const DataFormat format = *block.data_format;
        if (!container_serialisable(format))
            return 0;

        uint offsets_bytes = block.ts ? block.count * cast(uint)uint.sizeof : 0;
        uint records_bytes = block.count * format.stride;
        uint payload_bytes = offsets_bytes + records_bytes;
        void[] mem = defaultAllocator().alloc(payload_bytes);
        if (!mem.ptr)
            return 0;
        ubyte[] payload = cast(ubyte[])mem;
        if (offsets_bytes)
            payload[0 .. offsets_bytes] =
                (cast(const(ubyte)*)block.ts)[0 .. offsets_bytes];
        payload[offsets_bytes .. $] =
            (cast(const(ubyte)*)block.data)[0 .. records_bytes];

        uint ticket = next_ticket();
        Request r;
        r.kind = RequestKind.write;
        r.file = file;
        r.ticket = ticket;
        r.format.type = format.type;
        r.format.kind = format.kind;
        r.format.count = format.count;
        r.format.rate = format.rate;
        if (format.desc == DataFormat.Desc.quantity)
            r.format.unit = format.unit;
        r.first_index = block.first_index;
        r.t0 = block.t0;
        r.count = block.count;
        r.offsets_bytes = offsets_bytes;
        r.payload = mem.ptr;
        r.payload_bytes = payload_bytes;
        if (!send(r))
        {
            defaultAllocator().free(mem);
            return 0;
        }
        _pending_writes.insert(ticket, callback);
        wake();
        return ticket;
    }

    uint query(RecordFileId file, ulong from, ulong to, uint max_points, QueryMode mode, scope const(Sample)[] live, RecordQueryCallback callback)
    {
        if (!_running || file == invalid_record_file || callback is null)
            return 0;

        const(Sample)* copy;
        if (live.length)
        {
            void[] mem = defaultAllocator().alloc(live.length * Sample.sizeof);
            if (!mem.ptr)
                return 0;
            Sample* dst = cast(Sample*)mem.ptr;
            dst[0 .. live.length] = live[];
            copy = dst;
        }

        uint ticket = next_ticket();
        Request r;
        r.kind = RequestKind.query;
        r.file = file;
        r.ticket = ticket;
        r.from = from;
        r.to = to;
        r.max_points = max_points;
        r.mode = mode;
        r.live = copy;
        r.live_count = cast(uint)live.length;
        if (!send(r))
        {
            if (copy)
                defaultAllocator().free(cast(void[])copy[0 .. live.length]);
            return 0;
        }
        _pending_queries.insert(ticket, callback);
        wake();
        return ticket;
    }

    void cancel_write(uint ticket)
    {
        if (ticket)
            _pending_writes.remove(ticket);
    }

    void cancel_query(uint ticket)
    {
        if (ticket)
            _pending_queries.remove(ticket);
    }

    void update()
    {
        if (!_running)
            return;

        for (size_t i = 0; i < _deferred_closes.length;)
        {
            if (!send_close(_deferred_closes[i]))
                break;
            _deferred_closes.remove(i);
        }
        if (!_requests.empty)
            wake();
        drain_completions(true);
    }

private:
    SPSCRing!(Request, request_capacity) _requests;
    SPSCRing!(Completion, completion_capacity) _completions;
    Map!(uint, RecordWriteCallback) _pending_writes;
    Map!(uint, RecordQueryCallback) _pending_queries;
    Array!RecordFileId _deferred_closes;
    uint _next_file;
    uint _next_ticket;

    bool _running;
    Thread _thread;
    Event _wake;
    shared bool _stop;

    Map!(RecordFileId, RecordFile*) _files;
    RecordFile* _lru_head;
    RecordFile* _lru_tail;
    size_t _open_count;
    size_t _max_open = 2048;
    Array!Completion _worker_completions;

    uint next_ticket()
    {
        uint ticket = ++_next_ticket;
        if (!ticket)
            ticket = ++_next_ticket;
        return ticket;
    }

    bool send(ref Request request)
    {
        Request* slot = _requests.reserve();
        if (!slot)
            return false;
        *slot = request;
        _requests.commit();
        return true;
    }

    bool send_close(RecordFileId file)
    {
        Request r;
        r.kind = RequestKind.close;
        r.file = file;
        return send(r);
    }

    void wake()
    {
        _wake.set();
    }

    void worker_main()
    {
        for (;;)
        {
            _wake.reset();
            bool did = drive();
            if (atomicLoad!(MemoryOrder.acquire)(_stop) && _requests.empty)
                break;
            if (!did)
                _wake.wait(100.msecs);
        }
        drive();
        close_all_files();
    }

    bool drive()
    {
        bool did = flush_worker_completions();
        Request[32] requests = void;
        for (;;)
        {
            size_t n = _requests.pop(requests[]);
            if (!n)
                break;
            did = true;
            foreach (ref r; requests[0 .. n])
                service(r);
            flush_worker_completions();
        }
        return did;
    }

    void service(ref const Request r)
    {
        final switch (r.kind)
        {
            case RequestKind.create_directory:
                service_create_directory(r);
                break;
            case RequestKind.open:
                service_open(r);
                break;
            case RequestKind.write:
                service_write(r);
                break;
            case RequestKind.query:
                service_query(r);
                break;
            case RequestKind.close:
                service_close(r.file);
                break;
        }
    }

    void service_create_directory(ref const Request r)
    {
        import urt.file : make_record_directory = create_directory;

        make_record_directory(r.path[0 .. r.path_length]);
        defaultAllocator().free(cast(void[])r.path[0 .. r.path_length]);
    }

    void service_open(ref const Request r)
    {
        if (r.file in _files)
        {
            defaultAllocator().free(cast(void[])r.path[0 .. r.path_length]);
            return;
        }
        RecordFile* file = defaultAllocator().allocT!RecordFile();
        file.id = r.file;
        file.path = r.path[0 .. r.path_length].makeString(defaultAllocator());
        defaultAllocator().free(cast(void[])r.path[0 .. r.path_length]);
        _files.insert(file.id, file);
    }

    void service_write(ref const Request r)
    {
        bool success;
        if (RecordFile** p = r.file in _files)
        {
            RecordFile* file = *p;
            if (ensure_open(file))
            {
                RecordBlock block;
                block.first_index = r.first_index;
                block.t0 = r.t0;
                block.ts = r.offsets_bytes ? cast(const(uint)*)r.payload : null;
                block.data = cast(const(ubyte)*)r.payload + r.offsets_bytes;
                block.count = r.count;
                DataFormat format = r.format.unit != ScaledUnit()
                    ? DataFormat(r.format.type, r.format.kind, r.format.unit)
                    : DataFormat(r.format.type, r.format.kind);
                format.count = r.format.count;
                format.rate = r.format.rate;
                success = file.container.put(format, block);
                touch(file);
            }
        }

        defaultAllocator().free(cast(void[])r.payload[0 .. r.payload_bytes]);
        Completion c;
        c.kind = CompletionKind.write;
        c.ticket = r.ticket;
        c.success = success;
        _worker_completions ~= c;
    }

    void service_query(ref const Request r)
    {
        Array!Sample merged;
        bool available;
        if (RecordFile** p = r.file in _files)
        {
            RecordFile* file = *p;
            if (ensure_open(file))
            {
                ulong live_start = r.live_count ? r.live[0].time : ulong.max;
                read_archive(*file, r.from, r.to, live_start, merged);
                touch(file);
            }
        }
        if (r.live_count)
        {
            merged.reserve(merged.length + r.live_count);
            foreach (ref const s; r.live[0 .. r.live_count])
                merged ~= s;
        }
        available = merged.length != 0;

        Array!Sample result;
        reduce_samples(merged[], r.from, r.to, r.max_points, r.mode, result);

        Completion c;
        c.kind = CompletionKind.query;
        c.ticket = r.ticket;
        c.available = available;
        c.count = cast(uint)result.length;
        if (c.count)
        {
            void[] mem = defaultAllocator().alloc(c.count * Sample.sizeof);
            if (mem.ptr)
            {
                Sample* dst = cast(Sample*)mem.ptr;
                dst[0 .. c.count] = result[];
                c.samples = dst;
            }
            else
            {
                c.count = 0;
                c.available = false;
            }
        }
        _worker_completions ~= c;

        if (r.live)
            defaultAllocator().free(cast(void[])r.live[0 .. r.live_count]);
    }

    void service_close(RecordFileId id)
    {
        RecordFile** p = id in _files;
        if (!p)
            return;
        RecordFile* file = *p;
        close_file(file);
        _files.remove(id);
        defaultAllocator().freeT(file);
    }

    bool ensure_open(RecordFile* file)
    {
        if (file.container.is_open)
        {
            touch(file);
            return true;
        }
        while (_open_count >= _max_open && _lru_tail)
            close_file(_lru_tail);
        if (!file.container.open_(file.path[]))
            return false;
        ++_open_count;
        link_front(file);
        return true;
    }

    void touch(RecordFile* file)
    {
        if (_lru_head is file)
            return;
        unlink(file);
        link_front(file);
    }

    void link_front(RecordFile* file)
    {
        file.lru_prev = null;
        file.lru_next = _lru_head;
        if (_lru_head)
            _lru_head.lru_prev = file;
        else
            _lru_tail = file;
        _lru_head = file;
    }

    void unlink(RecordFile* file)
    {
        if (file.lru_prev)
            file.lru_prev.lru_next = file.lru_next;
        else if (_lru_head is file)
            _lru_head = file.lru_next;
        if (file.lru_next)
            file.lru_next.lru_prev = file.lru_prev;
        else if (_lru_tail is file)
            _lru_tail = file.lru_prev;
        file.lru_prev = null;
        file.lru_next = null;
    }

    void close_file(RecordFile* file)
    {
        if (!file.container.is_open)
            return;
        unlink(file);
        file.container.close_();
        --_open_count;
    }

    void close_all_files()
    {
        foreach (file; _files.values)
        {
            close_file(file);
            defaultAllocator().freeT(file);
        }
        _files.clear();
        _lru_head = null;
        _lru_tail = null;
        _open_count = 0;
    }

    void read_archive(ref RecordFile file, ulong from, ulong to, ulong live_start, ref Array!Sample result)
    {
        SeriesContainer* container = &file.container;
        if (!container.dir.length)
            return;

        size_t bi = container.find_by_time(from / 1000);
        if (bi == container.dir.length)
            --bi;
        else if (bi)
            --bi;

        outer: for (; bi < container.dir.length; ++bi)
        {
            if (container.dir[bi].hdr.first_tick * 1000 > to)
                break;
            RecordBlock block;
            DataFormat format;
            if (!container.load_raw(bi, block, format))
                break;
            foreach (i; 0 .. block.count)
            {
                ulong time = (block.t0 + (block.ts ? block.ts[i] : i)) * 1000;
                if (time >= live_start || time > to)
                    break outer;
                double value;
                Variant boxed = box_record(cast(const(ubyte)*)block.data + i * format.stride,
                                           format);
                if (sample_to_double(boxed, value))
                    result ~= Sample(time, value);
            }
        }
    }

    bool flush_worker_completions()
    {
        bool did = false;
        while (_worker_completions.length)
        {
            Completion* slot = _completions.reserve();
            if (!slot)
                break;
            *slot = _worker_completions[0];
            _completions.commit();
            _worker_completions.remove(0);
            did = true;
        }
        return did;
    }

    void drain_completions(bool deliver)
    {
        Completion[32] completions = void;
        for (;;)
        {
            size_t n = _completions.pop(completions[]);
            if (!n)
                break;
            foreach (ref c; completions[0 .. n])
            {
                final switch (c.kind)
                {
                    case CompletionKind.write:
                        if (RecordWriteCallback* callback = c.ticket in _pending_writes)
                        {
                            if (deliver)
                                (*callback)(c.ticket, c.success);
                            _pending_writes.remove(c.ticket);
                        }
                        break;

                    case CompletionKind.query:
                        if (RecordQueryCallback* callback = c.ticket in _pending_queries)
                        {
                            if (deliver)
                                (*callback)(c.ticket,
                                    c.count ? c.samples[0 .. c.count] : null, c.available);
                            _pending_queries.remove(c.ticket);
                        }
                        break;
                }
                release_completion(c);
            }
        }
    }

    static void release_completion(ref Completion completion)
    {
        if (completion.samples)
            defaultAllocator().free(cast(void[])completion.samples[0 .. completion.count]);
        completion.samples = null;
        completion.count = 0;
    }
}


private struct SampleAggregator
{
nothrow @nogc:

    Array!Sample* sink;
    ulong from;
    ulong bucket_width;
    ulong bucket = ulong.max;
    double sum = 0;
    ulong last_time;
    uint count;

    void put(ref const Sample sample)
    {
        if (!bucket_width)
        {
            *sink ~= sample;
            return;
        }
        ulong b = (sample.time - from) / bucket_width;
        if (b != bucket)
        {
            emit();
            bucket = b;
        }
        sum += sample.value;
        last_time = sample.time;
        ++count;
    }

    void finish()
    {
        emit();
    }

    void emit()
    {
        if (!count)
            return;
        *sink ~= Sample(last_time, sum / count);
        sum = 0;
        count = 0;
    }
}

private struct GraphIntervalSampler
{
nothrow @nogc:

    Array!Sample* sink;
    ulong from;
    ulong to;
    ulong bucket_width;
    ulong bucket = ulong.max;
    ulong bucket_time;
    double sum = 0;
    ulong duration;
    ulong last_time;
    double last_value;
    bool has_value;
    bool seeded;
    bool emitted;

    void seed(ref const Sample sample)
    {
        last_time = from;
        last_value = sample.value;
        has_value = true;
        seeded = true;
    }

    void put(ref const Sample sample)
    {
        if (!bucket_width)
        {
            *sink ~= sample;
            return;
        }

        ulong time = sample.time;
        if (time < from)
            return;
        if (time > to)
            time = to;
        if (has_value)
            accumulate(last_time, time, last_value);
        last_time = time;
        last_value = sample.value;
        has_value = true;
    }

    void finish()
    {
        if (!bucket_width)
            return;
        if (has_value)
            accumulate(last_time, to, last_value);
        emit();
    }

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
            if (b != bucket)
            {
                emit();
                bucket = b;
                ulong bucket_start = from + b * bucket_width;
                bucket_time = (seeded || emitted || start <= bucket_start)
                    ? bucket_start : start;
            }

            ulong bucket_end = from + (b + 1) * bucket_width;
            ulong stop = end < bucket_end ? end : bucket_end;
            ulong dt = stop - start;
            sum += value * cast(double)dt;
            duration += dt;
            start = stop;
        }
    }

    void emit()
    {
        if (!duration)
            return;
        *sink ~= Sample(bucket_time, sum / cast(double)duration);
        sum = 0;
        duration = 0;
        emitted = true;
    }
}

private void reduce_samples(scope const(Sample)[] samples, ulong from, ulong to, uint max_points, QueryMode mode, ref Array!Sample result)
{
    if (!samples.length)
        return;

    ulong bucket_width = max_points ? (to - from) / max_points + 1 : 0;
    if (mode == QueryMode.graph)
    {
        Sample held;
        bool has_held;
        foreach (ref const sample; samples)
        {
            if (sample.time >= from)
                break;
            held = sample;
            has_held = true;
        }
        ulong hold_limit = bucket_width ? bucket_width : to - from;
        has_held = has_held && from - held.time <= hold_limit;

        if (!bucket_width)
        {
            if (has_held)
                result ~= Sample(from, held.value);
            foreach (ref const sample; samples)
                if (sample.time >= from && sample.time <= to)
                    result ~= sample;
        }
        else
        {
            GraphIntervalSampler sampler;
            sampler.sink = &result;
            sampler.from = from;
            sampler.to = to;
            sampler.bucket_width = bucket_width;
            if (has_held)
                sampler.seed(held);
            foreach (ref const sample; samples)
            {
                if (sample.time < from)
                    continue;
                if (sample.time > to)
                    break;
                sampler.put(sample);
            }
            sampler.finish();
        }
        return;
    }

    SampleAggregator aggregator;
    aggregator.sink = &result;
    aggregator.from = from;
    aggregator.bucket_width = bucket_width;
    foreach (ref const sample; samples)
    {
        if (sample.time < from)
            continue;
        if (sample.time > to)
            break;
        aggregator.put(sample);
    }
    aggregator.finish();
}


unittest
{
    Array!Sample reduced;
    SampleAggregator average;
    average.sink = &reduced;
    average.from = 0;
    average.bucket_width = 10;
    average.put(Sample(1, 1));
    average.put(Sample(5, 3));
    average.put(Sample(12, 10));
    average.finish();
    assert(reduced.length == 2);
    assert(reduced[0].time == 5 && reduced[0].value == 2);
    assert(reduced[1].time == 12 && reduced[1].value == 10);

    reduced.clear();
    GraphIntervalSampler graph;
    graph.sink = &reduced;
    graph.from = 0;
    graph.to = 100;
    graph.bucket_width = 25;
    Sample seed = Sample(0, 10);
    graph.seed(seed);
    graph.put(Sample(40, 20));
    graph.put(Sample(90, 30));
    graph.finish();
    assert(reduced.length == 4);
    assert(reduced[0].time == 0);
    assert(reduced[1].time == 25);
    assert(reduced[2].time == 50);
    assert(reduced[3].time == 75);

    static if (record_io_threads)
    {
        import urt.file : delete_file, get_temp_filename;
        import urt.mem.allocator : defaultAllocator;
        import urt.time : from_unix_time_ns;
        import manager.element;

        static struct Sink
        {
            bool wrote;
            bool write_ok;
            bool queried;
            bool available;
            Array!Sample samples;

            void on_write(uint, bool success) nothrow @nogc
            {
                wrote = true;
                write_ok = success;
            }

            void on_query(uint, scope const(Sample)[] result, bool available_) nothrow @nogc
            {
                samples = result;
                available = available_;
                queried = true;
            }
        }

        char[320] path_buffer = void;
        char[] path = path_buffer[];
        assert(get_temp_filename(path, "", "owsig-worker"));
        delete_file(path);

        RecordIO io = defaultAllocator().allocT!RecordIO();
        assert(io.startup());
        RecordFileId file = io.open(path);
        assert(file != invalid_record_file);

        static immutable DataFormat format = DataFormat(ValueType.f64, SeriesKind.held);
        Element element;
        element.format = register_format(format);
        element.ensure_history();
        foreach (i; 0 .. 8)
            element.write_sample(i * 2.0, from_unix_time_ns((i + 1) * 1_000_000UL));
        Cursor cursor = element.open_series_cursor(0);
        RecordBlock block = cursor.next(16);

        Sink sink;
        assert(io.write(file, block, &sink.on_write));
        foreach (_; 0 .. 2_000_000)
        {
            io.update();
            if (sink.wrote)
                break;
        }
        assert(sink.wrote && sink.write_ok);

        assert(io.query(file, 0, 20_000_000, 0, QueryMode.raw, null,
                        &sink.on_query));
        foreach (_; 0 .. 2_000_000)
        {
            io.update();
            if (sink.queried)
                break;
        }
        assert(sink.queried && sink.available);
        assert(sink.samples.length == 8);
        assert(sink.samples[0].value == 0 && sink.samples[7].value == 14);

        sink.queried = false;
        Sample[3] live = [Sample(7_000_000, 12), Sample(8_000_000, 14),
                          Sample(9_000_000, 16)];
        assert(io.query(file, 0, 20_000_000, 0, QueryMode.raw, live[],
                        &sink.on_query));
        foreach (_; 0 .. 2_000_000)
        {
            io.update();
            if (sink.queried)
                break;
        }
        assert(sink.queried && sink.available);
        assert(sink.samples.length == 9);
        assert(sink.samples[5].value == 10 && sink.samples[8].value == 16);

        io.close(file);
        io.shutdown();
        defaultAllocator().freeT(io);
        element.close_series_cursor(cursor);
        element.teardown();
        delete_file(path);
    }
}


private:

version (linux)
{
    extern(C) int getrlimit(int resource, rlimit_t* rlim) nothrow @nogc;
    struct rlimit_t { ulong rlim_cur; ulong rlim_max; }
    enum int RLIMIT_NOFILE_ = 7;

    size_t record_open_cap()
    {
        rlimit_t limit;
        if (getrlimit(RLIMIT_NOFILE_, &limit) != 0)
            return 2048;
        enum ulong reserve = 512;
        if (limit.rlim_cur <= reserve + 64)
            return 64;
        return cast(size_t)(limit.rlim_cur - reserve);
    }
}
