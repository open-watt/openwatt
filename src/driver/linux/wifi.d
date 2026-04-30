module driver.linux.wifi;

// =====================================================================
// SKELETON. Mirrors driver/windows/wifi.d in shape, but the OS-state
// queries (current SSID, BSSID, RSSI, signal quality, channel) are
// stubbed pending nl80211 (generic netlink) bindings. The packet path
// is fully wired via AF_PACKET on the wlan netdev -- managed-mode wifi
// delivers de-encapsulated ethernet frames to the kernel netdev, so
// the same RawAdapter that drives LinuxRawEthernet works here.
//
// Future work, in roughly increasing order of effort:
//
// 1. nl80211/genl bindings in driver/linux/nl80211.d -- analogue of
//    driver/windows/wlanapi.d. Implements WlanQueryInterface-equivalent
//    queries (NL80211_CMD_GET_STATION for RSSI/BSSID, GET_INTERFACE for
//    channel/iftype) and connect/disconnect (CMD_CONNECT, CMD_DISCONNECT
//    via nl80211, OR plumb to a wpa_supplicant control socket).
//
// 2. RTNetlink RTM_NEWLINK / RTM_DELLINK for async hotplug (same hook
//    point as the ethernet driver -- see on_devices_changed).
//
// 3. APInterface support: hostapd integration for AP mode. Linux's
//    multi-VIF mac80211 supports STA + N*AP on a single radio (subject
//    to channel-locking and chipset interface_combinations). One radio
//    can host multiple SSIDs on the AP side via additional __ap-type VIFs.
//
// 4. Monitor mode / raw 802.11: a separate code path entirely. The radio
//    holds the AF_PACKET socket on a monX VIF, frames are 802.11+radiotap
//    not ethernet, so the existing EthernetInterface model doesn't fit --
//    needs a WiFi80211Interface variant. Worth doing only if a use case
//    actually requires L2-promisc on the wireless side.
// =====================================================================

version (linux):

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import manager.os.sysfs;

import driver.linux.raw;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;
import router.iface.wifi;

nothrow @nogc:


alias DevicesChangedHandler = void delegate() nothrow @nogc;

// Register a callback to be invoked when the OS reports a wifi adapter list change.
// TODO: not yet wired -- callers should poll enumerate_wifi_adapters() as a fallback.
//       Implementation: nl80211 multicast group via genl, or RTNetlink
//       RTM_NEWLINK / RTM_DELLINK on NETLINK_ROUTE.
void on_devices_changed(DevicesChangedHandler handler)
{
    g_devices_changed = handler;
}

private __gshared DevicesChangedHandler g_devices_changed;


// ---------------------------------------------------------------------------
// Concrete subclasses for the Linux wifi backend.
//
// Same (Radio, WLAN) pairing as the Windows backend. On Linux a single phy
// can in principle host multiple VIFs (STA+AP+monitor), but the skeleton
// covers the common case: one radio, one paired STA. Multi-VIF lands when
// AP support arrives.
// ---------------------------------------------------------------------------

class LinuxWifiRadio : WiFiInterface
{
    alias Properties = AliasSeq!(Prop!("adapter", adapter));
nothrow @nogc:

    enum type_name = "wifi";
    enum path = "/interface/wifi";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LinuxWifiRadio, id, flags);
    }

    final const(char)[] adapter() const pure
        => _adapter[];
    final void adapter(const(char)[] value)
    {
        _adapter = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "adapter")();
    }

    override const(char)[] mode() const pure
        => "sta";

protected:

    override bool validate() const
        => !_adapter.empty;

    override CompletionStatus startup()
    {
        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_state();
        }

        if (_status.connected == ConnectionStatus.disconnected)
            return CompletionStatus.continue_;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update()
    {
        // No native packet capture on the radio yet (managed-mode STA + APs
        // each own their own AF_PACKET on their VIF). Aggregate their
        // counters here so the radio's status reflects total link activity.
        // When monitor-mode lands and the radio holds its own RawAdapter,
        // its packet path will populate the counters directly via
        // add_rx_frame/add_tx_frame -- this aggregation should then become
        // conditional on `!_raw.valid` (or moved out entirely, with the
        // counters MAC-filtered on the radio side).
        ulong rx_bytes, tx_bytes, rx_packets, tx_packets, rx_dropped, tx_dropped;
        if (auto sta = bound_sta)
        {
            rx_bytes   += sta.status.rx_bytes;
            tx_bytes   += sta.status.tx_bytes;
            rx_packets += sta.status.rx_packets;
            tx_packets += sta.status.tx_packets;
            rx_dropped += sta.status.rx_dropped;
            tx_dropped += sta.status.tx_dropped;
        }
        foreach (ap; bound_aps)
        {
            rx_bytes   += ap.status.rx_bytes;
            tx_bytes   += ap.status.tx_bytes;
            rx_packets += ap.status.rx_packets;
            tx_packets += ap.status.tx_packets;
            rx_dropped += ap.status.rx_dropped;
            tx_dropped += ap.status.tx_dropped;
        }
        bool changed = (_status.rx_bytes   != rx_bytes  ||
                        _status.tx_bytes   != tx_bytes  ||
                        _status.rx_packets != rx_packets ||
                        _status.tx_packets != tx_packets ||
                        _status.rx_dropped != rx_dropped ||
                        _status.tx_dropped != tx_dropped);
        _status.rx_bytes   = rx_bytes;
        _status.tx_bytes   = tx_bytes;
        _status.rx_packets = rx_packets;
        _status.tx_packets = tx_packets;
        _status.rx_dropped = rx_dropped;
        _status.tx_dropped = tx_dropped;
        if (changed)
            mark_set!(typeof(this), [ "rx-bytes", "tx-bytes", "rx-packets", "tx-packets",
                                      "rx-dropped", "tx-dropped" ])();

        super.update();

        SysTime now = getSysTime();
        if (now - _last_refresh < 1.seconds)
            return;
        _last_refresh = now;
        refresh_state();
        if (_status.connected == ConnectionStatus.disconnected)
        {
            restart();
            return;
        }
    }

private:
    String _adapter;
    SysTime _last_refresh;

    void refresh_state()
    {
        // Channel query is an nl80211 job (NL80211_CMD_GET_INTERFACE,
        // NL80211_ATTR_WIPHY_FREQ -> channel mapping); not wired yet.
        // We still pull MAC/MTU/carrier/speed from sysfs -- carrier-up on a
        // wlan netdev means associated, which is the proxy for "STA online"
        // until nl80211 lands.

        OSAdapterInfo info;
        if (!query_adapter(_adapter[], info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)       mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu)   mark_set!(typeof(this), "max-l2mtu")();
        if (c & AdapterChange.connected) mark_set!(typeof(this), "connected")();
        if (c & AdapterChange.tx_speed)  mark_set!(typeof(this), "tx-link-speed")();
        if (c & AdapterChange.rx_speed)  mark_set!(typeof(this), "rx-link-speed")();
    }
}


class LinuxWlan : WLANInterface
{
nothrow @nogc:

    enum type_name = "wlan";
    enum path = "/interface/wlan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LinuxWlan, id, flags);
    }

    // OS-state queries are stubbed pending nl80211. Until then the
    // base-class defaults (empty SSID/BSSID, zero RSSI/quality) stand.

protected:

    override bool validate() const
        => radio !is null;

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto r = cast(LinuxWifiRadio)radio;
        if (!_raw.valid && !_raw.open(r.adapter))
            return CompletionStatus.error;

        // No nl80211 yet, so we can't tell associated-vs-not. carrier-up
        // on the wlan netdev means associated; carrier-down means not
        // associated (or admin-down). Use the same sysfs path as the
        // ethernet driver and the radio.
        OSAdapterInfo info;
        if (query_adapter(r.adapter, info) && info.connection != ConnectionStatus.connected)
            return CompletionStatus.continue_;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        _raw.close();
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            OSAdapterInfo info;
            if (query_adapter(r.adapter, info) && info.connection != ConnectionStatus.connected)
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

    // TODO: ssid setter override that drives wpa_supplicant or nl80211 CMD_CONNECT.

    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

private:
    RawAdapter _raw;
    SysTime _last_refresh;
}


// ---------------------------------------------------------------------------
// Driver module: discovers wifi adapters from sysfs and creates a (Radio,
// WLAN) pair for each. Subscribes the on_devices_changed hook for future
// async hotplug; falls back to a 1Hz poll until netlink is wired.
// ---------------------------------------------------------------------------

class LinuxWlanModule : Module
{
    mixin DeclareModule!"interface.wifi.linux";
nothrow @nogc:

    override void pre_init()
    {
        on_devices_changed(&sync_radios);
        sync_radios();
    }

    override void init()
    {
        g_app.console.register_collection!LinuxWifiRadio();
        g_app.console.register_collection!LinuxWlan();
    }

    override void update()
    {
        SysTime now = getSysTime();
        if (now - _last_scan < 1.seconds)
            return;
        _last_scan = now;
        sync_radios();
    }

private:
    SysTime _last_scan;

    void sync_radios()
    {
        // Radio identity == OS netdev identity. Paired WLAN inherits its
        // adapter via the radio at startup (don't set wlan.adapter directly
        // -- the WLANBaseInterface.radio setter clears adapter as a side-effect).
        Array!String os_buf;
        enumerate_wifi_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            bool present = false;
            foreach (r; Collection!LinuxWifiRadio().values)
            {
                if (r.adapter == name)
                {
                    present = true;
                    break;
                }
            }
            if (!present)
            {
                auto base = next_radio_name();
                writeInfo("Found wifi interface: \"", description, "\" (", name, ")");

                auto radio = Collection!LinuxWifiRadio().create(tconcat(base, "-radio"));
                radio.adapter = name;
                if (description.length > 0)
                    radio.comment = description.makeString(defaultAllocator);

                auto wlan = Collection!LinuxWlan().create(base);
                wlan.radio = radio;
            }

            os_buf ~= name.makeString(defaultAllocator);
        });

        Array!LinuxWifiRadio gone;
        foreach (r; Collection!LinuxWifiRadio().values)
        {
            bool still_there = false;
            foreach (ref s; os_buf[])
            {
                if (r.adapter == s[])
                {
                    still_there = true;
                    break;
                }
            }
            if (!still_there)
                gone ~= r;
        }
        foreach (r; gone[])
        {
            writeInfo("Wifi adapter gone: ", r.adapter);
            Array!LinuxWlan paired;
            foreach (w; Collection!LinuxWlan().values)
                if (cast(LinuxWifiRadio)w.radio is r)
                    paired ~= w;
            foreach (w; paired[])
                Collection!LinuxWlan().remove(w);
            Collection!LinuxWifiRadio().remove(r);
        }
    }

    const(char)[] next_radio_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("wlan", n);
            bool taken = false;
            foreach (w; Collection!LinuxWlan().values)
            {
                if (w.name == candidate)
                {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                return candidate;
        }
        return tconcat("wlan", 999);
    }
}
