module driver.windows.wlanapi;

version (Windows):

import urt.log;
import urt.internal.sys.windows;

nothrow @nogc:


// ---------------------------------------------------------------------------
// Raw wlanapi.dll bindings (subset). Dynamically loaded so we can degrade
// gracefully if the WLAN service isn't installed/running.
// ---------------------------------------------------------------------------

struct GUID
{
    uint   Data1;
    ushort Data2;
    ushort Data3;
    ubyte[8] Data4;
}

enum WLAN_API_VERSION_2_0 = 0x00000002u;
enum DOT11_SSID_MAX_LENGTH = 32;

struct DOT11_SSID
{
    uint uSSIDLength;
    ubyte[DOT11_SSID_MAX_LENGTH] ucSSID;
}

alias DOT11_MAC_ADDRESS = ubyte[6];

enum DOT11_BSS_TYPE : uint
{
    infrastructure = 1,
    independent    = 2,
    any            = 3,
}

enum DOT11_PHY_TYPE : uint
{
    unknown = 0,
}

enum WLAN_INTERFACE_STATE : uint
{
    not_ready,
    connected,
    ad_hoc_network_formed,
    disconnecting,
    disconnected,
    associating,
    discovering,
    authenticating,
}

enum WLAN_CONNECTION_MODE : uint
{
    profile,
    temporary_profile,
    discovery_secure,
    discovery_unsecure,
    auto_,
    invalid,
}

enum WLAN_INTF_OPCODE : uint
{
    autoconf_start              = 0x00000000,
    current_connection          = 0x00000007,
    channel_number              = 0x00000008,
    statistics                  = 0x0000000C,
    rssi                        = 0x0000000D,
    radio_state                 = 0x0000000F,
    interface_state             = 0x00000001,
}

enum WLAN_OPCODE_VALUE_TYPE : uint
{
    query_only,
    set_by_group_policy,
    set_by_user,
    invalid,
}

struct WLAN_INTERFACE_INFO
{
    GUID InterfaceGuid;
    wchar[256] strInterfaceDescription;
    WLAN_INTERFACE_STATE isState;
}

struct WLAN_INTERFACE_INFO_LIST
{
    uint dwNumberOfItems;
    uint dwIndex;
    WLAN_INTERFACE_INFO[1] InterfaceInfo;   // actually [dwNumberOfItems]
}

struct WLAN_ASSOCIATION_ATTRIBUTES
{
    DOT11_SSID         dot11Ssid;
    DOT11_BSS_TYPE     dot11BssType;
    DOT11_MAC_ADDRESS  dot11Bssid;
    DOT11_PHY_TYPE     dot11PhyType;
    uint               uDot11PhyIndex;
    uint               wlanSignalQuality;   // 0..100
    uint               ulRxRate;            // kbps
    uint               ulTxRate;            // kbps
}

struct WLAN_SECURITY_ATTRIBUTES
{
    int  bSecurityEnabled;
    int  bOneXEnabled;
    uint dot11AuthAlgorithm;
    uint dot11CipherAlgorithm;
}

struct WLAN_CONNECTION_ATTRIBUTES
{
    WLAN_INTERFACE_STATE         isState;
    WLAN_CONNECTION_MODE         wlanConnectionMode;
    wchar[256]                   strProfileName;
    WLAN_ASSOCIATION_ATTRIBUTES  wlanAssociationAttributes;
    WLAN_SECURITY_ATTRIBUTES     wlanSecurityAttributes;
}

extern(Windows) uint function(uint, void*, uint*, void**) nothrow @nogc WlanOpenHandle;
extern(Windows) uint function(void*, void*) nothrow @nogc WlanCloseHandle;
extern(Windows) uint function(void*, void*, WLAN_INTERFACE_INFO_LIST**) nothrow @nogc WlanEnumInterfaces;
extern(Windows) uint function(void*, const(GUID)*, WLAN_INTF_OPCODE, void*, uint*, void**, WLAN_OPCODE_VALUE_TYPE*) nothrow @nogc WlanQueryInterface;
extern(Windows) void function(void*) nothrow @nogc WlanFreeMemory;

bool wlanapi_loaded() => _wlanapi !is null;

private __gshared HMODULE _wlanapi;

pragma(crt_constructor)
void crt_bootup_wlanapi()
{
    HMODULE lib = LoadLibraryA("wlanapi.dll");
    if (lib is null)
    {
        writeWarning("wlanapi.dll not available; wifi interface state will be limited.");
        return;
    }

    WlanOpenHandle     = cast(typeof(WlanOpenHandle))    GetProcAddress(lib, "WlanOpenHandle");
    WlanCloseHandle    = cast(typeof(WlanCloseHandle))   GetProcAddress(lib, "WlanCloseHandle");
    WlanEnumInterfaces = cast(typeof(WlanEnumInterfaces))GetProcAddress(lib, "WlanEnumInterfaces");
    WlanQueryInterface = cast(typeof(WlanQueryInterface))GetProcAddress(lib, "WlanQueryInterface");
    WlanFreeMemory     = cast(typeof(WlanFreeMemory))    GetProcAddress(lib, "WlanFreeMemory");

    if (!WlanOpenHandle || !WlanCloseHandle || !WlanEnumInterfaces || !WlanQueryInterface || !WlanFreeMemory)
    {
        writeWarning("wlanapi.dll missing required exports.");
        FreeLibrary(lib);
        return;
    }
    _wlanapi = lib;
}


// ---------------------------------------------------------------------------
// Higher-level helper. One per WindowsWifiRadio.
// ---------------------------------------------------------------------------

struct WlanClient
{
nothrow @nogc:

    bool is_open() const pure
        => _handle !is null;

    bool open()
    {
        if (_handle !is null)
            return true;
        if (!wlanapi_loaded())
            return false;
        uint negotiated;
        uint r = WlanOpenHandle(WLAN_API_VERSION_2_0, null, &negotiated, &_handle);
        if (r != 0)
        {
            writeError("WlanOpenHandle failed: ", r);
            _handle = null;
            return false;
        }
        return true;
    }

    void close()
    {
        if (_handle !is null)
        {
            WlanCloseHandle(_handle, null);
            _handle = null;
        }
    }

    // Match an npcap-style adapter name like "\Device\NPF_{GUID}" against the
    // OS WLAN interface list. Returns true (and populates `out_guid`) if a
    // matching wifi interface is found.
    bool find_interface_for_adapter(const(char)[] adapter_name, ref GUID out_guid)
    {
        if (_handle is null)
            return false;

        // extract the {...} substring
        ptrdiff_t lb = -1, rb = -1;
        foreach (i, c; adapter_name)
        {
            if (c == '{') lb = i;
            else if (c == '}') { rb = i; break; }
        }
        if (lb < 0 || rb <= lb + 1)
            return false;
        const(char)[] guid_str = adapter_name[lb + 1 .. rb];

        GUID parsed;
        if (!parse_guid_string(guid_str, parsed))
            return false;

        WLAN_INTERFACE_INFO_LIST* list;
        if (WlanEnumInterfaces(_handle, null, &list) != 0)
            return false;
        scope(exit) WlanFreeMemory(list);

        WLAN_INTERFACE_INFO* arr = list.InterfaceInfo.ptr;
        foreach (i; 0 .. list.dwNumberOfItems)
        {
            if (guids_equal(arr[i].InterfaceGuid, parsed))
            {
                out_guid = arr[i].InterfaceGuid;
                return true;
            }
        }
        return false;
    }

    bool query_current_connection(ref const GUID iface_guid, out WLAN_CONNECTION_ATTRIBUTES out_attrs)
    {
        if (_handle is null)
            return false;
        WLAN_CONNECTION_ATTRIBUTES* data;
        uint size;
        WLAN_OPCODE_VALUE_TYPE vt;
        uint r = WlanQueryInterface(_handle, &iface_guid, WLAN_INTF_OPCODE.current_connection,
                                    null, &size, cast(void**)&data, &vt);
        if (r != 0 || data is null)
            return false;
        scope(exit) WlanFreeMemory(data);
        out_attrs = *data;
        return true;
    }

    bool query_channel(ref const GUID iface_guid, out uint channel)
    {
        if (_handle is null)
            return false;
        uint* data;
        uint size;
        WLAN_OPCODE_VALUE_TYPE vt;
        uint r = WlanQueryInterface(_handle, &iface_guid, WLAN_INTF_OPCODE.channel_number,
                                    null, &size, cast(void**)&data, &vt);
        if (r != 0 || data is null)
            return false;
        scope(exit) WlanFreeMemory(data);
        channel = *data;
        return true;
    }

    bool query_rssi(ref const GUID iface_guid, out int rssi_dbm)
    {
        if (_handle is null)
            return false;
        int* data;
        uint size;
        WLAN_OPCODE_VALUE_TYPE vt;
        uint r = WlanQueryInterface(_handle, &iface_guid, WLAN_INTF_OPCODE.rssi,
                                    null, &size, cast(void**)&data, &vt);
        if (r != 0 || data is null)
            return false;
        scope(exit) WlanFreeMemory(data);
        rssi_dbm = *data;
        return true;
    }

private:
    void* _handle;
}


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool guids_equal(ref const GUID a, ref const GUID b) pure
{
    return a.Data1 == b.Data1 && a.Data2 == b.Data2 && a.Data3 == b.Data3 && a.Data4 == b.Data4;
}

// Parse the standard 8-4-4-4-12 GUID form (case-insensitive, no braces).
bool parse_guid_string(const(char)[] s, ref GUID g) pure
{
    if (s.length != 36) return false;
    if (s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-') return false;

    uint d1; if (!parse_hex_uint(s[0 .. 8], d1)) return false; g.Data1 = d1;
    uint d2; if (!parse_hex_uint(s[9 .. 13], d2)) return false; g.Data2 = cast(ushort)d2;
    uint d3; if (!parse_hex_uint(s[14 .. 18], d3)) return false; g.Data3 = cast(ushort)d3;

    uint b;
    if (!parse_hex_uint(s[19 .. 21], b)) return false; g.Data4[0] = cast(ubyte)b;
    if (!parse_hex_uint(s[21 .. 23], b)) return false; g.Data4[1] = cast(ubyte)b;
    foreach (i; 0 .. 6)
    {
        if (!parse_hex_uint(s[24 + i*2 .. 26 + i*2], b)) return false;
        g.Data4[2 + i] = cast(ubyte)b;
    }
    return true;
}

private bool parse_hex_uint(const(char)[] s, out uint value) pure
{
    uint v = 0;
    foreach (c; s)
    {
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return false;
    }
    value = v;
    return true;
}
