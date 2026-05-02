module driver.windows.pcap;

version (Windows):

import urt.log;
import urt.string;
import urt.time;

import manager.os.npcap;

nothrow @nogc:


// Lightweight wrapper over an npcap pcap_t handle.
// Owns the open / close / poll / send sequence so the consuming
// EthernetInterface / WLANInterface subclass doesn't need to know about pcap.
struct PcapAdapter
{
nothrow @nogc:

    bool open(const(char)[] adapter_name)
    {
        char[PCAP_ERRBUF_SIZE] errbuf = void;

        // TODO: we may not want to open promiscuous unless we're a member of a bridge, or some form of L2 tunnel.
        bool promiscuous = true;
        int timeout_ms = 1; // TODO: we could probably tune this to our program update rate...?

        handle = pcap_open_live(adapter_name.tstringz, ushort.max, promiscuous, timeout_ms, errbuf.ptr);
        if (handle is null)
        {
            writeError("pcap_open_live failed for adapter '", adapter_name, "': ", errbuf.ptr[0 .. strlen(errbuf.ptr)]);
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
    int poll(out const(ubyte)[] data, out uint wire_len, out SysTime timestamp)
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
        timestamp = timeval_to_systime(header.ts);
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
