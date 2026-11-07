module apps.energy.supply;

import urt.array;
import urt.log;
import urt.mem.temp : talloc_array, tconcat;
import urt.string;
import urt.time;

import apps.energy.accounts : AccountFloatCell, AccountStringCell, account_element;
import apps.energy.meter;
import apps.energy.model;
import apps.energy.topology;

import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


// AS 60038: 230 V nominal +10% / -6%.
enum overvoltage_threshold = MeterVolts(253);
enum undervoltage_threshold = MeterVolts(216);

VoltageWindow supply_voltage_window(SysTime now) pure
    => VoltageWindow(now - 180.seconds, now + 5.seconds);

// Taken as the meter is read, before inference rewrites the port's data.
float supply_sample(ref const MeterData d) pure
    => d.voltage_fresh & 1 ? d.voltage[0].value : 0;

enum SupplyState : ubyte
{
    normal,
    over,
    under,
}

const(char)[] supply_state_name(SupplyState s) pure
{
    final switch (s)
    {
        case SupplyState.normal: return "normal";
        case SupplyState.over:   return "over";
        case SupplyState.under:  return "under";
    }
}

enum SupplyEvent : ubyte
{
    none,
    entered,
    reminder,
    recovered,
}

struct VoltageCandidate
{
    Component meter;
    float volts;
    ubyte phase;
    bool reference;
}

// With an even count the two middle meters bound the median; an excursion
// needs both on the same side, so one biased meter of a pair cannot trip it.
struct SupplyReading
{
nothrow @nogc:
    Component low_meter;
    Component high_meter;
    size_t meters;
    float low = float.nan;
    float high = float.nan;
    bool reference;

    bool valid() const pure
        => meters != 0;

    float value() const pure
        => (low + high) * 0.5f;

    const(char)[] basis() const
    {
        if (reference)
            return "reference meter";
        if (meters >= 2)
            return tconcat("corroborated by median of ", meters, " meters");
        return "single meter, uncorroborated";
    }
}

SupplyReading select_supply(VoltageCandidate[] candidates) pure
{
    size_t references;
    foreach (ref c; candidates)
        references += c.reference;
    SupplyReading r;
    r.reference = references != 0;
    r.meters = references ? references : candidates.length;

    foreach (i, ref c; candidates)
    {
        if (c.reference != r.reference)
            continue;
        size_t rank;
        foreach (j, ref o; candidates)
            if (o.reference == r.reference && (o.volts < c.volts || (o.volts == c.volts && j < i)))
                ++rank;
        if (rank == (r.meters - 1) / 2)
        {
            r.low = c.volts;
            r.low_meter = c.meter;
        }
        if (rank == r.meters / 2)
        {
            r.high = c.volts;
            r.high_meter = c.meter;
        }
    }
    return r;
}

struct SupplyMonitor
{
nothrow @nogc:
    enum entry_delay = 10.seconds;
    enum recovery_delay = 60.seconds;
    enum reminder_interval = 900.seconds;
    enum hysteresis = 2.0f;

    SupplyState state;
    SupplyState excursion;
    MonoTime since;
    MonoTime excursion_start;
    float peak = 0;

    SupplyEvent update(ref const SupplyReading r, MonoTime now, float over, float under)
    {
        if (!since)
            since = now;

        SupplyState s = SupplyState.normal;
        if (r.valid)
        {
            if (r.low > over)
                s = SupplyState.over;
            else if (r.high < under)
                s = SupplyState.under;
            if (state != SupplyState.normal)
                track_peak(peak, side(r, state), state);
        }

        if (s != SupplyState.normal && s != state)
        {
            if (s != _pending)
            {
                _pending = s;
                _pending_since = now;
                _pending_peak = side(r, s);
            }
            else
                track_peak(_pending_peak, side(r, s), s);
            if (now - _pending_since >= entry_delay)
            {
                state = excursion = s;
                since = excursion_start = _pending_since;
                peak = _pending_peak;
                _pending = SupplyState.normal;
                _recovering_since = MonoTime();
                _last_report = now;
                return SupplyEvent.entered;
            }
        }
        else
            _pending = SupplyState.normal;

        if (state == SupplyState.normal)
            return SupplyEvent.none;

        bool clear = r.valid && r.low > under + hysteresis && r.high < over - hysteresis;
        if (!clear)
            _recovering_since = MonoTime();
        else if (!_recovering_since)
            _recovering_since = now;
        else if (now - _recovering_since >= recovery_delay)
        {
            state = SupplyState.normal;
            since = _recovering_since;
            return SupplyEvent.recovered;
        }

        if (now - _last_report >= reminder_interval)
        {
            _last_report = now;
            return SupplyEvent.reminder;
        }
        return SupplyEvent.none;
    }

    Duration excursion_duration(MonoTime now) const
        => (state == SupplyState.normal ? since : now) - excursion_start;

private:
    SupplyState _pending;
    MonoTime _pending_since;
    MonoTime _recovering_since;
    MonoTime _last_report;
    float _pending_peak = 0;

    static float side(ref const SupplyReading r, SupplyState s) pure
        => s == SupplyState.over ? r.low : r.high;

    static void track_peak(ref float peak, float v, SupplyState s) pure
    {
        if (s == SupplyState.over ? v > peak : v < peak)
            peak = v;
    }
}

struct IslandSupply
{
nothrow @nogc:
    SupplyMonitor monitor;

    void retire()
    {
        if (!_bound)
            return;
        SysTime t = getSysTime();
        _value.element.invalidate(t);
        _state.element.invalidate(t);
        _peak.element.invalidate(t);
        _since.invalidate(t);
        _source.element.invalidate(t);
        _bound = false;
    }

private:
    AccountFloatCell _value;
    AccountFloatCell _peak;
    AccountStringCell _state;
    AccountStringCell _source;
    Element* _since;
    Component _source_meter;
    MonoTime _published_since;
    bool _bound;
}

void update_supply(Device energy, ref Islands islands, ref Array!VoltageCandidate scratch, MonoTime now, SysTime wall)
{
    foreach (island; islands[])
    {
        scratch.clear();
        collect_candidates(island, scratch);
        SupplyReading r = select_supply(scratch[]);
        SupplyEvent e = island.supply.monitor.update(r, now, overvoltage_threshold.value, undervoltage_threshold.value);
        if (e != SupplyEvent.none)
            report(island, r, e, now);
        publish(energy, island, r, now, wall);
    }
}


private:

enum dead_volts = 40.0f;

// One reading per physical meter: a flagged port's reading wins, then the lowest phase slot.
void collect_candidates(Island* island, ref Array!VoltageCandidate into)
{
    foreach (bus; island.members[])
    {
        foreach (p; bus.ports[])
        {
            float v = p.supply_volts;
            // A near-zero reading is a meter without supply or data, not a brownout.
            if (p.meter is null || !(v > dead_volts && v < float.infinity))
                continue;
            Device dev = p.meter.root_device();
            if (dev !is null && dev.online_status == OnlineStatus.offline)
                continue;

            VoltageCandidate c = VoltageCandidate(p.meter, v, p.meter_phase, p.voltage_reference);
            bool seen;
            foreach (ref o; into[])
            {
                if (o.meter !is c.meter)
                    continue;
                if (c.reference > o.reference || (c.reference == o.reference && c.phase < o.phase))
                    o = c;
                seen = true;
                break;
            }
            if (!seen)
                into ~= c;
        }
    }
}

const(char)[] meter_path(Component meter)
{
    if (meter is null)
        return "-";
    char[] buf = talloc_array!char(256);
    ptrdiff_t n = meter.full_path(buf);
    if (n <= 0 || n > buf.length)
        return meter.id[];
    return buf[0 .. n];
}

Component source_meter(ref SupplyReading r, SupplyState state)
    => state == SupplyState.under ? r.high_meter : r.low_meter;

void report(Island* island, ref SupplyReading r, SupplyEvent e, MonoTime now)
{
    const(SupplyMonitor)* m = &island.supply.monitor;
    bool under = m.excursion == SupplyState.under;
    float threshold = under ? undervoltage_threshold.value : overvoltage_threshold.value;
    write_log(e == SupplyEvent.recovered ? Severity.notice : Severity.warning, "energy.supply", null,
              under ? "Supply undervoltage" : "Supply overvoltage",
              e == SupplyEvent.entered ? "" : e == SupplyEvent.reminder ? " persists" : " recovered",
              " on island '", island.id[], "': ", r.valid ? tconcat(r.value, "V") : "unavailable",
              " (threshold ", threshold, "V, peak ", m.peak, "V, for ", m.excursion_duration(now), ") from ",
              meter_path(source_meter(r, m.excursion)), ", ", r.valid ? r.basis() : "no fresh meter");
}

void publish(Device energy, Island* island, ref SupplyReading r, MonoTime now, SysTime wall)
{
    IslandSupply* s = &island.supply;
    const(SupplyMonitor)* m = &s.monitor;
    bool bind = !s._bound;
    if (bind)
    {
        DeviceBuilder b = energy.edit();
        s._value.bind(account_element!float(b, island.id[], "voltage.value"));
        s._state.bind(account_element!String(b, island.id[], "voltage.state"));
        s._peak.bind(account_element!float(b, island.id[], "voltage.peak"));
        s._since = account_element!SysTime(b, island.id[], "voltage.since");
        s._source.bind(account_element!String(b, island.id[], "voltage.source"));
        s._bound = true;
    }

    s._value.publish(r.valid ? r.value : float.nan, wall);
    s._state.publish(supply_state_name(m.state), wall);
    s._peak.publish(m.excursion == SupplyState.normal ? float.nan : m.peak, wall);
    if (bind || m.since != s._published_since)
    {
        s._since.value(wall - (now - m.since), wall);
        s._published_since = m.since;
    }
    Component source = source_meter(r, m.state);
    if (bind || source !is s._source_meter)
    {
        s._source.publish(meter_path(source), wall);
        s._source_meter = source;
    }
}


unittest
{
    import urt.mem : free;
    import manager.device : DeviceTable;

    VoltageCandidate[3] three = [ VoltageCandidate(null, 263.5f), VoltageCandidate(null, 254.0f), VoltageCandidate(null, 253.2f) ];
    SupplyReading r = select_supply(three[]);
    assert(r.meters == 3 && !r.reference);
    assert(r.low == 254.0f && r.high == 254.0f);

    VoltageCandidate[2] pair = [ VoltageCandidate(null, 263.5f), VoltageCandidate(null, 252.0f) ];
    r = select_supply(pair[]);
    assert(r.meters == 2 && r.low == 252.0f && r.high == 263.5f);

    VoltageCandidate[3] with_ref = [ VoltageCandidate(null, 240.0f), VoltageCandidate(null, 255.0f, 0, true), VoltageCandidate(null, 241.0f) ];
    r = select_supply(with_ref[]);
    assert(r.reference && r.meters == 1 && r.low == 255.0f && r.high == 255.0f);

    VoltageCandidate[1] single = [ VoltageCandidate(null, 258.0f) ];
    r = select_supply(single[]);
    assert(r.meters == 1 && !r.reference && r.value == 258.0f);
    assert(!select_supply(null).valid);

    static SupplyReading reading(float v)
    {
        SupplyReading r;
        r.low = r.high = v;
        r.meters = 3;
        return r;
    }

    enum float over = overvoltage_threshold.value, under = undervoltage_threshold.value;
    MonoTime t0 = MonoTime(1);
    SupplyMonitor m;

    assert(m.update(reading(255), t0, over, under) == SupplyEvent.none);
    assert(m.update(reading(256), t0 + 9.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(252), t0 + 9500.msecs, over, under) == SupplyEvent.none);
    assert(m.update(reading(255), t0 + 10.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(254), t0 + 19.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(254), t0 + 20.seconds, over, under) == SupplyEvent.entered);
    assert(m.state == SupplyState.over && m.peak == 255 && m.excursion_start == t0 + 10.seconds);

    MonoTime t1 = t0 + 20.seconds;
    assert(m.update(reading(258), t1 + 60.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(254), t1 + 899.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(254), t1 + 900.seconds, over, under) == SupplyEvent.reminder);
    assert(m.peak == 258 && m.excursion_duration(t1 + 900.seconds) == 910.seconds);
    assert(m.update(reading(254), t1 + 1000.seconds, over, under) == SupplyEvent.none);

    MonoTime t2 = t1 + 1000.seconds;
    assert(m.update(reading(252), t2, over, under) == SupplyEvent.none);
    assert(m.update(reading(250.5f), t2 + 1.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(250.5f), t2 + 60.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(252), t2 + 61.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(250), t2 + 62.seconds, over, under) == SupplyEvent.none);
    assert(m.update(SupplyReading(), t2 + 100.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(250), t2 + 101.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(250), t2 + 160.seconds, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.over);
    assert(m.update(reading(250), t2 + 161.seconds, over, under) == SupplyEvent.recovered);
    assert(m.state == SupplyState.normal && m.since == t2 + 101.seconds);
    assert(m.excursion == SupplyState.over && m.peak == 258);
    assert(m.excursion_duration(t2 + 200.seconds) == (t2 + 101.seconds) - (t0 + 10.seconds));

    SupplyReading pair_reading;
    pair_reading.low = 252;
    pair_reading.high = 263;
    pair_reading.meters = 2;
    MonoTime t3 = t2 + 300.seconds;
    assert(m.update(pair_reading, t3, over, under) == SupplyEvent.none);
    assert(m.update(pair_reading, t3 + 30.seconds, over, under) == SupplyEvent.none);

    MonoTime t4 = t3 + 100.seconds;
    assert(m.update(reading(210), t4, over, under) == SupplyEvent.none);
    assert(m.update(reading(205), t4 + 10.seconds, over, under) == SupplyEvent.entered);
    assert(m.state == SupplyState.under && m.peak == 205);
    assert(m.update(reading(217), t4 + 20.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(219), t4 + 30.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(219), t4 + 90.seconds, over, under) == SupplyEvent.recovered);

    MonoTime t5 = t4 + 200.seconds;
    assert(m.update(reading(255), t5, over, under) == SupplyEvent.none);
    assert(m.update(SupplyReading(), t5 + 5.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(255), t5 + 10.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(256), t5 + 20.seconds, over, under) == SupplyEvent.entered);
    assert(m.update(reading(205), t5 + 25.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(206), t5 + 35.seconds, over, under) == SupplyEvent.entered);
    assert(m.state == SupplyState.under && m.excursion_start == t5 + 25.seconds && m.peak == 205);
    assert(m.update(SupplyReading(), t5 + 36.seconds + SupplyMonitor.reminder_interval, over, under) == SupplyEvent.reminder);
    assert(m.update(SupplyReading(), t5 + 200.seconds + SupplyMonitor.reminder_interval, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.under);

    MonoTime t6 = t5 + 5000.seconds;
    m = SupplyMonitor();
    assert(m.update(reading(255), t6, over, under) == SupplyEvent.none);
    assert(m.update(reading(255), t6 + 10.seconds, over, under) == SupplyEvent.entered);
    assert(m.update(reading(245), t6 + 20.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(205), t6 + 80.seconds, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.over);
    assert(m.update(reading(205), t6 + 90.seconds, over, under) == SupplyEvent.entered);
    assert(m.state == SupplyState.under);

    SupplyReading disputed;
    disputed.low = 250;
    disputed.high = 272;
    disputed.meters = 2;
    MonoTime t7 = t6 + 5000.seconds;
    m = SupplyMonitor();
    assert(m.update(reading(255), t7, over, under) == SupplyEvent.none);
    assert(m.update(reading(255), t7 + 10.seconds, over, under) == SupplyEvent.entered);
    assert(m.update(disputed, t7 + 20.seconds, over, under) == SupplyEvent.none);
    assert(m.update(disputed, t7 + 200.seconds, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.over && m.peak == 255);
    assert(m.update(reading(249), t7 + 201.seconds, over, under) == SupplyEvent.none);
    assert(m.update(disputed, t7 + 230.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(249), t7 + 231.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(249), t7 + 290.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(249), t7 + 291.seconds, over, under) == SupplyEvent.recovered);

    SupplyReading low_pair;
    low_pair.low = 200;
    low_pair.high = 225;
    low_pair.meters = 2;
    MonoTime t8 = t7 + 5000.seconds;
    m = SupplyMonitor();
    assert(m.update(reading(255), t8, over, under) == SupplyEvent.none);
    assert(m.update(reading(255), t8 + 10.seconds, over, under) == SupplyEvent.entered);
    assert(m.update(low_pair, t8 + 20.seconds, over, under) == SupplyEvent.none);
    assert(m.update(low_pair, t8 + 200.seconds, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.over);

    SupplyReading high_pair;
    high_pair.low = 240;
    high_pair.high = 276;
    high_pair.meters = 2;
    MonoTime t9 = t8 + 5000.seconds;
    m = SupplyMonitor();
    assert(m.update(reading(210), t9, over, under) == SupplyEvent.none);
    assert(m.update(reading(210), t9 + 10.seconds, over, under) == SupplyEvent.entered);
    assert(m.update(high_pair, t9 + 20.seconds, over, under) == SupplyEvent.none);
    assert(m.update(high_pair, t9 + 200.seconds, over, under) == SupplyEvent.none);
    assert(m.state == SupplyState.under);
    assert(m.update(reading(230), t9 + 201.seconds, over, under) == SupplyEvent.none);
    assert(m.update(reading(230), t9 + 261.seconds, over, under) == SupplyEvent.recovered);

    DeviceTable devices;
    Device energy = devices.create("energy").device;
    Component m1, m2, m3, m4, m5, m6, m7, m8;
    {
        DeviceBuilder b = devices.create("site");
        SysTime t = getSysTime();
        auto volts = register_value_format!MeterVolts();
        m1 = b.component("m1");
        b.element(m1, "voltage", volts).value(MeterVolts(254), t);
        m2 = b.component("m2");
        b.element(m2, "voltage", volts).value(MeterVolts(255), t);
        b.element(m2, "voltage1", volts).value(MeterVolts(256), t);
        m3 = b.component("m3");
        b.element(m3, "voltage2", volts).value(MeterVolts(263), t - 600.seconds);
        m4 = b.component("m4");
        b.element(m4, "power", register_value_format!MeterWatts()).value(MeterWatts(2300), t);
        b.element(m4, "current", register_value_format!MeterAmps()).value(MeterAmps(10), t);
        m5 = b.component("m5");
        b.element(m5, "voltage1", volts).value(MeterVolts(253), t);
        b.element(m5, "voltage2", volts).value(MeterVolts(0.5f), t - 600.seconds);
        m6 = b.component("m6");
        b.element(m6, "voltage", volts).value(MeterVolts(254), t + 60.seconds);
        m7 = b.component("m7");
        b.element(m7, "voltage1", volts).value(MeterVolts(254), t);
        b.element(m7, "voltage2", volts).value(MeterVolts(256), t - 1.seconds);
        m8 = b.component("m8");
        String dc = StringLit!"dc";
        b.element(m8, "type", register_value_format!String()).value(dc, t);
        b.element(m8, "voltage1", volts).value(MeterVolts(252), t);
    }

    VoltageWindow w = supply_voltage_window(getSysTime());
    assert(!(get_port_meter_data(m5, 0, MeterSign.normal, &w).voltage_fresh & 1));
    assert(get_port_meter_data(m5, 1, MeterSign.normal, &w).voltage_fresh & 1);
    assert(!(get_port_meter_data(m5, 2, MeterSign.normal, &w).voltage_fresh & 1));
    assert(get_port_meter_data(m7, 0, MeterSign.normal, &w).voltage_fresh & 1);
    assert(!(get_port_meter_data(m6, 0, MeterSign.normal, &w).voltage_fresh & 1));
    assert(!(get_port_meter_data(m7, 0, MeterSign.normal).voltage_fresh & 1));
    assert(supply_sample(get_port_meter_data(m5, 1, MeterSign.normal, &w)) == 253);
    assert(supply_sample(get_port_meter_data(m8, 1, MeterSign.normal, &w)) == 0);
    assert(supply_sample(get_port_meter_data(m8, 0, MeterSign.normal, &w)) == 0);

    Port[6] ports;
    Component[6] port_meters = [ m1, m2, m3, m4, m2, m2 ];
    Bus bus;
    foreach (i, ref p; ports)
    {
        p.meter = port_meters[i];
        p.meter_phase = i == 5 ? 1 : 0;
        p.voltage_reference = i >= 4;
        p.meter_data = get_port_meter_data(p.meter, p.meter_phase, MeterSign.normal, &w);
        p.supply_volts = supply_sample(p.meter_data);
    }
    foreach (ref p; ports[0 .. 4])
        bus.ports ~= &p;
    Island island;
    island.id = StringLit!"t";
    island.members ~= &bus;
    Islands islands;
    islands ~= &island;

    Array!VoltageCandidate scratch;
    collect_candidates(&island, scratch);
    assert(scratch.length == 2 && scratch[0].meter is m1 && scratch[1].meter is m2);

    MonoTime n0 = MonoTime(1);
    update_supply(energy, islands, scratch, n0, getSysTime());
    assert(energy.find_element("islands.t.voltage.value").value.asFloat == 254.5f);
    assert(energy.find_element("islands.t.voltage.state").text_value == "normal");
    assert(energy.find_element("islands.t.voltage.source").text_value == "site.m1");

    bus.ports ~= &ports[5];
    scratch.clear();
    collect_candidates(&island, scratch);
    assert(scratch.length == 2 && scratch[1].meter is m2 && scratch[1].reference && scratch[1].phase == 1 && scratch[1].volts == 256);
    bus.ports ~= &ports[4];
    scratch.clear();
    collect_candidates(&island, scratch);
    assert(scratch.length == 2 && scratch[1].reference && scratch[1].phase == 0 && scratch[1].volts == 255);

    ports[0].supply_volts = float.infinity;
    scratch.clear();
    collect_candidates(&island, scratch);
    assert(scratch.length == 1 && scratch[0].meter is m2);

    foreach (ref p; ports[0 .. 2])
        p.supply_volts = 256;
    bus.ports.resize(2);
    update_supply(energy, islands, scratch, n0 + 1.seconds, getSysTime());
    assert(energy.find_element("islands.t.voltage.state").text_value == "normal");
    update_supply(energy, islands, scratch, n0 + 11.seconds, getSysTime());
    assert(energy.find_element("islands.t.voltage.state").text_value == "over");
    assert(energy.find_element("islands.t.voltage.peak").value.asFloat == 256);

    island.supply.retire();
    assert(!energy.find_element("islands.t.voltage.state").has_value);

    Component main_meter, blind_meter, ref_meter;
    {
        DeviceBuilder b = devices.create("bench");
        SysTime t = getSysTime();
        main_meter = b.component("main");
        b.element(main_meter, "power", register_value_format!MeterWatts()).value(MeterWatts(-1000), t);
        b.element(main_meter, "voltage", register_value_format!MeterVolts()).value(MeterVolts(240), t);
        blind_meter = b.component("blind");
        b.element(blind_meter, "power", register_value_format!MeterWatts()).value(MeterWatts(-1000), t);
        ref_meter = b.component("ref");
        b.element(ref_meter, "voltage", register_value_format!MeterVolts()).value(MeterVolts(265), t);
    }

    // The solver's view must stay exactly as before; the monitor reads the pre-inference sample.
    foreach (layout; 0 .. 3)
    {
        TopologyGraph graph;
        Bus* site = graph.ensure_bus("site");
        Port* ref_p;
        void add_ref()
        {
            ref_p = graph.add_port(null, site, PortRole.connection, FlowDomain.bidirectional, ref_meter, 0);
            ref_p.voltage_reference = true;
            graph.add_to_group(graph.add_group("ref", PortGroupKind.appliance), ref_p);
        }
        if (layout == 1)
            add_ref();
        Port* main_p = graph.add_port(null, site, PortRole.connection, FlowDomain.bidirectional, layout == 2 ? blind_meter : main_meter, 0);
        graph.add_to_group(graph.add_group("main", PortGroupKind.handover), main_p);
        if (layout != 1)
            add_ref();
        graph.refresh();

        assert(ref_p.meter_data.source(MeterField.power) == Provenance.inferred_subtraction);
        assert(ref_p.supply_volts == 265);
        if (layout == 2)
        {
            assert(!site.balance.has(MeterField.voltage) && !ref_p.meter_data.has(MeterField.voltage));
        }
        else
        {
            assert(ref_p.meter_data.is_inferred(MeterField.voltage) && ref_p.meter_data.voltage[0].value == 240);
            assert(site.balance.voltage[0].value == 240);
        }

        Islands graph_islands;
        update_islands(graph_islands, graph);
        update_supply(energy, graph_islands, scratch, MonoTime(1), getSysTime());
        assert(energy.find_element("islands.site.voltage.value").value.asFloat == 265);
        assert(energy.find_element("islands.site.voltage.source").text_value == "bench.ref");
        foreach (solved; graph_islands[])
            free(solved);
        graph.clear();
    }
}
