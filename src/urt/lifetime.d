module urt.lifetime;


T* emplace(T)(T* chunk) @safe pure
{
    import core.internal.lifetime : emplaceRef;

    emplaceRef!T(*chunk);
    return chunk;
}

T* emplace(T, Args...)(T* chunk, auto ref Args args)
    if (is(T == struct) || Args.length == 1)
{
    import core.internal.lifetime : emplaceRef;

    emplaceRef!T(*chunk, forward!args);
    return chunk;
}

T emplace(T, Args...)(T chunk, auto ref Args args)
    if (is(T == class))
{
    import core.internal.traits : isInnerClass;

    static assert(!__traits(isAbstractClass, T), T.stringof ~
        " is abstract and it can't be emplaced");

    // Initialize the object in its pre-ctor state
    const initializer = __traits(initSymbol, T);
    (() @trusted { (cast(void*) chunk)[0 .. initializer.length] = initializer[]; })();

    static if (isInnerClass!T)
    {
        static assert(Args.length > 0,
            "Initializing an inner class requires a pointer to the outer class");
        static assert(is(Args[0] : typeof(T.outer)),
            "The first argument must be a pointer to the outer class");

        chunk.outer = args[0];
        alias args1 = args[1..$];
    }
    else alias args1 = args;

    // Call the ctor if any
    static if (is(typeof(chunk.__ctor(forward!args1))))
    {
        // T defines a genuine constructor accepting args
        // Go the classic route: write .init first, then call ctor
        chunk.__ctor(forward!args1);
    }
    else
    {
        static assert(args1.length == 0 && !is(typeof(&T.__ctor)),
            "Don't know how to initialize an object of type "
            ~ T.stringof ~ " with arguments " ~ typeof(args1).stringof);
    }
    return chunk;
}

T emplace(T, Args...)(void[] chunk, auto ref Args args)
    if (is(T == class))
{
    enum classSize = __traits(classInstanceSize, T);
    assert(chunk.length >= classSize, "chunk size too small.");

    enum alignment = __traits(classInstanceAlignment, T);
    assert((cast(size_t) chunk.ptr) % alignment == 0, "chunk is not aligned.");

    return emplace!T(cast(T)(chunk.ptr), forward!args);
}

T* emplace(T, Args...)(void[] chunk, auto ref Args args)
    if (!is(T == class))
{
    import core.internal.traits : Unqual;
    import core.internal.lifetime : emplaceRef;

    assert(chunk.length >= T.sizeof, "chunk size too small.");
    assert((cast(size_t) chunk.ptr) % T.alignof == 0, "emplace: Chunk is not aligned.");

    emplaceRef!(T, Unqual!T)(*cast(Unqual!T*) chunk.ptr, forward!args);
    return cast(T*) chunk.ptr;
}


/+
void copyEmplace(S, T)(ref S source, ref T target) @system
    if (is(immutable S == immutable T))
{
    import core.internal.traits : BaseElemOf, hasElaborateCopyConstructor, Unconst, Unqual;

    // cannot have the following as simple template constraint due to nested-struct special case...
    static if (!__traits(compiles, (ref S src) { T tgt = src; }))
    {
        alias B = BaseElemOf!T;
        enum isNestedStruct = is(B == struct) && __traits(isNested, B);
        static assert(isNestedStruct, "cannot copy-construct " ~ T.stringof ~ " from " ~ S.stringof);
    }

    void blit()
    {
        import core.stdc.string : memcpy;
        memcpy(cast(Unqual!(T)*) &target, cast(Unqual!(T)*) &source, T.sizeof);
    }

    static if (is(T == struct))
    {
        static if (__traits(hasPostblit, T))
        {
            blit();
            (cast() target).__xpostblit();
        }
        else static if (__traits(hasCopyConstructor, T))
        {
            // https://issues.dlang.org/show_bug.cgi?id=22766
            import core.internal.lifetime : emplaceInitializer;
            emplaceInitializer(*(cast(Unqual!T*)&target));
            static if (__traits(isNested, T))
            {
                 // copy context pointer
                *(cast(void**) &target.tupleof[$-1]) = cast(void*) source.tupleof[$-1];
            }
            target.__ctor(source); // invoke copy ctor
        }
        else
        {
            blit(); // no opAssign
        }
    }
    else static if (is(T == E[n], E, size_t n))
    {
        static if (hasElaborateCopyConstructor!E)
        {
            size_t i;
            try
            {
                for (i = 0; i < n; i++)
                    copyEmplace(source[i], target[i]);
            }
            catch (Exception e)
            {
                // destroy, in reverse order, what we've constructed so far
                while (i--)
                    destroy(*cast(Unconst!(E)*) &target[i]);
                throw e;
            }
        }
        else // trivial copy
        {
            blit(); // all elements at once
        }
    }
    else
    {
        *cast(Unconst!(T)*) &target = *cast(Unconst!(T)*) &source;
    }
}
+/


template forward(args...)
{
    import urt.meta : AliasSeq;

    template fwd(alias arg)
    {
        // by ref || lazy || const/immutable
        static if (__traits(isRef,  arg) ||
                   __traits(isOut,  arg) ||
                   __traits(isLazy, arg) ||
                   !is(typeof(move(arg))))
            alias fwd = arg;
        // (r)value
        else
            @property auto fwd()
            {
                version (DigitalMars) { /* @@BUG 23890@@ */ } else pragma(inline, true);
                return move(arg);
            }
    }

    alias Result = AliasSeq!();
    static foreach (arg; args)
        Result = AliasSeq!(Result, fwd!arg);
    static if (Result.length == 1)
        alias forward = Result[0];
    else
        alias forward = Result;
}


void move(T)(ref T source, ref T target) nothrow @nogc
{
    moveImpl(target, source);
}

T move(T)(return scope ref T source) nothrow @nogc
{
    return moveImpl(source);
}


private void moveImpl(T)(scope ref T target, return scope ref T source) nothrow @nogc
{
    import core.internal.traits : hasElaborateDestructor;

    static if (is(T == struct))
    {
        //  Unsafe when compiling without -preview=dip1000
        if ((() @trusted => &source == &target)()) return;
        // Destroy target before overwriting it
        static if (hasElaborateDestructor!T) target.__xdtor();
    }
    // move and emplace source into target
    moveEmplaceImpl(target, source);
}

private T moveImpl(T)(return scope ref T source) nothrow @nogc
{
    // Properly infer safety from moveEmplaceImpl as the implementation below
    // might void-initialize pointers in result and hence needs to be @trusted
    if (false) moveEmplaceImpl(source, source);

    return trustedMoveImpl(source);
}

private T trustedMoveImpl(T)(return scope ref T source) @trusted nothrow @nogc
{
    T result = void;
    moveEmplaceImpl(result, source);
    return result;
}




private enum bool hasContextPointers(T) = {
    static if (__traits(isStaticArray, T))
    {
        return hasContextPointers!(typeof(T.init[0]));
    }
    else static if (is(T == struct))
    {
        import core.internal.traits : anySatisfy;
        return __traits(isNested, T) || anySatisfy!(hasContextPointers, typeof(T.tupleof));
    }
    else return false;
} ();


private void moveEmplaceImpl(T)(scope ref T target, return scope ref T source) @nogc
{
    // TODO: this assert pulls in half of phobos. we need to work out an alternative assert strategy.
//    static if (!is(T == class) && hasAliasing!T) if (!__ctfe)
//    {
//        import std.exception : doesPointTo;
//        assert(!doesPointTo(source, source) && !hasElaborateMove!T),
//              "Cannot move object with internal pointer unless `opPostMove` is defined.");
//    }

    import core.internal.traits : hasElaborateAssign, isAssignable, hasElaborateMove,
                                  hasElaborateDestructor, hasElaborateCopyConstructor;
    static if (is(T == struct))
    {

        //  Unsafe when compiling without -preview=dip1000
        assert((() @trusted => &source !is &target)(), "source and target must not be identical");

        static if (hasElaborateAssign!T || !isAssignable!T)
        {
            import core.stdc.string : memcpy;
            () @trusted { memcpy(&target, &source, T.sizeof); }();
        }
        else
            target = source;

        static if (hasElaborateMove!T)
            __move_post_blt(target, source);

        // If the source defines a destructor or a postblit hook, we must obliterate the
        // object in order to avoid double freeing and undue aliasing
        static if (hasElaborateDestructor!T || hasElaborateCopyConstructor!T)
        {
            // If there are members that are nested structs, we must take care
            // not to erase any context pointers, so we might have to recurse
            static if (__traits(isZeroInit, T))
                wipe(source);
            else
                wipe(source, ref () @trusted { return *cast(immutable(T)*) __traits(initSymbol, T).ptr; } ());
        }
    }
    else static if (__traits(isStaticArray, T))
    {
        static if (T.length)
        {
            static if (!hasElaborateMove!T &&
                       !hasElaborateDestructor!T &&
                       !hasElaborateCopyConstructor!T)
            {
                // Single blit if no special per-instance handling is required
                () @trusted
                {
                    assert(source.ptr !is target.ptr, "source and target must not be identical");
                    *cast(ubyte[T.sizeof]*) &target = *cast(ubyte[T.sizeof]*) &source;
                } ();
            }
            else
            {
                for (size_t i = 0; i < source.length; ++i)
                    moveEmplaceImpl(target[i], source[i]);
            }
        }
    }
    else
    {
        // Primitive data (including pointers and arrays) or class -
        // assignment works great
        target = source;
    }
}

void moveEmplace(T)(ref T source, ref T target) @system @nogc
{
    moveEmplaceImpl(target, source);
}



//debug = PRINTF;

debug(PRINTF)
{
    import core.stdc.stdio;
}

/// Implementation of `_d_delstruct` and `_d_delstructTrace`
template _d_delstructImpl(T)
{
    private void _d_delstructImpure(ref T p)
    {
        debug(PRINTF) printf("_d_delstruct(%p)\n", p);

        destroy(*p);
        p = null;
    }

    /**
     * This is called for a delete statement where the value being deleted is a
     * pointer to a struct with a destructor but doesn't have an overloaded
     * `delete` operator.
     *
     * Params:
     *   p = pointer to the value to be deleted
     *
     * Bugs:
     *   This function template was ported from a much older runtime hook that
     *   bypassed safety, purity, and throwabilty checks. To prevent breaking
     *   existing code, this function template is temporarily declared
     *   `@trusted` until the implementation can be brought up to modern D
     *   expectations.
     */
    void _d_delstruct(ref T p) @trusted @nogc pure nothrow
    {
        if (p)
        {
            alias Type = void function(ref T P) @nogc pure nothrow;
            (cast(Type) &_d_delstructImpure)(p);
        }
    }

    version (D_ProfileGC)
    {
        import core.internal.array.utils : _d_HookTraceImpl;

        private enum errorMessage = "Cannot delete struct if compiling without support for runtime type information!";

        /**
         * TraceGC wrapper around $(REF _d_delstruct, core,lifetime,_d_delstructImpl).
         *
         * Bugs:
         *   This function template was ported from a much older runtime hook that
         *   bypassed safety, purity, and throwabilty checks. To prevent breaking
         *   existing code, this function template is temporarily declared
         *   `@trusted` until the implementation can be brought up to modern D
         *   expectations.
         */
        alias _d_delstructTrace = _d_HookTraceImpl!(T, _d_delstruct, errorMessage);
    }
}


// wipes source after moving
pragma(inline, true)
private void wipe(T, Init...)(return scope ref T source, ref const scope Init initializer) @trusted nothrow @nogc
if (!Init.length ||
    ((Init.length == 1) && (is(immutable T == immutable Init[0]))))
{
    static if (__traits(isStaticArray, T) && hasContextPointers!T)
    {
        for (auto i = 0; i < T.length; i++)
            static if (Init.length)
                wipe(source[i], initializer[0][i]);
            else
                wipe(source[i]);
    }
    else static if (is(T == struct) && hasContextPointers!T)
    {
        import core.internal.traits : anySatisfy;
        static if (anySatisfy!(hasContextPointers, typeof(T.tupleof)))
        {
            static foreach (i; 0 .. T.tupleof.length - __traits(isNested, T))
                static if (Init.length)
                    wipe(source.tupleof[i], initializer[0].tupleof[i]);
                else
                    wipe(source.tupleof[i]);
        }
        else
        {
            static if (__traits(isNested, T))
                enum sz = T.tupleof[$-1].offsetof;
            else
                enum sz = T.sizeof;

            static if (Init.length)
                *cast(ubyte[sz]*) &source = *cast(ubyte[sz]*) &initializer[0];
            else
                *cast(ubyte[sz]*) &source = 0;
        }
    }
    else
    {
        import core.internal.traits : hasElaborateAssign, isAssignable;
        static if (Init.length)
        {
            static if (hasElaborateAssign!T || !isAssignable!T)
                *cast(ubyte[T.sizeof]*) &source = *cast(ubyte[T.sizeof]*) &initializer[0];
            else
                source = *cast(T*) &initializer[0];
        }
        else
        {
            *cast(ubyte[T.sizeof]*) &source = 0;
        }
    }
}

/+
T _d_newclassT(T)() @trusted
    if (is(T == class))
{
    import core.internal.traits : hasIndirections;
    import core.exception : onOutOfMemoryError;
    import core.memory : pureMalloc;
    import core.memory : GC;

    alias BlkAttr = GC.BlkAttr;

    auto init = __traits(initSymbol, T);
    void* p;

    static if (__traits(getLinkage, T) == "Windows")
    {
        p = pureMalloc(init.length);
        if (!p)
            onOutOfMemoryError();
    }
    else
    {
        BlkAttr attr = BlkAttr.NONE;

        /* `extern(C++)`` classes don't have a classinfo pointer in their vtable,
         * so the GC can't finalize them.
         */
        static if (__traits(hasMember, T, "__dtor") && __traits(getLinkage, T) != "C++")
            attr |= BlkAttr.FINALIZE;
        static if (!hasIndirections!T)
            attr |= BlkAttr.NO_SCAN;

        p = GC.malloc(init.length, attr, typeid(T));
        debug(PRINTF) printf(" p = %p\n", p);
    }

    debug(PRINTF)
    {
        printf("p = %p\n", p);
        printf("init.ptr = %p, len = %llu\n", init.ptr, cast(ulong)init.length);
        printf("vptr = %p\n", *cast(void**) init);
        printf("vtbl[0] = %p\n", (*cast(void***) init)[0]);
        printf("vtbl[1] = %p\n", (*cast(void***) init)[1]);
        printf("init[0] = %x\n", (cast(uint*) init)[0]);
        printf("init[1] = %x\n", (cast(uint*) init)[1]);
        printf("init[2] = %x\n", (cast(uint*) init)[2]);
        printf("init[3] = %x\n", (cast(uint*) init)[3]);
        printf("init[4] = %x\n", (cast(uint*) init)[4]);
    }

    // initialize it
    p[0 .. init.length] = init[];

    debug(PRINTF) printf("initialization done\n");
    return cast(T) p;
}

/**
 * TraceGC wrapper around $(REF _d_newclassT, core,lifetime).
 */
T _d_newclassTTrace(T)(string file, int line, string funcname) @trusted
{
    version (D_TypeInfo)
    {
        import core.internal.array.utils : TraceHook, gcStatsPure, accumulatePure;
        mixin(TraceHook!(T.stringof, "_d_newclassT"));

        return _d_newclassT!T();
    }
    else
        assert(0, "Cannot create new class if compiling without support for runtime type information!");
}

/**
 * Allocate an initialized non-array item.
 *
 * This is an optimization to avoid things needed for arrays like the __arrayPad(size).
 * Used to allocate struct instances on the heap.
 *
 * ---
 * struct Sz {int x = 0;}
 * struct Si {int x = 3;}
 *
 * void main()
 * {
 *     new Sz(); // uses zero-initialization
 *     new Si(); // uses Si.init
 * }
 * ---
 *
 * Returns:
 *     newly allocated item
 */
T* _d_newitemT(T)() @trusted
{
    import core.internal.lifetime : emplaceInitializer;
    import core.internal.traits : hasIndirections;
    import core.memory : GC;

    auto flags = !hasIndirections!T ? GC.BlkAttr.NO_SCAN : GC.BlkAttr.NONE;
    immutable tiSize = TypeInfoSize!T;
    immutable itemSize = T.sizeof;
    immutable totalSize = itemSize + tiSize;
    if (tiSize)
        flags |= GC.BlkAttr.STRUCTFINAL | GC.BlkAttr.FINALIZE;

    auto blkInfo = GC.qalloc(totalSize, flags, null);
    auto p = blkInfo.base;

    if (tiSize)
    {
        // The GC might not have cleared the padding area in the block.
        *cast(TypeInfo*) (p + (itemSize & ~(size_t.sizeof - 1))) = null;
        *cast(TypeInfo*) (p + blkInfo.size - tiSize) = cast() typeid(T);
    }

    emplaceInitializer(*(cast(T*) p));

    return cast(T*) p;
}

version (D_ProfileGC)
{
    /**
    * TraceGC wrapper around $(REF _d_newitemT, core,lifetime).
    */
    T* _d_newitemTTrace(T)(string file, int line, string funcname) @trusted
    {
        version (D_TypeInfo)
        {
            import core.internal.array.utils : TraceHook, gcStatsPure, accumulatePure;
            mixin(TraceHook!(T.stringof, "_d_newitemT"));

            return _d_newitemT!T();
        }
        else
            assert(0, "Cannot create new `struct` if compiling without support for runtime type information!");
    }
}

template TypeInfoSize(T)
{
    import core.internal.traits : hasElaborateDestructor;
    enum TypeInfoSize = hasElaborateDestructor!T ? size_t.sizeof : 0;
}
+/
