module driver.linux.ethernet;

version (linux):

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import manager.os.sysfs;

import driver.linux.raw;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;

nothrow @nogc:


alias DevicesChangedHandler = void delegate() nothrow @nogc;

// Register a callback to be invoked when the OS reports an adapter list change.
// TODO: not yet wired -- callers should poll enumerate_adapters() as a fallback.
//       Implementation: RTNetlink RTM_NEWLINK / RTM_DELLINK on a NETLINK_ROUTE
//       socket; trampoline must marshal onto the main update tick before
//       invoking the registered handler so consumers don't need to be thread-safe.
void on_devices_changed(DevicesChangedHandler handler)
{
    g_devices_changed = handler;
}

private __gshared DevicesChangedHandler g_devices_changed;


// ---------------------------------------------------------------------------
// EthernetInterface backed by an AF_PACKET socket on a kernel netdev.
// ---------------------------------------------------------------------------

class LinuxRawEthernet : EthernetInterface
{
    alias Properties = AliasSeq!(Prop!("adapter", adapter));
nothrow @nogc:

    enum type_name = "ether";
    enum path = "/interface/ethernet";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LinuxRawEthernet, id, flags);
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
        if (!_raw.valid && !_raw.open(_adapter[]))
            return CompletionStatus.error;

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_os_state();
        }

        if (_status.connected == ConnectionStatus.disconnected)
            return CompletionStatus.continue_;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        _raw.close();
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
            int res = _raw.poll(data, wire_len, ts);
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
        => _raw.send(frame) ? 0 : -1;

private:
    RawAdapter _raw;
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
// Driver module: scans /sys/class/net/, syncs the LinuxRawEthernet collection
// against it. Subscribes the (currently stub) on_devices_changed hook for
// future async hotplug; falls back to a 1Hz poll until netlink is wired.
// ---------------------------------------------------------------------------

class LinuxRawEthernetModule : Module
{
    mixin DeclareModule!"interface.ethernet.linux";
nothrow @nogc:

    override void pre_init()
    {
        on_devices_changed(&sync_adapters);
        sync_adapters();
    }

    override void init()
    {
        g_app.console.register_collection!LinuxRawEthernet();
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

    void sync_adapters()
    {
        Array!String os_buf;
        enumerate_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            bool present = false;
            foreach (e; Collection!LinuxRawEthernet().values)
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
                auto iface = Collection!LinuxRawEthernet().create(iface_name);
                iface.adapter = name;
                if (description.length > 0)
                    iface.comment = description.makeString(defaultAllocator);
            }

            os_buf ~= name.makeString(defaultAllocator);
        });

        Array!LinuxRawEthernet gone;
        foreach (e; Collection!LinuxRawEthernet().values)
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
            Collection!LinuxRawEthernet().remove(e);
        }
    }

    const(char)[] next_iface_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("ether", n);
            bool taken = false;
            foreach (e; Collection!LinuxRawEthernet().values)
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
