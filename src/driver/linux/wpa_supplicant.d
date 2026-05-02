module driver.linux.wpa_supplicant;

version (linux):

import urt.result;

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
