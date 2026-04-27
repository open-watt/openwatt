module router.iface.wifi;

import urt.lifetime;
import urt.log;
import urt.mem;
import urt.result : Result;
import urt.mem.string;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;
import manager.secret;

import router.iface;
import router.iface.ethernet;

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

// Regulatory installation context. Selects the per-domain allowed channels,
// max EIRP, and DFS rules for 5GHz; honoured by backends that have a real
// regulatory hookup (none of ours do yet).
enum WifiInstallation : byte
{
    any,
    indoor,
    outdoor,
}


// Abstract radio. Owns the WLAN/AP bind accounting and shared properties;
// per-platform subclasses (driver/baremetal/wifi.d, driver/windows/wifi.d, ...)
// provide actual hardware/OS interaction.
abstract class WiFiInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("mode", mode, "radio"),
                                 Prop!("channel", channel, "radio"),
                                 Prop!("tx-power", tx_power, "radio"),
                                 Prop!("country", country, "radio"));
nothrow @nogc:

    protected this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);

        mark_set!(typeof(this), "mode")();
    }

    // Properties

    const(char)[] mode() const pure
    {
        bool ap = _bound_ap !is null;
        bool sta = _bound_sta !is null;
        if (ap && sta)
            return "apsta";
        if (ap)
            return "ap";
        if (sta)
            return "sta";
        return "monitor";
    }

    ubyte channel() const pure
        => _channel;
    final const(char)[] channel(ubyte value)
    {
        if (value > 196)
            return "invalid channel number";
        _channel = value;
        mark_set!(typeof(this), "channel")();
        return null;
    }

    final byte tx_power() const pure
        => _tx_power;
    final const(char)[] tx_power(byte value)
    {
        _tx_power = value;
        mark_set!(typeof(this), "tx-power")();
        return null;
    }

    final const(char)[] country() const pure
        => _country[];
    final void country(const(char)[] value)
    {
        _country = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "country")();
    }

    // API

    void bind_wlan(WLANBaseInterface wlan, bool remove)
    {
        bool is_ap = cast(APInterface)wlan !is null;
        if (is_ap)
            _bound_ap = remove ? null : wlan;
        else
            _bound_sta = remove ? null : wlan;
        on_wlan_bind_changed();
    }

protected:

    // Subclass hook fired whenever a WLAN/AP gets bound or unbound. Default no-op;
    // embedded backends override to retune the radio mode (sta/ap/apsta).
    void on_wlan_bind_changed() {}

    final inout(WLANBaseInterface) bound_sta() inout pure => _bound_sta;
    final inout(WLANBaseInterface) bound_ap() inout pure => _bound_ap;

    override ushort pcap_type() const
        => 127; // LINKTYPE_IEEE802_11_RADIOTAP

    override int transmit(ref const Packet packet, MessageCallback)
    {
        add_tx_drop();
        return -1;
    }

private:
    ubyte _channel;
    byte _tx_power;
    String _country;
    WLANBaseInterface _bound_sta;
    WLANBaseInterface _bound_ap;
}


abstract class WLANBaseInterface : EthernetInterface
{
    alias Properties = AliasSeq!(Prop!("radio",  radio,  "configuration"),
                                 Prop!("ssid",   ssid,   "configuration"),
                                 Prop!("secret", secret, "configuration"));
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
        mark_set!(typeof(this), "radio")();
        restart();
    }

    const(char)[] ssid() const pure
        => _ssid[];
    final void ssid(const(char)[] value)
    {
        _ssid = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "ssid")();
    }

    final inout(Secret) secret() inout pure
        => _secret;
    final void secret(Secret value)
    {
        _secret = value;
        mark_set!(typeof(this), "secret")();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const
        => _radio !is null && !_ssid.empty;

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
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
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
        return CompletionStatus.complete;
    }

    final const(char)[] get_password() const
    {
        if (_secret)
        {
            if (!_secret.allow_service("wifi"))
                return null;
            return _secret.password;
        }
        return null;
    }

    this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
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


abstract class WLANInterface : WLANBaseInterface
{
    alias Properties = AliasSeq!(Prop!("bssid-filter",   bssid_filter,   "configuration"),
                                 Prop!("bssid",          bssid,          "configuration"),
                                 Prop!("rssi",           rssi,           "configuration"),
                                 Prop!("signal-quality", signal_quality, "configuration"));
nothrow @nogc:

    protected this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
    }

    // Properties

    final MACAddress bssid_filter() const pure
        => _bssid_filter;
    final void bssid_filter(MACAddress value)
    {
        _bssid_filter = value;
        mark_set!(typeof(this), "bssid-filter")();
    }

    MACAddress bssid() const
        => MACAddress();

    int rssi() const
        => 0; // dBm; 0 == not connected / unknown

    ubyte signal_quality() const
        => 0; // 0..100

private:
    MACAddress _bssid_filter;
}


abstract class APInterface : WLANBaseInterface
{
    alias Properties = AliasSeq!(Prop!("auth",             auth,             "configuration"),
                                 Prop!("client-isolation", client_isolation, "configuration"),
                                 Prop!("max-clients",      max_clients,      "configuration"),
                                 Prop!("hidden",           hidden,           "configuration"),
                                 Prop!("installation",     installation,     "configuration"));
nothrow @nogc:

    protected this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);
    }

    // Properties

    final WifiAuth auth() const pure
        => _auth;
    final void auth(WifiAuth value)
    {
        _auth = value;
        mark_set!(typeof(this), "auth")();
    }

    final bool client_isolation() const pure
        => _client_isolation;
    final void client_isolation(bool value)
    {
        _client_isolation = value;
        mark_set!(typeof(this), "client-isolation")();
    }

    final ubyte max_clients() const pure
        => _max_clients;
    final void max_clients(ubyte value)
    {
        _max_clients = value;
        mark_set!(typeof(this), "max-clients")();
    }

    final bool hidden() const pure
        => _hidden;
    final void hidden(bool value)
    {
        _hidden = value;
        mark_set!(typeof(this), "hidden")();
    }

    final WifiInstallation installation() const pure
        => _installation;
    final void installation(WifiInstallation value)
    {
        _installation = value;
        mark_set!(typeof(this), "installation")();
    }

private:
    WifiAuth _auth;
    ubyte _max_clients;
    bool _client_isolation;
    bool _hidden;
    WifiInstallation _installation;
}


// Just registers the WifiAuth enum. Per-platform driver modules register
// their own concrete subclasses (BuiltinWiFi, WindowsWifiRadio, etc.) which
// claim the canonical /interface/{wifi,wlan,ap} paths.
class WiFiInterfaceModule : Module
{
    mixin DeclareModule!"interface.wifi";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!WifiAuth();
        g_app.register_enum!WifiInstallation();
    }
}
