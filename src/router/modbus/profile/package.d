module router.modbus.profile;

import std.math	: PI;
import std.format;

enum RecordType : ubyte
{
	uint16 = 0,
	int16,
	uint32,
	int32,
	uint8H,	// masked access
	uint8L, // masked access
	int8H, // masked access
	int8L, // masked access
	exp10, // power of 10
	float32,
	bf16,
	bf32,
	enum16,
	enum32,
	str
}
enum RecordType_str(ushort len) = cast(RecordType)(RecordType.str + len - 1);

enum Unit : uint
{
	none = 0,
	metre,
	squaremetre,
	litre,
	gram,
	second,
	cycle,
	coulomb,
	joule,
	volt,
	ohm,
	farad,
	newton,
	celcius, // TODO: kelvin/farenheit are tricky because they need an offset, not just a scaling factor
	lumen,
	max,

	// scaled units
	percent = centi(Unit.none),
	permille = milli(Unit.none),
	partspermillion = micro(Unit.none), 
	kilometre = scaledUnit(metre, ScaleFactor.kilo),
	centimetre = scaledUnit(metre, ScaleFactor.centi),
	millimetre = scaledUnit(metre, ScaleFactor.milli),
	millilitre = scaledUnit(litre, ScaleFactor.milli),
	kilogram = scaledUnit(gram, ScaleFactor.kilo),
	milligram = scaledUnit(gram, ScaleFactor.milli),
	inch = scaledUnit(metre, ScaleFactor.inch),
	foot = scaledUnit(metre, ScaleFactor.foot),
	yard = scaledUnit(metre, ScaleFactor.yard),
	mile = scaledUnit(metre, ScaleFactor.mile),
	fluidounce = scaledUnit(litre, ScaleFactor.fluidounce),
	gallon = scaledUnit(litre, ScaleFactor.gallon),
	ounce = scaledUnit(gram, ScaleFactor.ounce),
	pound = scaledUnit(gram, ScaleFactor.pound),
	minute = scaledUnit(second, ScaleFactor.minute),
	hour = scaledUnit(second, ScaleFactor.hour),
	day = scaledUnit(second, ScaleFactor.day),
	week = scaledUnit(second, ScaleFactor.week),
	degrees = scaledUnit(cycle, ScaleFactor.degrees),
	radians	= scaledUnit(cycle, ScaleFactor.radians),
	amperehour = scaledUnit(coulomb, ScaleFactor.hour),
	watthour = scaledUnit(joule, ScaleFactor.hour),
	psi = scaledUnit(pascal, ScaleFactor.psi),
	bar = scaledUnit(pascal, ScaleFactor.bar),

	// derivatives
	hertz = derivative(cycle, second),
	ampere = derivative(coulomb, second),
	watt = derivative(joule, second),
	pascal = derivative(newton, squaremetre),
	lux = derivative(lumen, squaremetre),
	metrespersecond = derivative(metre, second),
	kilometresperhour = derivative(kilometre, hour),
}
static assert (Unit.max <= 0xF);

enum ScaleFactor : uint
{
	none = 0,
	peta,
	tera,
	giga,
	mega,
	kilo,
	deci,
	centi,
	milli,
	micro,
	nano,
	pico,
	minute,
	hour,
	day,
	week,
	inch,
	foot,
	yard,
	mile,
	gallon,
	ounce,
	pound,
	fluidounce,
	psi,
	bar,
	degrees,
	radians,
}
static assert (ScaleFactor.max <= 0x1F);

Unit scaledUnit(Unit unit, ScaleFactor scale) => cast(Unit)(scale << 4 | unit);

Unit derivative(Unit base, Unit per) => base << 9 | per;

Unit peta(Unit unit) => scaledUnit(unit, ScaleFactor.peta);
Unit tera(Unit unit) => scaledUnit(unit, ScaleFactor.tera);
Unit mega(Unit unit) => scaledUnit(unit, ScaleFactor.mega);
Unit giga(Unit unit) => scaledUnit(unit, ScaleFactor.giga);
Unit kilo(Unit unit) => scaledUnit(unit, ScaleFactor.kilo);
Unit deci(Unit unit) => scaledUnit(unit, ScaleFactor.deci);
Unit centi(Unit unit) => scaledUnit(unit, ScaleFactor.centi);
Unit milli(Unit unit) => scaledUnit(unit, ScaleFactor.milli);
Unit micro(Unit unit) => scaledUnit(unit, ScaleFactor.micro);
Unit nano(Unit unit) => scaledUnit(unit, ScaleFactor.nano);
Unit pico(Unit unit) => scaledUnit(unit, ScaleFactor.pico);

Unit baseUnit(Unit unit) => cast(Unit)(unit & 0b0000_0000_0011_1100_0001_1110_0000_1111);

bool equivalentUnits(Unit a, Unit b) => a.baseUnit == b.baseUnit;

double convertUnit(double value, Unit from, Unit to)
{
	debug assert(equivalentUnits(from, to));

	if (from < 0x200 && to < 0x200)
		return scaleFactors[from >> 4 & 0x1F] * scaleDivisors[to >> 4 & 0x1F];
	return scaleFactors[from >> 13 & 0x1F] * scaleDivisors[to >> 13 & 0x1F] * scaleDivisors[from >> 4 & 0x1F] * scaleFactors[to >> 4 & 0x1F];
}

double convertUnit(Unit from, Unit to)(double value)
{
	static assert(equivalentUnits(from, to));

	static if (from < 0x200 && to < 0x200)
		enum scale = scaleFactors[from >> 4 & 0x1F] / scaleFactors[to >> 4 & 0x1F];
	else
		enum scale = scaleFactors[from >> 13 & 0x1F] / scaleFactors[to >> 13 & 0x1F] / scaleFactors[from >> 4 & 0x1F] * scaleFactors[to >> 4 & 0x1F];
	return value * scale;
}


struct ModbusRegInfo
{
	ushort reg;			// register address; 5 digits with register type; ie 30001, 40001, etc
	ushort refReg;
	RecordType type = RecordType.uint16; // register type; ie uint16, float, etc. Strings use RecordType_str!(len)
	ubyte seqLen = 1;
	ubyte seqOffset;
	string name;		// field name; ie "soc", "voltage", "power", etc
	string units;		// units of measure; ie "%", "10mV", "kWh", etc
	string desc;		// readable field description
	string[] fields;	// enum or bitfield names; ie [ "off", "on" ], [ "charging", "discharging" ], etc

	this(int reg, RecordType type = RecordType.uint16, string name = null, string units = null, string desc = null, string[] fields = null)
	{
		this.reg = cast(ushort)reg;
		this.refReg = this.reg;
		this.type = type >= RecordType.str ? RecordType.str : type;
		this.seqLen = type >= RecordType.str ? cast(ubyte)(type - RecordType.str + 1) : seqLens[type];
		this.name = name ? name : format("reg%d", reg).idup;
		this.units = units;
		this.desc = desc;
		this.fields = fields;
	}
	this(int reg, string name, string units = null, string desc = null)
	{
		this.reg = cast(ushort)reg;
		this.refReg = this.reg;
		this.type = RecordType.uint16;
		this.seqLen = seqLens[RecordType.uint16];
		this.name = name ? name : format("reg%d", reg).idup;
		this.units = units;
		this.desc = desc;
	}
	this(int reg, int refReg, int seqIndex)
	{
		this.reg = cast(ushort)reg;
		this.refReg = cast(ushort)refReg;
		this.seqOffset = cast(ubyte)seqIndex;
		this.name = null;
		this.units = null;
		this.desc = null;
		this.fields = null;
	}
}

struct RegValue
{
	this(ModbusRegInfo* info)
	{
		this.info = info;
		words[] = 0;
	}

	struct E
	{
		ushort val;
		ushort exp;
	}

	ModbusRegInfo* info;
	union
	{
		ushort u16;
		short i16;
		uint u32;
		int i32;
		float f32;
		E e;
		ushort[12] words;
	}

	string toString()
	{
		import std.conv : to;
		import std.math : pow;

		final switch (info.type) with (RecordType)
		{
			case uint16:
				return u16.to!string;
			case int16:
				return i16.to!string;
			case uint32:
				return u32.to!string;
			case int32:
				return i32.to!string;
			case uint8H:
				return (cast(ubyte)(u16 >> 8)).to!string;
			case uint8L:
				return (cast(ubyte)(u16 & 0xFF)).to!string;
			case int8H:
				return (cast(byte)(u16 >> 8)).to!string;
			case int8L:
				return (cast(byte)(u16 & 0xFF)).to!string;
			case exp10:
				return pow(cast(float)e.val, e.exp).to!string;
			case float32:
				return f32.to!string;
			case bf16:
				return "TODO";
			case bf32:
				return "TODO";
			case enum16:
				if (u16 < info.fields.length)
					return info.fields[u16];
				else
					return u16.to!string;
			case enum32:
				if (u32 < info.fields.length)
					return info.fields[u32];
				else
					return u32.to!string;
			case str:
				char[] s = (cast(char*)words.ptr)[0 .. words.sizeof];
				for (size_t i = 0; i < words.sizeof; ++i)
				{
					if (s[i] == '\0')
						return s[0 .. i].idup;
				}
				return s[].idup;
		}
	}
}

struct ModbusProfile
{
	ModbusRegInfo[int] regInfoById;
	ModbusRegInfo*[string] regByName;

	// TODO: populate from json, yaml, etc

	void populateRegs(ModbusRegInfo[] regs)
	{
		foreach (r; regs)
		{
			regInfoById[r.reg] = r;

			if (r.seqOffset == 0)
			{
				ModbusRegInfo* info = &regInfoById[r.reg];
				regByName[r.name] = info;
				for (int i = 1; i < r.seqLen; ++i)
					regInfoById[r.reg + i] = ModbusRegInfo(r.reg + i, r.reg, i);
			}
		}
	}
}

private:

immutable ubyte[RecordType.max] seqLens = [ 1, 1, 2, 2, 1, 2, 1, 2, 1, 2 ];
immutable string[RecordType.max + 1] typeStrings = [ "u16", "i16", "u32", "i32", "e10", "f32", "bf16", "bf32", "enum16", "enum32", "str" ];

immutable char[ScaleFactor.pico + 1] siScaleFactorLetters = [0,'P','T','G','M','k','d','c','m','u','n','p'];

immutable double[ScaleFactor.max + 1] scaleFactors = [
	1,
	1_000_000_000_000_000,
	1_000_000_000_000,
	1_000_000_000,
	1_000_000,
	1_000,
	0.1,
	0.01,
	0.001,
	0.000_001,
	0.000_000_001,
	0.000_000_000_001,
	60,
	3600,
	86400,
	604_800,
	0.0254,
	0.3048,
	0.9144,
	1_609.344,
	3.785_411_784,
	28.3495,
	453.59237,
	29.573_529_562_5,
	6_894.757_293_168_3,
	100_000,
	360,
	2*PI,
];

immutable double[ScaleFactor.max + 1] scaleDivisors = [
	1,
	0.000_000_000_000_001,
	0.000_000_000_001,
	0.000_000_001,
	0.000_001,
	0.001,
	10,
	100,
	1000,
	1_000_000,
	1_000_000_000,
	1_000_000_000_000,
	1.0/60,
	1.0/3600,
	1.0/86400,
	1.0/604_800,
	1.0/scaleFactors[ScaleFactor.inch],
	1.0/scaleFactors[ScaleFactor.foot],
	1.0/scaleFactors[ScaleFactor.yard],
	1.0/scaleFactors[ScaleFactor.mile],
	1.0/scaleFactors[ScaleFactor.gallon],
	1.0/scaleFactors[ScaleFactor.ounce],
	1.0/scaleFactors[ScaleFactor.pound],
	1.0/scaleFactors[ScaleFactor.fluidounce],
	1.0/scaleFactors[ScaleFactor.psi],
	0.000_01,
	1.0/360,
	1.0/(2*PI),
];



immutable Unit[string] unitNames = [
	"pc": Unit.percent,
	"pct": Unit.percent,
	"percent": Unit.percent,
	"%": Unit.percent,
	"pm": Unit.permille,
	"pml": Unit.permille,
	"permille": Unit.permille,
	"‰": Unit.permille,
	"ppm": Unit.partspermillion,
	"degC": Unit.celcius,
	"°C": Unit.celcius,
	"m": Unit.metre,
	"g": Unit.gram,
	"l": Unit.litre,
	"day": Unit.day,
	"h": Unit.hour,
	"hr": Unit.hour,
	"min": Unit.minute,
	"s": Unit.second,
	"sec": Unit.second,
	"Hz": Unit.hertz,
	"N": Unit.newton,
	"Pa": Unit.pascal,
	"V": Unit.volt,
	"A": Unit.ampere,
	"Ah": Unit.amperehour,
	"W": Unit.watt,
	"Wh": Unit.watthour,
	"F": Unit.farad,
	"O": Unit.ohm,
	"lm": Unit.lumen,
	"lx": Unit.lux,
	"mi": Unit.mile,
	"yd": Unit.yard,
	"ft": Unit.foot,
	"in": Unit.inch,
	"psi": Unit.psi
];
