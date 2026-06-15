module driver.linux.nl80211_sta;

// =====================================================================
// Native Linux STA: drives nl80211 (cfg80211 SME) directly and runs the
// 4-way handshake in-process via urt.driver.wpa, replacing the
// wpa_supplicant control-socket dependency.
//
// Flow:
//   1. open()    -- resolve ifindex/MAC, open a command socket and an event
//                   socket joined to the nl80211 "scan"/"mlme" mcast groups.
//   2. connect() -- configure the supplicant (derives the PMK), send
//                   NL80211_CMD_CONNECT to a scanned BSS (BSSID+freq), handing
//                   it the same RSN IE the supplicant will MIC.
//   3. pump()    -- drain async events. CONNECT(status=0) -> associated(),
//                   which kicks the 4-way; DISCONNECT/DEAUTH -> tear down.
//   4. EAPOL     -- runs over the netdev (AF_PACKET, owned by LinuxWlan).
//                   on_eapol() feeds RX into the supplicant; the send_eapol
//                   hook TXes via the same RawAdapter. Keys install with
//                   NL80211_CMD_NEW_KEY, then NL80211_CMD_PORT_AUTHORIZED.
//
// The shared generic-netlink plumbing (NlBuilder, foreach_attr/find_attr,
// nl_open_socket, resolve_nl80211, nl_ack/nl_request) lives in
// driver.linux.nl80211 -- reused by the radio scan, not duplicated here.
//
// WPA2-PSK/CCMP only (matches the urt supplicant). Open networks work too
// (no PSK -> association completes immediately). WPA3-SAE is future work.
// =====================================================================

version (linux):
version (WifiStaKernel):

import urt.log;
import urt.mem.temp;
import urt.result;
import urt.string;

import urt.internal.sys.posix : posix_close = close;

import urt.driver.wifi : WifiStaConfig;
import urt.driver.wpa.supplicant;

import driver.linux.nl80211;   // shared genl/netlink ABI + toolkit
import driver.linux.raw : RawAdapter, ioctl, ifreq, SIOCGIFHWADDR, IFNAMSIZ;

import router.iface.mac;

nothrow @nogc:


// STA-specific commands/attrs (shared key/cipher/auth ABI lives in nl80211).
enum NL80211_CMD_GET_STATION     = 17;
enum NL80211_CMD_DEAUTHENTICATE  = 39;
enum NL80211_CMD_CONNECT         = 46;
enum NL80211_CMD_PORT_AUTHORIZED = 125;

enum NL80211_ATTR_STA_INFO    = 21;
enum NL80211_ATTR_STATUS_CODE = 72;
enum NL80211_STA_INFO_SIGNAL  = 7;


enum StaState : ubyte
{
    idle,
    connecting,     // CMD_CONNECT sent, awaiting the association event
    keying,         // associated; 4-way handshake in progress
    connected,
    disconnected,
    failed,
}


// The hooks the supplicant calls are plain function pointers (no context), so
// they dispatch through this. Set transiently around every supplicant entry
// point; the main loop is single-threaded and hooks fire synchronously inside
// those calls, so at most one session is "current" at a time.
private __gshared Nl80211Sta* g_active_sta;


struct Nl80211Sta
{
nothrow @nogc:

    bool valid() const pure        => _cmd_fd >= 0;
    bool connected() const pure    => _state == StaState.connected;
    bool failed() const pure       => _state == StaState.failed;
    bool disconnected() const pure => _state == StaState.disconnected;
    bool idle() const pure         => _state == StaState.idle;
    int event_fd() const pure      => _event_fd;
    MACAddress bssid() const pure  => _bssid;
    int rssi() const pure          => _rssi;
    uint freq() const pure         => _freq;
    ubyte signal_quality() const pure => rssi_to_quality(_rssi);

    // Frontend frame-loop bridge: feed EAPOL into the in-process supplicant.
    // src is unused -- a STA has a single peer (the AP).
    bool consume_eapol(const(ubyte)[6] src, const(ubyte)[] payload)
    {
        on_eapol(payload);
        return true;
    }

    const(char)[] status_message() const pure
    {
        final switch (_state) with (StaState)
        {
            case idle:         return "idle";
            case connecting:   return "connecting";
            case keying:       return "4-way-handshake";
            case connected:    return "connected";
            case disconnected: return "disconnected";
            case failed:       return "authentication failed";
        }
    }

    StringResult open(const(char)[] adapter, RawAdapter* raw)
    {
        _raw = raw;
        _ifindex = cast(uint)raw.ifindex;

        if (adapter.length >= IFNAMSIZ)
            return StringResult("adapter name too long");
        ifreq req;
        req.ifr_name[0 .. adapter.length] = adapter[];
        req.ifr_name[adapter.length] = 0;
        if (ioctl(raw.fd, SIOCGIFHWADDR, &req) < 0)
            return StringResult(tconcat("SIOCGIFHWADDR('", adapter, "') failed: errno=", last_errno()));
        _own_mac[] = req.ifru_addr.data[0 .. 6];

        _cmd_fd = nl_open_socket(false);
        if (_cmd_fd < 0)
            return StringResult(tconcat("nl80211 command socket failed: errno=", last_errno()));

        _event_fd = nl_open_socket(true);
        if (_event_fd < 0)
        {
            posix_close(_cmd_fd);
            _cmd_fd = -1;
            return StringResult(tconcat("nl80211 event socket failed: errno=", last_errno()));
        }

        uint scan_grp, mlme_grp;
        if (!resolve_nl80211(_cmd_fd, _family_id, scan_grp, mlme_grp))
        {
            close_fds();
            return StringResult("nl80211 generic-netlink family unavailable");
        }
        // STA cares about MLME events (connect/disconnect/deauth); the radio
        // owns scan, so we don't subscribe to the scan group here.
        if (mlme_grp)
            setsockopt(_event_fd, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &mlme_grp, mlme_grp.sizeof);

        _state = StaState.idle;
        return StringResult.success;
    }

    void close()
    {
        if (_state == StaState.connecting || _state == StaState.keying || _state == StaState.connected)
            disconnect_kernel();
        close_fds();
        _state = StaState.idle;
        _raw = null;
    }

    // Connect to a specific scanned BSS (bssid+freq from the radio scan). A
    // concrete BSS makes cfg80211 register the connection so keys install.
    bool connect(const(char)[] ssid, const(char)[] password, const(ubyte)[6] bssid, uint freq)
    {
        g_active_sta = &this;
        scope(exit) g_active_sta = null;

        WifiStaConfig cfg;
        cfg.ssid = ssid;
        cfg.password = password;
        cfg.bssid = bssid;
        if (!_supp.configure(cfg))
        {
            log_warning("wifi.sta", "supplicant configure failed");
            _state = StaState.failed;
            return false;
        }

        _supp.hooks.send_eapol         = &hook_send_eapol;
        _supp.hooks.install_pairwise_key = &hook_install_pairwise;
        _supp.hooks.install_group_key  = &hook_install_group;
        _supp.hooks.auth_done          = &hook_auth_done;

        _bssid.b[] = bssid[];
        _freq = freq;

        bool psk = _supp.profile.key_mgmt == WpaKeyMgmt.wpa2_psk;
        _supp.begin_association(_own_mac, psk ? wpa2_psk_ccmp_rsn_ie[] : null);

        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_CONNECT);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_SSID, cast(const(ubyte)[])ssid);
        b.put_bytes(NL80211_ATTR_MAC, bssid[]);
        if (freq)
            b.put_u32(NL80211_ATTR_WIPHY_FREQ, freq);
        b.put_u32(NL80211_ATTR_AUTH_TYPE, NL80211_AUTHTYPE_OPEN_SYSTEM);
        if (psk)
        {
            b.put_u32(NL80211_ATTR_WPA_VERSIONS, NL80211_WPA_VERSION_2);
            b.put_u32(NL80211_ATTR_CIPHER_SUITES_PAIRWISE, rsn_cipher_ccmp);
            b.put_u32(NL80211_ATTR_CIPHER_SUITE_GROUP, rsn_cipher_ccmp);
            b.put_u32(NL80211_ATTR_AKM_SUITES, rsn_akm_psk);
            b.put_bytes(NL80211_ATTR_IE, wpa2_psk_ccmp_rsn_ie[]);
        }
        if (!nl_ack(_cmd_fd, b, "CONNECT"))
        {
            _state = StaState.failed;
            return false;
        }

        _state = StaState.connecting;
        log_info("wifi.sta", "CONNECT sent ssid='", ssid, "' bssid=", _bssid, " (", psk ? "WPA2-PSK" : "open", ")");
        return true;
    }

    // Drain async events from the multicast socket and advance the state machine.
    void pump()
    {
        if (_event_fd < 0)
            return;
        g_active_sta = &this;
        scope(exit) g_active_sta = null;

        ubyte[8192] buf = void;
        while (true)
        {
            ptrdiff_t n = recv(_event_fd, buf.ptr, buf.length, 0);
            if (n <= 0)
                break;

            const(ubyte)[] data = buf[0 .. cast(size_t)n];
            while (data.length >= nlmsghdr.sizeof)
            {
                const nlmsghdr* mh = cast(const nlmsghdr*)data.ptr;
                uint len = mh.nlmsg_len;
                if (len < nlmsghdr.sizeof || len > data.length)
                    break;
                if (mh.nlmsg_type == _family_id && len >= nlmsghdr.sizeof + genlmsghdr.sizeof)
                {
                    const genlmsghdr* gh = cast(const genlmsghdr*)(data.ptr + nlmsghdr.sizeof);
                    handle_event(gh.cmd, data[nlmsghdr.sizeof + genlmsghdr.sizeof .. len]);
                }
                uint aligned = (len + 3) & ~3u;
                if (aligned >= data.length)
                    break;
                data = data[aligned .. $];
            }
        }
    }

    // Feed a received 802.1X payload (ethernet header already stripped).
    void on_eapol(const(ubyte)[] payload)
    {
        g_active_sta = &this;
        scope(exit) g_active_sta = null;
        _supp.receive_eapol(payload);
    }

    // NL80211_CMD_GET_STATION -> signal strength, while connected.
    void refresh_signal()
    {
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST, ++_seq, NL80211_CMD_GET_STATION);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_MAC, _bssid.b[]);

        ubyte[4096] reply = void;
        size_t n;
        if (!nl_request(_cmd_fd, b, reply[], n))
            return;

        const nlmsghdr* mh = cast(const nlmsghdr*)reply.ptr;
        if (n < nlmsghdr.sizeof + genlmsghdr.sizeof || mh.nlmsg_len > n)
            return;
        const(ubyte)[] attrs = reply[nlmsghdr.sizeof + genlmsghdr.sizeof .. mh.nlmsg_len];
        const(ubyte)[] sta_info = find_attr(attrs, NL80211_ATTR_STA_INFO);
        if (sta_info.length == 0)
            return;
        const(ubyte)[] sig = find_attr(sta_info, NL80211_STA_INFO_SIGNAL);
        if (sig.length >= 1)
            _rssi = cast(byte)sig[0];   // s8 dBm
    }

private:

    int _cmd_fd = -1;
    int _event_fd = -1;
    ushort _family_id;
    uint _ifindex;
    ubyte[6] _own_mac;
    RawAdapter* _raw;

    WpaStaSupplicant _supp;
    StaState _state;
    MACAddress _bssid;
    int _rssi;
    uint _freq;
    ushort _last_reason;
    uint _seq;

    void close_fds()
    {
        if (_cmd_fd >= 0)   { posix_close(_cmd_fd);   _cmd_fd = -1; }
        if (_event_fd >= 0) { posix_close(_event_fd); _event_fd = -1; }
    }

    void handle_event(ubyte cmd, const(ubyte)[] attrs)
    {
        switch (cmd)
        {
            case NL80211_CMD_CONNECT:
                ushort status = 0xFFFF;
                const(ubyte)[] sc = find_attr(attrs, NL80211_ATTR_STATUS_CODE);
                if (sc.length >= 2)
                    status = *cast(const(ushort)*)sc.ptr;
                const(ubyte)[] mac = find_attr(attrs, NL80211_ATTR_MAC);
                if (status == 0)
                {
                    if (mac.length >= 6)
                        _bssid.b[] = mac[0 .. 6];
                    const(ubyte)[] fr = find_attr(attrs, NL80211_ATTR_WIPHY_FREQ);
                    if (fr.length >= 4)
                        _freq = *cast(const(uint)*)fr.ptr;
                    log_info("wifi.sta", "associated bssid=", _bssid, " freq=", _freq);
                    _state = StaState.keying;
                    ubyte[6] ap = _bssid.b;
                    _supp.associated(ap);   // open: completes now; PSK: waits for msg1
                }
                else
                {
                    log_warning("wifi.sta", "association failed (status=", status, ")");
                    _last_reason = status;
                    _state = StaState.failed;
                }
                break;

            case NL80211_CMD_DISCONNECT:
            case NL80211_CMD_DEAUTHENTICATE:
                if (_state == StaState.connecting || _state == StaState.keying || _state == StaState.connected)
                {
                    ushort reason;
                    const(ubyte)[] rc = find_attr(attrs, NL80211_ATTR_REASON_CODE);
                    if (rc.length >= 2)
                        reason = *cast(const(ushort)*)rc.ptr;
                    log_info("wifi.sta", "disconnected (reason=", reason, ")");
                    _supp.disconnected(reason);
                    _last_reason = reason;
                    _state = StaState.disconnected;
                }
                break;

            default:
                break;
        }
    }

    bool new_key(uint key_type, ubyte idx, const(ubyte)[] key, const(ubyte)[] rsc, const(ubyte)[] addr)
    {
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_NEW_KEY);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_KEY_DATA, key);
        b.put_u32(NL80211_ATTR_KEY_CIPHER, rsn_cipher_ccmp);
        b.put_u8(NL80211_ATTR_KEY_IDX, idx);
        if (rsc.length)
            b.put_bytes(NL80211_ATTR_KEY_SEQ, rsc);
        if (addr.length >= 6)
            b.put_bytes(NL80211_ATTR_MAC, addr[0 .. 6]);
        b.put_u32(NL80211_ATTR_KEY_TYPE, key_type);
        return nl_ack(_cmd_fd, b, key_type == NL80211_KEYTYPE_PAIRWISE ? "NEW_KEY/pairwise" : "NEW_KEY/group");
    }

    void port_authorized()
    {
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_PORT_AUTHORIZED);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_MAC, _bssid.b[]);
        nl_ack(_cmd_fd, b, "PORT_AUTHORIZED", true);   // best-effort: key install already opens the port; EOPNOTSUPP on brcmfmac
    }

    void disconnect_kernel()
    {
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_DISCONNECT);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        nl_ack(_cmd_fd, b, "DISCONNECT");
    }

    // --- supplicant hook bridges (dispatch through g_active_sta) ---

    static bool hook_send_eapol(const(ubyte)[] eapol)
    {
        Nl80211Sta* s = g_active_sta;
        if (s is null || s._raw is null)
            return false;
        ubyte[14 + 256] frame = void;
        if (eapol.length + 14 > frame.length)
            return false;
        frame[0 .. 6]   = s._bssid.b[];
        frame[6 .. 12]  = s._own_mac[];
        frame[12]       = 0x88;
        frame[13]       = 0x8e;
        frame[14 .. 14 + eapol.length] = eapol[];
        return s._raw.send(frame[0 .. 14 + eapol.length]);
    }

    static bool hook_install_pairwise(const(ubyte)[] tk, const(ubyte)[] rsc)
    {
        Nl80211Sta* s = g_active_sta;
        if (s is null)
            return false;
        return s.new_key(NL80211_KEYTYPE_PAIRWISE, 0, tk, rsc, s._bssid.b[]);
    }

    static bool hook_install_group(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
    {
        Nl80211Sta* s = g_active_sta;
        if (s is null)
            return false;
        return s.new_key(NL80211_KEYTYPE_GROUP, key_idx, gtk, rsc, null);
    }

    static bool hook_auth_done(ushort reason)
    {
        Nl80211Sta* s = g_active_sta;
        if (s is null)
            return false;
        if (reason == 0)
        {
            s.port_authorized();
            s._state = StaState.connected;
            log_info("wifi.sta", "4-way complete; link authorized");
        }
        else
        {
            s._last_reason = reason;
            s._state = StaState.failed;
            log_warning("wifi.sta", "handshake failed (reason=", reason, ")");
        }
        return true;
    }
}
