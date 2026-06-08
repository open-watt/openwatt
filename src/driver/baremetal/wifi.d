module driver.baremetal.wifi;

import urt.driver.wifi;

static if (num_wifi > 0) {

import urt.atomic;
import urt.endian;
import urt.result;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;
import router.iface.wifi;

nothrow @nogc:

class BuiltinWiFi : WiFiInterface
{
nothrow @nogc:

    enum type_name = "wifi";
    enum path = "/interface/wifi";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinWiFi, id, flags);
    }

    final Result drv_transmit(WifiVif vif, const(ubyte)[] data)
    {
        return wifi_tx(_wifi, vif, data);
    }

    final Result drv_get_mac(WifiVif vif, ref ubyte[6] mac)
    {
        return wifi_get_mac(_wifi, vif, mac);
    }

    uint sta_connected_seq;
    uint sta_disconnected_seq;
    uint ap_started_seq;
    uint ap_stopped_seq;

    final ref Wifi wifi() pure { return _wifi; }

    final const(char)[] would_accept(const(WLANBaseInterface) candidate) const pure
    {
        bool candidate_is_ap = cast(const(APInterface))candidate !is null;
        bool candidate_is_sta = !candidate_is_ap && cast(const(WLANInterface))candidate !is null;

        size_t ap_count = _num_ap;
        size_t sta_count = _num_client;
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

        if (!already_bound)
        {
            if (candidate_is_ap)
                ++ap_count;
            else if (candidate_is_sta)
                ++sta_count;
        }

        if (ap_count > 1)
            return "only one AP per radio";
        if (sta_count > 1)
            return "only one STA per radio";
        if (sta_count > 0 && ap_count > 0)
            return "concurrent AP+STA is not supported by this BL808 WiFi firmware";
        return null;
    }

    override void bind_wlan(WLANBaseInterface wlan, bool remove)
    {
        bool is_ap = cast(APInterface)wlan !is null;
        if (is_ap)
            _num_ap = cast(ubyte)(_num_ap + (remove ? -1 : 1));
        else
            _num_client = cast(ubyte)(_num_client + (remove ? -1 : 1));
        super.bind_wlan(wlan, remove);
    }

protected:
    override bool validate() const
    {
        // The BL808 blob accepts one virtual interface at a time. It exposes
        // two host-side VIF slots, but MM_ADD_IF_CFM returns CO_FAIL for the
        // second VIF in both STA-first and AP-first order.
        if (_num_ap > 1 || _num_client > 1)
            return false;
        if (_num_ap > 0 && _num_client > 0)
            return false;
        return super.validate();
    }

    override const(char)[] status_message() const
    {
        if (_num_ap > 1)
            return "only one AP per radio";
        if (_num_client > 1)
            return "only one STA per radio";
        if (_num_ap > 0 && _num_client > 0)
            return "concurrent AP+STA is not supported by this BL808 WiFi firmware";
        return super.status_message();
    }

    bool has_sta_bound() const pure nothrow
    {
        return _num_client > 0;
    }

    bool mode_update_pending() const pure nothrow
    {
        return _mode_update_pending;
    }

    override CompletionStatus startup()
    {
        WifiConfig cfg;
        cfg.tx_power = tx_power;
        cfg.channel = super.channel;

        if (!wifi_open(_wifi, 0, cfg))
        {
            log.error("WiFi radio init failed");
            return CompletionStatus.error;
        }

        wifi_set_event_callback(_wifi, &wifi_event_dispatch);
        wifi_set_rx_callback(_wifi, &wifi_rx_dispatch);
        _active_radios[0] = this;
        wifi_set_wake_callback(&wifi_wake_dispatch);

        if (!update_drv_mode())
        {
            log.error("WiFi set mode failed");
            teardown_radio();
            return CompletionStatus.error;
        }

        if (monitor)
        {
            wifi_set_raw_rx_callback(_wifi, &wifi_raw_rx_dispatch);
            if (super.channel != 0 && _num_client == 0 && _num_ap == 0)
                apply_channel(super.channel);
        }
        return CompletionStatus.complete;
    }

    void apply_channel(ubyte ch)
    {
        if (!_wifi.is_open || ch == 0)
            return;
        if (wifi_set_channel(_wifi, ch).failed)
            log.warning("WiFi set channel ", ch, " failed");
    }

    override CompletionStatus shutdown()
    {
        teardown_radio();
        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        if (_wifi.is_open)
        {
            wifi_poll(_wifi);
            ubyte hw_ch = wifi_get_channel(_wifi);
            if (hw_ch != 0)
                set_active_channel(hw_ch);
        }

        flush_pending_mode_update();
    }

    override void on_wlan_bind_changed()
    {
        if (!running)
            return;
        _mode_update_pending = true;
    }

    override void on_tx_power_changed()
    {
        if (_wifi.is_open)
            wifi_set_tx_power(_wifi, tx_power);
    }

    override void on_monitor_changed(bool enabled)
    {
        if (!_wifi.is_open)
            return;
        wifi_set_raw_rx_callback(_wifi, enabled ? &wifi_raw_rx_dispatch : null);
        if (_num_client == 0 && _num_ap == 0)
            update_drv_mode();
        if (enabled && super.channel != 0 && _num_client == 0 && _num_ap == 0)
            apply_channel(super.channel);
    }

    override void on_channel_changed(ubyte ch)
    {
        if (!_wifi.is_open)
            return;
        if (_num_client > 0)
            return;
        if (_num_ap > 0)
        {
            restart();
            return;
        }
        apply_channel(ch);
    }

    override int transmit(ref const Packet packet, MessageCallback callback)
    {
        if (packet.type != PacketType.wifi_80211 || !_wifi.is_open)
        {
            add_tx_drop();
            return -1;
        }
        if (wifi_raw_tx(_wifi, cast(const(ubyte)[])packet.data).failed)
        {
            add_tx_drop();
            return -1;
        }
        add_tx_frame(packet.length);
        return 0;
    }

private:
    Wifi _wifi;
    ubyte _num_ap;
    ubyte _num_client;
    bool _mode_update_pending;
    bool _mode_update_warned;

    __gshared BuiltinWiFi[num_wifi] _active_radios;
    shared uint _wifi_pump_pending;

    Result update_drv_mode()
    {
        WifiMode m = WifiMode.none;
        if (_num_client > 0 && _num_ap > 0)
            m = WifiMode.apsta;
        else if (_num_client > 0)
            m = WifiMode.sta;
        else if (_num_ap > 0)
            m = WifiMode.ap;
        else if (monitor)
            m = WifiMode.monitor;  // radio on (as STA in the driver), no virtual ifs
        return wifi_set_mode(_wifi, m);
    }

    void flush_pending_mode_update()
    {
        if (!_mode_update_pending || !_wifi.is_open)
            return;
        if (!update_drv_mode())
        {
            if (!_mode_update_warned)
            {
                _mode_update_warned = true;
                log.warning("WiFi mode change deferred");
            }
            return;
        }
        _mode_update_pending = false;
        _mode_update_warned = false;
    }

    void teardown_radio()
    {
        if (_wifi.is_open)
        {
            wifi_set_rx_callback(_wifi, null);
            wifi_set_event_callback(_wifi, null);
            wifi_set_wake_callback(null);
            _active_radios[_wifi.port] = null;
            wifi_close(_wifi);
        }
        atomicStore!(MemoryOrder.release)(_wifi_pump_pending, 0u);
        _mode_update_pending = false;
        _mode_update_warned = false;
    }

    static void wifi_wake_dispatch() nothrow @nogc
    {
        if (auto radio = _active_radios[0])
            radio.request_wifi_pump();
    }

    void request_wifi_pump()
    {
        if (!_wifi.is_open || g_app is null)
            return;
        if (!cas(&_wifi_pump_pending, 0u, 1u))
            return;
        if (!g_app.post_event(&wifi_pump_event, getTime(), EventPriority.control))
            atomicStore!(MemoryOrder.release)(_wifi_pump_pending, 0u);
    }

    void wifi_pump_event(MonoTime when)
    {
        atomicStore!(MemoryOrder.release)(_wifi_pump_pending, 0u);
        if (_wifi.is_open)
        {
            wifi_poll(_wifi);
            ubyte hw_ch = wifi_get_channel(_wifi);
            if (hw_ch != 0)
                set_active_channel(hw_ch);
        }
    }

    static void wifi_event_dispatch(Wifi wifi, WifiEvent event, const(void)* data) nothrow @nogc
    {
        if (wifi.port < num_wifi)
            if (auto radio = _active_radios[wifi.port])
                radio.on_wifi_event(event, data);
    }

    static void wifi_rx_dispatch(Wifi wifi, WifiVif vif, const(ubyte)[] data) nothrow @nogc
    {
        if (wifi.port >= num_wifi)
            return;
        auto radio = _active_radios[wifi.port];
        if (radio is null)
            return;
        radio.dispatch_rx(vif, data);
    }

    static void wifi_raw_rx_dispatch(Wifi wifi, const(ubyte)[] frame, byte rssi, ubyte channel) nothrow @nogc
    {
        if (wifi.port >= num_wifi)
            return;
        auto radio = _active_radios[wifi.port];
        if (radio is null || !radio.running)
            return;
        if (frame.length < 10)
        {
            radio.add_rx_drop();
            return;
        }

        Packet pkt;
        auto hdr = &pkt.init!Wifi80211(frame);
        // 802.11 is little-endian on the wire (unlike most network protocols).
        hdr.frame_control = littleEndianToNative!ushort(frame[0 .. 2][0 .. 2]);
        // addr1 is always present at offset 4. addr2/3/seq_ctrl only exist on
        // mgmt/data frames (>= 24 bytes). For shorter control frames (ACK/CTS
        // = 10 bytes, RTS = 16 bytes) leave the trailing fields zero.
        hdr.addr1 = MACAddress(frame[4 .. 10]);
        if (frame.length >= 16)
            hdr.addr2 = MACAddress(frame[10 .. 16]);
        if (frame.length >= 24)
        {
            hdr.addr3 = MACAddress(frame[16 .. 22]);
            hdr.seq_ctrl = littleEndianToNative!ushort(frame[22 .. 24][0 .. 2]);
        }
        hdr.rssi = rssi;
        hdr.channel = channel;
        radio.dispatch(pkt);
    }

    void dispatch_rx(WifiVif vif, const(ubyte)[] data)
    {
        if (data.length < 14 || data.length > 1518)
            return;
        WLANBaseInterface target = vif == WifiVif.ap ? bound_ap : bound_sta;
        if (target !is null && target.running)
            target.on_radio_rx(data, getSysTime());
    }

    final void on_wifi_event(WifiEvent event, const(void)* data = null)
    {
        final switch (event)
        {
            case WifiEvent.sta_connected:       ++sta_connected_seq; break;
            case WifiEvent.sta_disconnected:    ++sta_disconnected_seq; break;
            case WifiEvent.ap_started:          ++ap_started_seq; break;
            case WifiEvent.ap_stopped:          ++ap_stopped_seq; break;
            case WifiEvent.ap_sta_connected:
                if (data !is null)
                    log.info("STA ", MACAddress((cast(ubyte*)data)[0 .. 6]), " joined AP");
                else
                    log.info("STA joined AP");
                break;
            case WifiEvent.ap_sta_disconnected:
                if (data !is null)
                    log.info("STA ", MACAddress((cast(ubyte*)data)[0 .. 6]), " left AP");
                else
                    log.info("STA left AP");
                break;
            case WifiEvent.scan_done:           break;
        }
    }

}


class BuiltinWlan : WLANInterface
{
nothrow @nogc:

    enum type_name = "wlan";
    enum path = "/interface/wlan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinWlan, id, flags);
    }

    // Properties

    override const(char)[] status_message() const pure
    {
        if (_status_detail.length > 0)
            return _status_detail;
        auto r = cast(const(BuiltinWiFi))radio;
        if (!r)
            return "no radio configured";
        if (auto reason = r.would_accept(this))
            return reason;
        return super.status_message();
    }

protected:
    override bool validate() const
    {
        if (!super.validate())
            return false;
        auto r = cast(const(BuiltinWiFi))radio;
        if (!r)
            return false;
        return r.would_accept(this) is null;
    }

    override void update()
    {
        super.update();

        auto radio = cast(BuiltinWiFi)this.radio;
        if (radio && radio.sta_disconnected_seq != _last_sta_disconnected_seq)
        {
            _last_sta_disconnected_seq = radio.sta_disconnected_seq;
            auto detail = wifi_sta_status_message(radio.wifi);
            _status_detail = detail.length != 0 ? detail : "Disconnected";
            _next_connect_time = getTime() + 2.seconds;
            log.warning("disconnected from '", ssid, "': ", _status_detail);
            restart();
        }
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto radio = cast(BuiltinWiFi)this.radio;
        if (!radio)
            return CompletionStatus.error;

        if (_connect_initiated)
        {
            if (radio.sta_connected_seq != _connect_sta_connected_seq)
            {
                _last_sta_disconnected_seq = radio.sta_disconnected_seq;
                _status_detail = null;
                return CompletionStatus.complete;
            }
            if (radio.sta_disconnected_seq != _connect_sta_disconnected_seq)
            {
                _last_sta_disconnected_seq = radio.sta_disconnected_seq;
                auto detail = wifi_sta_status_message(radio.wifi);
                _status_detail = detail.length != 0 ? detail : "Association failed";
                _next_connect_time = getTime() + 2.seconds;
                log.warning("failed to connect to '", ssid, "': ", _status_detail);
                _connect_initiated = false;
                return CompletionStatus.continue_;
            }
            return CompletionStatus.continue_;
        }

        auto now = getTime();
        if (_next_connect_time.ticks != 0 && now < _next_connect_time)
            return CompletionStatus.continue_;

        WifiStaConfig sta_cfg;
        sta_cfg.ssid = ssid;
        sta_cfg.password = get_password();
        if (bssid_filter != MACAddress.init)
            sta_cfg.bssid = bssid_filter.b;

        if (!wifi_sta_configure(radio.wifi, sta_cfg))
        {
            auto detail = wifi_sta_status_message(radio.wifi);
            _status_detail = detail.length != 0 ? detail : "STA config rejected by driver";
            log.error(_status_detail);
            return CompletionStatus.error;
        }

        _connect_sta_connected_seq = radio.sta_connected_seq;
        _connect_sta_disconnected_seq = radio.sta_disconnected_seq;
        _last_sta_disconnected_seq = radio.sta_disconnected_seq;

        if (!wifi_sta_connect(radio.wifi))
        {
            _status_detail = "Connect request rejected by driver";
            log.error("STA connect rejected by driver");
            return CompletionStatus.error;
        }

        ubyte[6] mac_buf = void;
        if (radio.drv_get_mac(WifiVif.sta, mac_buf))
        {
            remove_address(mac);
            mac = MACAddress(mac_buf);
            add_address(mac, this);
        }

        _connect_initiated = true;
        _status_detail = "Connecting";
        log.info("connecting to '", ssid, "'");

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        auto radio = cast(BuiltinWiFi)this.radio;
        if (_connect_initiated && radio)
            wifi_sta_disconnect(radio.wifi);
        _connect_initiated = false;
        _status_detail = null;
        return super.shutdown();
    }

protected:
    override int wire_send(const(ubyte)[] frame)
    {
        auto r = cast(BuiltinWiFi)radio;
        if (!r || !r.running || frame.length == 0)
            return -1;
        if (!r.drv_transmit(WifiVif.sta, frame))
            return -1;
        return 0;
    }

private:

    const(char)[] _status_detail;
    bool _connect_initiated;
    uint _connect_sta_connected_seq;
    uint _connect_sta_disconnected_seq;
    uint _last_sta_disconnected_seq;
    MonoTime _next_connect_time;
}


class BuiltinAp : APInterface
{
nothrow @nogc:

    enum type_name = "wifi-ap";
    enum path = "/interface/ap";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinAp, id, flags);
    }

    // Properties

    override const(char)[] status_message() const pure
    {
        if (_status_detail.length > 0)
            return _status_detail;
        if (max_clients > wifi_max_ap_clients)
            return "too many AP clients configured for this WiFi driver";
        auto r = cast(const(BuiltinWiFi))radio;
        if (!r)
            return "no radio configured";
        if (auto reason = r.would_accept(this))
            return reason;
        return super.status_message();
    }

protected:
    override void on_max_clients_changed(ubyte value)
    {
        auto r = cast(BuiltinWiFi)radio;
        if (!r || !running || !r.running)
            return;
        if (value > wifi_max_ap_clients)
            return;
        if (!wifi_ap_set_max_clients(r.wifi, value))
            log.error("AP max-clients update rejected by driver");
    }

    override bool validate() const
    {
        if (!super.validate())
            return false;
        if (max_clients > wifi_max_ap_clients)
            return false;
        auto r = cast(const(BuiltinWiFi))radio;
        if (!r)
            return false;
        return r.would_accept(this) is null;
    }

    override void update()
    {
        super.update();

        auto radio = cast(BuiltinWiFi)this.radio;
        if (!radio || radio.ap_stopped_seq == _last_ap_stopped_seq)
            return;

        _last_ap_stopped_seq = radio.ap_stopped_seq;
        _status_detail = "AP stopped";
        log.warning("AP '", ssid, "' stopped");
        restart();
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto radio = cast(BuiltinWiFi)this.radio;
        if (!radio)
            return CompletionStatus.error;

        if (radio.mode_update_pending)
        {
            _status_detail = "Waiting for AP mode";
            return CompletionStatus.continue_;
        }

        if (_ap_config_sent)
        {
            if (radio.ap_started_seq != _ap_started_seq_start)
            {
                _last_ap_stopped_seq = radio.ap_stopped_seq;
                _status_detail = null;
                return CompletionStatus.complete;
            }
            if (radio.ap_stopped_seq != _ap_stopped_seq_start)
            {
                _last_ap_stopped_seq = radio.ap_stopped_seq;
                _status_detail = "AP failed to start";
                log.warning("AP '", ssid, "' failed to start");
                _ap_config_sent = false;
                return CompletionStatus.error;
            }
            return CompletionStatus.continue_;
        }

        WifiApConfig ap_cfg;
        ap_cfg.ssid = ssid;
        ap_cfg.password = get_password();
        final switch (auth)
        {
            case router.iface.wifi.WifiAuth.open:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.open;
                break;
            case router.iface.wifi.WifiAuth.wpa2:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.wpa2_psk;
                break;
            case router.iface.wifi.WifiAuth.wpa3:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.wpa3_psk;
                break;
            case router.iface.wifi.WifiAuth.wpa2_wpa3:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.wpa2_wpa3_psk;
                break;
            case router.iface.wifi.WifiAuth.wpa2_enterprise:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.wpa2_enterprise;
                break;
            case router.iface.wifi.WifiAuth.wpa3_enterprise:
                ap_cfg.auth = urt.driver.wifi.WifiAuth.wpa3_enterprise;
                break;
        }
        ap_cfg.channel = radio.active_channel != 0 ? radio.active_channel : radio.channel;
        ap_cfg.max_clients = max_clients;
        ap_cfg.hidden = hidden;

        _ap_started_seq_start = radio.ap_started_seq;
        _ap_stopped_seq_start = radio.ap_stopped_seq;
        _last_ap_stopped_seq = radio.ap_stopped_seq;

        if (!wifi_ap_configure(radio.wifi, ap_cfg))
        {
            _status_detail = "AP config rejected by driver";
            log.error("AP config rejected by driver");
            return CompletionStatus.error;
        }

        ubyte[6] mac_buf = void;
        if (radio.drv_get_mac(WifiVif.ap, mac_buf))
        {
            remove_address(mac);
            mac = MACAddress(mac_buf);
            add_address(mac, this);
        }

        _ap_config_sent = true;
        _status_detail = "Starting AP";
        log.info("starting AP '", ssid, "'");

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _ap_config_sent = false;
        _status_detail = null;
        return super.shutdown();
    }

protected:
    override int wire_send(const(ubyte)[] frame)
    {
        auto r = cast(BuiltinWiFi)radio;
        if (!r || !r.running || frame.length == 0)
            return -1;
        if (!r.drv_transmit(WifiVif.ap, frame))
            return -1;
        return 0;
    }

private:

    const(char)[] _status_detail;
    bool _ap_config_sent;
    uint _ap_started_seq_start;
    uint _ap_stopped_seq_start;
    uint _last_ap_stopped_seq;
}


class BuiltinWifiModule : Module
{
    mixin DeclareModule!"interface.wifi.builtin";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BuiltinWiFi();
        g_app.console.register_collection!BuiltinWlan();
        g_app.console.register_collection!BuiltinAp();
    }
}

}
