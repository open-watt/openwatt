module urt.zip;

import urt.crc;
import urt.endian;
import urt.hash;
import urt.mem.allocator;

alias zlib_crc = calculateCRC!(Algorithm.CRC32_ISO_HDLC);

nothrow @nogc:


// this is a port of tinflate (tiny inflate)

enum error_code : int
{
    OK         = 0,  /**< Success */
    DATA_ERROR = -3, /**< Input error */
    BUF_ERROR  = -5  /**< Not enough room for output */
}

enum gzip_flag : ubyte
{
    FTEXT    = 1,
    FHCRC    = 2,
    FEXTRA   = 4,
    FNAME    = 8,
    FCOMMENT = 16
}

error_code zlib_uncompress(const(void)[] source, void[] dest, out size_t destLen)
{
    const ubyte* src = cast(const ubyte*)source.ptr;
    uint sourceLen = cast(uint)source.length;

    if (sourceLen < 6)
        return error_code.DATA_ERROR;

    ubyte cmf = src[0];
    ubyte flg = src[1];

    // check checksum
    if ((256 * cmf + flg) % 31)
        return error_code.DATA_ERROR;

    // check method is deflate
    if ((cmf & 0x0F) != 8)
        return error_code.DATA_ERROR;

    // check window size is valid
    if ((cmf >> 4) > 7)
        return error_code.DATA_ERROR;

    // check there is no preset dictionary
    if (flg & 0x20)
        return error_code.DATA_ERROR;

    if (uncompress((src + 2)[0 .. sourceLen - 6], dest, destLen) != error_code.OK)
        return error_code.DATA_ERROR;

    if (adler32(dest[0 .. destLen]) != loadBigEndian!uint(cast(uint*)&src[sourceLen - 4]))
        return error_code.DATA_ERROR;

    return error_code.OK;
}

error_code gzip_uncompressed_length(const(void)[] source, out size_t destLen)
{
    const ubyte* src = cast(const ubyte*)source.ptr;
    uint sourceLen = cast(uint)source.length;

    if (sourceLen < 18)
        return error_code.DATA_ERROR;

    // check id bytes
    if (src[0] != 0x1F || src[1] != 0x8B)
        return error_code.DATA_ERROR;

    // check method is deflate
    if (src[2] != 8)
        return error_code.DATA_ERROR;

    ubyte flg = src[3];

    // check that reserved bits are zero
    if (flg & 0xE0)
        return error_code.DATA_ERROR;

    // get decompressed length
    destLen = loadLittleEndian!uint(cast(uint*)(src + sourceLen - 4));

    return error_code.OK;
}

error_code gzip_uncompress(const(void)[] source, void[] dest, out size_t destLen)
{
    const ubyte* src = cast(const ubyte*)source.ptr;
    uint sourceLen = cast(uint)source.length;

    if (sourceLen < 18)
        return error_code.DATA_ERROR;

    // check id bytes
    if (src[0] != 0x1F || src[1] != 0x8B)
        return error_code.DATA_ERROR;

    // check method is deflate
    if (src[2] != 8)
        return error_code.DATA_ERROR;

    ubyte flg = src[3];

    // check that reserved bits are zero
    if (flg & 0xE0)
        return error_code.DATA_ERROR;

    // skip base header of 10 bytes
    const(ubyte)* start = src + 10;

    // skip extra data if present
    if (flg & gzip_flag.FEXTRA)
    {
        uint xlen = loadLittleEndian!ushort(cast(ushort*)start);

        if (xlen > sourceLen - 12)
            return error_code.DATA_ERROR;

        start += xlen + 2;
    }

    // skip file name if present
    if (flg & gzip_flag.FNAME)
    {
        do
        {
            if (start - src >= sourceLen)
                return error_code.DATA_ERROR;
        }
        while (*start++);
    }

    // skip file comment if present
    if (flg & gzip_flag.FCOMMENT)
    {
        do
        {
            if (start - src >= sourceLen)
                return error_code.DATA_ERROR;
        }
        while (*start++);
    }

    // check header crc if present
    if (flg & gzip_flag.FHCRC)
    {
        uint hcrc;

        if (start - src > sourceLen - 2)
            return error_code.DATA_ERROR;

        hcrc = loadLittleEndian!ushort(cast(ushort*)start);

        if (hcrc != (zlib_crc(src[0 .. start - src]) & 0x0000FFFF))
            return error_code.DATA_ERROR;

        start += 2;
    }

    // get decompressed length
    uint dlen = loadLittleEndian!uint(cast(uint*)(src + sourceLen - 4));
    if (dlen > dest.length)
        return error_code.BUF_ERROR;

    if ((src + sourceLen) - start < 8)
        return error_code.DATA_ERROR;

    if (uncompress(start[0 .. (src + sourceLen) - start - 8], dest, destLen) != error_code.OK)
        return error_code.DATA_ERROR;

    if (destLen != dlen)
        return error_code.DATA_ERROR;

    // check CRC32 checksum
    if (zlib_crc(dest[0..dlen]) != loadLittleEndian!uint(cast(uint*)(src + sourceLen - 8)))
        return error_code.DATA_ERROR;

    return error_code.OK;
}

error_code uncompress(const(void)[] source, void[] dest, out size_t destLen)
{
    data d;

    d.source = cast(const(ubyte)*)source.ptr;
    d.source_end = d.source + source.length;
    d.tag = 0;
    d.bitcount = 0;
    d.overflow = 0;

    d.dest = cast(ubyte*)dest.ptr;
    d.dest_start = d.dest;
    d.dest_end = d.dest + dest.length;

    int bfinal;
    do
    {
        // Read final block flag
        bfinal = getbits(&d, 1);

        // Read block type (2 bits)
        uint btype = getbits(&d, 2);

        // Decompress block
        error_code res;
        switch (btype)
        {
            case 0:
                // Decompress uncompressed block
                res = inflate_uncompressed_block(&d);
                break;
            case 1:
                // Decompress block with fixed Huffman trees
                res = inflate_fixed_block(&d);
                break;
            case 2:
                // Decompress block with dynamic Huffman trees
                res = inflate_dynamic_block(&d);
                break;
            default:
                res = error_code.DATA_ERROR;
                break;
        }
        if (res != error_code.OK)
            return res;
    }
    while (!bfinal);

    if (d.overflow)
        return error_code.DATA_ERROR;

    destLen = d.dest - d.dest_start;

    return error_code.OK;
}


// this is a port of the deflate function from stb_image_write.h
// -------------------------------------------------------------

// NOTE: THIS IMPLEMENTATION IS NOT EFFICIENT!

ubyte[] zlib_compress(const void[] message, int quality)
{
    import urt.mem : memcpy, memmove;

    __gshared immutable ushort[] lengthc = [ 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258, 259 ];
    __gshared immutable ubyte[] lengtheb = [ 0,0,0,0,0,0,0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,  4,  5,  5,  5,  5,  0 ];
    __gshared immutable ushort[] distc =   [ 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577, 32768 ];
    __gshared immutable ubyte[] disteb =   [ 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 ];

    int data_len = cast(int)message.length;
    ubyte* data = cast(ubyte*)message.ptr;

    uint bitbuf=0;
    int i,j, bitcount=0;
    ubyte* out_ = null;
    ubyte*** hash_table = cast(ubyte***) STBIW_MALLOC(stbiw__ZHASH * ubyte**.sizeof);
    if (hash_table == null)
        return null;
    if (quality < 5)
        quality = 5;

    void stbiw__zlib_flush()
    {
        out_ = stbiw__zlib_flushf(out_, &bitbuf, &bitcount);
    }
    void stbiw__zlib_add(T, U)(T code, U codebits)
    {
        bitbuf |= code << bitcount;
        bitcount += codebits;
        stbiw__zlib_flush();
    }
    void stbiw__zlib_huffa(T, U)(T b, U c)
    {
        stbiw__zlib_add(stbiw__zlib_bitrev(b, c), c);
    }

    // default huffman tables
    void stbiw__zlib_huff1(T)(T n) => stbiw__zlib_huffa(0x30 + n, 8);
    void stbiw__zlib_huff2(T)(T n) => stbiw__zlib_huffa(0x190 + n-144, 9);
    void stbiw__zlib_huff3(T)(T n) => stbiw__zlib_huffa(0 + n-256,7);
    void stbiw__zlib_huff4(T)(T n) => stbiw__zlib_huffa(0xc0 + n-280,8);
    void stbiw__zlib_huff(T)(T n)  => (n <= 143 ? stbiw__zlib_huff1(n) : n <= 255 ? stbiw__zlib_huff2(n) : n <= 279 ? stbiw__zlib_huff3(n) : stbiw__zlib_huff4(n));
    void stbiw__zlib_huffb(ubyte n) => (n <= 143 ? stbiw__zlib_huff1(n) : stbiw__zlib_huff2(n));

    stbiw__sbpush(out_, 0x78);   // DEFLATE 32K window
    stbiw__sbpush(out_, 0x5e);   // FLEVEL = 1
    stbiw__zlib_add(1,1);  // BFINAL = 1
    stbiw__zlib_add(1,2);  // BTYPE = 1 -- fixed huffman

    for (i=0; i < stbiw__ZHASH; ++i)
        hash_table[i] = null;

    i=0;
    while (i < data_len-3)
    {
        // hash next 3 bytes of data to be compressed
        int h = stbiw__zhash(data+i)&(stbiw__ZHASH-1), best=3;
        ubyte* bestloc = null;
        ubyte** hlist = hash_table[h];
        int n = stbiw__sbcount(hlist);
        for (j=0; j < n; ++j)
        {
            if (hlist[j]-data > i-32768)
            {
                // if entry lies within window
                int d = stbiw__zlib_countm(hlist[j], data+i, data_len-i);
                if (d >= best)
                {
                    best=d;
                    bestloc=hlist[j];
                }
            }
        }
        // when hash table entry is too long, delete half the entries
        if (hash_table[h] && stbiw__sbn(hash_table[h]) == 2*quality)
        {
            memmove(hash_table[h], hash_table[h]+quality, hash_table[h][0].sizeof*quality);
            stbiw__sbn(hash_table[h]) = quality;
        }
        stbiw__sbpush(hash_table[h], data + i);

        if (bestloc)
        {
            // "lazy matching" - check match at *next* byte, and if it's better, do cur byte as literal
            h = stbiw__zhash(data+i+1)&(stbiw__ZHASH-1);
            hlist = hash_table[h];
            n = stbiw__sbcount(hlist);
            for (j=0; j < n; ++j)
            {
                if (hlist[j]-data > i-32767)
                {
                    int e = stbiw__zlib_countm(hlist[j], data+i+1, data_len-i-1);
                    if (e > best)
                    {
                        // if next match is better, bail on current match
                        bestloc = null;
                        break;
                    }
                }
            }
        }

        if (bestloc) {
            int d = cast(int)(data+i - bestloc); // distance back
            assert(d <= 32767 && best <= 258);
            for (j=0; best > lengthc[j+1]-1; ++j)
            {}
            stbiw__zlib_huff(j+257);
            if (lengtheb[j])
                stbiw__zlib_add(best - lengthc[j], lengtheb[j]);
            for (j=0; d > distc[j+1]-1; ++j)
            {}
            stbiw__zlib_add(stbiw__zlib_bitrev(j,5),5);
            if (disteb[j])
                stbiw__zlib_add(d - distc[j], disteb[j]);
            i += best;
        }
        else
        {
            stbiw__zlib_huffb(data[i]);
            ++i;
        }
    }
    // write out_ final bytes
    for (;i < data_len; ++i)
        stbiw__zlib_huffb(data[i]);
    stbiw__zlib_huff(256); // end of block
    // pad with 0 bits to byte boundary
    while (bitcount)
        stbiw__zlib_add(0,1);

    for (i=0; i < stbiw__ZHASH; ++i)
        stbiw__sbfree(hash_table[i]);
    STBIW_FREE(hash_table);

    // store uncompressed instead if compression was worse
    if (stbiw__sbn(out_) > data_len + 2 + ((data_len+32766)/32767)*5)
    {
        stbiw__sbn(out_) = 2;  // truncate to DEFLATE 32K window and FLEVEL = 1
        for (j = 0; j < data_len;)
        {
            int blocklen = data_len - j;
            if (blocklen > 32767)
                blocklen = 32767;
            stbiw__sbpush(out_, data_len - j == blocklen); // BFINAL = ?, BTYPE = 0 -- no compression
            stbiw__sbpush(out_, STBIW_UCHAR(blocklen)); // LEN
            stbiw__sbpush(out_, STBIW_UCHAR(blocklen >> 8));
            stbiw__sbpush(out_, STBIW_UCHAR(~blocklen)); // NLEN
            stbiw__sbpush(out_, STBIW_UCHAR(~blocklen >> 8));
            memcpy(out_+stbiw__sbn(out_), data+j, blocklen);
            stbiw__sbn(out_) += blocklen;
            j += blocklen;
        }
    }

    {
        // compute adler32 on input
        uint s1=1, s2=0;
        int blocklen = cast(int)(data_len % 5552);
        j=0;
        while (j < data_len)
        {
            for (i=0; i < blocklen; ++i) { s1 += data[j+i]; s2 += s1; }
            s1 %= 65521; s2 %= 65521;
            j += blocklen;
            blocklen = 5552;
        }
        stbiw__sbpush(out_, STBIW_UCHAR(s2 >> 8));
        stbiw__sbpush(out_, STBIW_UCHAR(s2));
        stbiw__sbpush(out_, STBIW_UCHAR(s1 >> 8));
        stbiw__sbpush(out_, STBIW_UCHAR(s1));
    }

    size_t out_len = stbiw__sbn(out_);
    // make returned pointer freeable
    memmove(stbiw__sbraw(out_), out_, out_len);
    return (cast(ubyte*)stbiw__sbraw(out_))[0 .. out_len];
}


unittest
{
//    ubyte[256] buffer = void;

    void[] result = zlib_compress("123456789012345678901234567890", 9);
    assert(result.length <= 20);

    ubyte[256] decompressBuffer = void;
    size_t len;

    zlib_uncompress(result, decompressBuffer, len);
    assert(len == 30);
}


private:

enum stbiw__ZHASH = 16384;

void* STBIW_MALLOC(size_t size)
    => defaultAllocator().alloc(size).ptr;

void* STBIW_REALLOC_SIZED(void* ptr, size_t old_size, size_t new_size)
    => defaultAllocator().realloc(ptr[0..old_size], new_size).ptr;

void STBIW_FREE(void* ptr)
{
    defaultAllocator().free(ptr[0..0]);
}

ubyte STBIW_UCHAR(T)(T x)
    => cast(ubyte)(x & 0xff);

// stretchy buffer; stbiw__sbpush() == vector<>::push_back() -- stbiw__sbcount() == vector<>::size()
int* stbiw__sbraw(T)(T* a)  => cast(int*)a - 2;
ref int stbiw__sbm(T)(T* a) => (cast(int*)a - 2)[0];
ref int stbiw__sbn(T)(T* a) => (cast(int*)a - 2)[1];

bool stbiw__sbneedgrow(T)(T* a, int n)       => !a || (stbiw__sbn(a) + n >= stbiw__sbm(a));
void* stbiw__sbmaybegrow(T)(ref T* a, int n) => stbiw__sbneedgrow(a,n) ? stbiw__sbgrow(a, n) : null;
void* stbiw__sbgrow(T)(ref T* a, int n)      => stbiw__sbgrowf(cast(void**)&a, n, T.sizeof);

auto stbiw__sbcount(T)(T* a)   => a ? stbiw__sbn(a) : 0;
auto stbiw__sbpush(T)(ref T* a, T v)
{
    stbiw__sbmaybegrow(a, 1);
    return (a[stbiw__sbn(a)++] = v);
}
void stbiw__sbfree(T)(auto ref T a)
{
    if (a)
        STBIW_FREE(cast(int*)a - 2);
}

void* stbiw__sbgrowf(void** arr, int increment, int itemsize)
{
    int m = *arr ? 2*stbiw__sbm(*arr) + increment : increment + 1;
    void* p = STBIW_REALLOC_SIZED(*arr ? stbiw__sbraw(*arr) : null, *arr ? int.sizeof*2 + stbiw__sbm(*arr)*itemsize : 0, int.sizeof*2 + itemsize*m);
    assert(p);
    if (p)
    {
        if (!*arr) (cast(int*)p)[1] = 0;
        *arr = cast(void*) (cast(int*)p + 2);
        stbiw__sbm(*arr) = m;
    }
    return *arr;
}

ubyte* stbiw__zlib_flushf(ubyte* data, uint* bitbuffer, int* bitcount)
{
    while (*bitcount >= 8)
    {
        stbiw__sbpush(data, STBIW_UCHAR(*bitbuffer));
        *bitbuffer >>= 8;
        *bitcount -= 8;
    }
    return data;
}

int stbiw__zlib_bitrev(int code, int codebits)
{
    int res = 0;
    while (codebits--)
    {
        res = (res << 1) | (code & 1);
        code >>= 1;
    }
    return res;
}

uint stbiw__zlib_countm(const ubyte* a, const ubyte* b, int limit)
{
    int i;
    for (i = 0; i < limit && i < 258; ++i)
        if (a[i] != b[i])
            break;
    return i;
}

uint stbiw__zhash(const ubyte* data)
{
    uint hash = data[0] + (data[1] << 8) + (data[2] << 16);
    hash ^= hash << 3;
    hash += hash >> 5;
    hash ^= hash << 4;
    hash += hash >> 17;
    hash ^= hash << 25;
    hash += hash >> 6;
    return hash;
}


//----------------------------------------------------


/* -- Internal data structures -- */

struct tree
{
    ushort[16] counts; /* Number of codes with a given length */
    ushort[288] symbols; /* Symbols sorted by code */
    int max_sym;
}

struct data
{
    const(ubyte)* source;
    const(ubyte)* source_end;
    uint tag;
    int bitcount;
    int overflow;

    ubyte*dest_start;
    ubyte*dest;
    ubyte*dest_end;

    tree ltree; /* Literal/length tree */
    tree dtree; /* Distance tree */
}


void build_fixed_trees(tree *lt, tree *dt)
{
    ubyte i;

    /* Build fixed literal/length tree */
    for (i = 0; i < 16; ++i)
        lt.counts[i] = 0;

    lt.counts[7] = 24;
    lt.counts[8] = 152;
    lt.counts[9] = 112;

    for (i = 0; i < 24; ++i)
        lt.symbols[i] = 256 + i;
    for (i = 0; i < 144; ++i)
        lt.symbols[24 + i] = i;
    for (i = 0; i < 8; ++i)
        lt.symbols[24 + 144 + i] = 280 + i;
    for (i = 0; i < 112; ++i)
        lt.symbols[24 + 144 + 8 + i] = 144 + i;

    lt.max_sym = 285;

    /* Build fixed distance tree */
    for (i = 0; i < 16; ++i)
        dt.counts[i] = 0;

    dt.counts[5] = 32;

    for (i = 0; i < 32; ++i)
        dt.symbols[i] = i;

    dt.max_sym = 29;
}

/* Given an array of code lengths, build a tree */
error_code build_tree(tree *t, const(ubyte)* lengths, ushort num)
{
    ushort[16] offs = void;
    uint available;
    ushort i, num_codes;

    assert(num <= 288);

    for (i = 0; i < 16; ++i)
        t.counts[i] = 0;

    t.max_sym = -1;

    /* Count number of codes for each non-zero length */
    for (i = 0; i < num; ++i)
    {
        assert(lengths[i] <= 15);

        if (lengths[i])
        {
            t.max_sym = i;
            t.counts[lengths[i]]++;
        }
    }

    /* Compute offset table for distribution sort */
    for (available = 1, num_codes = 0, i = 0; i < 16; ++i)
    {
        ushort used = t.counts[i];

        /* Check length contains no more codes than available */
        if (used > available)
            return error_code.DATA_ERROR;
        available = 2 * (available - used);

        offs[i] = num_codes;
        num_codes += used;
    }

    /*
    * Check all codes were used, or for the special case of only one
    * code that it has length 1
    */
    if ((num_codes > 1 && available > 0) || (num_codes == 1 && t.counts[1] != 1))
        return error_code.DATA_ERROR;

    /* Fill in symbols sorted by code */
    for (i = 0; i < num; ++i)
    {
        if (lengths[i])
            t.symbols[offs[lengths[i]]++] = i;
    }

    /*
    * For the special case of only one code (which will be 0) add a
    * code 1 which results in a symbol that is too large
    */
    if (num_codes == 1)
    {
        t.counts[1] = 2;
        t.symbols[1] = cast(ushort)(t.max_sym + 1);
    }

    return error_code.OK;
}

/* -- Decode functions -- */

void refill(data *d, int num)
{
    assert(num >= 0 && num <= 32);

    /* Read bytes until at least num bits available */
    while (d.bitcount < num) {
        if (d.source != d.source_end)
            d.tag |= cast(uint)*d.source++ << d.bitcount;
        else
            d.overflow = 1;
        d.bitcount += 8;
    }

    assert(d.bitcount <= 32);
}

uint getbits_no_refill(data *d, int num)
{
    assert(num >= 0 && num <= d.bitcount);

    uint bits = d.tag & ((1UL << num) - 1);
    d.tag >>= num;
    d.bitcount -= num;
    return bits;
}

/* Get num bits from source stream */
uint getbits(data *d, int num)
{
    refill(d, num);
    return getbits_no_refill(d, num);
}

/* Read a num bit value from stream and add base */
uint getbits_base(data *d, int num, int base)
{
    return base + (num ? getbits(d, num) : 0);
}

/* Given a data stream and a tree, decode a symbol */
int decode_symbol(data *d, const tree *t)
{
    int base = 0, offs = 0;

    /*
    * Get more bits while code index is above number of codes
    *
    * Rather than the actual code, we are computing the position of the
    * code in the sorted order of codes, which is the index of the
    * corresponding symbol.
    *
    * Conceptually, for each code length (level in the tree), there are
    * counts[len] leaves on the left and internal nodes on the right.
    * The index we have decoded so far is base + offs, and if that
    * falls within the leaves we are done. Otherwise we adjust the range
    * of offs and add one more bit to it.
    */
    for (int len = 1; ; ++len)
    {
        offs = 2 * offs + getbits(d, 1);

        assert(len <= 15);

        if (offs < t.counts[len])
            break;

        base += t.counts[len];
        offs -= t.counts[len];
    }

    assert(base + offs >= 0 && base + offs < 288);

    return t.symbols[base + offs];
}

error_code decode_trees(data *d, tree *lt, tree *dt)
{
    /* Special ordering of code length codes */
    __gshared immutable ubyte[19] clcidx = [ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 ];

    ubyte[288 + 32] lengths = void;
    uint i, num, length;

    /* Get 5 bits HLIT (257-286) */
    ushort hlit = cast(ushort)getbits_base(d, 5, 257);

    /* Get 5 bits HDIST (1-32) */
    ubyte hdist = cast(ubyte)getbits_base(d, 5, 1);

    /* Get 4 bits HCLEN (4-19) */
    ubyte hclen = cast(ubyte)getbits_base(d, 4, 4);

    /*
    * The RFC limits the range of HLIT to 286, but lists HDIST as range
    * 1-32, even though distance codes 30 and 31 have no meaning. While
    * we could allow the full range of HLIT and HDIST to make it possible
    * to decode the fixed trees with this function, we consider it an
    * error here.
    *
    * See also: https://github.com/madler/zlib/issues/82
    */
    if (hlit > 286 || hdist > 30)
        return error_code.DATA_ERROR;

    for (i = 0; i < 19; ++i)
        lengths[i] = 0;

    /* Read code lengths for code length alphabet */
    for (i = 0; i < hclen; ++i)
    {
        /* Get 3 bits code length (0-7) */
        ubyte clen = cast(ubyte)getbits(d, 3);

        lengths[clcidx[i]] = clen;
    }

    /* Build code length tree (in literal/length tree to save space) */
    error_code res = build_tree(lt, lengths.ptr, 19);
    if (res != error_code.OK)
        return res;

    /* Check code length tree is not empty */
    if (lt.max_sym == -1)
        return error_code.DATA_ERROR;

    /* Decode code lengths for the dynamic trees */
    for (num = 0; num < hlit + hdist; )
    {
        int sym = decode_symbol(d, lt);

        if (sym > lt.max_sym)
            return error_code.DATA_ERROR;

        switch (sym)
        {
            case 16:
                /* Copy previous code length 3-6 times (read 2 bits) */
                if (num == 0) {
                    return error_code.DATA_ERROR;
                }
                sym = lengths[num - 1];
                length = getbits_base(d, 2, 3);
                break;
            case 17:
                /* Repeat code length 0 for 3-10 times (read 3 bits) */
                sym = 0;
                length = getbits_base(d, 3, 3);
                break;
            case 18:
                /* Repeat code length 0 for 11-138 times (read 7 bits) */
                sym = 0;
                length = getbits_base(d, 7, 11);
                break;
            default:
                /* Values 0-15 represent the actual code lengths */
                length = 1;
                break;
        }

        if (length > hlit + hdist - num)
            return error_code.DATA_ERROR;

        while (length--)
            lengths[num++] = cast(ubyte)sym;
    }

    /* Check EOB symbol is present */
    if (lengths[256] == 0)
        return error_code.DATA_ERROR;

    /* Build dynamic trees */
    res = build_tree(lt, lengths.ptr, hlit);

    if (res != error_code.OK)
        return res;

    res = build_tree(dt, lengths.ptr + hlit, hdist);

    if (res != error_code.OK)
        return res;

    return error_code.OK;
}

/* -- Block inflate functions -- */

/* Given a stream and two trees, inflate a block of data */
error_code inflate_block_data(data *d, tree *lt, tree *dt)
{
    /* Extra bits and base tables for length codes */
    __gshared immutable ubyte[30] length_bits = [ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 127 ];
    __gshared immutable ushort[30] length_base = [ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0 ];

    /* Extra bits and base tables for distance codes */
    __gshared immutable ubyte[30] dist_bits = [ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 ];
    __gshared immutable ushort[30] dist_base = [ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 ];

    for (;;)
    {
        int sym = decode_symbol(d, lt);

        /* Check for overflow in bit reader */
        if (d.overflow)
            return error_code.DATA_ERROR;

        if (sym < 256)
        {
            if (d.dest == d.dest_end)
                return error_code.BUF_ERROR;
            *d.dest++ = cast(ubyte)sym;
        }
        else
        {
            int length, dist, offs;
            int i;

            /* Check for end of block */
            if (sym == 256)
                return error_code.OK;

            /* Check sym is within range and distance tree is not empty */
            if (sym > lt.max_sym || sym - 257 > 28 || dt.max_sym == -1)
                return error_code.DATA_ERROR;

            sym -= 257;

            /* Possibly get more bits from length code */
            length = getbits_base(d, length_bits[sym], length_base[sym]);

            dist = decode_symbol(d, dt);

            /* Check dist is within range */
            if (dist > dt.max_sym || dist > 29)
                return error_code.DATA_ERROR;

            /* Possibly get more bits from distance code */
            offs = getbits_base(d, dist_bits[dist], dist_base[dist]);

            if (offs > d.dest - d.dest_start)
                return error_code.DATA_ERROR;

            if (d.dest_end - d.dest < length)
                return error_code.BUF_ERROR;

            /* Copy match */
            for (i = 0; i < length; ++i)
                d.dest[i] = d.dest[i - offs];

            d.dest += length;
        }
    }
}

/* Inflate an uncompressed block of data */
error_code inflate_uncompressed_block(data *d)
{
    if (d.source_end - d.source < 4)
        return error_code.DATA_ERROR;

    /* Get length */
    uint length = loadLittleEndian!ushort(cast(ushort*)d.source);

    /* Get one's complement of length */
    uint invlength = loadLittleEndian!ushort(cast(ushort*)(d.source + 2));

    /* Check length */
    if (length != (~invlength & 0x0000FFFF))
        return error_code.DATA_ERROR;

    d.source += 4;

    if (d.source_end - d.source < length)
        return error_code.DATA_ERROR;

    if (d.dest_end - d.dest < length)
        return error_code.BUF_ERROR;

    /* Copy block */
    while (length--)
        *d.dest++ = *d.source++;

    /* Make sure we start next block on a byte boundary */
    d.tag = 0;
    d.bitcount = 0;

    return error_code.OK;
}

error_code inflate_fixed_block(data *d)
{
    build_fixed_trees(&d.ltree, &d.dtree);
    return inflate_block_data(d, &d.ltree, &d.dtree);
}

error_code inflate_dynamic_block(data *d)
{
    error_code res = decode_trees(d, &d.ltree, &d.dtree);
    if (res != error_code.OK)
        return res;
    return inflate_block_data(d, &d.ltree, &d.dtree);
}
