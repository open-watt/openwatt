module router.iface.wifi;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.result : Result;
import urt.si.quantity;
import urt.si.unit : Gigahertz;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;
import manager.secret;

import router.iface;
import router.iface.ethernet;

public import urt.driver.wifi : WifiBand, WifiBandwidth, WifiPhyMode, WifiScanConfig, WifiScanResult;

nothrow @nogc:


// Invoked once when an async scan completes; `ok` is false on failure/abort.
// The results slice is valid only for the duration of the call.
alias ScanHandler = void delegate(scope const(WifiScanResult)[] results, bool ok) nothrow @nogc;


enum WifiAuth : byte
{
    open,
    wpa2,
    wpa3,
    wpa2_wpa3,
    wpa2_enterprise,
    wpa3_enterprise,
}

enum WifiInstallation : byte
{
    any,
    indoor,
    outdoor,
}


// Peak PHY rate in bit/s for the described link, for platforms that can name the PHY but not the
// negotiated rate. Returns 0 for an unknown mode.
ulong wifi_phy_max_rate(WifiPhyMode mode, WifiBandwidth bw, ubyte nss = 1, bool short_gi = false) pure
{
    // bit/s per spatial stream at the highest MCS each mode defines.
    // HT is 20/40MHz only, so wider requests clamp to HT40 rather than reading as unknown.
    static immutable uint[4][2] ht  = [[65_000_000, 135_000_000, 135_000_000, 135_000_000],
                                       [72_200_000, 150_000_000, 150_000_000, 150_000_000]];
    static immutable uint[4][2] vht = [[78_000_000, 180_000_000, 390_000_000, 780_000_000],
                                       [86_700_000, 200_000_000, 433_300_000, 866_700_000]];
    // HE/EHT carry a 12.8us symbol whose shortest guard interval (0.8us) is already the peak these
    // figures quote, so short_gi has no meaning here and is deliberately ignored.
    static immutable uint[4] he  = [143_400_000, 286_800_000, 600_400_000, 1_201_000_000];
    static immutable uint[4] eht = [172_100_000, 344_100_000, 720_600_000, 1_441_200_000];

    static assert(WifiBandwidth.max == WifiBandwidth.bw_160mhz, "a wider channel needs a column in every table here");

    const size_t gi = short_gi ? 1 : 0;

    uint rate;
    final switch (mode)
    {
        case WifiPhyMode.unknown:
            return 0;
        case WifiPhyMode.b:
            return 11_000_000;
        case WifiPhyMode.a:
        case WifiPhyMode.g:
            return 54_000_000;
        case WifiPhyMode.lr:
            return 500_000; // ESP-IDF wifi_phy_rate_t offers only LORA_250K and LORA_500K
        case WifiPhyMode.n:
            rate = ht[gi][bw];
            break;
        case WifiPhyMode.ac:
            rate = vht[gi][bw];
            break;
        case WifiPhyMode.ax:
            rate = he[bw];
            break;
        case WifiPhyMode.be:
            rate = eht[bw];
            break;
    }
    return ulong(rate) * (nss ? nss : 1);
}


// Human-readable description of a PHY, e.g. "VHT80 2SS". 802.11 folds the channel width into the mode
// name, so the width belongs there rather than beside it. Returns null for an unknown mode, and a
// stream count of 0 is left out rather than printed as a guess.
const(char)[] format_phy_mode(char[] buffer, WifiPhyMode mode, WifiBandwidth bw, ubyte nss = 0, bool short_gi = false)
{
    static immutable string[4] widths = [ "20", "40", "80", "160" ];

    return format_phy(buffer, mode, widths[bw], nss, short_gi);
}

// For a platform that names the PHY family and nothing else; the width is omitted rather than assumed,
// since 20MHz would be a wrong guess for anything above 11g.
const(char)[] format_phy_mode(char[] buffer, WifiPhyMode mode)
    => format_phy(buffer, mode, "", 0, false);

private const(char)[] format_phy(char[] buffer, WifiPhyMode mode, string width, ubyte nss, bool short_gi)
{
    string name;
    bool sized;
    final switch (mode)
    {
        case WifiPhyMode.unknown:
            return null;
        case WifiPhyMode.lr:
            name = "LR";
            break;
        case WifiPhyMode.b:
            name = "11b";
            break;
        case WifiPhyMode.a:
            name = "11a";
            break;
        case WifiPhyMode.g:
            name = "11g";
            break;
        case WifiPhyMode.n:
            name = "HT";
            sized = true;
            break;
        case WifiPhyMode.ac:
            name = "VHT";
            sized = true;
            break;
        case WifiPhyMode.ax:
            name = "HE";
            sized = true;
            break;
        case WifiPhyMode.be:
            name = "EHT";
            sized = true;
            break;
    }

    if (!sized)
        width = "";
    // HE and EHT choose a guard interval per transmission rather than per link, so it only describes
    // an HT or VHT rate
    string gi = short_gi && (mode == WifiPhyMode.n || mode == WifiPhyMode.ac) ? " SGI" : "";

    if (nss == 0)
        return buffer.concat(name, width, gi);
    return buffer.concat(name, width, " ", uint(nss), "SS", gi);
}


private struct PhyText
{
nothrow @nogc:
    enum capacity = 16;

    const(char)[] get() const pure
        => _text[0 .. _len];

    bool set(const(char)[] value)
    {
        if (value == _text[0 .. _len])
            return false;
        _len = cast(ubyte)value.length;
        _text[0 .. _len] = value;
        return true;
    }

private:
    char[capacity] _text = void;
    ubyte _len;
}


abstract class WiFiInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("mode", mode, "radio"),
                                 Prop!("band", band, "radio"),
                                 Prop!("channel", channel, "radio"),
                                 Prop!("active-channel", active_channel, "radio"),
                                 Prop!("tx-power", tx_power, "radio"),
                                 Prop!("country", country, "radio"),
                                 Prop!("monitor", monitor, "radio"),
                                 Prop!("phy-capability", phy_capability, "radio"));
nothrow @nogc:

    protected this(const CollectionTypeInfo* typeInfo, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(typeInfo, id, flags);

        mark_set!(typeof(this), "mode")();
    }

    // Properties

    const(char)[] mode() const pure
    {
        bool ap = _bound_aps.length > 0;
        bool sta = _bound_sta !is null;
        if (ap && sta)
            return "apsta";
        if (ap)
            return "ap";
        if (sta)
            return "sta";
        return "monitor";
    }

    final WifiBand band() const pure
        => _band;
    final void band(WifiBand value)
    {
        if (_band == value)
            return;
        _band = value;
        mark_set!(typeof(this), "band")();
        on_band_changed(value);
    }
    // accepts a centre-ish frequency so the CLI can take `band=2.4GHz` unquoted
    final const(char)[] band(Quantity!(float, Gigahertz) value)
    {
        float ghz = value.value;
        if (ghz >= 2 && ghz < 3)
            band = WifiBand._2_4ghz;
        else if (ghz >= 4.9 && ghz < 5.9)
            band = WifiBand._5ghz;
        else if (ghz >= 5.925 && ghz <= 7.2)
            band = WifiBand._6ghz;
        else
            return "not a WiFi band";
        return null;
    }

    final ubyte channel() const pure
        => _channel;
    final const(char)[] channel(ubyte value)
    {
        if (value > 233)
            return "invalid channel number";
        if (_channel == value)
            return null;
        _channel = value;
        mark_set!(typeof(this), "channel")();
        on_channel_changed(value);
        return null;
    }

    final ubyte active_channel() const pure
        => _active_channel;

    final const(char)[] phy_capability() const pure
        => _phy_capability.get;

    final byte tx_power() const pure
        => _tx_power;
    final const(char)[] tx_power(byte value)
    {
        if (_tx_power == value)
            return null;
        _tx_power = value;
        mark_set!(typeof(this), "tx-power")();
        on_tx_power_changed();
        return null;
    }

    final const(char)[] country() const pure
        => _country[];
    final void country(const(char)[] value)
    {
        _country = value.make_string();
        mark_set!(typeof(this), "country")();
    }

    final bool monitor() const pure
        => _monitor;
    final const(char)[] monitor(bool value)
    {
        if (_monitor == value)
            return null;
        _monitor = value;
        mark_set!(typeof(this), "monitor")();
        on_monitor_changed(value);
        return null;
    }

    // API

    void bind_wlan(WLANBaseInterface wlan, bool remove)
    {
        if (auto ap = cast(APInterface)wlan)
        {
            if (remove)
                _bound_aps.removeFirst(ap);
            else
                _bound_aps ~= ap;
        }
        else
            _bound_sta = remove ? null : wlan;
        on_wlan_bind_changed();
    }

    bool start_scan(ref const WifiScanConfig cfg, ScanHandler done) { return false; }

    void cancel_scan() {}

    bool scanning() const { return false; }

protected:

    override bool validate() const
        => band_channel_conflict() is null && super.validate();

    override const(char)[] status_message() const
    {
        if (auto conflict = band_channel_conflict())
            return conflict;
        return super.status_message();
    }

    final const(char)[] band_channel_conflict() const pure
    {
        if (_band == WifiBand._2_4ghz && _channel > 14)
            return "channel is not in the 2.4GHz band";
        if (_band == WifiBand._5ghz && _channel != 0 && _channel < 32)
            return "channel is not in the 5GHz band";
        return null;
    }

    void on_wlan_bind_changed() {}

    final void set_phy_capability(WifiPhyMode mode, WifiBandwidth bw, ubyte nss)
    {
        char[PhyText.capacity] buffer = void;
        if (_phy_capability.set(format_phy_mode(buffer[], mode, bw, nss)))
            mark_set!(typeof(this), "phy-capability")();
    }

    final void set_phy_capability(WifiPhyMode mode)
    {
        char[PhyText.capacity] buffer = void;
        if (_phy_capability.set(format_phy_mode(buffer[], mode)))
            mark_set!(typeof(this), "phy-capability")();
    }

    final void set_active_channel(ubyte value)
    {
        if (_active_channel == value)
            return;
        _active_channel = value;
        mark_set!(typeof(this), "active-channel")();
        on_active_channel_changed(value);
    }

    void on_active_channel_changed(ubyte channel) {}

    void on_band_changed(WifiBand band) {}

    void on_channel_changed(ubyte channel) {}

    void on_tx_power_changed() {}

    void on_monitor_changed(bool enabled) {}

    final inout(WLANBaseInterface) bound_sta() inout pure
        => _bound_sta;
    final inout(APInterface)[] bound_aps() inout pure
        => _bound_aps[];
    final inout(APInterface) bound_ap() inout pure
        => _bound_aps.length > 0 ? _bound_aps[0] : null;

    override ushort pcap_type() const
        => 127; // LINKTYPE_IEEE802_11_RADIOTAP

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
    {
        if (packet.type == PacketType.wifi_80211)
            sink(packet.data);
    }

    override int transmit(ref const Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        add_tx_drop();
        return -1;
    }

private:
    WifiBand _band;
    PhyText _phy_capability;
    ubyte _channel;
    ubyte _active_channel;
    byte _tx_power;
    bool _monitor;
    String _country;
    WLANBaseInterface _bound_sta;
    Array!APInterface _bound_aps;
}


abstract class WLANBaseInterface : EthernetInterface
{
    alias Properties = AliasSeq!(Prop!("radio",    radio,    "configuration"),
                                 Prop!("ssid",     ssid,     "configuration"),
                                 Prop!("secret",   secret,   "configuration"),
                                 Prop!("phy-mode", phy_mode, "configuration"));
nothrow @nogc:

    // Properties

    final const(char)[] phy_mode() const pure
        => _phy_mode.get;

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
        if (_ssid[] == value)
            return;
        _ssid = value.make_string();
        mark_set!(typeof(this), "ssid")();
        restart();
    }

    final inout(Secret) secret() inout pure
        => _secret;
    final void secret(Secret value)
    {
        if (_secret.get is value)
            return;
        _secret = value;
        mark_set!(typeof(this), "secret")();
        restart();
    }

    final void on_radio_rx(const(ubyte)[] data, MonoTime ts)
    {
        incoming_ethernet_frame(data, ts);
    }

protected:

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
        return super.shutdown();
    }

    final void set_phy_mode(WifiPhyMode mode, WifiBandwidth bw, ubyte nss, bool short_gi)
    {
        char[PhyText.capacity] buffer = void;
        if (_phy_mode.set(format_phy_mode(buffer[], mode, bw, nss, short_gi)))
            mark_set!(typeof(this), "phy-mode")();
    }

    final void set_phy_mode(WifiPhyMode mode)
    {
        char[PhyText.capacity] buffer = void;
        if (_phy_mode.set(format_phy_mode(buffer[], mode)))
            mark_set!(typeof(this), "phy-mode")();
    }

    override void offline()
    {
        super.offline();
        set_phy_mode(WifiPhyMode.unknown);
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
    PhyText _phy_mode;
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
        on_max_clients_changed(value);
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

protected:
    void on_max_clients_changed(ubyte value) {}

private:
    WifiAuth _auth;
    ubyte _max_clients;
    bool _client_isolation;
    bool _hidden;
    WifiInstallation _installation;
}


class WiFiInterfaceModule : Module
{
    mixin DeclareModule!"interface.wifi";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!Wifi80211();

        g_app.register_enum!WifiAuth();
        g_app.register_enum!WifiBand();
        g_app.register_enum!WifiInstallation();
    }
}


unittest
{
    char[16] buffer = void;

    assert(format_phy_mode(buffer[], WifiPhyMode.unknown) is null);
    assert(format_phy_mode(buffer[], WifiPhyMode.b, WifiBandwidth.bw_20mhz) == "11b");
    assert(format_phy_mode(buffer[], WifiPhyMode.a, WifiBandwidth.bw_20mhz) == "11a");

    assert(format_phy_mode(buffer[], WifiPhyMode.g, WifiBandwidth.bw_80mhz, 1) == "11g 1SS");
    assert(format_phy_mode(buffer[], WifiPhyMode.lr, WifiBandwidth.bw_20mhz) == "LR");

    assert(format_phy_mode(buffer[], WifiPhyMode.n, WifiBandwidth.bw_40mhz, 2) == "HT40 2SS");
    assert(format_phy_mode(buffer[], WifiPhyMode.ac, WifiBandwidth.bw_80mhz, 2, true) == "VHT80 2SS SGI");
    assert(format_phy_mode(buffer[], WifiPhyMode.be, WifiBandwidth.bw_160mhz, 8) == "EHT160 8SS");

    assert(format_phy_mode(buffer[], WifiPhyMode.ax, WifiBandwidth.bw_160mhz, 2, true) == "HE160 2SS");

    assert(format_phy_mode(buffer[], WifiPhyMode.n, WifiBandwidth.bw_20mhz, 0) == "HT20");
    assert(format_phy_mode(buffer[], WifiPhyMode.ac) == "VHT");

    assert(format_phy_mode(buffer[], WifiPhyMode.ac, WifiBandwidth.bw_160mhz, 8, true) == "VHT160 8SS SGI");
}
