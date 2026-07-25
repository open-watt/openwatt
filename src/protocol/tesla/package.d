module protocol.tesla;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.session;
import manager.plugin;

import protocol.tesla.iface;
import protocol.tesla.master;
import protocol.tesla.binding;
import protocol.tesla.twc;

import router.iface;

nothrow @nogc:


class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    Map!(const(char)[], TeslaTWCMaster) twc_masters;

    override void init()
    {
        register_packet_codec!TWCFrame();
        g_app.register_enum!(TeslaTWCMaster.ChargerState)();
        g_app.register_enum!TWCState();

        g_app.console.register_collection!TeslaInterface();
        g_app.console.register_collection!TeslaTWCBinding();
        g_app.console.register_command!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.register_command!twc_set("/protocol/tesla/twc", this, "set");
    }

    override void update()
    {
        // TeslaInterface update handled by base interface collection
        foreach(m; twc_masters.values)
            m.update();
    }

    void twc_add(Session session, const(char)[] name, const(char)[] _interface, ushort id, float max_current)
    {
        BaseInterface i = Collection!BaseInterface().get(_interface);
        if(i is null)
        {
            session.write_line("Interface '", _interface, "' not found");
            return;
        }

        TeslaTWCMaster master;
        foreach (m; twc_masters.values)
        {
            if (m.iface is i)
            {
                master = m;
                break;
            }
        }
        if (!master)
        {
            String n = tconcat(_interface, "_twc").makeString(defaultAllocator());

            master = defaultAllocator().allocT!TeslaTWCMaster(this, n.move, i);
            twc_masters[master.name[]] = master;
        }

        String n = name.makeString(defaultAllocator());

        master.add_charger(n.move, id, cast(ushort)(max_current * 100));
    }

    void twc_set(Session session, const(char)[] name, float target_current)
    {
        foreach (m; twc_masters.values)
        {
            if (m.set_target_current(name, cast(ushort)(target_current * 100)) >= 0)
                return;
        }
    }

}
