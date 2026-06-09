module apps.energy.state;

import urt.lifetime;
import urt.mem;
import urt.string;

import manager;
import manager.component;
import manager.device;

nothrow @nogc:


// The synthetic `energy` device. Carries all runtime state the energy app
// publishes: archipelago of islands (with per-island accounts, pressures, mode),
// active policies, current allocations, and tunable config. Dashboard, the
// /apps/energy/why command, and external subscribers (sync, MQTT) read from
// this device like any other.
//
// Top-level structure (populated by subsequent Phase 0 work):
//
//   energy
//     archipelago
//       island.<id>
//         account.{solar,battery,grid,generation,load.*}
//         pressure.{today,overnight,branch.*}
//         budget.{overnight_reserve_kwh,...}
//         constraints.binding
//         members, mode
//     policy
//       <policy_id>.{tier,goal,deadline,satisfied,marginal_value,...}
//     allocation
//       <target_id>.{setpoint_w,actual_w,reason,active_policy}
//     config
//       overnight_reserve_factor, voltage_threshold, slow_loop_period, daily_reset_time

Device create_energy_device()
{
    Device d = g_app.allocator.allocT!Device("energy".makeString(g_app.allocator));

    d.add_component(g_app.allocator.allocT!Component("archipelago".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("policy".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("allocation".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("config".makeString(g_app.allocator)));

    g_app.devices.insert(d.id[], d);
    d.notify(ComponentEvent.tree_changed);
    d.notify(ComponentEvent.online);

    return d;
}
