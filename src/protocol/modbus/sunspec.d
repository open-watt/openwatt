module protocol.modbus.sunspec;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.si.unit;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;
import manager.profile : Frequency, freq_to_element_mode, find_known_element, KnownElementTemplate;
import manager.sampler;

import protocol.modbus;
import protocol.modbus.iface : ModbusProtocol;
import protocol.modbus.message;
import protocol.modbus.node;

import router.iface.packet : PCP;

private alias Access = manager.element.Access;

//version = DebugSunspec;
//version = DebugSunspecRegs;

nothrow @nogc:


// SunSpec inverter operating state (model 101/103 `St` enum16). When OpenWatt
// settles on a canonical InverterState vocabulary, SunSpec values map 1:1.
enum SunSpecInverterState : ushort
{
    off            = 1,
    sleeping       = 2,
    starting       = 3,
    mppt           = 4,
    throttled      = 5,
    shutting_down  = 6,
    fault          = 7,
    standby        = 8,
}

// SunSpec inverter event flags (model 101/103 `Evt1` bitfield32). Bits 16-31
// reserved by SunSpec for future expansion; `EvtVnd1..4` are vendor-specific
// and not represented here.
enum SunSpecInverterEvent : uint
{
    ground_fault       = 1u <<  0,
    dc_over_volt       = 1u <<  1,
    ac_disconnect      = 1u <<  2,
    dc_disconnect      = 1u <<  3,
    grid_disconnect    = 1u <<  4,
    cabinet_open       = 1u <<  5,
    manual_shutdown    = 1u <<  6,
    over_temp          = 1u <<  7,
    over_frequency     = 1u <<  8,
    under_frequency    = 1u <<  9,
    ac_over_volt       = 1u << 10,
    ac_under_volt      = 1u << 11,
    blown_string_fuse  = 1u << 12,
    under_temp         = 1u << 13,
    memory_loss        = 1u << 14,
    hw_test_failure    = 1u << 15,
}


// SunSpec discovery constants

private enum ushort SUNS_REG0  = 0x5375; // 'S','u'
private enum ushort SUNS_REG1  = 0x6E53; // 'n','S'
private enum ushort END_MODEL  = 0xFFFF;

private static immutable ushort[3] sunspec_bases = [ 0, 40_000, 50_000 ];


// Field descriptor catalogue
//
// Each SunSpec model is described as a list of components to create and a list
// of fields placed within those components. Offsets are register offsets within
// the model's *data* (i.e. after the 2-register {id, len} header).

private enum FieldType : ubyte
{
    u16,
    i16,
    u32,
    i32,
    acc32,
    f32,
    str_,
    enum16,      // uint16 + enumeration flag; `unit` holds enum type name
    bitfield32,  // uint32 + bitfield + enumeration; `unit` holds enum type name
}

private struct ComponentDef
{
    string path;        // dotted path from device root (e.g. "inverter.solar.meter")
    string template_;
    string type_value;  // optional fixed value for the 'type' element
}

private struct FieldDef
{
    ubyte component_index;
    string id;
    string unit;        // SunSpec native unit; null for unitless
    ushort offset;
    short scale_off;    // -1 if no scale; else reg offset of sunssf within model data
    FieldType type;
    ubyte str_words;
    Frequency freq;
    Access access = Access.read;
}

// Repeating block (used by Model 160, 64111, etc). N instances of a fixed-size
// record live after the model's fixed section. SFs typically live in the fixed
// section and are referenced by all instances.
private struct RepeatBlock
{
    ushort count_offset;                   // .d offset of N register (count of instances)
    ushort first_offset;                   // .d offset where the first instance starts
    ushort stride;                         // words per instance
    string path_prefix;                    // e.g. "inverter.solar.string" — instance index appended
    immutable(ComponentDef)[] components;  // paths RELATIVE to the per-instance root
    immutable(FieldDef)[] fields;          // offsets are WITHIN the instance; scale_off is the model's .d
}

private struct ModelMapping
{
    ushort model_id;
    string device_type;  // value for DeviceInfo.type (single device_type per binding)
    immutable(ComponentDef)[] components;
    immutable(FieldDef)[] fields;
    RepeatBlock repeat;  // empty if model has no repeating section
}


// Model 1: Common

private immutable ComponentDef[] m1_components = [
    ComponentDef("info", "DeviceInfo", null),
];
private immutable FieldDef[] m1_fields = [
    FieldDef(0, "manufacturer_name", null,  0, -1, FieldType.str_, 16, Frequency.constant),
    FieldDef(0, "model_name",        null, 16, -1, FieldType.str_, 16, Frequency.constant),
    FieldDef(0, "firmware_version",  null, 40, -1, FieldType.str_,  8, Frequency.constant),
    FieldDef(0, "serial_number",     null, 48, -1, FieldType.str_, 16, Frequency.constant),
];

// Models 101/102/103: Inverter (integer with scale factors).
//
// Component layout (per COMPONENT_TEMPLATES.md "Inverter" sub-components):
//   0: inverter              (Inverter)         - top-level inverter component
//   1: inverter.solar        (Solar)            - PV input
//   2: inverter.solar.meter  (EnergyMeter dc)   - DC measurements at the inverter's PV input
//   3: inverter.load         (EnergyMeter ac)   - inverter's own AC output measurements

private immutable ComponentDef[] inverter_components_single = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("inverter.solar",       "Solar",       null),
    ComponentDef("inverter.solar.meter", "EnergyMeter", "dc"),
    ComponentDef("inverter.load",        "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] inverter_components_three = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("inverter.solar",       "Solar",       null),
    ComponentDef("inverter.solar.meter", "EnergyMeter", "dc"),
    ComponentDef("inverter.load",        "EnergyMeter", "three-phase"),
];

private immutable FieldDef[] m101_fields = [
    // AC output -> inverter.load
    FieldDef(3, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
    // DC input -> inverter.solar.meter
    FieldDef(2, "current",        "A",    25, 26, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    27, 28, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    29, 30, FieldType.i16,   0, Frequency.realtime),
    // Inverter status -> inverter
    FieldDef(0, "cabinet_temp",   null,   31, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   32, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 33, 35, FieldType.i16,   0, Frequency.low),
    // Operating state + event flags (SunSpec model 101 St / Evt1)
    FieldDef(0, "state",  "SunSpecInverterState", 36, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 38, -1, FieldType.bitfield32, 0, Frequency.high),
];

private immutable FieldDef[] m102_fields = [
    FieldDef(3, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "current1",       "A",     1,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "current2",       "A",     2,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage1",       "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage2",       "V",     9, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "ipv1",           "V",     5, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
    FieldDef(2, "current",        "A",    25, 26, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    27, 28, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    29, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "cabinet_temp",   null,   31, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   32, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 33, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "state",  "SunSpecInverterState", 36, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 38, -1, FieldType.bitfield32, 0, Frequency.high),
];

private immutable FieldDef[] m103_fields = [
    FieldDef(3, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "current1",       "A",     1,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "current2",       "A",     2,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "current3",       "A",     3,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage1",       "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage2",       "V",     9, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "voltage3",       "V",    10, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "ipv1",           "V",     5, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "ipv2",           "V",     6, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "ipv3",           "V",     7, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
    FieldDef(2, "current",        "A",    25, 26, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    27, 28, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    29, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "cabinet_temp",   null,   31, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   32, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 33, 35, FieldType.i16,   0, Frequency.low),
    FieldDef(0, "state",  "SunSpecInverterState", 36, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 38, -1, FieldType.bitfield32, 0, Frequency.high),
];

// Models 111/112/113: Inverter (float32). No scale factors; each f32 is 2 regs.

private immutable FieldDef[] m111_fields = [
    FieldDef(3, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
    FieldDef(2, "current",        "A",    32, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    34, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    36, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(0, "cabinet_temp",   null,   38, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   40, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 42, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "state",  "SunSpecInverterState", 46, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 48, -1, FieldType.bitfield32, 0, Frequency.high),
];

private immutable FieldDef[] m112_fields = [
    FieldDef(3, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "current1",       "A",     2, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "current2",       "A",     4, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage1",       "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage2",       "V",    16, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "ipv1",           "V",     8, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
    FieldDef(2, "current",        "A",    32, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    34, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    36, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(0, "cabinet_temp",   null,   38, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   40, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 42, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "state",  "SunSpecInverterState", 46, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 48, -1, FieldType.bitfield32, 0, Frequency.high),
];

private immutable FieldDef[] m113_fields = [
    FieldDef(3, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "current1",       "A",     2, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "current2",       "A",     4, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "current3",       "A",     6, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage1",       "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage2",       "V",    16, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "voltage3",       "V",    18, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "ipv1",           "V",     8, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "ipv2",           "V",    10, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "ipv3",           "V",    12, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(3, "export",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
    FieldDef(2, "current",        "A",    32, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "voltage",        "V",    34, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(2, "power",          "W",    36, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(0, "cabinet_temp",   null,   38, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "heatsink_temp",  null,   40, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "transformer_temp", null, 42, -1, FieldType.f32,   0, Frequency.low),
    FieldDef(0, "state",  "SunSpecInverterState", 46, -1, FieldType.enum16,    0, Frequency.high),
    FieldDef(0, "events", "SunSpecInverterEvent", 48, -1, FieldType.bitfield32, 0, Frequency.high),
];

// Models 201/203: AC Meter (integer with scale factors).
//
// Placed at device root as `meter`. For SolarEdge installs this is the grid-side
// CT meter sitting behind the inverter; for standalone meter devices it's just
// the meter. Either reading is "the external AC measurement", so a top-level
// `meter` component is the right home.

private immutable ComponentDef[] meter_single_components = [
    ComponentDef("meter", "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] meter_three_components = [
    ComponentDef("meter", "EnergyMeter", "three-phase"),
];

// When a meter model coexists with an inverter on the same physical device
// (e.g. SolarEdge with its grid CT), the meter is the inverter's external
// export reference, not the device's primary meter. Place it under the
// Inverter component as `export_meter` per the COMPONENT_TEMPLATES spec.
private immutable ComponentDef[] inverter_export_meter_single_components = [
    ComponentDef("inverter.export_meter", "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] inverter_export_meter_three_components = [
    ComponentDef("inverter.export_meter", "EnergyMeter", "three-phase"),
];

private immutable FieldDef[] m203_fields = [
    FieldDef(0, "current",      "A",     0,  4, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "current1",     "A",     1,  4, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "current2",     "A",     2,  4, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "current3",     "A",     3,  4, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "voltage",      "V",     5, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "voltage1",     "V",     6, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "voltage2",     "V",     7, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "voltage3",     "V",     8, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "ipv",          "V",     9, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "ipv1",         "V",    10, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "ipv2",         "V",    11, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "ipv3",         "V",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "frequency",    "Hz",   14, 15, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "power",        "W",    16, 20, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "power1",       "W",    17, 20, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "power2",       "W",    18, 20, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "power3",       "W",    19, 20, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "apparent",     "VA",   21, 25, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "apparent1",    "VA",   22, 25, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "apparent2",    "VA",   23, 25, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "apparent3",    "VA",   24, 25, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "reactive",     "var",  26, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "reactive1",    "var",  27, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "reactive2",    "var",  28, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "reactive3",    "var",  29, 30, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "pf",           "%",    31, 35, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "pf1",          "%",    32, 35, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "pf2",          "%",    33, 35, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "pf3",          "%",    34, 35, FieldType.i16,   0, Frequency.realtime),
    FieldDef(0, "export",       "Wh",   36, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "export1",      "Wh",   38, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "export2",      "Wh",   40, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "export3",      "Wh",   42, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "import",       "Wh",   44, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "import1",      "Wh",   46, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "import2",      "Wh",   48, 52, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "import3",      "Wh",   50, 52, FieldType.acc32, 0, Frequency.medium),
    // Apparent energy, split by active flow direction at sample time
    FieldDef(0, "apparent_export",  "VAh",  53, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_export1", "VAh",  55, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_export2", "VAh",  57, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_export3", "VAh",  59, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_import",  "VAh",  61, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_import1", "VAh",  63, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_import2", "VAh",  65, 69, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "apparent_import3", "VAh",  67, 69, FieldType.acc32, 0, Frequency.medium),
    // Reactive energy by PQ quadrant (lossless; inductive/capacitive/net derive from these)
    FieldDef(0, "q1",           "varh", 70, 102, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "q2",           "varh", 78, 102, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "q3",           "varh", 86, 102, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "q4",           "varh", 94, 102, FieldType.acc32, 0, Frequency.medium),
    // Meter event flags (no canonical enum yet — exposed as raw bitfield32)
    FieldDef(0, "events",       null,  103, -1, FieldType.bitfield32, 0, Frequency.high),
];

// Model 702: DER Capacity (static nameplate ratings -> inverter.config).
// SF block lives at the END of the model: W_SF=43, PF_SF=44, VA_SF=45, Var_SF=46,
// V_SF=47, A_SF=48, S_SF=49 (in .d offsets, i.e. spec-2).
//
// We expose ratings only; the parallel settings block (WMax/VNom/etc. at .d 24-42)
// is RW and properly belongs on a separate "settings" surface, not InverterConfig.

private immutable ComponentDef[] m702_components = [
    ComponentDef("inverter",        "Inverter",       null),
    ComponentDef("inverter.config", "InverterConfig", null),
];

private immutable FieldDef[] m702_fields = [
    FieldDef(1, "rated_power",            "W",   0, 43, FieldType.u16, 0, Frequency.constant),  // WMaxRtg
    FieldDef(1, "rated_apparent",         "VA",  5, 45, FieldType.u16, 0, Frequency.constant),  // VAMaxRtg
    FieldDef(1, "rated_reactive_inject",  "var", 6, 46, FieldType.u16, 0, Frequency.constant),  // VarMaxInjRtg
    FieldDef(1, "rated_reactive_absorb",  "var", 7, 46, FieldType.u16, 0, Frequency.constant),  // VarMaxAbsRtg
    FieldDef(1, "voltage_nominal",        "V",  12, 47, FieldType.u16, 0, Frequency.constant),  // VNomRtg
    FieldDef(1, "voltage_max",            "V",  13, 47, FieldType.u16, 0, Frequency.constant),  // VMaxRtg
    FieldDef(1, "voltage_min",            "V",  14, 47, FieldType.u16, 0, Frequency.constant),  // VMinRtg
    FieldDef(1, "rated_current",          "A",  15, 48, FieldType.u16, 0, Frequency.constant),  // AMaxRtg
    FieldDef(1, "pf_over_excited",        null, 16, 44, FieldType.u16, 0, Frequency.constant),  // PFOvrExtRtg
    FieldDef(1, "pf_under_excited",       null, 17, 44, FieldType.u16, 0, Frequency.constant),  // PFUndExtRtg
    FieldDef(1, "intentional_islanding",  null, 23, -1, FieldType.u16, 0, Frequency.constant),  // IntIslandCatRtg (bitfield16; raw u16 for now)
];


// Model 160: Multi-MPPT Inverter Extension (repeating per-input DC telemetry).
// Fixed section holds 4 SFs + Evt + N + TmsPer; each repeating instance has
// 20 words (ID, IDStr, DCA, DCV, DCW, DCWH, Tms, Tmp, DCSt, DCEvt).

private immutable FieldDef[] m160_fields = [];  // fixed-block fields we expose go here if needed

private immutable ComponentDef[] m160_repeat_components = [
    ComponentDef("",      "Solar",       null),    // the stringN component itself
    ComponentDef("info",  "DeviceInfo",  "input"), // per-input identity (model_id, name)
    ComponentDef("meter", "EnergyMeter", "dc"),    // DC measurements
];

private immutable FieldDef[] m160_repeat_fields = [
    FieldDef(1, "model_id", null, 0, -1, FieldType.u16,   0, Frequency.constant),
    FieldDef(1, "name",     null, 1, -1, FieldType.str_,  8, Frequency.constant),
    FieldDef(2, "current",  "A",  9,  0, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "voltage",  "V", 10,  1, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "power",    "W", 11,  2, FieldType.u16,   0, Frequency.realtime),
    FieldDef(2, "import",   "Wh", 12, 3, FieldType.acc32, 0, Frequency.medium),
    FieldDef(0, "temp",     "C", 16, -1, FieldType.i16,   0, Frequency.medium),
    FieldDef(0, "state",    "SunSpecInverterState", 17, -1, FieldType.enum16, 0, Frequency.high),
    FieldDef(0, "events",   null, 18, -1, FieldType.bitfield32, 0, Frequency.high),
];


private immutable ModelMapping[] g_models = [
    ModelMapping(  1, null,           m1_components,                  m1_fields),
    ModelMapping(101, "inverter",     inverter_components_single,     m101_fields),
    ModelMapping(102, "inverter",     inverter_components_three,      m102_fields),
    ModelMapping(103, "inverter",     inverter_components_three,      m103_fields),
    ModelMapping(111, "inverter",     inverter_components_single,     m111_fields),
    ModelMapping(112, "inverter",     inverter_components_three,      m112_fields),
    ModelMapping(113, "inverter",     inverter_components_three,      m113_fields),
    ModelMapping(160, "inverter",     [],                             m160_fields,
                 RepeatBlock(6, 8, 20, "inverter.solar.string", m160_repeat_components, m160_repeat_fields)),
    ModelMapping(203, "energy-meter", meter_three_components,         m203_fields),
    ModelMapping(702, "inverter",     m702_components,                m702_fields),
];

private const(ModelMapping)* find_model_mapping(ushort id) pure
{
    foreach (ref m; g_models)
        if (m.model_id == id)
            return &m;
    return null;
}


// SunspecBinding

class SunspecBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("node", node),
                                 Prop!("slave", slave));
nothrow @nogc:

    enum type_name = "sunspec-binding";
    enum path = "/binding/sunspec";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SunspecBinding, id, flags);
    }

    final inout(ModbusNode) node() inout pure
        => _node.get;
    final void node(ModbusNode value)
    {
        if (_node.get is value)
            return;
        teardown_node();
        _node = value;
        _slave_server = null;
        restart();
    }

    final ref const(String) slave() const pure
        => _slave_name;
    final void slave(String value)
    {
        if (value == _slave_name)
            return;
        _slave_name = value.move;
        _slave_server = null;
        restart();
    }

    final override bool validate() const pure
    {
        if (!_node.get || _device.empty || _slave_name.empty)
            return false;
        return true;
    }

    override CompletionStatus startup()
    {
        ModbusNode c = _node.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        if (!_slave_server)
        {
            _slave_server = get_module!ModbusProtocolModule.find_server_by_name(_slave_name[]);
            if (!_slave_server)
            {
                log.warning("slave '", _slave_name, "' not found");
                return CompletionStatus.error;
            }
            version (DebugSunspec)
                log.tracef("resolved slave '{0}' -> universal address {1}", _slave_name[], _slave_server.universal_address);
        }

        if (!_subscribed)
        {
            c.subscribe(&node_state_change);
            _subscribed = true;
        }

        final switch (_phase)
        {
            case Phase.idle:
                _phase = Phase.probing;
                _probe_index = 0;
                _chain_count = 0;
                _active_chain = 0;
                foreach (ref ch; _chains)
                    ch.scan_buffer.clear();
                _models_chain.clear();
                goto case;

            case Phase.probing:
                return drive_probe(c);

            case Phase.scanning:
                return drive_scan(c);

            case Phase.materialising:
                if (!materialise_device())
                    return CompletionStatus.error;
                _phase = Phase.running;
                foreach (ref ch; _chains)
                    ch.scan_buffer.clear();
                _needs_sort = true;
                version (DebugSunspec)
                    log.tracef("running: {0} sample entries", sample_entries.length);
                return CompletionStatus.complete;

            case Phase.running:
                return CompletionStatus.complete;
        }
    }

    override CompletionStatus shutdown()
    {
        teardown_node();
        sample_entries.clear();
        foreach (ref ch; _chains)
            ch.scan_buffer.clear();
        _models_chain.clear();
        _slave_server = null;
        _phase = Phase.idle;
        _probe_index = 0;
        _chain_count = 0;
        _active_chain = 0;
        _in_flight = false;
        _failed = false;
        _scan_eol = false;
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_phase != Phase.running)
            return;

        if (_needs_sort)
        {
            import urt.algorithm : qsort;
            qsort!((ref a, ref b) => a.register < b.register ? -1 : a.register > b.register ? 1 : 0)(sample_entries[]);
            _needs_sort = false;
        }

        ModbusNode c = _node.get;
        if (!c)
            return;

        enum MaxRegs = 125;
        enum MaxGap  = 16;

        MonoTime now = getTime();

        size_t i = 0;
        while (i < sample_entries.length)
        {
            if ((sample_entries[i].flags & 3)
                || sample_entries[i].sampleTimeMs == ushort.max
                || now - sample_entries[i].lastUpdate < msecs(sample_entries[i].sampleTimeMs))
            {
                ++i;
                continue;
            }

            ushort first = sample_entries[i].register;
            ushort count = sample_entries[i].seqLen;
            sample_entries[i].flags |= 1;

            size_t j = i + 1;
            for (; j < sample_entries.length; ++j)
            {
                if ((sample_entries[j].flags & 3)
                    || sample_entries[j].sampleTimeMs == ushort.max
                    || now - sample_entries[j].lastUpdate < msecs(sample_entries[j].sampleTimeMs))
                    continue;

                ushort next_reg = sample_entries[j].register;
                int last = next_reg + sample_entries[j].seqLen;
                if (last - first > MaxRegs)
                    break;
                if (next_reg >= first + count + MaxGap)
                    break;

                count = cast(ushort)(last - first);
                sample_entries[j].flags |= 1;
            }

            ModbusPDU pdu = createMessage_Read(RegisterType.holding_register, first, count);
            version (DebugSunspecRegs)
                log.tracef("read: {0} regs at {1}", count, first);
            if (!c.sendRequest(_slave_server.universal_address, pdu, &response_handler, &error_handler, 0, 1000, PCP.be, false))
            {
                for (size_t k = i; k < j; ++k)
                    sample_entries[k].flags &= 0xFE;
            }
            i = j;
        }
    }

protected:

    enum Phase : ubyte { idle, probing, scanning, materialising, running }

    struct SampleEntry
    {
        SysTime lastUpdate;
        ushort register;
        ubyte regKind = 4; // holding registers only for SunSpec
        ubyte flags;       // bit0 = in-flight, bit1 = constant-sampled
        ushort sampleTimeMs;
        Element* element;
        ValueDesc desc;
        uint sentinel;     // value-not-implemented sentinel; 0 means "no filter"
                           // checked against either 16- or 32-bit reads based on desc.data_length

        ubyte seqLen() const pure nothrow @nogc
            => cast(ubyte)(desc.data_length / 2);
    }

    struct ModelLoc
    {
        ushort model_id;
        ushort header_reg;
        ushort data_reg;
        ushort length;
        ubyte chain_index;   // which _chains entry this model belongs to
    }

    // SolarEdge (and similar) expose more than one parallel SunSpec chain — e.g.
    // a base-0 chain with the DER models and a base-40000 chain with model 160
    // and vendor extensions. Each chain is scanned independently into its own
    // buffer and the resulting ModelLocs are aggregated.
    struct ChainData
    {
        ushort base_reg;
        Array!ushort scan_buffer;   // values keyed by (reg - base_reg)
    }

    ObjectRef!ModbusNode _node;
    String _slave_name;
    ServerMap* _slave_server;
    Phase _phase;
    bool _subscribed;
    bool _in_flight;
    bool _failed;
    bool _scan_eol;       // device returned exception past valid SunSpec data
    bool _needs_sort;

    ubyte _probe_index;    // index into sunspec_bases for the probing pass
    ubyte _chain_count;    // number of chains discovered (entries used in _chains)
    ubyte _active_chain;   // chain currently being scanned/walked

    ChainData[sunspec_bases.length] _chains;
    Array!ModelLoc _models_chain;
    Array!SampleEntry sample_entries;

private:

    void teardown_node()
    {
        if (_subscribed && _node.get)
        {
            _node.unsubscribe(&node_state_change);
            _subscribed = false;
        }
    }

    void node_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    // Discovery: probe every candidate base. Each base that returns a "SunS"
    // marker becomes its own chain; SolarEdge in particular exposes parallel
    // chains at base 0 and base 40000.

    CompletionStatus drive_probe(ModbusNode c)
    {
        if (_in_flight)
            return CompletionStatus.continue_;

        if (_probe_index >= sunspec_bases.length)
        {
            if (_chain_count == 0)
            {
                log.warning("no SunSpec marker found at standard bases (0, 40000, 50000)");
                return CompletionStatus.error;
            }
            _active_chain = 0;
            _phase = Phase.scanning;
            version (DebugSunspec)
                log.tracef("probing complete: {0} chain(s) discovered", _chain_count);
            return CompletionStatus.continue_;
        }

        ushort base = sunspec_bases[_probe_index];
        version (DebugSunspec)
            log.tracef("probing for SunSpec marker at base {0}", base);
        ModbusPDU pdu = createMessage_Read(RegisterType.holding_register, base, 2);
        if (!c.sendRequest(_slave_server.universal_address, pdu, &probe_response_handler, &probe_error_handler, 0, 1000))
            return CompletionStatus.error;
        _in_flight = true;
        return CompletionStatus.continue_;
    }

    void probe_response_handler(ref const ModbusPDU req, ref ModbusPDU resp, SysTime, SysTime)
    {
        _in_flight = false;
        ushort base = sunspec_bases[_probe_index];
        ++_probe_index;

        if (resp.function_code & 0x80 || resp.data.length < 5)
        {
            version (DebugSunspec)
                log.tracef("probe at base {0}: exception or short response", base);
            return;
        }
        ushort r0 = (cast(ushort)resp.data[1] << 8) | resp.data[2];
        ushort r1 = (cast(ushort)resp.data[3] << 8) | resp.data[4];
        if (r0 != SUNS_REG0 || r1 != SUNS_REG1)
        {
            version (DebugSunspec)
                log.tracef("probe at base {0}: not SunSpec (got {1,04x} {2,04x})", base, r0, r1);
            return;
        }

        _chains[_chain_count].base_reg = base;
        _chains[_chain_count].scan_buffer.clear();
        _chains[_chain_count].scan_buffer ~= r0;
        _chains[_chain_count].scan_buffer ~= r1;
        ++_chain_count;
        version (DebugSunspec)
            log.tracef("found SunSpec marker at base {0} (chain {1})", base, _chain_count - 1);
    }

    void probe_error_handler(ModbusErrorType ty, ref const ModbusPDU, SysTime)
    {
        if (ty == ModbusErrorType.Retrying)
            return;
        _in_flight = false;
        ++_probe_index;  // advance past the failed probe
    }

    // Discovery: walk each chain's model list, reading 125-register chunks as
    // needed. After a chain ends (either via 0xFFFF terminator or a past-the-end
    // exception/timeout), advance to the next chain. Materialise once all chains
    // are walked.

    CompletionStatus drive_scan(ModbusNode c)
    {
        if (_in_flight)
            return CompletionStatus.continue_;

        auto chain = &_chains[_active_chain];

        if (_scan_eol)
        {
            // device responded with an exception (or stopped responding) past valid
            // data; not every device writes the 0xFFFF terminator. Treat as end-of-
            // chain regardless — count_models_in_chain isn't free, but the chain has
            // already populated _models_chain with anything valid.
            version (DebugSunspec)
                log.tracef("scan: chain at base {0} end-of-data (no 0xFFFF terminator)", chain.base_reg);
            return advance_chain_or_materialise();
        }
        if (_failed)
        {
            log.warning("SunSpec scan failed at base ", chain.base_reg, "; abandoning chain");
            return advance_chain_or_materialise();
        }

        // walk known headers, starting after the 2-reg "SunS" marker
        size_t walked = 2;
        while (true)
        {
            if (walked + 2 > chain.scan_buffer.length)
                return issue_scan_read(c, cast(ushort)(chain.base_reg + chain.scan_buffer.length));

            ushort id = chain.scan_buffer[walked];
            ushort len = chain.scan_buffer[walked + 1];

            if (id == END_MODEL)
            {
                version (DebugSunspec)
                    log.tracef("scan: end of model list at reg {0} (chain {1})", chain.base_reg + walked, _active_chain);
                return advance_chain_or_materialise();
            }

            ushort header_reg = cast(ushort)(chain.base_reg + walked);
            bool seen;
            foreach (ref ml; _models_chain)
                if (ml.chain_index == _active_chain && ml.header_reg == header_reg)
                {
                    seen = true;
                    break;
                }
            if (!seen)
            {
                _models_chain ~= ModelLoc(id, header_reg, cast(ushort)(header_reg + 2), len, _active_chain);
                version (DebugSunspec)
                    log.tracef("scan: model {0} (len {1}) at reg {2}", id, len, header_reg);
                if (find_model_mapping(id) is null)
                    log.warning("SunSpec model ", id, " advertised at reg ", header_reg, " is not implemented; skipped");
            }

            size_t end = walked + 2 + len;
            if (end > chain.scan_buffer.length)
                return issue_scan_read(c, cast(ushort)(chain.base_reg + chain.scan_buffer.length));
            walked = end;
        }
    }

    CompletionStatus advance_chain_or_materialise()
    {
        _scan_eol = false;
        _failed = false;
        ++_active_chain;
        if (_active_chain >= _chain_count)
        {
            if (_models_chain.length == 0)
            {
                log.warning("SunSpec discovery: no models found in any chain; aborting");
                return CompletionStatus.error;
            }
            _phase = Phase.materialising;
        }
        return CompletionStatus.continue_;
    }

    CompletionStatus issue_scan_read(ModbusNode c, ushort first)
    {
        enum ushort ChunkRegs = 125;
        version (DebugSunspec)
            log.tracef("scan: read {0} regs at {1}", ChunkRegs, first);
        ModbusPDU pdu = createMessage_Read(RegisterType.holding_register, first, ChunkRegs);
        if (!c.sendRequest(_slave_server.universal_address, pdu, &scan_response_handler, &scan_error_handler, 0, 1000))
            return CompletionStatus.error;
        _in_flight = true;
        return CompletionStatus.continue_;
    }

    void scan_response_handler(ref const ModbusPDU req, ref ModbusPDU resp, SysTime, SysTime)
    {
        _in_flight = false;
        if (resp.function_code & 0x80)
        {
            // exception past valid data; drive_scan converts this to end-of-chain
            _scan_eol = true;
            return;
        }
        ushort first = (cast(ushort)req.data[0] << 8) | req.data[1];
        ushort count = (cast(ushort)req.data[2] << 8) | req.data[3];
        if (resp.data.length < 1 + count * 2 || resp.data[0] != count * 2)
        {
            _failed = true;
            return;
        }

        auto chain = &_chains[_active_chain];
        size_t offset = first - chain.base_reg;
        if (chain.scan_buffer.length < offset + count)
            chain.scan_buffer.resize(offset + count);
        ushort[] slice = chain.scan_buffer[];
        for (size_t i = 0; i < count; ++i)
        {
            ushort r = cast(ushort)((cast(ushort)resp.data[1 + i*2] << 8) | resp.data[2 + i*2]);
            slice[offset + i] = r;
        }
    }

    void scan_error_handler(ModbusErrorType ty, ref const ModbusPDU, SysTime)
    {
        if (ty == ModbusErrorType.Retrying)
            return;
        _in_flight = false;
        // Many devices don't write 0xFFFF terminator AND don't return a Modbus
        // exception past valid data — they just drop the request. Treat that as
        // chain end if we've already walked at least one header in this chain.
        bool walked_any;
        foreach (ref ml; _models_chain)
            if (ml.chain_index == _active_chain)
            {
                walked_any = true;
                break;
            }
        if (walked_any)
            _scan_eol = true;
        else
            _failed = true;
    }

    // Materialise: walk _models_chain, build Device tree from g_models catalogue.

    bool materialise_device()
    {
        Device device;
        bool is_new = false;
        if (Device* existing = _device[] in g_app.devices)
            device = *existing;
        else
        {
            device = g_app.allocator.allocT!Device(_device[].makeString(g_app.allocator));
            is_new = true;
        }
        version (DebugSunspec)
            log.tracef("materialise: device '{0}' ({1}) from {2} model(s)", _device[], is_new ? "new" : "existing", _models_chain.length);

        string device_type;
        bool has_inverter;
        foreach (ref ml; _models_chain)
        {
            const(ModelMapping)* mm = find_model_mapping(ml.model_id);
            if (mm && mm.device_type)
            {
                if (!device_type)
                    device_type = mm.device_type;
                if (mm.device_type == "inverter")
                    has_inverter = true;
            }
        }

        // Pre-create info/type so it lands first in DeviceInfo ahead of the m1 fields
        if (device_type)
        {
            Component info = find_or_create_component(device, ComponentDef("info", "DeviceInfo", null));
            set_type_element(info, "DeviceInfo", device_type);
        }

        // Skip duplicate models. SolarEdge exposes parallel chains at base 0 and
        // base 40000 that mirror the same physical device — without dedup we'd
        // materialise every model twice and poll every register from both chains.
        // Also handles intra-chain repeats like the two Common Models that follow
        // an inverter+meter pair.
        foreach (size_t i, ref ml; _models_chain)
        {
            bool already_seen = false;
            foreach (size_t j; 0 .. i)
            {
                if (_models_chain[j].model_id == ml.model_id)
                {
                    already_seen = true;
                    break;
                }
            }
            if (already_seen)
            {
                version (DebugSunspec)
                    log.tracef("materialise: skipping duplicate model {0} at reg {1}", ml.model_id, ml.header_reg);
                continue;
            }

            const(ModelMapping)* mm = find_model_mapping(ml.model_id);
            if (!mm)
                continue;  // already warned during scan

            // Context-sensitive component layout: meter models that share a
            // device with an inverter map to inverter.export_meter, not the
            // device-root meter slot.
            const(ComponentDef)[] comp_defs = mm.components;
            if (has_inverter)
            {
                if (ml.model_id == 203)
                    comp_defs = inverter_export_meter_three_components;
                else if (ml.model_id == 201)
                    comp_defs = inverter_export_meter_single_components;
            }

            assert(comp_defs.length <= 8, "extend comps[] if more components per model are needed");
            Component[8] comps;
            foreach (ci, ref cd; comp_defs)
            {
                comps[ci] = find_or_create_component(device, cd);
                if (cd.type_value)
                    set_type_element(comps[ci], cd.template_, cd.type_value);
            }
            version (DebugSunspec)
                log.tracef("materialise: model {0} -> {1} component(s), {2} field(s)", ml.model_id, mm.components.length, mm.fields.length);

            foreach (ref fd; mm.fields)
                emit_field(ml, *mm, fd, comps[fd.component_index]);

            if (mm.repeat.stride > 0 && mm.repeat.fields.length > 0)
                materialise_repeat(ml, *mm, device);
        }

        materialise_network(device);

        if (is_new)
            g_app.devices.insert(device.id[], device);

        device.notify(ComponentEvent.tree_changed);
        device.notify(ComponentEvent.online);
        return true;
    }

    void materialise_network(Component device)
    {
        if (!_slave_server)
            return;

        Component status = find_or_create_component(device, ComponentDef("status", "DeviceStatus", null));
        Component network = find_or_create_component(status, ComponentDef("network", "Network", null));
        set_const_element(network, "Network", "mode", Variant("modbus"));

        Component modbus = find_or_create_component(network, ComponentDef("modbus", "Modbus", null));
        set_const_element(modbus, "Modbus", "status", Variant("online"));
        set_const_element(modbus, "Modbus", "address", Variant(cast(uint)_slave_server.local_address));

        if (_slave_server.iface)
        {
            string variant;
            final switch (_slave_server.iface.protocol)
            {
                case ModbusProtocol.rtu:     variant = "rtu";     break;
                case ModbusProtocol.tcp:     variant = "tcp";     break;
                case ModbusProtocol.ascii:   variant = "ascii";   break;
                case ModbusProtocol.unknown: variant = "unknown"; break;
            }
            set_const_element(modbus, "Modbus", "variant", Variant(variant));
        }
    }

    void set_const_element(Component c, string template_, string id, Variant value)
    {
        Element* e = ensure_element(c, id);
        if (e.value.isNull)
        {
            e.value = value;
            e.last_update = getSysTime();
            e.sampling_mode = SamplingMode.constant;
        }
        populate_element_metadata(e, template_, id);
    }

    void materialise_repeat(ref const ModelLoc ml, ref const ModelMapping mm, Component device)
    {
        auto chain = &_chains[ml.chain_index];
        size_t count_idx = (ml.data_reg + mm.repeat.count_offset) - chain.base_reg;
        if (count_idx >= chain.scan_buffer.length)
            return;
        ushort n = chain.scan_buffer[count_idx];
        if (n == 0 || n == 0xFFFF)  // 0xFFFF is SunSpec "not implemented"
            return;

        version (DebugSunspec)
            log.tracef("materialise: model {0} -> {1} repeat instance(s)", mm.model_id, n);

        assert(mm.repeat.components.length <= 8, "extend inst_comps[] if more sub-components per instance");
        for (ushort inst = 0; inst < n; ++inst)
        {
            const(char)[] inst_path = tconcat(mm.repeat.path_prefix, inst + 1);

            Component[8] inst_comps;
            foreach (ci, ref cd; mm.repeat.components)
            {
                const(char)[] full_path = cd.path.length == 0 ? inst_path : tconcat(inst_path, ".", cd.path);
                ComponentDef synth = ComponentDef(cast(string)full_path, cd.template_, cd.type_value);
                inst_comps[ci] = find_or_create_component(device, synth);
                if (cd.type_value)
                    set_type_element(inst_comps[ci], cd.template_, cd.type_value);
            }

            ushort inst_offset = cast(ushort)(mm.repeat.first_offset + inst * mm.repeat.stride);
            foreach (ref fd; mm.repeat.fields)
                emit_field(ml, mm, fd, inst_comps[fd.component_index], inst_offset);
        }
    }

    void emit_field(ref const ModelLoc ml, ref const ModelMapping mm, ref const FieldDef fd, Component target, ushort extra_offset = 0)
    {
        auto chain = &_chains[ml.chain_index];

        float pre_scale = 1.0f;
        if (fd.scale_off >= 0)
        {
            size_t sf_idx = (ml.data_reg + fd.scale_off) - chain.base_reg;
            if (sf_idx < chain.scan_buffer.length)
            {
                short sf = cast(short)chain.scan_buffer[sf_idx];
                pre_scale = pow10f(sf);
            }
        }

        ValueDesc desc = make_value_desc(fd, pre_scale);
        ushort reg = cast(ushort)(ml.data_reg + fd.offset + extra_offset);
        size_t idx = reg - chain.base_reg;
        size_t words = desc.data_length / 2;
        if (idx + words > chain.scan_buffer.length || desc.data_length > 128)
        {
            version (DebugSunspec)
                log.tracef("materialise: skip {0}.{1} — outside scan buffer", target.id[], fd.id);
            return;
        }

        const(ushort)[] field_words = chain.scan_buffer[][idx .. idx + words];
        bool sentinel_now = is_sentinel(fd.type, field_words);

        // Constants that report not-implemented at startup will never become
        // real, so drop them. Dynamic fields might be transiently sentinel
        // (e.g. solar current at night, vendor-specific events register) — we
        // still create the element so it appears in the device tree, and let
        // the poll loop fill in a real value once one is available.
        if (sentinel_now && (fd.freq == Frequency.constant || fd.freq == Frequency.configuration))
        {
            version (DebugSunspec)
                log.tracef("materialise: skip {0}.{1} — not implemented (constant)", target.id[], fd.id);
            return;
        }

        Element* e = ensure_element(target, fd.id);
        e.access = fd.access;
        populate_element_metadata(e, target.template_[], fd.id);

        if (!sentinel_now)
        {
            ubyte[128] tmp = void;
            for (size_t k = 0; k < words; ++k)
            {
                ushort w = field_words[k];
                tmp[k*2 + 0] = cast(ubyte)(w >> 8);
                tmp[k*2 + 1] = cast(ubyte)(w & 0xFF);
            }
            e.value = sample_value(tmp.ptr, desc);
            e.last_update = getSysTime();
        }

        if (fd.freq == Frequency.constant || fd.freq == Frequency.configuration)
        {
            e.sampling_mode = SamplingMode.constant;
            version (DebugSunspec)
                log.tracef("materialise: {0}.{1} = {2} (const, reg {3})", target.id[], fd.id, e.value, reg);
            return;
        }

        SampleEntry se;
        se.register = reg;
        se.regKind = 4;
        se.element = e;
        se.desc = desc;
        se.sampleTimeMs = freq_to_ms(fd.freq);
        se.sentinel = field_sentinel(fd.type);
        se.lastUpdate = sentinel_now ? SysTime() : getSysTime();
        sample_entries ~= se;
        e.sampling_mode = freq_to_element_mode(fd.freq);
        version (DebugSunspecRegs)
            log.tracef("materialise: {0}.{1} at reg {2} scale {3} every {4}ms", target.id[], fd.id, reg, pre_scale, se.sampleTimeMs);
    }

    void set_type_element(Component c, string template_, string type_value)
    {
        Element* te = ensure_element(c, "type");
        if (te.value.isNull)
        {
            te.value = Variant(type_value);
            te.last_update = getSysTime();
            te.sampling_mode = SamplingMode.constant;
        }
        populate_element_metadata(te, template_, "type");
    }

    void populate_element_metadata(Element* e, const(char)[] template_, const(char)[] id)
    {
        if (!e.name.empty && !e.desc.empty && !e.display_unit.empty)
            return;
        const KnownElementTemplate* et = find_known_element(template_, id);
        if (!et)
            return;
        if (e.display_unit.empty && et.units.length)
            e.display_unit = et.units.makeString(defaultAllocator());
        if (e.name.empty && et.name.length)
            e.name = et.name.makeString(defaultAllocator());
        if (e.desc.empty && et.desc.length)
            e.desc = et.desc.makeString(defaultAllocator());
    }

    Component find_or_create_component(Component root, ref const ComponentDef cd)
    {
        Component parent = root;
        const(char)[] remaining = cd.path;
        while (!remaining.empty)
        {
            const(char)[] segment = remaining.split!'.';
            if (segment.empty)
                continue;
            Component child;
            foreach (Component existing; parent.components)
                if (existing.id[] == segment)
                {
                    child = existing;
                    break;
                }
            if (child is null)
            {
                child = g_app.allocator.allocT!Component(segment.makeString(defaultAllocator()));
                child.parent = parent;
                parent.components ~= child;
            }
            parent = child;
        }
        if (cd.template_ && parent.template_.empty)
            parent.template_ = cd.template_.makeString(defaultAllocator());
        return parent;
    }

    Element* ensure_element(Component c, string id)
    {
        foreach (Element* existing; c.elements)
            if (existing.id[] == id)
                return existing;
        Element* e = g_app.allocator.allocT!Element();
        e.parent = c;
        e.id = id.makeString(defaultAllocator());
        c.elements ~= e;
        return e;
    }

    // Polling response/error handlers.

    void response_handler(ref const ModbusPDU req, ref ModbusPDU resp, SysTime, SysTime response_time)
    {
        ushort first = (cast(ushort)req.data[0] << 8) | req.data[1];
        ushort count = (cast(ushort)req.data[2] << 8) | req.data[3];

        if (resp.function_code & 0x80)
        {
            version (DebugSunspec)
                log.tracef("read at {0}+{1}: exception 0x{2,02x}", first, count, resp.data.length >= 1 ? resp.data[0] : 0);
            release_in_flight(first, count);
            return;
        }
        ushort byte_count = resp.data[0];
        if (byte_count != count * 2 || resp.data.length < 1 + byte_count)
        {
            version (DebugSunspec)
                log.tracef("read at {0}+{1}: malformed response", first, count);
            release_in_flight(first, count);
            return;
        }

        ubyte[] data = resp.data[1 .. 1 + byte_count];

        foreach (ref se; sample_entries)
        {
            if (se.register < first || se.register >= first + count)
                continue;

            se.lastUpdate = response_time;
            se.flags &= 0xFE;
            if (se.sampleTimeMs == 0)
                se.flags |= 2;

            ushort offset = cast(ushort)(se.register - first);
            uint byte_offset = offset * 2;

            // SunSpec "not implemented" sentinel; skip the write so consumers
            // don't see synthetic values for fields the device doesn't populate
            if (se.sentinel != 0)
            {
                bool is_sent = false;
                if (se.desc.data_length == 2)
                {
                    ushort raw = (cast(ushort)data[byte_offset] << 8) | data[byte_offset + 1];
                    is_sent = (raw == cast(ushort)se.sentinel);
                }
                else if (se.desc.data_length == 4)
                {
                    uint raw = (cast(uint)data[byte_offset]     << 24)
                             | (cast(uint)data[byte_offset + 1] << 16)
                             | (cast(uint)data[byte_offset + 2] <<  8)
                             |  cast(uint)data[byte_offset + 3];
                    is_sent = (raw == se.sentinel);
                }
                if (is_sent)
                {
                    version (DebugSunspecRegs)
                        log.tracef("reg {0}: not-implemented sentinel; skipped", se.register);
                    continue;
                }
            }

            se.element.value(sample_value(data.ptr + byte_offset, se.desc), response_time);
            version (DebugSunspecRegs)
                log.tracef("reg {0} = {1}", se.register, se.element.value);
        }
    }

    void error_handler(ModbusErrorType ty, ref const ModbusPDU req, SysTime)
    {
        if (ty == ModbusErrorType.Retrying)
            return;
        ushort first = (cast(ushort)req.data[0] << 8) | req.data[1];
        ushort count = (cast(ushort)req.data[2] << 8) | req.data[3];
        version (DebugSunspec)
            log.tracef("read at {0}+{1}: {2}", first, count, ty == ModbusErrorType.Timeout ? "timeout" : "failed");
        release_in_flight(first, count);
    }

    void release_in_flight(ushort first, ushort count)
    {
        foreach (ref se; sample_entries)
            if (se.register >= first && se.register < first + count)
                se.flags &= 0xFE;
    }
}


// helpers

private float pow10f(int exp) pure
{
    if (exp == 0)
        return 1.0f;
    float r = 1.0f;
    if (exp > 0)
    {
        for (int i = 0; i < exp; ++i)
            r *= 10.0f;
    }
    else
    {
        for (int i = 0; i < -exp; ++i)
            r *= 0.1f;
    }
    return r;
}

private ushort freq_to_ms(Frequency f) pure
{
    final switch (f)
    {
        case Frequency.realtime:       return 1;
        case Frequency.high:           return 1_000;
        case Frequency.medium:         return 10_000;
        case Frequency.low:            return 60_000;
        case Frequency.constant:       return 0;
        case Frequency.configuration:  return 0;
        case Frequency.on_demand:      return ushort.max;
        case Frequency.report:         return ushort.max;
    }
}

// Sentinel pattern for poll-time filtering. Returns 0 for "no filter".
// For 2-byte types, low 16 bits used; for 4-byte types, full 32 bits used.
// Acc32 explicitly never filters (0 is a valid "nothing yet" value).
// F32 and strings have multi-byte patterns handled out-of-band.
private uint field_sentinel(FieldType t) pure
{
    final switch (t)
    {
        case FieldType.u16:        return 0xFFFF;
        case FieldType.i16:        return 0x8000;
        case FieldType.enum16:     return 0xFFFF;
        case FieldType.u32:        return 0xFFFFFFFF;
        case FieldType.i32:        return 0x80000000;
        case FieldType.bitfield32: return 0xFFFFFFFF;
        case FieldType.acc32:
        case FieldType.f32:
        case FieldType.str_:
            return 0;
    }
}

// SunSpec "not implemented" sentinels per data type.
// Acc32 deliberately does not filter — 0 is a legitimate "nothing accumulated yet" value
// and would cause us to drop newly commissioned energy counters.
private bool is_sentinel(FieldType t, const(ushort)[] words) pure
{
    if (words.length == 0)
        return true;
    final switch (t)
    {
        case FieldType.u16:
        case FieldType.enum16:
            return words[0] == 0xFFFF;
        case FieldType.i16:
            return words[0] == 0x8000;
        case FieldType.u32:
            return words.length >= 2 && words[0] == 0xFFFF && words[1] == 0xFFFF;
        case FieldType.i32:
            return words.length >= 2 && words[0] == 0x8000 && words[1] == 0;
        case FieldType.bitfield32:
            return words.length >= 2 && words[0] == 0xFFFF && words[1] == 0xFFFF;
        case FieldType.acc32:
            return false;
        case FieldType.f32:
            // NaN / Inf: exponent bits all 1 (0x7F80 mask on the high word)
            return words.length >= 2 && (words[0] & 0x7F80) == 0x7F80;
        case FieldType.str_:
            // SunSpec strings are zero-padded; an unpopulated string starts with a null byte
            return (words[0] >> 8) == 0;
    }
}

private DataType build_data_type(FieldType t, ubyte str_words) pure
{
    final switch (t)
    {
        case FieldType.u16:
            return cast(DataType)(DataType.u16 | DataType.big_endian);
        case FieldType.i16:
            return cast(DataType)(DataType.i16 | DataType.big_endian);
        case FieldType.u32:
        case FieldType.acc32:
            return cast(DataType)(DataType.u32 | DataType.big_endian);
        case FieldType.i32:
            return cast(DataType)(DataType.i32 | DataType.big_endian);
        case FieldType.f32:
            return cast(DataType)(DataType.u32 | DataType.big_endian | (DataKind.floating << 12));
        case FieldType.str_:
            return cast(DataType)(DataType.array |
                                  (DataKind.string_ << 12) |
                                  (uint(str_words) * 2 << 16));
        case FieldType.enum16:
            return cast(DataType)(DataType.u16 | DataType.big_endian | DataType.enumeration);
        case FieldType.bitfield32:
            return cast(DataType)(DataType.u32 | DataType.big_endian | DataType.enumeration |
                                  (DataKind.bitfield << 12));
    }
}

private ValueDesc make_value_desc(ref const FieldDef fd, float pre_scale)
{
    DataType dt = build_data_type(fd.type, fd.str_words);

    // Enum/bitfield: `unit` carries the registered enum type name.
    if (fd.type == FieldType.enum16 || fd.type == FieldType.bitfield32)
    {
        if (fd.unit)
        {
            if (const(VoidEnumInfo)** ei = fd.unit in g_app.enum_templates)
                return ValueDesc(dt, *ei);
        }
        return ValueDesc(dt);
    }

    if (fd.type == FieldType.str_)
        return ValueDesc(dt);
    if (!fd.unit && pre_scale == 1.0f)
        return ValueDesc(dt);

    ScaledUnit unit;
    float unit_scale = 1.0f;
    if (fd.unit)
        unit.parseUnit(fd.unit, unit_scale);
    return ValueDesc(dt, unit, pre_scale * unit_scale);
}
