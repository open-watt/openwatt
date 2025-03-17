module urt.si.unit;

nothrow @nogc:


//
// Encoding schemes:
//
//   Unit: 00000000_uuuipp_uuuipp_uuuipp_uuuipp
//     Where: uuu is the 3-bit unit type
//              i is the inverted bit (ie; n/unit, or unit^^-1)
//             pp is the exponent minus 1 (ie; exp = pp+1, unit^^exp)
//
//                This encoding scheme can map unit exponents [-4, 4]
//
//   ScaledUnit: sssssssx_uuuipp_uuuipp_uuuipp_uuuipp
//     Where:   the lower 24 bits are from Unit
//            x specifies standard or extended encoding
//       Standard (x = 0): sssssss = eeeeeer
//            eeeeee is a 6-bit signed exponent (ie; scale = 10^^e)
//                   the value -32 (100000) is reserved for future expansion
//                 r is a reserved bit...
//       Extended (x = 1): sssssss = ieessss
//               i is the inverted bit (ie 1/scale)
//              ee is the scaling power minus 1 (ie; exp = ee+1, scale^^exp)
//            ssss is a value from the ScaleFactor table
//                 if ssss == 1111, we reinterpret ee as additional expanded encoding for values
//                 that can not be exponentiated, like temperatures
//


// base units
enum Metre = Unit(UnitType.Length);
enum Kilogram = Unit(UnitType.Mass);
enum Second = Unit(UnitType.Time);
enum Ampere = Unit(UnitType.Current);
enum Kelvin = Unit(UnitType.Temperature);
enum Candela = Unit(UnitType.Luma);
enum Radian = Unit(UnitType.Angle);

// non-si units
enum Inch = ScaledUnit(Metre, ScaleFactor.Inch);
enum Foot = ScaledUnit(Metre, ScaleFactor.Foot);
enum Mile = ScaledUnit(Metre, ScaleFactor.Mile);
enum Ounce = ScaledUnit(Kilogram, ScaleFactor.Ounce);
enum Pound = ScaledUnit(Kilogram, ScaleFactor.Pound);
enum Celsius = ScaledUnit(Kelvin, ExtendedScaleFactor.Celsius);
enum Fahrenheit = ScaledUnit(Kelvin, ExtendedScaleFactor.Fahrenheit);
enum Cycle = ScaledUnit(Radian, ScaleFactor.Cycles);
enum Degree = ScaledUnit(Radian, ScaleFactor.Degrees);

// derived units
enum Percent = ScaledUnit(Unit(), -2);
enum Permille = ScaledUnit(Unit(), -3);
enum Centimetre = ScaledUnit(Metre, -2);
enum Millimetre = ScaledUnit(Metre, -3);
enum Kilometre = ScaledUnit(Metre, 3);
enum SquareMetre = Metre^^2;
enum CubicMetre = Metre^^3;
enum Litre = ScaledUnit(CubicMetre, -3);
enum Gram = ScaledUnit(Kilogram, -3);
enum Milligram = ScaledUnit(Kilogram, -6);
enum Hertz = Cycle / Second;
enum Newton = Kilogram * Metre / Second^^2;
enum Pascal = Newton / Metre^^2;
enum PSI = ScaledUnit(Pascal, ScaleFactor.PSI);
enum Joule = Newton * Metre;
enum Watt = Joule / Second;
enum Kilowatt = ScaledUnit(Watt, 3);
enum AmpereHour = ScaledUnit(Coulomb, ScaleFactor.Hour);
enum WattHour = ScaledUnit(Joule, ScaleFactor.Hour);
//enum KilowattHour = TODO: ONOES! Our system can't encode kilowatt-hours! This is disaster!!
enum Coulomb = Ampere * Second;
enum Volt = Watt / Ampere;
enum Ohm = Volt / Ampere;
enum Farad = Coulomb / Volt;
enum Siemens = Ohm^^-1;
enum Weber = Volt * Second;
enum Tesla = Weber / Metre^^2;
enum Henry = Weber / Ampere;
enum Lumen = Candela * Radian^^2;
enum Lux = Lumen / Metre^^2;


enum UnitType : ubyte
{
    None,
    Mass,
    Length,
    Time,
    Current,
    Temperature,
    Luma,
    Angle
}

struct Unit
{
nothrow @nogc:

    uint pack;

    this(UnitType type, int e = 1) pure
    {
        debug assert(e != 0 && uint(e + 4) <= 8);
        pack = (type << 3) | (e < 0 ? 3-e : e-1);
    }

    Unit opBinary(string op)(int e) const pure
        if (op == "^^")
    {
        if (pack == 0 || e == 0)
            return Unit();
        if (pack < 0x40 && (pack & 3) == 0)
            return Unit(pack ^ (e < 0 ? 3-e : e-1));
        if (e == -1)
        {
            enum Signs = 0b000100_000100_000100_000100;

            // sign bits set for valid units
            uint valid = (pack >> 1 | (pack >> 2) | (pack >> 3)) & Signs;
            return Unit(pack ^ valid);
        }
//        if (e == 1)      // this case is highly unlikely, so consider it last
//            return this; // maybe just remove it; not worth the `if`?

        // we'll scale all the magnitudes by the exponent...
        enum Magnitude = 0b000011_000011_000011_000011;
        enum Ones      = 0b000001_000001_000001_000001;

        // one bits set for valid units
        uint valid = (pack >> 3 | (pack >> 4) | (pack >> 5)) & Ones;
        uint mags = (pack & Magnitude);

        bool neg = e < 0;
        mags += valid;
        mags *= neg ? -e : e;
        mags -= valid;

        // check for magnitude overflow
        if (mags & ~Magnitude)
            assert(false, "Invalid exponent: |e| > 4");

        if (neg)
            return Unit((pack & ~Magnitude) ^ (valid << 2) | mags);
        return Unit((pack & ~Magnitude) | mags);
    }

    Unit opBinary(string op)(Unit rh) const pure
        if (op == "*" || op == "/")
    {
        uint lp = pack;
        uint rp = rh.pack;

        if (!rp)
            return this;
        if (!lp)
        {
            static if (op == "*")
                return rh;
            else
                return rh^^-1;
        }

        uint a = lp & 0x3F;
        uint b = rp & 0x3F;

        uint r, s;
        while (true)
        {
            // we need to compound the exponents from each side on ascending order...
            if (a && (b == 0 || (a >> 3) < (b >> 3)))
            {
                r |= a << s;
                s += 6;
                lp >>= 6;
                a = lp & 0x3F;
            }
            else if (a == 0 || (b >> 3) < (a >> 3))
            {
                static if (op == "*")
                    r |= b << s;
                else
                    r |= (b ^ 4) << s;
                s += 6;
                rp >>= 6;
                b = rp & 0x3F;
            }
            else
            {
                // both sides have the same unit type so we sum the exponents...
                int e = decodeExp[a & 7];
//                int e = (a & 4) ? -(a & 3) : (a & 3);
                int be = decodeExp[b & 7];
//                int be = (b & 4) ? -(b & 3) : (b & 3);
                static if (op == "*")
                    e += be;
                else
                    e -= be;

                // the summed exponents may have cancelled out...
                if (e != 0)
                {
                    if (uint(e + 4) > 8)
                        assert(false, "Invalid exponent: |e| > 4");

                    r |= ((a & 0x38) | encodeExp[e + 4]) << s;
//                    r |= ((a & 0x38) | (e < 0 ? 3-e : e-1)) << s;
                    s += 6;
                }

                rp >>= 6, lp >>= 6;
                a = lp & 0x3F;
                b = rp & 0x3F;
            }

            if (!a && !b)
                break;
        }
        return Unit(r);
    }

    void opOpAssign(string op, T)(T rh) pure
    {
        this = this.opBinary!op(rh);
    }

    ptrdiff_t toString(char[] buffer) const
    {
        immutable string[24] si = [
//                "da", "h", "k", "10k", "100k", "M", "10M", "100M", "G", "10G", "100G", "T", "10T", "100T", "P", "10P", "100P", "E", "10E", "100E", "Z", "10Z", "100Z", "Y"
                "10", "100", "k", "10k", "100k", "M", "10M", "100M", "G", "10G", "100G", "T", "10T", "100T", "P", "10P", "100P", "E", "10E", "100E", "Z", "10Z", "100Z", "Y"
            ];
        immutable string[24] si_inv = [
//                "d", "c", "m", "100μ", "10μ", "μ", "100n", "10n", "n", "100p", "10p", "p", "100f", "10f", "f", "100a", "10a", "a", "100z", "10z", "z", "100y", "10y", "y"
                "100m", "10m", "m", "100μ", "10μ", "μ", "100n", "10n", "n", "100p", "10p", "p", "100f", "10f", "f", "100a", "10a", "a", "100z", "10z", "z", "100y", "10y", "y"
            ];

        ptrdiff_t len = 0;

        // ⁰¹⁻²³⁴⁵⁶⁷⁸⁹·°

//        if (q(0).exponent == 0)
//        {
//            // if we have a scaling factor... what do we write?
////            if (sf) ...
//            len = 0;
//            return len;
//        }
//
//        auto name = this in unitNames;
//        if (name)
//        {
//            len = name.length;
//            buffer[0 .. len] = *name;
//            return len;
//        }
//
//        int f = sf();
//        name = unit() in unitNames;
//
//        if ((name || q(1).exponent == 0) && f <= 24)
//        {
//            if (f > 0)
//            {
//                ref immutable string[24] prefix = inv ? si_inv : si;
//
//                uint scale = f - 1;
//                if (q(0).measure == UnitType.Mass)
//                    scale += 3;
//
//                len = prefix[scale].length;
//                buffer[0 .. len] = prefix[scale][];
//            }
//
//            if (name)
//            {
//                buffer[len .. len + name.length] = *name;
//                len += name.length;
//            }
//            else
//            {
//                immutable string[UnitType.max + 1] unit_name = [ "g", "m", "s", "A", "K", "cd", "cy" ];
//
//                string uname = unit_name[q(0).measure];
//                buffer[len .. len + uname.length] = uname[];
//                len += uname.length;
//            }
//
//            if (q(0).measure != 1)
//            {
//                buffer[len++] = '^';
//                len += q(0).exponent.toString(buffer[len .. $]);
//            }
//
//        }
//        else
//        {
//            // multiple terms, or an odd scale factor...
//            // TODO...
//            assert(false);
//        }

        return len;
    }

    size_t toHash() const pure
        => pack;

package:
    this(uint pack) pure
    {
        this.pack = pack;
    }
}

unittest
{
    assert(Unit(UnitType.Mass).pack       == ((UnitType.Mass   << 3) | 0));
    assert(Unit(UnitType.Length, 2).pack  == ((UnitType.Length << 3) | 1));
    assert(Unit(UnitType.Length, -2).pack == ((UnitType.Length << 3) | 5));

    assert(Metre * Unit() == Metre);
    assert(Unit() * Metre == Metre);
    assert(Unit() / Metre == Metre^^-1);
    assert(Metre * Metre^^-1 == Unit());
    assert(Cycle / Second == Hertz);
    assert(Metre^^2 * Metre == Metre^^3);
    assert((Metre^^-1)^^-1 == Metre);
    assert((Metre^^-1)^^2 == Metre^^-2);

    Unit farad = Kilogram^^-1 * Metre^^-2 * Second^^4 * Ampere^^2;
    assert(farad.pack == ((UnitType.Mass << 3)     | (4 << 0)  |
                          (UnitType.Length << 9)   | (5 << 6)  |
                          (UnitType.Time << 15)    | (3 << 12) |
                          (UnitType.Current << 21) | (1 << 18)));

    farad *= Metre / Second;
    assert(farad.pack == ((UnitType.Mass << 3)     | (4 << 0)  |
                          (UnitType.Length << 9)   | (4 << 6)  |
                          (UnitType.Time << 15)    | (2 << 12) |
                          (UnitType.Current << 21) | (1 << 18)));

    farad = farad^^-1;
    assert(farad.pack == ((UnitType.Mass << 3)     | (0 << 0)  |
                          (UnitType.Length << 9)   | (0 << 6)  |
                          (UnitType.Time << 15)    | (6 << 12) |
                          (UnitType.Current << 21) | (5 << 18)));

    // TODO: it'd be really cool to test the assert cases...
}


enum ScaleFactor : ubyte
{
    Minute = 0,
    Hour,
    Day,
    Inch,
    Foot,
    Mile,
    Ounce,
    Pound,
    USFluidOunce,
    USGallon,
    UKFluidOunce,
    UKGallon,
    PSI,
    Cycles,
    Degrees,
}
static assert(ScaleFactor.max < 15);

enum ExtendedScaleFactor : ubyte
{
    Res1 = 0,   // what here?
    Celsius = 1,
    Res2 = 2,   // what here?
    Fahrenheit = 3,
}

struct ScaledUnit
{
nothrow @nogc:

    uint pack;

    this(Unit u, int e = 0) pure
    {
        pack = u.pack | (e << 26);
    }

    this(Unit u, ScaleFactor sf, int e = 1) pure
    {
        pack = u.pack;

        if (e == 0)
            return;

        assert(uint(e + 4) <= 8);

        if (e < 0)
            pack |= 0x81000000 | (sf << 25) | (~e << 29);
        else
            pack |= 0x01000000 | (sf << 25) | ((e - 1) << 29);
    }

    this(Unit u, ExtendedScaleFactor scaleFactor, bool inverse = false) pure
    {
        pack = u.pack | 0x1F000000 | (scaleFactor << 29) | (inverse << 31);
    }

    bool siScale() const pure
        => (pack & 0x1000000) == 0;
    bool isExtended() const pure
        => (pack & 0x1F000000) == 0x1F000000;
    bool isTemperature() const pure
        => (pack & 0x3F000000) == 0x3F000000;

    int exp() const pure
        => int(pack) >> 26;

    bool inv() const pure
        => pack >> 31;
    ScaleFactor sf() const pure
        => cast(ScaleFactor)((pack >> 25) & 0xF);
    ExtendedScaleFactor esf() const pure
        => cast(ExtendedScaleFactor)((pack >> 29) & 0x3);

    bool canCompare(ScaledUnit b) const pure
    {
        return unit == b.unit;
    }

    double scale(bool inv = false)() const pure
    {
        if (siScale)
        {
            int e = exp();
            if (inv)
                e = -e;
            if (uint(e + 9) < 19)
                return sciScaleFactor[e + 9];
            return 10^^e;
        }

        if (isExtended())
            return extScaleFactor[(pack >> 29) ^ (inv << 2)];

        double s = scaleFactor[(pack >> 31) ^ inv][sf()];
        for (uint i = ((pack >> 29) & 3); i > 0; --i)
            s *= s;
        return s;
    }
    double offset(bool inv = false)() const pure
    {
        if (!isTemperature())
            return 0;
        return tempOffsets[(pack >> 30) ^ (inv << 1)];
    }

    Unit unit() const pure
        => Unit(pack & 0xFFFFFF);

    ScaledUnit opBinary(string op)(int e) const pure
        if (op == "^^")
    {
        if (pack == 0 || e == 0)
            return ScaledUnit();
        if (e == 1)
            return this;

        uint u = (unit^^e).pack;
        if (e == -1)
        {
            if (siScale())
                return ScaledUnit(u | (-exp() << 26));
            return ScaledUnit(u | (pack & 0xFF000000) ^ 0x80000000);
        }

        if (siScale())
            return ScaledUnit(u | ((exp() * e) << 26));

        // if it's extended, we can't exponentiate these units...
        assert(!isExtended(), "Temperature units can't be multiplied");

        int f = decodeExp[pack >> 29] * e;

        if (uint(f + 4) > 8)
            assert(false, "Invalid exponent: |e| > 4");

        return ScaledUnit(u | (pack & 0x1F000000) | (encodeExp[f + 4] << 29));
    }

    ScaledUnit opBinary(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        return ScaledUnit(unit.opBinary!op(b).pack | (pack & 0xFF000000));
    }

    ScaledUnit opBinaryRight(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        static if (op == "*")
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000));
        else
        {
            if (siScale())
                return ScaledUnit(b.opBinary!op(unit).pack | (-(int(pack) >> 26) << 26));
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000) ^ 0x80000000);
        }
    }

    ScaledUnit opBinary(string op)(ScaledUnit b) const pure
        if (op == "*" || op == "/")
    {
        uint u = unit.opBinary!op(b.unit).pack;

        ubyte f = pack >> 24;
        ubyte bf = b.pack >> 24;

        if (f == 0) // if LHS is identity
        {
            static if (op == "*")
                return ScaledUnit(u | (bf << 24));
            else
            {
                if (bf == 0)
                    return ScaledUnit(u);
                if ((bf & 1) == 0)
                    return ScaledUnit(u | (-(int(b.pack) >> 26) << 26));
                return ScaledUnit(u | ((bf ^ 0x80) << 24));
            }
        }
        else if (bf == 0) // if RHS is identity
            return ScaledUnit(u | (pack & 0xFF000000));

        if (siScale())
        {
            assert(b.siScale(), "Can't combine SI and arbitrary units");

            static if (op == "*")
                return ScaledUnit(u | ((exp() + b.exp()) << 26));
            else
                return ScaledUnit(u | ((exp() - b.exp()) << 26));
        }

        assert(!b.siScale(), "Can't combine SI and arbitrary units");
        assert(!isExtended(), "Temperature units can't be multiplied");
        assert(sf() == b.sf(), "Can't combine mismatching arbitrary units");

        static if (op == "*")
            int e = decodeExp[f >> 5] + decodeExp[bf >> 5];
        else
            int e = decodeExp[f >> 5] - decodeExp[bf >> 5];

        if (e == 0)
            return ScaledUnit(u);

        if (uint(e + 4) > 8)
            assert(false, "Invalid exponent: |e| > 4");

        return ScaledUnit(u | (pack & 0x1F000000) | (encodeExp[e + 4] << 29));
    }

    void opOpAssign(string op, T)(T rh) pure
    {
        this = this.opBinary!op(rh);
    }

    bool opEquals(ScaledUnit rh) const pure
        => pack == rh.pack;

    bool opEquals(Unit rh) const pure
        => (pack & 0xFF000000) ? false : unit == rh;

    size_t toHash() const pure
        => pack;

package:
    this(uint pack) pure
    {
        this.pack = pack;
    }
}

unittest
{
    assert(ScaledUnit(Metre) * ScaledUnit(Metre) == ScaledUnit(Metre^^2));
    assert(ScaledUnit(Metre) / ScaledUnit(Metre) == ScaledUnit());

    // si scale
    assert(Kilometre * ScaledUnit() == Kilometre);
    assert(Kilometre / ScaledUnit() == Kilometre);
    assert(ScaledUnit() * Kilometre == Kilometre);
    assert(ScaledUnit() / Kilometre == Kilometre^^-1);

    assert(Metre * Kilometre == ScaledUnit(Metre^^2, 3));
    assert(Metre / Kilometre == ScaledUnit(Unit(), -3));
    assert(Metre * Kilometre^^-1 == Metre / Kilometre);
    assert(Kilometre * Metre == ScaledUnit(Metre^^2, 3));
    assert(Kilometre / Metre == ScaledUnit(Unit(), 3));
    assert(Kilometre * Kilometre == Kilometre^^2);
    assert(Kilometre / Kilometre == ScaledUnit());
    assert(Kilometre^^2 == ScaledUnit(Metre^^2, 6));
    assert((Kilometre^^2)^^-2 == ScaledUnit(Metre^^-4, -12));

    // arbitrary scale
    assert(Inch * ScaledUnit() == Inch);
    assert(Inch / ScaledUnit() == Inch);
    assert(ScaledUnit() * Inch == Inch);
    assert(ScaledUnit() / Inch == Inch^^-1);

    assert(Inch * Inch == ScaledUnit(Metre^^2, ScaleFactor.Inch, 2));
    assert(Inch / Inch == ScaledUnit());
    assert(Inch * Inch^^-1 == ScaledUnit());
    assert(Inch^^2 * Inch == Inch^^3);
    assert((Inch^^2)^^-2 == ScaledUnit(Metre^^-4, ScaleFactor.Inch, -4));

    assert(Metre * Inch == ScaledUnit(Metre^^2, ScaleFactor.Inch));
    assert(Metre / Inch == ScaledUnit(Unit(), ScaleFactor.Inch, -1));
}


private:

import urt.math : PI;

immutable byte[8] decodeExp = [ 1, 2, 3, 4, -1, -2, -3, -4 ];
immutable ubyte[9] encodeExp = [ 7, 6, 5, 4, 0, 0, 1, 2, 3 ];

immutable double[19] sciScaleFactor = [ 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9 ];

immutable double[16][2] scaleFactor = [ [
    60,     // Minute
    3600,   // Hour
    86400,  // Day
    0.0254, // Inch
    0.3048, // Foot
    1609.344, // Mile
    453.59237 / 16, // Ounce
    453.59237, // Pound
    3.785411784 / 128, // USFluidOunce
    3.785411784, // USGallon
    4.54609 / 160, // UKFluidOunce
    4.54609, // UKGallon
    6894.7572931683, // PSI => 4.4482216152605/(0.0254*0.0254)
    2*PI, // Cycles
    PI/180, // Degrees
    double.nan // extended...
], [
    1/60,   // Minute
    1/3600, // Hour
    1/86400, // Day
    1/0.0254, // Inch
    1/0.3048, // Foot
    1/1609.344, // Mile
    16/453.59237, // Ounce
    1/453.59237, // Pound
    128/3.785411784, // USFluidOunce
    1/3.785411784, // USGallon
    160/4.54609, // UKFluidOunce
    1/4.54609, // UKGallon
    1/6894.7572931683, // PSI
    1/(2*PI), // Cycles
    180/PI, // Degrees
    double.nan // extended...
] ];

immutable double[8] extScaleFactor = [
    0,      // Res1
    1,      // Celsius
    0,      // Res2
    5.0/9,  // Fahrenheit

    0,      // 1/Res1
    1,      // 1/Celsius
    0,      // 1/Res2
    9.0/5   // 1/Fahrenheit
];

// what is the proper order?
immutable double[4] tempOffsets = [
    273.15,                 // C -> K
    (-32.0*5)/9 + 273.15,   // F -> K

    -273.15,                // K -> C
    (-273.15*9)/5 + 32      // K -> F
];

immutable string[ScaledUnit] unitNames = [

    // ⁰¹⁻²³⁴⁵⁶⁷⁸⁹·°

    // base units
    ScaledUnit()            : "",
    ScaledUnit(Metre)       : "m",
    ScaledUnit(Kilogram)    : "kg",
    ScaledUnit(Second)      : "s",
    ScaledUnit(Ampere)      : "A",
    ScaledUnit(Kelvin)      : "°K",
    ScaledUnit(Candela)     : "cd",
    ScaledUnit(Radian)      : "rad",

    // derived units
    ScaledUnit(SquareMetre) : "m²",
    ScaledUnit(CubicMetre)  : "m³",
    ScaledUnit(Newton)      : "N",
    ScaledUnit(Pascal)      : "Pa",
    ScaledUnit(Joule)       : "J",
    ScaledUnit(Watt)        : "W",
    ScaledUnit(Coulomb)     : "C",
    ScaledUnit(Volt)        : "V",
    ScaledUnit(Ohm)         : "Ω",
    ScaledUnit(Farad)       : "F",
    ScaledUnit(Siemens)     : "S",
    ScaledUnit(Weber)       : "Wb",
    ScaledUnit(Tesla)       : "T",
    ScaledUnit(Henry)       : "H",
    ScaledUnit(Lumen)       : "lm",
    ScaledUnit(Lux)         : "lx",

    // scaled units
    Inch        : "in",
    Foot        : "ft",
    Mile        : "mi",
    Ounce       : "oz",
    Pound       : "lb",
    Celsius     : "°C",
    Fahrenheit  : "°F",
    Cycle       : "cy",
    Degree      : "°",

    Percent     : "%",
    Permille    : "‰",
    Centimetre  : "cm",
    Millimetre  : "mm",
    Kilometre   : "km",
    Litre       : "l",
    Gram        : "g",
    Milligram   : "mg",
    Hertz       : "Hz",
    PSI         : "psi",
    Kilowatt    : "kW",
    AmpereHour  : "Ah",
    WattHour    : "Wh",
];
