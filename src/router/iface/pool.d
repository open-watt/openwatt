module router.iface.pool;

import urt.mem.pagepool;

import router.iface.packet;

nothrow @nogc:


// Packet-pool policy: category sizing lives here, the mechanism lives in
// urt.mem.pagepool. A pooled packet page is [Packet slot][headroom][data]; headroom
// gives received packets prefix room so encapsulation doesn't force a copy.

enum packet_headroom = 64;

// receive budget filling an ether page exactly: 1522 baby-giant + slack
enum packet_page_rx_budget = 1600;

// Lazy so unittest binaries (which bypass module init) work with the defaults.
void packet_pool_init()
{
    version (Tiny)
    {
        static immutable PageCategoryConfig[2] categories = [
            PageCategoryConfig(384, 16, 4, 1),      // small: 256B payload after packet slot + headroom
            PageCategoryConfig(1728, 4, 4, 1),      // ether: 1600B, covers 1522 baby-giant + slack
        ];
    }
    else
    {
        static immutable PageCategoryConfig[2] categories = [
            PageCategoryConfig(384, 32, 8, 1),
            PageCategoryConfig(1728, 8, 8, 1),
        ];
    }
    page_pool_init(categories);
}

Packet* packet_page_alloc(size_t data_bytes)
{
    if (page_pool_num_categories() == 0)
        packet_pool_init();
    void[] page = page_alloc_for(Packet.sizeof + packet_headroom + data_bytes);
    if (!page.ptr)
        return null;
    return cast(Packet*)page.ptr;
}

void packet_page_free(Packet* p)
{
    page_free(p);
}

// The data area of a page from packet_page_alloc(data_bytes); receive paths fill
// this directly, then the interface frames the Packet in place around it.
ubyte[] packet_page_data(Packet* p, size_t data_bytes)
    => (cast(ubyte*)&p[1] + packet_headroom)[0 .. data_bytes];
