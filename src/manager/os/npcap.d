module manager.os.npcap;

import urt.log;
import urt.time;

nothrow @nogc:


version (Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.winsock2 : sockaddr;

    HMODULE _npcap;

    pragma(crt_constructor)
    void crt_bootup()
    {
        _npcap = init_npcap();
    }

    bool npcap_loaded()
        => _npcap !is null;

    extern(Windows) void* AddDllDirectory(const wchar*);

    SysTime timeval_to_systime(ref const timeval tv) pure nothrow @nogc
    {
        ulong sec = tv.tv_sec + 11644473600UL;
        return SysTime(sec*10000000 + tv.tv_usec*10);
    }

    enum PCAP_ERRBUF_SIZE = 256;

    struct pcap_t {}

    struct pcap_addr {
        pcap_addr* next;
        sockaddr* addr;         // address
        sockaddr* netmask;      // netmask for that address
        sockaddr* broadaddr;    // broadcast address for that address
        sockaddr* dstaddr;      // P2P destination address for that address
    }

    struct pcap_if {
        pcap_if* next;
        char* name;         // name to hand to "pcap_open_live()"
        char* description;  // textual description of interface, or null
        pcap_addr* addresses;
        uint flags;         // PCAP_IF_ interface flags
    }

    struct pcap_pkthdr
    {
        timeval ts;
        uint caplen;
        uint len;
    }

    extern(Windows) int function(pcap_if**, char*) nothrow @nogc pcap_findalldevs;
    extern(Windows) void function(pcap_if* alldevs) nothrow @nogc pcap_freealldevs;
    extern(Windows) pcap_t* function(const(char)* device, int snaplen, int promisc, int to_ms, char* errbuf) nothrow @nogc pcap_open_live;
    extern(Windows) void function(pcap_t* p) nothrow @nogc pcap_close;
    extern(Windows) int function(pcap_t *p, int nonblock, char *errbuf) pcap_setnonblock;
    extern(Windows) int function(pcap_t* p, const void* buf, int size) nothrow @nogc pcap_sendpacket;
    extern(Windows) int function(pcap_t* p, pcap_pkthdr** pkt_header, const ubyte** pkt_data) nothrow @nogc pcap_next_ex;
    extern(Windows) const(char)* function(pcap_t* p) nothrow @nogc pcap_geterr;

    HMODULE init_npcap()
    {
        AddDllDirectory("C:\\Windows\\System32\\Npcap"w.ptr);
        HMODULE lib = LoadLibraryA("wpcap.dll");
        if (lib is null)
        {
            writeWarning("Failed to load npcap. Promiscuous access to ethernet interfaces will be unavailable.");
            return null;
        }

        pcap_findalldevs = cast(typeof(pcap_findalldevs))GetProcAddress(lib, "pcap_findalldevs");
        if (!pcap_findalldevs)
        {
            writeWarning("Failed to load npcap. Promiscuous access to ethernet interfaces will be unavailable.");
            FreeLibrary(lib);
            return null;
        }

        pcap_freealldevs = cast(typeof(pcap_freealldevs))GetProcAddress(lib, "pcap_freealldevs");
        pcap_open_live = cast(typeof(pcap_open_live))GetProcAddress(lib, "pcap_open_live");
        pcap_close = cast(typeof(pcap_close))GetProcAddress(lib, "pcap_close");
        pcap_setnonblock = cast(typeof(pcap_setnonblock))GetProcAddress(lib, "pcap_setnonblock");
        pcap_sendpacket = cast(typeof(pcap_sendpacket))GetProcAddress(lib, "pcap_sendpacket");
        pcap_next_ex = cast(typeof(pcap_next_ex))GetProcAddress(lib, "pcap_next_ex");
        pcap_geterr = cast(typeof(pcap_geterr))GetProcAddress(lib, "pcap_geterr");
        return lib;
    }
}
