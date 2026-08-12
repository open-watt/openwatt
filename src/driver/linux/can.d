module driver.linux.can;

version (linux):

// SocketCAN controllers (ARPHRD_CAN netdevs) are the linux backend for CANInterface's
// `adapter` property. Discovery mirrors the ethernet driver, with one difference: a CAN bus
// has a bitrate and no safe default, so a discovered interface takes `baud-rate` from the
// link rather than imposing one. A controller that has never been configured reads back 0
// and stays invalid until an operator sets a rate, at which point it is applied to the link.

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;

import manager;
import manager.collection;
import manager.plugin;

import driver.linux.netlink;
import driver.linux.netlink_write : netlink_ifindex, netlink_get_can_bitrate;
import driver.linux.sysfs;

import protocol.can.iface;

import router.port;

nothrow @nogc:


class LinuxSocketCANModule : Module
{
    mixin DeclareModule!"interface.can.linux";
nothrow @nogc:

    override void pre_init()
    {
        subscribe_link_changed(&on_link_changed);
        sync_adapters();
    }

private:

    void on_link_changed(uint, const(char)[], bool, bool)
    {
        sync_adapters();
    }

    void sync_adapters()
    {
        Array!String seen;
        enumerate_can_adapters((const(char)[] name, const(char)[] description) nothrow @nogc {
            // A USB CAN dongle can be unplugged; an SPI or platform controller is soldered down.
            const bool removable = adapter_is_removable(name);
            auto id = tconcat("linux:can:", name);
            port_add(PortKind.can, id, name, name, ModuleName, description,
                     removable ? PortFlags.removable : PortFlags.none);
            seen ~= id.makeString(defaultAllocator);

            bool present = false;
            foreach (e; Collection!CANInterface().values)
            {
                if (e.adapter == name)
                {
                    present = true;
                    break;
                }
            }
            if (!present)
            {
                auto iface_name = next_iface_name();
                log_info(ModuleName, "Found CAN interface: \"", description, "\" (", name, ")");
                auto iface = Collection!CANInterface().create(iface_name,
                                                              removable ? ObjectFlags.dynamic : ObjectFlags.none);
                iface.adapter = name;
                // Adopt the link's rate when it has one, so an already-configured bus is
                // left exactly as it is. A controller that has never been configured reports
                // 0, which is "don't know", not "zero" -- keep the property default and let
                // startup bring the link up with it.
                if (uint rate = netlink_get_can_bitrate(netlink_ifindex(name)))
                    iface.baud_rate = rate;
                if (description.length > 0)
                    iface.comment = description.makeString(defaultAllocator);
            }
        });

        Array!String gone;
        foreach (ref p; port_list())
        {
            if (p.kind != PortKind.can || p.driver[] != ModuleName)
                continue;

            bool still_there;
            foreach (ref id; seen[])
            {
                if (p.id[] == id[])
                {
                    still_there = true;
                    break;
                }
            }
            if (!still_there)
                gone ~= p.id[].makeString(defaultAllocator);
        }
        foreach (ref id; gone[])
            port_remove(PortKind.can, id[]);

        Array!CANInterface stale;
        foreach (e; Collection!CANInterface().values)
        {
            // Only removable controllers are reaped. A soldered one stays put, and a
            // stream-backed interface has no adapter so it is never ours to remove.
            if (!(e.flags & ObjectFlags.dynamic) || e.adapter.empty)
                continue;

            bool still_there;
            foreach (ref id; seen[])
            {
                if (tconcat("linux:can:", e.adapter) == id[])
                {
                    still_there = true;
                    break;
                }
            }
            if (!still_there)
                stale ~= e;
        }
        foreach (e; stale[])
        {
            log_info(ModuleName, "CAN adapter gone: ", e.adapter);
            // destroy(), not Collection.remove(): only destroy() runs shutdown(), which is
            // what drops the socket out of the reactor pool.
            e.destroy();
        }
    }

    // Pick the lowest unused "canN" name so removed slots get reused.
    const(char)[] next_iface_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("can", n);
            bool taken = false;
            foreach (e; Collection!CANInterface().values)
            {
                if (e.name == candidate)
                {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                return candidate;
        }
        return tconcat("can", 999);
    }
}
