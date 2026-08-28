module apps.energy.vehicle;

import urt.format.json;
import urt.lifetime;
import urt.log : writeError;
import urt.map;
import urt.mem;
import urt.meta : Alias;
import urt.string;
import urt.time : SysTime;

import apps.energy.appliance;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

import protocol.http;
import protocol.http.message;

nothrow @nogc:


struct VINInfo
{
    String manufacturer_name;
    String manufacturer_id;
    String model_name;
    String manufacture_location;
    int model_year;
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


// Failure is intentionally silent because local VIN decoding remains usable.
// vehicle_for's existing-component check also deduplicates this request.
void enrich_from_nhtsa(const(char)[] vin)
{
    import urt.mem.temp : tconcat;

    auto ctx = alloc!NHTSALookup;
    ctx.vin = vin.make_string();

    const(char)[] url = tconcat("https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVin/", vin, "?format=json");
    if (!http_request(url, &ctx.on_response))
        free(ctx);
}

private class NHTSALookup
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
            (*v).set_element(elem_path, value.make_string());
        }

        return 0;
    }
}


struct CapacityEstimate
{
    float sum_weighted;
    float weight_total;
    uint sample_count;

    float mean_kwh() const pure nothrow @nogc
        => weight_total > 0 ? sum_weighted / weight_total : float.nan;
}

__gshared Map!(String, CapacityEstimate) g_capacity_estimates;

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


unittest
{
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


Component vehicle_for(const(char)[] vin)
{
    Device* existing = vin in g_app.devices;
    Device vehicle;
    bool is_new = existing is null;
    if (is_new)
    {
        vehicle = alloc!Device(vin.make_string());
        g_app.devices.insert(vehicle);
    }
    else
        vehicle = *existing;

    vehicle.template_ = StringLit!"Vehicle";
    materialise_vehicle(vehicle, vin, is_new);
    return vehicle;
}


Appliance vehicle_appliance_for(const(char)[] vin)
{
    Component vehicle = vehicle_for(vin);

    auto appliances = Collection!Appliance();
    Appliance appliance = appliances.get(vin);
    if (!appliance)
    {
        // TODO: remove this compatibility lookup after all configured car
        // appliances have migrated to VIN IDs. The display name belongs in
        // Vehicle.info.name; the Collection object name is its stable identity.
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


private Component ensure_component(Component parent, const(char)[] id, const(char)[] template_)
{
    if (Component component = parent.find_component(id))
        return component;

    Component component = alloc!Component(id.make_string());
    component.template_ = template_.make_string();
    parent.add_component(component);
    return component;
}

private Element* define_element(Component vehicle, const(char)[] path, FormatId format,
                                Access access = Access.read)
{
    Element* element = vehicle.find_element(path);
    if (!element)
    {
        element = vehicle.find_or_create_element(path, format);
        element.access = access;
    }
    else if (element.access == Access.none)
        element.access = access;
    return element;
}

private enum VehicleElementType : ubyte
{
    string_,
    int_,
    bool_,
    float_,
    time,
}

private __gshared FormatId[VehicleElementType.max + 1] vehicle_element_formats;

void init_vehicle_formats()
{
    vehicle_element_formats[VehicleElementType.string_] = register_value_format!String();
    vehicle_element_formats[VehicleElementType.int_] = register_value_format!int();
    vehicle_element_formats[VehicleElementType.bool_] = register_value_format!bool();
    vehicle_element_formats[VehicleElementType.float_] = register_value_format!float();
    vehicle_element_formats[VehicleElementType.time] = register_value_format!SysTime();
}

private static immutable vehicle_components = make_table!([
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

private static immutable vehicle_elements = make_table!([
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

private enum element_id(string id) = Alias!(vehicle_elements.find_first(id));

private alias Type = VehicleElementType;

private static immutable VehicleElementType[vehicle_elements.length] vehicle_element_types =
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

static assert(VehicleElementType.sizeof == 1);
static assert(vehicle_components.length % 2 == 0);
static assert(vehicle_elements.length == vehicle_element_types.length);

private void materialise_vehicle(Device vehicle, const(char)[] vin, bool is_new)
{
    foreach (i; 0 .. vehicle_components.length / 2)
        ensure_component(vehicle, vehicle_components[i * 2][], vehicle_components[i * 2 + 1][]);

    foreach (i; 0 .. vehicle_elements.length)
        define_element(vehicle, vehicle_elements[i][], vehicle_element_formats[vehicle_element_types[i]]);

    if (!is_new)
        return;

    vehicle.set_element(vehicle_elements[element_id!"info.type"][], StringLit!"vehicle");
    vehicle.set_element(vehicle_elements[element_id!"info.serial_number"][], vin.make_string());
    vehicle.set_element(vehicle_elements[element_id!"control.kind"][], StringLit!"continuous");
    vehicle.set_element(vehicle_elements[element_id!"control.direction"][], StringLit!"consume");
    vehicle.set_element(vehicle_elements[element_id!"control.unit"][], StringLit!"A");
    vehicle.set_element(vehicle_elements[element_id!"control.min"][], 6);
    vehicle.set_element(vehicle_elements[element_id!"control.step"][], 1);
    vehicle.set_element(vehicle_elements[element_id!"meter.type"][], StringLit!"single-phase");

    VINInfo vi = decode_vin(vin);
    if (vi.manufacturer_name)
        vehicle.set_element(vehicle_elements[element_id!"info.manufacturer_name"][], vi.manufacturer_name);
    if (vi.manufacturer_id)
        vehicle.set_element(vehicle_elements[element_id!"info.manufacturer_id"][], vi.manufacturer_id);
    if (vi.model_name)
        vehicle.set_element(vehicle_elements[element_id!"info.model_name"][], vi.model_name);
    if (vi.manufacture_location)
        vehicle.set_element(vehicle_elements[element_id!"info.manufacture_location"][], vi.manufacture_location);
    if (vi.model_year != 0)
        vehicle.set_element(vehicle_elements[element_id!"info.model_year"][], vi.model_year);

    vehicle.notify(ComponentEvent.tree_changed);
    vehicle.notify(ComponentEvent.online);
    enrich_from_nhtsa(vin);
}
