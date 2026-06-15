module driver.linux.nl80211_ap;

// =====================================================================
// Native Linux AP: drives nl80211 directly and runs the WPA2-PSK 4-way
// authenticator in-process via urt.driver.wpa, replacing hostapd.
//
// Targets the FullMAC model (firmware/in-driver MLME): the driver handles
// auth/assoc and reports an already-associated station to userspace via
// NL80211_CMD_NEW_STATION; we run the 4-way + install keys + authorize. This
// is the same shape WpaApAuthenticator drives on BL808. SoftMAC (mac80211)
// AP needs userspace MLME (auth/assoc frame handling) -- out of scope here;
// hostapd remains the SoftMAC backend.
//
// Flow:
//   1. open()  -- resolve ifindex/MAC, command + event sockets (mlme group).
//   2. start() -- configure the authenticator (PMK + GTK), build a beacon
//                 (head/tail), NL80211_CMD_START_AP with privacy + control
//                 port so EAPOL routes to us over the netdev.
//   3. pump()  -- NEW_STATION -> station_join (sends msg 1); DEL_STATION ->
//                 station_leave.
//   4. EAPOL   -- runs over the netdev (AF_PACKET, owned by LinuxAP). on_eapol
//                 feeds RX into the authenticator; the send_eapol hook TXes via
//                 the same RawAdapter. Keys install with NL80211_CMD_NEW_KEY,
//                 the station is authorized with NL80211_CMD_SET_STATION.
//
// The shared generic-netlink toolkit + WPA key/cipher ABI live in
// driver.linux.nl80211; the 4-way itself lives in urt.driver.wpa.
// =====================================================================

version (linux):
version (WifiApKernel):

import urt.log;
import urt.mem.temp;
import urt.result;
import urt.string;

import urt.internal.sys.posix : posix_close = close;

import urt.driver.wpa.authenticator;

import driver.linux.nl80211;   // shared genl/netlink ABI + toolkit + WPA constants
import driver.linux.raw : RawAdapter, ioctl, ifreq, SIOCGIFHWADDR, IFNAMSIZ;

import router.iface.mac;

nothrow @nogc:


// AP-specific commands/attrs (shared key/cipher/auth ABI lives in nl80211).
enum NL80211_CMD_START_AP    = 15;
enum NL80211_CMD_SET_STATION = 18;
enum NL80211_CMD_NEW_STATION = 19;
enum NL80211_CMD_DEL_STATION = 20;

enum NL80211_ATTR_BEACON_INTERVAL = 12;
enum NL80211_ATTR_DTIM_PERIOD     = 13;
enum NL80211_ATTR_BEACON_HEAD     = 14;
enum NL80211_ATTR_BEACON_TAIL     = 15;
enum NL80211_ATTR_STA_FLAGS2      = 67;
enum NL80211_ATTR_PRIVACY         = 70;
enum NL80211_ATTR_HIDDEN_SSID     = 126;
enum NL80211_ATTR_CHANNEL_WIDTH   = 159;

enum NL80211_HIDDEN_SSID_ZERO_LEN = 1;

enum NL80211_CHAN_WIDTH_20_NOHT = 0;
enum NL80211_STA_FLAG_AUTHORIZED = 1;   // bit index; mask/set use (1 << flag)


enum ApState : ubyte
{
    idle,
    running,
    failed,
}


// The authenticator hooks are plain function pointers (no context), so they
// dispatch through this. Set transiently around every authenticator entry
// point; the main loop is single-threaded and hooks fire synchronously.
private __gshared Nl80211Ap* g_active_ap;


struct Nl80211Ap
{
nothrow @nogc:

    bool valid() const pure   => _cmd_fd >= 0;
    bool running() const pure  => _state == ApState.running;
    bool failed() const pure   => _state == ApState.failed;

    const(char)[] status_message() const pure
    {
        final switch (_state) with (ApState)
        {
            case idle:    return "idle";
            case running: return "running";
            case failed:  return "failed";
        }
    }

    // Frontend frame-loop bridge: feed EAPOL into the authenticator.
    bool consume_eapol(const(ubyte)[6] src, const(ubyte)[] payload)
    {
        on_eapol(src, payload);
        return true;
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
        // Station add/remove notifications arrive on the MLME group.
        if (mlme_grp)
            setsockopt(_event_fd, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &mlme_grp, mlme_grp.sizeof);

        _state = ApState.idle;
        return StringResult.success;
    }

    void close()
    {
        if (_state == ApState.running)
            stop();
        close_fds();
        _state = ApState.idle;
        _raw = null;
    }

    // Start the BSS. password == "" / open == true -> open network (no
    // authenticator). freq is the channel centre frequency (MHz).
    bool start(const(char)[] ssid, const(char)[] password, uint freq, ubyte channel, bool hidden)
    {
        if (ssid.length == 0 || ssid.length > 32)
        {
            log_warning("wifi.ap", "invalid SSID");
            _state = ApState.failed;
            return false;
        }

        _secured = password.length != 0;

        if (_secured)
        {
            g_active_ap = &this;
            scope(exit) g_active_ap = null;

            _auth.hooks.send_eapol         = &hook_send_eapol;
            _auth.hooks.install_pairwise_key = &hook_install_pairwise;
            _auth.hooks.install_group_key  = &hook_install_group;
            _auth.hooks.handshake_complete = &hook_complete;
            if (!_auth.configure(password, ssid, _own_mac, wpa2_psk_ccmp_rsn_ie[]))
            {
                log_warning("wifi.ap", "authenticator configure failed");
                _state = ApState.failed;
                return false;
            }
        }

        ubyte[256] head = void, tail = void;
        size_t head_len = build_beacon_head(head[], _own_mac, ssid, channel, _secured);
        size_t tail_len = build_beacon_tail(tail[], _secured);

        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_START_AP);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_BEACON_HEAD, head[0 .. head_len]);
        b.put_bytes(NL80211_ATTR_BEACON_TAIL, tail[0 .. tail_len]);
        b.put_u32(NL80211_ATTR_BEACON_INTERVAL, 100);
        b.put_u32(NL80211_ATTR_DTIM_PERIOD, 2);
        b.put_bytes(NL80211_ATTR_SSID, cast(const(ubyte)[])ssid);
        if (hidden)
            b.put_u32(NL80211_ATTR_HIDDEN_SSID, NL80211_HIDDEN_SSID_ZERO_LEN);
        if (freq)
        {
            b.put_u32(NL80211_ATTR_WIPHY_FREQ, freq);
            b.put_u32(NL80211_ATTR_CHANNEL_WIDTH, NL80211_CHAN_WIDTH_20_NOHT);
        }
        b.put_u32(NL80211_ATTR_AUTH_TYPE, NL80211_AUTHTYPE_OPEN_SYSTEM);
        if (_secured)
        {
            b.put_flag(NL80211_ATTR_PRIVACY);
            b.put_flag(NL80211_ATTR_CONTROL_PORT);   // userspace owns EAPOL (4-way over the netdev)
            b.put_u32(NL80211_ATTR_WPA_VERSIONS, NL80211_WPA_VERSION_2);
            b.put_u32(NL80211_ATTR_CIPHER_SUITES_PAIRWISE, rsn_cipher_ccmp);
            b.put_u32(NL80211_ATTR_CIPHER_SUITE_GROUP, rsn_cipher_ccmp);
            b.put_u32(NL80211_ATTR_AKM_SUITES, rsn_akm_psk);
        }
        if (!nl_ack(_cmd_fd, b, "START_AP"))
        {
            _state = ApState.failed;
            return false;
        }

        _state = ApState.running;
        log_info("wifi.ap", "START_AP ssid='", ssid, "' ch=", channel, " (", _secured ? "WPA2-PSK" : "open", ")");
        return true;
    }

    void stop()
    {
        if (_cmd_fd < 0)
            return;
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_STOP_AP);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        nl_ack(_cmd_fd, b, "STOP_AP", true);
        _state = ApState.idle;
    }

    // Drain async events: station add/remove drive the authenticator.
    void pump()
    {
        if (_event_fd < 0)
            return;
        g_active_ap = &this;
        scope(exit) g_active_ap = null;

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

    // Retransmit pump for outstanding handshake frames.
    void tick()
    {
        if (!_secured)
            return;
        import urt.time : getTime, MonoTime;
        g_active_ap = &this;
        scope(exit) g_active_ap = null;
        _auth.tick((getTime() - MonoTime.init).as!"usecs");
    }

    // Feed a received 802.1X payload from `src` (ethernet header stripped).
    void on_eapol(const(ubyte)[6] src, const(ubyte)[] payload)
    {
        if (!_secured)
            return;
        g_active_ap = &this;
        scope(exit) g_active_ap = null;
        _auth.handle_eapol(src, payload);
    }

private:

    int _cmd_fd = -1;
    int _event_fd = -1;
    ushort _family_id;
    uint _ifindex;
    ubyte[6] _own_mac;
    RawAdapter* _raw;

    WpaApAuthenticator _auth;
    ApState _state;
    bool _secured;
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
            case NL80211_CMD_NEW_STATION:
                if (!_secured)
                    break;
                const(ubyte)[] mac = find_attr(attrs, NL80211_ATTR_MAC);
                if (mac.length >= 6)
                {
                    ubyte[6] sta = mac[0 .. 6];
                    log_info("wifi.ap", "station joined ", MACAddress(sta), "; starting 4-way");
                    _auth.station_join(sta);    // sends msg 1
                }
                break;

            case NL80211_CMD_DEL_STATION:
                const(ubyte)[] dmac = find_attr(attrs, NL80211_ATTR_MAC);
                if (dmac.length >= 6 && _secured)
                {
                    ubyte[6] sta = dmac[0 .. 6];
                    log_info("wifi.ap", "station left ", MACAddress(sta));
                    _auth.station_leave(sta);
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
        // CCMP's PN is 6 bytes; the EAPOL-Key RSC field is 8. Pass only the 6
        // the kernel expects for CCMP, or it rejects the key with -EINVAL.
        if (rsc.length)
            b.put_bytes(NL80211_ATTR_KEY_SEQ, rsc[0 .. rsc.length < 6 ? rsc.length : 6]);
        // Pairwise (and per-station) keys carry the STA MAC + KEY_TYPE. The
        // broadcast GTK omits both (matching hostapd): cfg80211 infers GROUP
        // from the absent MAC, and a KEY_TYPE without a MAC is refused.
        if (addr.length >= 6)
        {
            b.put_bytes(NL80211_ATTR_MAC, addr[0 .. 6]);
            b.put_u32(NL80211_ATTR_KEY_TYPE, key_type);
        }
        return nl_ack(_cmd_fd, b, key_type == NL80211_KEYTYPE_PAIRWISE ? "NEW_KEY/pairwise" : "NEW_KEY/group");
    }

    void set_station_authorized(const(ubyte)[6] sta)
    {
        // nl80211_sta_flag_update { u32 mask; u32 set }, little-endian -- the
        // AUTHORIZED bit (value 2) lives in the low byte of each word.
        enum ubyte authorized_bit = 1 << NL80211_STA_FLAG_AUTHORIZED;
        ubyte[8] flags = 0;
        flags[0] = authorized_bit;   // mask
        flags[4] = authorized_bit;   // set

        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_SET_STATION);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_MAC, sta[]);
        b.put_bytes(NL80211_ATTR_STA_FLAGS2, flags[]);
        nl_ack(_cmd_fd, b, "SET_STATION/authorized", true);   // best-effort; key install opens the port
    }

    void del_station(const(ubyte)[6] sta, ushort reason)
    {
        NlBuilder b;
        b.start(_family_id, NLM_F_REQUEST | NLM_F_ACK, ++_seq, NL80211_CMD_DEL_STATION);
        b.put_u32(NL80211_ATTR_IFINDEX, _ifindex);
        b.put_bytes(NL80211_ATTR_MAC, sta[]);
        if (reason)
            b.put_u16(NL80211_ATTR_REASON_CODE, reason);
        nl_ack(_cmd_fd, b, "DEL_STATION", true);
    }

    // --- 802.11 beacon construction ---

    // Beacon head: mgmt header + fixed params + the IEs that precede the
    // (kernel-inserted) TIM.
    static size_t build_beacon_head(ubyte[] dst, const(ubyte)[6] ap_mac,
                                    const(char)[] ssid, ubyte channel, bool privacy)
    {
        size_t p;
        // 802.11 management header (24 bytes)
        dst[p++] = 0x80; dst[p++] = 0x00;           // frame control: mgmt / beacon
        dst[p++] = 0x00; dst[p++] = 0x00;           // duration
        dst[p .. p + 6] = 0xFF; p += 6;             // addr1 = broadcast
        dst[p .. p + 6] = ap_mac[]; p += 6;         // addr2 = SA = AP
        dst[p .. p + 6] = ap_mac[]; p += 6;         // addr3 = BSSID = AP
        dst[p++] = 0x00; dst[p++] = 0x00;           // sequence control
        // fixed beacon parameters
        dst[p .. p + 8] = 0; p += 8;                // timestamp (set by hw)
        dst[p++] = 0x64; dst[p++] = 0x00;           // beacon interval = 100 TU
        ushort cap = 0x0001 | 0x0020;               // ESS | ShortPreamble
        if (privacy) cap |= 0x0010;                 // Privacy
        dst[p++] = cap & 0xff; dst[p++] = (cap >> 8) & 0xff;
        // SSID IE
        dst[p++] = 0;
        dst[p++] = cast(ubyte)ssid.length;
        dst[p .. p + ssid.length] = cast(const(ubyte)[])ssid; p += ssid.length;
        // Supported rates IE (1,2,5.5,11 basic + 6,9,12,18)
        static immutable ubyte[8] rates = [0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24];
        dst[p++] = 1; dst[p++] = rates.length;
        dst[p .. p + rates.length] = rates[]; p += rates.length;
        // DS parameter set IE (current channel)
        dst[p++] = 3; dst[p++] = 1; dst[p++] = channel;
        return p;
    }

    // Beacon tail: IEs that follow the TIM. ERP + extended rates + (RSN).
    static size_t build_beacon_tail(ubyte[] dst, bool secured)
    {
        size_t p;
        // ERP IE
        dst[p++] = 42; dst[p++] = 1; dst[p++] = 0x00;
        // Extended supported rates IE (24,36,48,54)
        static immutable ubyte[4] ext = [0x30, 0x48, 0x60, 0x6c];
        dst[p++] = 50; dst[p++] = ext.length;
        dst[p .. p + ext.length] = ext[]; p += ext.length;
        // RSN IE
        if (secured)
        {
            dst[p .. p + wpa2_psk_ccmp_rsn_ie.length] = wpa2_psk_ccmp_rsn_ie[];
            p += wpa2_psk_ccmp_rsn_ie.length;
        }
        return p;
    }

    // --- authenticator hook bridges (dispatch through g_active_ap) ---

    static bool hook_send_eapol(const(ubyte)[6] sta, const(ubyte)[] eapol)
    {
        Nl80211Ap* a = g_active_ap;
        if (a is null || a._raw is null)
            return false;
        ubyte[14 + 256] frame = void;
        if (eapol.length + 14 > frame.length)
            return false;
        frame[0 .. 6]  = sta[];
        frame[6 .. 12] = a._own_mac[];
        frame[12]      = 0x88;
        frame[13]      = 0x8e;
        frame[14 .. 14 + eapol.length] = eapol[];
        return a._raw.send(frame[0 .. 14 + eapol.length]);
    }

    static bool hook_install_pairwise(const(ubyte)[6] sta, const(ubyte)[] tk)
    {
        Nl80211Ap* a = g_active_ap;
        if (a is null)
            return false;
        return a.new_key(NL80211_KEYTYPE_PAIRWISE, 0, tk, null, sta[]);
    }

    static bool hook_install_group(const(ubyte)[6] sta, ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
    {
        Nl80211Ap* a = g_active_ap;
        if (a is null)
            return false;
        return a.new_key(NL80211_KEYTYPE_GROUP, key_idx, gtk, rsc, null);
    }

    static void hook_complete(const(ubyte)[6] sta, bool success, ushort reason)
    {
        Nl80211Ap* a = g_active_ap;
        if (a is null)
            return;
        if (success)
        {
            a.set_station_authorized(sta);
            log_info("wifi.ap", "4-way complete for ", MACAddress(sta), "; authorized");
        }
        else
        {
            log_warning("wifi.ap", "4-way failed for ", MACAddress(sta), " (reason=", reason, ")");
            a.del_station(sta, reason ? reason : 1);
        }
    }
}
