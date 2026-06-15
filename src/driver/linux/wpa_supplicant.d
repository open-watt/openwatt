module driver.linux.wpa_supplicant;

version (linux):
version (WifiStaDaemon):

import urt.conv;
import urt.log;
import urt.mem;
import urt.result;
import urt.string;

import router.iface.mac;

import driver.linux.nl80211 : rssi_to_quality;

public import driver.linux.ctrl_iface;

nothrow @nogc:


// wpa_supplicant uses the shared ctrl_iface protocol. Path: /var/run/wpa_supplicant/<iface>.

enum wpa_remote_dir = "/var/run/wpa_supplicant";
enum wpa_local_tag  = "wpa";

StringResult wpa_open(ref CtrlIface c, const(char)[] iface)
    => c.open(iface, wpa_remote_dir, wpa_local_tag);


enum WpaState : ubyte
{
    unknown,
    disconnected,
    interface_disabled,
    inactive,
    scanning,
    authenticating,
    associating,
    associated,
    handshake4,
    handshake_group,
    completed,
}

WpaState parse_wpa_state(const(char)[] s) pure
{
    if (s == "DISCONNECTED")        return WpaState.disconnected;
    if (s == "INTERFACE_DISABLED")  return WpaState.interface_disabled;
    if (s == "INACTIVE")            return WpaState.inactive;
    if (s == "SCANNING")            return WpaState.scanning;
    if (s == "AUTHENTICATING")      return WpaState.authenticating;
    if (s == "ASSOCIATING")         return WpaState.associating;
    if (s == "ASSOCIATED")          return WpaState.associated;
    if (s == "4WAY_HANDSHAKE")      return WpaState.handshake4;
    if (s == "GROUP_HANDSHAKE")     return WpaState.handshake_group;
    if (s == "COMPLETED")           return WpaState.completed;
    return WpaState.unknown;
}

const(char)[] wpa_state_message(WpaState s) pure
{
    final switch (s) with (WpaState)
    {
        case unknown:            return "unknown";
        case disconnected:       return "disconnected";
        case interface_disabled: return "interface-disabled";
        case inactive:           return "inactive";
        case scanning:           return "scanning";
        case authenticating:     return "authenticating";
        case associating:        return "associating";
        case associated:         return "associated";
        case handshake4:         return "4-way-handshake";
        case handshake_group:    return "group-handshake";
        case completed:          return "connected";
    }
}


// STA session backed by an external wpa_supplicant via its ctrl_iface socket.
struct WpaSupplicantSta
{
nothrow @nogc:

    bool valid() const pure           => _wpa.valid;
    bool connected() const pure       => _wpa_state == WpaState.completed;
    MACAddress bssid() const pure     => _current_bssid;
    int rssi() const pure             => _current_rssi;
    ubyte signal_quality() const pure => _signal_quality;
    uint freq() const pure            => _freq;
    const(char)[] active_ssid() const pure => _current_ssid[];
    const(char)[] status_message() const pure => wpa_state_message(_wpa_state);

    StringResult open(const(char)[] adapter)
        => wpa_open(_wpa, adapter);

    void close()
    {
        _wpa.close();
        clear();
    }

    bool consume_eapol(const(ubyte)[6] src, const(ubyte)[] payload)
        => false;

    // Push the configured network into wpa_supplicant and select it. Wipes any
    // stale config first so reconnect cycles don't accumulate networks.
    void set_network(const(char)[] ssid, const(char)[] password)
    {
        if (!_wpa.valid)
            return;
        char[256] resp = void;
        size_t n;
        _wpa.send_command("REMOVE_NETWORK all", resp[], n);

        auto ra = _wpa.send_command("ADD_NETWORK", resp[], n);
        if (ra.failed || n == 0)
        {
            log_warning("wifi.sta", "wpa ADD_NETWORK failed");
            return;
        }
        size_t end = 0;
        while (end < n && resp[end] >= '0' && resp[end] <= '9')
            ++end;
        const(char)[] id = resp[0 .. end];
        if (id.length == 0)
            return;

        char[512] cmd = void;
        size_t l;
        l = format_set_network(cmd[], id, "ssid", ssid, true);
        if (l == 0 || _wpa.send_command(cmd[0 .. l], resp[], n).failed)
            return;
        if (password.length > 0)
        {
            l = format_set_network(cmd[], id, "psk", password, true);
            if (l == 0 || _wpa.send_command(cmd[0 .. l], resp[], n).failed)
                return;
        }
        else
        {
            l = format_set_network(cmd[], id, "key_mgmt", "NONE", false);
            if (l == 0 || _wpa.send_command(cmd[0 .. l], resp[], n).failed)
                return;
        }
        l = format_select_network(cmd[], id);
        if (l > 0)
            _wpa.send_command(cmd[0 .. l], resp[], n);
    }

    // Poll wpa_supplicant STATUS (+ SIGNAL_POLL when associated) and refresh the
    // cached link state. The frontend reads the accessors and marks changes.
    void update()
    {
        if (!_wpa.valid)
        {
            clear();
            return;
        }
        char[2048] buf = void;
        size_t n;
        if (_wpa.send_command("STATUS", buf[], n).failed)
        {
            clear();
            return;
        }

        WpaState new_state;
        const(char)[] new_ssid_view; bool got_ssid;
        MACAddress new_bssid; bool got_bssid;
        uint new_freq;

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
                long f = parse_int(value, &consumed);
                if (consumed == value.length && consumed > 0 && f > 0)
                    new_freq = cast(uint)f;
            }
        });

        _wpa_state = new_state;
        _freq = new_freq;
        if (got_ssid)
        {
            if (_current_ssid[] != new_ssid_view)
                _current_ssid = new_ssid_view.makeString(defaultAllocator);
        }
        else
            _current_ssid = String.init;
        _current_bssid = got_bssid ? new_bssid : MACAddress();

        if (new_state == WpaState.completed && _wpa.send_command("SIGNAL_POLL", buf[], n).succeeded)
        {
            int rssi_dbm; bool got_rssi;
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
    }

private:
    CtrlIface _wpa;
    WpaState _wpa_state = WpaState.unknown;
    String _current_ssid;
    MACAddress _current_bssid;
    int _current_rssi;
    ubyte _signal_quality;
    uint _freq;

    void clear()
    {
        _current_ssid = String.init;
        _current_bssid = MACAddress();
        _current_rssi = 0;
        _signal_quality = 0;
        _wpa_state = WpaState.unknown;
    }
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
