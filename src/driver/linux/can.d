module driver.linux.can;

version (linux):

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;

import manager;
import manager.collection;
import manager.plugin;

import driver.linux.netlink;
import driver.linux.sysfs;

import protocol.can.iface;

import router.port;

nothrow @nogc:


final class LinuxSocketCANModule : Module
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
            const bool removable = adapter_is_removable(name);
            auto id = tconcat("linux:can:", name);
            port_add(PortKind.can, id, name, name, ModuleName, description, removable ? PortFlags.removable : PortFlags.none);
            seen ~= id.make_string();

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
                auto iface = Collection!CANInterface().create(iface_name, ObjectFlags.dynamic);
                iface.adapter = name;
                if (description.length > 0)
                    iface.comment = description.make_string();
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
                gone ~= p.id[].make_string();
        }
        foreach (ref id; gone[])
            port_remove(PortKind.can, id[]);

        Array!CANInterface stale;
        foreach (e; Collection!CANInterface().values)
        {
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
            e.destroy();
        }
    }

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
