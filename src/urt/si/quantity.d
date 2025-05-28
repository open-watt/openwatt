module urt.si.quantity;

import urt.meta : TypeForOp;
import urt.si.unit;
import urt.traits;

nothrow @nogc:


alias VarQuantity = Quantity!(double);
alias Scalar = Quantity!(double, ScaledUnit());
alias Metres = Quantity!(double, ScaledUnit(Metre));
alias Seconds = Quantity!(double, ScaledUnit(Second));
alias Volts = Quantity!(double, ScaledUnit(Volt));
alias Amps = Quantity!(double, ScaledUnit(Ampere));
alias AmpHours = Quantity!(double, AmpereHour);
alias Watts = Quantity!(double, ScaledUnit(Watt));
alias Kilowatts = Quantity!(double, Kilowatt);
alias WattHours = Quantity!(double, WattHour);


struct Quantity(T, ScaledUnit _unit = ScaledUnit(uint.max))
{
nothrow @nogc:

    alias This = Quantity!(T, _unit);

    enum Dynamic = _unit.pack == uint.max;
    enum IsCompatible(ScaledUnit U) = _unit.unit == U.unit;

    T value = 0;

    static if (Dynamic)
        ScaledUnit unit;
    else
        alias unit = _unit;

    bool isCompatible(U, ScaledUnit _U)(Quantity!(U, _U) compatibleWith) const pure
        if (is(U : T))
        => unit.unit == compatibleWith.unit.unit;

    static if (Dynamic)
    {
        this(T value, ScaledUnit unit = ScaledUnit()) pure
        {
            this.unit = unit;
            this.value = value;
        }
    }
    else
    {
        this(T value) pure
        {
            this.value = value;
        }
    }

    this(U, ScaledUnit _U)(Quantity!(U, _U) b) pure
        if (is(U : T))
    {
        static if (Dynamic)
        {
            unit = b.unit;
            value = b.value;
        }
        else
        {
            static if (b.Dynamic)
                assert(isCompatible(b), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);
            value = adjustScale(b);
        }
    }
    
    void opAssign()(T value) pure
    {
        static if (Dynamic)
            unit = Scalar;
        else
            static assert(unit == Unit(), "Incompatible units: ", unit.toString, " and Scalar");
        this.value = value;
    }

    void opAssign(U, ScaledUnit _U)(Quantity!(U, _U) b) pure
    {
        static assert(__traits(compiles, value = b.value), "cannot implicitly convert ScaledUnit of type `", U, "` to `", T, "`");

        static if (Dynamic)
        {
            unit = b.unit;
            value = b.value;
        }
        else
        {
            static if (b.Dynamic)
                assert(isCompatible(b), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);
            value = adjustScale(b);
        }
    }

    auto opUnary(string op)() const pure
        if (op == "+" || op == "-")
    {
        alias RT = Quantity!(TypeForOp!(op, T), _unit);
        static if (Dynamic)
            return RT(mixin(op ~ "value"), unit);
        else
            return RT(mixin(op ~ "value"));
    }

    auto opBinary(string op, U)(U value) const pure
        if ((op == "+" || op == "-") && is(U : T))
        => opBinary!op(Quantity!(U, ScaledUnit())(value));

    auto opBinary(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
        if ((op == "+" || op == "-") && is(U : T))
    {
        // TODO: what unit should be result take?
        //       for float T, I reckon maybe the MAX exponent?
        //       for int types... we need to do some special shit to manage overflows!
        // HACK: for now, we just scale to the left-hand size... :/
        static if (!Dynamic && !b.Dynamic && unit == Unit() && b.unit == Unit())
            return mixin("value " ~ op ~ " b.value");
        else
        {
            static if (Dynamic || b.Dynamic)
                assert(isCompatible(b), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);

            Quantity!(TypeForOp!(op, T, U), _unit) r;
            r.value = mixin("value " ~ op ~ " adjustScale(b)");
            static if (Dynamic)
                r.unit = unit;
            return r;
        }
    }

    auto opBinary(string op, U)(U value) const pure
        if ((op == "*" || op == "/") && is(U : T))
    {
        static if (!Dynamic && unit == Unit())
            return mixin("this.value " ~ op ~ " value");
        else
        {
            Quantity!(TypeForOp!(op, T, U), unit) r;
            r.value = mixin("this.value " ~ op ~ " value");
            static if (Dynamic)
                r.unit = unit;
            return r;
        }
    }

    auto opBinary(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
        if ((op == "*" || op == "/") && is(U : T))
    {
        static if (!Dynamic && !b.Dynamic && unit == Unit() && b.unit == Unit())
            return mixin("value " ~ op ~ " b.value");
        else
        {
            // TODO: if the unit product is invalid, then we need to decide a target scaling factor...
            static if (Dynamic || b.Dynamic)
                const u = mixin("unit " ~ op ~ " b.unit");
            else
                enum u = mixin("unit " ~ op ~ " b.unit");

            alias RT = TypeForOp!(op, T, U);
            RT v = mixin("value " ~ op ~ " b.value");

            static if (Dynamic || b.Dynamic)
                return Quantity!RT(v, u);
            else
                return Quantity!(RT, u)(v);
        }
    }

    void opOpAssign(string op)(T value) pure
    {
        // TODO: in D; ubyte += int is allowed, so we should cast the result to T
        this = opBinary!op(value);
    }

    void opOpAssign(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) pure
    {
        // TODO: in D; ubyte += int is allowed, so we should cast the result to T
        this = opBinary!op(b);
    }

    bool opCast(T : bool)() const pure
        => value != 0;

    // not clear if this should return the raw value, or the normalised value...?
//    T opCast(T)() const pure
//        if (isSomeFloat!T || isSomeInt!T)
//    {
//        assert(unit.pack == 0, "Non-scalar unit can't cast to scalar");
//        assert(false, "TODO: should we be applying the scale to this result?");
//        return cast(T)value;
//    }

    T opCast(T)() const pure
        if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
    {
        static if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
        {
            T r;
            static if (Dynamic || T.Dynamic)
                assert(isCompatible(r), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", r.unit.toString, " and ", unit.toString);
            r.value = cast(U)r.adjustScale(this);
            static if (T.Dynamic)
                r.unit = unit;
            return r;
        }
    }

    bool opEquals(U)(U value) const pure
        if (is(U : T))
    {
        if (unit == Unit())
            return value == value;
        return false;
    }

    bool opEquals(double epsilon = 0, U, ScaledUnit _U)(Quantity!(U, _U) rh) const pure
        => opCmp!(epsilon, true)(rh);

    auto opCmp(double epsilon = 0, bool eq = false, U, ScaledUnit _U)(Quantity!(U, _U) rh) const pure
        if (is(U : T))
    {
        double lhs = value;
        double rhs = rh.value;

        // if they have the same unit and scale...
        if (unit == rh.unit)
            goto compare;

        // can't compare mismatch unit types... i think?
        static if (Dynamic || rh.Dynamic)
            assert(isCompatible(rh), "Incompatible units!");
        else
            static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", rh.unit.toString);

        // TODO: meeting in the middle is only better if the signs are opposite
        //       otherwise we should just scale to the left...
        static if (Dynamic && rh.Dynamic)
        {{
            // if the scale values are both dynamic, it should be more precise if we meet in the middle...
            auto lScale = unit.scale();
            auto lTrans = unit.offset();
            auto rScale = rh.unit.scale();
            auto rTrans = rh.unit.offset();
            lhs = lhs*lScale + lTrans;
            rhs = rhs*rScale + rTrans;
        }}
        else
            rhs = adjustScale(rh);

    compare:
        static if (epsilon == 0)
        {
            static if (eq)
                return lhs == rhs;
            else
                return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
        }
        else
        {
            double cmp = lhs - rhs;
            static if (eq)
                return cmp >= -epsilon && cmp <= epsilon;
            else
                return cmp < -epsilon ? -1 : cmp > epsilon ? 1 : 0;
        }
    }

    auto normalise() const pure
    {
        static if (Dynamic)
        {
            Quantity!T r;
            r.unit = ScaledUnit(unit.unit);
        }
        else
            Quantity!(T, ScaledUnit(unit.unit)) r;
        r.value = r.adjustScale(this);
        return r;
    }

    ptrdiff_t toString(char[] buffer) const
    {
        import urt.conv : formatFloat;

        double v = value;
        ScaledUnit u = unit;

        if (u.pack)
        {
            // round upward to the nearest ^3
            if (u.siScale)
            {
                int x = u.exp;
                if (u.unit.pack == 0)
                {
                    if (x == -3)
                    {
                        v *= 0.1;
                        u = ScaledUnit(Unit(), x + 1);
                    }
                    else if (x != -2)
                    {
                        v *= u.scale();
                        u = ScaledUnit();
                    }
                }
                else
                {
                    x = (x + 33) % 3;
                    if (x != 0)
                    {
                        u = ScaledUnit(u.unit, u.exp + (3 - x));
                        if (x == 1)
                            v *= 0.01;
                        else
                            v *= 0.1;
                    }
                }
            }
        }

        ptrdiff_t l = formatFloat(v, buffer);
        if (l < 0)
            return l;

        if (u.pack)
        {
            ptrdiff_t l2 = u.toString(buffer[l .. $]);
            if (l2 < 0)
                return l2;
            l += l2;
        }

        return l;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        return -1;
    }

private:
    T adjustScale(U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
    {
        static if (Dynamic)
        {
            auto lScale = unit.scale!true();
            auto lTrans = unit.offset!true();
        }
        else
        {
            enum lScale = unit.scale!true();
            enum lTrans = unit.offset!true();
        }
        static if (b.Dynamic)
        {
            auto rScale = b.unit.scale();
            auto rTrans = b.unit.offset();
        }
        else
        {
            enum rScale = b.unit.scale();
            enum rTrans = b.unit.offset();
        }

        static if (Dynamic || b.Dynamic)
        {
            auto scale = lScale*rScale;
            auto trans = lTrans + lScale*rTrans;
        }
        else
        {
            enum scale = lScale*rScale;
            enum trans = lTrans + lScale*rTrans;
        }
        return cast(T)(b.value*scale + trans);
    }
}


unittest
{
    alias Kilometres = Quantity!(double, Kilometre);
    alias Millimetres = Quantity!(double, Millimetre);
    alias Inches = Quantity!(double, Inch);
    alias Feet = Quantity!(double, Foot);
    alias SqMetres = Quantity!(double, ScaledUnit(Metre^^2));
    alias SqCentimetres = Quantity!(double, Centimetre^^2);
    alias SqInches = Quantity!(double, Inch^^2);
    alias MetresPerSecond = Quantity!(double, ScaledUnit(Metre/Second));
    alias DegreesK = Quantity!(double, ScaledUnit(Kelvin));
    alias DegreesC = Quantity!(double, Celsius);
    alias DegreesF = Quantity!(double, Fahrenheit);

    Scalar a = 1;
    Scalar b = 2;
    assert(a + b == 3);
    assert(a * b == 2);
    a *= 3;
    assert(a == 3);

    a = 10;
    assert(a == 10);

    Metres m = 10;
    assert(m == Metres(10));
    assert(m * b == Metres(20));
    Kilometres km = m;
    assert(km == Kilometres(0.01));
    km = m * 100;
    assert(km == Kilometres(1));
    Inches i = m;
    assert(i == Inches(393.7007874015748));
    i -= m;
    assert(i == Inches(0));
    SqMetres sqm = m * m;
    assert(sqm == SqMetres(100));
    sqm = Metres(1) * Kilometres(1);
    assert(sqm == SqMetres(1000));
    sqm = Kilometres(1) * Kilometres(1);
    assert(sqm == SqMetres(1000000));
    sqm = Metres(1) * Inches(1);
    assert(sqm == SqMetres(0.0254));
//    sqm = Kilometres(1) * Inches(1); // TODO: need a way to detect invalid unit product...
//    assert(sqm == SqMetres(25.4));

    Seconds s = 2;
    auto mps = m/s;
    static assert(is(typeof(mps) == MetresPerSecond));
    assert(mps == MetresPerSecond(5));

    m = mps * 2 * s;
    assert(m == Metres(20));

    VarQuantity v = mps;
    assert(v.unit == Metre/Second);
    v = m;
    assert(v.unit == Metre);
    assert(v * b == Metres(40));

    enum epsilon = 1e-12;

    DegreesF f = DegreesC(100);
    assert(f.opEquals!epsilon(DegreesF(212)));

    assert(Kilometres(2).opEquals!epsilon(Metres(2000)));
    assert(Metres(2).opEquals!epsilon(Kilometres(0.002)));
    assert(Kilometres(2).opEquals!epsilon(Millimetres(2000000)));

    assert(Inches(1).opEquals!epsilon(Metres(0.0254)));
    assert(Metres(1).opEquals!epsilon(Inches(1/0.0254)));
    assert(Millimetres(1).opEquals!epsilon(Inches(1/25.4)));
    assert(Inches(1).opEquals!epsilon(Millimetres(25.4)));
    assert(Feet(1).opEquals!epsilon(Inches(12)));
    assert(Inches(12).opEquals!epsilon(Feet(1)));
    assert(SqCentimetres(1).opEquals!epsilon(SqInches(0.15500031000062)));

    assert(DegreesC(100).opEquals!epsilon(DegreesK(373.15)));
    assert(DegreesK(200).opEquals!epsilon(DegreesC(-73.15)));
    assert(DegreesF(100).opEquals!epsilon(DegreesK(310.92777777777777)));
    assert(DegreesK(200).opEquals!epsilon(DegreesF(-99.67)));
    assert(DegreesC(100).opEquals!epsilon(DegreesF(212)));
    assert(DegreesF(100).opEquals!epsilon(DegreesC(37.77777777777777)));
}
