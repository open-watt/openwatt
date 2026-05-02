module driver.linux.hostapd;

version (linux):

import urt.conv;
import urt.mem.temp;
import urt.result;

import urt.internal.sys.posix;

import router.iface.wifi : WifiAuth;

public import driver.linux.ctrl_iface;

nothrow @nogc:


// hostapd uses the shared ctrl_iface protocol. Path: /var/run/hostapd/<iface>.
//
// Lifecycle policy: OpenWatt does NOT spawn or kill hostapd. It expects the
// daemon to be supervised externally (systemd unit, runit/s6 service, or the
// routeros container's init). We write the config file to a known path,
// hostapd reads it on RELOAD via the control socket.

enum hostapd_remote_dir = "/var/run/hostapd";
enum hostapd_local_tag  = "ha";
enum hostapd_config_dir = "/var/run/openwatt";

StringResult hostapd_open(ref CtrlIface c, const(char)[] iface)
    => c.open(iface, hostapd_remote_dir, hostapd_local_tag);


// Tell hostapd to re-read its config from disk and apply changes to the
// running BSSes. Returns success on "OK" response.
StringResult hostapd_reload(ref CtrlIface c)
    => simple_command(c, "RELOAD");

StringResult hostapd_disable(ref CtrlIface c)
    => simple_command(c, "DISABLE");

StringResult hostapd_enable(ref CtrlIface c)
    => simple_command(c, "ENABLE");

private StringResult simple_command(ref CtrlIface c, const(char)[] cmd)
{
    char[64] resp = void;
    size_t n;
    auto r = c.send_command(cmd, resp[], n);
    if (r.failed)
        return r;
    if (n < 2 || resp[0 .. 2] != "OK")
        return StringResult(tconcat(cmd, " refused: ", resp[0 .. n]));
    return StringResult.success;
}


// hostapd's hw_mode/iface state machine (defined in src/ap/hostapd.h). Values
// match the STATUS line "state=<...>". HAPD_IFACE_ENABLED is the operational
// terminal state; everything else is either startup-progress or trouble.
enum HostapdHwState : ubyte
{
    unknown,
    uninitialized,
    disabled,
    country_update,
    acs,
    ht_scan,
    dfs,
    no_ir,
    enabled,
}

HostapdHwState parse_hostapd_state(const(char)[] s) pure
{
    if (s == "UNINITIALIZED")  return HostapdHwState.uninitialized;
    if (s == "DISABLED")       return HostapdHwState.disabled;
    if (s == "COUNTRY_UPDATE") return HostapdHwState.country_update;
    if (s == "ACS")            return HostapdHwState.acs;
    if (s == "HT_SCAN")        return HostapdHwState.ht_scan;
    if (s == "DFS")            return HostapdHwState.dfs;
    if (s == "NO_IR")          return HostapdHwState.no_ir;
    if (s == "ENABLED")        return HostapdHwState.enabled;
    return HostapdHwState.unknown;
}

// Returns null when the BSS is operational (ENABLED), otherwise a short
// human-readable description of why it isn't.
const(char)[] hostapd_state_message(HostapdHwState s) pure
{
    final switch (s)
    {
        case HostapdHwState.unknown:        return "hostapd: unknown state";
        case HostapdHwState.uninitialized:  return "hostapd: not initialised (config rejected?)";
        case HostapdHwState.disabled:       return "hostapd: disabled";
        case HostapdHwState.country_update: return "hostapd: applying regulatory domain";
        case HostapdHwState.acs:            return "hostapd: selecting channel (ACS)";
        case HostapdHwState.ht_scan:        return "hostapd: scanning for clear channel";
        case HostapdHwState.dfs:            return "hostapd: waiting for radar clearance (DFS)";
        case HostapdHwState.no_ir:          return "hostapd: no initial radiation permitted";
        case HostapdHwState.enabled:        return null;
    }
}


// hostapd STATUS keys we care about today: "state", "channel", "ssid[0]"
// (first BSS), "bssid[0]", "num_sta[0]". Multi-BSS reports "ssid[1]" etc.
struct HostapdStatus
{
    const(char)[] state;        // raw state string for callers that want it.
    HostapdHwState hw_state;    // parsed; use this in preference to `state`.
    ubyte channel;
    const(char)[] ssid;         // first BSS only in v1
    const(char)[] bssid;
    uint num_sta;
}

StringResult hostapd_query_status(ref CtrlIface c, ref HostapdStatus out_status, char[] buf)
{
    size_t n;
    auto r = c.send_command("STATUS", buf, n);
    if (r.failed)
        return r;
    out_status = HostapdStatus.init;
    foreach_kv(buf[0 .. n], (key, value) nothrow @nogc {
        if (key == "state")
        {
            out_status.state = value;
            out_status.hw_state = parse_hostapd_state(value);
        }
        else if (key == "channel")
        {
            size_t consumed;
            long v = parse_int(value, &consumed);
            if (consumed == value.length && consumed > 0 && v >= 0 && v <= 196)
                out_status.channel = cast(ubyte)v;
        }
        else if (key == "ssid[0]")
            out_status.ssid = value;
        else if (key == "bssid[0]")
            out_status.bssid = value;
        else if (key == "num_sta[0]")
        {
            size_t consumed;
            long v = parse_int(value, &consumed);
            if (consumed == value.length && consumed > 0 && v >= 0)
                out_status.num_sta = cast(uint)v;
        }
    });
    return StringResult.success;
}


// Multi-BSS config-file generator. Writes to /var/run/openwatt/hostapd_<iface>.conf
// (where <iface> is the primary BSS netdev); the operator's hostapd service must
// be configured to read from this path.
//
// Layout:
//   bsses[0]    -> primary BSS, uses `interface=` (the radio's netdev).
//   bsses[1..]  -> additional BSSes, each emitted as `bss=<vif>` followed by
//                  per-BSS keys. hostapd creates the VIF via its nl80211 driver
//                  on RELOAD if it doesn't already exist.
// All BSSes share the radio block (channel, country, hw_mode) at the top.

struct BssConfig
{
    const(char)[] iface;        // primary uses the radio netdev; extras use a VIF (e.g. wlan0-guest)
    const(char)[] ssid;
    const(char)[] passphrase;   // empty -> open auth
    WifiAuth auth = WifiAuth.wpa2;
    bool hidden;
    bool client_isolation;
    ubyte max_clients;          // 0 -> hostapd default
}

struct ApConfig
{
    const(char)[] country;      // ISO-3166 2-letter; empty -> hostapd default
    ubyte channel;              // 0 -> ACS (auto channel selection)
    BssConfig[] bsses;          // bsses[0] is primary; must be non-empty
}

StringResult write_hostapd_config(ref const ApConfig cfg)
{
    if (cfg.bsses.length == 0)
        return StringResult("no BSSes configured");
    foreach (ref bss; cfg.bsses)
    {
        if (bss.iface.length == 0 || bss.iface.length > 32)
            return StringResult(tconcat("bad BSS iface name '", bss.iface, "'"));
    }

    auto rd = ensure_dir(hostapd_config_dir);
    if (rd.failed)
        return rd;

    char[256] path_buf = void;
    size_t plen = format_config_path(path_buf[], cfg.bsses[0].iface);
    if (plen == 0)
        return StringResult("config path overflow");

    char[4096] body_buf = void;
    size_t blen = format_config_body(body_buf[], cfg);
    if (blen == 0)
        return StringResult("config body overflow");

    int fd = open(path_buf.ptr, O_WRONLY | O_CREAT | O_TRUNC, octal!"600");
    if (fd < 0)
        return StringResult(tconcat("open('", path_buf.ptr[0 .. plen], "') failed: errno=", errno_result().system_code));
    scope(exit) close(fd);

    ssize_t wn = write(fd, body_buf.ptr, blen);
    if (wn < 0)
        return StringResult(tconcat("write('", path_buf.ptr[0 .. plen], "') failed: errno=", errno_result().system_code));
    if (cast(size_t)wn != blen)
        return StringResult(tconcat("write('", path_buf.ptr[0 .. plen], "') short: ", wn, "/", blen));
    return StringResult.success;
}


private:

enum uint octal(string s) = cast(uint)parse_uint(s, null, 8);

StringResult ensure_dir(const(char)[] path)
{
    char[256] tmp = void;
    if (path.length + 1 > tmp.length)
        return StringResult("dir path overflow");
    tmp[0 .. path.length] = path;
    tmp[path.length] = 0;

    stat_t st;
    if (stat(tmp.ptr, &st) == 0)
        return S_ISREG(st.st_mode) ? StringResult(tconcat("'", path, "' exists and is a regular file")) : StringResult.success;

    if (mkdir(tmp.ptr, octal!"700") < 0)
        return StringResult(tconcat("mkdir('", path, "') failed: errno=", errno_result().system_code));
    return StringResult.success;
}

size_t format_config_path(char[] dst, const(char)[] iface)
{
    enum prefix = hostapd_config_dir ~ "/hostapd_";
    enum suffix = ".conf";
    size_t need = prefix.length + iface.length + suffix.length + 1;
    if (need > dst.length)
        return 0;

    size_t i = 0;
    dst[i .. i + prefix.length] = prefix;       i += prefix.length;
    foreach (c; iface)
    {
        if (c == '/' || c == 0)
            return 0;
        dst[i++] = c;
    }
    dst[i .. i + suffix.length] = suffix;       i += suffix.length;
    dst[i] = 0;
    return i;
}

size_t format_config_body(char[] dst, ref const ApConfig cfg)
{
    size_t i = 0;

    bool put(const(char)[] s)
    {
        if (i + s.length > dst.length)
            return false;
        dst[i .. i + s.length] = s;
        i += s.length;
        return true;
    }

    bool kv(const(char)[] key, const(char)[] value)
    {
        return put(key) && put("=") && put(value) && put("\n");
    }

    bool kv_uint(const(char)[] key, uint v)
    {
        char[16] tmp = void;
        size_t n = v.format_int(tmp[]);
        return put(key) && put("=") && put(tmp[0 .. n]) && put("\n");
    }

    bool emit_bss_keys(ref const BssConfig bss)
    {
        if (!kv("ssid", bss.ssid)) return false;

        if (bss.max_clients > 0)
            if (!kv_uint("max_num_sta", bss.max_clients)) return false;
        if (bss.client_isolation)
            if (!kv("ap_isolate", "1")) return false;
        if (bss.hidden)
            if (!kv("ignore_broadcast_ssid", "1")) return false;

        // Auth. wpa= bitfield: 1=WPA, 2=WPA2/RSN, 3=mixed.
        final switch (bss.auth) with (WifiAuth)
        {
            case open:
                if (!kv("auth_algs", "1")) return false;
                break;

            case wpa2:
                if (!kv("auth_algs", "1")) return false;
                if (!kv("wpa", "2")) return false;
                if (!kv("wpa_key_mgmt", "WPA-PSK")) return false;
                if (!kv("rsn_pairwise", "CCMP")) return false;
                if (bss.passphrase.length > 0)
                    if (!kv("wpa_passphrase", bss.passphrase)) return false;
                break;

            case wpa3:
                if (!kv("auth_algs", "1")) return false;
                if (!kv("wpa", "2")) return false;
                if (!kv("wpa_key_mgmt", "SAE")) return false;
                if (!kv("rsn_pairwise", "CCMP")) return false;
                if (!kv("ieee80211w", "2")) return false;  // PMF required for WPA3
                if (bss.passphrase.length > 0)
                    if (!kv("sae_password", bss.passphrase)) return false;
                break;

            case wpa2_wpa3:
                if (!kv("auth_algs", "1")) return false;
                if (!kv("wpa", "2")) return false;
                if (!kv("wpa_key_mgmt", "WPA-PSK SAE")) return false;
                if (!kv("rsn_pairwise", "CCMP")) return false;
                if (!kv("ieee80211w", "1")) return false;  // PMF optional for transition
                if (bss.passphrase.length > 0)
                {
                    if (!kv("wpa_passphrase", bss.passphrase)) return false;
                    if (!kv("sae_password", bss.passphrase)) return false;
                }
                break;

            case wpa2_enterprise:
            case wpa3_enterprise:
                // Enterprise auth (EAP) needs a RADIUS server config; not in v1.
                // Caller should validate this isn't requested before generating.
                return false;
        }
        return true;
    }

    // Radio block: applies to all BSSes; must precede the first `bss=` line.
    if (!kv("interface", cfg.bsses[0].iface)) return 0;
    if (!kv("driver", "nl80211")) return 0;
    if (!kv("ctrl_interface", hostapd_remote_dir)) return 0;

    // hw_mode: 'g' for 2.4GHz, 'a' for 5GHz/6GHz. Inferred from channel; 0
    // (ACS) defaults to 'g' which hostapd interprets correctly with an empty
    // channel list. 6GHz needs more attribute work; defer to follow-up.
    bool is_5g = (cfg.channel >= 36);
    if (!kv("hw_mode", is_5g ? "a" : "g")) return 0;
    if (!kv_uint("channel", cfg.channel)) return 0;

    if (cfg.country.length > 0)
        if (!kv("country_code", cfg.country)) return 0;

    // Primary BSS keys (continuation of the interface= block).
    if (!emit_bss_keys(cfg.bsses[0])) return 0;

    // Additional BSSes.
    foreach (ref bss; cfg.bsses[1 .. $])
    {
        if (!kv("bss", bss.iface)) return 0;
        if (!emit_bss_keys(bss)) return 0;
    }

    return i;
}
