module manager.ows;

// ows v0: raw-image series container. The file is a doubly-linked block list: each block
// header carries next/prev file offsets and its index/timestamp span; the first block of a
// format run additionally carries a BlockFormatHeader (and, later, name-binding data for
// enum/user/codec identity) behind it, and followers point at that anchor via format_block,
// so a format change just starts a new run and stable runs skip the repeat noise.
//
// The container is a block reader/writer over the file, nothing more: indexing lives in the
// SeriesStore. open_() walks the chain once and adopts every block into the store as a
// fully-evicted Bucket (headers only, no bytes), so a cursor opened at index 0 walks all of
// recorded history through the same reconstitute() that serves a packed block. append()
// writes one sealed bucket's encoded image as one block - the sealed raw image is
// byte-identical to the ows payload, so a flush is a straight write.
//
// Not serialisable yet: user types and enum identity (need name binding), domain-clocked
// series (need anchor blocks for the clock).
//
// TODO *** ADOPTION UNDER LIVE CURSORS IS UNRESOLVED ***
// open_() rebases standing RAM buckets (and the store's pin positions) behind the adopted
// history, but external Cursor structs hold their position by VALUE and cannot be reached,
// so a cursor opened before the container attaches keeps a stale (pre-rebase) position: it
// will re-read adopted history as if new, and a pinned sync cursor would re-ship it to the
// peer. The window is the sub-second gap between element creation and the recorder's scan;
// open_() logs a warning when it fires. Fix candidates: a store-held rebase epoch/offset the
// cursor applies lazily, or cursors holding store-side positions only.

import urt.array;
import urt.file;
import urt.log : writeWarning;
import urt.mem.alloc;
import urt.si.unit : ScaledUnit;

import manager.features : has_file_io;
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

struct SeriesContainer
{
nothrow @nogc:

    bool is_open() const pure
        => _open;

    // Open the file and adopt its history into the store: one fully-evicted Bucket per block,
    // renumbered contiguously from zero (files written before index continuity may hold
    // overlapping spans). Standing RAM buckets shift up behind the adopted history and head
    // resumes after the last record, so the index space is one sequence across restarts.
    bool open_(const(char)[] path, ref SeriesStore store)
    {
        assert(!_open);
        assert(store.container is null, "store already has a backing container");
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
            store.container = &this;
            return true;
        }
        if (fh.magic != "OWSG" || fh.version_ != 1 || fh.header_bytes < FileHeader.sizeof)
        {
            close_();
            return false;
        }

        Array!(Bucket*) adopted;
        ulong offset = fh.header_bytes;
        _end = fh.header_bytes;
        ulong size = get_size(_file); // 0 = unknown
        FormatId run_id = FormatId.invalid;
        ulong next_index = 0;

        // on failure at stays on the offending block and the store keeps the prefix walked so far
        bool adopt(ref ulong at)
        {
            BlockHeader hdr;
            size_t bytes;
            if (read_at(_file, (cast(void*)&hdr)[0 .. BlockHeader.sizeof], at, bytes) != Result.success
                || bytes < BlockHeader.sizeof || !block_sane(hdr, at, size))
                return false;
            ulong anchor = hdr.format_block ? hdr.format_block : at;
            if (anchor != _fmt_anchor)
            {
                if (anchor < fh.header_bytes || anchor > at || !load_format(anchor))
                    return false;
                run_id = register_block_format(_afmt);
            }
            const(DataFormat)* f = format_info(run_id);
            bool irregular = (hdr.flags & BlockHeader.Flags.irregular) != 0;
            if (irregular == f.regular || (hdr.heap_bytes && (f.count || hdr.heap_bytes > 0x10000)))
                return false;
            ulong count = hdr.last_index - hdr.first_index + 1;
            ulong image = (irregular ? count * uint.sizeof : 0) + count * f.stride + hdr.heap_bytes;
            if (image > uint.max || (hdr.codec == ows_codec_raw && hdr.payload_bytes != image))
                return false;

            Bucket* b = cast(Bucket*)alloc(Bucket.sizeof).ptr;
            *b = Bucket.init;
            b.format = run_id;
            b.first_index = next_index;
            b.count = cast(uint)count;
            b.first_tick = hdr.first_tick;
            b.last_offset = cast(uint)(hdr.last_tick - hdr.first_tick);
            b.heap_used = hdr.heap_bytes;
            b.codec = hdr.codec;
            b.packed_bytes = hdr.payload_bytes;
            b.pack_declined = hdr.codec == ows_codec_raw;
            b.sealed = true;
            b.follows_gap = (hdr.flags & BlockHeader.Flags.follows_gap) != 0;
            b.file_offset = at + hdr.header_bytes;
            adopted ~= b;
            next_index += count;
            _tail = at;
            _end = at + hdr.header_bytes + hdr.payload_bytes;
            at = hdr.next;
            return true;
        }
        while (offset)
        {
            if (!adopt(offset))
            {
                writeWarning("ows: corrupt block at ", offset, "; history truncated");
                break;
            }
        }

        if (next_index)
        {
            if (store.cursors.length)
                writeWarning("series container attached under live cursors; their positions predate the rebase");
            foreach (b; store.buckets[])
                b.first_index += next_index;
            foreach (ref slot; store.cursors[])
                if (slot.pinned)
                    slot.pin_position += next_index;
            store.head += next_index;
            foreach (b; store.buckets[])
                adopted ~= b;
            store.buckets = adopted.move;
        }
        store.container = &this;
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
    }

    // append one sealed bucket as one block; on success the bucket carries its file offset
    // and its codec/packed_bytes describe the payload as written
    bool append(Bucket* b)
    {
        debug assert(b.sealed && b.count && !b.file_offset && b.resident);
        const(DataFormat)* f = format_info(b.format);
        debug assert(container_serialisable(*f));

        const(void)[] payload;
        ubyte codec;
        if (b.packed)
        {
            payload = b.packed[0 .. b.packed_bytes];
            codec = b.codec;
        }
        else
        {
            void* base = b.offsets ? cast(void*)b.offsets : b.samples;
            payload = base[0 .. b.image_bytes];
            codec = ows_codec_raw;
        }

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
        h.first_index = b.first_index;
        h.last_index = b.first_index + b.count - 1;
        h.first_tick = b.first_tick;
        h.last_tick = b.last_tick;
        h.payload_bytes = cast(uint)payload.length;
        h.flags = cast(ubyte)((f.regular ? 0 : BlockHeader.Flags.irregular)
                            | (b.follows_gap ? BlockHeader.Flags.follows_gap : 0));
        h.codec = codec;
        h.heap_bytes = b.heap_used;

        ubyte[BlockHeader.sizeof + BlockFormatHeader.sizeof] hbuf = void;
        *cast(BlockHeader*)hbuf.ptr = h;
        if (anchor)
            *cast(BlockFormatHeader*)(hbuf.ptr + BlockHeader.sizeof) = bf;

        ulong offset = _end;
        size_t written;
        if (write_at(_file, hbuf[0 .. h.header_bytes], offset, written) != Result.success
            || written < h.header_bytes)
            return false;
        if (write_at(_file, payload, offset + h.header_bytes, written) != Result.success
            || written < payload.length)
            return false;
        if (_tail)
            if (write_at(_file, (cast(const(void)*)&offset)[0 .. 8], _tail, written) != Result.success)
                return false; // next-link patch failed; block stays unreferenced, its space reused on the next put
        _tail = offset;
        _end = offset + h.header_bytes + payload.length;
        if (anchor)
        {
            _fmt_anchor = offset;
            _afmt = bf;
        }

        b.file_offset = offset + h.header_bytes;
        if (!b.packed)
        {
            b.packed_bytes = cast(uint)payload.length;
            b.codec = ows_codec_raw;
            b.pack_declined = true; // the file is the canonical encoded copy; never re-pack
        }
        return true;
    }

    // fetch a flushed bucket's encoded image; dst is packed_bytes long
    bool read_payload(ref const Bucket b, void[] dst)
    {
        debug assert(b.file_offset && dst.length == b.packed_bytes);
        size_t bytes;
        return read_at(_file, dst, b.file_offset, bytes) == Result.success && bytes >= dst.length;
    }

private:
    File _file;
    BlockFormatHeader _afmt;
    ulong _fmt_anchor;
    ulong _tail;
    ulong _end;
    bool _open;

    // the successor must lie strictly beyond the block so the walk always advances
    static bool block_sane(ref const BlockHeader hdr, ulong offset, ulong size) pure
    {
        ulong end = offset + hdr.header_bytes + hdr.payload_bytes;
        return hdr.header_bytes >= BlockHeader.sizeof && hdr.payload_bytes
            && hdr.last_index >= hdr.first_index && hdr.last_index - hdr.first_index < uint.max
            && hdr.last_tick >= hdr.first_tick && hdr.last_tick - hdr.first_tick <= uint.max
            && (!size || end <= size) && (!hdr.next || hdr.next >= end);
    }

    static bool format_sane(ref const BlockFormatHeader bf) pure
    {
        if (bf.type > ValueType.char_ || bf.kind > SeriesKind.point || bf.header_bytes < BlockFormatHeader.sizeof)
            return false;
        DataFormat f = DataFormat(cast(ValueType)bf.type, cast(SeriesKind)bf.kind);
        f.count = bf.count;
        if (bf.count == 0 ? bf.type != ValueType.char_ && bf.type != ValueType.u8 : !f.stride_fits)
            return false;
        return bf.stride == f.stride;
    }

    // make the run anchored at anchor the current one; false = not a sane anchor block
    bool load_format(ulong anchor)
    {
        BlockHeader hdr;
        BlockFormatHeader bf;
        size_t bytes;
        if (read_at(_file, (cast(void*)&hdr)[0 .. BlockHeader.sizeof], anchor, bytes) != Result.success
            || bytes < BlockHeader.sizeof || hdr.format_block != 0
            || read_at(_file, (cast(void*)&bf)[0 .. BlockFormatHeader.sizeof], anchor + BlockHeader.sizeof, bytes) != Result.success
            || bytes < BlockFormatHeader.sizeof || !format_sane(bf)
            || hdr.header_bytes < BlockHeader.sizeof + bf.header_bytes)
            return false;
        _fmt_anchor = anchor;
        _afmt = bf;
        return true;
    }

    static FormatId register_block_format(ref const BlockFormatHeader bf)
    {
        DataFormat f = DataFormat(cast(ValueType)bf.type, cast(SeriesKind)bf.kind);
        if (bf.unit)
        {
            ScaledUnit u;
            (cast(ubyte*)&u)[0 .. ScaledUnit.sizeof] = (cast(const(ubyte)*)&bf.unit)[0 .. ScaledUnit.sizeof];
            f = DataFormat(cast(ValueType)bf.type, cast(SeriesKind)bf.kind, u);
        }
        f.count = bf.count;
        f.rate = bf.rate;
        return register_format(f);
    }

    static bool same_format(ref const BlockFormatHeader a, ref const BlockFormatHeader b) pure
        => a.type == b.type && a.kind == b.kind && a.count == b.count
        && a.stride == b.stride && a.rate == b.rate && a.unit == b.unit;
}


static if (has_file_io)
unittest
{
    import urt.time : from_unix_time_ns;
    import manager.element;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, SeriesKind.held);

    enum path = "ows_unittest.tmp";
    delete_file(path);

    // first life: two sealed buckets flush as two blocks; eviction leaves headers-only
    // descriptors that reconstitute straight from the file
    {
        Element e;
        e.format = register_format(f64_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        assert(c.open_(path, *h));
        assert(h.container is &c);

        foreach (i; 0 .. 4)
        {
            e.write_sample(i * 1.5, from_unix_time_ns((i + 1) * 1_000_000UL));
            if (i == 1)
                e.mark_gap(); // second bucket
        }
        assert(h.buckets.length == 2);
        h.seal(h.buckets[$-1]);
        foreach (b; h.buckets[])
            assert(c.append(b));
        assert(h.buckets[0].file_offset && h.buckets[1].file_offset);

        // evict both to disk; the descriptors stay and the read round-trips
        foreach (b; h.buckets[])
        {
            h.drop_raw(b);
            if (b.packed)
            {
                free(b.packed[0 .. b.packed_bytes]);
                b.packed = null;
            }
        }
        assert(!h.buckets[0].resident);
        RecordBlock blk = e.read_records(0, 16);
        assert(blk.count == 2 && blk.get!double(0) == 0.0 && blk.get!double(1) == 1.5);
        assert(blk.time(1) == from_unix_time_ns(2_000_000));

        c.close_();
        h.container = null;
        e.teardown();
    }

    // second life: open adopts the chain as evicted buckets, head resumes, a cursor at 0
    // walks all of recorded history, and new writes append to the same index space
    {
        Element e;
        e.format = register_format(f64_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        assert(c.open_(path, *h));
        assert(h.buckets.length == 2 && h.head == 4);
        assert(!h.buckets[0].resident && h.buckets[0].sealed);
        assert(h.buckets[1].follows_gap);

        e.write_sample(9.0, from_unix_time_ns(5_000_000));
        assert(e.record_count == 5);
        assert(h.buckets[$-1].first_index == 4);

        Cursor cur = e.open_series_cursor(0);
        RecordBlock blk = cur.next(256);
        assert(blk.count == 2 && blk.get!double(0) == 0.0);
        blk = cur.next(256);
        assert(blk.count == 2 && blk.get!double(1) == 4.5);
        assert(blk.box(1).asDouble == 4.5);
        blk = cur.next(256);
        assert(blk.count == 1 && blk.get!double(0) == 9.0);
        assert(!cur.pending);
        e.close_series_cursor(cur);
        assert(!h.buckets[0].resident);   // the walk's borrows dropped on close

        // flush the tail: append after reopen patches prev/next across sessions
        h.seal(h.buckets[$-1]);
        assert(c.append(h.buckets[$-1]));

        c.close_();
        h.container = null;
        e.teardown();
    }

    // third life: three blocks now; standing RAM history rebases behind the adopted file
    {
        Element e;
        e.format = register_format(f64_held);
        e.ensure_history();
        e.write_sample(21.0, from_unix_time_ns(6_000_000));   // written before the recorder attaches
        SeriesStore* h = e.ensure_history();
        assert(h.head == 1);

        SeriesContainer c;
        assert(c.open_(path, *h));
        assert(h.head == 6);
        assert(h.buckets.length == 4 && h.buckets[$-1].first_index == 5);

        Cursor cur = e.open_series_cursor(0);
        double[6] expect = [0.0, 1.5, 3.0, 4.5, 9.0, 21.0];
        size_t n;
        for (;;)
        {
            RecordBlock blk = cur.next(256);
            if (!blk.count)
                break;
            foreach (i; 0 .. blk.count)
                assert(blk.get!double(i) == expect[n++]);
        }
        assert(n == 6);
        e.close_series_cursor(cur);

        c.close_();
        h.container = null;
        e.teardown();
    }
    delete_file(path);

    // text: the heap plane rides the sealed image; round-trips through flush and adoption
    DataFormat text_fmt = DataFormat(ValueType.char_, SeriesKind.held);
    text_fmt.count = 0;
    enum tpath = "ows_text_unittest.tmp";
    delete_file(tpath);
    {
        Element t;
        t.format = register_format(text_fmt);
        SeriesStore* h = t.ensure_history();
        SeriesContainer c;
        assert(c.open_(tpath, *h));
        t.write_sample("alpha", from_unix_time_ns(1_000_000));
        t.write_sample("a somewhat longer beta value", from_unix_time_ns(2_000_000));
        t.write_sample("alpha", from_unix_time_ns(3_000_000));
        h.seal(h.buckets[$-1]);
        assert(c.append(h.buckets[0]));
        assert(h.buckets[0].heap_used == heap_entry_bytes(5) + heap_entry_bytes(28));
        c.close_();
        h.container = null;
        t.teardown();
    }
    {
        Element t;
        t.format = register_format(text_fmt);
        SeriesStore* h = t.ensure_history();
        SeriesContainer c;
        assert(c.open_(tpath, *h));
        assert(h.buckets.length == 1 && h.head == 3);
        RecordBlock blk = t.read_records(0, 16);
        assert(blk.count == 3);
        assert(blk.text(0) == "alpha");
        assert(blk.box(1).asString == "a somewhat longer beta value");
        assert(blk.text(2) == "alpha");
        assert((cast(const(ushort)*)blk.data)[0] == (cast(const(ushort)*)blk.data)[2]);
        assert(blk.time(2) == from_unix_time_ns(3_000_000));
        c.close_();
        h.container = null;
        t.teardown();
    }
    delete_file(tpath);

    // a format change starts a new run: the follower re-anchors and both read back typed
    enum fpath = "ows_format_unittest.tmp";
    delete_file(fpath);
    {
        Element e;
        e.format = register_format(f64_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        assert(c.open_(fpath, *h));
        e.write_sample(1.0, from_unix_time_ns(1_000_000));
        h.seal(h.buckets[$-1]);
        assert(c.append(h.buckets[0]));

        static immutable DataFormat s32_held = DataFormat(ValueType.s32, SeriesKind.held);
        e.format = register_format(s32_held);
        e.write_sample(42, from_unix_time_ns(2_000_000));   // format roll: new bucket, new run
        assert(h.buckets.length == 2 && h.buckets[1].format == e.format);
        h.seal(h.buckets[$-1]);
        assert(c.append(h.buckets[1]));
        c.close_();
        h.container = null;
        e.teardown();
    }
    {
        Element e;
        static immutable DataFormat s32_held = DataFormat(ValueType.s32, SeriesKind.held);
        e.format = register_format(s32_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        assert(c.open_(fpath, *h));
        assert(h.buckets.length == 2);
        assert(h.buckets[0].format != h.buckets[1].format);   // per-run formats survive
        RecordBlock blk = e.read_records(0, 16);
        assert(blk.count == 1 && blk.get!double(0) == 1.0);   // served in the OLD format
        blk = e.read_records(1, 16);
        assert(blk.count == 1 && blk.get!int(0) == 42);
        c.close_();
        h.container = null;
        e.teardown();
    }
    delete_file(fpath);

    // hostile containers: each case patches a fresh two-block f64 file and reopens it
    enum cpath = "ows_corrupt_unittest.tmp";
    void make_file()
    {
        delete_file(cpath);
        Element e;
        e.format = register_format(f64_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        assert(c.open_(cpath, *h));
        foreach (i; 0 .. 4)
        {
            e.write_sample(i * 1.5, from_unix_time_ns((i + 1) * 1_000_000UL));
            if (i == 1)
                e.mark_gap();
        }
        h.seal(h.buckets[$-1]);
        foreach (b; h.buckets[])
            assert(c.append(b));
        c.close_();
        h.container = null;
        e.teardown();
    }
    void patch(ulong offset, ulong value, size_t size)
    {
        File f;
        size_t n;
        assert(urt.file.open(f, cpath, FileOpenMode.ReadWriteExisting) == Result.success);
        assert(write_at(f, (cast(const(void)*)&value)[0 .. size], offset, n) == Result.success && n == size);
        urt.file.close(f);
    }
    int reopen() // -1 = refused, else adopted buckets
    {
        Element e;
        e.format = register_format(f64_held);
        SeriesStore* h = e.ensure_history();
        SeriesContainer c;
        int r = c.open_(cpath, *h) ? cast(int)h.buckets.length : -1;
        c.close_();
        h.container = null;
        e.teardown();
        return r;
    }
    enum b1 = FileHeader.sizeof;
    enum b2 = b1 + BlockHeader.sizeof + BlockFormatHeader.sizeof + 2 * (uint.sizeof + double.sizeof);
    enum fmt1 = b1 + BlockHeader.sizeof;

    make_file();
    assert(reopen() == 2);
    patch(b2 + BlockHeader.next.offsetof, b2, 8);                    // self-pointing link
    assert(reopen() == 1);
    make_file();
    patch(b1 + BlockHeader.first_index.offsetof, 5, 8);              // last_index < first_index
    assert(reopen() == 0);
    make_file();
    patch(fmt1 + BlockFormatHeader.type.offsetof, 0xFF, 1);
    assert(reopen() == 0);
    make_file();
    patch(fmt1 + BlockFormatHeader.count.offsetof, 64, 1);           // 512-byte stride
    assert(reopen() == 0);
    make_file();
    patch(fmt1 + BlockFormatHeader.stride.offsetof, 9, 2);
    assert(reopen() == 0);
    make_file();
    patch(b1 + BlockHeader.payload_bytes.offsetof, 2 * (uint.sizeof + double.sizeof) - 8, 4);
    assert(reopen() == 0);
    make_file();
    patch(FileHeader.header_bytes.offsetof, 0, 2);
    assert(reopen() == -1);
    delete_file(cpath);
}
