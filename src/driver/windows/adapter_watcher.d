module driver.windows.adapter_watcher;

version (Windows):

import urt.array;
import urt.atomic : atomicLoad, atomicStore, MemoryOrder;
import urt.lifetime : move;
import urt.log : writeError;
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
// - acquire/release and both consumers run on the main thread.
// - The first acquire scans before starting the sole producer thread.
// - Only the last release joins the worker and resets its state.
// - Both rings are SPSC: worker is sole producer, main thread is sole consumer.
// - Worker must NOT touch any data outside this struct.
struct AdapterWatcher
{
nothrow @nogc:
    enum ScanIntervalMs = 5000;
    enum TickMs         = 100;

    AdapterRing ethernet_ring;
    AdapterRing wifi_ring;

    void acquire()
    {
        if (_owners++ == 0)
            scan();
        if (_thread !is null)
            return;
        version (unittest)
        {
            bool create = !_test_fail_start;
            _test_fail_start = false;
        }
        else
            enum create = true;
        uint tid;
        if (create)
            _thread = CreateThread(null, 0, &thread_main, &this, 0, &tid);
        if (_thread is null)
            writeError("adapter watcher: failed to start worker");
    }

    void release()
    {
        assert(_owners > 0);
        if (--_owners != 0)
            return;
        stop();
        reset();
    }

private:
    HANDLE _thread;
    shared bool _stop;
    uint _owners;
    Array!Entry _last;

    version (unittest)
    {
        bool function(ref Array!Entry) nothrow @nogc _test_enumerate;
        bool _test_fail_start;
    }

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

    void stop()
    {
        if (_thread is null)
            return;
        atomicStore!(MemoryOrder.release)(_stop, true);
        WaitForSingleObject(_thread, INFINITE);
        CloseHandle(_thread);
        _thread = null;
    }

    void reset()
    {
        destroy(_last);
        ethernet_ring.init();
        wifi_ring.init();
        atomicStore!(MemoryOrder.release)(_stop, false);
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
        Array!Entry current;
        bool enumerated;
        version (unittest)
        {
            if (_test_enumerate)
                enumerated = _test_enumerate(current);
            else
                enumerated = enumerate(current);
        }
        else
            enumerated = enumerate(current);
        if (!enumerated)
            return;

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

    bool enumerate(ref Array!Entry current)
    {
        if (!npcap_loaded())
            return false;

        pcap_if* interfaces;
        char[PCAP_ERRBUF_SIZE] errbuf = void;
        if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
            return false;
        scope(exit) pcap_freealldevs(interfaces);

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
        return true;
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


unittest
{
    import urt.atomic : atomicFetchAdd;

    struct Probe
    {
        static shared uint scans;
        static shared bool changed;

        static bool enumerate(ref Array!(AdapterWatcher.Entry) entries) nothrow @nogc
        {
            uint pass = atomicFetchAdd(scans, 1u);
            if (pass && !atomicLoad(changed))
                return false;
            const(char)[] name = pass == 0 ? "initial" : "updated";
            AdapterWatcher.Entry e;
            e.name_buf[0 .. name.length] = name;
            e.name_len = cast(ubyte)name.length;
            e.is_ethernet = true;
            entries ~= e;
            e.is_ethernet = false;
            e.is_wifi = true;
            e.name_buf[0 .. 4] = "wifi";
            e.name_len = 4;
            entries ~= e;
            return true;
        }
    }

    AdapterWatcher watcher;
    watcher._test_enumerate = &Probe.enumerate;
    scope(exit) watcher.stop();
    atomicStore(Probe.scans, 0u);
    atomicStore(Probe.changed, false);
    watcher._test_fail_start = true;
    watcher.acquire();
    assert(watcher._owners == 1 && watcher._thread is null);
    assert(watcher.ethernet_ring.pending == 1 && watcher.wifi_ring.pending == 1);
    watcher.acquire();
    assert(watcher._owners == 2 && watcher._thread !is null);
    HANDLE worker = watcher._thread;
    watcher.release();
    assert(watcher._owners == 1 && watcher._thread == worker);
    assert(!atomicLoad(watcher._stop));
    assert(watcher.ethernet_ring.pending == 1 && watcher.wifi_ring.pending == 1);
    watcher.release();
    assert(watcher._owners == 0 && watcher._thread is null);
    assert(!atomicLoad(watcher._stop));
    assert(watcher._last.ptr is null);
    assert(watcher.ethernet_ring.empty && watcher.wifi_ring.empty);

    atomicStore(Probe.scans, 0u);
    atomicStore(Probe.changed, false);
    watcher.acquire();
    assert(watcher._thread !is null);
    assert(watcher.ethernet_ring.pending == 1 && watcher.wifi_ring.pending == 1);
    assert(watcher.ethernet_ring.peek().name == "initial");
    worker = watcher._thread;
    watcher.acquire();
    assert(watcher._owners == 2 && watcher._thread == worker);
    watcher.release();
    assert(watcher._owners == 1 && watcher._thread == worker);
    assert(watcher.ethernet_ring.pending == 1 && watcher.wifi_ring.pending == 1);
    watcher.ethernet_ring.pop(1);
    atomicStore(Probe.changed, true);
    bool arrived;
    foreach (i; 0 .. AdapterWatcher.ScanIntervalMs / AdapterWatcher.TickMs + 10)
    {
        AdapterEvent[] batch = watcher.ethernet_ring.peek(size_t.max);
        foreach (ref ev; batch)
            arrived |= ev.kind == AdapterEventKind.added && ev.name == "updated";
        watcher.ethernet_ring.pop(batch.length);
        if (arrived)
            break;
        sleep(AdapterWatcher.TickMs.msecs);
    }
    assert(arrived, "restarted watcher did not deliver a worker event");
    watcher.release();
    assert(watcher.ethernet_ring.empty && watcher.wifi_ring.empty);
    assert(watcher._last.ptr is null);
}
