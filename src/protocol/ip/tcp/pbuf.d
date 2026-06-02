/**
 * @file protocol.ip.tcp.pbuf
 * MVP pbuf — packet buffer for the TCP port.
 *
 * lwIP's pbuf is a chained, refcounted byte buffer with headroom for
 * prepending protocol headers. The ported TCP source assumes ~12 functions:
 * alloc, free, ref, realloc, add_header, remove_header, cat, chain, dechain,
 * copy_partial, clen, split_64k.
 *
 * Notes:
 *   - pbuf_alloc(PBUF_RAM) packs the pbuf struct, headroom, and payload as
 *     one heap block. Fine for MVP; later we'll want a slab/freelist.
 *   - pbuf_realloc only shrinks (lwIP only ever shrinks here).
 *   - We added an `_alloc_size` field so pbuf_free can pass the right slice
 *     length to allocators that care (region/pool). Not in upstream pbuf.
 *   - PBUF_REF / PBUF_POOL are minimal stubs; only PBUF_RAM and PBUF_ROM
 *     are exercised by TCP at this stage.
 */
module protocol.ip.tcp.pbuf;

version (UseInternalIPStack):

import urt.mem.allocator : defaultAllocator;
import urt.mem : memcpy, memzero;

nothrow @nogc:

/* Layer / headroom hint passed to pbuf_alloc.
   Numeric value = bytes of headroom reserved for prependable headers. */
alias pbuf_layer = int;
enum : pbuf_layer {
    PBUF_TRANSPORT = 54,    /* eth + ipv4 + tcp */
    PBUF_IP        = 34,    /* eth + ipv4 */
    PBUF_LINK      = 14,    /* eth */
    PBUF_RAW_TX    =  0,
    PBUF_RAW       =  0,
}

/* Storage backing for a pbuf. Low 4 bits of pbuf.type_internal. */
alias pbuf_type = int;
enum : pbuf_type {
    PBUF_RAM,   /* payload is heap-allocated with the struct */
    PBUF_POOL,  /* payload comes from a fixed pool (MVP: treat as RAM) */
    PBUF_ROM,   /* payload points at external read-only memory */
    PBUF_REF,   /* payload points at external read-write memory */
}

/* Type-flag bits OR'd into pbuf.type_internal above the low nibble. */
enum PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS = 0x80;
enum PBUF_TYPE_FLAG_DATA_VOLATILE          = 0x40;

/* Per-pbuf flags (pbuf.flags). */
enum PBUF_FLAG_PUSH       = 0x01;
enum PBUF_FLAG_IS_CUSTOM  = 0x02;
enum PBUF_FLAG_MAC_FILTER = 0x04;
enum PBUF_FLAG_LLBCAST    = 0x08;
enum PBUF_FLAG_LLMCAST    = 0x10;
enum PBUF_FLAG_TCP_FIN    = 0x20;

struct pbuf
{
    pbuf*   next;
    void*   payload;
    ushort  tot_len;        /* total length of chain from this pbuf onward */
    ushort  len;            /* length of this pbuf's payload */
    ubyte   type_internal;  /* low 4 bits = pbuf_type, upper = PBUF_TYPE_FLAG_* */
    ubyte   flags;          /* PBUF_FLAG_* */
    ubyte   ref_;           /* refcount; `ref` is a D keyword */
    ubyte   _pad;
    /* MVP-only: total bytes the allocator handed us, for the matching free. */
    uint    _alloc_size;
}

alias pbuf_rom = pbuf;

private size_t headroom_for(pbuf_layer layer) pure
{
    switch (layer) {
        case PBUF_TRANSPORT: return 54;
        case PBUF_IP:        return 34;
        case PBUF_LINK:      return 14;
        default:             return 0;
    }
}

/* Payload must start at a 4-byte boundary so packed-but-naturally-aligned
   wire structs (tcp_hdr, ip_hdr) parse without unaligned loads. We round
   (pbuf.sizeof + headroom) up to MEM_ALIGNMENT, padding the headroom. */
enum MEM_ALIGNMENT = 4;
private size_t payload_offset(size_t headroom) pure
{
    size_t off = pbuf.sizeof + headroom;
    return (off + (MEM_ALIGNMENT - 1)) & ~(MEM_ALIGNMENT - 1);
}

pbuf* pbuf_alloc(pbuf_layer layer, ushort length, pbuf_type type)
{
    size_t headroom = headroom_for(layer);

    if (type == PBUF_RAM || type == PBUF_POOL) {
        size_t off = payload_offset(headroom);
        size_t total = off + length;
        void[] block = defaultAllocator.alloc(total);
        if (block.ptr is null)
            return null;
        pbuf* p = cast(pbuf*)block.ptr;
        p.next         = null;
        p.payload      = cast(void*)(cast(ubyte*)block.ptr + off);
        p.tot_len      = length;
        p.len          = length;
        p.type_internal = cast(ubyte)(type | PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS);
        p.flags        = 0;
        p.ref_         = 1;
        p._alloc_size  = cast(uint)total;
        return p;
    }
    else
    {
        size_t total = pbuf.sizeof;
        void[] block = defaultAllocator.alloc(total);
        if (block.ptr is null)
            return null;
        pbuf* p = cast(pbuf*)block.ptr;
        p.next         = null;
        p.payload      = null;
        p.tot_len      = length;
        p.len          = length;
        ubyte ti = cast(ubyte)type;
        if (type == PBUF_REF)
            ti |= PBUF_TYPE_FLAG_DATA_VOLATILE;
        p.type_internal = ti;
        p.flags        = 0;
        p.ref_         = 1;
        p._alloc_size  = cast(uint)total;
        return p;
    }
}

ubyte pbuf_free(pbuf* p)
{
    ubyte count = 0;
    while (p !is null) {
        pbuf* q = p.next;
        if (--p.ref_ != 0)
            break;
        defaultAllocator.free((cast(void*)p)[0 .. p._alloc_size]);
        p = q;
        ++count;
    }
    return count;
}

void pbuf_ref(pbuf* p)
{
    if (p !is null)
        ++p.ref_;
}

ushort pbuf_clen(const(pbuf)* p)
{
    ushort n = 0;
    while (p !is null) {
        ++n;
        p = p.next;
    }
    return n;
}

void pbuf_cat(pbuf* head, pbuf* tail)
{
    if (head is null || tail is null)
        return;
    pbuf* it = head;
    while (it.next !is null)
        it = it.next;
    it.next = tail;
    ushort add = tail.tot_len;
    for (pbuf* w = head; w !is null; w = w.next) {
        w.tot_len = cast(ushort)(w.tot_len + add);
        if (w is it) break;
    }
}

void pbuf_chain(pbuf* head, pbuf* tail)
{
    pbuf_cat(head, tail);
    pbuf_ref(tail);
}

pbuf* pbuf_dechain(pbuf* p)
{
    if (p is null)
        return null;
    pbuf* q = p.next;
    p.next = null;
    p.tot_len = p.len;
    return q;
}

void pbuf_realloc(pbuf* p, ushort new_len)
{
    if (p is null || new_len >= p.tot_len)
        return;
    ushort remaining = new_len;
    pbuf* it = p;
    while (it !is null) {
        if (remaining <= it.len) {
            it.len = remaining;
            it.tot_len = remaining;
            pbuf* drop = it.next;
            it.next = null;
            pbuf_free(drop);
            ushort acc = remaining;
            for (pbuf* w = p; w !is it; w = w.next)
                acc = cast(ushort)(acc + w.len);
            for (pbuf* w = p; w !is null && w !is it; w = w.next) {
                w.tot_len = acc;
                acc = cast(ushort)(acc - w.len);
            }
            return;
        }
        it.tot_len = new_len;
        remaining = cast(ushort)(remaining - it.len);
        it = it.next;
    }
}

ubyte pbuf_add_header(pbuf* p, size_t header_size_increment)
{
    if (p is null) return 1;
    ubyte type = p.type_internal & 0x0F;
    if (type != PBUF_RAM && type != PBUF_POOL)
        return 1;
    ubyte* struct_end = cast(ubyte*)p + pbuf.sizeof;
    size_t available  = cast(ubyte*)p.payload - struct_end;
    if (header_size_increment > available)
        return 1;
    p.payload = cast(ubyte*)p.payload - header_size_increment;
    p.len     = cast(ushort)(p.len + header_size_increment);
    p.tot_len = cast(ushort)(p.tot_len + header_size_increment);
    return 0;
}

ubyte pbuf_remove_header(pbuf* p, size_t header_size)
{
    if (p is null || header_size > p.len) return 1;
    p.payload = cast(ubyte*)p.payload + header_size;
    p.len     = cast(ushort)(p.len - header_size);
    p.tot_len = cast(ushort)(p.tot_len - header_size);
    return 0;
}

ushort pbuf_copy_partial(const(pbuf)* buf, void* dataptr, ushort len, ushort offset)
{
    if (buf is null || dataptr is null)
        return 0;
    ushort copied = 0;
    const(pbuf)* p = buf;
    while (p !is null && offset >= p.len) {
        offset = cast(ushort)(offset - p.len);
        p = p.next;
    }
    while (p !is null && copied < len) {
        ushort avail = cast(ushort)(p.len - offset);
        ushort take  = cast(ushort)(len - copied);
        if (take > avail) take = avail;
        memcpy(cast(ubyte*)dataptr + copied,
               cast(const(ubyte)*)p.payload + offset,
               take);
        copied = cast(ushort)(copied + take);
        offset = 0;
        p = p.next;
    }
    return copied;
}

/* Copy chain `from` into chain `into`. */
int pbuf_copy(pbuf* into, const(pbuf)* from)
{
    import protocol.ip.tcp : ERR_OK, ERR_ARG, ERR_VAL;
    if (into is null || from is null || into.tot_len < from.tot_len)
        return ERR_ARG;
    ushort copied = pbuf_copy_partial(from, into.payload, from.tot_len, 0);
    return copied == from.tot_len ? ERR_OK : ERR_VAL;
}

/* Used by tcp_in.c only when TCP_QUEUE_OOSEQ && LWIP_WND_SCALE. MVP: no-op. */
void pbuf_split_64k(pbuf* p, pbuf** rest)
{
    if (rest !is null) *rest = null;
}
