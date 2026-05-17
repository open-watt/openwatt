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
    string path;        // dotted path from device root (e.g. "grid.meter")
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
    string path_prefix;                    // e.g. "solar.mppt" with instance index appended
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
//   0: inverter            (Inverter)          - top-level inverter component
//   1: solar               (Port/Solar)        - single PV input, or multi-input aggregate
//   2: solar.meter         (EnergyMeter dc)    - DC measurements at the PV input/aggregate
//   3: grid                (Port)              - inverter AC output / grid-facing circuit
//   4: grid.meter          (EnergyMeter ac)    - inverter exchange with the attached circuit
// The AC output is a Port so /apps/energy/appliance bindings such as
// `grid=house device=se10000h` can attach readings to the topology. A
// coexisting CT (model 201/203) is the property-gateway export meter and is mounted
// at inverter.export_meter below, not here.

private immutable ComponentDef[] inverter_components_single = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("solar",                "Port",        null),
    ComponentDef("solar.meter",          "EnergyMeter", "dc"),
    ComponentDef("grid",                 "Port",        null),
    ComponentDef("grid.meter",           "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] inverter_components_three = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("solar",                "Port",        null),
    ComponentDef("solar.meter",          "EnergyMeter", "dc"),
    ComponentDef("grid",                 "Port",        null),
    ComponentDef("grid.meter",           "EnergyMeter", "three-phase"),
];
private immutable ComponentDef[] inverter_components_single_mppt = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("solar",                "Solar",       null),
    ComponentDef("solar.meter",          "EnergyMeter", "dc"),
    ComponentDef("grid",                 "Port",        null),
    ComponentDef("grid.meter",           "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] inverter_components_three_mppt = [
    ComponentDef("inverter",             "Inverter",    null),
    ComponentDef("solar",                "Solar",       null),
    ComponentDef("solar.meter",          "EnergyMeter", "dc"),
    ComponentDef("grid",                 "Port",        null),
    ComponentDef("grid.meter",           "EnergyMeter", "three-phase"),
];

private immutable FieldDef[] m101_fields = [
    // AC output -> grid.meter
    FieldDef(4, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
    // DC input -> solar.meter
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
    FieldDef(4, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "current1",       "A",     1,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "current2",       "A",     2,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage1",       "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage2",       "V",     9, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "ipv1",           "V",     5, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
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
    FieldDef(4, "current",        "A",     0,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "current1",       "A",     1,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "current2",       "A",     2,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "current3",       "A",     3,  4, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage1",       "V",     8, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage2",       "V",     9, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "voltage3",       "V",    10, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "ipv1",           "V",     5, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "ipv2",           "V",     6, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "ipv3",           "V",     7, 11, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    12, 13, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   14, 15, FieldType.u16,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   16, 17, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  18, 19, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    20, 21, FieldType.i16,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   22, 24, FieldType.acc32, 0, Frequency.medium),
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
    FieldDef(4, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
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
    FieldDef(4, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "current1",       "A",     2, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "current2",       "A",     4, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage1",       "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage2",       "V",    16, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "ipv1",           "V",     8, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
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
    FieldDef(4, "current",        "A",     0, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "current1",       "A",     2, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "current2",       "A",     4, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "current3",       "A",     6, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage",        "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage1",       "V",    14, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage2",       "V",    16, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "voltage3",       "V",    18, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "ipv1",           "V",     8, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "ipv2",           "V",    10, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "ipv3",           "V",    12, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "power",          "W",    20, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "frequency",      "Hz",   22, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "apparent",       "VA",   24, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "reactive",       "var",  26, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "pf",             "%",    28, -1, FieldType.f32,   0, Frequency.realtime),
    FieldDef(4, "import",         "Wh",   30, -1, FieldType.f32,   0, Frequency.medium),
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
// Standalone meter device: the meter is the device's primary measurement, placed
// at device root as `meter`. When a meter coexists with an inverter on the same
// device it is remapped to `inverter.export_meter` below (the inverter's own AC
// output already owns the top-level `meter`).

private immutable ComponentDef[] meter_single_components = [
    ComponentDef("meter", "EnergyMeter", "single-phase"),
];
private immutable ComponentDef[] meter_three_components = [
    ComponentDef("meter", "EnergyMeter", "three-phase"),
];

// When a meter model coexists with an inverter on the same physical device
// (e.g. SolarEdge with its grid CT), that meter sits at the property gateway and
// is the export-limiting / self-consumption reference, not the inverter's exchange
// with its own circuit. It mounts under the Inverter component as `export_meter`.
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

private immutable ComponentDef[] m160_components = [
    ComponentDef("solar", "Solar", null),
];

private immutable FieldDef[] m160_fields = [];  // fixed-block fields we expose go here if needed

private immutable ComponentDef[] m160_repeat_components = [
    ComponentDef("",      "Port",        null),    // the mpptN port itself
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
    ModelMapping(160, "inverter",     m160_components,                m160_fields,
                 RepeatBlock(6, 8, 20, "solar.mppt", m160_repeat_components, m160_repeat_fields)),
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

private const(char)[] sunspec_model_name(ushort id) pure nothrow @nogc
{
    switch (id)
    {
        case 1:   return "Common";
        case 101: return "Inverter, single-phase, integer";
        case 102: return "Inverter, split-phase, integer";
        case 103: return "Inverter, three-phase, integer";
        case 111: return "Inverter, single-phase, float";
        case 112: return "Inverter, split-phase, float";
        case 113: return "Inverter, three-phase, float";
        case 160: return "Multiple MPPT inverter extension";
        case 201: return "Meter, single-phase";
        case 202: return "Meter, split-phase";
        case 203: return "Meter, three-phase";
        case 702: return "DER capacity";
        default:
            if (id >= 120 && id < 130)
                return "inverter extension";
            if (id >= 700 && id < 800)
                return "DER model";
            if (id >= 800 && id < 900)
                return "storage/battery model";
            if (id >= 64_000)
                return "manufacturer-specific model";
            return "unknown model";
    }
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
                version (DebugSunspec)
                    log.tracef("running: {0} stripe(s)", stripes.length);
                return CompletionStatus.complete;

            case Phase.running:
                return CompletionStatus.complete;
        }
    }

    override CompletionStatus shutdown()
    {
        teardown_node();
        stripes.clear();
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

        ModbusNode c = _node.get;
        if (!c)
            return;

        MonoTime now = getTime();

        foreach (ref st; stripes)
        {
            bool full_due = false;
            if (st.full_ms != ushort.max && st.end > st.middle)
                full_due = now - st.full_last >= msecs(st.full_ms);

            if (full_due)
            {
                if (!st.realtime_in_flight && !st.full_in_flight
                    && issue_read(c, st, st.start, cast(ushort)(st.end - st.start), true))
                    st.full_in_flight = true;
                continue;
            }

            if (!st.realtime_in_flight && !st.full_in_flight
                && st.middle > st.start
                && now - st.realtime_last >= msecs(freq_to_ms(Frequency.realtime)))
            {
                if (issue_read(c, st, st.start, cast(ushort)(st.middle - st.start), false))
                    st.realtime_in_flight = true;
            }
        }
    }

    bool issue_read(ModbusNode c, ref Stripe st, ushort first, ushort count, bool full)
    {
        if (count == 0)
            return false;
        assert(count <= 125);
        ModbusPDU pdu = createMessage_Read(RegisterType.holding_register, first, count);
        version (DebugSunspecRegs)
            log.tracef("fetch model {0} ({1}): {2} sample, {3} regs at {4}", st.model_id, sunspec_model_name(st.model_id), full ? "low-freq" : "high-freq", count, first);
        return c.sendRequest(_slave_server.universal_address, pdu, &response_handler, &error_handler, 0, 1000, PCP.be, false);
    }

protected:

    enum Phase : ubyte { idle, probing, scanning, materialising, running }

    struct StripeField
    {
        Element* element;
        ValueDesc desc;       // without SunSpec SF
        ushort reg;
        int sf_reg = -1;
        uint sentinel;
        Frequency freq;

        ushort words() const pure nothrow @nogc
            => cast(ushort)(desc.data_length / 2);
    }

    // `middle` marks the realtime prefix; slow polls read the whole stripe.
    struct Stripe
    {
        MonoTime realtime_last;
        MonoTime full_last;
        ushort model_id;
        ushort start, middle, end;
        ushort full_ms;
        bool realtime_in_flight;
        bool full_in_flight;
        Array!StripeField fields;
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

    ubyte _probe_index;    // index into sunspec_bases for the probing pass
    ubyte _chain_count;    // number of chains discovered (entries used in _chains)
    ubyte _active_chain;   // chain currently being scanned/walked

    ChainData[sunspec_bases.length] _chains;
    Array!ModelLoc _models_chain;
    Array!Stripe stripes;

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

    void probe_response_handler(ref const ModbusPDU req, ref ModbusPDU resp, MonoTime, MonoTime)
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

    void probe_error_handler(ModbusErrorType ty, ref const ModbusPDU, MonoTime)
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
                    log.warning("SunSpec model ", id, " (", sunspec_model_name(id), ") advertised at reg ", header_reg, " is not implemented; skipped");
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

    void scan_response_handler(ref const ModbusPDU req, ref ModbusPDU resp, MonoTime, MonoTime)
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

    void scan_error_handler(ModbusErrorType ty, ref const ModbusPDU, MonoTime)
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
        ushort pv_input_count;
        size_t selected_pv_model_index = size_t.max;
        foreach (size_t i, ref ml; _models_chain)
        {
            const(ModelMapping)* mm = find_model_mapping(ml.model_id);
            if (mm && mm.device_type)
            {
                if (!device_type)
                    device_type = mm.device_type;
                if (mm.device_type == "inverter")
                    has_inverter = true;
            }
            if (ml.model_id == 160)
            {
                ushort n = mm ? repeat_instance_count(ml, *mm) : 0;
                if (n > pv_input_count)
                {
                    pv_input_count = n;
                    selected_pv_model_index = i;
                }
            }
        }
        bool pv_has_subports = pv_input_count > 1;

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
            if (ml.model_id == 160 && i != selected_pv_model_index)
            {
                version (DebugSunspec)
                    log.tracef("materialise: skipping duplicate model 160 at reg {0}; selected {1} PV input(s)",
                               ml.header_reg, pv_input_count);
                continue;
            }

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
                else if (pv_has_subports)
                {
                    if (ml.model_id == 101 || ml.model_id == 111)
                        comp_defs = inverter_components_single_mppt;
                    else if (ml.model_id == 102 || ml.model_id == 103 || ml.model_id == 112 || ml.model_id == 113)
                        comp_defs = inverter_components_three_mppt;
                }
                else if (ml.model_id == 160)
                {
                    // A single SunSpec MPPT/input is the top-level solar Port.
                    // Multiple inputs get a Solar container plus mpptN ports.
                    comp_defs = [];
                }
            }

            assert(comp_defs.length <= 8, "extend comps[] if more components per model are needed");
            Component[8] comps;
            foreach (ci, ref cd; comp_defs)
            {
                comps[ci] = find_or_create_component(device, cd);
                if (cd.type_value)
                    set_type_element(comps[ci], cd.template_, cd.type_value);
                configure_standard_component(comps[ci], cd);
            }
            version (DebugSunspec)
                log.tracef("materialise: model {0} -> {1} component(s), {2} field(s)", ml.model_id, mm.components.length, mm.fields.length);

            Array!StripeField mf;
            foreach (ref fd; mm.fields)
                emit_field(ml, *mm, fd, comps[fd.component_index], mf);

            if (mm.repeat.stride > 0 && mm.repeat.fields.length > 0)
            {
                const(char)[] repeat_prefix = mm.repeat.path_prefix;
                if (ml.model_id == 160 && !pv_has_subports)
                    repeat_prefix = "solar";
                materialise_repeat(ml, *mm, device, repeat_prefix, mf);
            }

            build_stripes(mf, ml.model_id);
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

    void configure_standard_component(Component c, ref const ComponentDef cd)
    {
        if (cd.template_ != "Port")
            return;

        if (cd.path == "grid")
        {
            set_const_element(c, "Port", "role", Variant("grid"));
            set_const_element(c, "Port", "flow", Variant("bidirectional"));
            set_const_element(c, "Port", "meter_sign", Variant("inverted"));
        }
        else if (is_pv_port_path(cd.path))
        {
            set_const_element(c, "Port", "role", Variant("pv"));
            set_const_element(c, "Port", "flow", Variant("supply"));
        }
    }

    bool is_pv_port_path(const(char)[] path) const pure nothrow @nogc
    {
        return path == "solar" ||
               path == "pv" ||
               (path.length > 3 && path[0 .. 3] == "pv.") ||
               (path.length >= 10 && path[0 .. 10] == "solar.mppt");
    }

    ushort repeat_instance_count(ref const ModelLoc ml, ref const ModelMapping mm)
    {
        if (mm.repeat.stride == 0)
            return 0;
        if (ml.length <= mm.repeat.first_offset)
            return 0;

        ushort max_n = cast(ushort)((ml.length - mm.repeat.first_offset) / mm.repeat.stride);
        if (max_n == 0)
            return 0;

        assert(mm.repeat.count_offset < ml.length);
        auto chain = &_chains[ml.chain_index];
        size_t count_idx = (ml.data_reg + mm.repeat.count_offset) - chain.base_reg;
        if (count_idx >= chain.scan_buffer.length)
            return 0;
        ushort n = chain.scan_buffer[count_idx];
        if (n == 0 || n == 0xFFFF)  // 0xFFFF is SunSpec "not implemented"
            return 0;
        if (n > max_n)
        {
            version (DebugSunspec)
                log.tracef("model {0}: repeat count {1} exceeds model length cap {2}", ml.model_id, n, max_n);
            n = max_n;
        }
        return n;
    }

    void materialise_repeat(ref const ModelLoc ml, ref const ModelMapping mm, Component device, const(char)[] path_prefix, ref Array!StripeField out_fields)
    {
        ushort n = repeat_instance_count(ml, mm);
        if (n == 0)
            return;

        version (DebugSunspec)
            log.tracef("materialise: model {0} -> {1} repeat instance(s)", mm.model_id, n);

        assert(mm.repeat.components.length <= 8, "extend inst_comps[] if more sub-components per instance");
        for (ushort inst = 0; inst < n; ++inst)
        {
            const(char)[] inst_path = n == 1 ? path_prefix : tconcat(path_prefix, inst + 1);

            Component[8] inst_comps;
            foreach (ci, ref cd; mm.repeat.components)
            {
                const(char)[] full_path = cd.path.length == 0 ? inst_path : tconcat(inst_path, ".", cd.path);
                ComponentDef synth = ComponentDef(cast(string)full_path, cd.template_, cd.type_value);
                inst_comps[ci] = find_or_create_component(device, synth);
                if (cd.type_value)
                    set_type_element(inst_comps[ci], cd.template_, cd.type_value);
                configure_standard_component(inst_comps[ci], synth);
            }

            ushort inst_offset = cast(ushort)(mm.repeat.first_offset + inst * mm.repeat.stride);
            foreach (ref fd; mm.repeat.fields)
                emit_field(ml, mm, fd, inst_comps[fd.component_index], out_fields, inst_offset);
        }
    }

    void emit_field(ref const ModelLoc ml, ref const ModelMapping mm, ref const FieldDef fd, Component target,
                    ref Array!StripeField out_fields, ushort extra_offset = 0)
    {
        auto chain = &_chains[ml.chain_index];

        int sf_reg = -1;
        if (fd.scale_off >= 0)
            sf_reg = cast(ushort)(ml.data_reg + fd.scale_off);

        ValueDesc desc = make_value_desc(fd);
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
        if (fd.freq != Frequency.constant && fd.freq != Frequency.configuration && element_already_sampled(e, out_fields))
        {
            version (DebugSunspec)
                log.tracef("materialise: skip duplicate sampler for {0}.{1}", target.id[], fd.id);
            return;
        }

        if (!sentinel_now)
        {
            float scale = 1.0f;
            bool have_scale = read_scan_scale(chain.scan_buffer[], chain.base_reg, sf_reg, scale);
            ubyte[128] tmp = void;
            for (size_t k = 0; k < words; ++k)
            {
                ushort w = field_words[k];
                tmp[k*2 + 0] = cast(ubyte)(w >> 8);
                tmp[k*2 + 1] = cast(ubyte)(w & 0xFF);
            }
            if (have_scale)
            {
                e.value = sample_sunspec_value(tmp.ptr, desc, scale);
                e.last_update = getSysTime();
            }
        }

        if (fd.freq == Frequency.constant || fd.freq == Frequency.configuration)
        {
            e.sampling_mode = SamplingMode.constant;
            version (DebugSunspec)
                log.tracef("materialise: {0}.{1} = {2} (const, reg {3})", target.id[], fd.id, e.value, reg);
            return;
        }

        StripeField sfd;
        sfd.element = e;
        sfd.desc = desc;
        sfd.reg = reg;
        sfd.sf_reg = sf_reg;
        sfd.sentinel = field_sentinel(fd.type);
        sfd.freq = fd.freq;
        out_fields ~= sfd;
        e.sampling_mode = freq_to_element_mode(fd.freq);
        version (DebugSunspecRegs)
            log.tracef("materialise: {0}.{1} at reg {2} sf_reg {3} every {4}ms", target.id[], fd.id, reg, sf_reg, freq_to_ms(fd.freq));
    }

    bool element_already_sampled(Element* e, ref const Array!StripeField pending) const pure nothrow @nogc
    {
        foreach (ref f; pending[])
            if (f.element is e)
                return true;
        foreach (ref st; stripes[])
            foreach (ref f; st.fields[])
                if (f.element is e)
                    return true;
        return false;
    }

    // Keep SFs in the same read as their values.
    void build_stripes(ref Array!StripeField mf, ushort model_id)
    {
        if (mf.length == 0)
            return;

        import urt.algorithm : qsort;
        qsort!((ref a, ref b) => a.reg < b.reg ? -1 : a.reg > b.reg ? 1 : 0)(mf[]);

        size_t i = 0;
        while (i < mf.length)
        {
            ushort lo = field_lo(mf[i]);
            ushort hi = field_hi(mf[i]);
            size_t k = i + 1;
            for (; k < mf.length; ++k)
            {
                ushort flo = field_lo(mf[k]);
                ushort fhi = field_hi(mf[k]);
                ushort nlo = flo < lo ? flo : lo;
                ushort nhi = fhi > hi ? fhi : hi;
                if (nhi - nlo > 125)
                    break;
                lo = nlo;
                hi = nhi;
            }

            ushort rt_hi = lo;
            bool any_rt = false;
            for (size_t f = i; f < k; ++f)
            {
                if (mf[f].freq == Frequency.realtime)
                {
                    ushort fh = field_hi(mf[f]);
                    if (fh > rt_hi)
                        rt_hi = fh;
                    any_rt = true;
                }
            }
            ushort middle = any_rt ? rt_hi : lo;

            ushort full_ms = ushort.max;
            for (size_t f = i; f < k; ++f)
            {
                if (mf[f].freq != Frequency.realtime)
                {
                    ushort m = freq_to_ms(mf[f].freq);
                    if (m < full_ms)
                        full_ms = m;
                }
            }

            assert(hi - lo <= 125);

            stripes ~= Stripe();
            Stripe* st = &stripes[stripes.length - 1];
            st.model_id = model_id;
            st.start = lo;
            st.middle = middle;
            st.end = hi;
            st.full_ms = full_ms;
            if (full_ms != ushort.max && hi > middle)
                st.full_last = getTime() - msecs(full_ms);
            for (size_t f = i; f < k; ++f)
                st.fields ~= mf[f];

            i = k;
        }
    }

    static ushort field_lo(ref const StripeField f) pure nothrow @nogc
    {
        ushort lo = f.reg;
        if (f.sf_reg >= 0 && f.sf_reg < lo)
            lo = cast(ushort)f.sf_reg;
        return lo;
    }

    static ushort field_hi(ref const StripeField f) pure nothrow @nogc
    {
        ushort hi = cast(ushort)(f.reg + f.words);
        if (f.sf_reg >= 0 && f.sf_reg + 1 > hi)
            hi = cast(ushort)(f.sf_reg + 1);
        return hi;
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

    void response_handler(ref const ModbusPDU req, ref ModbusPDU resp, MonoTime, MonoTime response_time)
    {
        ushort first = (cast(ushort)req.data[0] << 8) | req.data[1];
        ushort count = (cast(ushort)req.data[2] << 8) | req.data[3];

        bool is_full;
        Stripe* st = find_stripe(first, count, is_full);
        if (st)
        {
            if (is_full)
                st.full_in_flight = false;
            else
                st.realtime_in_flight = false;
        }

        if (resp.function_code & 0x80)
        {
            version (DebugSunspec)
                log.tracef("read at {0}+{1}: exception 0x{2,02x}", first, count, resp.data.length >= 1 ? resp.data[0] : 0);
            return;
        }
        ushort byte_count = resp.data[0];
        if (byte_count != count * 2 || resp.data.length < 1 + byte_count)
        {
            version (DebugSunspec)
                log.tracef("read at {0}+{1}: malformed response", first, count);
            return;
        }
        if (!st)
            return;

        if (is_full)
        {
            st.full_last = response_time;
            st.realtime_last = response_time;
        }
        else
            st.realtime_last = response_time;

        ubyte[] data = resp.data[1 .. 1 + byte_count];
        decode_block(*st, first, cast(ushort)(first + count), data, cast(SysTime)response_time, is_full);
    }

    Stripe* find_stripe(ushort first, ushort count, out bool is_full)
    {
        foreach (ref st; stripes)
        {
            if (st.middle > st.start && st.start == first && st.middle - st.start == count)
            {
                is_full = false;
                return &st;
            }
            if (st.end > st.middle && st.start == first && st.end - st.start == count)
            {
                is_full = true;
                return &st;
            }
        }
        return null;
    }

    void decode_block(ref Stripe st, ushort first, ushort last, ubyte[] data, SysTime ts, bool is_full)
    {
        foreach (ref f; st.fields)
        {
            if (!is_full && f.freq != Frequency.realtime)
                continue;
            ushort w = f.words;
            if (f.reg < first || f.reg + w > last)
                continue;
            uint off = cast(uint)((f.reg - first) * 2);
            float scale = 1.0f;
            if (!read_message_scale(first, last, data, f.sf_reg, scale))
                continue;

            if (f.sentinel != 0)
            {
                bool is_sent = false;
                if (f.desc.data_length == 2)
                {
                    ushort raw = (cast(ushort)data[off] << 8) | data[off + 1];
                    is_sent = (raw == cast(ushort)f.sentinel);
                }
                else if (f.desc.data_length == 4)
                {
                    uint raw = (cast(uint)data[off]     << 24)
                             | (cast(uint)data[off + 1] << 16)
                             | (cast(uint)data[off + 2] <<  8)
                             |  cast(uint)data[off + 3];
                    is_sent = (raw == f.sentinel);
                }
                if (is_sent)
                {
                    version (DebugSunspecRegs)
                        log.tracef("reg {0}: not-implemented sentinel; skipped", f.reg);
                    continue;
                }
            }

            f.element.value(sample_sunspec_value(data.ptr + off, f.desc, scale), ts);
            version (DebugSunspecRegs)
                log.tracef("reg {0} = {1}", f.reg, f.element.value);
        }
    }

    void error_handler(ModbusErrorType ty, ref const ModbusPDU req, MonoTime)
    {
        if (ty == ModbusErrorType.Retrying)
            return;
        ushort first = (cast(ushort)req.data[0] << 8) | req.data[1];
        ushort count = (cast(ushort)req.data[2] << 8) | req.data[3];
        bool is_full;
        if (Stripe* st = find_stripe(first, count, is_full))
        {
            if (is_full)
                st.full_in_flight = false;
            else
                st.realtime_in_flight = false;
        }
        version (DebugSunspec)
            log.tracef("read at {0}: {1}", first, ty == ModbusErrorType.Timeout ? "timeout" : "failed");
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

private bool read_scan_scale(const(ushort)[] regs, ushort base, int sf_reg, out float scale) pure
{
    scale = 1.0f;
    if (sf_reg < 0)
        return true;
    size_t idx = cast(size_t)(sf_reg - base);
    if (idx >= regs.length)
        return false;
    short sf = cast(short)regs[idx];
    if (sf == cast(short)0x8000)
        return false;
    scale = pow10f(sf);
    return true;
}

private bool read_message_scale(ushort first, ushort last, const(ubyte)[] data, int sf_reg, out float scale) pure
{
    scale = 1.0f;
    if (sf_reg < 0)
        return true;
    if (sf_reg < first || sf_reg >= last)
        return false;

    size_t off = cast(size_t)(sf_reg - first) * 2;
    if (off + 1 >= data.length)
        return false;

    short sf = cast(short)((cast(ushort)data[off] << 8) | data[off + 1]);
    if (sf == cast(short)0x8000)
        return false;
    scale = pow10f(sf);
    return true;
}

private Variant sample_sunspec_value(const void* data, ref const ValueDesc desc, float scale)
{
    if (scale == 1.0f || desc.is_enum || desc.is_string || desc.is_date_time)
        return sample_value(data, desc);
    ValueDesc scaled_desc = ValueDesc(desc.data_type, desc.unit, desc.pre_scale * scale);
    return sample_value(data, scaled_desc);
}

private ValueDesc make_value_desc(ref const FieldDef fd)
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
    if (!fd.unit)
        return ValueDesc(dt);

    ScaledUnit unit;
    float unit_scale = 1.0f;
    unit.parseUnit(fd.unit, unit_scale);
    return ValueDesc(dt, unit, unit_scale);
}
