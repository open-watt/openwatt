module apps.energy.forecast;

import urt.time;

import apps.energy.island;
import apps.energy.meter : MeterField;

import manager.component;

nothrow @nogc:


// Predicts supply (kWh) available to an island over a future window.
// Real implementations: cloud-cover weather forecast for solar, schedule for
// generators, etc. Trivial default: zero (conservative).
interface SupplyForecast
{
nothrow @nogc:
    float expected_kwh(Island* island, SysTime from, Duration window);
}


// Predicts demand (kWh) on an island over a future window. Real implementations:
// historical baseline (rolling average, same-time-last-week), occupancy hints,
// scheduled jobs. Trivial default: extrapolate the current root-meter load.
interface DemandForecast
{
nothrow @nogc:
    float expected_kwh(Island* island, SysTime from, Duration window);
}


// HACK: conservative placeholder. Always returns zero supply. Replace with a
// real forecast (weather API, historical solar profile) when available.
class NoSupplyForecast : SupplyForecast
{
nothrow @nogc:
    float expected_kwh(Island* island, SysTime from, Duration window) => 0;
}


// HACK: assumes load is flat at the currently-measured value for the whole
// window. Wildly wrong overnight (load drops) and during cooking peaks.
// Replace with a rolling-baseline forecast once db.Stream lands and we can
// query historical load curves.
class ConstantLoadDemandForecast : DemandForecast
{
nothrow @nogc:
    float expected_kwh(Island* island, SysTime from, Duration window)
    {
        if (island is null || island.root is null || !island.root.meter)
            return 0;
        if (!island.root.meter_data.has(MeterField.power))
            return 0;
        float power_w = island.root.meter_data.active[0].value;
        if (power_w <= 0)
            return 0;
        float hours = cast(float)window.as!"seconds" / 3600.0f;
        return power_w * hours / 1000.0f;
    }
}
