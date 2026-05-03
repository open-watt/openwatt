module driver.windows.wifi;

// =====================================================================
// SHELVED -- this file currently only contains adapter enumeration via
// npcap. The real Windows WiFi driver is on hold pending the wider
// EthernetBackend/WiFiBackend refactor. Notes from the design discussion:
//
// 1. Drop static `num_wifi`. The compile-time radio count is fine for
//    embedded targets but wrong for any runtime-discovered platform.
//    Replace with `WiFiBackend.enumerate()` returning N at runtime, plus
//    a `WiFiCaps` bitfield per backend so the frontend knows what's
//    supported (station, scan, ap, monitor, set_channel, country_code,
//    ...). All `static if (num_wifi > 0)` blocks in router/iface/wifi.d
//    become runtime checks (or per-call cap checks the backend can refuse).
//
// 2. The realistic Windows WiFi backend via wlanapi.dll exposes:
//      enumerate adapters       (WlanEnumInterfaces)        ok
//      scan SSIDs               (WlanScan + Get*List)       ok
//      join network             (WlanConnect + profile XML) ok
//      disconnect               (WlanDisconnect)            ok
//      query SSID/BSSID/RSSI/ch (WlanQueryInterface)        ok
//      set channel              -                            no public API
//      AP mode                  -                            Hosted Network deprecated/removed
//      monitor / promiscuous    -                            not via WLAN API; npcap-on-supported-chipset only
//    So the Windows WiFi backend ships as `caps = station | scan` with
//    AP/channel/monitor explicitly unsupported.
//
// 3. AP via Mobile Hotspot (NetworkOperatorTetheringManager UWP API): can
//    be wired up with hand-rolled WinRT bindings (RoInitialize +
//    RoActivateInstance via combase.dll). But the resulting "AP" is fully
//    OS-owned (Windows runs DHCP, ICS-NAT, firewall on its own virtual
//    adapter); our IP stack can't participate. Treat as a checkbox feature
//    only -- new caps flag `os_managed_ap` -- not a real router path.
//
// 4. Parallel-stack via npcap on the Hotspot adapter (sniff/inject our
//    own L2) was considered and ruled out: 802.11 doesn't carry client-
//    tagged 802.1Q frames reliably, and even if it did, NAT/upstream is
//    Windows-owned. The pattern *might* work on a wired NIC where the
//    consumer driver passes 802.1Q transparently and there's a real
//    switch beyond -- file under "future WindowsPcapVlanBackend" if a
//    user actually wants it.
//
// 5. Realistic "OpenWatt as a Windows-side router" answers stay:
//    TUN/TAP virtual adapter (we own L2 entirely), Hyper-V vSwitch with
//    OpenWatt as a vNIC, or a Linux VM with NIC passthrough. Each lands
//    as another EthernetBackend implementation when needed.
// =====================================================================

version (Windows):

import urt.array;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import manager.os.iphlpapi;
import manager.os.npcap;

import driver.windows.pcap;
import driver.windows.wlanapi;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;
import router.iface.wifi;

nothrow @nogc:


alias DevicesChangedHandler = void delegate() nothrow @nogc;

// Register a callback to be invoked when the OS reports a wifi adapter list change.
// TODO: not yet wired -- callers should poll enumerate_wifi_adapters() as a fallback.
//       Implementation: WlanRegisterNotification with WLAN_NOTIFICATION_SOURCE_ACM
//       (filter on wlan_notification_acm_interface_arrival / _removal). Fires on a
//       worker thread; trampoline must marshal onto the main update tick.
void on_devices_changed(DevicesChangedHandler handler)
{
    g_devices_changed = handler;
}

private __gshared DevicesChangedHandler g_devices_changed;


// Walk the OS adapter list and call `on_adapter(name, description)` for each
// wifi-looking adapter. Skips virtual / non-wifi devices.
void enumerate_wifi_adapters(scope void delegate(const(char)[] name, const(char)[] description) nothrow @nogc on_adapter)
{
    if (!npcap_loaded())
        return;

    pcap_if* interfaces;
    char[PCAP_ERRBUF_SIZE] errbuf = void;
    if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
        return;
    scope(exit) pcap_freealldevs(interfaces);

    for (auto dev = interfaces; dev; dev = dev.next)
    {
        if ((dev.flags & 0x00000001) != 0)
            continue;

        const(char)[] name = dev.name[0..dev.name.strlen];
        const(char)[] description = dev.description[0..dev.description.strlen];

        // skip virtual / wired adapters
        if (description.contains_i("virtual") ||
            description.contains_i("miniport") ||
            description.contains_i("hyper-v") ||
            description.contains_i("bluetooth") ||
            description.contains_i("wi-fi direct") ||
            description.contains_i("virtualbox") ||
            description.contains_i("tunnel") ||
            description.contains_i("offload") ||
            description.contains_i("tap"))
            continue;

        bool is_wifi = (dev.flags & 0x00000008) != 0;
        if (!is_wifi)
        {
            if (description.contains_i("wireless") ||
                description.contains_i("wi-fi") ||
                description.contains_i("wifi"))
                is_wifi = true;
        }

        if (!is_wifi)
            continue;

        on_adapter(name, description);
    }
}


// ---------------------------------------------------------------------------
// Concrete subclasses for the Windows wifi backend.
//
// On embedded targets, WiFiInterface (radio) and WLANInterface (station) are
// distinct objects -- one radio can host multiple logical WLANs/APs. Windows
// collapses these: the OS gives us a single "wifi adapter" that's both. We
// keep the split anyway by synthesising a paired (Radio, WLAN) per adapter
// so the existing radio.* properties (channel, rssi, ssid query, ...) have
// a place to live, and the WLAN -> _radio link works as the embedded path
// expects.
//
// TODO: WindowsWifiRadio currently has no real OS interaction. Next pass
// opens a wlanapi.dll handle (WlanOpenHandle) and overrides the OS-readable
// properties (channel, current SSID, BSSID, RSSI, link quality) to pull
// from WlanQueryInterface. Connect/disconnect on WLAN goes via
// WlanConnect / WlanDisconnect through the radio's handle.
// ---------------------------------------------------------------------------

class WindowsWifiRadio : WiFiInterface
{
    alias Properties = AliasSeq!(Prop!("adapter", adapter));
nothrow @nogc:

    enum type_name = "wifi";
    enum path = "/interface/wifi";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WindowsWifiRadio, id, flags);
    }

    // Properties

    final const(char)[] adapter() const pure
        => _adapter[];
    final void adapter(const(char)[] value)
    {
        _adapter = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "adapter")();
    }

    override const(char)[] mode() const pure
        => "sta";

    override ubyte channel() const
    {
        if (running && _current_channel != 0)
            return _current_channel;
        return super.channel;
    }

    // API

protected:

    override bool validate() const
        => !_adapter.empty;

    override CompletionStatus startup()
    {
        if (!_wlan.open())
            return CompletionStatus.error;
        if (_guid == GUID.init && !_wlan.find_interface_for_adapter(adapter, _guid))
        {
            // adapter exists in npcap but the WLAN service doesn't know about
            // it (could be a wired NIC misclassified upstream, or WLAN service
            // disabled). Keep running -- packets still flow via the WLAN side
            // -- but OS-readable wifi state stays empty.
            log.warning("no WLAN interface matches adapter '", adapter, "'");
        }

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
        _wlan.close();
        return CompletionStatus.complete;
    }

    override void update()
    {
        // The radio is the logical carrier for whatever WLAN/AP is bound to
        // it; aggregate their traffic counters here so the radio's status
        // reflects link activity (and so the base's rate sampling has fresh
        // bytes to diff against). Today only one sub-interface is paired on
        // Windows (STA), but aggregation handles the future STA+AP case for
        // free.
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
        if (auto ap = bound_ap)
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
    // Per-adapter wlanapi handle. Module-private (D's `private` is per-module),
    // so WindowsWlan accesses these directly to run STA-side queries.
    WlanClient _wlan;
    GUID _guid;

    SysTime _last_refresh;
    ubyte _current_channel;

    void refresh_state()
    {
        uint channel;
        ubyte new_channel;
        if (_wlan.query_channel(_guid, channel))
            new_channel = cast(ubyte)channel;
        if (new_channel != _current_channel)
        {
            _current_channel = new_channel;
            mark_set!(typeof(this), [ "channel" ]);
        }

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


class WindowsWlan : WLANInterface
{
nothrow @nogc:

    enum type_name = "wlan";
    enum path = "/interface/wlan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WindowsWlan, id, flags);
    }

    // Properties

    override const(char)[] ssid() const pure
        => _current_ssid[];

    override MACAddress bssid() const
        => _current_bssid;

    override int rssi() const
        => _current_rssi;

    override ubyte signal_quality() const
        => _signal_quality;

    override const(char)[] status_message() const
    {
        if (!is_os_connected)
        {
            final switch (_state) with (WLAN_INTERFACE_STATE)
            {
                case not_ready:             return "not-ready";
                case connected:             break;
                case ad_hoc_network_formed: return "ad-hoc";
                case disconnecting:         return "disconnecting";
                case disconnected:          return "disconnected";
                case associating:           return "associating";
                case discovering:           return "discovering";
                case authenticating:        return "authenticating";
            }
        }
        return super.status_message();
    }

protected:

    override bool validate() const
        => radio !is null;

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto r = cast(WindowsWifiRadio)radio;
        if (_pcap.handle is null && !_pcap.open(r.adapter))
            return CompletionStatus.error;

        refresh_state();
        if (!is_os_connected)
            return CompletionStatus.continue_;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        _pcap.close();
        clear_os_state();
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_state();
            if (!is_os_connected)
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

    // TODO: ssid setter override that calls WlanConnect via the radio's handle.

    override int wire_send(const(ubyte)[] frame)
        => _pcap.send(frame) ? 0 : -1;

private:
    PcapAdapter _pcap;

    SysTime _last_refresh;
    String _current_ssid;
    MACAddress _current_bssid;
    int _current_rssi;          // dBm
    ubyte _signal_quality;       // 0..100
    WLAN_INTERFACE_STATE _state = WLAN_INTERFACE_STATE.not_ready;

    bool is_os_connected() const pure
        => _state == WLAN_INTERFACE_STATE.connected;

    void clear_os_state()
    {
        _state = WLAN_INTERFACE_STATE.not_ready;
        _current_ssid = null;
        _current_bssid = MACAddress();
        _current_rssi = 0;
        _signal_quality = 0;
    }

    void refresh_state()
    {
        auto r = cast(WindowsWifiRadio)radio;
        if (!r)
        {
            clear_os_state();
            return;
        }

        WLAN_CONNECTION_ATTRIBUTES attrs;
        if (!r._wlan.query_current_connection(r._guid, attrs))
        {
            _state = WLAN_INTERFACE_STATE.disconnected;
            _current_ssid = null;
            _current_bssid = MACAddress();
            _current_rssi = 0;
            _signal_quality = 0;
            mark_set!(typeof(this), [ "ssid", "bssid", "rssi", "signal-quality", "status" ])();
        }
        else
        {
            _state = attrs.isState;

            ref ssid_attr = attrs.wlanAssociationAttributes.dot11Ssid;
            const(char)[] ssid_str = cast(const(char)[])ssid_attr.ucSSID[0 .. ssid_attr.uSSIDLength];
            if (_current_ssid[] != ssid_str)
                _current_ssid = ssid_str.makeString(defaultAllocator);

            const(ubyte)[6] b = attrs.wlanAssociationAttributes.dot11Bssid;
            _current_bssid = MACAddress(b[0], b[1], b[2], b[3], b[4], b[5]);
            _signal_quality = cast(ubyte)attrs.wlanAssociationAttributes.wlanSignalQuality;

            int rssi;
            if (r._wlan.query_rssi(r._guid, rssi))
                _current_rssi = rssi;

            mark_set!(typeof(this), [ "ssid", "bssid", "rssi", "signal-quality", "status" ])();
        }

        OSAdapterInfo info;
        if (!query_adapter(r.adapter, info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)       mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu)   mark_set!(typeof(this), "max-l2mtu")();
        if (c & AdapterChange.connected) mark_set!(typeof(this), "connected")();
        if (c & AdapterChange.tx_speed)  mark_set!(typeof(this), "tx-link-speed")();
        if (c & AdapterChange.rx_speed)  mark_set!(typeof(this), "rx-link-speed")();
    }
}


// ---------------------------------------------------------------------------
// Driver module: discovers wifi adapters and creates a (Radio, WLAN) pair
// for each. Subscribes the on_devices_changed hook for true async hotplug;
// falls back to a 1Hz poll until the OS notification path is wired.
// ---------------------------------------------------------------------------

class WindowsWlanModule : Module
{
    mixin DeclareModule!"wifi.windows";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!WindowsWifiRadio();
        g_app.console.register_collection!WindowsWlan();

        on_devices_changed(&sync_radios);
        sync_radios();
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
        import urt.log;

        // Radio identity == OS adapter identity. The paired WLAN inherits its
        // adapter via the radio at startup (don't set wlan.adapter directly --
        // the WLANBaseInterface.radio setter clears adapter as a side-effect).
        Array!String os_buf;
        enumerate_wifi_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            bool present = false;
            foreach (r; Collection!WindowsWifiRadio().values)
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
                log_info(ModuleName, "Found wifi interface: \"", description, "\" (", name, ")");

                auto radio = Collection!WindowsWifiRadio().create(tconcat(base, "-radio"));
                radio.adapter = name;
                radio.comment = description.makeString(defaultAllocator);

                auto wlan = Collection!WindowsWlan().create(base);
                wlan.radio = radio;
            }

            os_buf ~= name.makeString(defaultAllocator);
        });

        // remove radios whose adapter is no longer in the OS list (and any paired wlan)
        Array!WindowsWifiRadio gone;
        foreach (r; Collection!WindowsWifiRadio().values)
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
            // remove paired wlan(s) first
            Array!WindowsWlan paired;
            foreach (w; Collection!WindowsWlan().values)
                if (cast(WindowsWifiRadio)w.radio is r)
                    paired ~= w;
            foreach (w; paired[])
                Collection!WindowsWlan().remove(w);
            Collection!WindowsWifiRadio().remove(r);
        }
    }

    // Pick the lowest unused "wlanN" name so the paired radio gets "wlanN-radio".
    const(char)[] next_radio_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("wlan", n);
            bool taken = false;
            foreach (w; Collection!WindowsWlan().values)
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
