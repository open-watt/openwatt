module protocol.tesla.vehicle_retry;

import urt.string;
import urt.time;
import urt.util : min;

nothrow @nogc:

enum VehicleCommandKind : ubyte
{
    unknown,
    get_charge_state,
    get_climate_state,
    get_vehicle_state,
    charging_start,
    charging_stop,
    set_charging_amps,
    climate_power,
    climate_temperature,
    schedule_charging,
}

static immutable vehicle_command_names = make_table!([
    "command",
    "get-charge",
    "get-climate",
    "get-vehicle",
    "charge-start",
    "charge-stop",
    "set-amps",
    "climate",
    "set-temperature",
    "schedule-charging",
]);

struct VehicleRetryState
{
nothrow @nogc:
    enum size_t count = VehicleCommandKind.max + 4;
    struct Failure
    {
    nothrow @nogc:
        String reason;
        MonoTime retry_at;
        ubyte failures;
        bool latched;

        bool available(MonoTime now) const pure => !latched && now >= retry_at;
        MonoTime next() const pure => latched ? MonoTime(ulong.max) : retry_at;
    }

    Failure[count] failures;
    String status;

    static size_t index(VehicleCommandKind kind, ubyte category = 0) pure
    {
        assert(category < 4);
        return kind == VehicleCommandKind.get_vehicle_state && category ? VehicleCommandKind.max + category : cast(size_t)kind;
    }

    void failed(size_t slot, const(char)[] reason, MonoTime now, bool latch)
    {
        ref f = failures[slot];
        f.reason = reason.make_string();
        f.latched |= latch;
        f.retry_at = now + min(5u << min(f.failures, 6), 300u).seconds;
        if (f.failures < 6)
            ++f.failures;
        update_status();
    }

    void succeeded(size_t slot)
    {
        if (failures[slot].latched || !failures[slot].failures)
            return;
        failures[slot] = Failure.init;
        update_status();
    }

    void update_status()
    {
        MutableString!0 text;
        foreach (i, ref f; failures)
        {
            if (!f.failures)
                continue;
            if (text.length)
                text.concat("; ");
            text.concat(category_name(i), ": ", f.reason[], f.latched ? " (latched; use vehicle-scanner reset-backoff)" : " (timed back-off, at most 5m)");
        }
        status = String(text.move);
    }

    static const(char)[] category_name(size_t slot) pure
    {
        if (slot == 0)
            return "session";
        if (slot == VehicleCommandKind.get_vehicle_state)
            return "drive";
        if (slot <= VehicleCommandKind.max)
            return vehicle_command_names[slot][];
        static immutable extra_names = make_table!(["location", "closures", "tire-pressure"]);
        return extra_names[slot - VehicleCommandKind.max - 1][];
    }
}

unittest
{
    VehicleRetryState r;
    MonoTime now = MonoTime() + 100.seconds;
    auto charge = r.index(VehicleCommandKind.get_charge_state);
    r.failed(charge, "Vehicle busy", now, false);
    assert(!r.failures[charge].available(now + 4.seconds));
    assert(r.failures[charge].available(now + 5.seconds));
    r.failed(charge, "Vehicle busy", now + 5.seconds, false);
    assert(r.failures[charge].retry_at == now + 15.seconds);
    foreach (i; 0 .. 12)
        r.failed(charge, "Vehicle busy", now, false);
    assert(r.failures[charge].retry_at == now + 300.seconds);
    r.succeeded(charge);
    assert(r.failures[charge].available(now) && !r.status.length);

    auto drive = r.index(VehicleCommandKind.get_vehicle_state, 1);
    r.failed(drive, "Command unsupported", now, true);
    r.succeeded(drive);
    assert(!r.failures[drive].available(now + 86400.seconds));
    assert(r.failures[r.index(VehicleCommandKind.get_vehicle_state, 2)].available(now));
    assert(r.failures[charge].available(now));
    assert(r.status[].length);

    char[4] reason = "busy";
    r.failed(charge, reason[], now, false);
    reason[] = 'x';
    assert(r.failures[charge].reason[] == "busy");
}
