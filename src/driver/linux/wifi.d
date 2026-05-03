module driver.linux.wifi;

// =====================================================================
// Linux wifi backend. Packet path: AF_PACKET on the wlan netdev (managed-
// mode delivers de-encapsulated ethernet frames). State + STA control:
// wpa_supplicant control socket; AP control: hostapd control socket; both
// daemons supervised externally. No direct nl80211 work.
//
// Outstanding:
//
// 1. Monitor mode / raw 802.11: a separate code path entirely. The radio
//    holds the AF_PACKET socket on a monX VIF, frames are 802.11+radiotap
//    not ethernet, so the EthernetInterface model doesn't fit -- needs the
//    WiFi80211Interface base to grow an incoming_80211_frame() path and
//    PacketType.wifi_80211. Worth doing only if a use case actually
//    requires L2-promisc on the wireless side. Creating the monitor VIF
//    needs a thin nl80211 binding (CMD_NEW_INTERFACE / SET_CHANNEL only --
//    not the full surface).
// =====================================================================

version (linux):

import urt.array;
import urt.conv;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import manager.os.netlink;
import manager.os.nl80211;
import manager.os.sysfs;

import driver.linux.ctrl_iface;
import driver.linux.hostapd;
import driver.linux.raw;
import driver.linux.wpa_supplicant;

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
        => "sta";

    // VIF lookup for a bound AP.
    //   no STA bound:     bound_aps[0] uses the radio's netdev; rest get VIFs.
    //   STA bound:        STA owns the netdev; ALL APs get VIFs.
    // Returns empty slice if `target` isn't bound to this radio.
    final const(char)[] vif_for(const(APInterface) target) const
    {
        auto aps = bound_aps;
        foreach (i, ap; aps)
        {
            if (ap is target)
            {
                bool primary = (i == 0 && bound_sta is null);
                return primary ? _adapter[] : tconcat(_adapter[], "-", target.name[]);
            }
        }
        return null;
    }

    final void update_active_channel(ubyte ch)
    {
        set_active_channel(ch);
    }

    // Binding policy gate. Called from LinuxAP.validate / LinuxWlan.validate;
    // returns null when the proposed binding fits the chipset's advertised
    // interface_combinations, or a human-readable reason when it doesn't.
    // The candidate is the iface CONSIDERING binding (it's not in bound_sta /
    // bound_aps yet at validate time).
    final const(char)[] would_accept(const(WLANBaseInterface) candidate) const pure
    {
        if (!_caps.valid)
            return null;  // chipset capabilities unknown -- be optimistic.

        bool candidate_is_ap = cast(const(APInterface))candidate !is null;
        bool candidate_is_sta = !candidate_is_ap && (cast(const(WLANInterface))candidate !is null);

        if (candidate_is_ap && !_caps.supports_ap)
            return "driver does not support AP mode";
        if (candidate_is_sta && !_caps.supports_sta)
            return "driver does not support STA mode";

        // Counts after this binding takes effect (candidate isn't in
        // bound_aps / bound_sta yet at validate time).
        size_t ap_count = bound_aps.length + (candidate_is_ap ? 1 : 0);
        bool has_sta = bound_sta !is null || candidate_is_sta;

        if (has_sta && ap_count > 0 && !_caps.supports_sta_ap)
            return "driver does not support simultaneous STA + AP";

        if (ap_count > _caps.max_aps)
        {
            if (_caps.max_aps <= 1)
                return "driver does not support multi-AP";
            return "too many APs configured for this driver";
        }

        return null;
    }

protected:

    override bool validate() const
        => !_adapter.empty;

    override CompletionStatus startup()
    {
        // Snapshot chipset capabilities once. Cheap (one nl80211 round-trip)
        // and the answer doesn't change without a kernel module reload, so
        // we don't bother re-querying after restarts.
        if (!_caps_queried)
        {
            uint ifindex = read_ifindex(_adapter[]);
            if (ifindex != 0)
                query_phy_capabilities(ifindex, _caps);
            _caps_queried = true;
        }

        // ctrl_iface sockets are best-effort: each daemon may or may not
        // be running. Packet path keeps working regardless.
        try_open_daemons();

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
        _wpa.close();
        _hostapd.close();
        return CompletionStatus.complete;
    }

    override void on_wlan_bind_changed()
    {
        // Any change to the bound set may shift VIF allocation (e.g. binding
        // a STA evicts the primary AP off the radio's netdev) so always sync.
        sync_hostapd_config();
    }

    override void on_active_channel_changed(ubyte ch)
    {
        // STA-driven channel updates land here. APs follow via RELOAD.
        sync_hostapd_config();
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

        // Track STA online/offline transitions for the channel-revert grace
        // period, and re-sync hostapd if the target channel has changed
        // (covers grace expiry where no other event would otherwise fire).
        track_sta_channel_authority(now);
        if (target_channel() != _last_synced_channel)
            sync_hostapd_config();
    }

private:
    enum channel_revert_grace = 30.seconds;

    String _adapter;
    SysTime _last_refresh;

    PhyCapabilities _caps;
    bool _caps_queried;

    // Channel arbitration state. _last_synced_channel is the value last
    // written to the hostapd config; sync_hostapd_config skips the RELOAD if
    // it hasn't changed. _sta_offline_since holds the moment the bound STA
    // last lost association so we can hold APs on its previous channel for
    // a grace window before reverting to the radio's configured channel.
    ubyte _last_synced_channel;
    SysTime _sta_offline_since;
    bool _sta_was_providing;

    bool sta_providing_channel() const
    {
        auto wlan = cast(const(LinuxWlan))bound_sta;
        return wlan !is null && wlan._wpa_state == WpaState.completed;
    }

    void track_sta_channel_authority(SysTime now)
    {
        bool providing = sta_providing_channel();
        if (_sta_was_providing && !providing)
            _sta_offline_since = now;
        _sta_was_providing = providing;
    }

    // Decide which channel hostapd should be on right now.
    //   no STA bound:                       configured `channel`.
    //   STA associated:                     STA's active_channel.
    //   STA bound, recently disassociated:  hold the last known channel
    //                                       through the grace window so
    //                                       quick reassociation doesn't
    //                                       interrupt connected AP clients.
    //   STA bound, long-disassociated:      configured `channel`.
    ubyte target_channel() const
    {
        if (bound_sta is null)
            return channel;
        if (sta_providing_channel())
            return active_channel != 0 ? active_channel : channel;
        if (active_channel != 0 && getSysTime() - _sta_offline_since < channel_revert_grace)
            return active_channel;
        return channel;
    }

    // wpa_supplicant + hostapd ctrl_iface sockets, one per radio (= per
    // netdev). Bound LinuxWlan / LinuxAP borrow these via cast access since
    // they're in the same module. Matches the WindowsWifiRadio pattern (_wlan
    // handle on the radio), and gives future radio-level uses (scan, channel
    // queries) somewhere obvious to live.
    CtrlIface _wpa;
    CtrlIface _hostapd;
    bool _wpa_open_failure_logged;
    bool _hostapd_open_failure_logged;

    // Open whichever ctrl sockets aren't already open. Failures log once per
    // failure cycle (transition into the failed state) and once on recovery,
    // since startup() / refresh_state() retry every tick or every second.
    void try_open_daemons()
    {
        if (!_wpa.valid)
        {
            auto r = wpa_open(_wpa, _adapter[]);
            if (r.failed)
            {
                if (!_wpa_open_failure_logged)
                {
                    log.warning("wpa_supplicant: ", r.message);
                    _wpa_open_failure_logged = true;
                }
            }
            else
            {
                if (_wpa_open_failure_logged)
                    log.info("wpa_supplicant: ctrl socket connected");
                _wpa_open_failure_logged = false;
            }
        }

        if (!_hostapd.valid)
        {
            auto r = hostapd_open(_hostapd, _adapter[]);
            if (r.failed)
            {
                if (!_hostapd_open_failure_logged)
                {
                    log.warning("hostapd: ", r.message);
                    _hostapd_open_failure_logged = true;
                }
            }
            else
            {
                if (_hostapd_open_failure_logged)
                    log.info("hostapd: ctrl socket connected");
                _hostapd_open_failure_logged = false;
            }
        }
    }

    void refresh_state()
    {
        // Channel query is an nl80211 job (NL80211_CMD_GET_INTERFACE,
        // NL80211_ATTR_WIPHY_FREQ -> channel mapping); not wired yet.
        // We still pull MAC/MTU/carrier/speed from sysfs -- carrier-up on a
        // wlan netdev means associated, which is the proxy for "STA online"
        // until nl80211 lands.

        // Retry ctrl_iface connections -- daemons may have launched after us.
        try_open_daemons();

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

    void sync_hostapd_config()
    {
        if (!_hostapd.valid)
            return;

        if (bound_aps.length == 0)
        {
            auto r = hostapd_disable(_hostapd);
            if (r.failed)
                log.warning("hostapd disable: ", r.message);
            _last_synced_channel = 0;
            return;
        }

        // Cap is hostapd's typical compile-time MAX_BSS_PER_RADIO; keeping it
        // local to v1 avoids a heap allocation. Bump alongside hostapd if a
        // deployment ever needs more.
        enum max_bsses = 8;
        if (bound_aps.length > max_bsses)
        {
            log.error("too many APs bound (", bound_aps.length, ", max ", max_bsses, ")");
            return;
        }

        BssConfig[max_bsses] bss_storage;
        foreach (i, base; bound_aps)
        {
            auto ap = cast(LinuxAP)base;
            if (!ap)
                return;
            ap.fill_bss_config(bss_storage[i], this);
        }

        ApConfig cfg;
        cfg.country = country;
        cfg.channel = target_channel();
        cfg.bsses = bss_storage[0 .. bound_aps.length];

        auto rw = write_hostapd_config(cfg);
        if (rw.failed)
        {
            log.error("hostapd config: ", rw.message);
            return;
        }

        // ENABLE is idempotent if already enabled; RELOAD picks up the new
        // config-on-disk for any subsequent change. hostapd creates / destroys
        // bss= VIFs as part of RELOAD via its nl80211 driver.
        auto re = hostapd_enable(_hostapd);
        if (re.failed)
            log.warning("hostapd enable: ", re.message);
        auto rr = hostapd_reload(_hostapd);
        if (rr.failed)
            log.warning("hostapd reload: ", rr.message);
        _last_synced_channel = cfg.channel;
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

    // Active state -- what wpa_supplicant says we're associated to right now.
    // The configured SSID set via the ssid= property lives in the base under
    // a different name; we kick off the connect flow with it on startup.

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
        auto r = cast(const(LinuxWifiRadio))radio;
        if (!r)
            return "no radio configured";
        if (ssid.empty)
            return "SSID not set";
        if (!r.running)
            return "Waiting for radio";
        if (auto reason = r.would_accept(this))
            return reason;
        if (!r._wpa.valid)
            return "wpa_supplicant unavailable";
        if (_wpa_state != WpaState.completed)
            return wpa_state_message(_wpa_state);
        return super.status_message();
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
        if (!_raw.valid)
        {
            auto rr = _raw.open(r.adapter);
            if (rr.failed)
            {
                log.error(rr.message);
                return CompletionStatus.error;
            }
        }

        // wpa_supplicant lives on the radio (open in radio.startup, retried
        // in radio.refresh_state). If it's available and we have a configured
        // SSID, kick off association.
        if (r._wpa.valid && super.ssid.length > 0)
            connect_to_configured_network(r._wpa);

        refresh_wpa_state();

        // Without wpa_supplicant we have no association signal, so fall back
        // to the kernel's carrier flag as the proxy for "ready to pass traffic".
        if (!r._wpa.valid)
        {
            OSAdapterInfo info;
            if (query_adapter(r.adapter, info) && info.connection != ConnectionStatus.connected)
                return CompletionStatus.continue_;
        }
        else if (_wpa_state != WpaState.completed)
            return CompletionStatus.continue_;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // _wpa belongs to the radio -- don't close it here.
        _raw.close();
        clear_wpa_state();
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
            if (r._wpa.valid)
            {
                refresh_wpa_state();
                if (_wpa_state != WpaState.completed)
                {
                    restart();
                    return;
                }
            }
            else
            {
                OSAdapterInfo info;
                if (query_adapter(r.adapter, info) && info.connection != ConnectionStatus.connected)
                {
                    restart();
                    return;
                }
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

    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

private:
    RawAdapter _raw;
    SysTime _last_refresh;

    String _current_ssid;
    MACAddress _current_bssid;
    int _current_rssi;
    ubyte _signal_quality;
    WpaState _wpa_state = WpaState.unknown;
    bool _wpa_status_failure_logged;

    void clear_wpa_state()
    {
        _current_ssid = String.init;
        _current_bssid = MACAddress();
        _current_rssi = 0;
        _signal_quality = 0;
        _wpa_state = WpaState.unknown;
    }

    void refresh_wpa_state()
    {
        auto r = cast(LinuxWifiRadio)radio;
        if (!r || !r._wpa.valid)
        {
            clear_wpa_state();
            return;
        }

        char[2048] buf = void;
        size_t n;
        auto rs = r._wpa.send_command("STATUS", buf[], n);
        if (rs.failed)
        {
            if (!_wpa_status_failure_logged)
            {
                log.warning("wpa STATUS: ", rs.message);
                _wpa_status_failure_logged = true;
            }
            clear_wpa_state();
            mark_set!(typeof(this), [ "ssid", "bssid", "rssi", "signal-quality", "status" ])();
            return;
        }
        _wpa_status_failure_logged = false;

        WpaState new_state;
        const(char)[] new_ssid_view;
        bool got_ssid;
        MACAddress new_bssid;
        bool got_bssid;
        ubyte new_channel;

        foreach_kv(buf[0 .. n], (key, value) nothrow @nogc {
            if (key == "wpa_state")
                new_state = parse_wpa_state(value);
            else if (key == "ssid")
            {
                new_ssid_view = value;
                got_ssid = true;
            }
            else if (key == "bssid")
            {
                MACAddress mac;
                if (mac.fromString(value) == MACAddress.StringLen)
                {
                    new_bssid = mac;
                    got_bssid = true;
                }
            }
            else if (key == "freq")
            {
                size_t consumed;
                long freq_mhz = parse_int(value, &consumed);
                if (consumed == value.length && consumed > 0 && freq_mhz > 0)
                    new_channel = freq_to_channel(cast(uint)freq_mhz);
            }
        });

        // The STA dictates the radio's channel while associated; push it up
        // so the radio can fan it out to bound APs.
        if (new_state == WpaState.completed && new_channel != 0)
            r.update_active_channel(new_channel);

        _wpa_state = new_state;
        if (got_ssid)
        {
            if (_current_ssid[] != new_ssid_view)
                _current_ssid = new_ssid_view.makeString(defaultAllocator);
        }
        else
        {
            _current_ssid = String.init;
        }
        _current_bssid = got_bssid ? new_bssid : MACAddress();

        if (new_state == WpaState.completed && r._wpa.send_command("SIGNAL_POLL", buf[], n).succeeded)
        {
            int rssi_dbm;
            bool got_rssi;
            foreach_kv(buf[0 .. n], (key, value) nothrow @nogc {
                if (key == "RSSI")
                {
                    size_t consumed;
                    long v = parse_int(value, &consumed);
                    if (consumed == value.length && consumed > 0)
                    {
                        rssi_dbm = cast(int)v;
                        got_rssi = true;
                    }
                }
            });
            if (got_rssi)
            {
                _current_rssi = rssi_dbm;
                _signal_quality = rssi_to_quality(rssi_dbm);
            }
        }
        else
        {
            _current_rssi = 0;
            _signal_quality = 0;
        }

        mark_set!(typeof(this), [ "ssid", "bssid", "rssi", "signal-quality", "status" ])();
    }

    void connect_to_configured_network(ref CtrlIface wpa)
    {
        char[256] resp = void;
        size_t n;

        // Wipe any stale config from a previous run/restart so we don't
        // accumulate duplicate networks across reconnect cycles.
        wpa.send_command("REMOVE_NETWORK all", resp[], n);

        auto ra = wpa.send_command("ADD_NETWORK", resp[], n);
        if (ra.failed || n == 0)
        {
            log.error("wpa ADD_NETWORK: ", ra.failed ? ra.message : "empty response");
            return;
        }
        size_t end = 0;
        while (end < n && resp[end] >= '0' && resp[end] <= '9')
            ++end;
        const(char)[] id = resp[0 .. end];
        if (id.length == 0)
        {
            log.error("wpa ADD_NETWORK: returned no id");
            return;
        }

        char[512] cmd = void;
        size_t l;

        l = format_set_network(cmd[], id, "ssid", super.ssid, true);
        if (l == 0 || wpa.send_command(cmd[0 .. l], resp[], n).failed)
            return;

        const(char)[] pwd = get_password();
        if (pwd.length > 0)
        {
            l = format_set_network(cmd[], id, "psk", pwd, true);
            if (l == 0 || wpa.send_command(cmd[0 .. l], resp[], n).failed)
                return;
        }
        else
        {
            l = format_set_network(cmd[], id, "key_mgmt", "NONE", false);
            if (l == 0 || wpa.send_command(cmd[0 .. l], resp[], n).failed)
                return;
        }

        l = format_select_network(cmd[], id);
        if (l > 0)
            wpa.send_command(cmd[0 .. l], resp[], n);
    }
}


// ---------------------------------------------------------------------------
// APInterface, multi-BSS aware.
//
// Each LinuxAP binds its packet path (RawAdapter) to its own netdev:
//   bound_aps[0] (primary) -> radio's netdev (e.g. wlan0)
//   bound_aps[N>0]         -> "<adapter>-<ap_name>" VIF created by hostapd
//                             when it parses our bss= section on RELOAD.
// VIFs for non-primary APs may not exist at startup() time -- we return
// continue_ and retry on each update() until the kernel surfaces them.
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

    // Build the per-BSS slice of the radio's hostapd config. Called from
    // sync_hostapd_config() once per bound AP.
    void fill_bss_config(ref BssConfig bss, const(LinuxWifiRadio) r) const
    {
        bss.iface = r.vif_for(this);
        bss.ssid = ssid;
        bss.passphrase = get_password();
        bss.auth = auth;
        bss.hidden = hidden;
        bss.client_isolation = client_isolation;
        bss.max_clients = max_clients;
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
        if (!_hostapd.valid)
            return "hostapd unavailable";
        if (auto m = hostapd_state_message(_hostapd_state))
            return m;
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto vif = current_vif();
        if (vif.length == 0)
            return CompletionStatus.continue_;

        // For non-primary APs the VIF is created by hostapd on RELOAD; if it
        // isn't there yet, retry on the next tick.
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
        }

        // Per-BSS hostapd ctrl socket; best-effort.
        try_open_hostapd(vif);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        _hostapd.close();
        _raw.close();
        return super.shutdown();
    }

    override void update()
    {
        super.update();

        auto r = cast(LinuxWifiRadio)radio;
        if (!r)
            return;

        // Retry resources we couldn't grab at startup.
        if (!_raw.valid || !_hostapd.valid)
        {
            auto vif = current_vif();
            if (vif.length > 0)
            {
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
                    }
                    else
                        _raw_open_failure_logged = false;
                }
                try_open_hostapd(vif);
            }
        }

        SysTime now = getSysTime();
        if (now - _last_refresh >= 1.seconds)
        {
            _last_refresh = now;
            refresh_ap_state();
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

    override int wire_send(const(ubyte)[] frame)
        => _raw.send(frame) ? 0 : -1;

private:

    RawAdapter _raw;
    CtrlIface _hostapd;
    HostapdHwState _hostapd_state;
    SysTime _last_refresh;
    bool _raw_open_failure_logged;
    bool _hostapd_open_failure_logged;
    bool _hostapd_status_failure_logged;

    // Returns empty slice if the radio isn't a LinuxWifiRadio or we aren't
    // bound (transitional states; caller should retry).
    const(char)[] current_vif() const
    {
        auto r = cast(const(LinuxWifiRadio))radio;
        return r ? r.vif_for(this) : null;
    }

    void try_open_hostapd(const(char)[] vif)
    {
        if (_hostapd.valid)
            return;
        auto r = hostapd_open(_hostapd, vif);
        if (r.failed)
        {
            if (!_hostapd_open_failure_logged)
            {
                log.warning("hostapd: ", r.message);
                _hostapd_open_failure_logged = true;
            }
        }
        else
        {
            if (_hostapd_open_failure_logged)
                log.info("hostapd: ctrl socket connected");
            _hostapd_open_failure_logged = false;
        }
    }

    void refresh_ap_state()
    {
        if (!_hostapd.valid)
        {
            _hostapd_state = HostapdHwState.unknown;
            return;
        }

        char[2048] buf = void;
        HostapdStatus s;
        auto rs = hostapd_query_status(_hostapd, s, buf[]);
        if (rs.failed)
        {
            if (!_hostapd_status_failure_logged)
            {
                log.warning("hostapd STATUS: ", rs.message);
                _hostapd_status_failure_logged = true;
            }
            _hostapd_state = HostapdHwState.unknown;
            return;
        }
        _hostapd_status_failure_logged = false;

        _hostapd_state = s.hw_state;

        // All BSSes on a radio share the chip's channel; any one of them
        // reporting it is enough to drive active_channel.
        auto r = cast(LinuxWifiRadio)radio;
        if (r && s.channel != 0)
            r.update_active_channel(s.channel);
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


private size_t format_set_network(char[] dst, const(char)[] id, const(char)[] key, const(char)[] value, bool quoted)
{
    enum prefix = "SET_NETWORK ";
    size_t total = prefix.length + id.length + 1 + key.length + 1 + (quoted ? 2 : 0) + value.length;
    if (total > dst.length)
        return 0;
    size_t i = 0;
    dst[i .. i + prefix.length] = prefix;     i += prefix.length;
    dst[i .. i + id.length]     = id;         i += id.length;
    dst[i++] = ' ';
    dst[i .. i + key.length]    = key;        i += key.length;
    dst[i++] = ' ';
    if (quoted) dst[i++] = '"';
    dst[i .. i + value.length]  = value;      i += value.length;
    if (quoted) dst[i++] = '"';
    return i;
}

private size_t format_select_network(char[] dst, const(char)[] id)
{
    enum prefix = "SELECT_NETWORK ";
    if (prefix.length + id.length > dst.length)
        return 0;
    size_t i = 0;
    dst[i .. i + prefix.length] = prefix;  i += prefix.length;
    dst[i .. i + id.length]     = id;      i += id.length;
    return i;
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
        sync_radios();
    }

    override void init()
    {
        g_app.console.register_collection!LinuxWifiRadio();
        g_app.console.register_collection!LinuxWlan();
        g_app.console.register_collection!LinuxAP();
    }

private:

    void on_link_changed(uint, const(char)[], bool, bool)
    {
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
