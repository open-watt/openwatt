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
    import core.sys.windows.winsock2;
    import manager.os.npcap;
}

nothrow @nogc:

class IPModule : Module
{
    mixin DeclareModule!"protocol.ip";
nothrow @nogc:

    Collection!IPAddress addresses;
    Collection!IPRoute routes;

    override void init()
    {
        g_app.console.registerCollection("/protocol/ip/address", addresses);
        g_app.console.registerCollection("/protocol/ip/route", routes);
    }

    override void post_init()
    {
        // pre-populate the address list from the operating system...
        version(Windows)
        {
            import urt.endian : loadBigEndian;
            import urt.socket : make_InetAddress;
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
                foreach (i; get_module!InterfaceModule.interfaces.values)
                {
                    EthernetInterface e = cast(EthernetInterface)i;
                    if (!e || e.adapter != dev.name[0..dev.name.strlen])
                        continue;

                    for (auto addr = dev.addresses; addr; addr = addr.next)
                    {
                        if (addr.addr.sa_family == AF_INET)
                        {
                            IPNetworkAddress net_addr;
                            net_addr.addr = make_InetAddress(addr.addr)._a.ipv4.addr;
                            net_addr.mask = make_InetAddress(addr.netmask)._a.ipv4.addr;

                            IPAddress ip = addresses.create(tconcat(e.name, ".addr"));
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
        addresses.update_all();
        routes.update_all();
    }
}
