module urt.meta.tuple;

import urt.meta;


enum isTuple(T) = __traits(compiles, { void f(Specs...)(Tuple!Specs tup) {} f(T.init); } );


template tuple(Names...)
{
    auto tuple(Args...)(Args args) nothrow @nogc
    {
        static if (Names.length == 0)
            return Tuple!Args(args);
        else static if (!is(typeof(Names[0]) : string))
            return Tuple!Names(args);
        else
        {
            static assert(Names.length == Args.length,
                          "Insufficient number of names given.");

            template Interleave(A...)
            {
                template and(B...) if (B.length == 1)
                {
                    alias and = AliasSeq!(A[0], B[0]);
                }

                template and(B...) if (B.length != 1)
                {
                    alias and = AliasSeq!(A[0], B[0], Interleave!(A[1..$]).and!(B[1..$]));
                }
            }
            return Tuple!(Interleave!(Args).and!(Names))(args);
        }
    }
}


template Tuple(Specs...)
    if (distinctFieldNames!(Specs))
{
    alias fieldSpecs = parseSpecs!Specs;

    // Generates named fields as follows:
    //    alias name_0 = Identity!(field[0]);
    //    alias name_1 = Identity!(field[1]);
    //      :
    // NOTE: field[k] is an expression (which yields a symbol of a
    //       variable) and can't be aliased directly.
    enum injectNamedFields = () {
            string decl = "";
            static foreach (i, val; fieldSpecs)
            {{
                immutable si = i.stringof;
                decl ~= "alias _" ~ si ~ " = Identity!(field[" ~ si ~ "]);";
                if (val.name.length != 0)
                {
                    decl ~= "alias " ~ val.name ~ " = _" ~ si ~ ";";
                }
            }}
            return decl;
        };

    // Returns Specs for a subtuple this[from .. to] preserving field
    // names if any.
    alias sliceSpecs(size_t from, size_t to) = staticMap!(expandSpec, fieldSpecs[from .. to]);

    struct Tuple
    {
    nothrow @nogc:

        alias Types = staticMap!(extractType, fieldSpecs);

        private alias _Fields = Specs;

        /**
        * The names of the `Tuple`'s components. Unnamed fields have empty names.
        */
        alias fieldNames = staticMap!(extractName, fieldSpecs);

        /**
        * Use `t.expand` for a `Tuple` `t` to expand it into its
        * components. The result of `expand` acts as if the `Tuple`'s components
        * were listed as a list of values. (Ordinarily, a `Tuple` acts as a
        * single value.)
        */
        Types expand;
        mixin(injectNamedFields());

        static if (is(Specs))
        {
            // This is mostly to make t[n] work.
            alias expand this;
        }
        else
        {
            @property
                ref inout(Tuple!Types) _Tuple_super() inout @trusted
                {
                    static foreach (i; 0 .. Types.length)   // Rely on the field layout
                    {
                        static assert(typeof(return).init.tupleof[i].offsetof ==
                                      expand[i].offsetof);
                    }
                    return *cast(typeof(return)*) &(field[0]);
                }
            // This is mostly to make t[n] work.
            alias _Tuple_super this;
        }

        // backwards compatibility
        alias field = expand;

        /**
        * Constructor taking one value for each field.
        *
        * Params:
        *     values = A list of values that are either the same
        *              types as those given by the `Types` field
        *              of this `Tuple`, or can implicitly convert
        *              to those types. They must be in the same
        *              order as they appear in `Types`.
        */
        static if (Types.length > 0)
        {
            this(Types values)
            {
                field[] = values[];
            }
        }

        /**
        * Constructor taking a compatible array.
        *
        * Params:
        *     values = A compatible static array to build the `Tuple` from.
        *              Array slices are not supported.
        */
        this(U, size_t n)(U[n] values)
            if (n == Types.length && allSatisfy!(isBuildableFrom!U, Types))
        {
            static foreach (i; 0 .. Types.length)
            {
                field[i] = values[i];
            }
        }

        /**
        * Constructor taking a compatible `Tuple`. Two `Tuple`s are compatible
        * $(B iff) they are both of the same length, and, for each type `T` on the
        * left-hand side, the corresponding type `U` on the right-hand side can
        * implicitly convert to `T`.
        *
        * Params:
        *     another = A compatible `Tuple` to build from. Its type must be
        *               compatible with the target `Tuple`'s type.
        */
        this(U)(U another)
            if (areBuildCompatibleTuples!(typeof(this), U) && (noMemberHasCopyCtor!(typeof(this)) || !is(Unqual!U == Unqual!(typeof(this)))))
        {
            field[] = another.field[];
        }

        /**
        * Comparison for equality. Two `Tuple`s are considered equal
        * $(B iff) they fulfill the following criteria:
        *
        * $(UL
        *   $(LI Each `Tuple` is the same length.)
        *   $(LI For each type `T` on the left-hand side and each type
        *        `U` on the right-hand side, values of type `T` can be
        *        compared with values of type `U`.)
        *   $(LI For each value `v1` on the left-hand side and each value
        *        `v2` on the right-hand side, the expression `v1 == v2` is
        *        true.))
        *
        * Params:
        *     rhs = The `Tuple` to compare against. It must meeting the criteria
        *           for comparison between `Tuple`s.
        *
        * Returns:
        *     true if both `Tuple`s are equal, otherwise false.
        */
        bool opEquals(R)(R rhs)
            if (areCompatibleTuples!(typeof(this), R, "=="))
        {
            return field[] == rhs.field[];
        }

        /// ditto
        bool opEquals(R)(R rhs) const
            if (areCompatibleTuples!(typeof(this), R, "=="))
        {
            return field[] == rhs.field[];
        }

        /// ditto
        bool opEquals(R...)(auto ref R rhs)
            if (R.length > 1 && areCompatibleTuples!(typeof(this), Tuple!R, "=="))
        {
            static foreach (i; 0 .. Types.length)
                if (field[i] != rhs[i])
                    return false;

            return true;
        }

        /**
        * Comparison for ordering.
        *
        * Params:
        *     rhs = The `Tuple` to compare against. It must meet the criteria
        *           for comparison between `Tuple`s.
        *
        * Returns:
        * For any values `v1` contained by the left-hand side tuple and any
        * values `v2` contained by the right-hand side:
        *
        * 0 if `v1 == v2` for all members or the following value for the
        * first position were the mentioned criteria is not satisfied:
        *
        * $(UL
        *   $(LI NaN, in case one of the operands is a NaN.)
        *   $(LI A negative number if the expression `v1 < v2` is true.)
        *   $(LI A positive number if the expression `v1 > v2` is true.))
        */
        auto opCmp(R)(R rhs)
            if (areCompatibleTuples!(typeof(this), R, "<"))
        {
            static foreach (i; 0 .. Types.length)
            {
                if (field[i] != rhs.field[i])
                {
                    return field[i] < rhs.field[i] ? -1 : 1;
                }
            }
            return 0;
        }

        /// ditto
        auto opCmp(R)(R rhs) const
            if (areCompatibleTuples!(typeof(this), R, "<"))
        {
            static foreach (i; 0 .. Types.length)
            {
                if (field[i] != rhs.field[i])
                {
                    return field[i] < rhs.field[i] ? -1 : 1;
                }
            }
            return 0;
        }

        /**
        Concatenate Tuples.
        Tuple concatenation is only allowed if all named fields are distinct (no named field of this tuple occurs in `t`
        and no named field of `t` occurs in this tuple).

        Params:
        t = The `Tuple` to concatenate with

        Returns: A concatenation of this tuple and `t`
        */
        auto opBinary(string op, T)(auto ref T t)
            if (op == "~" && !(is(T : U[], U) && isTuple!U))
        {
            static if (isTuple!T)
            {
                static assert(distinctFieldNames!(_Fields, T._Fields),
                                "Cannot concatenate tuples with duplicate fields: " ~ fieldNames.stringof ~
                                " - " ~ T.fieldNames.stringof);
                return Tuple!(_Fields, T._Fields)(expand, t.expand);
            }
            else
            {
                return Tuple!(_Fields, T)(expand, t);
            }
        }

        /// ditto
        auto opBinaryRight(string op, T)(auto ref T t)
            if (op == "~" && !(is(T : U[], U) && isTuple!U))
        {
            static if (isTuple!T)
            {
                static assert(distinctFieldNames!(_Fields, T._Fields),
                                "Cannot concatenate tuples with duplicate fields: " ~ T.stringof ~
                                " - " ~ fieldNames.fieldNames.stringof);
                return Tuple!(T._Fields, _Fields)(t.expand, expand);
            }
            else
            {
                return Tuple!(T, _Fields)(t, expand);
            }
        }

        /**
        * Assignment from another `Tuple`.
        *
        * Params:
        *     rhs = The source `Tuple` to assign from. Each element of the
        *           source `Tuple` must be implicitly assignable to each
        *           respective element of the target `Tuple`.
        */
        ref Tuple opAssign(R)(auto ref R rhs)
            if (areCompatibleTuples!(typeof(this), R, "="))
        {
            static if (is(R == Tuple!Types) && !__traits(isRef, rhs) && isTuple!R)
            {
                if (__ctfe)
                {
                    // Cannot use swap at compile time
                    field[] = rhs.field[];
                }
                else
                {
                    import urt.util : swap;

                    // Use swap-and-destroy to optimize rvalue assignment
                    swap!(Tuple!Types)(this, rhs);
                }
            }
            else
            {
                // Do not swap; opAssign should be called on the fields.
                field[] = rhs.field[];
            }
            return this;
        }
/+
        /**
        * Renames the elements of a $(LREF Tuple).
        *
        * `rename` uses the passed `names` and returns a new
        * $(LREF Tuple) using these names, with the content
        * unchanged.
        * If fewer names are passed than there are members
        * of the $(LREF Tuple) then those trailing members are unchanged.
        * An empty string will remove the name for that member.
        * It is an compile-time error to pass more names than
        * there are members of the $(LREF Tuple).
        */
        ref rename(names...)() inout return
            if (names.length == 0 || allSatisfy!(isSomeString, typeof(names)))
        {
            import std.algorithm.comparison : equal;
            // to circumvent https://issues.dlang.org/show_bug.cgi?id=16418
            static if (names.length == 0 || equal([names], [fieldNames]))
                return this;
            else
            {
                enum nT = Types.length;
                enum nN = names.length;
                static assert(nN <= nT, "Cannot have more names than tuple members");
                alias allNames = AliasSeq!(names, fieldNames[nN .. $]);

                import std.meta : Alias, aliasSeqOf;

                template GetItem(size_t idx)
                {
                    import std.array : empty;
                    static if (idx < nT)
                        alias GetItem = Alias!(Types[idx]);
                    else static if (allNames[idx - nT].empty)
                        alias GetItem = AliasSeq!();
                    else
                        alias GetItem = Alias!(allNames[idx - nT]);
                }

                import std.range : roundRobin, iota;
                alias NewTupleT = Tuple!(staticMap!(GetItem, aliasSeqOf!(
                                                                            roundRobin(iota(nT), iota(nT, 2*nT)))));
                return *(() @trusted => cast(NewTupleT*)&this)();
            }
        }

        /**
        * Overload of $(LREF _rename) that takes an associative array
        * `translate` as a template parameter, where the keys are
        * either the names or indices of the members to be changed
        * and the new names are the corresponding values.
        * Every key in `translate` must be the name of a member of the
        * $(LREF tuple).
        * The same rules for empty strings apply as for the variadic
        * template overload of $(LREF _rename).
        */
        ref rename(alias translate)() inout
            if (is(typeof(translate) : V[K], V, K) && isSomeString!V && (isSomeString!K || is(K : size_t)))
        {
            import std.meta : aliasSeqOf;
            import std.range : ElementType;
            static if (isSomeString!(ElementType!(typeof(translate.keys))))
            {
                {
                    import std.conv : to;
                    import std.algorithm.iteration : filter;
                    import std.algorithm.searching : canFind;
                    enum notFound = translate.keys
                        .filter!(k => fieldNames.canFind(k) == -1);
                    static assert(notFound.empty, "Cannot find members "
                                    ~ notFound.to!string ~ " in type "
                                    ~ typeof(this).stringof);
                }
                return this.rename!(aliasSeqOf!(
                                                {
                                                    import std.array : empty;
                                                    auto names = [fieldNames];
                                                    foreach (ref n; names)
                                                        if (!n.empty)
                                                            if (auto p = n in translate)
                                                                n = *p;
                                                    return names;
                                                }()));
            }
            else
            {
                {
                    import std.algorithm.iteration : filter;
                    import std.conv : to;
                    enum invalid = translate.keys.
                        filter!(k => k < 0 || k >= this.length);
                    static assert(invalid.empty, "Indices " ~ invalid.to!string
                                    ~ " are out of bounds for tuple with length "
                                    ~ this.length.to!string);
                }
                return this.rename!(aliasSeqOf!(
                                                {
                                                    auto names = [fieldNames];
                                                    foreach (k, v; translate)
                                                        names[k] = v;
                                                    return names;
                                                }()));
            }
        }

        @property ref inout(Tuple!(sliceSpecs!(from, to))) slice(size_t from, size_t to)() inout @trusted
            if (from <= to && to <= Types.length)
        {
            static assert(
                            (typeof(this).alignof % typeof(return).alignof == 0) &&
                            (expand[from].offsetof % typeof(return).alignof == 0),
                            "Slicing by reference is impossible because of an alignment mistmatch" ~
                            " (See https://issues.dlang.org/show_bug.cgi?id=15645).");

            return *cast(typeof(return)*) &(field[from]);
        }
+/
        size_t toHash() const nothrow @safe
        {
            size_t h = 0;
            static foreach (i, T; Types)
            {{
                static if (__traits(compiles, h = .hashOf(field[i])))
                    const k = .hashOf(field[i]);
                else
                {
                    // Workaround for when .hashOf is not both @safe and nothrow.
                    static if (is(T : shared U, U) && __traits(compiles, (U* a) nothrow @safe => .hashOf(*a))
                               && !__traits(hasMember, T, "toHash"))
                        // BUG: Improperly casts away `shared`!
                        const k = .hashOf(*(() @trusted => cast(U*) &field[i])());
                    else
                    {
                        assert(false, "TODO: @NOGC PROBLEM!");
                      // BUG: Improperly casts away `shared`!
//                      const k = typeid(T).getHash((() @trusted => cast(const void*) &field[i])());
                      const k = 0;
                    }
                }
                static if (i == 0)
                    h = k;
                else
                    // As in boost::hash_combine
                    // https://www.boost.org/doc/libs/1_55_0/doc/html/hash/reference.html#boost.hash_combine
                    h ^= k + 0x9e3779b9 + (h << 6) + (h >>> 2);
            }}
            return h;
        }
/+
        /**
        * Converts to string.
        *
        * Returns:
        *     The string representation of this `Tuple`.
        */
        string toString()() const
        {
            import std.array : appender;
            auto app = appender!string();
            this.toString((const(char)[] chunk) => app ~= chunk);
            return app.data;
        }

        import std.format.spec : FormatSpec;

        /**
        * Formats `Tuple` with either `%s`, `%(inner%)` or `%(inner%|sep%)`.
        *
        * $(TABLE2 Formats supported by Tuple,
        * $(THEAD Format, Description)
        * $(TROW $(P `%s`), $(P Format like `Tuple!(types)(elements formatted with %s each)`.))
        * $(TROW $(P `%(inner%)`), $(P The format `inner` is applied the expanded `Tuple`$(COMMA) so
        *      it may contain as many formats as the `Tuple` has fields.))
        * $(TROW $(P `%(inner%|sep%)`), $(P The format `inner` is one format$(COMMA) that is applied
        *      on all fields of the `Tuple`. The inner format must be compatible to all
        *      of them.)))
        *
        * Params:
        *     sink = A `char` accepting delegate
        *     fmt = A $(REF FormatSpec, std,format)
        */
        void toString(DG)(scope DG sink) const
        {
            auto f = FormatSpec!char();
            toString(sink, f);
        }

        /// ditto
        void toString(DG, Char)(scope DG sink, scope const ref FormatSpec!Char fmt) const
        {
            import std.format : format, FormatException;
            import std.format.write : formattedWrite;
            import std.range : only;
            if (fmt.nested)
            {
                if (fmt.sep)
                {
                    foreach (i, Type; Types)
                    {
                        static if (i > 0)
                        {
                            sink(fmt.sep);
                        }
                        // TODO: Change this once formattedWrite() works for shared objects.
                        static if (is(Type == class) && is(Type == shared))
                        {
                            sink(Type.stringof);
                        }
                        else
                        {
                            formattedWrite(sink, fmt.nested, this.field[i]);
                        }
                    }
                }
                else
                {
                    formattedWrite(sink, fmt.nested, staticMap!(sharedToString, this.expand));
                }
            }
            else if (fmt.spec == 's')
            {
                enum header = Unqual!(typeof(this)).stringof ~ "(",
                    footer = ")",
                    separator = ", ";
                sink(header);
                foreach (i, Type; Types)
                {
                    static if (i > 0)
                    {
                        sink(separator);
                    }
                    // TODO: Change this once format() works for shared objects.
                    static if (is(Type == class) && is(Type == shared))
                    {
                        sink(Type.stringof);
                    }
                    else
                    {
                        sink(format!("%(%s%)")(only(field[i])));
                    }
                }
                sink(footer);
            }
            else
            {
                const spec = fmt.spec;
                throw new FormatException(
                                          "Expected '%s' or '%(...%)' or '%(...%|...%)' format specifier for type '" ~
                                          Unqual!(typeof(this)).stringof ~ "', not '%" ~ spec ~ "'.");
            }
        }
+/
    }
}


private:

enum bool distinctFieldNames(names...) = __traits(compiles,
{
    static foreach (__name; names)
        static if (is(typeof(__name) : string))
            mixin("enum int " ~ __name ~ " = 0;");
});

enum areCompatibleTuples(Tup1, Tup2, string op) =
    isTuple!(OriginalType!Tup2) && Tup1.Types.length == Tup2.Types.length && is(typeof(
    (ref Tup1 tup1, ref Tup2 tup2)
    {
        static foreach (i; 0 .. Tup1.Types.length)
        {{
            auto lhs = typeof(tup1.field[i]).init;
            auto rhs = typeof(tup2.field[i]).init;
            static if (op == "=")
                lhs = rhs;
            else
                auto result = mixin("lhs "~op~" rhs");
        }}
    }));

template parseSpecs(Specs...)
{
    static if (Specs.length == 0)
    {
        alias parseSpecs = AliasSeq!();
    }
    else static if (is(Specs[0]))
    {
        static if (is(typeof(Specs[1]) : string))
        {
            alias parseSpecs =
                AliasSeq!(FieldSpec!(Specs[0 .. 2]),
                          parseSpecs!(Specs[2 .. $]));
        }
        else
        {
            alias parseSpecs =
                AliasSeq!(FieldSpec!(Specs[0]),
                          parseSpecs!(Specs[1 .. $]));
        }
    }
    else
    {
        static assert(0, "Attempted to instantiate Tuple with an "
                        ~"invalid argument: "~ Specs[0].stringof);
    }
}

template FieldSpec(T, string s = "")
{
    alias Type = T;
    alias name = s;
}

alias extractType(alias spec) = spec.Type;
alias extractName(alias spec) = spec.name;

alias Identity(alias A) = A;

enum areBuildCompatibleTuples(Tup1, Tup2) = isTuple!Tup2 && is(typeof({
                                                                        static assert(Tup1.Types.length == Tup2.Types.length);
                                                                        static foreach (i; 0 .. Tup1.Types.length)
                                                                            static assert(isBuildable!(Tup1.Types[i], Tup2.Types[i]));
                                                                      }));
enum isBuildable(T, U) = is(typeof({ U u = U.init; T t = u; }));

private template OriginalType(T)
{
    static if (is(T EType == enum))
        alias OriginalType = .OriginalType!EType;
    else
        alias OriginalType = T;
}
