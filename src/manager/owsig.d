module manager.owsig;

// owsig v0: raw-image series container. The file is a doubly-linked block list: each block
// header carries next/prev file offsets, its index and timestamp span, and its own data
// format, so a format change just starts a new block. The runtime keeps the headers as an
// in-memory directory (offset + span), so time-seek is a binary search and recall is: load
// one block's payload, view it in place as a RecordBlock (byte-identical to the RAM image).
//
// Codecs are registered with a selection predicate; the first match packs the payload and
// RAW is the mandatory fallback (a codec that doesn't beat raw is ignored). Codec ids 0/1
// are reserved (raw, zlib); zlib waits on a deflate encoder in urt. Registered codec ids
// are process-local: TODO bind them by NAME in the file before any ships (id.d doctrine).
//
// Not serialisable yet: text (String handles need a flattening codec), user types and enum
// identity (need name binding), domain-clocked series (need anchor blocks).

import urt.array;
import urt.file;
import urt.si.unit : ScaledUnit;

import manager.series;

nothrow @nogc:


enum ubyte owsig_codec_raw = 0;
enum ubyte owsig_codec_zlib = 1;
enum ubyte first_registered_codec = 2;

struct SeriesCodec
{
    const(char)[] name;
    bool function(ref const DataFormat fmt, ref const RecordBlock blk) nothrow @nogc match;
    // pack the raw payload image into dst; bytes written, or -1 to decline (raw applies)
    ptrdiff_t function(ref const RecordBlock blk, const(void)[] raw, void[] dst) nothrow @nogc pack;
    // unpack a payload into the raw image; false = corrupt
    bool function(const(void)[] src, ref const BlockHeader hdr, void[] dst) nothrow @nogc unpack;
}

ubyte register_series_codec(ref const SeriesCodec codec)
{
    assert(g_num_codecs < g_codecs.length, "too many series codecs");
    g_codecs[g_num_codecs] = codec;
    return cast(ubyte)(first_registered_codec + g_num_codecs++);
}

bool container_serialisable(ref const DataFormat f)
    => f.clock is null && !f.is_text && f.type != ValueType.user;

struct FileHeader
{
    char[4] magic = "OWSG";
    ubyte version_ = 0;
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
    ulong first_index;
    ulong last_index;    // inclusive
    ulong first_tick;    // usecs; also the time base of the offsets plane
    ulong last_tick;     // inclusive
    ulong unit;          // ScaledUnit image; 0 = none
    uint payload_bytes;
    uint rate;
    ushort header_bytes; // offset from block start to the payload; readers skip unknown extensions
    ushort stride;
    ubyte type;          // ValueType
    ubyte semantics;
    ubyte extent;        // DataFormat.count
    ubyte flags;         // Flags
    ubyte codec;
    ubyte[7] reserved;

    enum Flags : ubyte
    {
        irregular   = 1 << 0,  // offsets plane precedes the records
        follows_gap = 1 << 1,
    }

    uint count() const pure
        => cast(uint)(last_index - first_index + 1);

    uint raw_bytes() const pure
        => cast(uint)(((flags & Flags.irregular) ? count * uint.sizeof : 0) + count * stride);
}
static assert(BlockHeader.sizeof == 80);

struct BlockEntry
{
    ulong offset;
    BlockHeader hdr;
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
        if (fh.magic != "OWSG" || fh.version_ != 0)
        {
            close_();
            return false;
        }

        // walk the chain to rebuild the directory
        ulong offset = fh.header_bytes;
        _end = fh.header_bytes;
        while (offset)
        {
            BlockHeader h;
            if (read_at(_file, (cast(void*)&h)[0 .. BlockHeader.sizeof], offset, bytes) != Result.success
                || bytes < BlockHeader.sizeof)
                break;
            dir ~= BlockEntry(offset, h);
            _tail = offset;
            _end = offset + h.header_bytes + h.payload_bytes;
            offset = h.next;
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
        dir.clear();
    }

    bool put(ref const RecordBlock blk)
    {
        ref const DataFormat f = *blk.format;
        debug assert(container_serialisable(f));
        uint count = blk.count;
        if (count == 0)
            return true;
        bool irregular = blk.ts !is null;
        uint offs_bytes = irregular ? count * cast(uint)uint.sizeof : 0;
        uint raw_bytes = offs_bytes + count * f.stride;

        _wbuf.resize(BlockHeader.sizeof + raw_bytes);
        ubyte[] raw = _wbuf[BlockHeader.sizeof .. $];
        if (irregular)
        {
            // rebase the offsets plane so first_tick doubles as the block's time base
            uint[] offs = cast(uint[])raw[0 .. offs_bytes];
            uint base = blk.ts[0];
            foreach (i; 0 .. count)
                offs[i] = blk.ts[i] - base;
        }
        raw[offs_bytes .. $] = cast(const(ubyte)[])blk.records();

        BlockHeader h;
        h.header_bytes = BlockHeader.sizeof;
        h.prev = _tail;
        h.first_index = blk.first_index;
        h.last_index = blk.first_index + count - 1;
        h.first_tick = blk.tick(0);
        h.last_tick = blk.tick(count - 1);
        h.payload_bytes = raw_bytes;
        h.rate = f.rate;
        h.stride = f.stride;
        h.type = f.type;
        h.semantics = f.semantics;
        h.extent = f.count;
        h.flags = irregular ? BlockHeader.Flags.irregular : 0;
        h.codec = owsig_codec_raw;
        if (f.desc == DataFormat.Desc.quantity)
        {
            static assert(ScaledUnit.sizeof <= 8);
            (cast(ubyte*)&h.unit)[0 .. ScaledUnit.sizeof] = (cast(const(ubyte)*)&f.unit)[0 .. ScaledUnit.sizeof];
        }

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
                _wbuf.resize(BlockHeader.sizeof + packed);
                _wbuf[BlockHeader.sizeof .. $] = _pbuf[0 .. packed];
            }
            break;
        }

        *cast(BlockHeader*)_wbuf.ptr = h;

        ulong offset = _end;
        size_t written;
        if (write_at(_file, _wbuf[], offset, written) != Result.success || written < _wbuf.length)
            return false;
        if (_tail)
            if (write_at(_file, (cast(const(void)*)&offset)[0 .. 8], _tail, written) != Result.success)
                return false; // next-link patch failed; directory still knows the block
        if (dir.length)
            dir[$-1].hdr.next = offset;
        dir ~= BlockEntry(offset, h);
        _tail = offset;
        _end = offset + _wbuf.length;
        return true;
    }

    // load block i; the returned view and its format are valid until the next load
    bool load(size_t i, out RecordBlock blk)
    {
        ref const BlockEntry e = dir[i];
        uint raw_bytes = e.hdr.raw_bytes;
        _buf.resize(raw_bytes);

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
            if (!g_codecs[e.hdr.codec - first_registered_codec].unpack(_pbuf[], e.hdr, _buf[]))
                return false;
        }

        _fmt = DataFormat(cast(ValueType)e.hdr.type, cast(Semantics)e.hdr.semantics);
        _fmt.count = e.hdr.extent;
        _fmt.rate = e.hdr.rate;
        if (e.hdr.unit)
        {
            ScaledUnit u;
            (cast(ubyte*)&u)[0 .. ScaledUnit.sizeof] = (cast(const(ubyte)*)&e.hdr.unit)[0 .. ScaledUnit.sizeof];
            _fmt = DataFormat(cast(ValueType)e.hdr.type, cast(Semantics)e.hdr.semantics, u);
            _fmt.count = e.hdr.extent;
            _fmt.rate = e.hdr.rate;
        }

        bool irregular = (e.hdr.flags & BlockHeader.Flags.irregular) != 0;
        uint offs_bytes = irregular ? e.hdr.count * cast(uint)uint.sizeof : 0;
        blk.format = &_fmt;
        blk.count = e.hdr.count;
        blk.first_index = e.hdr.first_index;
        blk.t0 = e.hdr.first_tick;
        blk.ts = irregular ? cast(const(uint)*)_buf.ptr : null;
        blk.data = _buf.ptr + offs_bytes;
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
    DataFormat _fmt;
    ulong _tail;
    ulong _end;
    bool _open;
}


private:

__gshared SeriesCodec[8] g_codecs;
__gshared ubyte g_num_codecs;


unittest
{
    import urt.time : from_unix_time_ns;
    import manager.element2;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, Semantics.held);

    Element2 e;
    e.format = &f64_held;
    e.ensure_history();
    foreach (i; 0 .. 4)
    {
        e.observe(i * 1.5, from_unix_time_ns((i + 1) * 1_000_000UL));
        if (i == 1)
            e.mark_gap(); // second block
    }

    enum path = "owsig_unittest.tmp";
    delete_file(path);

    {
        SeriesContainer c;
        assert(c.open_(path));
        Cursor cur = e.open_cursor(0);
        while (cur.pending)
        {
            RecordBlock blk = cur.next(256);
            if (blk.count == 0)
                break;
            assert(c.put(blk));
        }
        e.close_cursor(cur);
        assert(c.dir.length == 2);
        c.close_();
    }

    // reopen: the chain rebuilds the directory; loaded blocks read back as in-memory views
    {
        SeriesContainer c;
        assert(c.open_(path));
        assert(c.dir.length == 2);
        assert(c.dir[0].hdr.first_index == 0 && c.dir[1].hdr.last_index == 3);

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
        e.observe(9.0, from_unix_time_ns(5_000_000));
        Cursor cur = e.open_cursor(4);
        RecordBlock nb = cur.next(256);
        assert(nb.count == 1 && c.put(nb));
        e.close_cursor(cur);
        assert(c.dir.length == 3 && c.dir[2].hdr.prev == c.dir[1].offset);
        c.close_();
    }

    {
        SeriesContainer c;
        assert(c.open_(path));
        assert(c.dir.length == 3);
        RecordBlock blk;
        assert(c.load(2, blk));
        assert(blk.count == 1 && blk.get!double(0) == 9.0);
        c.close_();
    }

    delete_file(path);
    e.teardown();
}
