module apps.energy.vehicle;

import urt.format.json;
import urt.lifetime;
import urt.log : writeError;
import urt.map;
import urt.mem;
import urt.meta : Alias;
import urt.si.unit;
import urt.string;
import urt.time : SysTime;

import apps.energy.appliance;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.series;

import protocol.http;
import protocol.http.message;

nothrow @nogc:


void init_vehicle_formats()
{
    foreach (i, ref f; vehicle_element_formats)
    {
        DataFormat fmt;
        final switch (vehicle_element_types[i]) with (VehicleElementType)
        {
            case string_: fmt = data_format_of!String(); break;
            case int_:    fmt = data_format_of!int(); break;
            case bool_:   fmt = data_format_of!bool(); break;
            case float_:  fmt = data_format_of!float(); break;
            case time:    fmt = data_format_of!SysTime(); break;
        }
        if (vehicle_element_units[i] != none)
            fmt = DataFormat(fmt.type, SeriesKind.held, vehicle_element_units[i]);
        f = register_format(fmt);
    }
}

void add_capacity_sample(const(char)[] vin, float estimate_kwh, float weight)
{
    if (!(estimate_kwh >= 40.0f && estimate_kwh <= 150.0f) || !(weight > 0))
        return;

    CapacityEstimate* estimate = vin in g_capacity_estimates;
    if (!estimate)
    {
        String key = vin.make_string();
        estimate = &g_capacity_estimates.replace(key.move, CapacityEstimate.init);
    }
    estimate.sum_weighted += estimate_kwh * weight;
    estimate.weight_total += weight;
    ++estimate.sample_count;

    if (Device* vehicle = vin in g_app.devices)
    {
        float confidence = estimate.sample_count >= 10 ? 1.0f : estimate.sample_count / 10.0f;
        (*vehicle).set_element("battery.full_capacity", estimate.mean_kwh);
        (*vehicle).set_element("battery.capacity_confidence", confidence);
    }
}


Component vehicle_for(const(char)[] vin)
{
    Device* existing = vin in g_app.devices;
    Device vehicle;
    if (!existing)
    {
        vehicle = alloc!Device(vin.make_string());
        g_app.devices.insert(vehicle);
    }
    else
        vehicle = *existing;

    bool changed = vehicle.template_[] != "Vehicle";
    vehicle.template_ = StringLit!"Vehicle";
    materialise_vehicle(vehicle, vin, changed);
    return vehicle;
}


Appliance vehicle_appliance_for(const(char)[] vin)
{
    Component vehicle = vehicle_for(vin);

    auto appliances = Collection!Appliance();
    Appliance appliance = appliances.get(vin);
    if (!appliance)
    {
        // TODO: remove compatibility lookup after configured vehicle appliances migrate to VIN IDs.
        foreach (Appliance candidate; appliances.values)
        {
            if (candidate.vin == vin)
            {
                appliance = candidate;
                Element* friendly_name = vehicle.find_element("info.name");
                if (friendly_name && friendly_name.record_update() == SysTime())
                    friendly_name.value(candidate.name[]);
                break;
            }
        }
    }
    if (!appliance)
    {
        appliance = appliances.alloc(vin, ObjectFlags.dynamic);
        if (!appliance)
        {
            writeError("could not create vehicle appliance for VIN '", vin, "'");
            return null;
        }
        appliances.add(appliance);
    }

    appliance.vin(vin);
    if (const(char)[] error = appliance.device(vin))
        writeError("could not bind vehicle appliance for VIN '", vin, "': ", error);
    return appliance;
}


private:

enum VehicleElementType : ubyte
{
    string_,
    int_,
    bool_,
    float_,
    time,
}

enum element_id(string id) = Alias!(vehicle_elements.find_first(id));

alias Type = VehicleElementType;

struct VINInfo
{
    String manufacturer_name;
    String manufacturer_id;
    String model_name;
    String manufacture_location;
    int model_year;
}

struct CapacityEstimate
{
    float sum_weighted;
    float weight_total;
    uint sample_count;

    float mean_kwh() const pure nothrow @nogc
        => weight_total > 0 ? sum_weighted / weight_total : float.nan;
}

__gshared FormatId[vehicle_elements.length] vehicle_element_formats;
__gshared Map!(String, CapacityEstimate) g_capacity_estimates;

static immutable vehicle_components = make_table!([
    "info", "DeviceInfo",
    "status", "DeviceStatus",
    "battery", "Battery",
    "meter", "EnergyMeter",
    "control", "PowerControl",
    "charging", "VehicleCharging",
    "hvac", "HVAC",
    "access", "VehicleAccess",
    "closures", "VehicleClosures",
    "drive", "VehicleDrive",
    "location", "Location",
    "tyres", "VehicleTyres",
]);

static immutable vehicle_elements = make_table!([
    "info.name",
    "info.type",
    "info.serial_number",
    "info.manufacturer_name",
    "info.manufacturer_id",
    "info.model_name",
    "info.manufacture_location",
    "info.model_year",
    "info.software_version",
    "connected",
    "last_seen",
    "charging_state",
    "minutes_to_full",
    "charging.enabled",
    "charging.target_soc",
    "charging.scheduled",
    "charging.schedule_time",
    "charging.port_open",
    "battery.soc",
    "battery.usable_soc",
    "battery.full_capacity",
    "battery.capacity_confidence",
    "meter.voltage",
    "meter.current",
    "meter.power",
    "meter.import",
    "meter.type",
    "control.kind",
    "control.direction",
    "control.unit",
    "control.min",
    "control.max",
    "control.step",
    "control.setpoint",
    "hvac.power",
    "hvac.state",
    "hvac.mode",
    "hvac.temperature",
    "hvac.outside_temperature",
    "hvac.target_temperature",
    "hvac.passenger_target_temperature",
    "hvac.min_temperature",
    "hvac.max_temperature",
    "hvac.fan_speed",
    "hvac.preconditioning",
    "hvac.defrost",
    "hvac.climate_keeper_mode",
    "hvac.battery.heating",
    "access.locked",
    "access.user_present",
    "closures.driver_front",
    "closures.passenger_front",
    "closures.driver_rear",
    "closures.passenger_rear",
    "closures.trunk",
    "closures.frunk",
    "closures.charge_port",
    "drive.gear",
    "drive.speed",
    "drive.power",
    "drive.odometer",
    "location.latitude",
    "location.longitude",
    "location.heading",
    "location.accuracy",
    "tyres.front_left.pressure",
    "tyres.front_right.pressure",
    "tyres.rear_left.pressure",
    "tyres.rear_right.pressure",
    "tyres.front_left.warning",
    "tyres.front_right.warning",
    "tyres.rear_left.warning",
    "tyres.rear_right.warning",
]);

static immutable VehicleElementType[vehicle_elements.length] vehicle_element_types =
[
    Type.string_, Type.string_, Type.string_, Type.string_, Type.string_, Type.string_,
    Type.string_, Type.int_, Type.string_, Type.bool_, Type.time, Type.string_, Type.int_,
    Type.bool_, Type.int_, Type.bool_, Type.int_, Type.bool_, Type.int_, Type.int_,
    Type.float_, Type.float_, Type.int_, Type.int_, Type.int_, Type.float_, Type.string_,
    Type.string_, Type.string_, Type.string_, Type.int_, Type.int_, Type.int_, Type.int_,
    Type.bool_, Type.string_, Type.string_, Type.float_, Type.float_, Type.float_,
    Type.float_, Type.float_, Type.float_, Type.int_, Type.bool_, Type.string_,
    Type.string_, Type.bool_, Type.bool_, Type.bool_, Type.string_, Type.string_,
    Type.string_, Type.string_, Type.string_, Type.string_, Type.string_, Type.string_,
    Type.float_, Type.int_, Type.float_, Type.float_, Type.float_, Type.float_, Type.float_,
    Type.float_, Type.float_, Type.float_, Type.float_, Type.bool_, Type.bool_, Type.bool_,
    Type.bool_,
];

static immutable ubyte['Y' - '1' + 1] vin_year_ordinals =
[
    22, 23, 24, 25, 26, 27, 28, 29, 30,
    0, 0, 0, 0, 0, 0, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13,
    0, 14, 0, 15, 16, 17, 0, 18, 19, 20, 21,
];

__gshared const String[12] nhtsa_element_ids = [
    StringLit!"info.manufacturer_name",
    StringLit!"info.brand_name",
    StringLit!"info.model_name",
    StringLit!"info.trim",
    StringLit!"info.series",
    StringLit!"info.body_class",
    StringLit!"info.drive_type",
    StringLit!"info.plant_city",
    StringLit!"info.plant_state",
    StringLit!"info.plant_country",
    StringLit!"info.plant_company",
    StringLit!"info.electrification",
];

enum none = ScaledUnit.init;

static immutable ScaledUnit[vehicle_elements.length] vehicle_element_units =
[
    none, none, none, none, none, none, none, none, none, none, none, none, ScaledUnits.minute, none,
    ScaledUnits.percent, none, none, none, ScaledUnits.percent, ScaledUnits.percent, ScaledUnits.kilowatt_hour,
    none, ScaledUnits.volt, ScaledUnits.ampere, ScaledUnits.watt, ScaledUnits.kilowatt_hour, none, none, none, none,
    ScaledUnits.ampere, ScaledUnits.ampere, ScaledUnits.ampere, ScaledUnits.ampere, none, none, none,
    ScaledUnits.celsius, ScaledUnits.celsius, ScaledUnits.celsius, ScaledUnits.celsius, ScaledUnits.celsius,
    ScaledUnits.celsius, none, none, none, none, none, none, none, none, none, none, none, none, none, none, none,
    ScaledUnits.kilometre_per_hour, ScaledUnits.kilowatt, ScaledUnits.kilometre, ScaledUnits.degree,
    ScaledUnits.degree, ScaledUnits.degree, ScaledUnits.metre, ScaledUnit(Pascal, 5), ScaledUnit(Pascal, 5),
    ScaledUnit(Pascal, 5), ScaledUnit(Pascal, 5), none, none, none, none,
];


static assert(VehicleElementType.sizeof == 1);
static assert(vehicle_components.length % 2 == 0);
static assert(vehicle_elements.length == vehicle_element_types.length);
static assert(vehicle_elements.length == vehicle_element_units.length);

void materialise_vehicle(Device vehicle, const(char)[] vin, bool changed)
{
    foreach (i; 0 .. vehicle_components.length / 2)
        ensure_component(vehicle, vehicle_components[i * 2][], vehicle_components[i * 2 + 1][], changed);

    foreach (i; 0 .. vehicle_elements.length)
        define_element(vehicle, vehicle_elements[i][], vehicle_element_formats[i], changed);

    changed |= set_default(vehicle, vehicle_elements[element_id!"info.type"][], StringLit!"vehicle");
    Element* serial = vehicle.find_element(vehicle_elements[element_id!"info.serial_number"][]);
    if (serial && serial.record_update() == SysTime())
    {
        serial.value(vin.make_string());
        changed = true;
    }
    changed |= set_default(vehicle, vehicle_elements[element_id!"control.kind"][], StringLit!"continuous");
    changed |= set_default(vehicle, vehicle_elements[element_id!"control.direction"][], StringLit!"consume");
    changed |= set_default(vehicle, vehicle_elements[element_id!"control.unit"][], StringLit!"A");
    changed |= set_default(vehicle, vehicle_elements[element_id!"control.min"][], 6);
    changed |= set_default(vehicle, vehicle_elements[element_id!"control.step"][], 1);
    changed |= set_default(vehicle, vehicle_elements[element_id!"meter.type"][], StringLit!"single-phase");

    VINInfo vi = decode_vin(vin);
    if (vi.manufacturer_name)
        changed |= set_default(vehicle, vehicle_elements[element_id!"info.manufacturer_name"][], vi.manufacturer_name);
    if (vi.manufacturer_id)
        changed |= set_default(vehicle, vehicle_elements[element_id!"info.manufacturer_id"][], vi.manufacturer_id);
    if (vi.model_name)
        changed |= set_default(vehicle, vehicle_elements[element_id!"info.model_name"][], vi.model_name);
    if (vi.manufacture_location)
        changed |= set_default(vehicle, vehicle_elements[element_id!"info.manufacture_location"][], vi.manufacture_location);
    if (vi.model_year != 0)
        changed |= set_default(vehicle, vehicle_elements[element_id!"info.model_year"][], vi.model_year);

    if (changed)
    {
        vehicle.notify(ComponentEvent.tree_changed);
        vehicle.notify(ComponentEvent.online);
    }
    enrich_from_nhtsa(vehicle, vin);
}

VINInfo decode_vin(const(char)[] vin)
{
    VINInfo info;
    if (vin.length != 17)
        return info;

    info.manufacturer_id = vin[0 .. 3].make_string();

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
            info.manufacture_location = StringLit!"USA"; // Exact plant is ambiguous from this WMI.
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

    info.model_year = decode_year_code(vin[9]);
    return info;
}

// ISO 3779 repeats year codes every 30 years; assume the 2010-2039 cycle.
int decode_year_code(char c) pure nothrow @nogc @safe
{
    uint i = uint(c - '1');
    if (i >= vin_year_ordinals.length)
        return 0;

    ubyte ordinal = vin_year_ordinals[i];
    return ordinal ? 2009 + ordinal : 0;
}

void enrich_from_nhtsa(Device vehicle, const(char)[] vin)
{
    bool required;
    foreach (ref id; nhtsa_element_ids)
    {
        Element* element = vehicle.find_element(id[]);
        if (!element || element.record_update() == SysTime())
        {
            required = true;
            break;
        }
    }
    if (!required)
        return;

    import urt.mem.temp : tconcat;

    auto ctx = alloc!NHTSALookup;
    ctx.vin = vin.make_string();

    const(char)[] url = tconcat("https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVin/", vin, "?format=json");
    if (!http_request(url, &ctx.on_response))
        free(ctx);
}

Component ensure_component(Component parent, const(char)[] id, const(char)[] template_, ref bool changed)
{
    if (Component component = parent.find_component(id))
    {
        if (!component.template_)
        {
            component.template_ = template_.make_string();
            changed = true;
        }
        return component;
    }

    Component component = alloc!Component(id.make_string());
    component.template_ = template_.make_string();
    parent.add_component(component);
    changed = true;
    return component;
}

Element* define_element(Component vehicle, const(char)[] path, FormatId format, ref bool changed, Access access = Access.read)
{
    Element* element = vehicle.find_element(path);
    if (!element)
    {
        element = vehicle.find_or_create_element(path, format);
        element.access = access;
        changed = true;
    }
    else
    {
        Access merged = cast(Access)(element.access | access);
        if (merged != element.access)
        {
            element.access = merged;
            changed = true;
        }
    }
    return element;
}

bool set_default(T)(Device vehicle, const(char)[] path, auto ref T value)
{
    Element* element = vehicle.find_element(path);
    if (!element)
    {
        element = vehicle.find_or_create_element(path, register_value_format(value));
        element.access = Access.read;
    }
    else if (element.record_update() != SysTime())
        return false;
    element.value(value);
    return true;
}


class NHTSALookup
{
nothrow @nogc:
    String vin;

    int on_response(ref const HTTPMessage msg)
    {
        scope(exit) free(this);

        if (msg.status_code != 200 || msg.content.length == 0)
            return 0;

        Variant root = parse_json(cast(const(char)[])msg.content[]);
        if (!root.isObject)
            return 0;
        const(Variant)* results = root.getMember("Results");
        if (!results || !results.isArray)
            return 0;

        Device* v = vin[] in g_app.devices;
        if (v is null)
            return 0;

        bool changed;
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
            changed |= set_default(*v, elem_path, value.make_string());
        }
        if (changed)
        {
            (*v).notify(ComponentEvent.tree_changed);
            (*v).notify(ComponentEvent.online);
        }

        return 0;
    }
}


unittest
{
    assert(decode_year_code('A') == 2010);
    assert(decode_year_code('Y') == 2030);
    assert(decode_year_code('1') == 2031);
    assert(decode_year_code('9') == 2039);
    assert(decode_year_code('0') == 0);
    assert(decode_year_code('I') == 0);
    assert(decode_year_code('Z') == 0);

    auto m3 = decode_vin("5YJ3E1EA5KF000001");
    assert(m3.manufacturer_name[] == "Tesla");
    assert(m3.manufacturer_id[] == "5YJ");
    assert(m3.model_name[] == "Model 3");
    assert(m3.manufacture_location[] == "Fremont, California, USA");
    assert(m3.model_year == 2019);

    assert(decode_vin("5YJSA1H22EFP00000").model_name[] == "Model S");
    assert(decode_vin("5YJSA1H22EFP00000").model_year == 2014);
    assert(decode_vin("5YJXCAE45GF000001").model_name[] == "Model X");
    assert(decode_vin("5YJYGDEE5LF000001").model_name[] == "Model Y");
    assert(decode_vin("5YJYGDEE5LF000001").model_year == 2020);

    auto berlin = decode_vin("XP7YGCEE5PB000001");
    assert(berlin.manufacturer_name[] == "Tesla");
    assert(berlin.manufacture_location[] == "Berlin-Brandenburg, Germany");
    assert(berlin.model_year == 2023);

    auto shanghai = decode_vin("LRW3E7FA5LC000001");
    assert(shanghai.manufacturer_name[] == "Tesla");
    assert(shanghai.manufacture_location[] == "Shanghai, China");

    auto unknown = decode_vin("7G2CEHED5RA000001");
    assert(unknown.manufacturer_name == String());
    assert(unknown.manufacturer_id[] == "7G2");
    assert(unknown.model_year == 2024);

    assert(decode_vin("").manufacturer_id == String());
    assert(decode_vin("TOO_SHORT").manufacturer_id == String());
}
