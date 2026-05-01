module router.stream.memory;

import urt.array;
import urt.atomic;
import urt.string;
import urt.string.format;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.stream;

nothrow @nogc:


enum MemoryMode : ubyte
{
    none,     // unconfigured side
    dynamic,  // TX only - growable buffer (for capture/testing)
    buffer,   // caller-owned fixed buffer, linear cursor, no wrap
    fifo,     // caller-owned shared-mem ring; cursors live at buffer extents
}


// Shared-memory FIFO layout (for MemoryMode.fifo):
//   buf[0 .. 4]    - read index  (consumer-owned, monotonic u32)
//   buf[$-4 .. $]  - write index (producer-owned, monotonic u32)
//   buf[4 .. $-4]  - data region
// Cursors are placed at opposite extents so they land on separate cache
// lines naturally, avoiding false sharing between producer and consumer.
// Indices are monotonic; arithmetic is correct modulo 2^32 as long as
// capacity < 2^31.

enum fifo_overhead = 8;


class MemoryStream : Stream
{
    alias Properties = AliasSeq!(Prop!("tx-mode", tx_mode),
                                 Prop!("tx-ptr", tx_ptr),
                                 Prop!("tx-size", tx_size),
                                 Prop!("rx-mode", rx_mode),
                                 Prop!("rx-ptr", rx_ptr),
                                 Prop!("rx-size", rx_size));
nothrow @nogc:

    enum type_name = "memory";
    enum path = "/stream/memory";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!MemoryStream, id, flags, StreamOptions.none);
    }

    // Properties

    final MemoryMode tx_mode() const pure => _tx_mode;
    final void tx_mode(MemoryMode value)
    {
        if (value == _tx_mode)
            return;
        _tx_mode = value;
        restart();
    }

    final size_t tx_ptr() const pure => cast(size_t)_tx.ptr;
    final void tx_ptr(size_t value)
    {
        auto p = cast(ubyte*)value;
        if (p is _tx.ptr)
            return;
        _tx = p[0 .. _tx.length];
        restart();
    }

    final size_t tx_size() const pure => _tx.length;
    final void tx_size(size_t value)
    {
        if (value == _tx.length)
            return;
        _tx = _tx.ptr[0 .. value];
        restart();
    }

    final MemoryMode rx_mode() const pure => _rx_mode;
    final void rx_mode(MemoryMode value)
    {
        if (value == _rx_mode)
            return;
        _rx_mode = value;
        restart();
    }

    final size_t rx_ptr() const pure => cast(size_t)_rx.ptr;
    final void rx_ptr(size_t value)
    {
        auto p = cast(ubyte*)value;
        if (p is _rx.ptr)
            return;
        _rx = p[0 .. _rx.length];
        restart();
    }

    final size_t rx_size() const pure => _rx.length;
    final void rx_size(size_t value)
    {
        if (value == _rx.length)
            return;
        _rx = _rx.ptr[0 .. value];
        restart();
    }

    // API

    // Captured output in dynamic TX mode. Empty otherwise.
    final const(ubyte)[] captured() const pure
        => _dynamic[];

    override const(char)[] remote_name()
        => "memory";

    override ptrdiff_t read(void[] buffer)
    {
        ubyte[] dst = cast(ubyte[])buffer;
        size_t got;
        final switch (_rx_mode)
        {
            case MemoryMode.none:
            case MemoryMode.dynamic:
                return 0;

            case MemoryMode.buffer:
                size_t available = _rx.length - _rx_cursor;
                got = available < dst.length ? available : dst.length;
                dst[0 .. got] = (cast(ubyte[])_rx)[_rx_cursor .. _rx_cursor + got];
                _rx_cursor += got;
                break;

            case MemoryMode.fifo:
                got = fifo_read(_rx, dst);
                break;
        }
        if (got)
        {
            add_rx_bytes(got);
            if (_logging)
                write_to_log(true, dst[0 .. got]);
        }
        return got;
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        size_t total;
        final switch (_tx_mode)
        {
            case MemoryMode.none:
                return 0;

            case MemoryMode.dynamic:
                foreach (d; data)
                {
                    _dynamic ~= cast(ubyte[])d;
                    total += d.length;
                }
                break;

            case MemoryMode.buffer:
                ubyte[] buf = cast(ubyte[])_tx;
                foreach (d; data)
                {
                    size_t remain = buf.length - _tx_cursor;
                    if (remain == 0)
                        break;
                    size_t take = d.length < remain ? d.length : remain;
                    buf[_tx_cursor .. _tx_cursor + take] = cast(const(ubyte)[])d[0 .. take];
                    _tx_cursor += take;
                    total += take;
                    if (take < d.length)
                        break;
                }
                break;

            case MemoryMode.fifo:
                foreach (d; data)
                {
                    size_t w = fifo_write(_tx, cast(const(ubyte)[])d);
                    total += w;
                    if (w < d.length)
                        break;
                }
                break;
        }
        if (total)
        {
            add_tx_bytes(total);
            if (_logging)
            {
                size_t remain = total;
                foreach (d; data)
                {
                    if (remain == 0)
                        break;
                    size_t chunk = d.length < remain ? d.length : remain;
                    write_to_log(false, d[0 .. chunk]);
                    remain -= chunk;
                }
            }
        }
        return total;
    }

    override ptrdiff_t pending()
    {
        final switch (_rx_mode)
        {
            case MemoryMode.none:
            case MemoryMode.dynamic:
                return 0;
            case MemoryMode.buffer:
                return _rx.length - _rx_cursor;
            case MemoryMode.fifo:
                return fifo_used(_rx);
        }
    }

    override ptrdiff_t flush()
    {
        final switch (_rx_mode)
        {
            case MemoryMode.none:
            case MemoryMode.dynamic:
                return 0;
            case MemoryMode.buffer:
                size_t n = _rx.length - _rx_cursor;
                _rx_cursor = _rx.length;
                return n;
            case MemoryMode.fifo:
                uint w = fifo_load_write(_rx);
                uint r = fifo_load_read(_rx);
                fifo_store_read(_rx, w);
                return cast(uint)(w - r);
        }
    }

protected:
    override bool validate() const pure
    {
        if (_tx_mode == MemoryMode.none && _rx_mode == MemoryMode.none)
            return false;
        if (_rx_mode == MemoryMode.dynamic)
            return false;
        if (_tx_mode == MemoryMode.buffer || _tx_mode == MemoryMode.fifo)
        {
            if (_tx.ptr is null || _tx.length == 0)
                return false;
            if (_tx_mode == MemoryMode.fifo && _tx.length <= fifo_overhead)
                return false;
        }
        if (_rx_mode == MemoryMode.buffer || _rx_mode == MemoryMode.fifo)
        {
            if (_rx.ptr is null || _rx.length == 0)
                return false;
            if (_rx_mode == MemoryMode.fifo && _rx.length <= fifo_overhead)
                return false;
        }
        return true;
    }

    override CompletionStatus startup()
    {
        _tx_cursor = 0;
        _rx_cursor = 0;
        _dynamic.clear();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

private:
    MemoryMode _tx_mode;
    MemoryMode _rx_mode;

    void[] _tx;
    void[] _rx;

    size_t _tx_cursor;  // buffer mode: write position
    size_t _rx_cursor;  // buffer mode: read position

    Array!ubyte _dynamic;  // dynamic TX mode: owned output

    // FIFO cursor accessors - cursors sit at buf[0] (read) and buf[$-4] (write).

    static uint fifo_load_read(const void[] buf)
        => atomic_load!(MemoryOrder.acquire)(*cast(shared(uint)*)buf.ptr);

    static uint fifo_load_write(const void[] buf)
        => atomic_load!(MemoryOrder.acquire)(*cast(shared(uint)*)(buf.ptr + buf.length - 4));

    static void fifo_store_read(void[] buf, uint v)
        => atomic_store!(MemoryOrder.release)(*cast(shared(uint)*)buf.ptr, v);

    static void fifo_store_write(void[] buf, uint v)
        => atomic_store!(MemoryOrder.release)(*cast(shared(uint)*)(buf.ptr + buf.length - 4), v);

    static uint fifo_capacity(const void[] buf)
        => cast(uint)(buf.length - fifo_overhead);

    static uint fifo_used(const void[] buf)
    {
        uint r = fifo_load_read(buf);
        uint w = fifo_load_write(buf);
        return w - r;  // modulo 2^32 - correct as long as capacity < 2^31
    }

    static size_t fifo_read(void[] buf, ubyte[] dst)
    {
        uint cap = fifo_capacity(buf);
        uint r = fifo_load_read(buf);
        uint w = fifo_load_write(buf);
        uint used = w - r;
        size_t got = used < dst.length ? used : dst.length;
        ubyte* data = cast(ubyte*)buf.ptr + 4;
        size_t head = r % cap;
        size_t first = cap - head;
        if (first >= got)
        {
            dst[0 .. got] = data[head .. head + got];
        }
        else
        {
            dst[0 .. first] = data[head .. cap];
            dst[first .. got] = data[0 .. got - first];
        }
        fifo_store_read(buf, r + cast(uint)got);
        return got;
    }

    static size_t fifo_write(void[] buf, const(ubyte)[] src)
    {
        uint cap = fifo_capacity(buf);
        uint r = fifo_load_read(buf);
        uint w = fifo_load_write(buf);
        uint free = cap - (w - r);
        size_t put = src.length < free ? src.length : free;
        ubyte* data = cast(ubyte*)buf.ptr + 4;
        size_t head = w % cap;
        size_t first = cap - head;
        if (first >= put)
        {
            data[head .. head + put] = src[0 .. put];
        }
        else
        {
            data[head .. cap] = src[0 .. first];
            data[0 .. put - first] = src[first .. put];
        }
        fifo_store_write(buf, w + cast(uint)put);
        return put;
    }
}


class MemoryStreamModule : Module
{
    mixin DeclareModule!"stream.memory";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!MemoryMode();
        g_app.console.register_collection!MemoryStream();
    }
}


unittest
{
    // Exercise the static FIFO helpers directly. They hold the subtle
    // correctness invariants (cursor-at-extents layout, modulo-2^32
    // index arithmetic, wrap-around copy split). Stream-level tests
    // belong with the integration harness, not here.

    // Small ring: 8 bytes overhead + 16 bytes data = 24-byte buffer.
    align(4) ubyte[24] buf;

    void reset()
    {
        buf[] = 0;
    }

    uint read_idx() => *cast(uint*)&buf[0];
    uint write_idx() => *cast(uint*)&buf[buf.sizeof - 4];

    // --- basic round-trip ---
    reset();
    {
        ubyte[5] src = [1, 2, 3, 4, 5];
        size_t w = MemoryStream.fifo_write(buf[], src[]);
        assert(w == 5);
        assert(MemoryStream.fifo_used(buf[]) == 5);

        ubyte[5] dst;
        size_t r = MemoryStream.fifo_read(buf[], dst[]);
        assert(r == 5);
        assert(dst[] == src[]);
        assert(MemoryStream.fifo_used(buf[]) == 0);
    }

    // --- fill to capacity, overflow is rejected ---
    reset();
    {
        ubyte[20] src;
        foreach (i, ref b; src) b = cast(ubyte)(i + 0x10);

        // capacity is 16
        size_t w = MemoryStream.fifo_write(buf[], src[]);
        assert(w == 16);
        assert(MemoryStream.fifo_used(buf[]) == 16);

        // another write returns 0 - ring full
        ubyte[1] extra = [0xFF];
        assert(MemoryStream.fifo_write(buf[], extra[]) == 0);

        ubyte[16] dst;
        size_t r = MemoryStream.fifo_read(buf[], dst[]);
        assert(r == 16);
        assert(dst[] == src[0 .. 16]);
    }

    // --- empty read ---
    reset();
    {
        ubyte[4] dst;
        assert(MemoryStream.fifo_read(buf[], dst[]) == 0);
    }

    // --- partial read leaves remainder ---
    reset();
    {
        ubyte[10] src = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        MemoryStream.fifo_write(buf[], src[]);

        ubyte[4] dst;
        assert(MemoryStream.fifo_read(buf[], dst[]) == 4);
        assert(dst[] == src[0 .. 4]);
        assert(MemoryStream.fifo_used(buf[]) == 6);

        ubyte[6] rest;
        assert(MemoryStream.fifo_read(buf[], rest[]) == 6);
        assert(rest[] == src[4 .. 10]);
    }

    // --- wrap-around: producer and consumer indices advance past `cap` ---
    reset();
    {
        // Advance indices to force wrap: write 10, read 10, then write 10 more.
        // After this the write cursor ends at position 20, which wraps past cap=16.
        ubyte[10] a;
        foreach (i, ref b; a) b = cast(ubyte)(0x20 + i);
        ubyte[10] b_src;
        foreach (i, ref b; b_src) b = cast(ubyte)(0x40 + i);

        MemoryStream.fifo_write(buf[], a[]);
        ubyte[10] junk;
        MemoryStream.fifo_read(buf[], junk[]);
        assert(junk[] == a[]);

        // Now write 10 more - this straddles the end of the data region.
        size_t w = MemoryStream.fifo_write(buf[], b_src[]);
        assert(w == 10);

        ubyte[10] out_;
        size_t r = MemoryStream.fifo_read(buf[], out_[]);
        assert(r == 10);
        assert(out_[] == b_src[]);

        // Indices are monotonic - not reset on wrap.
        assert(write_idx() == 20);
        assert(read_idx() == 20);
    }

    // --- many round-trips exercise repeated wrap ---
    reset();
    {
        ubyte[7] src = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6];
        foreach (iter; 0 .. 20)
        {
            // nudge the pattern each iteration so we catch stale-data bugs
            ubyte[7] s = src;
            foreach (ref b; s) b = cast(ubyte)(b + iter);

            size_t w = MemoryStream.fifo_write(buf[], s[]);
            assert(w == 7);

            ubyte[7] d;
            size_t r = MemoryStream.fifo_read(buf[], d[]);
            assert(r == 7);
            assert(d[] == s[]);
        }
        // 20 iterations * 7 bytes = 140 - cursor has wrapped through the
        // 16-byte region many times over.
        assert(write_idx() == 140);
        assert(read_idx() == 140);
    }
}
