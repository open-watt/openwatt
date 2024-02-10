module manager.units;

import std.math	: PI, pow;
import std.conv;


struct UnitDef
{
	double scale = 1;
	double offset = 0;

	double normalise(double value) const { return value * scale + offset; }
	double denormalise(double value) const { return (value - offset) / scale; }
}

double normalise(string unit)(double value)
{
	enum UnitDef unit = unit.parseUnitDef;
	return value * unit.scale + unit.offset;
}
double denormalise(string unit)(double value)
{
	enum UnitDef unit = unit.parseUnitDef;
	enum UnitDef inv = UnitDef(1.0/unit.scale, -unit.offset/unit.scale);
	return value * inv.scale + inv.offset;
}

double convertUnit(string from, string to)(double value)
{
	enum UnitDef conv = unitConversion(from, to);
	return value * conv.scale + conv.offset;
}

UnitDef unitConversion(string from, string to)
{
	UnitDef fromNorm = from.parseUnitDef;
	UnitDef toNorm = to.parseUnitDef;
	return UnitDef(fromNorm.scale/toNorm.scale, (fromNorm.offset - toNorm.offset)/toNorm.scale);
}

UnitDef unitConversion(UnitDef from, UnitDef to)
{
	return UnitDef(from.scale*to.scale, from.offset*to.scale + to.offset);
}

UnitDef getUnitConv(string unit)
{
	static UnitDef[string] cache;
	if (!unit)
		return UnitDef();
	UnitDef* cached = unit in cache;
	if (cached)
		return *cached;
	return cache[unit] = unit.parseUnitDef;
}

UnitDef getUnitConv(string from, string to)
{
	return unitConversion(from.getUnitConv, to.getUnitConv);
}

UnitDef parseUnitDef(string unitDef)
{
	double multiple = 1;
	double offset = 0;
	string unit = null;

	// parse number with optional decimal
	size_t i = 0;
	int hasDot = 0;
	while (i < unitDef.length && (unitDef[i] >= '0' && unitDef[i] <= '9' || unitDef[i] == '.' && !hasDot++))
		i++;
	if (i > 0)
	{
		multiple = unitDef[0 .. i].to!double;
		unitDef = unitDef[i .. $];
	}

	// parse unit name, scanning in reverse for '+' after which will be an optional offset
	i = unitDef.length;
	while (i > 0 && unitDef[i - 1] != '+')
		i--;
	if (i > 0)
	{
		offset = unitDef[i .. $].to!double;
		unitDef = unitDef[0 .. i - 1];
	}

	// what's left now should be the unit
	unit = unitDef;

	if (!unit.length)
		return UnitDef(multiple, offset);

	// now let's try and disect the unit name
	// first, we can chop off any per- suffixes
	string per;
	i = unitDef.length;
	while (i > 0 && unitDef[i - 1] != '/')
		i--;
	if (i > 0)
	{
		per = unit[i .. $];
		unitDef = unitDef[0 .. i - 1];
	}

	// TODO: if the suffix is an SI unit, then the thing needs to be scaled... but the interior unit also needs to be handled
	if (per)
	{
		// let's just not process suffix units for now...
		return UnitDef(multiple, offset);
	}

	// see if it's an absolute unit
	const(UnitDef)* conv = unit in absoluteUnitMap;
	if (conv)
		return UnitDef(conv.scale * multiple, conv.offset + offset);

	conv = unit in siUnitMap;
	if (conv)
		return UnitDef(conv.scale * multiple, conv.offset + offset);

	conv = unit[0] in siScaleUnitMap;
	if (conv)
	{
		multiple *= conv.scale;
		offset += conv.offset;

		conv = unit in siUnitMap;
		if (conv)
			return UnitDef(conv.scale * multiple, conv.offset + offset);
	}

	return UnitDef(multiple, offset);
}

immutable UnitDef[char] siScaleUnitMap = [
	'Y':	UnitDef(1e24),	// yotta
	'Z':	UnitDef(1e21),	// zetta
	'E':	UnitDef(1e18),	// exa
	'P':	UnitDef(1e15),	// peta
	'T':	UnitDef(1e12),	// tera
	'G':	UnitDef(1e9),	// giga
	'M':	UnitDef(1e6),	// mega
	'k':	UnitDef(1e3),	// kilo
	'h':	UnitDef(1e2),	// hecto
	'd':	UnitDef(1e-1),	// deci
	'c':	UnitDef(1e-2),	// centi
	'm':	UnitDef(1e-3),	// milli
	'u':	UnitDef(1e-6),	// micro
	'n':	UnitDef(1e-9),	// nano
	'p':	UnitDef(1e-12),	// pico
	'f':	UnitDef(1e-15),	// femto
	'a':	UnitDef(1e-18),	// atto
	'z':	UnitDef(1e-21),	// zepto
	'y':	UnitDef(1e-24),	// yocto
];

immutable UnitDef[string] siUnitMap = [
	"m":	UnitDef(1),			// metre
	"m²":	UnitDef(1),			// square metre
	"l":	UnitDef(1),			// litre
	"m³":	UnitDef(1000),		// cubic metre
	"m3":	UnitDef(1000),		// cubic metre
	"m^3":	UnitDef(1000),		// cubic metre
	"g":	UnitDef(1),			// gram
	"s":	UnitDef(1),			// second
	"Hz":	UnitDef(1),			// hertz
	"V":	UnitDef(1),			// volt
	"A":	UnitDef(1),			// ampere
	"W":	UnitDef(1),			// watt
	"VA":	UnitDef(1),			// voltamp
	"VAR":	UnitDef(1),			// voltamp-reactive
	"C":	UnitDef(1.0/3600),	// coulomb
	"Ah":	UnitDef(1),			// amperehour
	"J":	UnitDef(1.0/3600),	// joule
	"Wh":	UnitDef(1),			// watthour
	"VAh":	UnitDef(1),			// voltamphour
	"VARh":	UnitDef(1),			// voltamp-reactivehour
	"Ω":	UnitDef(1),			// ohm (shuold we accept O ?)
	"ohm":	UnitDef(1),			// ohm
	"F":	UnitDef(1),			// farad
	"N":	UnitDef(1),			// newton
	"Pa":	UnitDef(1),			// pascal
	"lm":	UnitDef(1),			// lumen
	"lx":	UnitDef(1),			// lux
	"lux":	UnitDef(1),			// lux
];

immutable UnitDef[string] absoluteUnitMap = [
	"%":		UnitDef(0.01),				// percent
	"pc":		UnitDef(0.01),				// percent
	"pct":		UnitDef(0.01),				// percent
	"percent":	UnitDef(0.01),				// percent
	"‰":		UnitDef(0.001),				// permille
	"pm":		UnitDef(0.01),				// percent
	"pml":		UnitDef(0.01),				// percent
	"permille":	UnitDef(0.001),				// permille
	"ppm":		UnitDef(0.000001),			// parts per million
	"in":		UnitDef(0.0254),			// inch
	"\"":		UnitDef(0.0254),			// inch
	"ft":		UnitDef(0.3048),			// foot
	"'":		UnitDef(0.3048),			// foot
	"mi":		UnitDef(5280 * 0.3048),		// mile
	"nmi":		UnitDef(1852),				// nautical mile
	"sqm":		UnitDef(1),					// square metre
	"ha":		UnitDef(10000),				// hectare
	"in²":		UnitDef(0.0254 * 0.0254),	// square inch
	"sqin":		UnitDef(0.0254 * 0.0254),	// square inch
	"sq-in":	UnitDef(0.0254 * 0.0254),	// square inch
	"sq in":	UnitDef(0.0254 * 0.0254),	// square inch
	"US floz":	UnitDef(3.785411784 / 128),	// US fluid ounce
	"US fl-oz":	UnitDef(3.785411784 / 128),	// US fluid ounce
	"US fl oz":	UnitDef(3.785411784 / 128),	// US fluid ounce
	"US pt":	UnitDef(3.785411784 / 8),	// US pint
	"US qt":	UnitDef(3.785411784 / 4),	// US quart
	"US gal":	UnitDef(3.785411784),		// US gallon
	"UK floz":	UnitDef(4.54609 / 160),		// UK fluid ounce
	"UK fl-oz":	UnitDef(4.54609 / 160),		// UK fluid ounce
	"UK fl oz":	UnitDef(4.54609 / 160),		// UK fluid ounce
	"UK pt":	UnitDef(4.54609 / 8),		// UK pint
	"UK qt":	UnitDef(4.54609 / 4),		// UK quart
	"UK gal":	UnitDef(4.54609),			// UK gallon
	"oz":		UnitDef(0.45359237 / 16),	// ounce
	"lb":		UnitDef(0.45359237),		// pound
	"min":		UnitDef(60),				// minute
	"h":		UnitDef(3600),				// hour
	"d":		UnitDef(86400),				// day
	"deg":		UnitDef(1.0/360),			// degrees
	"rad":		UnitDef(1.0/(2*PI)),		// radians
	"ftlb":		UnitDef(1.3558179483314 / 3600),// foot-pound
	"ft-lb":	UnitDef(1.3558179483314 / 3600),// foot-pound
	"ft lb":	UnitDef(1.3558179483314 / 3600),// foot-pound
	"lbf":		UnitDef(4.4482216152605),	// pound-force
	"psi":		UnitDef(6894.757293168),	// psi
	"bar":		UnitDef(100000),			// bar
	"°C":		UnitDef(1),					// celcius
	"degC":		UnitDef(1),					// celcius
	"deg C":	UnitDef(1),					// celcius
	"°F":		UnitDef(5.0/9, -160.0/9),	// fahrenheit
	"degF":		UnitDef(5.0/9, -160.0/9),	// fahrenheit
	"deg F":	UnitDef(5.0/9, -160.0/9),	// fahrenheit
	"°K":		UnitDef(1, -273.15),		// kelvin
	"degK":		UnitDef(1, -273.15),		// kelvin
	"deg K":	UnitDef(1, -273.15),		// kelvin
];

/*
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
*/
