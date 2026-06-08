module driver.windows.adapter_watcher;

version (Windows):

import urt.array;
import urt.atomic : atomicLoad, atomicStore, MemoryOrder;
import urt.lifetime : move;
import urt.string;
import urt.system : sleep;
import urt.sync.spsc : SPSCRing;
import urt.time : msecs;

import driver.windows.npcap;

import urt.internal.sys.windows;

nothrow @nogc:


enum AdapterEventKind : ubyte { added, removed }

// Fixed-size event so SPSCRing can copy it as a POD across threads.
// 128 bytes covers an NPF GUID name (~52) and an Intel description (~80) easily.
struct AdapterEvent
{
nothrow @nogc:
    enum NameMax = 128;
    enum DescMax = 128;

    AdapterEventKind kind;
    ubyte name_len;
    ubyte description_len;
    char[NameMax] name_buf = void;
    char[DescMax] description_buf = void;

    const(char)[] name() return const pure
        => name_buf[0 .. name_len];
    const(char)[] description() return const pure
        => description_buf[0 .. description_len];
}

alias AdapterRing = SPSCRing!(AdapterEvent, 16);


// Worker thread that calls pcap_findalldevs every ScanIntervalMs and reports
// add/remove events into per-consumer SPSC rings. Lives off the main update
// tick because pcap_findalldevs hits SCM/registry under the hood and routinely
// spikes 50-100ms on Windows.
//
// Threading rules:
// - scan_sync() runs on the main thread; safe to call ONLY before start().
// - start() spawns the worker; thereafter only the worker calls scan().
// - Both rings are SPSC: worker is sole producer, main thread is sole consumer.
// - Worker must NOT touch any data outside this struct.
struct AdapterWatcher
{
nothrow @nogc:
    enum ScanIntervalMs = 5000;
    enum TickMs         = 100;

    AdapterRing ethernet_ring;
    AdapterRing wifi_ring;

    void scan_sync()
    {
        scan();
    }

    bool start()
    {
        if (_thread !is null)
            return true;
        uint tid;
        _thread = CreateThread(null, 0, &thread_main, &this, 0, &tid);
        return _thread !is null;
    }

    // Signal the worker to exit and join it. Must run while the CRT and
    // NPCap DLL are still alive, hence the crt_destructor below.
    void stop()
    {
        if (_thread is null)
            return;
        atomicStore!(MemoryOrder.release)(_stop, true);
        WaitForSingleObject(_thread, INFINITE);
        CloseHandle(_thread);
        _thread = null;
    }

private:
    HANDLE _thread;
    shared bool _stop;
    Array!Entry _last;

    struct Entry
    {
    nothrow @nogc:
        char[AdapterEvent.NameMax] name_buf = void;
        char[AdapterEvent.DescMax] description_buf = void;
        ubyte name_len;
        ubyte description_len;
        bool is_ethernet;
        bool is_wifi;

        const(char)[] name() return const pure
            => name_buf[0 .. name_len];
        const(char)[] description() return const pure
            => description_buf[0 .. description_len];
    }

    extern(Windows) static uint thread_main(void* arg) nothrow @nogc
    {
        auto self = cast(AdapterWatcher*)arg;
        // Poll the stop flag at TickMs granularity so shutdown isn't blocked by
        // the full ScanIntervalMs.
        uint elapsed;
        while (!atomicLoad!(MemoryOrder.acquire)(self._stop))
        {
            sleep(TickMs.msecs);
            elapsed += TickMs;
            if (elapsed >= ScanIntervalMs)
            {
                self.scan();
                elapsed = 0;
            }
        }
        return 0;
    }

    void scan()
    {
        if (!npcap_loaded())
            return;

        pcap_if* interfaces;
        char[PCAP_ERRBUF_SIZE] errbuf = void;
        if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
            return;
        scope(exit) pcap_freealldevs(interfaces);

        Array!Entry current;
        for (auto dev = interfaces; dev; dev = dev.next)
        {
            if ((dev.flags & 0x1) != 0)
                continue;
            const(char)[] name = dev.name[0 .. dev.name.strlen];
            const(char)[] desc = dev.description ? dev.description[0 .. dev.description.strlen] : "";

            // Truncate beyond fixed-size buffer; NPF names and Windows descriptions
            // both fit comfortably in 128 chars in practice.
            if (name.length > AdapterEvent.NameMax)
                continue;
            if (desc.length > AdapterEvent.DescMax)
                desc = desc[0 .. AdapterEvent.DescMax];

            bool is_virtual = desc.contains_i("virtual") || desc.contains_i("miniport") ||
                              desc.contains_i("hyper-v") || desc.contains_i("bluetooth") ||
                              desc.contains_i("wi-fi direct") || desc.contains_i("virtualbox") ||
                              desc.contains_i("tunnel") || desc.contains_i("offload") ||
                              desc.contains_i("tap");
            if (is_virtual)
                continue;

            bool desc_wifi = desc.contains_i("wireless") || desc.contains_i("wi-fi") || desc.contains_i("wifi");
            bool flag_wifi = (dev.flags & 0x8) != 0;
            bool is_wifi = desc_wifi || flag_wifi;

            Entry e;
            e.name_buf[0 .. name.length] = name[];
            e.name_len = cast(ubyte)name.length;
            e.description_buf[0 .. desc.length] = desc[];
            e.description_len = cast(ubyte)desc.length;
            e.is_wifi = is_wifi;
            e.is_ethernet = !is_wifi;
            current ~= e;
        }

        foreach (ref old; _last[])
        {
            bool still = false;
            foreach (ref cur; current[])
            {
                if (cur.name == old.name)
                {
                    still = true;
                    break;
                }
            }
            if (!still)
            {
                if (old.is_ethernet)
                    push_event(ethernet_ring, AdapterEventKind.removed, old);
                if (old.is_wifi)
                    push_event(wifi_ring, AdapterEventKind.removed, old);
            }
        }
        foreach (ref cur; current[])
        {
            bool prev = false;
            foreach (ref old; _last[])
            {
                if (old.name == cur.name)
                {
                    prev = true;
                    break;
                }
            }
            if (!prev)
            {
                if (cur.is_ethernet)
                    push_event(ethernet_ring, AdapterEventKind.added, cur);
                if (cur.is_wifi)
                    push_event(wifi_ring, AdapterEventKind.added, cur);
            }
        }

        _last = current.move;
    }

    static void push_event(ref AdapterRing ring, AdapterEventKind kind, ref const Entry e)
    {
        AdapterEvent[] slot = ring.reserve(1);
        if (slot.length == 0)
            return;
        slot[0].kind = kind;
        slot[0].name_len = e.name_len;
        slot[0].description_len = e.description_len;
        slot[0].name_buf[0 .. e.name_len] = e.name_buf[0 .. e.name_len];
        slot[0].description_buf[0 .. e.description_len] = e.description_buf[0 .. e.description_len];
        ring.commit();
    }
}


__gshared AdapterWatcher g_adapter_watcher;


pragma(crt_destructor)
extern(C) void shutdown_adapter_watcher()
{
    g_adapter_watcher.stop();
}
