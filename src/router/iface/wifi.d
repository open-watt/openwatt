module router.iface.wifi;

import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.string;
import urt.mem.temp;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;
import manager.secret;

import router.iface;
import router.iface.ethernet;

version(Windows)
{
    import manager.os.npcap;
}
else version(Espressif)
{
    import urt.endian : loadBigEndian;
    import urt.time : getSysTime;

    extern(C) nothrow @nogc
    {
        int ow_wifi_init();
        void ow_wifi_deinit();
        int ow_wifi_set_mode(int mode);
        int ow_wifi_start();
        int ow_wifi_stop();
        int ow_wifi_sta_config(const(char)* ssid, const(char)* password, const(ubyte)* bssid);
        int ow_wifi_sta_connect();
        int ow_wifi_sta_disconnect();
        int ow_wifi_ap_config(const(char)* ssid, const(char)* password, ubyte channel, ubyte max_conn, ubyte hidden);
        int ow_wifi_set_tx_power(byte power);
        int ow_wifi_get_channel(ubyte* channel);
        int ow_wifi_get_mac(int iface, ubyte* mac);
        int ow_wifi_set_rx_callback(void function(const(ubyte)*, int, int) nothrow @nogc cb);
        int ow_wifi_tx(int iface, const(ubyte)* data, int len);
        void ow_wifi_set_sta_callback(void function(int, void*, int) nothrow @nogc);
        void ow_wifi_set_ap_callback(void function(int, void*, int) nothrow @nogc);
    }

    // ESP-IDF wifi event IDs (from esp_wifi_types.h)
    enum : int
    {
        WIFI_EVENT_STA_START = 2,
        WIFI_EVENT_STA_STOP = 3,
        WIFI_EVENT_STA_CONNECTED = 4,
        WIFI_EVENT_STA_DISCONNECTED = 5,
        WIFI_EVENT_AP_START = 12,
        WIFI_EVENT_AP_STOP = 13,
        WIFI_EVENT_AP_STACONNECTED = 14,
        WIFI_EVENT_AP_STADISCONNECTED = 15,
    }

    // active interfaces for RX dispatch (ESP32 supports one STA + one AP)
    __gshared WLANInterface esp_active_sta;
    __gshared APInterface esp_active_ap;

    // event flags set from ESP event task, polled from main loop
    __gshared bool esp_sta_connected;
    __gshared bool esp_sta_disconnected;
    __gshared bool esp_ap_started;
    __gshared bool esp_ap_stopped;

    extern(C) void esp_sta_event(int event_id, void*, int) nothrow @nogc
    {
        if (event_id == WIFI_EVENT_STA_CONNECTED)
            esp_sta_connected = true;
        else if (event_id == WIFI_EVENT_STA_DISCONNECTED)
            esp_sta_disconnected = true;
    }

    extern(C) void esp_ap_event(int event_id, void*, int) nothrow @nogc
    {
        if (event_id == WIFI_EVENT_AP_START)
            esp_ap_started = true;
        else if (event_id == WIFI_EVENT_AP_STOP)
            esp_ap_stopped = true;
    }

    extern(C) void esp_wifi_rx(const(ubyte)* data, int len, int iface) nothrow @nogc
    {
        WLANBaseInterface target;
        if (iface == 0)
            target = esp_active_sta;
        else
            target = esp_active_ap;

        if (!target || !target.running || len < 14)
            return;

        Packet packet;
        ref eth = packet.init!Ethernet(data[0 .. len], getSysTime());
        auto mac_hdr = cast(const Ethernet*)data;
        eth.dst = mac_hdr.dst;
        eth.src = mac_hdr.src;
        eth.ether_type = loadBigEndian(&mac_hdr.ether_type);
        packet._offset = 14;

        target.incoming_packet(packet);
    }
}

nothrow @nogc:


enum WifiAuth : byte
{
    open,
    wpa2,
    wpa3,
    wpa2_wpa3,
    wpa2_enterprise,
    wpa3_enterprise,
}

class WiFiInterface : BaseInterface
{
    __gshared Property[5] Properties = [
        Property.create!("adapter", adapter)(),
        Property.create!("mode", mode)(),
        Property.create!("channel", channel)(),
        Property.create!("tx-power", tx_power)(),
        Property.create!("country", country)(),
    ];
nothrow @nogc:

    enum type_name = "wifi";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WiFiInterface, id, flags);
    }

    // Properties

    final const(char)[] adapter() pure
        => _adapter[];
    final void adapter(const(char)[] value)
    {
        _adapter = value.makeString(defaultAllocator);
    }

    final const(char)[] mode() const pure
    {
        if (_num_ap > 0 && _num_client > 0)
            return "apsta";
        if (_num_ap > 0)
            return "ap";
        if (_num_client > 0)
            return "sta";
        return "monitor";
    }

    final ubyte channel() const
    {
        version(Espressif)
        {
            if (running)
            {
                ubyte actual = void;
                if (ow_wifi_get_channel(&actual))
                    return actual;
            }
        }
        return _channel;
    }
    final const(char)[] channel(ubyte value)
    {
        if (value > 196)
            return "invalid channel number";
        _channel = value;
        return null;
    }

    final byte tx_power() const pure
        => _tx_power;
    final const(char)[] tx_power(byte value)
    {
        _tx_power = value;
        return null;
    }

    final const(char)[] country() const pure
        => _country[];
    final void country(const(char)[] value)
    {
        _country = value.makeString(defaultAllocator);
    }

    // API

    final void bind_wlan(WLANBaseInterface wlan, bool remove)
    {
        bool is_ap = cast(APInterface)wlan !is null;
        if (remove)
        {
            if (is_ap)
                --_num_ap;
            else
                --_num_client;
        }
        else
        {
            if (is_ap)
                ++_num_ap;
            else
                ++_num_client;
        }

        version(Espressif)
        {
            if (_num_ap > 1 || _num_client > 1)
                restart();
            else if (_esp_started)
                update_esp_mode();
        }
    }

protected:

    override bool validate() const
    {
        version(Espressif)
        {
            if (_num_ap > 1 || _num_client > 1)
                return false;
        }
        return true;
    }

    override const(char)[] status_message() const
    {
        version(Espressif)
        {
            if (_num_ap > 1)
                return "ESP32 supports only one AP per radio";
            if (_num_client > 1)
                return "ESP32 supports only one STA per radio";
        }
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        version(Espressif)
        {
            if (auto err = ow_wifi_init())
            {
                writeError("WiFi radio init failed: esp_err=", err);
                return CompletionStatus.error;
            }

            if (_tx_power > 0)
                ow_wifi_set_tx_power(_tx_power);

            ow_wifi_set_rx_callback(&esp_wifi_rx);
            ow_wifi_set_sta_callback(&esp_sta_event);
            ow_wifi_set_ap_callback(&esp_ap_event);

            if (!ow_wifi_start())
            {
                writeError("WiFi radio start failed");
                return CompletionStatus.error;
            }
            _esp_started = true;
            update_esp_mode();
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        version(Espressif)
        {
            _esp_started = false;
            ow_wifi_set_rx_callback(null);
            ow_wifi_set_sta_callback(null);
            ow_wifi_set_ap_callback(null);
            ow_wifi_stop();
            ow_wifi_deinit();
        }
        return CompletionStatus.complete;
    }

    override ushort pcap_type() const
        => 127; // LINKTYPE_IEEE802_11_RADIOTAP

    override int transmit(ref const Packet packet, MessageCallback)
    {
        // can't sent raw 802.11 frames! (maybe some exotic wifi adapter can do it?)
        ++_status.send_dropped;
        return -1;
    }

private:
    ubyte _num_ap;
    ubyte _num_client;
    ubyte _channel;
    byte _tx_power;
    String _adapter;
    String _country;

    version(Espressif)
    {
        bool _esp_started;

        void update_esp_mode()
        {
            int esp_mode = 0; // WIFI_MODE_NULL
            if (_num_client > 0 && _num_ap > 0)
                esp_mode = 3; // WIFI_MODE_APSTA
            else if (_num_client > 0)
                esp_mode = 1; // WIFI_MODE_STA
            else if (_num_ap > 0)
                esp_mode = 2; // WIFI_MODE_AP
            ow_wifi_set_mode(esp_mode);
        }
    }
}


abstract class WLANBaseInterface : EthernetInterface
{
    __gshared Property[3] Properties = [
        Property.create!("radio", radio)(),
        Property.create!("ssid", ssid)(),
        Property.create!("secret", secret)(),
    ];
nothrow @nogc:

    // Properties

    final inout(WiFiInterface) radio() inout pure
        => _radio;
    final void radio(WiFiInterface value)
    {
        if (_radio is value)
            return;
        if (_subscribed)
        {
            _radio.unsubscribe(&radio_state_change);
            _subscribed = false;
        }
        if (_bound)
        {
            _radio.bind_wlan(this, true);
            _bound = false;
        }
        _radio = value;
        adapter(null);
        restart();
    }

    alias adapter = typeof(super).adapter;
    override void adapter(const(char)[] value)
    {
        super.adapter(value);
        if (!value.empty)
        {
            if (_subscribed)
            {
                _radio.unsubscribe(&radio_state_change);
                _subscribed = false;
            }
            if (_bound)
            {
                _radio.bind_wlan(this, true);
                _bound = false;
            }
            _radio = null;
        }
        restart();
    }

    final const(char)[] ssid() const pure
        => _ssid[];
    final void ssid(const(char)[] value)
    {
        _ssid = value.makeString(defaultAllocator);
    }

    final inout(Secret) secret() inout pure
        => _secret;
    final void secret(Secret value)
    {
        _secret = value;
    }

    // API

    override bool validate() const
    {
        if (super.validate())
            return true;
        return _radio !is null && !_ssid.empty;
    }

    override CompletionStatus validating()
    {
        _radio.try_reattach();
        return super.validating();
    }

    override const(char)[] status_message() const pure
    {
        if (_state == State.starting || _state == State.restarting)
        {
            if (_radio && !_radio.running)
                return "Waiting for radio";
        }
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        if (_radio)
        {
            if (!_bound)
            {
                _radio.bind_wlan(this, false);
                _bound = true;
                _radio.subscribe(&radio_state_change);
                _subscribed = true;
            }

            if (!_radio.running)
                return CompletionStatus.continue_;

            if (_radio.adapter.length > 0)
                super.adapter(_radio.adapter);
        }

        return super.startup();
    }

    override CompletionStatus shutdown()
    {
        auto result = super.shutdown();

        if (_subscribed)
        {
            _radio.unsubscribe(&radio_state_change);
            _subscribed = false;
        }
        if (_bound)
        {
            _radio.bind_wlan(this, true);
            _bound = false;
        }
        return result;
    }

protected:
    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
    }

    const(char)[] get_password() const
    {
        if (_secret)
        {
            if (!_secret.allow_service("wifi"))
                return null;
            return _secret.password;
        }
        return null;
    }

    version(Espressif)
    {
        override int transmit(ref const Packet packet, MessageCallback)
        {
            int iface = cast(APInterface)this !is null ? 1 : 0;
            if (packet.data.length > 0)
            {
                if (!ow_wifi_tx(iface, cast(const(ubyte)*)packet.data.ptr, cast(int)packet.data.length))
                {
                    ++_status.send_dropped;
                    return -1;
                }
                ++_status.send_packets;
                _status.send_bytes += packet.data.length;
            }
            return 0;
        }
    }

private:
    ObjectRef!WiFiInterface _radio;
    ObjectRef!Secret _secret;
    bool _subscribed;
    bool _bound;
    String _ssid;

    void radio_state_change(BaseObject, StateSignal signal)
    {
        if (signal == StateSignal.offline && running)
            restart();
    }

    version(Espressif)
    {
        void incoming_packet(ref Packet packet)
        {
            dispatch(packet);
        }
    }
}


class WLANInterface : WLANBaseInterface
{
    __gshared Property[1] Properties = [
        Property.create!("bssid-filter", bssid_filter)(),
    ];
nothrow @nogc:

    enum type_name = "wlan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WLANInterface, id, flags);
    }

    // Properties

    final MACAddress bssid_filter() const pure
        => _bssid_filter;
    final void bssid_filter(MACAddress value)
    {
        _bssid_filter = value;
    }

    override const(char)[] status_message() const pure
    {
        if (_status_detail.length > 0)
            return _status_detail;
        return super.status_message();
    }

    version(Espressif)
    {
        override void update()
        {
            if (esp_sta_disconnected)
            {
                esp_sta_disconnected = false;
                _status_detail = "Disconnected";
                log.warning("disconnected from '", _ssid[], "'");
                restart();
            }
        }
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        version(Espressif)
        {
            if (_connect_initiated)
            {
                if (esp_sta_connected)
                {
                    esp_sta_connected = false;
                    _status_detail = null;
                    return CompletionStatus.complete;
                }
                if (esp_sta_disconnected)
                {
                    esp_sta_disconnected = false;
                    _status_detail = "Association failed";
                    log.warning("failed to connect to '", _ssid[], "'");
                    _connect_initiated = false;
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }

            const(char)[] pw = get_password();
            if (!ow_wifi_sta_config(
                    ssid.length > 0 ? ssid[].tstringz : null,
                    pw.length > 0 ? pw[].tstringz : null,
                    _bssid_filter != MACAddress.init ? _bssid_filter.b.ptr : null))
            {
                _status_detail = "STA config rejected by driver";
                writeError("WiFi STA config failed for '", name, "'");
                return CompletionStatus.error;
            }

            ubyte[6] mac_buf = void;
            if (ow_wifi_get_mac(0, mac_buf.ptr))
            {
                remove_address(mac);
                mac = MACAddress(mac_buf);
                add_address(mac, this);
            }

            esp_sta_connected = false;
            esp_sta_disconnected = false;

            if (!ow_wifi_sta_connect())
            {
                _status_detail = "Connect request rejected by driver";
                writeError("WiFi STA connect failed for '", name, "'");
                return CompletionStatus.error;
            }

            _connect_initiated = true;
            _status_detail = "Connecting";
            log.info("connecting to '", _ssid[], "'");
            esp_active_sta = this;
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        version(Espressif)
        {
            if (esp_active_sta is this)
                esp_active_sta = null;
            _connect_initiated = false;
            ow_wifi_sta_disconnect();
        }
        _status_detail = null;
        return super.shutdown();
    }

private:
    MACAddress _bssid_filter;
    const(char)[] _status_detail;
    bool _connect_initiated;
}


class APInterface : WLANBaseInterface
{
    __gshared Property[4] Properties = [
        Property.create!("auth", auth)(),
        Property.create!("client-isolation", client_isolation)(),
        Property.create!("max-clients", max_clients)(),
        Property.create!("hidden", hidden)(),
    ];
nothrow @nogc:

    enum type_name = "wifi-ap";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!APInterface, id, flags);
    }

    // Properties

    final WifiAuth auth() const pure
        => _auth;
    final void auth(WifiAuth value)
    {
        _auth = value;
    }

    final bool client_isolation() const pure
        => _client_isolation;
    final void client_isolation(bool value)
    {
        _client_isolation = value;
    }

    final ubyte max_clients() const pure
        => _max_clients;
    final void max_clients(ubyte value)
    {
        _max_clients = value;
    }

    final bool hidden() const pure
        => _hidden;
    final void hidden(bool value)
    {
        _hidden = value;
    }

    override const(char)[] status_message() const pure
    {
        if (_status_detail.length > 0)
            return _status_detail;
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;

        version(Espressif)
        {
            if (_ap_config_sent)
            {
                if (esp_ap_started)
                {
                    esp_ap_started = false;
                    _status_detail = null;
                    return CompletionStatus.complete;
                }
                if (esp_ap_stopped)
                {
                    esp_ap_stopped = false;
                    _status_detail = "AP failed to start";
                    log.warning("AP '", _ssid[], "' failed to start");
                    _ap_config_sent = false;
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }

            const(char)[] pw = get_password();
            if (!ow_wifi_ap_config(
                    ssid.length > 0 ? ssid[].tstringz : null,
                    pw.length > 0 ? pw[].tstringz : null,
                    _radio ? _radio.channel : cast(ubyte)0,
                    _max_clients,
                    _hidden ? 1 : 0))
            {
                _status_detail = "AP config rejected by driver";
                writeError("WiFi AP config failed for '", name, "'");
                return CompletionStatus.error;
            }

            ubyte[6] mac_buf = void;
            if (ow_wifi_get_mac(1, mac_buf.ptr))
            {
                remove_address(mac);
                mac = MACAddress(mac_buf);
                add_address(mac, this);
            }

            esp_ap_started = false;
            esp_ap_stopped = false;
            _ap_config_sent = true;
            _status_detail = "Starting AP";
            log.info("starting AP '", _ssid[], "'");
            esp_active_ap = this;
        }

        return CompletionStatus.continue_;
    }

    version(Espressif)
    {
        override CompletionStatus shutdown()
        {
            if (esp_active_ap is this)
                esp_active_ap = null;
            _ap_config_sent = false;
            _status_detail = null;
            return super.shutdown();
        }
    }

private:
    WifiAuth _auth;
    ubyte _max_clients;
    bool _client_isolation;
    bool _hidden;
    const(char)[] _status_detail;
    bool _ap_config_sent;
}


class WiFiInterfaceModule : Module
{
    mixin DeclareModule!"interface.wifi";
nothrow @nogc:

    Collection!WiFiInterface wifi_radios;
    Collection!WLANInterface wlan_interfaces;
    Collection!APInterface ap_interfaces;

    override void init()
    {
        g_app.console.register_collection("/interface/wifi", wifi_radios);
        g_app.console.register_collection("/interface/wlan", wlan_interfaces);
        g_app.console.register_collection("/interface/ap", ap_interfaces);

        version(Windows)
        {
            if (!npcap_loaded())
                return;

            pcap_if* interfaces;
            char[PCAP_ERRBUF_SIZE] errbuf = void;
            if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
                return;
            scope(exit) pcap_freealldevs(interfaces);

            int num_radios = 0;
            for (auto dev = interfaces; dev; dev = dev.next)
            {
                if ((dev.flags & 0x00000001) != 0)
                    continue;

                const(char)[] name = dev.name[0..dev.name.strlen];
                const(char)[] description = dev.description[0..dev.description.strlen];

                bool is_wifi = (dev.flags & 0x00000008) != 0; // PCAP_IF_WIRELESS
                if (!is_wifi)
                {
                    if (description.contains_i("wireless") ||
                        description.contains_i("wi-fi") ||
                        description.contains_i("wifi"))
                        is_wifi = true;
                }

                if (!is_wifi)
                    continue;

                writeInfo("Found wifi interface: \"", description, "\" (", name[], ")");

                auto wlan = wlan_interfaces.create(tconcat("wlan", ++num_radios));
                wlan.adapter = name;
            }
        }
    }

    override void update()
    {
        wifi_radios.update_all();
        wlan_interfaces.update_all();
        ap_interfaces.update_all();
    }
}
