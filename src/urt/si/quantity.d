module urt.si.quantity;

import urt.si.unit;

nothrow @nogc:


alias VarQuantity = Quantity!(double);
alias Scalar = Quantity!(double, ScaledUnit());
alias Metres = Quantity!(double, ScaledUnit(Metre));
alias Seconds = Quantity!(double, ScaledUnit(Second));


struct Quantity(T, ScaledUnit _unit = ScaledUnit(uint.max))
{
nothrow @nogc:

    alias This = Quantity!(T, _unit);

    enum Dynamic = _unit.pack == uint.max;
    enum IsCompatible(ScaledUnit U) = _unit.unit == U.unit;

    T value;

    static if (Dynamic)
        ScaledUnit unit;
    else
        alias unit = _unit;

    bool isCompatible(U, ScaledUnit _U)(Quantity!(U, _U) compatibleWith) const pure
        if (is(U : T))
        => unit.unit == compatibleWith.unit.unit;

    this(T value) pure
    {
        static if (Dynamic)
            this.unit = ScaledUnit();
        this.value = value;
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
                assert(isCompatible(b), "Incompatible unit!");
            else
                static assert(IsCompatible!_U, "Incompatible unit: ", unit, " and ", b.unit);
            value = adjustScale(b);
        }
    }

    void opAssign()(T value) pure
    {
        static if (Dynamic)
            unit = Scalar;
        else
            static assert(unit == Unit(), "Incompatible unit: ", unit, " and Scalar");
        this.value = value;
    }

    void opAssign(U, ScaledUnit _U)(Quantity!(U, _U) b) pure
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
                assert(isCompatible(b), "Incompatible unit!");
            else
                static assert(IsCompatible!_U, "Incompatible unit: ", unit, " and ", b.unit);
            value = adjustScale(b);
        }
    }

    auto opBinary(string op, U)(U value) const pure
        if ((op == "+" || op == "-") && is(U : T))
    {
        static if (Dynamic)
            assert(unit == Scalar);
        else
            static assert(unit == Unit(), "Incompatible unit: ", unit, " and Scalar");
        return mixin("this.value " ~ op ~ " value");
    }

    auto opBinary(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
        if ((op == "+" || op == "-") && is(U : T))
    {
        static if (!Dynamic && !b.Dynamic && unit == Unit() && b.unit == Unit())
            return mixin("value " ~ op ~ " b.value");
        else
        {
            static if (Dynamic || b.Dynamic)
                assert(isCompatible(b), "Incompatible unit!");
            else
                static assert(IsCompatible!_U, "Incompatible unit: ", unit, " and ", b.unit);

            This r;
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
            This r;
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
            static if (Dynamic || b.Dynamic)
            {
                Quantity!T r;
                r.unit = mixin("unit " ~ op ~ " b.unit");
            }
            else
                Quantity!(T, mixin("unit " ~ op ~ " b.unit")) r;

            // TODO: if the unit product is invalid, then we apply the scaling factor...
            //       ... but which side should we scale to? probably the left I guess...

            r.value = mixin("value " ~ op ~ " b.value");
            return r;
        }
    }

    void opOpAssign(string op, U)(U value) pure
        if (is(U : T))
    {
        this = opBinary!op(value);
    }

    void opOpAssign(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) pure
    {
        this = opBinary!op(b);
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
            assert(isCompatible(rh), "Incompatible unit!");
        else
            static assert(IsCompatible!_U, "Incompatible unit: ", unit, " and ", rh.unit);

        // TODO: meeting in the middle is only better if the signs are opposite
        //       otherwise we should just scale to the left...
        static if (Dynamic && rh.Dynamic)
        {
            // if the scale values are both dynamic, it should be more precise if we meet in the middle...
            auto lScale = unit.scale();
            auto lTrans = unit.offset();
            auto rScale = rh.unit.scale();
            auto rTrans = rh.unit.offset();
            lhs = lhs*lScale + lTrans;
            rhs = rhs*rScale + rTrans;
        }
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
