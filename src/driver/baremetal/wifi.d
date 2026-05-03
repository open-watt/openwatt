module driver.baremetal.wifi;

import urt.driver.wifi;

static if (num_wifi > 0) {

import urt.endian : loadBigEndian;
import urt.result : Result;
import urt.thread : SPSCRing;
import urt.time : SysTime, getSysTime;

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


// ---------------------------------------------------------------------------
// Embedded radio backed by the urt.driver.wifi peripheral interface.
// One BuiltinWiFi per compile-time radio port.
// ---------------------------------------------------------------------------
class BuiltinWiFi : WiFiInterface
{
nothrow @nogc:

    enum type_name = "wifi";
    enum path = "/interface/wifi";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinWiFi, id, flags);
    }

    // Subclass-only API used by BuiltinWlan / BuiltinAp
    final Result drv_transmit(WifiVif vif, const(ubyte)[] data)
    {
        return wifi_tx(_wifi, vif, data);
    }

    final Result drv_get_mac(WifiVif vif, ref ubyte[6] mac)
    {
        return wifi_get_mac(_wifi, vif, mac);
    }

    // Event flags, set from driver callback, polled from update
    bool evt_sta_connected;
    bool evt_sta_disconnected;
    bool evt_ap_started;
    bool evt_ap_stopped;

    final ref Wifi wifi() pure { return _wifi; }

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
        // ESP32 supports one STA + one AP per radio
        if (_num_ap > 1 || _num_client > 1)
            return false;
        return super.validate();
    }

    override const(char)[] status_message() const
    {
        if (_num_ap > 1)
            return "only one AP per radio";
        if (_num_client > 1)
            return "only one STA per radio";
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        WifiConfig cfg;
        cfg.tx_power = tx_power;
        cfg.channel = super.channel;

        auto r = wifi_open(_wifi, 0, cfg);
        if (!r)
        {
            log.error("WiFi radio init failed");
            return CompletionStatus.error;
        }

        wifi_set_event_callback(_wifi, &wifi_event_dispatch);
        wifi_set_rx_callback(_wifi, &wifi_rx_dispatch);

        _active_radios[0] = this;
        update_drv_mode();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_wifi.is_open)
        {
            wifi_set_rx_callback(_wifi, null);
            wifi_set_event_callback(_wifi, null);
            _active_radios[_wifi.port] = null;
            wifi_close(_wifi);
        }
        evt_sta_connected = false;
        evt_sta_disconnected = false;
        evt_ap_started = false;
        evt_ap_stopped = false;
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

        drain_rx();
    }

    override void on_wlan_bind_changed()
    {
        if (_wifi.is_open)
            update_drv_mode();
    }

private:
    Wifi _wifi;
    ubyte _num_ap;
    ubyte _num_client;

    void update_drv_mode()
    {
        WifiMode m = WifiMode.none;
        if (_num_client > 0 && _num_ap > 0)
            m = WifiMode.apsta;
        else if (_num_client > 0)
            m = WifiMode.sta;
        else if (_num_ap > 0)
            m = WifiMode.ap;
        wifi_set_mode(_wifi, m);
    }

    // Module-level dispatch targets (function pointers, not delegates)
    __gshared BuiltinWiFi[num_wifi] _active_radios;

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
        if (data.length < 14 || data.length > RxFrameMax)
            return;

        auto slot = radio._rx_queue.reserve();
        if (slot is null)
            return;
        slot.timestamp = getSysTime();
        slot.vif = vif;
        slot.length = cast(ushort)data.length;
        slot.data[0 .. data.length] = data[];
        radio._rx_queue.commit();
    }

    void drain_rx()
    {
        while (true)
        {
            auto slot = _rx_queue.peek();
            if (slot is null)
                return;
            WLANBaseInterface target = slot.vif == WifiVif.ap ? bound_ap : bound_sta;
            if (target !is null && target.running)
                target.on_radio_rx(slot.data[0 .. slot.length], slot.timestamp);
            _rx_queue.pop(1);
        }
    }

    enum size_t RxFrameMax = 1518;
    struct RxSlot
    {
        SysTime timestamp;
        WifiVif vif;
        ushort length;
        ubyte[RxFrameMax] data;
    }
    SPSCRing!(RxSlot, 8) _rx_queue;

    final void on_wifi_event(WifiEvent event, const(void)* data = null)
    {
        final switch (event)
        {
            case WifiEvent.sta_connected:       evt_sta_connected = true; break;
            case WifiEvent.sta_disconnected:    evt_sta_disconnected = true; break;
            case WifiEvent.ap_started:          evt_ap_started = true; break;
            case WifiEvent.ap_stopped:          evt_ap_stopped = true; break;
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


// ---------------------------------------------------------------------------
// Embedded station -- joins networks via wifi_sta_connect
// ---------------------------------------------------------------------------
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
        return super.status_message();
    }

protected:

    override void update()
    {
        super.update();

        auto radio = cast(BuiltinWiFi)this.radio;
        if (radio && radio.evt_sta_disconnected)
        {
            radio.evt_sta_disconnected = false;
            _status_detail = "Disconnected";
            log.warning("disconnected from '", ssid, "'");
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
            if (radio.evt_sta_connected)
            {
                radio.evt_sta_connected = false;
                _status_detail = null;
                return CompletionStatus.complete;
            }
            if (radio.evt_sta_disconnected)
            {
                radio.evt_sta_disconnected = false;
                _status_detail = "Association failed";
                log.warning("failed to connect to '", ssid, "'");
                _connect_initiated = false;
                return CompletionStatus.error;
            }
            return CompletionStatus.continue_;
        }

        WifiStaConfig sta_cfg;
        sta_cfg.ssid = ssid;
        sta_cfg.password = get_password();
        if (bssid_filter != MACAddress.init)
            sta_cfg.bssid = bssid_filter.b;

        if (!wifi_sta_configure(radio.wifi, sta_cfg))
        {
            _status_detail = "STA config rejected by driver";
            log.error("STA config rejected by driver");
            return CompletionStatus.error;
        }

        ubyte[6] mac_buf = void;
        if (radio.drv_get_mac(WifiVif.sta, mac_buf))
        {
            remove_address(mac);
            mac = MACAddress(mac_buf);
            add_address(mac, this);
        }

        radio.evt_sta_connected = false;
        radio.evt_sta_disconnected = false;

        if (!wifi_sta_connect(radio.wifi))
        {
            _status_detail = "Connect request rejected by driver";
            log.error("STA connect rejected by driver");
            return CompletionStatus.error;
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
}


// ---------------------------------------------------------------------------
// Embedded access point -- broadcasts SSID via wifi_ap_configure
// ---------------------------------------------------------------------------
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
        return super.status_message();
    }

protected:

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        auto radio = cast(BuiltinWiFi)this.radio;
        if (!radio)
            return CompletionStatus.error;

        if (_ap_config_sent)
        {
            if (radio.evt_ap_started)
            {
                radio.evt_ap_started = false;
                _status_detail = null;
                return CompletionStatus.complete;
            }
            if (radio.evt_ap_stopped)
            {
                radio.evt_ap_stopped = false;
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
        ap_cfg.channel = radio.channel;
        ap_cfg.max_clients = max_clients;
        ap_cfg.hidden = hidden;

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

        radio.evt_ap_started = false;
        radio.evt_ap_stopped = false;
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
}


// ---------------------------------------------------------------------------
// Driver module: registers the embedded subclasses and pre-creates the
// compile-time radio array.
// ---------------------------------------------------------------------------
class BuiltinWifiModule : Module
{
    mixin DeclareModule!"interface.wifi.builtin";
nothrow @nogc:

    override void pre_init()
    {
        import urt.mem.temp : tconcat;
        foreach (i; 0 .. num_wifi)
            Collection!BuiltinWiFi().create(tconcat("wifi", i + 1));
    }

    override void init()
    {
        g_app.console.register_collection!BuiltinWiFi();
        g_app.console.register_collection!BuiltinWlan();
        g_app.console.register_collection!BuiltinAp();
    }
}

} // static if (num_wifi > 0)
