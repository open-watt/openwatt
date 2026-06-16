module driver.windows.ethernet;

version (Windows):

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import driver.windows.iphlpapi;
import driver.windows.npcap;

import driver.windows.adapter_watcher;
import driver.windows.pcap;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;

nothrow @nogc:


// ---------------------------------------------------------------------------
// Concrete EthernetInterface backed by an npcap adapter handle.
// ---------------------------------------------------------------------------

class WindowsPcapEthernet : EthernetInterface
{
    alias Properties = AliasSeq!(Prop!("adapter", adapter));
nothrow @nogc:

    enum type_name = "ether";
    enum path = "/interface/ethernet";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WindowsPcapEthernet, id, flags);
    }

    final const(char)[] adapter() const pure
        => _adapter[];
    final void adapter(const(char)[] value)
    {
        _adapter = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "adapter")();
    }

    override bool validate() const
        => !_adapter.empty;

    override const(char)[] status_message() const
    {
        if (_status.connected == ConnectionStatus.disconnected)
            return "Cable unplugged";
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        if (_pcap.handle is null && !_pcap.open(_adapter[]))
            return CompletionStatus.error;

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_os_state();
        }

        // wait for the cable / OS to report the link as connected before going running
        if (_status.connected == ConnectionStatus.disconnected)
            return CompletionStatus.continue_;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        _pcap.close();
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_os_state();
            if (_status.connected == ConnectionStatus.disconnected)
            {
                restart();
                return;
            }
        }

        const(ubyte)[] data;
        uint wire_len;
        MonoTime ts;

        while (true)
        {
            int res = _pcap.poll(data, wire_len, ts);
            if (res == 0)
                break;
            if (res < 0)
                break;

            if (data.length < wire_len)
            {
                add_rx_drop();
                continue;
            }

            incoming_ethernet_frame(data, ts);
        }
    }

protected:
    override int wire_send(const(ubyte)[] frame)
        => _pcap.send(frame) ? 0 : -1;

private:
    PcapAdapter _pcap;
    String _adapter;
    SysTime _last_refresh;
    ulong _loopback_count;

    void refresh_os_state()
    {
        OSAdapterInfo info;
        if (!query_adapter(_adapter[], info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)       mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu)   mark_set!(typeof(this), "max-l2mtu")();
        if (c & AdapterChange.connected) mark_set!(typeof(this), [ "connected", "status" ])();
        if (c & AdapterChange.tx_speed)  mark_set!(typeof(this), "tx-link-speed")();
        if (c & AdapterChange.rx_speed)  mark_set!(typeof(this), "rx-link-speed")();
    }
}


// ---------------------------------------------------------------------------
// Driver module: registers the WindowsPcapEthernet collection. Adapter
// discovery is delegated to a shared background watcher (driver.windows.
// adapter_watcher) which calls pcap_findalldevs off the main tick and feeds
// add/remove events through an SPSC ring; we just drain that ring each update.
// ---------------------------------------------------------------------------

class WindowsPcapEthernetModule : Module
{
    mixin DeclareModule!"ethernet.pcap";
nothrow @nogc:

    override void pre_init()
    {
        g_adapter_watcher.scan_sync();
        drain_events();
    }

    override void init()
    {
        g_app.console.register_collection!WindowsPcapEthernet();
        g_adapter_watcher.start();
    }

    override void update()
    {
        drain_events();
    }

private:

    void drain_events()
    {
        // peek() returns a contiguous slice; if events wrap the ring boundary
        // we get the head portion this iteration and the wrapped portion next.
        while (true)
        {
            AdapterEvent[] batch = g_adapter_watcher.ethernet_ring.peek(size_t.max);
            if (batch.length == 0)
                break;
            foreach (ref ev; batch)
                apply_event(ev);
            g_adapter_watcher.ethernet_ring.pop(batch.length);
        }
    }

    void apply_event(ref const AdapterEvent ev)
    {
        final switch (ev.kind) with (AdapterEventKind)
        {
            case added:
                auto iface_name = next_iface_name();
                log_info(ModuleName, "Found ethernet interface: \"", ev.description, "\" (", ev.name, ")");
                auto iface = Collection!WindowsPcapEthernet().create(iface_name);
                iface.adapter = ev.name;
                iface.comment = ev.description.makeString(defaultAllocator);
                // TODO: we need to set the MAC for the interface to the NIC MAC address...
                return;
            case removed:
                foreach (e; Collection!WindowsPcapEthernet().values)
                {
                    if (e.adapter == ev.name)
                    {
                        writeInfo("Ethernet adapter gone: ", e.adapter);
                        Collection!WindowsPcapEthernet().remove(e);
                        return;
                    }
                }
                return;
        }
    }

    // Pick the lowest unused "etherN" name so removed slots get reused.
    const(char)[] next_iface_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("ether", n);
            bool taken = false;
            foreach (e; Collection!WindowsPcapEthernet().values)
            {
                if (e.name == candidate)
                {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                return candidate;
        }
        return tconcat("ether", 999);
    }
}
