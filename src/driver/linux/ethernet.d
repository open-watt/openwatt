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

import driver.linux.fdwatch;
import driver.linux.netlink;
import driver.linux.netlink_write;
import driver.linux.sysfs;

import driver.linux.raw;

import urt.internal.sys.posix : pollfd, POLLIN;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.port;

nothrow @nogc:


// ---------------------------------------------------------------------------
// EthernetInterface backed by an AF_PACKET socket on a kernel netdev.
// ---------------------------------------------------------------------------

final class LinuxRawEthernet : EthernetInterface
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
        _adapter = value.make_string();
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
        if (!_raw.valid)
        {
            auto r = _raw.open(_adapter[]);
            if (r.failed)
            {
                log.error(r.message);
                return CompletionStatus.error;
            }
            apply_configured_mtu();

            ubyte[6] hw = void;
            if (_raw.read_mac(_adapter[], hw))
                adopt_mac(MACAddress(hw));
            set_kernel_ifindex(_raw.ifindex);
        }

        // heartbeat() only runs once we are up, so the wait for carrier is polled here
        MonoTime now = getTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_os_state();
        }

        if (_status.connected == ConnectionStatus.disconnected)
            return CompletionStatus.continue_;

        register_fdwatch();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unregister_fdwatch();
        _raw.close();
        set_kernel_ifindex(0);
        return super.shutdown();
    }

    protected override const(char)[] apply_mac(ref MACAddress value)
    {
        int ifindex = _raw.valid ? _raw.ifindex : netlink_ifindex(_adapter[]);
        if (ifindex == 0)
            return "network interface is unavailable";
        int err = netlink_reprogram_link_mac(ifindex, value.b);
        if (err != 0)
        {
            log.error("could not set ", _adapter[], " hardware address: netlink error=", err);
            return "driver rejected hardware address";
        }
        return null;
    }

    final void set_enslaved(bool value)
    {
        if (_enslaved == value)
            return;
        _enslaved = value;
        if (!value)
        {
            // Discard frames already switched by the kernel before resuming software RX.
            _raw.close();
            if (running)
                restart();
        }
        fd_watch_changed();
    }

    override void heartbeat(MonoTime now)
    {
        super.heartbeat(now);

        if (!_raw.valid)
            return restart();

        refresh_os_state();
        if (_status.connected == ConnectionStatus.disconnected)
            restart();
    }

protected:
    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

    override void on_mtu_changed()
    {
        apply_configured_mtu();
    }

private:
    RawAdapter _raw;
    String _adapter;
    MonoTime _last_refresh;
    bool _enslaved;
    bool _fdwatch_registered;

    void register_fdwatch()
    {
        if (!_fdwatch_registered && add_fd_watcher(&service_io, &collect_fds))
        {
            _fdwatch_registered = true;
            fd_watch_changed();
        }
    }

    void unregister_fdwatch()
    {
        if (_fdwatch_registered)
        {
            remove_fd_watcher(&service_io);
            _fdwatch_registered = false;
            fd_watch_changed();
        }
    }

    void collect_fds(ref Array!pollfd fds)
    {
        if (_raw.valid && !_enslaved)
            fds ~= pollfd(_raw.fd, POLLIN);
    }

    void service_io()
    {
        if (!running || !_raw.valid || _enslaved)
            return;

        const(ubyte)[] data;
        uint wire_len;
        MonoTime ts;
        ubyte pkttype;
        ushort vlan_tci;
        ushort vlan_tpid;

        while (running && _raw.valid && !_enslaved)
        {
            int res = _raw.poll_ll(data, wire_len, ts, pkttype, vlan_tci, vlan_tpid);
            if (res == 0)
                break;
            if (res < 0)
            {
                // Remove error-ready fds from epoll; heartbeat retries the interface.
                log.error("receive failed on '", _adapter, "': errno=", _raw.last_recv_error.system_code);
                _raw.close();
                return;
            }

            if (pkttype == PACKET_OUTGOING)
                continue;

            if (data.length < wire_len)
            {
                add_rx_drop();
                continue;
            }

            incoming_ethernet_frame(data, ts, vlan_tci, vlan_tpid);
        }
    }

    void apply_configured_mtu()
    {
        if (_mtu == 0 || _adapter.empty)
            return;
        if (!set_adapter_mtu(_adapter[], actual_mtu))
            log.warning("failed to set MTU ", actual_mtu, " on '", _adapter, "'");
    }

    void refresh_os_state()
    {
        OSAdapterInfo info;
        if (!query_adapter(_adapter[], info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)       mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu)   mark_set!(typeof(this), "max-l2mtu")();
        if (c & AdapterChange.connected) { mark_set!(typeof(this), "connected")(); write_status(); }
        set_link_speed(info.tx_link_speed, info.rx_link_speed);
    }
}


// ---------------------------------------------------------------------------
// Driver module: scans /sys/class/net/ at startup, then receives async
// notifications from manager.os.netlink (RTM_NEWLINK / RTM_DELLINK) to keep
// the LinuxRawEthernet collection in sync with the kernel's netdev list.
// ---------------------------------------------------------------------------

final class LinuxRawEthernetModule : Module
{
    mixin DeclareModule!"interface.ethernet.linux";
nothrow @nogc:

    override void pre_init()
    {
        subscribe_link_changed(&on_link_changed);
        sync_adapters();
    }

    override void init()
    {
        g_app.console.register_collection!LinuxRawEthernet();
    }

private:

    void on_link_changed(uint, const(char)[], bool, bool)
    {
        // Coarse: any link event triggers a full rescan. Cheap (sysfs walk +
        // small Set diff) and easier to reason about than per-event mutation.
        sync_adapters();
    }

    void sync_adapters()
    {
        Array!String os_buf;
        enumerate_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            port_add(PortKind.ethernet, tconcat("linux:ethernet:", name), name, name, ModuleName, description, adapter_is_removable(name) ? PortFlags.removable : PortFlags.none);

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
                log_info(ModuleName, "Found ethernet interface: \"", description, "\" (", name, ")");
                auto iface = Collection!LinuxRawEthernet().create(iface_name, ObjectFlags.dynamic);
                iface.adapter = name;
                if (description.length > 0)
                    iface.comment = description.make_string();
            }

            os_buf ~= name.make_string();
        });

        Array!LinuxRawEthernet gone;
        foreach (e; Collection!LinuxRawEthernet().values)
        {
            if (!(e.flags & ObjectFlags.dynamic))
                continue;

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
            log_info(ModuleName, "Ethernet adapter gone: ", e.adapter);
            port_remove(PortKind.ethernet, tconcat("linux:ethernet:", e.adapter[]));
            e.destroy();
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
