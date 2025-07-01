module router.port;

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.string;
import urt.time;

import router.iface.mac;

import manager.plugin;

nothrow @nogc:


struct Port
{
nothrow @nogc:
    String name;
    String type;
    String desc;

    union {
        MACAddress mac;
    }
    ushort mtu;
    ulong txRate, rxRate;

    Array!InetAddress addresses;

    this(String name, String type) nothrow @nogc
    {
        this.name = name.move;
        this.type = type.move;
    }

    this(this) @disable;

    this(Port rh) nothrow @nogc
    {
        this.name = rh.name.move;
        this.type = rh.type.move;
        this.desc = rh.desc.move;
        this.mac = rh.mac;
        this.addresses = rh.addresses.move;
    }

    this(ref Port rh) nothrow @nogc
    {
        this.name = rh.name;
        this.type = rh.type;
        this.desc = rh.desc;
        this.mac = rh.mac;
        this.addresses = rh.addresses;
    }
}


class PortsModule : Module
{
    mixin DeclareModule!"ports";
nothrow @nogc:

    Map!(const(char)[], Port) ports;

    override void init()
    {
        updateTimer.setTimeout(1.seconds);
        update();
    }

    override void update()
    {
        if (updateTimer.expired)
        {
            updateTimer.reset();

            MonoTime start = getTime();
            // scan for hardware changes...
            version (Windows)
            {
                import urt.mem : wcslen;
                import urt.string.uni;

                char[512] tmp = void;

                // enumerate com ports
                HDEVINFO hDevInfo;
                SP_DEVINFO_DATA devInfoData;
                uint i;

                // Get list of present devices for the Ports (COM & LPT) class
                hDevInfo = SetupDiGetClassDevsW(&GUID_DEVCLASS_PORTS, null, null, DIGCF_PRESENT);
                if (hDevInfo == INVALID_HANDLE_VALUE)
                    return;

                for (i = 0; SetupDiEnumDeviceInfo(hDevInfo, i, &devInfoData); i++)
                {
                    HKEY hKey = SetupDiOpenDevRegKey(hDevInfo, &devInfoData, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
                    if (hKey != INVALID_HANDLE_VALUE)
                    {
                        wchar[256] wsBuffer = "\0";
                        uint len = wsBuffer.sizeof;
                        uint type = 0;
                        if (RegQueryValueExW(hKey, "PortName"w.ptr, null, &type, cast(ubyte*)wsBuffer, &len) == ERROR_SUCCESS)
                        {
                            if (wsBuffer[0..3] == "COM")
                            {
                                size_t l = wcslen(wsBuffer.ptr);
                                if (l >= len/2)
                                {
                                    writeWarning("Invalid serial port name!");
                                    continue;
                                }
                                const(char)[] portName = tmp[0 .. wsBuffer[0 .. l].uniConvert(tmp)];

                                Port* port = ports.get(portName);
                                if (!port)
                                {
                                    String name = portName.makeString(defaultAllocator());
                                    port = ports.insert(name[], Port(name.move, StringLit!"serial"));
                                    assert(port, "Failed to insert port into map!?");
                                }

                                if (SetupDiGetDeviceRegistryPropertyW(hDevInfo, &devInfoData, SPDRP_DEVICEDESC, null, cast(ubyte*)wsBuffer, wsBuffer.sizeof, null))
                                {
                                    l = wcslen(wsBuffer.ptr);
                                    port.desc = tmp[0 .. wsBuffer[0 .. l].uniConvert(tmp)].makeString(defaultAllocator());
                                }
                            }
                        }
                        RegCloseKey(hKey);
                    }
                }

                SetupDiDestroyDeviceInfoList(hDevInfo);


                // enumerate network adapters
                ULONG size = 0;
                GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, null, null, &size);
                void[] buffer = defaultAllocator().alloc(size);
                IP_ADAPTER_ADDRESSES* adapters = cast(IP_ADAPTER_ADDRESSES*)buffer.ptr;

                if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, null, adapters, &size) == NO_ERROR)
                {
                    for (IP_ADAPTER_ADDRESSES* a = adapters; a; a = a.Next)
                    {
                        if (a.IfType != 6 && a.IfType != 71)
                            continue;

                        const(char)[] portName = tmp[0 .. a.FriendlyName[0 .. a.FriendlyName.wcslen].uniConvert(tmp)];

                        Port* port = ports.get(portName);
                        if (!port)
                        {
                            String name = portName.makeString(defaultAllocator());
                            String type;
                            switch (a.IfType)
                            {
                                case IFTYPE.ETHERNET_CSMACD:    type = StringLit!"ethernet";    break;
                                case IFTYPE.IEEE80211:          type = StringLit!"wifi";        break;
                                case IFTYPE.PPP:    // TODO: do we actually want to populate windows tunnels?
                                case IFTYPE.TUNNEL: //       ...
                                default:
                                    // TODO: handle other types??
                                    continue;
                            }
                            port = ports.insert(name[], Port(name.move, type.move));
                            assert(port, "Failed to insert port into map!?");
                        }

                        const(char)[] desc = tmp[0 .. a.Description[0 .. a.Description.wcslen].uniConvert(tmp)];
                        if (desc[] != port.desc[])
                            port.desc = desc.makeString(defaultAllocator());

                        assert(a.Mtu <= ushort.max, "TODO: investigate enormous MTU...");
                        port.mtu = cast(ushort)a.Mtu;
                        port.txRate = a.TransmitLinkSpeed;
                        port.rxRate = a.ReceiveLinkSpeed;

                        if (a.PhysicalAddressLength == 6)
                            port.mac.b = a.PhysicalAddress[0..6];
                        else
                            assert(false, "TODO: what kind of address is this? EUI64?");

                        import urt.socket : make_InetAddress;
                        port.addresses.clear();
                        for (IP_ADAPTER_UNICAST_ADDRESS* ua = a.FirstUnicastAddress; ua; ua = ua.Next)
                            port.addresses ~= make_InetAddress(cast(sockaddr*)ua.Address.lpSockaddr);

//                        printf("  DHCP: %s\n\n", (a->Flags & IP_ADAPTER_DHCP_ENABLED) ? "Enabled" : "Disabled");
                    }
                }
                defaultAllocator().free(buffer);
            }
            else version (linux)
            {

            }
            else
                static assert(false, "TODO");

            Duration elapsed = getTime() - start;
            writeInfo("PortsModule update took ", elapsed);
        }
    }

private:

    Timer updateTimer;
}


version (Windows)
{
nothrow @nogc:
    import core.sys.windows.windows;
    import core.sys.windows.setupapi;
    import core.sys.windows.regstr;
    import core.sys.windows.winsock2;
    import core.sys.windows.iphlpapi;
    import core.sys.windows.iptypes;

    pragma(lib, "setupapi");
    pragma( lib, "iphlpapi");

    extern (Windows) int SetupDiDestroyDeviceInfoList(HDEVINFO);
    extern (Windows) int SetupDiEnumDeviceInfo(HDEVINFO, uint, PSP_DEVINFO_DATA);
    extern (Windows) HDEVINFO SetupDiGetClassDevsW(const(GUID)*, wchar*, HWND, uint);
    extern (Windows) int SetupDiGetDeviceRegistryPropertyW(HDEVINFO, PSP_DEVINFO_DATA, uint, uint*, ubyte*, uint, uint*);
    extern (Windows) HKEY SetupDiOpenDevRegKey(HDEVINFO, PSP_DEVINFO_DATA, uint, uint, uint, REGSAM);

    extern (Windows) ULONG GetAdaptersAddresses(ULONG Family, ULONG Flags, void* Reserved, IP_ADAPTER_ADDRESSES* AdapterAddresses, ULONG* SizePointer);

    alias IP_ADAPTER_ADDRESSES = IP_ADAPTER_ADDRESSES_LH;

    alias IF_INDEX = uint;
    enum IFTYPE : uint
    {
        OTHER = 1,
        ETHERNET_CSMACD = 6,
        ISO88025_TOKENRING = 9,
        PPP = 23,
        SOFTWARE_LOOPBACK = 24,
        ATM = 37,
        IEEE80211 = 71,
        TUNNEL = 131,
        IEEE1394 = 144,
    }

    alias NET_IF_COMPARTMENT_ID = uint;
    alias NET_IF_NETWORK_GUID = GUID;

    enum GAA_FLAG_INCLUDE_PREFIX = 0x0010;

    enum MAX_DHCPV6_DUID_LENGTH = 130;
    struct IP_ADAPTER_ADDRESSES_LH
    {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG    Length;
                IF_INDEX IfIndex;
            }
        }
        IP_ADAPTER_ADDRESSES_LH           *Next;
        PCHAR                              AdapterName;
        PIP_ADAPTER_UNICAST_ADDRESS        FirstUnicastAddress;
        PIP_ADAPTER_ANYCAST_ADDRESS_XP     FirstAnycastAddress;
        PIP_ADAPTER_MULTICAST_ADDRESS_XP   FirstMulticastAddress;
        PIP_ADAPTER_DNS_SERVER_ADDRESS_XP  FirstDnsServerAddress;
        wchar*                             DnsSuffix;
        wchar*                             Description;
        wchar*                             FriendlyName;
        BYTE[MAX_ADAPTER_ADDRESS_LENGTH]   PhysicalAddress;
        ULONG                              PhysicalAddressLength;
        union {
            ULONG Flags;
//            struct {
//                ULONG DdnsEnabled : 1;
//                ULONG RegisterAdapterSuffix : 1;
//                ULONG Dhcpv4Enabled : 1;
//                ULONG ReceiveOnly : 1;
//                ULONG NoMulticast : 1;
//                ULONG Ipv6OtherStatefulConfig : 1;
//                ULONG NetbiosOverTcpipEnabled : 1;
//                ULONG Ipv4Enabled : 1;
//                ULONG Ipv6Enabled : 1;
//                ULONG Ipv6ManagedAddressConfigurationSupported : 1;
//            };
        }
        ULONG                              Mtu;
        IFTYPE                             IfType;
        IF_OPER_STATUS                     OperStatus;
        IF_INDEX                           Ipv6IfIndex;
        ULONG[16]                          ZoneIndices;
        PIP_ADAPTER_PREFIX_XP              FirstPrefix;
        ULONG64                            TransmitLinkSpeed;
        ULONG64                            ReceiveLinkSpeed;
        PIP_ADAPTER_WINS_SERVER_ADDRESS_LH FirstWinsServerAddress;
        PIP_ADAPTER_GATEWAY_ADDRESS_LH     FirstGatewayAddress;
        ULONG                              Ipv4Metric;
        ULONG                              Ipv6Metric;
        IF_LUID                            Luid;
        SOCKET_ADDRESS                     Dhcpv4Server;
        NET_IF_COMPARTMENT_ID              CompartmentId;
        NET_IF_NETWORK_GUID                NetworkGuid;
        NET_IF_CONNECTION_TYPE             ConnectionType;
        TUNNEL_TYPE                        TunnelType;
        SOCKET_ADDRESS                     Dhcpv6Server;
        BYTE[MAX_DHCPV6_DUID_LENGTH]       Dhcpv6ClientDuid;
        ULONG                              Dhcpv6ClientDuidLength;
        ULONG                              Dhcpv6Iaid;
        PIP_ADAPTER_DNS_SUFFIX             FirstDnsSuffix;
    }
    alias PIP_ADAPTER_ADDRESSES_LH = IP_ADAPTER_ADDRESSES_LH*;

    struct IP_ADAPTER_UNICAST_ADDRESS {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Flags;
            }
        }
        IP_ADAPTER_UNICAST_ADDRESS *Next;
        SOCKET_ADDRESS                 Address;
        IP_PREFIX_ORIGIN               PrefixOrigin;
        IP_SUFFIX_ORIGIN               SuffixOrigin;
        IP_DAD_STATE                   DadState;
        ULONG                          ValidLifetime;
        ULONG                          PreferredLifetime;
        ULONG                          LeaseLifetime;
        UINT8                          OnLinkPrefixLength;
    }
    alias PIP_ADAPTER_UNICAST_ADDRESS = IP_ADAPTER_UNICAST_ADDRESS*;

    struct IP_ADAPTER_ANYCAST_ADDRESS_XP {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Flags;
            }
        }
        IP_ADAPTER_ANYCAST_ADDRESS_XP *Next;
        SOCKET_ADDRESS                 Address;
    }
    alias PIP_ADAPTER_ANYCAST_ADDRESS_XP = IP_ADAPTER_ANYCAST_ADDRESS_XP*;

    struct IP_ADAPTER_MULTICAST_ADDRESS_XP {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Flags;
            }
        }
        IP_ADAPTER_MULTICAST_ADDRESS_XP *Next;
        SOCKET_ADDRESS                   Address;
    }
    alias PIP_ADAPTER_MULTICAST_ADDRESS_XP = IP_ADAPTER_MULTICAST_ADDRESS_XP*;

    struct IP_ADAPTER_DNS_SERVER_ADDRESS_XP {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Reserved;
            }
        }
        IP_ADAPTER_DNS_SERVER_ADDRESS_XP *Next;
        SOCKET_ADDRESS                    Address;
    }
    alias PIP_ADAPTER_DNS_SERVER_ADDRESS_XP = IP_ADAPTER_DNS_SERVER_ADDRESS_XP*;

    struct SOCKET_ADDRESS
    {
        LPSOCKADDR lpSockaddr;
        INT        iSockaddrLength;
    }
    alias PSOCKET_ADDRESS = SOCKET_ADDRESS*;
    alias LPSOCKET_ADDRESS = SOCKET_ADDRESS*;

    struct IP_ADAPTER_PREFIX_XP {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Flags;
            }
        }
        IP_ADAPTER_PREFIX_XP *Next;
        SOCKET_ADDRESS        Address;
        ULONG                 PrefixLength;
    }
    alias PIP_ADAPTER_PREFIX_XP = IP_ADAPTER_PREFIX_XP*;

    struct IP_ADAPTER_WINS_SERVER_ADDRESS_LH {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Reserved;
            }
        }
        IP_ADAPTER_WINS_SERVER_ADDRESS_LH *Next;
        SOCKET_ADDRESS                            Address;
    }
    alias PIP_ADAPTER_WINS_SERVER_ADDRESS_LH = IP_ADAPTER_WINS_SERVER_ADDRESS_LH*;

    struct IP_ADAPTER_GATEWAY_ADDRESS_LH {
        union {
            ULONGLONG Alignment;
            struct {
                ULONG Length;
                DWORD Reserved;
            }
        }
        IP_ADAPTER_GATEWAY_ADDRESS_LH *Next;
        SOCKET_ADDRESS                 Address;
    }
    alias PIP_ADAPTER_GATEWAY_ADDRESS_LH = IP_ADAPTER_GATEWAY_ADDRESS_LH*;

    enum MAX_DNS_SUFFIX_STRING_LENGTH = 256;
    struct IP_ADAPTER_DNS_SUFFIX {
        IP_ADAPTER_DNS_SUFFIX               *Next;
        WCHAR[MAX_DNS_SUFFIX_STRING_LENGTH]  String;
    }
    alias PIP_ADAPTER_DNS_SUFFIX = IP_ADAPTER_DNS_SUFFIX*;

    union NET_LUID_LH {
        ULONG64 Value;
//        struct Info
//        {
//            ULONG64 Reserved : 24;
//            ULONG64 NetLuidIndex : 24;
//            ULONG64 IfType : 16;
//        }
    }
    alias IF_LUID = NET_LUID_LH;
    alias PNET_LUID_LH = NET_LUID_LH*;

    enum IF_OPER_STATUS {
        IfOperStatusUp = 1,
        IfOperStatusDown,
        IfOperStatusTesting,
        IfOperStatusUnknown,
        IfOperStatusDormant,
        IfOperStatusNotPresent,
        IfOperStatusLowerLayerDown
    }

    enum TUNNEL_TYPE {
        TUNNEL_TYPE_NONE = 0,
        TUNNEL_TYPE_OTHER = 1,
        TUNNEL_TYPE_DIRECT = 2,
        TUNNEL_TYPE_6TO4 = 11,
        TUNNEL_TYPE_ISATAP = 13,
        TUNNEL_TYPE_TEREDO = 14,
        TUNNEL_TYPE_IPHTTPS = 15
    }

    enum NET_IF_CONNECTION_TYPE
    {
        NET_IF_CONNECTION_DEDICATED = 1,
        NET_IF_CONNECTION_PASSIVE = 2,
        NET_IF_CONNECTION_DEMAND = 3,
        NET_IF_CONNECTION_MAXIMUM = 4
    }

    enum IP_PREFIX_ORIGIN {
        IpPrefixOriginOther = 0,
        IpPrefixOriginManual,
        IpPrefixOriginWellKnown,
        IpPrefixOriginDhcp,
        IpPrefixOriginRouterAdvertisement,
        IpPrefixOriginUnchanged = 1 << 4
    }

    enum IP_SUFFIX_ORIGIN {
        IpSuffixOriginOther = 0,
        IpSuffixOriginManual,
        IpSuffixOriginWellKnown,
        IpSuffixOriginDhcp,
        IpSuffixOriginLinkLayerAddress,
        IpSuffixOriginRandom,
        IpSuffixOriginUnchanged = 1 << 4
    }

    enum IP_DAD_STATE {
        IpDadStateInvalid = 0,
        IpDadStateTentative,
        IpDadStateDuplicate,
        IpDadStateDeprecated,
        IpDadStatePreferred
    }
}
