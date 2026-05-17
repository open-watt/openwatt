module apps.energy.vehicle;

import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.string;

import manager;
import manager.component;
import manager.device;
import manager.element;

import protocol.http;
import protocol.http.message;

nothrow @nogc:


// Decoded VIN fields. Any field may be empty/zero if not derivable.
struct VINInfo
{
    String manufacturer_name;
    String manufacturer_id;     // raw WMI (positions 1-3), useful as opaque id
    String model_name;
    String manufacture_location; // human-readable plant / region
    int    model_year;          // 0 if not decoded
}


// Decode as many identity fields as we can from a VIN string.
// - Manufacturer/location: from WMI (positions 1-3)
// - Model: from position 4 (Tesla-specific; other manufacturers vary)
// - Model year: from position 10 (ISO 3779 cycle; assumes 2010+ era)
//
// Returns empty/zero fields when the VIN isn't recognised or is malformed.
VINInfo decode_vin(const(char)[] vin)
{
    VINInfo info;
    if (vin.length != 17)
        return info;

    info.manufacturer_id = vin[0 .. 3].makeString(defaultAllocator());

    // WMI lookup. Each Tesla plant gets its own WMI; we report the location
    // alongside the manufacturer so consumers don't need their own table.
    const(char)[] wmi = vin[0 .. 3];
    bool is_tesla = false;
    switch (wmi)
    {
        case "5YJ":
            info.manufacturer_name = StringLit!"Tesla";
            info.manufacture_location = StringLit!"Fremont, California, USA";
            is_tesla = true;
            break;
        case "7SA":
            info.manufacturer_name = StringLit!"Tesla";
            info.manufacture_location = StringLit!"USA"; // Lathrop / Reno — exact plant unclear from WMI alone
            is_tesla = true;
            break;
        case "XP7":
            info.manufacturer_name = StringLit!"Tesla";
            info.manufacture_location = StringLit!"Berlin-Brandenburg, Germany";
            is_tesla = true;
            break;
        case "LRW":
            info.manufacturer_name = StringLit!"Tesla";
            info.manufacture_location = StringLit!"Shanghai, China";
            is_tesla = true;
            break;
        default:
            break;
    }

    if (is_tesla)
    {
        switch (vin[3])
        {
            case 'S': info.model_name = StringLit!"Model S"; break;
            case '3': info.model_name = StringLit!"Model 3"; break;
            case 'X': info.model_name = StringLit!"Model X"; break;
            case 'Y': info.model_name = StringLit!"Model Y"; break;
            case 'C': info.model_name = StringLit!"Cybertruck"; break;
            case 'R': info.model_name = StringLit!"Roadster"; break;
            default: break;
        }
    }

    // Model year (position 10). The ISO 3779 alphabet skips I, O, Q, U, Z and
    // 0, and cycles every 30 years. We assume the current cycle (2010-2039)
    // which covers all modern Teslas. A car older than ~2009 will misdecode.
    info.model_year = decode_year_code(vin[9]);

    return info;
}

// ISO 3779 model-year char → year. The alphabet skips I, O, Q, U, Z and 0 and
// cycles every 30 years; we assume the current 2010-2039 cycle (any car older
// than ~2009 will misdecode).
private int decode_year_code(char c) pure nothrow @nogc @safe
{
    switch (c)
    {
        case 'A': return 2010;  case 'B': return 2011;  case 'C': return 2012;
        case 'D': return 2013;  case 'E': return 2014;  case 'F': return 2015;
        case 'G': return 2016;  case 'H': return 2017;  case 'J': return 2018;
        case 'K': return 2019;  case 'L': return 2020;  case 'M': return 2021;
        case 'N': return 2022;  case 'P': return 2023;  case 'R': return 2024;
        case 'S': return 2025;  case 'T': return 2026;  case 'V': return 2027;
        case 'W': return 2028;  case 'X': return 2029;  case 'Y': return 2030;
        case '1': return 2031;  case '2': return 2032;  case '3': return 2033;
        case '4': return 2034;  case '5': return 2035;  case '6': return 2036;
        case '7': return 2037;  case '8': return 2038;  case '9': return 2039;
        default: return 0;
    }
}


// ---------------------------------------------------------------------------
// NHTSA vPIC enrichment
//
// Free public VIN decoder run by the US DOT. Returns ~150 fields including
// Drive Configuration, Body Class, exact plant City/State, legal manufacturer
// name. No battery capacity (we measure that empirically).
//
// Fire-and-forget: vehicle_for() calls enrich_from_nhtsa(vin) once per VIN
// on creation. Response folds extra fields into info.* elements. Failure is
// silent — the locally-decoded VIN values stand.
// ---------------------------------------------------------------------------

// Caller (vehicle_for) is responsible for only invoking this once per VIN —
// the find-existing-component check at the top of vehicle_for is the dedup,
// so there's no need for a separate "have we already fetched" set.
void enrich_from_nhtsa(const(char)[] vin)
{
    import urt.mem.temp : tconcat;

    auto ctx = defaultAllocator.allocT!NHTSALookup;
    ctx.vin = vin.makeString(defaultAllocator());

    const(char)[] url = tconcat("https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVin/", vin, "?format=json");
    if (!http_request(url, &ctx.on_response))
        defaultAllocator.freeT(ctx);
}

private class NHTSALookup
{
nothrow @nogc:
    String vin;

    int on_response(ref const HTTPMessage msg)
    {
        scope(exit) defaultAllocator.freeT(this);

        if (msg.status_code != 200 || msg.content.length == 0)
            return 0;

        Variant root = parse_json(cast(const(char)[])msg.content[]);
        if (!root.isObject)
            return 0;
        const(Variant)* results = root.getMember("Results");
        if (!results || !results.isArray)
            return 0;

        Component v;
        if (g_vehicles_device !is null)
            v = g_vehicles_device.find_component(vin[]);
        if (v is null)
            return 0;

        // NHTSA returns each field as {Variable: name, Value: value}. Walk the
        // array, dispatch known Variable names to corresponding info.* elements.
        // Empty / "Not Applicable" / null Values are skipped.
        foreach (i; 0 .. results.length)
        {
            const(Variant)* entry = &(*results)[i];
            if (!entry.isObject)
                continue;
            const(Variant)* var_node = entry.getMember("Variable");
            const(Variant)* val_node = entry.getMember("Value");
            if (!var_node || !val_node || !var_node.isString || !val_node.isString)
                continue;

            const(char)[] var_name = var_node.asString;
            const(char)[] value    = val_node.asString;
            if (value.length == 0 || value == "Not Applicable" || value == "null")
                continue;

            const(char)[] elem_path;
            switch (var_name)
            {
                case "Manufacturer Name":      elem_path = "info.manufacturer_name"; break;
                case "Make":                   elem_path = "info.brand_name"; break;
                case "Model":                  elem_path = "info.model_name"; break;
                case "Trim":                   elem_path = "info.trim"; break;
                case "Series":                 elem_path = "info.series"; break;
                case "Body Class":             elem_path = "info.body_class"; break;
                case "Drive Type":             elem_path = "info.drive_type"; break;
                case "Plant City":             elem_path = "info.plant_city"; break;
                case "Plant State":            elem_path = "info.plant_state"; break;
                case "Plant Country":          elem_path = "info.plant_country"; break;
                case "Plant Company Name":     elem_path = "info.plant_company"; break;
                case "Electrification Level":  elem_path = "info.electrification"; break;
                default: continue;
            }
            v.find_or_create_element(elem_path).value = value.makeString(defaultAllocator());
        }

        return 0;
    }
}


// ---------------------------------------------------------------------------
// Battery capacity estimator
//
// Persistent running mean per VIN; each charging session feeds (delta_energy,
// delta_soc) samples in and the global estimate updates. Vehicle Component
// gets `battery.full_capacity` (kWh) and `battery.capacity_confidence` (0..1)
// written each time a new sample lands.
//
// Algorithm sanity bounds:
//   - Only accept estimates in [40, 150] kWh (sanity range for current EVs)
//   - Caller is expected to filter the SOC window (15..85%) to avoid the BMS
//     buffer regions where SOC reporting is nonlinear
// ---------------------------------------------------------------------------

struct CapacityEstimate
{
    float sum_weighted = 0;   // Σ(estimate_kwh × weight)
    float weight_total = 0;   // Σ(weight)
    uint  sample_count = 0;
    float mean_kwh() const pure nothrow @nogc @safe
        => weight_total > 0 ? sum_weighted / weight_total : float.nan;
}

__gshared Map!(String, CapacityEstimate) g_capacity_estimates;


// Fold a new capacity estimate into the running mean for this VIN and update
// the Vehicle Component's battery.full_capacity and battery.capacity_confidence
// elements. Weight should be larger for more-trusted samples (typically the
// SOC delta in percent — a 20% window is far more precise than 5%).
//
// Rejects estimates outside the [40, 150] kWh sanity range (probably charger
// disconnect or a measurement glitch).
void add_capacity_sample(const(char)[] vin, float estimate_kwh, float weight)
{
    if (!(estimate_kwh >= 40.0f && estimate_kwh <= 150.0f) || !(weight > 0))
        return;

    String key = vin.makeString(defaultAllocator());
    CapacityEstimate* ce = key in g_capacity_estimates;
    if (!ce)
    {
        g_capacity_estimates[key] = CapacityEstimate.init;
        ce = key in g_capacity_estimates;
    }
    ce.sum_weighted += estimate_kwh * weight;
    ce.weight_total += weight;
    ++ce.sample_count;

    // Simple confidence proxy: ramps linearly from 0 to 1 over the first
    // 10 samples. A future refinement could use stddev / relative spread.
    float confidence = ce.sample_count >= 10 ? 1.0f : ce.sample_count / 10.0f;

    if (g_vehicles_device !is null)
    {
        if (Component v = g_vehicles_device.find_component(vin))
        {
            v.find_or_create_element("battery.full_capacity").value = ce.mean_kwh;
            v.find_or_create_element("battery.capacity_confidence").value = confidence;
        }
    }
}


unittest
{
    // Tesla VINs across the WMI variants and all model codes.
    auto m3 = decode_vin("5YJ3E1EA5KF000001");
    assert(m3.manufacturer_name[] == "Tesla");
    assert(m3.manufacturer_id[] == "5YJ");
    assert(m3.model_name[] == "Model 3");
    assert(m3.manufacture_location[] == "Fremont, California, USA");
    assert(m3.model_year == 2019);  // 'K' = 2019

    assert(decode_vin("5YJSA1H22EFP00000").model_name[] == "Model S");
    assert(decode_vin("5YJSA1H22EFP00000").model_year == 2014);  // 'E' = 2014
    assert(decode_vin("5YJXCAE45GF000001").model_name[] == "Model X");
    assert(decode_vin("5YJYGDEE5LF000001").model_name[] == "Model Y");
    assert(decode_vin("5YJYGDEE5LF000001").model_year == 2020);  // 'L' = 2020

    auto berlin = decode_vin("XP7YGCEE5PB000001");
    assert(berlin.manufacturer_name[] == "Tesla");
    assert(berlin.manufacture_location[] == "Berlin-Brandenburg, Germany");
    assert(berlin.model_year == 2023);  // 'P' = 2023

    auto shanghai = decode_vin("LRW3E7FA5LC000001");
    assert(shanghai.manufacturer_name[] == "Tesla");
    assert(shanghai.manufacture_location[] == "Shanghai, China");

    // Unknown WMI: still records the raw id but no friendly name/location.
    auto unknown = decode_vin("7G2CEHED5RA000001");
    assert(unknown.manufacturer_name == String());
    assert(unknown.manufacturer_id[] == "7G2");
    assert(unknown.model_year == 2024);  // 'R' = 2024 — year decode is manufacturer-agnostic

    // Bad input
    assert(decode_vin("").manufacturer_id == String());
    assert(decode_vin("TOO_SHORT").manufacturer_id == String());
}


// EnergyModule-owned singleton Device that publishes all known vehicles as
// VIN-keyed Components. Every vehicle data source (Tesla BLE, future
// OVMS/BlueLink/...) registers into this same Device.
__gshared Device g_vehicles_device;


Device create_vehicles_device()
{
    assert(g_vehicles_device is null, "vehicles device already created");
    g_vehicles_device = g_app.allocator.allocT!Device("vehicles".makeString(g_app.allocator));
    g_vehicles_device.hidden = true;
    g_app.devices.insert(g_vehicles_device.id[], g_vehicles_device);
    g_vehicles_device.notify(ComponentEvent.tree_changed);
    g_vehicles_device.notify(ComponentEvent.online);
    return g_vehicles_device;
}


Component vehicle_for(const(char)[] vin)
{
    assert(g_vehicles_device !is null, "vehicles device not initialised");

    if (Component existing = g_vehicles_device.find_component(vin))
        return existing;

    Component vehicle = g_app.allocator.allocT!Component(vin.makeString(defaultAllocator()));
    vehicle.template_ = StringLit!"Vehicle";
    g_vehicles_device.add_component(vehicle);

    Component info = g_app.allocator.allocT!Component(StringLit!"info");
    info.template_ = StringLit!"DeviceInfo";
    vehicle.add_component(info);

    Component status = g_app.allocator.allocT!Component(StringLit!"status");
    status.template_ = StringLit!"DeviceStatus";
    vehicle.add_component(status);

    Component battery = g_app.allocator.allocT!Component(StringLit!"battery");
    battery.template_ = StringLit!"Battery";
    vehicle.add_component(battery);

    Component meter = g_app.allocator.allocT!Component(StringLit!"meter");
    meter.template_ = StringLit!"EnergyMeter";
    vehicle.add_component(meter);

    Component control = g_app.allocator.allocT!Component(StringLit!"control");
    control.template_ = StringLit!"PowerControl";
    vehicle.add_component(control);

    // Seed identity from VIN. Manufacturer/model come from WMI + position-4
    // decoding (decode_vin) — caller-supplied hints aren't accepted because
    // the VIN is the authoritative source.
    vehicle.find_or_create_element("info.type").value = StringLit!"vehicle";
    vehicle.find_or_create_element("info.serial_number").value = vin.makeString(defaultAllocator());

    VINInfo vi = decode_vin(vin);
    if (vi.manufacturer_name)
        vehicle.find_or_create_element("info.manufacturer_name").value = vi.manufacturer_name;
    if (vi.manufacturer_id)
        vehicle.find_or_create_element("info.manufacturer_id").value = vi.manufacturer_id;
    if (vi.model_name)
        vehicle.find_or_create_element("info.model_name").value = vi.model_name;
    if (vi.manufacture_location)
        vehicle.find_or_create_element("info.manufacture_location").value = vi.manufacture_location;
    if (vi.model_year != 0)
        vehicle.find_or_create_element("info.model_year").value = vi.model_year;

    // Static PowerControl shape (max + setpoint filled dynamically from vehicle reports).
    vehicle.find_or_create_element("control.kind").value = StringLit!"continuous";
    vehicle.find_or_create_element("control.direction").value = StringLit!"consume";
    vehicle.find_or_create_element("control.unit").value = StringLit!"A";
    vehicle.find_or_create_element("control.min").value = 6;
    vehicle.find_or_create_element("control.step").value = 1;

    // EnergyMeter declares its kind so downstream consumers know how to read it.
    vehicle.find_or_create_element("meter.type").value = StringLit!"single-phase";

    g_vehicles_device.notify(ComponentEvent.tree_changed);

    // Progressive enhancement: try NHTSA's vPIC for richer DeviceInfo fields
    // (Drive Configuration / Plant City / etc.). Fire-and-forget; if it fails
    // for any reason the locally-decoded VIN values remain in place.
    enrich_from_nhtsa(vin);

    return vehicle;
}
