module protocol.ip;

import urt.inet;
import urt.mem.temp;
import urt.string;
import urt.log;

import manager.collection;
import manager.console;
import manager.plugin;

import protocol.ip.address;
import protocol.ip.route;

import router.iface;
import router.iface.ethernet;

version(Windows)
{
    import urt.internal.sys.windows.winsock2;
    import manager.os.npcap;
}

nothrow @nogc:

class IPModule : Module
{
    mixin DeclareModule!"protocol.ip";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!IPAddress("/protocol/ip/address");
        g_app.console.register_collection!IPRoute("/protocol/ip/route");
    }

    override void post_init()
    {
        // pre-populate the address list from the operating system...
        version(Windows)
        {
            import urt.endian : loadBigEndian;
            import urt.util : clz;

            if (!npcap_loaded())
            {
                writeError("NPCap library not loaded, cannot enumerate ethernet interfaces.");
                return;
            }

            pcap_if* interfaces;
            char[PCAP_ERRBUF_SIZE] errbuf = void;
            if (pcap_findalldevs(&interfaces, errbuf.ptr) == -1)
            {
                writeError("pcap_findalldevs failed: ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
                return;
            }
            scope(exit) pcap_freealldevs(interfaces);

            for (auto dev = interfaces; dev; dev = dev.next)
            {
                foreach (i; Collection!BaseInterface().values)
                {
                    EthernetInterface e = cast(EthernetInterface)i;
                    if (!e || e.adapter != dev.name[0..dev.name.strlen])
                        continue;

                    for (auto addr = dev.addresses; addr; addr = addr.next)
                    {
                        if (addr.addr.sa_family == AF_INET)
                        {
                            const sockaddr_in* ain = cast(const(sockaddr_in)*)&addr.addr;
                            const sockaddr_in* nmin = cast(const(sockaddr_in)*)&addr.netmask;

                            IPNetworkAddress net_addr;
                            net_addr.addr.b[0] = ain.sin_addr.S_un.S_un_b.s_b1;
                            net_addr.addr.b[1] = ain.sin_addr.S_un.S_un_b.s_b2;
                            net_addr.addr.b[2] = ain.sin_addr.S_un.S_un_b.s_b3;
                            net_addr.addr.b[3] = ain.sin_addr.S_un.S_un_b.s_b4;
                            net_addr.mask.b[0] = nmin.sin_addr.S_un.S_un_b.s_b1;
                            net_addr.mask.b[1] = nmin.sin_addr.S_un.S_un_b.s_b2;
                            net_addr.mask.b[2] = nmin.sin_addr.S_un.S_un_b.s_b3;
                            net_addr.mask.b[3] = nmin.sin_addr.S_un.S_un_b.s_b4;

                            IPAddress ip = Collection!IPAddress().create(tconcat(e.name, ".addr"));
                            ip.address = net_addr;
                            ip.iface = e;
                        }
                    }
                }
            }
        }
    }

    override void update()
    {
        Collection!IPAddress().update_all();
        Collection!IPRoute().update_all();
    }
}
