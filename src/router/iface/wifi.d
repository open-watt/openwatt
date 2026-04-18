module router.iface.wifi;

import urt.lifetime;
import urt.log;
import urt.mem;
import urt.result : Result;
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

import sys.baremetal.wifi;

version (Windows)
{
    import manager.os.npcap;
}

static if (num_wifi > 0)
{
    import urt.endian : loadBigEndian;
    import urt.time : getSysTime;
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
    enum path = "/interface/wifi";

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
        static if (num_wifi > 0)
        {
            if (running && _wifi.is_open)
                return wifi_get_channel(_wifi);
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
            {
                --_num_ap;
                _bound_ap = null;
            }
            else
            {
                --_num_client;
                _bound_sta = null;
            }
        }
        else
        {
            if (is_ap)
            {
                ++_num_ap;
                _bound_ap = wlan;
            }
            else
            {
                ++_num_client;
                _bound_sta = wlan;
            }
        }

        static if (num_wifi > 0)
        {
            if (_wifi.is_open)
                update_drv_mode();
        }
    }

    static if (num_wifi > 0)
    {
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
    }

protected:

    override bool validate() const
    {
        static if (num_wifi > 0)
        {
            // ESP32 supports one STA + one AP per radio
            if (_num_ap > 1 || _num_client > 1)
                return false;
        }
        return true;
    }

    override const(char)[] status_message() const
    {
        static if (num_wifi > 0)
        {
            if (_num_ap > 1)
                return "only one AP per radio supported";
            if (_num_client > 1)
                return "only one STA per radio supported";
        }
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        static if (num_wifi > 0)
        {
            WifiConfig cfg;
            cfg.tx_power = _tx_power;
            cfg.channel = _channel;

            auto r = wifi_open(_wifi, 0, cfg);
            if (!r)
            {
                writeError("WiFi radio init failed");
                return CompletionStatus.error;
            }

            wifi_set_event_callback(_wifi, &wifi_event_dispatch);
            wifi_set_rx_callback(_wifi, &wifi_rx_dispatch);

            _active_radios[0] = this;
            update_drv_mode();
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        static if (num_wifi > 0)
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
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        static if (num_wifi > 0)
        {
            if (_wifi.is_open)
                wifi_poll(_wifi);
        }
    }

    override ushort pcap_type() const
        => 127; // LINKTYPE_IEEE802_11_RADIOTAP

    override int transmit(ref const Packet packet, MessageCallback)
    {
        add_tx_drop();
        return -1;
    }

private:
    ubyte _num_ap;
    ubyte _num_client;
    ubyte _channel;
    byte _tx_power;
    String _adapter;
    String _country;
    WLANBaseInterface _bound_sta;
    WLANBaseInterface _bound_ap;

    static if (num_wifi > 0)
    {
        Wifi _wifi;

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

        __gshared WiFiInterface[num_wifi] _active_radios;

        static void wifi_event_dispatch(Wifi wifi, WifiEvent event, const(void)*) nothrow @nogc
        {
            if (wifi.port < num_wifi)
                if (auto radio = _active_radios[wifi.port])
                    radio.on_wifi_event(event);
        }

        static void wifi_rx_dispatch(Wifi wifi, WifiVif vif, const(ubyte)[] data) nothrow @nogc
        {
            if (wifi.port < num_wifi)
                if (auto radio = _active_radios[wifi.port])
                    radio.on_wifi_rx(vif, data);
        }

        final void on_wifi_event(WifiEvent event)
        {
            final switch (event)
            {
                case WifiEvent.sta_connected:       evt_sta_connected = true; break;
                case WifiEvent.sta_disconnected:    evt_sta_disconnected = true; break;
                case WifiEvent.ap_started:          evt_ap_started = true; break;
                case WifiEvent.ap_stopped:          evt_ap_stopped = true; break;
                case WifiEvent.ap_sta_connected:    break;
                case WifiEvent.ap_sta_disconnected: break;
                case WifiEvent.scan_done:           break;
            }
        }

        final void on_wifi_rx(WifiVif vif, const(ubyte)[] data)
        {
            auto target = vif == WifiVif.ap ? _bound_ap : _bound_sta;
            if (target is null || !target.running || data.length < 14)
                return;

            Packet packet;
            ref eth = packet.init!Ethernet(data, getSysTime());
            auto mac_hdr = cast(const Ethernet*)data.ptr;
            eth.dst = mac_hdr.dst;
            eth.src = mac_hdr.src;
            eth.ether_type = loadBigEndian(&mac_hdr.ether_type);
            packet._offset = 14;

            target.dispatch(packet);
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

    static if (num_wifi > 0)
    {
        override int transmit(ref const Packet packet, MessageCallback)
        {
            if (!_radio || !_radio.running || packet.data.length == 0)
            {
                add_tx_drop();
                return -1;
            }
            WifiVif vif = cast(APInterface)this !is null ? WifiVif.ap : WifiVif.sta;
            if (!_radio.drv_transmit(vif, cast(const(ubyte)[])packet.data))
            {
                add_tx_drop();
                return -1;
            }
            add_tx_frame(packet.data.length);
            return 0;
        }
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

private:
    ObjectRef!WiFiInterface _radio;
    ObjectRef!Secret _secret;
    bool _subscribed;
    bool _bound;
    String _ssid;

    void radio_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline && running)
            restart();
    }
}


class WLANInterface : WLANBaseInterface
{
    __gshared Property[1] Properties = [
        Property.create!("bssid-filter", bssid_filter)(),
    ];
nothrow @nogc:

    enum type_name = "wlan";
    enum path = "/interface/wlan";

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

    static if (num_wifi > 0)
    {
        override void update()
        {
            super.update();

            if (_radio && _radio.evt_sta_disconnected)
            {
                _radio.evt_sta_disconnected = false;
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

        static if (num_wifi > 0)
        {
            if (!_radio)
                return CompletionStatus.error;

            if (_connect_initiated)
            {
                if (_radio.evt_sta_connected)
                {
                    _radio.evt_sta_connected = false;
                    _status_detail = null;
                    return CompletionStatus.complete;
                }
                if (_radio.evt_sta_disconnected)
                {
                    _radio.evt_sta_disconnected = false;
                    _status_detail = "Association failed";
                    log.warning("failed to connect to '", _ssid[], "'");
                    _connect_initiated = false;
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }

            WifiStaConfig sta_cfg;
            sta_cfg.ssid = _ssid[];
            sta_cfg.password = get_password();
            if (_bssid_filter != MACAddress.init)
                sta_cfg.bssid = _bssid_filter.b;

            if (!wifi_sta_configure(_radio._wifi, sta_cfg))
            {
                _status_detail = "STA config rejected by driver";
                writeError("WiFi STA config failed for '", name, "'");
                return CompletionStatus.error;
            }

            ubyte[6] mac_buf = void;
            if (_radio.drv_get_mac(WifiVif.sta, mac_buf))
            {
                remove_address(mac);
                mac = MACAddress(mac_buf);
                add_address(mac, this);
            }

            _radio.evt_sta_connected = false;
            _radio.evt_sta_disconnected = false;

            if (!wifi_sta_connect(_radio._wifi))
            {
                _status_detail = "Connect request rejected by driver";
                writeError("WiFi STA connect failed for '", name, "'");
                return CompletionStatus.error;
            }

            _connect_initiated = true;
            _status_detail = "Connecting";
            log.info("connecting to '", _ssid[], "'");
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        static if (num_wifi > 0)
        {
            if (_connect_initiated && _radio)
                wifi_sta_disconnect(_radio._wifi);
            _connect_initiated = false;
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
    enum path = "/interface/ap";

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

        static if (num_wifi > 0)
        {
            if (!_radio)
                return CompletionStatus.error;

            if (_ap_config_sent)
            {
                if (_radio.evt_ap_started)
                {
                    _radio.evt_ap_started = false;
                    _status_detail = null;
                    return CompletionStatus.complete;
                }
                if (_radio.evt_ap_stopped)
                {
                    _radio.evt_ap_stopped = false;
                    _status_detail = "AP failed to start";
                    log.warning("AP '", _ssid[], "' failed to start");
                    _ap_config_sent = false;
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }

            WifiApConfig ap_cfg;
            ap_cfg.ssid = _ssid[];
            ap_cfg.password = get_password();
            ap_cfg.channel = _radio ? _radio.channel : cast(ubyte)0;
            ap_cfg.max_clients = _max_clients;
            ap_cfg.hidden = _hidden;

            if (!wifi_ap_configure(_radio._wifi, ap_cfg))
            {
                _status_detail = "AP config rejected by driver";
                writeError("WiFi AP config failed for '", name, "'");
                return CompletionStatus.error;
            }

            ubyte[6] mac_buf = void;
            if (_radio.drv_get_mac(WifiVif.ap, mac_buf))
            {
                remove_address(mac);
                mac = MACAddress(mac_buf);
                add_address(mac, this);
            }

            _radio.evt_ap_started = false;
            _radio.evt_ap_stopped = false;
            _ap_config_sent = true;
            _status_detail = "Starting AP";
            log.info("starting AP '", _ssid[], "'");
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        static if (num_wifi > 0)
            _ap_config_sent = false;
        _status_detail = null;
        return super.shutdown();
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

    override void init()
    {
        g_app.register_enum!WifiAuth();

        g_app.console.register_collection!WiFiInterface();
        g_app.console.register_collection!WLANInterface();
        g_app.console.register_collection!APInterface();

        version (Windows)
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

                writeInfo("Found wifi interface: \"", description, "\" (", name[], ")");

                auto wlan = cast(WLANInterface)Collection!WLANInterface().create(tconcat("wlan", ++num_radios));
                wlan.adapter = name;
            }
        }
    }
}
