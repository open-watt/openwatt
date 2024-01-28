module router.modbus.profile;

import std.algorithm : map;
import std.ascii : toLower;
import std.format;
import std.math	: PI, pow;

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

enum Access : byte
{
	Read,
	Write,
	ReadWrite
}

enum Frequency : ubyte
{
	Realtime = 0,
	High,	// ie, seconds
	Medium,	// ie, 10s seconds
	Low,	// ie, minutes
	Constant,
	Configuration
}

enum Unit : uint
{
	none = 0,
	metre,
	squaremetre,
	litre,
	gram,
	second,
	cycle,
	coulomb, // base unit for amperehour
	joule,   // base unit for watthour
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
	rpm = derivative(cycle, minute),
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
	Access access = Access.Read;
	ubyte seqLen = 1;
	ubyte seqOffset;
	string name;		// field name; ie "soc", "voltage", "power", etc
	string units;		// units of measure; ie "%", "kWh", "10mV+1000", etc
	string displayUnits;
	Frequency updateFrequency = Frequency.Medium;
	string desc;		// readable field description
	string[] fields;	// enum or bitfield names; ie [ "off", "on" ], [ "charging", "discharging" ], etc
	string[] fieldDesc;

	this(int reg, string type = "u16", string name = null, string units = null, string displayUnits = null, Frequency updateFrequency = Frequency.Medium, string desc = null, string[] fields = null, string[] fieldDesc = null)
	{
		this.reg = cast(ushort)reg;
		this.refReg = this.reg;
		parseTypeString(type);
		this.name = name ? name : format("reg%d", reg).idup;
		this.units = units;
		this.units = displayUnits ? displayUnits : units;
		this.updateFrequency = updateFrequency;
		this.desc = desc;
		this.fields = fields;
		this.fields = fieldDesc;
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

private:
	void parseTypeString(string type)
	{
		foreach (i; 0 .. RecordType.max + 1)
		{
			string ts = typeStrings[i];
			if (type.length >= ts.length && type[0..ts.length] == ts[])
			{
				this.type = cast(RecordType)i;

				size_t j = i + 1;
				if (i == RecordType.str)
				{
					assert(type.length > 3, "String type needs length, eg: \"str10\"");
					this.seqLen = 0;
					for (; j < type.length; ++j)
					{
						if (type[j] < '0' || type[j] > '9')
							break;
						this.seqLen = cast(ubyte)(this.seqLen*10 + type[j] - '0');
					}
					assert(this.seqLen > 0, "String length must be greater than 0");
				}
				else
					this.seqLen = seqLens[this.type];

				if (j < type.length && type[j] == '/' && j + 1 < type.length)
				{
					++j;
					if (type[j] == 'R')
					{
						if (j + 1 < type.length && type[j + 1] == 'W')
							this.access = Access.ReadWrite;
						else
							this.access = Access.Read;
					}
					else if (type[j] == 'W')
						this.access = Access.Write;
				}
				break;
			}
		}
	}
}

struct RegValue
{
	this(const ModbusRegInfo* info)
	{
		this.info = info;
		words[] = 0;
	}

	struct E
	{
		ushort val;
		ushort exp;
	}

	const ModbusRegInfo* info;
	union
	{
		ulong u;
		long i;
		double f;
		E e;
		ushort[12] words;
	}

//	auto opCast(T)()
//	{
//		static if (is(T : double))
//		{
//		}
//	}

	double toFloat()
	{
		final switch (info.type) with (RecordType)
		{
			case uint16:
			case uint32:
			case uint8H:
			case uint8L:
			case bf16:
			case bf32:
			case enum16:
			case enum32:
				return cast(double)u;
			case int16:
			case int32:
			case int8H:
			case int8L:
				return cast(double)i;
			case float32:
				return f;
			case exp10:
				return pow(cast(double)e.val, e.exp);
			case str:
				return double.nan;
		}
	}

	string toString()
	{
		import std.conv : to;

		string s;

		final switch (info.type) with (RecordType)
		{
			case uint16:
			case uint32:
			case uint8H:
			case uint8L:
				s = u.to!string;
				break;
			case int16:
			case int32:
			case int8H:
			case int8L:
				s = i.to!string;
				break;
			case float32:
				s = f.to!string;
				break;
			case exp10:
				s = pow(cast(double)e.val, e.exp).to!string;
				break;
			case bf16:
				for (auto i = 0; i < 16; ++i)
				{
					if (info.fields)
					{
						if (u & (1 << i))
						{
							if (s)
								s ~= " | ";
							s ~= info.fields[i];
						}
					}
					else
						s ~= (u & (1 << i)) ? "X" : "O";
				}
				s = s ? s : "NONE";
				break;
			case bf32:
				for (auto i = 0; i < 32; ++i)
				{
					if (info.fields)
					{
						if (u & (1 << i))
						{
							if (s)
								s ~= " | ";
							s ~= info.fields[i];
						}
					}
					else
						s ~= (u & (1 << i)) ? "X" : "O";
				}
				s = s ? s : "NONE";
				break;
			case enum16:
				if (u < info.fields.length)
					s = info.fields[u];
				else
					s = u.to!string;
				break;
			case enum32:
				if (u < info.fields.length)
					s = info.fields[u];
				else
					s = u.to!string;
				break;
			case str:
				assert(info.seqLen <= words.sizeof);
				char[] c = (cast(char*)words.ptr)[0 .. info.seqLen];
				for (size_t i = 0; i < c.length; ++i)
				{
					if (c[i] == '\0')
					{
						s = c[0 .. i].idup;
						break;
					}
				}
				s = s ? s : c[].idup;
				break;
		}
		return info.name ~ ": " ~ s;
	}
}

struct ModbusProfile
{
	ModbusRegInfo[] registers;
	ModbusRegInfo*[int] regById;
	ModbusRegInfo*[string] regByName;

	// TODO: populate from json, yaml, etc

	void populateRegs(ModbusRegInfo[] regs)
	{
		registers = regs;

		foreach (ref r; regs)
		{
			regById[r.reg] = &r;
			regByName[r.name] = &r;
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
