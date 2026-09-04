module driver.power.hardware;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.attribute : critical, isr_safe;
import urt.driver.counter;
import urt.driver.event;
import urt.driver.gpio;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum FireMode : ubyte
{
    burst_fire,
    phase_angle,
}

struct FireConfig
{
    uint psm_gpio = uint.max;
    uint zc_gpio = uint.max;
    GpioInterruptTrigger zc_trigger = GpioInterruptTrigger.rising;
    Pull zc_pull = Pull.none;
    bool psm_invert;
}

struct FireParams
{
    uint level;             // Q16 power fraction; the ceiling when droop is active
    uint window = 50;       // burst repeat window in full mains cycles
    uint droop_start_mhz;   // output is zero at and below this frequency
    uint droop_span_mhz;    // start..start+span maps 0..level; 0 disables droop
    uint droop_slope_q16;   // level per mHz across the span
    FireMode mode;
    bool enable;
}

struct FireStatus
{
    uint period_q4;         // smoothed half-cycle period, 1/16 us units; 0 until locked
    uint level_q16;         // level currently applied by the engine
    uint edges;
    uint fired;             // half-cycles conducted
    bool fault;             // zero-cross watchdog tripped
}

enum bool fire_supported = num_gpio > 0 && num_links >= 3 && num_counters >= 2;

struct FireEngine
{
    Counter timebase;       // 1MHz; count is us since the last accepted edge, periodic alarm is the watchdog
    Counter fire;           // 1MHz one-shot for the phase-angle firing delay
    Link edge_link;
    Link watchdog_link;
    Link fire_link;
    FireConfig config;
    FireParams[2] params;
    shared ubyte param_bank;
    shared bool phase_armed;
    shared bool fault;
    shared uint stat_period_q4;
    shared uint stat_level;
    shared uint stat_edges;
    shared uint stat_fired;

    // edge-isr private state
    uint period_ema_q4;
    uint burst_acc;
    ubyte warmup;
    ubyte edge_parity;
    bool locked;
    bool burst_on;
    bool psm_on;
}

static if (fire_supported)
{

enum uint watchdog_period_us = 50_000;
enum uint min_half_period_us = 4_000;   // below this an edge is crossing ring or a pulse tail
enum uint max_half_period_us = 14_000;  // beyond this we lost edges; drop lock and re-sync

Result fire_open(ref FireEngine engine, ref const FireConfig config)
{
    if (config.psm_gpio == uint.max || config.zc_gpio == uint.max)
        return InternalResult.invalid_parameter;

    engine.config = config;
    engine.params[0] = FireParams();
    engine.params[1] = FireParams();
    atomicStore!(MemoryOrder.release)(engine.param_bank, ubyte(0));
    atomicStore!(MemoryOrder.relaxed)(engine.phase_armed, false);
    atomicStore!(MemoryOrder.relaxed)(engine.fault, false);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_period_q4, 0);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_level, 0);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_edges, 0);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_fired, 0);
    engine.period_ema_q4 = 0;
    engine.burst_acc = 0;
    engine.warmup = 0;
    engine.edge_parity = 0;
    engine.locked = false;
    engine.burst_on = false;
    engine.psm_on = false;

    gpio_output_init(config.psm_gpio, config.psm_invert);
    gpio_input_init(config.zc_gpio, config.zc_pull);

    CounterConfig counter_config;
    Result result = counter_acquire(engine.timebase, counter_config);
    if (!result)
        goto failed;
    result = counter_acquire(engine.fire, counter_config);
    if (!result)
        goto failed;
    result = counter_arm(engine.timebase, watchdog_period_us, true);
    if (!result)
        goto failed;
    // started so the edge isr can rearm it; phase_armed gates the stray first alarm
    result = counter_arm(engine.fire, 1_000_000, false);
    if (!result)
        goto failed;

    result = link_acquire(engine.edge_link,
                          gpio_event(GpioLine(0, config.zc_gpio), config.zc_trigger), isr_task!zc_edge(&engine));
    if (!result)
        goto failed;
    result = link_acquire(engine.watchdog_link,
                          counter_event(engine.timebase), isr_task!zc_watchdog(&engine));
    if (!result)
        goto failed;
    result = link_acquire(engine.fire_link,
                          counter_event(engine.fire), isr_task!fire_alarm(&engine));
    if (!result)
        goto failed;
    return Result.success;

failed:
    fire_close(engine);
    return result;
}

void fire_set_params(ref FireEngine engine, ref const FireParams params)
{
    ubyte bank = atomicLoad!(MemoryOrder.relaxed)(engine.param_bank) ^ 1;
    engine.params[bank] = params;
    atomicStore!(MemoryOrder.release)(engine.param_bank, bank);
}

FireStatus fire_status(ref FireEngine engine)
{
    FireStatus status;
    status.period_q4 = atomicLoad!(MemoryOrder.relaxed)(engine.stat_period_q4);
    status.level_q16 = atomicLoad!(MemoryOrder.relaxed)(engine.stat_level);
    status.edges = atomicLoad!(MemoryOrder.relaxed)(engine.stat_edges);
    status.fired = atomicLoad!(MemoryOrder.relaxed)(engine.stat_fired);
    status.fault = atomicLoad!(MemoryOrder.relaxed)(engine.fault);
    return status;
}

void fire_close(ref FireEngine engine)
{
    link_close(engine.edge_link);
    link_close(engine.watchdog_link);
    link_close(engine.fire_link);
    counter_close(engine.timebase);
    counter_close(engine.fire);
    if (engine.config.psm_gpio != uint.max)
    {
        gpio_output_set(engine.config.psm_gpio, engine.config.psm_invert);
        gpio_release(engine.config.psm_gpio);
        engine.config.psm_gpio = uint.max;
    }
    if (engine.config.zc_gpio != uint.max)
    {
        gpio_release(engine.config.zc_gpio);
        engine.config.zc_gpio = uint.max;
    }
}


private:

@critical void set_psm(ref FireEngine engine, bool on)
{
    engine.psm_on = on;
    gpio_output_set(engine.config.psm_gpio, on != engine.config.psm_invert);
    if (on)
        atomicStore!(MemoryOrder.relaxed)(engine.stat_fired, atomicLoad!(MemoryOrder.relaxed)(engine.stat_fired) + 1);
}

@isr_safe @critical bool zc_edge(void* context, LinkContext)
{
    FireEngine* engine = cast(FireEngine*)context;

    uint dt = cast(uint)counter_read(engine.timebase);
    if (dt < min_half_period_us)
        return false;
    counter_reload(engine.timebase);
    atomicStore!(MemoryOrder.relaxed)(engine.fault, false);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_edges, atomicLoad!(MemoryOrder.relaxed)(engine.stat_edges) + 1);

    if (dt > max_half_period_us)
    {
        engine.locked = false;
        engine.warmup = 0;
    }

    uint dt_q4 = dt << 4;
    if (!engine.locked)
    {
        engine.period_ema_q4 = dt_q4;
        if (++engine.warmup >= 4)
            engine.locked = true;
    }
    else
        engine.period_ema_q4 += (int(dt_q4) - int(engine.period_ema_q4)) >> 2;
    atomicStore!(MemoryOrder.relaxed)(engine.stat_period_q4, engine.locked ? engine.period_ema_q4 : 0);

    ref const FireParams params = engine.params[atomicLoad!(MemoryOrder.acquire)(engine.param_bank)];

    uint level = 0;
    if (params.enable && engine.locked)
    {
        level = params.level;
        if (params.droop_span_mhz)
        {
            uint freq_mhz = 500_000_000 / ((engine.period_ema_q4 + 8) >> 4);
            if (freq_mhz <= params.droop_start_mhz)
                level = 0;
            else
            {
                uint above = freq_mhz - params.droop_start_mhz;
                if (above > params.droop_span_mhz)
                    above = params.droop_span_mhz;
                uint droop_level = cast(uint)((ulong(above) * params.droop_slope_q16) >> 16);
                if (droop_level < level)
                    level = droop_level;
            }
        }
    }
    atomicStore!(MemoryOrder.relaxed)(engine.stat_level, level);

    if (params.mode == FireMode.burst_fire)
    {
        engine.edge_parity ^= 1;
        if (engine.edge_parity == 1)
        {
            // fire whole cycles only, so the load never draws a dc component
            uint fire_cycles = cast(uint)((ulong(level) * params.window + 0x8000) >> 16);
            engine.burst_acc += fire_cycles;
            if (engine.burst_acc >= params.window)
            {
                engine.burst_acc -= params.window;
                engine.burst_on = true;
            }
            else
                engine.burst_on = false;
        }
        if (engine.psm_on != engine.burst_on)
            set_psm(*engine, engine.burst_on);
        else if (engine.burst_on)
            atomicStore!(MemoryOrder.relaxed)(engine.stat_fired, atomicLoad!(MemoryOrder.relaxed)(engine.stat_fired) + 1);
    }
    else
    {
        if (level >= 0xFFF0)
        {
            if (!engine.psm_on)
                set_psm(*engine, true);
            else
                atomicStore!(MemoryOrder.relaxed)(engine.stat_fired, atomicLoad!(MemoryOrder.relaxed)(engine.stat_fired) + 1);
        }
        else
        {
            set_psm(*engine, false);
            if (level)
            {
                uint delay_us = cast(uint)((ulong(engine.period_ema_q4 >> 4) * phase_delay_frac(level)) >> 15);
                if (delay_us > 100)
                {
                    atomicStore!(MemoryOrder.release)(engine.phase_armed, true);
                    counter_rearm(engine.fire, delay_us);
                }
                else
                    set_psm(*engine, true);
            }
        }
    }
    return false;
}

@isr_safe @critical bool fire_alarm(void* context, LinkContext)
{
    FireEngine* engine = cast(FireEngine*)context;
    if (!atomicLoad!(MemoryOrder.acquire)(engine.phase_armed))
        return false;
    atomicStore!(MemoryOrder.relaxed)(engine.phase_armed, false);
    if (!atomicLoad!(MemoryOrder.relaxed)(engine.fault))
        set_psm(*engine, true);
    return false;
}

@isr_safe @critical bool zc_watchdog(void* context, LinkContext)
{
    FireEngine* engine = cast(FireEngine*)context;
    atomicStore!(MemoryOrder.relaxed)(engine.fault, true);
    atomicStore!(MemoryOrder.relaxed)(engine.phase_armed, false);
    atomicStore!(MemoryOrder.relaxed)(engine.stat_period_q4, 0);
    engine.locked = false;
    engine.warmup = 0;
    set_psm(*engine, false);
    return false;
}

}
else
{

Result fire_open(ref FireEngine engine, ref const FireConfig config)
    => InternalResult.unsupported;

void fire_set_params(ref FireEngine engine, ref const FireParams params)
{
}

FireStatus fire_status(ref FireEngine engine)
    => FireStatus();

void fire_close(ref FireEngine engine)
{
}

}


private:

// firing-delay fraction of the half-period (Q15) for a target power fraction,
// inverting P(a) = (pi - a + sin(2a)/2) / pi so commanded level is linear in power
@critical uint phase_delay_frac(uint level_q16)
{
    uint index = level_q16 >> 11;
    if (index >= 32)
        return 0;
    uint frac = level_q16 & 0x7FF;
    uint a = phase_delay_q15[index];
    uint b = phase_delay_q15[index + 1];
    return a - (((a - b) * frac) >> 11);
}

// __gshared so the table lands in .data: the edge isr must not touch flash-resident rodata
__gshared ushort[33] phase_delay_q15 = build_phase_delay_lut();

ushort[33] build_phase_delay_lut()
{
    enum double pi = 3.141592653589793238;

    static double sine(double x)
    {
        double term = x, sum = x;
        foreach (n; 1 .. 16)
        {
            term *= -x * x / ((2 * n) * (2 * n + 1));
            sum += term;
        }
        return sum;
    }

    static double power(double alpha)
        => (pi - alpha + sine(2 * alpha) / 2) / pi;

    ushort[33] lut;
    foreach (i; 0 .. 33)
    {
        double target = i / 32.0;
        double lo = 0, hi = pi;
        foreach (_; 0 .. 48)
        {
            double mid = (lo + hi) / 2;
            if (power(mid) > target)
                lo = mid;
            else
                hi = mid;
        }
        lut[i] = cast(ushort)((lo + hi) / 2 / pi * 32768.0 + 0.5);
    }
    return lut;
}


unittest
{
    // endpoints and monotonicity: more power always means a shorter firing delay
    assert(phase_delay_q15[32] == 0);
    assert(phase_delay_q15[0] > 32700);
    foreach (i; 1 .. 33)
        assert(phase_delay_q15[i] < phase_delay_q15[i - 1]);

    // 50% power fires at exactly the half-cycle midpoint
    assert(phase_delay_frac(0x8000) == 16384);
}
