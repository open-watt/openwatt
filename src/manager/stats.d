module manager.stats;

import urt.si.quantity : Quantity;
import urt.si.unit : Percent;
import urt.string;
import urt.string.ascii : to_lower;
import urt.system;
import urt.time;

import manager;
import manager.component;
import manager.device;
import manager.element;
import manager.system : node_id;

nothrow @nogc:


void create_system_device()
{
    ulong peer_id = node_id();
    if (!peer_id)
        return;
    DeviceBuilder builder = g_app.devices.create("system", peer_id);
    Device system = builder.device;
    Component mem = builder.component("mem");

    SystemInfo info = get_sysinfo();
    FormatId bytes = register_value_format!ulong();
    foreach (i, ref p; info.pools)
    {
        if (p.total == 0)
            continue;

        char[16] lowered;
        assert(p.name.length <= lowered.length, "pool name too long");
        Component pool = builder.component(mem, p.name.to_lower(lowered[0 .. p.name.length]));

        builder.constant(pool, "total", p.total).access = Access.read;
        _pools[i].used = metric(builder, pool, "used", bytes);
        _pools[i].low = metric(builder, pool, "low", bytes);
        _pools[i].high = metric(builder, pool, "high", bytes);
    }

    if (info.stack_size || info.stack_peak)
    {
        Component stack = builder.component(mem, "stack");
        if (info.stack_size)
            builder.constant(stack, "total", info.stack_size).access = Access.read;
        _stack_peak = metric(builder, stack, "peak", bytes);
    }

    Component cpu = builder.component("cpu");

    FormatId percent = register_value_format!Load();
    _cpu.load = metric(builder, cpu, "load", percent);
    _cpu.low = metric(builder, cpu, "low", percent);
    _cpu.high = metric(builder, cpu, "high", percent);

    builder.commit();
    system.notify(ComponentEvent.materialised);
    system.set_online(cast(void*)system, true);

    g_app.register_heartbeat_handler((MonoTime) { publish(); });
}


private:

alias Load = Quantity!(ubyte, Percent);

Element* metric(ref DeviceBuilder builder, Component parent, const(char)[] name, FormatId format)
{
    Element* e = builder.element(parent, name, format);
    e.access = Access.read;
    e.sampling_mode = SamplingMode.report;
    return e;
}

struct PoolElements
{
    Element* used;
    Element* low;
    Element* high;
}

struct CpuElements
{
    Element* load;
    Element* low;
    Element* high;
}

__gshared PoolElements[MaxMemoryPools] _pools;
__gshared CpuElements _cpu;
__gshared Element* _stack_peak;

void publish()
{
    PoolUsage[MaxMemoryPools] usage;
    sample_memory_usage(usage);
    ulong stack_size, stack_peak;
    get_stack_usage(stack_size, stack_peak);

    uint load = get_cpu_load();
    uint cpu_low, cpu_high;
    get_cpu_load_range(cpu_low, cpu_high);

    SysTime now = getSysTime();
    {
        auto beat = open_commit();
        _cpu.load.value(Load(cast(ubyte)load), now);
        _cpu.low.value(Load(cast(ubyte)cpu_low), now);
        _cpu.high.value(Load(cast(ubyte)cpu_high), now);
        if (_stack_peak)
            _stack_peak.value(stack_peak, now);
        foreach (i, ref u; usage)
        {
            PoolElements* e = &_pools[i];
            if (!e.used)
                continue;
            e.used.value(u.used, now);
            e.low.value(u.low, now);
            e.high.value(u.high, now);
        }
    }
}
