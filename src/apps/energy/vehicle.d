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

    info.manufacturer_id = vin[0 .. 3].makeString(defaultAllocator());

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
            v.set_element(elem_path, value.makeString(defaultAllocator()));
        }

        return 0;
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


// All vehicle sources converge on one VIN-keyed device.
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

    vehicle.set_element("info.type", StringLit!"vehicle");
    vehicle.set_element("info.serial_number", vin.makeString(defaultAllocator()));

    VINInfo vi = decode_vin(vin);
    if (vi.manufacturer_name)
        vehicle.set_element("info.manufacturer_name", vi.manufacturer_name);
    if (vi.manufacturer_id)
        vehicle.set_element("info.manufacturer_id", vi.manufacturer_id);
    if (vi.model_name)
        vehicle.set_element("info.model_name", vi.model_name);
    if (vi.manufacture_location)
        vehicle.set_element("info.manufacture_location", vi.manufacture_location);
    if (vi.model_year != 0)
        vehicle.set_element("info.model_year", vi.model_year);

    vehicle.set_element("control.kind", StringLit!"continuous");
    vehicle.set_element("control.direction", StringLit!"consume");
    vehicle.set_element("control.unit", StringLit!"A");
    vehicle.set_element("control.min", 6);
    vehicle.set_element("control.step", 1);

    vehicle.set_element("meter.type", StringLit!"single-phase");

    g_vehicles_device.notify(ComponentEvent.tree_changed);

    enrich_from_nhtsa(vin);

    return vehicle;
}
