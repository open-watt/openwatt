module driver.linux.wifi;

// =====================================================================
// Linux wifi backend. The physical adapter is the radio/STA netdev. APs and
// monitor capture use sibling VIFs on the same phy so STA channel ownership can
// coexist with AP beacons and radiotap capture.
// =====================================================================

version (linux):

import urt.array;
import urt.conv;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import urt.driver.wifi : WifiScanResult, WifiScanConfig, WifiBand, DrvWifiAuth = WifiAuth;
import urt.meta.nullable : Nullable;

import manager;
import manager.collection;
import manager.console;
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.live_view : LiveViewState;
import manager.console.table : Table;
import manager.plugin;

import driver.linux.netlink;
import driver.linux.nl80211;
import driver.linux.sysfs;
import driver.linux.fdwatch;

version (WifiStaKernel) import driver.linux.nl80211_sta;
else                    import driver.linux.wpa_supplicant;
version (WifiApKernel)  import driver.linux.nl80211_ap;
else                    import driver.linux.hostapd;
import driver.linux.raw : RawAdapter, PACKET_OUTGOING;
import urt.internal.sys.posix : pollfd, POLLIN;

// KernelMirror builds let the kernel own IP; an AP must publish its netdev
// ifindex so the mirror can place the configured address/routes on it.
version (KernelMirror)
    import protocol.ip.linux_mirror : mirror_refresh_interface;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;
import router.iface.wifi;

nothrow @nogc:


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
        => super.mode();

    // VIF lookup for a bound AP.
    // The physical adapter stays the radio/STA netdev; every AP gets a
    // sibling AP-mode VIF. That makes AP/STA ownership independent of bind
    // order and avoids flipping the station netdev into AP mode.
    // Returns empty slice if `target` isn't bound to this radio.
    final const(char)[] vif_for(const(APInterface) target) const
    {
        auto aps = bound_aps;
        foreach (ap; aps)
        {
            if (ap is target)
                return tconcat(_adapter[], "-", target.name[]);
        }
        return null;
    }

    final void update_active_channel(ubyte ch)
    {
        set_active_channel(ch);
        sync_bound_ap_channels();
    }

    final void clear_active_sta_channel()
    {
        if (active_channel != 0)
            set_active_channel(0);
        sync_bound_ap_channels();
    }

    // Binding policy gate. Called from LinuxAP.validate / LinuxWlan.validate;
    // returns null when the proposed binding fits the chipset's advertised
    // interface_combinations, or a human-readable reason when it doesn't.
    // The candidate is the iface CONSIDERING binding (it's not in bound_sta /
    // bound_aps yet at validate time).
    final const(char)[] would_accept(const(WLANBaseInterface) candidate) const pure
    {
        if (!_phy_caps.valid)
            return null;  // chipset capabilities unknown -- be optimistic.

        bool candidate_is_ap = cast(const(APInterface))candidate !is null;
        bool candidate_is_sta = !candidate_is_ap && (cast(const(WLANInterface))candidate !is null);

        if (candidate_is_ap && !_phy_caps.supports_ap)
            return "driver does not support AP mode";
        if (candidate_is_sta && !_phy_caps.supports_sta)
            return "driver does not support STA mode";

        bool already_bound;
        if (candidate_is_ap)
        {
            foreach (ap; bound_aps)
            {
                if (ap is candidate)
                {
                    already_bound = true;
                    break;
                }
            }
        }
        else if (candidate_is_sta)
            already_bound = bound_sta is candidate;

        // Counts after this binding takes effect.
        size_t ap_count = bound_aps.length + (candidate_is_ap && !already_bound ? 1 : 0);
        bool has_sta = bound_sta !is null || candidate_is_sta;

        if (monitor && !_phy_caps.supports_monitor)
            return "driver does not support monitor mode";

        if (monitor && has_sta && ap_count > 0)
        {
            if (!_phy_caps.supports_sta_ap_monitor)
                return "driver does not support simultaneous STA + AP + monitor";
            if (ap_count > _phy_caps.max_aps_with_sta_monitor)
            {
                if (_phy_caps.max_aps_with_sta_monitor <= 1)
                    return "driver does not support STA + multi-AP + monitor";
                return "too many APs configured with STA + monitor for this driver";
            }
        }
        else if (monitor && has_sta)
        {
            if (!_phy_caps.supports_sta_monitor)
                return "driver does not support simultaneous STA + monitor";
        }
        else if (monitor && ap_count > 0)
        {
            if (!_phy_caps.supports_ap_monitor)
                return "driver does not support simultaneous AP + monitor";
            if (ap_count > _phy_caps.max_aps_with_monitor)
            {
                if (_phy_caps.max_aps_with_monitor <= 1)
                    return "driver does not support multi-AP + monitor";
                return "too many APs configured with monitor for this driver";
            }
        }
        else if (has_sta && ap_count > 0)
        {
            if (!_phy_caps.supports_sta_ap)
                return "driver does not support simultaneous STA + AP";
            if (ap_count > _phy_caps.max_aps_with_sta)
            {
                if (_phy_caps.max_aps_with_sta <= 1)
                    return "driver does not support STA + multi-AP";
                return "too many APs configured with STA for this driver";
            }
        }
        else if (ap_count > _phy_caps.max_aps)
        {
            if (_phy_caps.max_aps <= 1)
                return "driver does not support multi-AP";
            return "too many APs configured for this driver";
        }

        return null;
    }

    final const(char)[] would_accept_monitor() const pure
    {
        if (!_phy_caps.valid)
            return null;
        if (!_phy_caps.supports_monitor)
            return "driver does not support monitor mode";

        bool has_sta = bound_sta !is null;
        size_t ap_count = bound_aps.length;

        if (has_sta && ap_count > 0)
        {
            if (!_phy_caps.supports_sta_ap_monitor)
                return "driver does not support simultaneous STA + AP + monitor";
            if (ap_count > _phy_caps.max_aps_with_sta_monitor)
            {
                if (_phy_caps.max_aps_with_sta_monitor <= 1)
                    return "driver does not support STA + multi-AP + monitor";
                return "too many APs configured with STA + monitor for this driver";
            }
        }
        else if (has_sta)
        {
            if (!_phy_caps.supports_sta_monitor)
                return "driver does not support simultaneous STA + monitor";
        }
        else if (ap_count > 0)
        {
            if (!_phy_caps.supports_ap_monitor)
                return "driver does not support simultaneous AP + monitor";
            if (ap_count > _phy_caps.max_aps_with_monitor)
            {
                if (_phy_caps.max_aps_with_monitor <= 1)
                    return "driver does not support multi-AP + monitor";
                return "too many APs configured with monitor for this driver";
            }
        }

        return null;
    }

protected:

    override bool validate() const
    {
        if (_adapter.empty)
            return false;
        if (monitor && _phy_caps.valid && would_accept_monitor() !is null)
            return false;
        return true;
    }

    override const(char)[] status_message() const
    {
        if (monitor)
        {
            if (auto reason = would_accept_monitor())
                return reason;
            if (auto reason = monitor_failure_message(_monitor_failure))
                return reason;
        }
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        // We own the adapter outright: reset it to a clean station-mode slate --
        // tearing down any AP/association/keys left by hostapd, NetworkManager,
        // wpa_supplicant or a previous run -- before any STA/AP binds to it.
        _ifindex = read_ifindex(_adapter[]);
        if (_ifindex != 0)
            reset_device(_adapter[], _ifindex);
        apply_configured_mtu();

        open_scan_sockets();
        sync_monitor_vif();

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_state();
        }

        // Carrier is telemetry, not a startup condition: an idle radio has no
        // carrier until a bound STA associates or a bound AP beacons -- both of
        // which can only happen once the radio is running.
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        close_monitor_vif();
        close_scan_sockets();
        return CompletionStatus.complete;
    }

    override void on_wlan_bind_changed()
    {
        sync_bound_ap_channels();
    }

    override void on_monitor_changed(bool enabled)
    {
        if (running)
            sync_monitor_vif();
    }

    override void on_active_channel_changed(ubyte ch)
    {
        sync_bound_ap_channels();
    }

    override void on_channel_changed(ubyte ch)
    {
        if (!sta_providing_channel())
            sync_bound_ap_channels();
    }

    override void on_mtu_changed()
    {
        apply_configured_mtu();
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

    }

private:
    String _adapter;
    SysTime _last_refresh;

    PhyCapabilities _phy_caps;
    bool _caps_queried;

    bool sta_providing_channel() const
    {
        auto wlan = cast(const(LinuxWlan))bound_sta;
        return wlan !is null && wlan._sta.connected;
    }

    // Decide which channel AP VIFs should beacon on right now:
    // connected STA wins; otherwise the configured radio channel wins.
    ubyte target_channel() const
    {
        if (sta_providing_channel())
            return active_channel != 0 ? active_channel : channel;
        return channel;
    }

    void sync_bound_ap_channels()
    {
        ubyte desired = target_channel();
        foreach (base; bound_aps)
        {
            auto ap = cast(LinuxAP)base;
            if (ap && ap.running && ap._running_channel != desired)
                ap.restart();
        }
        sync_monitor_channel();
    }

    void refresh_state()
    {
        // Channel query is an nl80211 job (NL80211_CMD_GET_INTERFACE,
        // NL80211_ATTR_WIPHY_FREQ -> channel mapping); not wired yet.
        // We still pull MAC/MTU/carrier/speed from sysfs -- carrier-up on a
        // wlan netdev means associated, which is the proxy for "STA online"
        // until nl80211 lands.

        // Snapshot chipset capabilities once -- but only latch after the
        // netdev's ifindex resolves; at startup the adapter may still be
        // bouncing (eg a daemon restart recreating VIFs).
        if (!_caps_queried)
        {
            uint ifindex = read_ifindex(_adapter[]);
            if (ifindex != 0)
            {
                query_phy_capabilities(ifindex, _phy_caps);
                _caps_queried = true;
                log.info("phy capabilities: valid=", _phy_caps.valid, " sta=", _phy_caps.supports_sta,
                         " ap=", _phy_caps.supports_ap, " monitor=", _phy_caps.supports_monitor,
                         " sta+ap=", _phy_caps.supports_sta_ap, " max-aps=", _phy_caps.max_aps,
                         " max-aps-with-sta=", _phy_caps.max_aps_with_sta,
                         " sta+monitor=", _phy_caps.supports_sta_monitor,
                         " ap+monitor=", _phy_caps.supports_ap_monitor,
                         " sta+ap+monitor=", _phy_caps.supports_sta_ap_monitor,
                         " max-aps-with-monitor=", _phy_caps.max_aps_with_monitor,
                         " max-aps-with-sta-monitor=", _phy_caps.max_aps_with_sta_monitor,
                         " max-monitors=", _phy_caps.max_monitors);
            }
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

    void apply_configured_mtu()
    {
        if (_mtu == 0 || _adapter.empty)
            return;
        if (!set_adapter_mtu(_adapter[], actual_mtu))
            log.warning("failed to set MTU ", actual_mtu, " on '", _adapter, "'");
    }

    // --- nl80211 scan (device-level: the radio owns the adapter) ---
public:
    override bool scanning() const
        => _scanning;

    override void cancel_scan()
    {
        _scan_handler = null;   // a late completion finds no handler and no-ops
        _scanning = false;
    }

    override bool start_scan(ref const WifiScanConfig cfg, ScanHandler done)
    {
        if (_scanning || _scan_cmd_fd < 0 || _nl_family == 0 || !running)
            return false;
        NlBuilder b;
        b.start(_nl_family, NLM_F_REQUEST | NLM_F_ACK, ++_scan_seq, NL80211_CMD_TRIGGER_SCAN);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        // One SSID entry: empty = wildcard (broadcast active probe); a specific
        // SSID also probes hidden APs. Either way an active scan.
        size_t nest = b.nest_start(NL80211_ATTR_SCAN_SSIDS);
        b.put_bytes(1, cast(const(ubyte)[])cfg.ssid);
        b.nest_end(nest);
        if (!nl_ack(_scan_cmd_fd, b, "TRIGGER_SCAN"))
            return false;
        _scan_handler = done;
        _scanning = true;
        return true;
    }

private:
    uint _ifindex;
    int _scan_cmd_fd = -1;
    int _scan_event_fd = -1;
    ushort _nl_family;
    uint _scan_seq;
    ScanHandler _scan_handler;
    bool _scanning;
    bool _scan_fdwatch_registered;
    RawAdapter _monitor_raw;
    uint _monitor_ifindex;
    bool _monitor_created;
    ubyte _monitor_channel;
    MonitorFailure _monitor_failure;

    void open_scan_sockets()
    {
        if (_scan_cmd_fd >= 0)
            return;
        _scan_cmd_fd = nl_open_socket(false);
        _scan_event_fd = nl_open_socket(true);
        if (_scan_cmd_fd < 0 || _scan_event_fd < 0)
        {
            close_scan_sockets();
            return;
        }
        uint scan_grp, mlme_grp;
        if (resolve_nl80211(_scan_cmd_fd, _nl_family, scan_grp, mlme_grp) && scan_grp)
            setsockopt(_scan_event_fd, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &scan_grp, scan_grp.sizeof);
        if (!_scan_fdwatch_registered && add_fd_watcher(&service_scan_fds, &collect_scan_fds))
        {
            _scan_fdwatch_registered = true;
            fd_watch_changed();
        }
    }

    void close_scan_sockets()
    {
        if (_scan_fdwatch_registered)
        {
            remove_fd_watcher(&service_scan_fds);
            _scan_fdwatch_registered = false;
        }
        if (_scanning)
            finish_scan(null, false);
        nl_close(_scan_cmd_fd);
        nl_close(_scan_event_fd);
        _nl_family = 0;
        fd_watch_changed();
    }

    void collect_scan_fds(ref Array!pollfd fds)
    {
        if (_scan_event_fd >= 0)
            fds ~= pollfd(_scan_event_fd, POLLIN);
        if (_monitor_raw.valid)
            fds ~= pollfd(_monitor_raw.fd, POLLIN);
    }

    void service_scan_fds()
    {
        pump_scan();
        pump_monitor();
    }

    const(char)[] monitor_vif_name() const
    {
        return tconcat(_adapter[], "-mon");
    }

    void sync_monitor_vif()
    {
        if (!monitor)
        {
            close_monitor_vif();
            return;
        }
        _monitor_failure = MonitorFailure.none;
        if (_phy_caps.valid && !_phy_caps.supports_monitor)
        {
            log.warning("monitor mode requested but driver does not advertise monitor VIF support");
            return;
        }
        if (_phy_caps.valid)
        {
            if (auto reason = would_accept_monitor())
            {
                log.warning("monitor mode requested but ", reason);
                return;
            }
        }
        if (_ifindex == 0)
            _ifindex = read_ifindex(_adapter[]);
        if (_ifindex == 0)
            return;

        const(char)[] vif = monitor_vif_name();
        if (_monitor_ifindex == 0)
            _monitor_ifindex = read_ifindex(vif);
        if (_monitor_ifindex == 0)
        {
            uint wiphy = read_wiphy(_ifindex);
            if (wiphy == uint.max || !create_monitor_vif(wiphy, vif))
            {
                _monitor_failure = MonitorFailure.create_vif;
                log.warning("failed to create monitor VIF '", vif, "'");
                return;
            }
            _monitor_created = true;
            _monitor_ifindex = read_ifindex(vif);
        }
        if (_monitor_ifindex == 0)
            return;

        if (!_monitor_raw.valid)
        {
            auto r = _monitor_raw.open(vif, false);
            if (r.failed)
            {
                _monitor_failure = MonitorFailure.open_vif;
                log.warning("failed to open monitor VIF '", vif, "': ", r.message);
                return;
            }
            _monitor_failure = MonitorFailure.none;
            fd_watch_changed();
        }
        sync_monitor_channel();
    }

    void close_monitor_vif()
    {
        bool changed = _monitor_raw.valid;
        _monitor_raw.close();
        if (_monitor_created && _monitor_ifindex != 0)
            delete_vif(_monitor_ifindex);
        _monitor_ifindex = 0;
        _monitor_created = false;
        _monitor_channel = 0;
        _monitor_failure = MonitorFailure.none;
        if (changed)
            fd_watch_changed();
    }

    void sync_monitor_channel()
    {
        if (!_monitor_raw.valid || _monitor_ifindex == 0)
            return;
        ubyte ch = target_channel();
        if (ch == 0 || ch == _monitor_channel)
            return;
        WifiBand band = ch <= 14 ? WifiBand.band_2g4 : WifiBand.band_5g;
        if (set_vif_channel(_monitor_ifindex, channel_to_freq(ch, band)))
        {
            _monitor_channel = ch;
            _monitor_failure = MonitorFailure.none;
        }
        else
        {
            _monitor_failure = MonitorFailure.set_channel;
            log.warning("failed to set monitor VIF channel to ", ch);
        }
    }

    void pump_monitor()
    {
        if (!_monitor_raw.valid)
            return;

        while (true)
        {
            const(ubyte)[] data;
            uint wire_len;
            MonoTime ts;
            ubyte pkttype;
            int r = _monitor_raw.poll_ll(data, wire_len, ts, pkttype);
            if (r == 0)
                break;
            if (r < 0)
            {
                add_rx_drop();
                break;
            }
            if (pkttype == PACKET_OUTGOING)
                continue;
            incoming_monitor_frame(data, ts);
        }
    }

    void incoming_monitor_frame(const(ubyte)[] data, MonoTime ts)
    {
        if (data.length < 4)
        {
            add_rx_drop();
            return;
        }

        ushort radiotap_len = load_le16(data[2 .. 4]);
        if (radiotap_len < 4 || radiotap_len > data.length)
        {
            add_rx_drop();
            return;
        }

        Packet packet;
        ref wifi = packet.init!Wifi80211(data, ts);
        wifi.rssi = parse_radiotap_rssi(data[0 .. radiotap_len]);
        wifi.channel = parse_radiotap_channel(data[0 .. radiotap_len]);
        if (wifi.channel == 0)
            wifi.channel = target_channel();

        size_t h = radiotap_len;
        if (data.length >= h + 24)
        {
            wifi.frame_control = load_le16(data[h .. h + 2]);
            wifi.addr1 = MACAddress(data[h + 4], data[h + 5], data[h + 6],
                                     data[h + 7], data[h + 8], data[h + 9]);
            wifi.addr2 = MACAddress(data[h + 10], data[h + 11], data[h + 12],
                                     data[h + 13], data[h + 14], data[h + 15]);
            wifi.addr3 = MACAddress(data[h + 16], data[h + 17], data[h + 18],
                                     data[h + 19], data[h + 20], data[h + 21]);
            wifi.seq_ctrl = load_le16(data[h + 22 .. h + 24]);
        }

        dispatch(packet);
    }

    static ushort load_le16(const(ubyte)[] v) pure
    {
        return cast(ushort)(v[0] | (v[1] << 8));
    }

    static uint load_le32(const(ubyte)[] v) pure
    {
        return cast(uint)(v[0] | (v[1] << 8) | (v[2] << 16) | (v[3] << 24));
    }

    static size_t rtap_align(size_t off, size_t alignment) pure
    {
        return (off + alignment - 1) & ~(alignment - 1);
    }

    static ubyte parse_radiotap_channel(const(ubyte)[] rtap) pure
    {
        ushort freq;
        byte rssi;
        parse_radiotap_common(rtap, freq, rssi);
        return freq_to_channel(freq);
    }

    static byte parse_radiotap_rssi(const(ubyte)[] rtap) pure
    {
        ushort freq;
        byte rssi;
        parse_radiotap_common(rtap, freq, rssi);
        return rssi;
    }

    static void parse_radiotap_common(const(ubyte)[] rtap, ref ushort freq, ref byte rssi) pure
    {
        if (rtap.length < 8)
            return;

        size_t off = 8;
        uint present = load_le32(rtap[4 .. 8]);
        while (present & (1u << 31))
        {
            if (off + 4 > rtap.length)
                return;
            present = load_le32(rtap[off .. off + 4]);
            off += 4;
        }

        present = load_le32(rtap[4 .. 8]);
        foreach (bit; 0 .. 15)
        {
            size_t alignment = 1;
            size_t len = 0;
            switch (bit)
            {
                case 0:  alignment = 8; len = 8; break; // TSFT
                case 1:  len = 1; break;            // flags
                case 2:  len = 1; break;            // rate
                case 3:  alignment = 2; len = 4; break; // channel
                case 4:  alignment = 2; len = 2; break; // FHSS
                case 5:  len = 1; break;            // antenna signal (dBm)
                case 6:  len = 1; break;            // antenna noise (dBm)
                case 7:  alignment = 2; len = 2; break; // lock quality
                case 8:  alignment = 2; len = 2; break; // tx attenuation
                case 9:  alignment = 2; len = 2; break; // db tx attenuation
                case 10: len = 1; break;            // dbm tx power
                case 11: len = 1; break;            // antenna
                case 12: len = 1; break;            // db antenna signal
                case 13: len = 1; break;            // db antenna noise
                case 14: alignment = 2; len = 2; break; // rx flags
                default: break;
            }

            if ((present & (1u << bit)) == 0)
                continue;
            off = rtap_align(off, alignment);
            if (off + len > rtap.length)
                return;
            if (bit == 3)
                freq = load_le16(rtap[off .. off + 2]);
            else if (bit == 5)
                rssi = cast(byte)rtap[off];
            off += len;
        }
    }

    // Drain scan-done notifications off the event socket; on completion pull the
    // results with a GET_SCAN dump and hand them to the pending handler.
    void pump_scan()
    {
        if (_scan_event_fd < 0)
            return;
        ubyte[8192] buf = void;
        while (true)
        {
            ptrdiff_t n = recv(_scan_event_fd, buf.ptr, buf.length, 0);
            if (n <= 0)
                break;
            const(ubyte)[] data = buf[0 .. cast(size_t)n];
            while (data.length >= nlmsghdr.sizeof)
            {
                const nlmsghdr* mh = cast(const nlmsghdr*)data.ptr;
                uint len = mh.nlmsg_len;
                if (len < nlmsghdr.sizeof || len > data.length)
                    break;
                if (mh.nlmsg_type == _nl_family && len >= nlmsghdr.sizeof + genlmsghdr.sizeof)
                {
                    const genlmsghdr* gh = cast(const genlmsghdr*)(data.ptr + nlmsghdr.sizeof);
                    if (gh.cmd == NL80211_CMD_NEW_SCAN_RESULTS)
                        deliver_scan_results();
                    else if (gh.cmd == NL80211_CMD_SCAN_ABORTED)
                        finish_scan(null, false);
                }
                uint aligned = (len + 3) & ~3u;
                if (aligned >= data.length)
                    break;
                data = data[aligned .. $];
            }
        }
    }

    void deliver_scan_results()
    {
        if (!_scanning)
            return;
        WifiScanResult[32] results = void;
        size_t n = dump_scan_results(results[]);
        finish_scan(results[0 .. n], true);
    }

    // Synchronous GET_SCAN dump of the kernel's cached BSS table -- fast (no
    // trigger). Used by the scan-completion path and by the CLI scan command.
    size_t dump_scan_results(WifiScanResult[] buf)
    {
        if (_scan_cmd_fd < 0 || _nl_family == 0)
            return 0;
        NlBuilder b;
        b.start(_nl_family, NLM_F_REQUEST | NLM_F_DUMP, ++_scan_seq, NL80211_CMD_GET_SCAN);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        const(void)[] msg = b.finish();
        sockaddr_nl k;
        k.nl_family = AF_NETLINK;
        if (sendto(_scan_cmd_fd, msg.ptr, msg.length, 0, &k, sockaddr_nl.sizeof) != cast(ptrdiff_t)msg.length)
            return 0;

        size_t count = 0;
        bool done = false;
        while (!done)
        {
            ubyte[16_384] reply = void;
            ptrdiff_t n = recv(_scan_cmd_fd, reply.ptr, reply.length, 0);
            if (n <= 0)
                break;
            const(ubyte)[] data = reply[0 .. cast(size_t)n];
            while (data.length >= nlmsghdr.sizeof)
            {
                const nlmsghdr* mh = cast(const nlmsghdr*)data.ptr;
                uint len = mh.nlmsg_len;
                if (len < nlmsghdr.sizeof || len > data.length)
                    break;
                if (mh.nlmsg_type == NLMSG_DONE || mh.nlmsg_type == NLMSG_ERROR)
                {
                    done = true;
                    break;
                }
                if (mh.nlmsg_type == _nl_family && len >= nlmsghdr.sizeof + genlmsghdr.sizeof && count < buf.length)
                {
                    if (parse_bss(data[nlmsghdr.sizeof + genlmsghdr.sizeof .. len], buf[count]))
                        ++count;
                }
                uint aligned = (len + 3) & ~3u;
                if (aligned >= data.length)
                    break;
                data = data[aligned .. $];
            }
        }
        return count;
    }

    // Kick a fresh broadcast scan without a completion handler; results land in
    // the kernel cache, readable later via dump_scan_results.
    bool trigger_scan()
    {
        if (_scan_cmd_fd < 0 || _nl_family == 0 || !running)
            return false;
        NlBuilder b;
        b.start(_nl_family, NLM_F_REQUEST | NLM_F_ACK, ++_scan_seq, NL80211_CMD_TRIGGER_SCAN);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        size_t nest = b.nest_start(NL80211_ATTR_SCAN_SSIDS);
        b.put_bytes(1, null);   // wildcard SSID -> active broadcast probe
        b.nest_end(nest);
        return nl_ack(_scan_cmd_fd, b, "TRIGGER_SCAN", true);   // quiet: harmless if busy
    }

    void finish_scan(scope const(WifiScanResult)[] results, bool ok)
    {
        if (!_scanning)
            return;
        _scanning = false;
        ScanHandler h = _scan_handler;
        _scan_handler = null;
        if (h !is null)
            h(results, ok);
    }

    bool parse_bss(const(ubyte)[] attrs, out WifiScanResult r)
    {
        const(ubyte)[] bss = find_attr(attrs, NL80211_ATTR_BSS);
        if (bss.length == 0)
            return false;
        const(ubyte)[] bssid = find_attr(bss, NL80211_BSS_BSSID);
        if (bssid.length < 6)
            return false;
        r.bssid[] = bssid[0 .. 6];
        const(ubyte)[] fr = find_attr(bss, NL80211_BSS_FREQUENCY);
        uint freq = fr.length >= 4 ? *cast(const(uint)*)fr.ptr : 0;
        r.channel = freq_to_channel(freq);
        r.band = freq >= 5000 ? WifiBand.band_5g : WifiBand.band_2g4;
        const(ubyte)[] sig = find_attr(bss, NL80211_BSS_SIGNAL_MBM);
        if (sig.length >= 4)
            r.rssi = cast(byte)(*cast(const(int)*)sig.ptr / 100);   // mBm -> dBm
        r.auth = DrvWifiAuth.open;
        parse_ies(find_attr(bss, NL80211_BSS_INFORMATION_ELEMENTS), r);
        return true;
    }

    static void parse_ies(const(ubyte)[] ies, ref WifiScanResult r)
    {
        size_t i = 0;
        while (i + 2 <= ies.length)
        {
            ubyte id = ies[i];
            ubyte len = ies[i + 1];
            if (i + 2 + len > ies.length)
                break;
            const(ubyte)[] payload = ies[i + 2 .. i + 2 + len];
            if (id == 0)   // SSID
            {
                size_t c = len < r.ssid_buf.length ? len : r.ssid_buf.length;
                r.ssid_buf[0 .. c] = cast(const(char)[])payload[0 .. c];
                r.ssid_len = cast(ubyte)c;
            }
            else if (id == 48)  // RSN -> WPA2/WPA3 (treated as WPA2-PSK for now)
                r.auth = DrvWifiAuth.wpa2_psk;
            i += 2 + len;
        }
    }
}


enum MonitorFailure : ubyte
{
    none,
    create_vif,
    open_vif,
    set_channel,
}


const(char)[] monitor_failure_message(MonitorFailure f) pure
{
    final switch (f)
    {
        case MonitorFailure.none:        return null;
        case MonitorFailure.create_vif:  return "monitor: failed to create VIF";
        case MonitorFailure.open_vif:    return "monitor: failed to open packet socket";
        case MonitorFailure.set_channel: return "monitor: failed to set channel";
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

    // Active link state comes from the nl80211 session + in-process supplicant
    // (driver.linux.nl80211_sta). The configured SSID lives in the base; we
    // kick off the connect flow with it on startup.

    override MACAddress bssid() const
        => _sta.bssid;

    override int rssi() const
        => _sta.rssi;

    override ubyte signal_quality() const
        => _sta.signal_quality;

    version (WifiStaDaemon)
    override const(char)[] ssid() const pure
        => _sta.active_ssid;

    override const(char)[] status_message() const
    {
        auto r = cast(const(LinuxWifiRadio))radio;
        if (!r)
            return "no radio configured";
        if (super.ssid.empty)
            return "SSID not set";
        if (!r.running)
            return "Waiting for radio";
        if (auto reason = r.would_accept(this))
            return reason;
        version (WifiStaKernel)
        {
            if (_scan_inflight)
                return "scanning";
            if (_scan_retry_armed)
                return "waiting to rescan";
        }
        if (!_sta.valid)
            return super.status_message();
        return _sta.status_message();
    }

protected:

    override bool validate() const
    {
        if (!super.validate())
            return false;
        auto r = cast(const(LinuxWifiRadio))radio;
        if (!r || !r.running)
            return false;
        if (r.would_accept(this) !is null)
            return false;
        return true;
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return CompletionStatus.error;

        if (!_raw.valid)
        {
            auto rr = _raw.open(r.adapter);
            if (rr.failed)
            {
                log.error(rr.message);
                return CompletionStatus.error;
            }
            apply_configured_mtu();
            refresh_os_state();
            register_fdwatch();
        }

        // Publish the netdev ifindex so the IP mirror can place an address on it
        // -- e.g. a dhcp-client lease bound to this STA (the lease address is a
        // dynamic IPAddress created after we're up, so it must resolve then).
        version (KernelMirror)
        {
            if (kernel_ifindex() == 0)
            {
                set_kernel_ifindex(read_ifindex(r.adapter));
                mirror_refresh_interface(this);
            }
        }

        version (WifiStaKernel)
        {
            // Open the nl80211 STA session; update() then scans and connects to
            // the matching BSS (a concrete BSS lets cfg80211 install keys).
            if (!_sta.valid)
            {
                auto rs = _sta.open(r.adapter, &_raw);
                if (rs.failed)
                {
                    log.error(rs.message);
                    return CompletionStatus.error;
                }
                fd_watch_changed();
            }
            service_io();
            if (_sta.connected)
                return CompletionStatus.complete;
            if (_sta.failed)
                return CompletionStatus.error;
            ensure_scan_started();
            return CompletionStatus.continue_;
        }
        else
        {
            // Open the wpa_supplicant ctrl socket, push the configured network,
            // and wait until it reports an association before going Running.
            if (!_sta.valid)
            {
                auto rs = _sta.open(r.adapter);
                if (rs.failed)
                {
                    log.error(rs.message);
                    return CompletionStatus.error;
                }
                if (super.ssid.length > 0)
                    _sta.set_network(super.ssid, get_password());
            }
            _sta.update();
            return _sta.connected ? CompletionStatus.complete : CompletionStatus.continue_;
        }
    }

    override CompletionStatus shutdown()
    {
        version (WifiStaKernel)
        {
            if (_scan_inflight)
            {
                if (auto r = cast(LinuxWifiRadio)radio)
                    r.cancel_scan();
                _scan_inflight = false;
            }
            cancel_scan_retry();
        }
        unregister_fdwatch();
        _sta.close();
        _raw.close();
        version (WifiStaKernel)
        {
            if (auto r = cast(LinuxWifiRadio)radio)
                r.clear_active_sta_channel();
        }
        // Drop our kernel netdev binding and withdraw any mirrored addresses.
        version (KernelMirror)
        {
            if (kernel_ifindex() != 0)
            {
                set_kernel_ifindex(0);
                mirror_refresh_interface(this);
            }
        }
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;

        version (WifiStaKernel)
        {
            // Legacy heartbeat fallback. The real pump is fdwatch -> service_io.
            service_io();
        }
        else
        {
            SysTime now = getSysTime();
            // Daemon backend: poll wpa_supplicant; bounce the interface if the
            // association drops so startup re-runs the connect.
            if (now - _last_refresh >= 1.seconds)
            {
                _last_refresh = now;
                _sta.update();
                ubyte ch = freq_to_channel(_sta.freq);
                if (_sta.connected && ch != 0)
                    r.update_active_channel(ch);
                mark_set!(typeof(this), [ "ssid", "bssid", "rssi", "signal-quality", "status" ])();
                if (!_sta.connected)
                {
                    restart();
                    return;
                }
            }
            pump_raw_frames();
        }
    }

    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

    override void on_mtu_changed()
    {
        apply_configured_mtu();
    }

private:
    RawAdapter _raw;
    SysTime _last_refresh;
    bool _fdwatch_registered;

    version (WifiStaKernel)
    {
        Nl80211Sta _sta;
        bool _scan_inflight;
        bool _scan_retry_armed;
    }
    else
    {
        WpaSupplicantSta _sta;
    }

    void apply_configured_mtu()
    {
        if (_mtu == 0)
            return;
        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;
        if (!set_adapter_mtu(r.adapter, actual_mtu))
            log.warning("failed to set MTU ", actual_mtu, " on '", r.adapter, "'");
    }

    void refresh_os_state()
    {
        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;
        OSAdapterInfo info;
        if (!query_adapter(r.adapter, info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)     mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu) mark_set!(typeof(this), "max-l2mtu")();
    }

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
        if (_raw.valid)
            fds ~= pollfd(_raw.fd, POLLIN);
        version (WifiStaKernel)
        {
            if (_sta.event_fd >= 0)
                fds ~= pollfd(_sta.event_fd, POLLIN);
        }
    }

    void service_io()
    {
        version (WifiStaKernel)
        {
            bool was_connected = _sta.connected;
            _sta.pump();
            pump_raw_frames();

            if (_sta.connected)
            {
                refresh_connected_state();
                if (!was_connected)
                    post_progress_event();
            }
            else if (_sta.failed)
            {
                post_progress_event();
            }
            else if (_sta.disconnected)
            {
                if (auto r = cast(LinuxWifiRadio)radio)
                    r.clear_active_sta_channel();
                restart();
            }
        }
        else
            pump_raw_frames();
    }

    void pump_raw_frames()
    {
        const(ubyte)[] data;
        uint wire_len;
        MonoTime ts;
        ubyte pkttype;

        while (true)
        {
            int res = _raw.poll_ll(data, wire_len, ts, pkttype);
            if (res <= 0)
                break;

            if (data.length < wire_len)
            {
                add_rx_drop();
                continue;
            }

            if (data.length >= 14 && data[12] == 0x88 && data[13] == 0x8e)
            {
                if (pkttype == PACKET_OUTGOING)
                    continue;
                ubyte[6] src = data[6 .. 12];
                if (_sta.consume_eapol(src, data[14 .. $]))
                    continue;
            }

            incoming_ethernet_frame(data, ts);
        }
    }

    version (WifiStaKernel)
    {
        void refresh_connected_state()
        {
            _sta.refresh_signal();
            ubyte ch = freq_to_channel(_sta.freq);
            if (ch != 0)
            {
                if (auto r = cast(LinuxWifiRadio)radio)
                    r.update_active_channel(ch);
            }
            mark_set!(typeof(this), [ "bssid", "rssi", "signal-quality", "status" ])();
        }

        void ensure_scan_started()
        {
            if (!_sta.idle || _scan_inflight || super.ssid.length == 0)
                return;
            auto r = cast(LinuxWifiRadio)radio;
            if (!r || r.scanning)
            {
                schedule_scan_retry(1.seconds);
                return;
            }
            WifiScanConfig sc;
            sc.ssid = super.ssid;
            if (r.start_scan(sc, &on_scan_done))
            {
                _scan_inflight = true;
                mark_set!(typeof(this), "status")();
            }
            else
                schedule_scan_retry(2.seconds);
        }

        void schedule_scan_retry(Duration delay)
        {
            if (_scan_retry_armed)
                return;
            _scan_retry_armed = true;
            g_app.schedule(getTime() + delay, &scan_retry_event);
            mark_set!(typeof(this), "status")();
        }

        void cancel_scan_retry()
        {
            if (_scan_retry_armed)
            {
                g_app.cancel(&scan_retry_event);
                _scan_retry_armed = false;
            }
        }

        void scan_retry_event(MonoTime)
        {
            _scan_retry_armed = false;
            if (_state == State.starting || _state == State.running)
                ensure_scan_started();
        }

        void post_progress_event()
        {
            g_app.post_event(&progress_event, getTime(), EventPriority.control);
        }

        void progress_event(MonoTime)
        {
            if (_state == State.starting)
            {
                if (_sta.connected)
                    set_state(State.running);
                else if (_sta.failed)
                    set_state(State.failure);
                else
                    mark_set!(typeof(this), "status")();
            }
        }

        // Scan completed: pick the strongest BSS for our SSID and connect to it.
        void on_scan_done(scope const(WifiScanResult)[] results, bool ok)
        {
            _scan_inflight = false;
            if (!ok)
            {
                schedule_scan_retry(2.seconds);
                return;
            }
            const(WifiScanResult)* best;
            foreach (ref res; results)
            {
                if (res.ssid != super.ssid)
                    continue;
                if (best is null || res.rssi > best.rssi)
                    best = &res;
            }
            if (best is null)
            {
                log.warning("ssid '", super.ssid, "' not found in scan");
                schedule_scan_retry(3.seconds);
                return;
            }
            if (!_sta.connect(super.ssid, get_password(), best.bssid, channel_to_freq(best.channel, best.band)))
                post_progress_event();
            mark_set!(typeof(this), "status")();
        }
    }
}


// ---------------------------------------------------------------------------
// APInterface, multi-BSS aware.
//
// Each LinuxAP binds its packet path (RawAdapter) to its own AP-mode VIF:
//   "<adapter>-<ap_name>" created on the radio's wiphy.
// VIFs may not exist at startup() time -- we create them and retry until the
// kernel surfaces them.
//
// Each AP also opens its own hostapd ctrl_iface against /var/run/hostapd/<vif>;
// per-BSS STATUS queries see themselves as ssid[0]/bssid[0]/num_sta[0], so no
// across-BSS index parsing is needed.
// ---------------------------------------------------------------------------

class LinuxAP : APInterface
{
nothrow @nogc:

    enum type_name = "ap";
    enum path = "/interface/ap";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LinuxAP, id, flags);
    }

protected:

    override bool validate() const
    {
        if (radio is null || ssid.empty)
            return false;
        auto r = cast(const(LinuxWifiRadio))radio;
        if (!r || !r.running)
            return false;
        if (r.would_accept(this) !is null)
            return false;
        return true;
    }

    override const(char)[] status_message() const
    {
        auto r = cast(const(LinuxWifiRadio))radio;
        if (!r)
            return "no radio configured";
        if (ssid.empty)
            return "SSID not set";
        if (!r.running)
            return "Waiting for radio";
        if (auto reason = r.would_accept(this))
            return reason;
        if (!_ap.running)
            return _ap.status_message();
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return CompletionStatus.continue_;
        auto vif = current_vif();
        if (vif.length == 0)
            return CompletionStatus.continue_;

        // Every AP gets a sibling AP-mode VIF; the physical adapter stays
        // reserved for the radio/STA side.
        if (read_ifindex(vif) == 0)
        {
            uint wiphy = read_wiphy(read_ifindex(r.adapter));
            if (wiphy == uint.max || !create_ap_vif(wiphy, vif))
                return CompletionStatus.continue_;
            _created_vif_ifindex = read_ifindex(vif);
        }

        if (!_raw.valid)
        {
            auto rr = _raw.open(vif);
            if (rr.failed)
            {
                if (!_raw_open_failure_logged)
                {
                    log.warning(rr.message);
                    _raw_open_failure_logged = true;
                }
                return CompletionStatus.continue_;
            }
            _raw_open_failure_logged = false;
            apply_configured_mtu();
            refresh_os_state(vif);
            register_fdwatch();
        }

        version (WifiApKernel)
        {
            if (!_ap.valid)
            {
                auto ro = _ap.open(vif, &_raw);
                if (ro.failed)
                {
                    log.warning(ro.message);
                    return CompletionStatus.continue_;
                }
                fd_watch_changed();
            }

            if (!_ap.running)
            {
                ubyte ch = r.target_channel();
                WifiBand band = ch <= 14 ? WifiBand.band_2g4 : WifiBand.band_5g;
                if (!_ap.start(ssid, get_password(), channel_to_freq(ch, band), ch, hidden))
                    return CompletionStatus.continue_;
                _running_channel = ch;
                arm_ap_timer_if_needed();
            }
        }
        else
        {
            // hostapd backend: open its ctrl socket and (re)load a single-BSS
            // config for this netdev. hostapd owns iftype + beaconing.
            if (!_ap.valid)
            {
                auto ro = _ap.open(vif);
                if (ro.failed)
                {
                    log.warning(ro.message);
                    return CompletionStatus.continue_;
                }
            }
            ubyte ch = r.target_channel();
            if (!_ap.running || _running_channel != ch)
            {
                if (!_ap.start(ssid, get_password(), auth, ch, r.country, hidden, client_isolation, max_clients))
                    return CompletionStatus.continue_;
                _running_channel = ch;
            }
        }

        // The BSS netdev is up; publish its kernel ifindex so the IP mirror
        // places ap0's address/routes on it (addresses added before the AP
        // started won't otherwise re-trigger a push).
        version (KernelMirror)
        {
            set_kernel_ifindex(read_ifindex(vif));
            mirror_refresh_interface(this);
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unregister_fdwatch();
        cancel_ap_timer();
        _ap.close();
        _raw.close();
        _running_channel = 0;
        if (_created_vif_ifindex != 0)
        {
            delete_vif(_created_vif_ifindex);
            _created_vif_ifindex = 0;
        }
        // Drop our kernel netdev binding and withdraw the mirrored addresses.
        version (KernelMirror)
        {
            if (kernel_ifindex() != 0)
            {
                set_kernel_ifindex(0);
                mirror_refresh_interface(this);
            }
        }
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;

        version (WifiApKernel)
        {
            // Legacy heartbeat fallback. The real pump is fdwatch -> service_io.
            service_io();
        }
        else
        {
            // hostapd backend: poll STATUS for operational state + channel.
            if (getSysTime() - _last_refresh >= 1.seconds)
            {
                _last_refresh = getSysTime();
                _ap.update();
                if (_ap.channel != 0)
                    r.update_active_channel(_ap.channel);
            }
            pump_raw_frames();
        }
    }

    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

    override void on_mtu_changed()
    {
        apply_configured_mtu();
    }

private:

    RawAdapter _raw;
    bool _raw_open_failure_logged;
    SysTime _last_refresh;
    uint _created_vif_ifindex;      // secondary-AP VIF we created (0 = none)
    ubyte _running_channel;
    bool _fdwatch_registered;
    bool _ap_timer_armed;

    version (WifiApKernel)
        Nl80211Ap _ap;
    else
        HostapdAp _ap;

    void apply_configured_mtu()
    {
        if (_mtu == 0)
            return;
        auto vif = current_vif();
        if (vif.length == 0)
            return;
        if (!set_adapter_mtu(vif, actual_mtu))
            log.warning("failed to set MTU ", actual_mtu, " on '", vif, "'");
    }

    void refresh_os_state(const(char)[] vif)
    {
        OSAdapterInfo info;
        if (!query_adapter(vif, info))
            return;
        AdapterChange c = apply_os_adapter_info(this, _l2mtu, _max_l2mtu, _status, info);
        if (c & AdapterChange.mtu)     mark_set!(typeof(this), [ "l2mtu", "actual-mtu" ])();
        if (c & AdapterChange.max_mtu) mark_set!(typeof(this), "max-l2mtu")();
    }

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
        if (_raw.valid)
            fds ~= pollfd(_raw.fd, POLLIN);
        version (WifiApKernel)
        {
            if (_ap.event_fd >= 0)
                fds ~= pollfd(_ap.event_fd, POLLIN);
        }
    }

    void service_io()
    {
        version (WifiApKernel)
        {
            _ap.pump();
            pump_raw_frames();
            if (_ap.failed)
            {
                restart();
                return;
            }
            arm_ap_timer_if_needed();
        }
        else
            pump_raw_frames();
    }

    void pump_raw_frames()
    {
        const(ubyte)[] data;
        uint wire_len;
        MonoTime ts;
        ubyte pkttype;

        while (true)
        {
            int res = _raw.poll_ll(data, wire_len, ts, pkttype);
            if (res <= 0)
                break;

            if (data.length < wire_len)
            {
                add_rx_drop();
                continue;
            }

            if (data.length >= 14 && data[12] == 0x88 && data[13] == 0x8e)
            {
                if (pkttype == PACKET_OUTGOING)
                    continue;
                ubyte[6] src = data[6 .. 12];
                if (_ap.consume_eapol(src, data[14 .. $]))
                    continue;
            }

            incoming_ethernet_frame(data, ts);
        }
    }

    version (WifiApKernel)
    {
        void arm_ap_timer_if_needed()
        {
            if (_ap_timer_armed || !_ap.needs_tick())
                return;
            _ap_timer_armed = true;
            g_app.schedule(getTime() + 250.msecs, &ap_timer_event);
        }

        void cancel_ap_timer()
        {
            if (_ap_timer_armed)
            {
                g_app.cancel(&ap_timer_event);
                _ap_timer_armed = false;
            }
        }

        void ap_timer_event(MonoTime)
        {
            _ap_timer_armed = false;
            if (_state != State.running && _state != State.starting)
                return;
            _ap.tick();
            if (_ap.failed)
            {
                restart();
                return;
            }
            arm_ap_timer_if_needed();
        }
    }
    else
    {
        void cancel_ap_timer() {}
    }

    // Returns empty slice if the radio isn't a LinuxWifiRadio or we aren't
    // bound (transitional states; caller should retry).
    const(char)[] current_vif() const
    {
        auto r = cast(const(LinuxWifiRadio))radio;
        return r ? r.vif_for(this) : null;
    }
}


// MHz -> 802.11 channel for the bands we support (2.4GHz + 5GHz). 6GHz uses
// op_class-based numbering and a different hostapd config shape; punt for now.
private ubyte freq_to_channel(uint freq_mhz) pure
{
    if (freq_mhz == 2484)
        return 14;
    if (freq_mhz >= 2412 && freq_mhz < 2484)
        return cast(ubyte)((freq_mhz - 2407) / 5);
    if (freq_mhz >= 5180 && freq_mhz <= 5905)
        return cast(ubyte)((freq_mhz - 5000) / 5);
    return 0;
}

private uint channel_to_freq(ubyte ch, WifiBand band) pure
{
    if (ch == 0)
        return 0;
    if (band == WifiBand.band_5g || ch > 14)
        return 5000 + ch * 5;
    if (ch == 14)
        return 2484;
    return 2412 + (ch - 1) * 5;
}


// Live view of nearby APs: re-scans on a timer and redraws a table each poll.
// Modelled on CollectionWatchState (the collection `print --watch` live view).
private final class WifiScanView : LiveViewState
{
nothrow @nogc:

    this(Session session, LinuxWifiRadio radio)
    {
        super(session, null);
        _radio = radio;
        refresh();
    }

    override uint content_height()
        => cast(uint)_count;

    override uint header_rows()
        => 1;

    override CommandCompletionState update()
    {
        if (getSysTime() - _last_refresh >= 2.seconds)
            refresh();
        return super.update();
    }

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }

        Table table;
        table.add_column("BSSID");
        table.add_column("CH", Table.TextAlign.right);
        table.add_column("SIGNAL", Table.TextAlign.right);
        table.add_column("SSID");
        foreach (ref res; _results[0 .. _count])
        {
            table.add_row();
            table.cell(tconcat(MACAddress(res.bssid)));
            table.cell(tconcat(res.channel));
            table.cell(tconcat(res.rssi, " dBm"));
            table.cell(res.ssid);
        }
        table.render_viewport(session, offset, count, _sticky_widths[]);
    }

    override const(char)[] status_text()
        => tconcat(_count, " APs | rescans every 2s");

private:
    LinuxWifiRadio _radio;
    WifiScanResult[64] _results = void;
    size_t _count;
    SysTime _last_refresh;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;

    void refresh()
    {
        _count = _radio.dump_scan_results(_results[]);
        _radio.trigger_scan();
        _last_refresh = getSysTime();
    }
}


// ---------------------------------------------------------------------------
// Driver module: discovers wifi adapters at startup, then receives async
// notifications from manager.os.netlink (RTM_NEWLINK / RTM_DELLINK) to keep
// the (Radio, WLAN) pairs in sync with the kernel's wifi netdevs.
// ---------------------------------------------------------------------------

class LinuxWlanModule : Module
{
    mixin DeclareModule!"interface.wifi.linux";
nothrow @nogc:

    override void pre_init()
    {
        subscribe_link_changed(&on_link_changed);
    }

    override void init()
    {
        g_app.console.register_collection!LinuxWifiRadio();
        g_app.console.register_collection!LinuxWlan();
        g_app.console.register_collection!LinuxAP();
        g_app.console.register_command!scan_cmd("/interface/wifi", this, "scan");
    }

    override void update()
    {
        // Defer the first adapter discovery until after startup.conf has run, so
        // an operator-configured radio (e.g. `/interface/wifi/add adapter=wlan0`)
        // claims its netdev before auto-discovery would create a duplicate radio
        // for the same adapter -- two radios on one netdev fight over iftype and
        // tear down each other's AP/association. Link-change events thereafter
        // keep the (Radio, WLAN) pairs in sync.
        if (!_initial_sync_done)
        {
            _initial_sync_done = true;
            sync_radios();
        }
    }

    // /interface/wifi/scan [radio] -- live view of nearby APs; re-scans every
    // couple of seconds and redraws (q/Ctrl-C to quit). <radio> defaults to the
    // first wifi radio.
    CommandState scan_cmd(Session session, Nullable!String radio)
    {
        LinuxWifiRadio r;
        foreach (rr; Collection!LinuxWifiRadio().values)
        {
            if (!radio) { r = rr; break; }
            if (rr.name == radio.value[]) { r = rr; break; }
        }
        if (!r)
        {
            session.write_line("no wifi radio found");
            return null;
        }
        return session.allocator.allocT!WifiScanView(session, r);
    }

private:

    bool _initial_sync_done;

    void on_link_changed(uint, const(char)[], bool, bool)
    {
        // Hold off until the deferred initial discovery has run (post
        // startup.conf); an early event could otherwise auto-create a duplicate
        // radio before an operator radio claims the adapter.
        if (!_initial_sync_done)
            return;
        sync_radios();
    }

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
                log_info(ModuleName, "Found wifi interface: \"", description, "\" (", name, ")");

                // dynamic: auto-discovery owns these and rediscovers them each
                // boot, so they aren't persisted to config -- and only dynamic
                // entries are reaped below when their netdev disappears.
                // Operator/config radios (flags == none) are left alone.
                auto radio = Collection!LinuxWifiRadio().create(tconcat(base, "-radio"), ObjectFlags.dynamic);
                radio.adapter = name;
                if (description.length > 0)
                    radio.comment = description.makeString(defaultAllocator);

                auto wlan = Collection!LinuxWlan().create(base, ObjectFlags.dynamic);
                wlan.radio = radio;
            }

            os_buf ~= name.makeString(defaultAllocator);
        });

        Array!LinuxWifiRadio gone;
        foreach (r; Collection!LinuxWifiRadio().values)
        {
            // Only reap what auto-discovery created; an operator/config radio is
            // not ours to remove even if its netdev momentarily disappears.
            if (!(r.flags & ObjectFlags.dynamic))
                continue;

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
            log_info(ModuleName, "Wifi adapter gone: ", r.adapter);
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
