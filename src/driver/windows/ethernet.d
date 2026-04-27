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

import manager.os.iphlpapi;
import manager.os.npcap;

import driver.windows.pcap;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;

nothrow @nogc:


alias DevicesChangedHandler = void delegate() nothrow @nogc;

// Register a callback to be invoked when the OS reports an adapter list change.
// TODO: not yet wired -- callers should poll enumerate_adapters() as a fallback.
//       Implementation: NotifyIpInterfaceChange (iphlpapi) fires on a system
//       worker thread; the trampoline here should marshal back onto the main
//       update tick (queue a flag, drain on next update) before invoking the
//       registered handler so consumers don't need to be thread-safe.
void on_devices_changed(DevicesChangedHandler handler)
{
    g_devices_changed = handler;
}

private __gshared DevicesChangedHandler g_devices_changed;


// Walk the OS adapter list and call `on_adapter(name, description)` for each
// non-loopback ethernet-looking adapter. Skips virtual / wifi / tunnel / etc.
void enumerate_adapters(scope void delegate(const(char)[] name, const(char)[] description) nothrow @nogc on_adapter)
{
    if (!npcap_loaded())
    {
        writeError("NPCap library not loaded, cannot enumerate ethernet interfaces.");
        return;
    }

    pcap_if* interfaces;
    char[PCAP_ERRBUF_SIZE] errbuf = void;
    if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
    {
        writeError("pcap_findalldevs failed: ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
        return;
    }
    scope(exit) pcap_freealldevs(interfaces);

    for (auto dev = interfaces; dev; dev = dev.next)
    {
        // skip loopback interfaces
        if ((dev.flags & 0x00000001) != 0)
            continue;

        const(char)[] name = dev.name[0..dev.name.strlen];
        const(char)[] description = dev.description[0..dev.description.strlen];

        // skip virtual / non-ethernet adapters
        if (description.contains_i("virtual") ||
            description.contains_i("miniport") ||
            description.contains_i("hyper-v") ||
            description.contains_i("bluetooth") ||
            description.contains_i("wi-fi direct") ||
            description.contains_i("virtualbox") ||
            description.contains_i("tunnel") ||
            description.contains_i("offload") ||
            description.contains_i("tap") ||
            description.contains_i("wireless") ||
            description.contains_i("wi-fi") ||
            description.contains_i("wifi"))
            continue;

        on_adapter(name, description);
    }
}


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
        return CompletionStatus.complete;
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
        SysTime ts;

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
// Driver module: registers the WindowsPcapEthernet collection, owns adapter
// discovery + sync. Subscribes the (currently stub) on_devices_changed hook
// for true async hotplug; falls back to a 1Hz poll until the OS notification
// path is wired.
// ---------------------------------------------------------------------------

class WindowsPcapEthernetModule : Module
{
    mixin DeclareModule!"interface.ethernet.pcap";
nothrow @nogc:

    override void pre_init()
    {
        on_devices_changed(&sync_adapters);
        sync_adapters();
    }

    override void init()
    {
        g_app.console.register_collection!WindowsPcapEthernet();
    }

    override void update()
    {
        SysTime now = getSysTime();
        if (now - _last_scan < 1.seconds)
            return;
        _last_scan = now;
        sync_adapters();
    }

private:
    SysTime _last_scan;

    // Idempotent diff against the OS adapter list. Operates only on
    // WindowsPcapEthernet instances so it doesn't disturb interfaces created
    // by other sources (manual /add, USB manager, future TUN/TAP, ...).
    void sync_adapters()
    {
        Array!String os_buf;
        enumerate_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            bool present = false;
            foreach (e; Collection!WindowsPcapEthernet().values)
            {
                if (e.adapter == name)
                {
                    present = true;
                    break;
                }
            }
            if (!present)
            {
                auto iface_name = next_iface_name();
                writeInfo("Found ethernet interface: \"", description, "\" (", name, ")");
                auto iface = Collection!WindowsPcapEthernet().create(iface_name);
                iface.adapter = name;
                auto desc = description.makeString(defaultAllocator);
                iface.comment = desc;
                // TODO: we need to set the MAC for the interface to the NIC MAC address...
            }

            os_buf ~= name.makeString(defaultAllocator);
        });

        Array!WindowsPcapEthernet gone;
        foreach (e; Collection!WindowsPcapEthernet().values)
        {
            bool still_there = false;
            foreach (ref s; os_buf[])
            {
                if (e.adapter == s[])
                {
                    still_there = true;
                    break;
                }
            }
            if (!still_there)
                gone ~= e;
        }
        foreach (e; gone[])
        {
            writeInfo("Ethernet adapter gone: ", e.adapter);
            Collection!WindowsPcapEthernet().remove(e);
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
