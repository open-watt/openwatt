module driver.windows.pcap;

version (Windows):

import urt.log;
import urt.string;
import urt.time;

import driver.windows.npcap;

nothrow @nogc:


// Lightweight wrapper over an npcap pcap_t handle.
// Owns the open / close / poll / send sequence so the consuming
// EthernetInterface / WLANInterface subclass doesn't need to know about pcap.
struct PcapAdapter
{
nothrow @nogc:

    bool open(const(char)[] adapter_name)
    {
        // pcap_open is a WinPcap extension; only present when NPCap is installed
        // in WinPcap-API-compatible mode. We require it for NOCAPTURE_LOCAL --
        // without it npcap echoes our own pcap_sendpacket frames back into the
        // receive queue and the IP stack route-loops.
        if (pcap_open is null)
        {
            writeError("pcap_open unavailable -- NPCap must be installed in WinPcap API-compatible mode");
            return false;
        }

        char[PCAP_ERRBUF_SIZE] errbuf = void;

        // TODO: we may not want to open promiscuous unless we're a member of a bridge, or some form of L2 tunnel.
        int flags = PCAP_OPENFLAG_PROMISCUOUS | PCAP_OPENFLAG_NOCAPTURE_LOCAL | PCAP_OPENFLAG_MAX_RESPONSIVENESS;
        int timeout_ms = 1; // TODO: we could probably tune this to our program update rate...?

        handle = pcap_open(adapter_name.tstringz, ushort.max, flags, timeout_ms, null, errbuf.ptr);
        if (handle is null)
        {
            writeError("pcap_open failed for adapter '", adapter_name, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
            return false;
        }
        if (pcap_setnonblock(handle, 1, errbuf.ptr) != 0)
        {
            writeError("pcap_setnonblock failed on adapter '", adapter_name, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
            pcap_close(handle);
            handle = null;
            return false;
        }
        return true;
    }

    void close()
    {
        if (handle !is null)
        {
            pcap_close(handle);
            handle = null;
        }
    }

    // returns:  1 = got a frame; data/wire_len/timestamp populated
    //           0 = no frame ready
    //          -1 = error (already logged)
    int poll(out const(ubyte)[] data, out uint wire_len, out MonoTime timestamp)
    {
        pcap_pkthdr* header;
        const(ubyte)* bytes;

        int res = pcap_next_ex(handle, &header, &bytes);
        if (res == 0)
            return 0;
        if (res < 0)
        {
            writeError("pcap_next_ex failed: ", pcap_geterr(handle));
            // TODO: any specific error handling? restart interface?
            //       we need to know the set of errors we might expect...
            return -1;
        }
        data = bytes[0 .. header.caplen];
        wire_len = header.len;
        // pcap's header.ts is wall-clock; capture monotonic for transit/retry timing instead
        timestamp = getTime();
        return 1;
    }

    bool send(const(ubyte)[] frame)
    {
        if (pcap_sendpacket(handle, frame.ptr, cast(int)frame.length) != 0)
        {
            writeError("pcap_sendpacket failed: ", pcap_geterr(handle));
            // TODO: any specific error handling? restart interface?
            return false;
        }
        return true;
    }

    pcap_t* handle;
}
