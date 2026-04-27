module manager.os.iphlpapi;

version (Windows):

import urt.inet;
import urt.log;
import urt.time;

import router.iface : BaseInterface;
import router.status;

import urt.internal.sys.windows;
import urt.internal.sys.windows.winsock2 : AF_INET, AF_INET6, sockaddr_in, sockaddr_in6;

nothrow @nogc:


enum
{
    ERROR_SUCCESS         = 0,
    ERROR_BUFFER_OVERFLOW = 111,
    ERROR_NO_DATA         = 232,
}

enum AF_UNSPEC = 0;

enum
{
    GAA_FLAG_SKIP_UNICAST       = 0x0001,
    GAA_FLAG_SKIP_ANYCAST       = 0x0002,
    GAA_FLAG_SKIP_MULTICAST     = 0x0004,
    GAA_FLAG_SKIP_DNS_SERVER    = 0x0008,
    GAA_FLAG_INCLUDE_PREFIX     = 0x0010,
    GAA_FLAG_SKIP_FRIENDLY_NAME = 0x0020,
}

enum IF_OPER_STATUS : uint
{
    Up             = 1,
    Down           = 2,
    Testing        = 3,
    Unknown        = 4,
    Dormant        = 5,
    NotPresent     = 6,
    LowerLayerDown = 7,
}

struct SOCKET_ADDRESS
{
    void* lpSockaddr;       // sockaddr*
    int iSockaddrLength;
}

align(8) struct IP_ADAPTER_UNICAST_ADDRESS_LH
{
    union {
        ulong Alignment;
        struct {
            uint Length;
            uint Flags;
        }
    }
    IP_ADAPTER_UNICAST_ADDRESS_LH* Next;
    SOCKET_ADDRESS Address;
    uint PrefixOrigin;
    uint SuffixOrigin;
    uint DadState;
    uint ValidLifetime;
    uint PreferredLifetime;
    uint LeaseLifetime;
    ubyte OnLinkPrefixLength;
    // further fields unused
}

align(8) struct IP_ADAPTER_ADDRESSES_LH
{
    union {
        ulong Alignment;
        struct {
            uint Length;
            uint IfIndex;
        }
    }
    IP_ADAPTER_ADDRESSES_LH* Next;
    char* AdapterName;                  // ANSI; "{GUID}" form
    IP_ADAPTER_UNICAST_ADDRESS_LH* FirstUnicastAddress;
    void* FirstAnycastAddress;
    void* FirstMulticastAddress;
    void* FirstDnsServerAddress;
    wchar* DnsSuffix;
    wchar* Description;
    wchar* FriendlyName;
    ubyte[8] PhysicalAddress;           // MAX_ADAPTER_ADDRESS_LENGTH
    uint PhysicalAddressLength;
    uint Flags;
    uint Mtu;
    uint IfType;
    IF_OPER_STATUS OperStatus;
    uint Ipv6IfIndex;
    uint[16] ZoneIndices;
    void* FirstPrefix;
    ulong TransmitLinkSpeed;
    ulong ReceiveLinkSpeed;
    // ... further OS fields not used here
}

struct SOCKADDR_INET
{
    union
    {
        sockaddr_in Ipv4;
        sockaddr_in6 Ipv6;
        ushort si_family;
    }
}

struct IP_ADDRESS_PREFIX
{
    SOCKADDR_INET Prefix;
    ubyte PrefixLength;
}

struct MIB_IPFORWARD_ROW2
{
    ulong InterfaceLuid;
    uint InterfaceIndex;
    IP_ADDRESS_PREFIX DestinationPrefix;
    SOCKADDR_INET NextHop;
    ubyte SitePrefixLength;
    uint ValidLifetime;
    uint PreferredLifetime;
    uint Metric;
    uint Protocol;
    ubyte Loopback;
    ubyte AutoconfigureAddress;
    ubyte Publish;
    ubyte Immortal;
    uint Age;
    uint Origin;
}

struct MIB_IPFORWARD_TABLE2
{
    uint NumEntries;
    MIB_IPFORWARD_ROW2[1] Table;
}

extern(Windows) uint function(uint Family, uint Flags, void* Reserved, IP_ADAPTER_ADDRESSES_LH* AdapterAddresses, uint* SizeOfBuffer) nothrow @nogc GetAdaptersAddresses;
extern(Windows) uint function(uint Family, MIB_IPFORWARD_TABLE2** Table) nothrow @nogc GetIpForwardTable2;
extern(Windows) void function(void* Memory) nothrow @nogc FreeMibTable;

private __gshared HMODULE _iphlpapi;

pragma(crt_constructor)
void crt_bootup()
{
    _iphlpapi = LoadLibraryA("iphlpapi.dll");
    if (!_iphlpapi)
    {
        writeWarning("Failed to load iphlpapi.dll; OS adapter info unavailable.");
        return;
    }
    GetAdaptersAddresses = cast(typeof(GetAdaptersAddresses))GetProcAddress(_iphlpapi, "GetAdaptersAddresses");
    GetIpForwardTable2   = cast(typeof(GetIpForwardTable2))GetProcAddress(_iphlpapi, "GetIpForwardTable2");
    FreeMibTable         = cast(typeof(FreeMibTable))GetProcAddress(_iphlpapi, "FreeMibTable");
}

bool iphlpapi_loaded()
    => GetAdaptersAddresses !is null;

struct OSAdapterInfo
{
    bool valid;
    ubyte[6] mac;
    ubyte mac_len;
    uint mtu;
    ConnectionStatus connection = ConnectionStatus.unknown;
    ulong tx_link_speed;    // bps
    ulong rx_link_speed;    // bps
}

private ConnectionStatus map_oper_status(IF_OPER_STATUS s) pure
{
    final switch (s) with (IF_OPER_STATUS)
    {
        case Up:                return ConnectionStatus.connected;
        case Down:              return ConnectionStatus.disconnected;
        case LowerLayerDown:    return ConnectionStatus.disconnected;
        case NotPresent:        return ConnectionStatus.disconnected;
        case Dormant:           return ConnectionStatus.disconnected;
        case Testing:           return ConnectionStatus.unknown;
        case Unknown:           return ConnectionStatus.unknown;
    }
}

bool query_adapter(const(char)[] adapter_name, out OSAdapterInfo info)
{
    if (!iphlpapi_loaded())
        return false;

    const(char)[] guid = parse_npf_guid(adapter_name);
    if (guid.length == 0)
        return false;

    align(8) ubyte[16*1024] buf = void;
    uint size = buf.sizeof;
    uint flags = GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_ANYCAST |
                    GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER |
                    GAA_FLAG_SKIP_FRIENDLY_NAME;

    auto first = cast(IP_ADAPTER_ADDRESSES_LH*)buf.ptr;
    uint rc = GetAdaptersAddresses(AF_UNSPEC, flags, null, first, &size);
    if (rc != ERROR_SUCCESS)
        return false;

    for (auto p = first; p !is null; p = p.Next)
    {
        if (p.AdapterName is null)
            continue;
        size_t len = 0;
        while (p.AdapterName[len] != 0)
            ++len;
        if (p.AdapterName[0 .. len] != guid)
            continue;

        if (p.PhysicalAddressLength >= 6)
        {
            info.mac[] = p.PhysicalAddress[0 .. 6];
            info.mac_len = 6;
        }
        info.mtu            = p.Mtu;
        info.connection     = map_oper_status(p.OperStatus);
        // 0xFFFFFFFFFFFFFFFF is iphlpapi's "unknown link speed" sentinel.
        info.tx_link_speed  = p.TransmitLinkSpeed == ulong.max ? 0 : p.TransmitLinkSpeed;
        info.rx_link_speed  = p.ReceiveLinkSpeed == ulong.max ? 0 : p.ReceiveLinkSpeed;
        info.valid          = true;
        return true;
    }
    return false;
}

bool enumerate_os_adapters(scope void delegate(IP_ADAPTER_ADDRESSES_LH*) nothrow @nogc cb)
{
    if (!iphlpapi_loaded())
        return false;

    align(8) ubyte[32*1024] buf = void;
    uint size = buf.sizeof;
    uint flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                 GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME;
    auto first = cast(IP_ADAPTER_ADDRESSES_LH*)buf.ptr;
    if (GetAdaptersAddresses(AF_UNSPEC, flags, null, first, &size) != ERROR_SUCCESS)
        return false;

    for (auto p = first; p !is null; p = p.Next)
        cb(p);
    return true;
}

const(char)[] adapter_guid(const IP_ADAPTER_ADDRESSES_LH* p) pure
{
    if (p is null || p.AdapterName is null)
        return null;
    size_t len = 0;
    while (p.AdapterName[len] != 0)
        ++len;
    return p.AdapterName[0 .. len];
}

struct IpForwardRowV4
{
    IPNetworkAddress destination;
    IPAddr gateway;         // 0.0.0.0 means on-link
    uint if_index;
    uint metric;
    bool is_loopback;
}

bool enumerate_ipv4_routes(scope void delegate(ref const IpForwardRowV4) nothrow @nogc cb)
{
    if (GetIpForwardTable2 is null || FreeMibTable is null)
        return false;

    MIB_IPFORWARD_TABLE2* table;
    if (GetIpForwardTable2(AF_INET, &table) != ERROR_SUCCESS)
        return false;
    scope(exit) FreeMibTable(table);

    foreach (i; 0 .. table.NumEntries)
    {
        const(MIB_IPFORWARD_ROW2)* row = &table.Table.ptr[i];
        if (row.DestinationPrefix.Prefix.si_family != AF_INET)
            continue;

        IpForwardRowV4 r;
        r.destination.addr.address  = row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr;
        r.destination.prefix_len    = row.DestinationPrefix.PrefixLength;
        r.gateway.address           = row.NextHop.Ipv4.sin_addr.s_addr;
        r.if_index                  = row.InterfaceIndex;
        r.metric                    = row.Metric;
        r.is_loopback               = row.Loopback != 0;

        cb(r);
    }
    return true;
}

const(char)[] parse_npf_guid(const(char)[] adapter_name) pure
{
    enum prefix = `\Device\NPF_`;
    if (adapter_name.length <= prefix.length)
        return null;
    if (adapter_name[0 .. prefix.length] != prefix)
        return null;
    return adapter_name[prefix.length .. $];
}

// Max L2 MTU we'll declare on Windows. 9000 is the practical jumbo ceiling
// that essentially any modern Windows NIC driver accepts; going higher (e.g.
// 9216) is rejected by some drivers. There's no userland API to query the
// adapter's true max, so this is a safe upper bound.
enum WINDOWS_MAX_L2MTU = 9000;

enum AdapterChange : uint
{
    none      = 0,
    mtu       = 1 << 0,
    max_mtu   = 1 << 1,
    connected = 1 << 2,
    tx_speed  = 1 << 3,
    rx_speed  = 1 << 4,
}

AdapterChange apply_os_adapter_info(BaseInterface iface, ref ushort l2mtu, ref ushort max_l2mtu, ref IfStatus status, ref const OSAdapterInfo info)
{
    import router.iface.mac : MACAddress;

    AdapterChange changed;

//    if (info.mac_len == 6)
//    {
//        MACAddress new_mac = MACAddress(info.mac);
//        if (new_mac != iface.mac)
//        {
//            iface.remove_address(iface.mac);
//            iface.mac = new_mac;
//            iface.add_address(iface.mac, iface);
//        }
//    }

    if (info.mtu != 0 && info.mtu != l2mtu)
    {
        l2mtu = cast(ushort)info.mtu;
        changed |= AdapterChange.mtu;
    }
    if (max_l2mtu != WINDOWS_MAX_L2MTU)
    {
        max_l2mtu = WINDOWS_MAX_L2MTU;
        changed |= AdapterChange.max_mtu;
    }

    if (status.connected != info.connection)
    {
        status.connected = info.connection;
        changed |= AdapterChange.connected;
    }

    if (status.tx_link_speed != info.tx_link_speed)
    {
        status.tx_link_speed = info.tx_link_speed;
        changed |= AdapterChange.tx_speed;
    }
    if (status.rx_link_speed != info.rx_link_speed)
    {
        status.rx_link_speed = info.rx_link_speed;
        changed |= AdapterChange.rx_speed;
    }

    return changed;
}
