module urt.range;

public import urt.range.primitives;


template map(fun...)
    if (fun.length >= 1)
{
    /**
    Params:
        r = an $(REF_ALTTEXT input range, isInputRange, std,range,primitives)
    Returns:
        A range with each fun applied to all the elements. If there is more than one
        fun, the element type will be `Tuple` containing one element for each fun.
     */
    auto map(Range)(Range r)
        if (isInputRange!(Unqual!Range))
    {
        import urt.meta : AliasSeq, staticMap;

        alias RE = ElementType!(Range);
        static if (fun.length > 1)
        {
            import std.functional : adjoin;
            import urt.meta : staticIndexOf;

            alias _funs = staticMap!(unaryFun, fun);
            alias _fun = adjoin!_funs;

            // Once https://issues.dlang.org/show_bug.cgi?id=5710 is fixed
            // accross all compilers (as of 2020-04, it wasn't fixed in LDC and GDC),
            // this validation loop can be moved into a template.
            foreach (f; _funs)
            {
                static assert(!is(typeof(f(RE.init)) == void),
                    "Mapping function(s) must not return void: " ~ _funs.stringof);
            }
        }
        else
        {
            alias _fun = unaryFun!fun;
            alias _funs = AliasSeq!(_fun);

            // Do the validation separately for single parameters due to
            // https://issues.dlang.org/show_bug.cgi?id=15777.
            static assert(!is(typeof(_fun(RE.init)) == void),
                "Mapping function(s) must not return void: " ~ _funs.stringof);
        }

        return MapResult!(_fun, Range)(r);
    }
}

private struct MapResult(alias fun, Range)
{
    alias R = Unqual!Range;
    R _input;

    static if (isBidirectionalRange!R)
    {
        @property auto ref back()()
        {
            assert(!empty, "Attempting to fetch the back of an empty map.");
            return fun(_input.back);
        }

        void popBack()()
        {
            assert(!empty, "Attempting to popBack an empty map.");
            _input.popBack();
        }
    }

    this(R input)
    {
        _input = input;
    }

    static if (isInfinite!R)
    {
        // Propagate infinite-ness.
        enum bool empty = false;
    }
    else
    {
        @property bool empty()
        {
            return _input.empty;
        }
    }

    void popFront()
    {
        assert(!empty, "Attempting to popFront an empty map.");
        _input.popFront();
    }

    @property auto ref front()
    {
        assert(!empty, "Attempting to fetch the front of an empty map.");
        return fun(_input.front);
    }

    static if (isRandomAccessRange!R)
    {
        static if (is(typeof(Range.init[ulong.max])))
            private alias opIndex_t = ulong;
        else
            private alias opIndex_t = uint;

        auto ref opIndex(opIndex_t index)
        {
            return fun(_input[index]);
        }
    }

    mixin ImplementLength!_input;

    static if (hasSlicing!R)
    {
        static if (is(typeof(_input[ulong.max .. ulong.max])))
            private alias opSlice_t = ulong;
        else
            private alias opSlice_t = uint;

        static if (hasLength!R)
        {
            auto opSlice(opSlice_t low, opSlice_t high)
            {
                return typeof(this)(_input[low .. high]);
            }
        }
        else static if (is(typeof(_input[opSlice_t.max .. $])))
        {
            struct DollarToken{}
            enum opDollar = DollarToken.init;
            auto opSlice(opSlice_t low, DollarToken)
            {
                return typeof(this)(_input[low .. $]);
            }

            auto opSlice(opSlice_t low, opSlice_t high)
            {
                import std.range : takeExactly;
                return this[low .. $].takeExactly(high - low);
            }
        }
    }

    static if (isForwardRange!R)
    {
        @property auto save()
        {
            return typeof(this)(_input.save);
        }
    }
}


template reduce(fun...)
    if (fun.length >= 1)
{
    import urt.meta : staticMap;

    alias binfuns = staticMap!(binaryFun, fun);
    static if (fun.length > 1)
        import urt.meta.tuple : tuple, isTuple;

    /++
    No-seed version. The first element of `r` is used as the seed's value.

    For each function `f` in `fun`, the corresponding
    seed type `S` is `Unqual!(typeof(f(e, e)))`, where `e` is an
    element of `r`: `ElementType!R` for ranges,
    and `ForeachType!R` otherwise.

    Once S has been determined, then `S s = e;` and `s = f(s, e);`
    must both be legal.

    Params:
        r = an iterable value as defined by `isIterable`

    Returns:
        the final result of the accumulator applied to the iterable

    Throws: `Exception` if `r` is empty
    +/
    auto reduce(R)(R r)
        if (isIterable!R)
    {
        import std.exception : enforce;
        alias E = Select!(isInputRange!R, ElementType!R, ForeachType!R);
        alias Args = staticMap!(ReduceSeedType!E, binfuns);

        static if (isInputRange!R)
        {
            // no need to throw if range is statically known to be non-empty
            static if (!__traits(compiles,
            {
                static assert(r.length > 0);
            }))
                enforce(!r.empty, "Cannot reduce an empty input range w/o an explicit seed value.");

            Args result = r.front;
            r.popFront();
            return reduceImpl!false(r, result);
        }
        else
        {
            auto result = Args.init;
            return reduceImpl!true(r, result);
        }
    }

    /++
    Seed version. The seed should be a single value if `fun` is a
    single function. If `fun` is multiple functions, then `seed`
    should be a $(REF Tuple, std,typecons), with one field per function in `f`.

    For convenience, if the seed is const, or has qualified fields, then
    `reduce` will operate on an unqualified copy. If this happens
    then the returned type will not perfectly match `S`.

    Use `fold` instead of `reduce` to use the seed version in a UFCS chain.

    Params:
        seed = the initial value of the accumulator
        r = an iterable value as defined by `isIterable`

    Returns:
        the final result of the accumulator applied to the iterable
    +/
    auto reduce(S, R)(S seed, R r)
        if (isIterable!R)
    {
        static if (fun.length == 1)
            return reducePreImpl(r, seed);
        else
        {
            import std.algorithm.internal : algoFormat;
            static assert(isTuple!S, algoFormat("Seed %s should be a Tuple", S.stringof));
            return reducePreImpl(r, seed.expand);
        }
    }

    private auto reducePreImpl(R, Args...)(R r, ref Args args)
    {
        alias Result = staticMap!(Unqual, Args);
        static if (is(Result == Args))
            alias result = args;
        else
            Result result = args;
        return reduceImpl!false(r, result);
    }

    private auto reduceImpl(bool mustInitialize, R, Args...)(R r, ref Args args)
        if (isIterable!R)
    {
        import std.algorithm.internal : algoFormat;
        static assert(Args.length == fun.length,
            algoFormat("Seed %s does not have the correct amount of fields (should be %s)", Args.stringof, fun.length));
        alias E = Select!(isInputRange!R, ElementType!R, ForeachType!R);

        static if (mustInitialize)
            bool initialized = false;
        foreach (/+auto ref+/ E e; r) // https://issues.dlang.org/show_bug.cgi?id=4707
        {
            foreach (i, f; binfuns)
            {
                static assert(!is(typeof(f(args[i], e))) || is(typeof(args[i] = f(args[i], e))),
                    algoFormat(
                        "Incompatible function/seed/element: %s/%s/%s",
                        fullyQualifiedName!f,
                        Args[i].stringof,
                        E.stringof
                    )
                );
            }

            static if (mustInitialize) if (initialized == false)
            {
                import core.internal.lifetime : emplaceRef;
                foreach (i, f; binfuns)
                    emplaceRef!(Args[i])(args[i], e);
                initialized = true;
                continue;
            }

            foreach (i, f; binfuns)
                args[i] = f(args[i], e);
        }
        static if (mustInitialize)
        // no need to throw if range is statically known to be non-empty
        static if (!__traits(compiles, { static assert(r.length > 0); }))
        {
            if (!initialized)
                throw new Exception("Cannot reduce an empty iterable w/o an explicit seed value.");
        }

        static if (Args.length == 1)
            return args[0];
        else
            return tuple(args);
    }
}

template fold(fun...)
    if (fun.length >= 1)
{
    /**
    Params:
    r = the $(REF_ALTTEXT input range, isInputRange, std,range,primitives) to fold
    seeds = the initial values of each accumulator (optional), one for each predicate
    Returns:
    Either the accumulated result for a single predicate, or a
    $(REF_ALTTEXT `Tuple`,Tuple,std,typecons) of results.
    */
    auto fold(R, S...)(R r, S seeds)
    {
        static if (S.length < 2)
        {
            return reduce!fun(seeds, r);
        }
        else
        {
            import std.typecons : tuple;
            return reduce!fun(tuple(seeds), r);
        }
    }
}
