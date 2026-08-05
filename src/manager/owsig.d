module manager.owsig;

// owsig v0: raw-image series container. The file is a doubly-linked block list: each block
// header carries next/prev file offsets and its index/timestamp span; the first block of a
// format run additionally carries a BlockFormatHeader (and, later, name-binding data for
// enum/user/codec identity) behind it, and followers point at that anchor via format_block,
// so a format change just starts a new run and stable runs skip the repeat noise. The
// runtime keeps the headers as an in-memory directory with the format resolved per entry,
// so time-seek is a binary search and recall is: load one block's payload, view it in place
// as a RecordBlock (byte-identical to the RAM image).
//
// Dynamic-record series (text) serialise as their RAM image: fixed-stride u16 offset records
// plus a trailing byte heap. put() compacts the heap per block - only entries the block's
// records reference ship, dedup'd by content, offsets rebased - since a cursor block may
// cover a slice of a bucket whose heap holds more than it references.
//
// Not serialisable yet: user types and enum identity (need name binding), domain-clocked
// series (need anchor blocks for the clock).

import urt.array;
import urt.file;
import urt.si.unit : ScaledUnit;

import manager.series;

nothrow @nogc:


bool container_serialisable(ref const DataFormat f)
    => f.clock is null && f.type != ValueType.user;

struct FileHeader
{
    char[4] magic = "OWSG";
    ubyte version_ = 1;
    ubyte pad;
    ushort header_bytes = FileHeader.sizeof;  // offset of the first block; the header may grow
    ubyte[8] reserved;
}
static assert(FileHeader.sizeof == 16);

struct BlockHeader
{
nothrow @nogc:

    ulong next;          // file offset of the next block; 0 = tail
    ulong prev;          // file offset of the previous block; 0 = head
    ulong format_block;  // first block of this format run; 0 = this block anchors (BlockFormatHeader follows)
    ulong first_index;
    ulong last_index;    // inclusive
    ulong first_tick;    // usecs; also the time base of the offsets plane
    ulong last_tick;     // inclusive
    uint payload_bytes;
    ushort header_bytes; // offset from block start to the payload; covers any format header and extensions
    ubyte flags;         // Flags
    ubyte codec;
    uint heap_bytes;     // dynamic-record series: byte heap trailing the record plane
    ubyte[4] reserved;

    enum Flags : ubyte
    {
        irregular   = 1 << 0,  // offsets plane precedes the records
        follows_gap = 1 << 1,
    }

    uint count() const pure
        => cast(uint)(last_index - first_index + 1);
}
static assert(BlockHeader.sizeof == 72);

// follows BlockHeader on format-anchor blocks; name-binding data (enum/user/codec identity)
// follows the fixed part, all within BlockHeader.header_bytes
struct BlockFormatHeader
{
    ulong unit;          // ScaledUnit image; 0 = none
    uint rate;
    ushort header_bytes = BlockFormatHeader.sizeof;  // fixed part; names follow
    ushort stride;
    ubyte type;          // ValueType
    ubyte kind;
    ubyte count;
    ubyte[5] reserved;
}
static assert(BlockFormatHeader.sizeof == 24);

struct BlockEntry
{
nothrow @nogc:

    ulong offset;
    BlockHeader hdr;
    BlockFormatHeader fmt;  // resolved for every entry; anchors own it, followers copy their run's

    uint raw_bytes() const pure
        => cast(uint)(((hdr.flags & BlockHeader.Flags.irregular) ? hdr.count * uint.sizeof : 0) + hdr.count * fmt.stride + hdr.heap_bytes);
}

struct SeriesContainer
{
nothrow @nogc:

    Array!BlockEntry dir;

    bool is_open() const pure
        => _open;

    bool open_(const(char)[] path)
    {
        assert(!_open);
        if (urt.file.open(_file, path, FileOpenMode.ReadWrite) != Result.success)
            return false;
        _open = true;

        FileHeader fh;
        size_t bytes;
        if (read_at(_file, (cast(void*)&fh)[0 .. FileHeader.sizeof], 0, bytes) != Result.success
            || bytes < FileHeader.sizeof)
        {
            // new file
            fh = FileHeader.init;
            if (write_at(_file, (cast(const(void)*)&fh)[0 .. FileHeader.sizeof], 0, bytes) != Result.success)
            {
                close_();
                return false;
            }
            _end = FileHeader.sizeof;
            return true;
        }
        if (fh.magic != "OWSG" || fh.version_ != 1)
        {
            close_();
            return false;
        }

        // walk the chain to rebuild the directory, resolving each entry's format run
        ulong offset = fh.header_bytes;
        _end = fh.header_bytes;
        BlockFormatHeader run_fmt;
        while (offset)
        {
            BlockEntry e;
            if (read_at(_file, (cast(void*)&e.hdr)[0 .. BlockHeader.sizeof], offset, bytes) != Result.success
                || bytes < BlockHeader.sizeof)
                break;
            e.offset = offset;
            if (e.hdr.format_block == 0)
            {
                if (read_at(_file, (cast(void*)&run_fmt)[0 .. BlockFormatHeader.sizeof],
                            offset + BlockHeader.sizeof, bytes) != Result.success
                    || bytes < BlockFormatHeader.sizeof)
                    break;
                _fmt_anchor = offset;
                _afmt = run_fmt;
            }
            else if (e.hdr.format_block != _fmt_anchor)
            {
                // referenced run isn't the walking one (future compaction); resolve backwards
                foreach_reverse (ref const BlockEntry p; dir[])
                {
                    if (p.offset == e.hdr.format_block)
                    {
                        run_fmt = p.fmt;
                        break;
                    }
                }
            }
            e.fmt = run_fmt;
            dir ~= e;
            _tail = offset;
            _end = offset + e.hdr.header_bytes + e.hdr.payload_bytes;
            offset = e.hdr.next;
        }
        return true;
    }

    void close_()
    {
        if (_open)
            urt.file.close(_file);
        _open = false;
        _tail = 0;
        _end = 0;
        _fmt_anchor = 0;
        dir.clear();
    }

    bool put(ref const RecordBlock blk)
    {
        ref const DataFormat f = *blk.data_format;
        debug assert(container_serialisable(f));
        uint count = blk.count;
        if (count == 0)
            return true;
        bool irregular = blk.ts !is null;
        uint offs_bytes = irregular ? count * cast(uint)uint.sizeof : 0;

        uint heap_bytes = 0;
        if (f.count == 0)
        {
            // compact the heap: only referenced entries ship, dedup'd, offsets rebased
            _rbuf.resize(count * ushort.sizeof);
            _hbuf.clear();
            ushort[] recs = cast(ushort[])_rbuf[];
            foreach (i; 0 .. count)
            {
                const(void)[] v = blk.dynamic(i);
                uint off = uint.max;
                uint pos = 0;
                while (pos < _hbuf.length)
                {
                    const(void)[] e = heap_view(_hbuf.ptr, pos);
                    if (e == v)
                    {
                        off = pos;
                        break;
                    }
                    pos += heap_entry_bytes(e.length);
                }
                if (off == uint.max)
                {
                    off = cast(uint)_hbuf.length;
                    _hbuf.resize(off + heap_entry_bytes(v.length));
                    ushort* p = cast(ushort*)(_hbuf.ptr + off);
                    *p = cast(ushort)v.length;
                    (cast(ubyte*)(p + 1))[0 .. v.length] = cast(const(ubyte)[])v[];
                    if (v.length & 1)
                        (cast(ubyte*)(p + 1))[v.length] = 0;
                }
                recs[i] = cast(ushort)off;
            }
            heap_bytes = cast(uint)_hbuf.length;
        }
        uint raw_bytes = offs_bytes + count * f.stride + heap_bytes;

        BlockFormatHeader bf;
        bf.rate = f.rate;
        bf.stride = f.stride;
        bf.type = f.type;
        bf.kind = f.kind;
        bf.count = f.count;
        if (f.desc == DataFormat.Desc.quantity)
        {
            static assert(ScaledUnit.sizeof <= 8);
            (cast(ubyte*)&bf.unit)[0 .. ScaledUnit.sizeof] = (cast(const(ubyte)*)&f.unit)[0 .. ScaledUnit.sizeof];
        }
        bool anchor = !(_fmt_anchor && same_format(bf, _afmt));

        BlockHeader h;
        h.header_bytes = cast(ushort)(BlockHeader.sizeof + (anchor ? BlockFormatHeader.sizeof : 0));
        h.format_block = anchor ? 0 : _fmt_anchor;
        h.prev = _tail;
        h.first_index = blk.first_index;
        h.last_index = blk.first_index + count - 1;
        h.first_tick = blk.tick(0);
        h.last_tick = blk.tick(count - 1);
        h.payload_bytes = raw_bytes;
        h.flags = irregular ? BlockHeader.Flags.irregular : 0;
        h.codec = owsig_codec_raw;
        h.heap_bytes = heap_bytes;

        _wbuf.resize(h.header_bytes + raw_bytes);
        ubyte[] raw = _wbuf[h.header_bytes .. $];
        if (irregular)
        {
            // rebase the offsets plane so first_tick doubles as the block's time base
            uint[] offs = cast(uint[])raw[0 .. offs_bytes];
            uint base = blk.ts[0];
            foreach (i; 0 .. count)
                offs[i] = blk.ts[i] - base;
        }
        if (f.count == 0)
        {
            raw[offs_bytes .. offs_bytes + count * ushort.sizeof] = _rbuf[];
            raw[offs_bytes + count * ushort.sizeof .. $] = _hbuf[];
        }
        else
            raw[offs_bytes .. $] = cast(const(ubyte)[])blk.records();

        foreach (i; 0 .. g_num_codecs)
        {
            if (!g_codecs[i].match || !g_codecs[i].match(f, blk))
                continue;
            _pbuf.resize(raw_bytes);
            ptrdiff_t packed = g_codecs[i].pack(blk, raw, _pbuf[]);
            if (packed > 0 && packed < raw_bytes)
            {
                h.codec = cast(ubyte)(first_registered_codec + i);
                h.payload_bytes = cast(uint)packed;
                _wbuf.resize(h.header_bytes + packed);
                _wbuf[h.header_bytes .. $] = _pbuf[0 .. packed];
            }
            break;
        }

        *cast(BlockHeader*)_wbuf.ptr = h;
        if (anchor)
            *cast(BlockFormatHeader*)(_wbuf.ptr + BlockHeader.sizeof) = bf;

        ulong offset = _end;
        size_t written;
        if (write_at(_file, _wbuf[], offset, written) != Result.success || written < _wbuf.length)
            return false;
        if (_tail)
            if (write_at(_file, (cast(const(void)*)&offset)[0 .. 8], _tail, written) != Result.success)
                return false; // next-link patch failed; block stays unreferenced, its space reused on the next put
        if (dir.length)
            dir[$-1].hdr.next = offset;
        dir ~= BlockEntry(offset, h, bf);
        _tail = offset;
        _end = offset + _wbuf.length;
        if (anchor)
        {
            _fmt_anchor = offset;
            _afmt = bf;
        }
        return true;
    }

    // load block i; the returned view and its format are valid until the next load
    bool load(size_t i, out RecordBlock blk)
    {
        ref const BlockEntry e = dir[i];
        uint raw_bytes = e.raw_bytes;
        _buf.resize(raw_bytes);

        _fmt = DataFormat(cast(ValueType)e.fmt.type, cast(SeriesKind)e.fmt.kind);
        if (e.fmt.unit)
        {
            ScaledUnit u;
            (cast(ubyte*)&u)[0 .. ScaledUnit.sizeof] = (cast(const(ubyte)*)&e.fmt.unit)[0 .. ScaledUnit.sizeof];
            _fmt = DataFormat(cast(ValueType)e.fmt.type, cast(SeriesKind)e.fmt.kind, u);
        }
        _fmt.count = e.fmt.count;
        _fmt.rate = e.fmt.rate;
        bool irregular = (e.hdr.flags & BlockHeader.Flags.irregular) != 0;

        size_t bytes;
        if (e.hdr.codec == owsig_codec_raw)
        {
            if (read_at(_file, _buf[], e.offset + e.hdr.header_bytes, bytes) != Result.success || bytes < raw_bytes)
                return false;
        }
        else
        {
            if (e.hdr.codec < first_registered_codec || e.hdr.codec >= first_registered_codec + g_num_codecs)
                return false; // unbound codec id (the name table lands with a real codec)
            _pbuf.resize(e.hdr.payload_bytes);
            if (read_at(_file, _pbuf[], e.offset + e.hdr.header_bytes, bytes) != Result.success
                || bytes < e.hdr.payload_bytes)
                return false;
            if (!g_codecs[e.hdr.codec - first_registered_codec].unpack(_pbuf[], _fmt, e.hdr.count, irregular, e.hdr.heap_bytes, _buf[]))
                return false;
        }
        uint offs_bytes = irregular ? e.hdr.count * cast(uint)uint.sizeof : 0;
        blk.format = register_format(_fmt);
        blk.count = e.hdr.count;
        blk.first_index = e.hdr.first_index;
        blk.t0 = e.hdr.first_tick;
        blk.ts = irregular ? cast(const(uint)*)_buf.ptr : null;
        blk.data = _buf.ptr + offs_bytes;
        if (e.hdr.heap_bytes)
        {
            blk.heap = _buf.ptr + offs_bytes + e.hdr.count * e.fmt.stride;
            blk.heap_bytes = e.hdr.heap_bytes;
        }
        return true;
    }

    // first block whose span ends at or after tick; dir.length when none
    size_t find_by_time(ulong tick) const
    {
        size_t lo = 0, hi = dir.length;
        while (lo < hi)
        {
            size_t mid = (lo + hi) / 2;
            if (dir[mid].hdr.last_tick < tick)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

private:
    File _file;
    Array!ubyte _buf;
    Array!ubyte _wbuf;
    Array!ubyte _pbuf;
    Array!ubyte _rbuf;  // dynamic-record put: remapped record plane
    Array!ubyte _hbuf;  // dynamic-record put: compacted heap
    DataFormat _fmt;
    BlockFormatHeader _afmt;
    ulong _fmt_anchor;
    ulong _tail;
    ulong _end;
    bool _open;

    static bool same_format(ref const BlockFormatHeader a, ref const BlockFormatHeader b) pure
        => a.type == b.type && a.kind == b.kind && a.count == b.count
        && a.stride == b.stride && a.rate == b.rate && a.unit == b.unit;
}


unittest
{
    import urt.time : from_unix_time_ns;
    import manager.element;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, SeriesKind.held);

    Element e;
    e.format = register_format(f64_held);
    e.ensure_history();
    foreach (i; 0 .. 4)
    {
        e.write_sample(i * 1.5, from_unix_time_ns((i + 1) * 1_000_000UL));
        if (i == 1)
            e.mark_gap(); // second block
    }

    enum path = "owsig_unittest.tmp";
    delete_file(path);

    {
        SeriesContainer c;
        assert(c.open_(path));
        Cursor cur = e.open_series_cursor(0);
        while (cur.pending)
        {
            RecordBlock blk = cur.next(256);
            if (blk.count == 0)
                break;
            assert(c.put(blk));
        }
        e.close_series_cursor(cur);
        assert(c.dir.length == 2);
        c.close_();
    }

    // reopen: the chain rebuilds the directory; loaded blocks read back as in-memory views
    {
        SeriesContainer c;
        assert(c.open_(path));
        assert(c.dir.length == 2);
        assert(c.dir[0].hdr.first_index == 0 && c.dir[1].hdr.last_index == 3);

        // format run: the anchor carries the format header, followers point and stay slim
        assert(c.dir[0].hdr.format_block == 0);
        assert(c.dir[0].hdr.header_bytes == BlockHeader.sizeof + BlockFormatHeader.sizeof);
        assert(c.dir[1].hdr.format_block == c.dir[0].offset);
        assert(c.dir[1].hdr.header_bytes == BlockHeader.sizeof);
        assert(c.dir[1].fmt.stride == 8); // follower resolved its run's format

        RecordBlock blk;
        assert(c.load(0, blk));
        assert(blk.count == 2 && blk.get!double(0) == 0.0 && blk.get!double(1) == 1.5);
        assert(blk.time(1) == from_unix_time_ns(2_000_000));
        assert(c.load(1, blk));
        assert(blk.count == 2 && blk.get!double(1) == 4.5);
        assert(blk.box(1).asDouble == 4.5);

        // time-seek through the in-memory directory
        assert(c.find_by_time(2_500) == 1);  // 2.5ms in usec ticks

        // append after reopen: prev/next links patch across sessions
        e.write_sample(9.0, from_unix_time_ns(5_000_000));
        Cursor cur = e.open_series_cursor(4);
        RecordBlock nb = cur.next(256);
        assert(nb.count == 1 && c.put(nb));
        e.close_series_cursor(cur);
        assert(c.dir.length == 3 && c.dir[2].hdr.prev == c.dir[1].offset);
        assert(c.dir[2].hdr.format_block == c.dir[0].offset); // anchor survives reopen
        c.close_();
    }

    {
        SeriesContainer c;
        assert(c.open_(path));
        assert(c.dir.length == 3);
        RecordBlock blk;
        assert(c.load(2, blk));
        assert(blk.count == 1 && blk.get!double(0) == 9.0);

        // a format change anchors a new run
        DataFormat s32_fmt = DataFormat(ValueType.s32, SeriesKind.held);
        int rv = 42;
        uint[1] rts = 0;
        RecordBlock rb;
        rb.format = register_format(s32_fmt);
        rb.count = 1;
        rb.first_index = 5;
        rb.t0 = 6_000_000 / 1000;
        rb.ts = rts.ptr;
        rb.data = &rv;
        assert(c.put(rb));
        assert(c.dir[3].hdr.format_block == 0);
        assert(c.load(3, blk) && blk.get!int(0) == 42);
        c.close_();
    }

    // text: heap-plane round-trip, compacted and dedup'd per block
    DataFormat text_fmt = DataFormat(ValueType.char_, SeriesKind.held);
    text_fmt.count = 0;
    Element t;
    t.format = register_format(text_fmt);
    t.ensure_history();
    t.write_sample("alpha", from_unix_time_ns(1_000_000));
    t.write_sample("a somewhat longer beta value", from_unix_time_ns(2_000_000));
    t.write_sample("alpha", from_unix_time_ns(3_000_000));

    enum tpath = "owsig_text_unittest.tmp";
    delete_file(tpath);
    {
        SeriesContainer c;
        assert(c.open_(tpath));
        Cursor cur = t.open_series_cursor(0);
        RecordBlock blk = cur.next(256);
        assert(blk.count == 3 && c.put(blk));
        t.close_series_cursor(cur);
        assert(c.dir[0].hdr.heap_bytes == heap_entry_bytes(5) + heap_entry_bytes(28));
        c.close_();
    }
    {
        SeriesContainer c;
        assert(c.open_(tpath));
        assert(c.dir.length == 1 && c.dir[0].fmt.stride == 2);
        RecordBlock blk;
        assert(c.load(0, blk));
        assert(blk.count == 3);
        assert(blk.text(0) == "alpha");
        assert(blk.box(1).asString == "a somewhat longer beta value");
        assert(blk.text(2) == "alpha");
        assert((cast(const(ushort)*)blk.data)[0] == (cast(const(ushort)*)blk.data)[2]);
        assert(blk.time(2) == from_unix_time_ns(3_000_000));
        c.close_();
    }
    delete_file(tpath);
    t.teardown();

    delete_file(path);
    e.teardown();
}


private:

__gshared SeriesCodec[8] g_codecs;
__gshared ubyte g_num_codecs;
