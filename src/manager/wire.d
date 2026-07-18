module manager.wire;

import urt.endian : loadLittleEndian, storeLittleEndian;
import urt.util : byte_reverse;

nothrow @nogc:


// Mechanical wire layout: position, width, and the swizzles that normalise device storage
// to a canonical little-endian image. Interpretation (units, scale, enums, types) is the
// layer above; this layer is closed and knows only bytes and bits.
//
// Decode: swap word order -> swap bytes within words -> whole reverse -> canonical LE
// image -> extract [bit_offset, bit_offset+bit_width), extended per kind. Encode mirrors.
//
// The three swizzles are commuting involutions with reverse == swap_words*swap_word_bytes,
// so any flag set reduces to intra^(sw^swb) * reverse^(sw^rev): at most one masked
// pair-swap and one byte_reverse+shift, applied to the loaded register. Involution also
// means encode and decode share the one transform.
//
// Flag resolution is the grammar compiler's job; resolved sets for reference:
//   byte-stream le            {}                modbus (BE ctx)      {reverse}
//   byte-stream be            {reverse}         modbus _wr   (CDAB)  {reverse, swap_words}
//   legacy u32le_r            {swap_words}      modbus _bs   (BADC)  {reverse, swap_word_bytes}
//                                               modbus _bs_wr (DCBA) {reverse, swap_words, swap_word_bytes}

enum WireKind : ubyte
{
    unsigned_,
    signed_,
    float_,
    bool_,
    char_,
}

enum WireFlags : ubyte
{
    none            = 0,
    swap_words      = 1,
    swap_word_bytes = 2,
    reverse         = 4,
    members_be      = 8,    // user types: members stored big-endian (gateway flips via td.byte_reverse)
    space_padded    = 16,   // text fields: trailing spaces pad (default is null padding)
}

struct WireLayout
{
nothrow @nogc:

    // kind(3) | width-1(6) | bit_offset(6) | flags(5) | word_shift(2) | container(4)
    uint pack;

    // container_bytes: the addressed storage unit the swizzle operates over. 0 derives the
    // minimal field span (word-rounded when worded); bit slices within a reversed container
    // must state it (the slice's span does not reveal the register's extent).
    this(WireKind kind, uint bit_width, uint bit_offset = 0, WireFlags flags = WireFlags.none,
         uint word_bytes = 2, uint container_bytes = 0) pure
    {
        assert(bit_width >= 1 && bit_width <= 64, "bit width must be 1..64");
        assert(bit_offset < 64, "bit offset is container-relative; containers cap at 64 bits");
        assert(kind != WireKind.float_ || bit_width == 32 || bit_width == 64, "invalid float width"); // TODO: half-float
        uint word_shift = word_bytes == 1 ? 0 : word_bytes == 2 ? 1 : word_bytes == 4 ? 2 : 3;
        assert(1 << word_shift == word_bytes, "word size must be 1/2/4/8 bytes");
        assert(!(flags & (WireFlags.swap_words | WireFlags.swap_word_bytes)) || word_bytes >= 2,
               "word swizzles need a word size");
        assert(container_bytes <= 8, "container exceeds 64 bits");
        assert(container_bytes == 0 || container_bytes * 8 >= bit_offset + bit_width, "field exceeds container");
        pack = kind | ((bit_width - 1) << 3) | (bit_offset << 9) | (flags << 15) | (word_shift << 20) | (container_bytes << 22);
    }

    WireKind kind() const pure
        => cast(WireKind)(pack & 0x7);

    uint bit_width() const pure
        => ((pack >> 3) & 0x3F) + 1;

    uint bit_offset() const pure
        => (pack >> 9) & 0x3F;

    WireFlags flags() const pure
        => cast(WireFlags)((pack >> 15) & 0x1F);

    uint word_bytes() const pure
        => 1 << ((pack >> 20) & 0x3);

    bool worded() const pure
        => (flags & (WireFlags.swap_words | WireFlags.swap_word_bytes)) != 0;

    // byte span the swizzle and extraction operate over
    uint container_bytes() const pure
    {
        uint bytes = (pack >> 22) & 0xF;
        if (bytes)
            return bytes;
        bytes = (bit_offset + bit_width + 7) / 8;
        if (worded)
        {
            uint wb = word_bytes;
            bytes = (bytes + wb - 1) & ~(wb - 1);
        }
        return bytes;
    }
}

// raw field bits from a wire window; sign-extended for signed_, 0/1 for bool_
ulong wire_extract(const(void)[] wire, WireLayout l) pure
{
    uint nbytes = l.container_bytes;
    assert(nbytes <= wire.length, "wire window too small");

    ulong v = swizzle(load_le(cast(const(ubyte)*)wire.ptr, nbytes), nbytes, l);

    uint sh = 64 - l.bit_width;
    v = (v >> l.bit_offset) << sh; // top-align: clears high bits without a width mask
    WireKind k = l.kind;
    if (k == WireKind.signed_)
        return cast(ulong)(cast(long)v >> sh);
    v >>= sh;
    if (k == WireKind.bool_)
        return v != 0;
    return v;
}

double wire_extract_float(const(void)[] wire, WireLayout l) pure
{
    assert(l.kind == WireKind.float_);
    ulong raw = wire_extract(wire, l);
    if (l.bit_width == 32)
    {
        uint bits = cast(uint)raw;
        return *cast(float*)&bits;
    }
    return *cast(double*)&raw;
}

// read-modify-write: field bits placed, surrounding container bits preserved
void wire_insert(void[] wire, WireLayout l, ulong value) pure
{
    uint nbytes = l.container_bytes;
    assert(nbytes <= wire.length, "wire window too small");

    ubyte* p = cast(ubyte*)wire.ptr;
    ulong image = swizzle(load_le(p, nbytes), nbytes, l);

    uint w = l.bit_width;
    ulong mask = w < 64 ? (1UL << w) - 1 : ~0UL;
    image = (image & ~(mask << l.bit_offset)) | ((value & mask) << l.bit_offset);

    store_le(p, nbytes, swizzle(image, nbytes, l));
}

// byte-granular swizzle for str/blob/user/codec data; text has no whole-value reverse,
// but encodings may (a MSB-first date field reverses to the LSB-first canonical image)
void wire_image(const(void)[] wire, WireLayout l, void[] image) pure
{
    assert(wire.ptr !is image.ptr, "in-place swizzle unsupported");
    assert(l.bit_offset == 0, "byte data does not bit-slice");
    size_t n = wire.length;
    assert(image.length >= n, "image buffer too small");

    const(ubyte)* s = cast(const(ubyte)*)wire.ptr;
    ubyte* d = cast(ubyte*)image.ptr;
    uint f = l.flags;
    if (!(f & (WireFlags.reverse | WireFlags.swap_words | WireFlags.swap_word_bytes)))
    {
        d[0 .. n] = s[0 .. n];
        return;
    }

    // word size is a power of two, so the index map is shifts and masks
    uint wsh = (l.pack >> 20) & 0x3;
    uint wb = 1 << wsh;
    assert(!l.worded || (n & (wb - 1)) == 0, "not a word multiple");
    uint x = (f & WireFlags.swap_word_bytes) ? wb - 1 : 0;
    foreach (i; 0 .. n)
    {
        size_t j = (f & WireFlags.reverse) ? n - 1 - i : i;
        if (f & WireFlags.swap_words)
            j = ((n >> wsh) - 1 - (j >> wsh)) << wsh | (j & (wb - 1));
        d[i] = s[j ^ x];
    }
}

// inverse of wire_image; the mapping is an involution so it is the same scatter
alias wire_image_encode = wire_image;


unittest
{
    alias WK = WireKind;
    alias WF = WireFlags;

    static WireFlags wf(uint f) pure
        => cast(WireFlags)f;

    // byte-stream widths, both endians (vectors carried from sampler.d)
    immutable ubyte[8] buf = [0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87];
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 8)) == 0x80);
    assert(wire_extract(buf, WireLayout(WK.signed_, 8)) == cast(ulong)long(-0x80));
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 16)) == 0x8180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 16, 0, WF.reverse)) == 0x8081);
    assert(wire_extract(buf, WireLayout(WK.signed_, 16, 0, WF.reverse)) == cast(ulong)long(0xFFFFFFFFFFFF8081));
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 24)) == 0x828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 24, 0, WF.reverse)) == 0x808182);
    assert(wire_extract(buf, WireLayout(WK.signed_, 24)) == cast(ulong)long(0xFFFFFFFFFF828180));
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 32)) == 0x83828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 32, 0, WF.reverse)) == 0x80818283);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 40)) == 0x8483828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 40, 0, WF.reverse)) == 0x8081828384);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 48)) == 0x858483828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 48, 0, WF.reverse)) == 0x808182838485);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 56)) == 0x86858483828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 56, 0, WF.reverse)) == 0x80818283848586);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 64)) == 0x8786858483828180);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 64, 0, WF.reverse)) == 0x8081828384858687);

    // modbus quartet: value 0x01020304 in each storage scheme
    immutable ubyte[4] abcd = [0x01, 0x02, 0x03, 0x04];
    immutable ubyte[4] cdab = [0x03, 0x04, 0x01, 0x02];
    immutable ubyte[4] badc = [0x02, 0x01, 0x04, 0x03];
    immutable ubyte[4] dcba = [0x04, 0x03, 0x02, 0x01];
    assert(wire_extract(abcd, WireLayout(WK.unsigned_, 32, 0, WF.reverse)) == 0x01020304);
    assert(wire_extract(cdab, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_words))) == 0x01020304);
    assert(wire_extract(badc, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_word_bytes))) == 0x01020304);
    assert(wire_extract(dcba, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_words | WF.swap_word_bytes))) == 0x01020304);
    assert(wire_extract(dcba, WireLayout(WK.unsigned_, 32)) == 0x01020304);

    // u48 storage schemes from the design table: value 0x010203040506
    immutable ubyte[6] w48    = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06];
    immutable ubyte[6] w48_wr = [0x05, 0x06, 0x03, 0x04, 0x01, 0x02];
    immutable ubyte[6] w48_bs = [0x02, 0x01, 0x04, 0x03, 0x06, 0x05];
    immutable ubyte[6] w48_le = [0x06, 0x05, 0x04, 0x03, 0x02, 0x01];
    assert(wire_extract(w48, WireLayout(WK.unsigned_, 48, 0, WF.reverse)) == 0x010203040506);
    assert(wire_extract(w48_wr, WireLayout(WK.unsigned_, 48, 0, wf(WF.reverse | WF.swap_words))) == 0x010203040506);
    assert(wire_extract(w48_bs, WireLayout(WK.unsigned_, 48, 0, wf(WF.reverse | WF.swap_word_bytes))) == 0x010203040506);
    assert(wire_extract(w48_le, WireLayout(WK.unsigned_, 48, 0, wf(WF.reverse | WF.swap_words | WF.swap_word_bytes))) == 0x010203040506);

    // legacy word-reverse spellings: u32le_r = {swap_words}, u32be_r = {reverse, swap_words}
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 32, 0, WF.swap_words)) == 0x81808382);
    assert(wire_extract(buf, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_words))) == 0x82838081);

    // bit slices within a BE register: u3@5, s12@4, bool@3, u8@8
    immutable ubyte[2] reg = [0x9A, 0xBC];
    assert(wire_extract(reg, WireLayout(WK.unsigned_, 16, 0, WF.reverse)) == 0x9ABC);
    assert(wire_extract(reg, WireLayout(WK.unsigned_, 3, 5, WF.reverse, 2, 2)) == ((0x9ABC >> 5) & 0x7));
    assert(wire_extract(reg, WireLayout(WK.unsigned_, 8, 8, WF.reverse)) == 0x9A);  // high byte
    assert(wire_extract(reg, WireLayout(WK.unsigned_, 8, 0, WF.reverse, 2, 2)) == 0xBC);  // low byte
    assert(wire_extract(reg, WireLayout(WK.bool_, 1, 3, WF.reverse, 2, 2)) == ((0x9ABC >> 3) & 1));
    assert(wire_extract(reg, WireLayout(WK.signed_, 12, 4, WF.reverse)) == cast(ulong)long(0xFFFFFFFFFFFFF9AB));

    // 32-bit words
    immutable ubyte[8] q32 = [0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04];
    assert(wire_extract(q32, WireLayout(WK.unsigned_, 64, 0, wf(WF.reverse | WF.swap_words), 4)) == 0x0102030405060708);

    // floats
    immutable float f = 1234.5f;
    ubyte[4] fbuf;
    *cast(uint*)fbuf.ptr = *cast(const uint*)&f;
    assert(wire_extract_float(fbuf, WireLayout(WK.float_, 32)) == 1234.5f);
    ubyte[4] fbe = [fbuf[3], fbuf[2], fbuf[1], fbuf[0]];
    assert(wire_extract_float(fbe, WireLayout(WK.float_, 32, 0, WF.reverse)) == 1234.5f);

    // insert: full round trips and read-modify-write on shared registers
    ubyte[4] out4;
    wire_insert(out4, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_words)), 0x01020304);
    assert(out4 == cdab);
    wire_insert(out4, WireLayout(WK.unsigned_, 32, 0, wf(WF.reverse | WF.swap_word_bytes)), 0x01020304);
    assert(out4 == badc);
    ubyte[2] rmw = [0x9A, 0xBC];
    wire_insert(rmw, WireLayout(WK.unsigned_, 3, 5, WF.reverse, 2, 2), 0x2);
    assert(wire_extract(rmw, WireLayout(WK.unsigned_, 3, 5, WF.reverse, 2, 2)) == 0x2);
    assert(wire_extract(rmw, WireLayout(WK.unsigned_, 8, 8, WF.reverse)) == 0x9A);  // untouched bits preserved
    assert(wire_extract(rmw, WireLayout(WK.bool_, 1, 3, WF.reverse, 2, 2)) == ((0x9ABC >> 3) & 1));

    // byte-granular swizzles: the swapped-chars-in-words device
    immutable char[6] swapped = "EHLL!O";
    char[6] text, back;
    wire_image(swapped, WireLayout(WK.char_, 8, 0, WF.swap_word_bytes), text);
    assert(text == "HELLO!");
    wire_image_encode(text, WireLayout(WK.char_, 8, 0, WF.swap_word_bytes), back);
    assert(back == "EHLL!O");
    char[6] rev6;
    wire_image(swapped, WireLayout(WK.char_, 8, 0, WF.swap_words), rev6);
    assert(rev6 == "!OLLEH");
}


private:

ulong load_le(const(ubyte)* p, uint n) pure
{
    if (n == 8)
        return loadLittleEndian(cast(const(ulong)*)p);
    ulong v = 0;
    uint o = n & 4;
    if (o)
        v = loadLittleEndian(cast(const(uint)*)p);
    if (n & 2)
    {
        v |= ulong(loadLittleEndian(cast(const(ushort)*)(p + o))) << (o*8);
        o += 2;
    }
    if (n & 1)
        v |= ulong(p[o]) << (o*8);
    return v;
}

void store_le(ubyte* p, uint n, ulong v) pure
{
    if (n == 8)
        return storeLittleEndian(cast(ulong*)p, v);
    uint o = n & 4;
    if (o)
        storeLittleEndian(cast(uint*)p, cast(uint)v);
    if (n & 2)
    {
        storeLittleEndian(cast(ushort*)(p + o), cast(ushort)(v >> (o*8)));
        o += 2;
    }
    if (n & 1)
        p[o] = cast(ubyte)(v >> (o*8));
}

// self-inverse register transform: intra^(sw^swb), then reverse^(sw^rev)
ulong swizzle(ulong v, uint nbytes, WireLayout l) pure
{
    uint f = l.flags;
    if ((f ^ (f >> 1)) & 1) // sw^swb: swap bytes within words
    {
        v = ((v & 0x00FF00FF00FF00FF) << 8) | ((v >> 8) & 0x00FF00FF00FF00FF);
        uint ws = (l.pack >> 20) & 0x3;
        if (ws >= 2)
            v = ((v & 0x0000FFFF0000FFFF) << 16) | ((v >> 16) & 0x0000FFFF0000FFFF);
        if (ws == 3)
            v = (v << 32) | (v >> 32);
    }
    if ((f ^ (f >> 2)) & 1) // sw^rev: whole reverse over the container
        v = byte_reverse(v) >> ((8 - nbytes)*8);
    return v;
}
