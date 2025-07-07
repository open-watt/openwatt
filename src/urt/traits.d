module urt.traits;

import urt.meta;


enum bool isType(alias X) = is(X);

enum bool isBoolean(T) = __traits(isUnsigned, T) && is(T : bool);

enum bool isUnsignedInt(T) = is(Unqual!T == ubyte) || is(Unqual!T == ushort) || is(Unqual!T == uint) || is(Unqual!T == ulong);
enum bool isSignedInt(T) = is(Unqual!T == byte) || is(Unqual!T == short) || is(Unqual!T == int) || is(Unqual!T == long);
enum bool isSomeInt(T) = isUnsignedInt!T || isSignedInt!T;
enum bool isUnsignedIntegral(T) = is(Unqual!T == bool) || isUnsignedInt!T || isSomeChar!T;
enum bool isSignedIntegral(T) = isSignedInt!T;
enum bool isIntegral(T) = isUnsignedIntegral!T || isSignedIntegral!T;
enum bool isSomeFloat(T) = is(Unqual!T == float) || is(Unqual!T == double) || is(Unqual!T == real);

enum bool isEnum(T) = is(T == enum);
template enumType(T)
    if (isEnum!T)
{
    static if (is(T E == enum))
        alias enumType = E;
    else
        static assert(false, "How this?");
}

template isUnsigned(T)
{
    static if (!__traits(isUnsigned, T))
        enum isUnsigned = false;
    else static if (is(T U == enum))
        enum isUnsigned = isUnsigned!U;
    else
        enum isUnsigned = __traits(isZeroInit, T) // Not char, wchar, or dchar.
            && !is(immutable T == immutable bool) && !is(T == __vector);
}

enum bool isSigned(T) = __traits(isArithmetic, T) && !__traits(isUnsigned, T) && is(T : real);

template isSomeChar(T)
{
    static if (!__traits(isUnsigned, T))
        enum isSomeChar = false;
    else static if (is(T U == enum))
        enum isSomeChar = isSomeChar!U;
    else
        enum isSomeChar = !__traits(isZeroInit, T);
}

enum bool isSomeFunction(alias T) = is(T == return) || is(typeof(T) == return) || is(typeof(&T) == return);
enum bool isFunctionPointer(alias T) = is(typeof(*T) == function);
enum bool isDelegate(alias T) = is(typeof(T) == delegate) || is(T == delegate);

template isCallable(alias callable)
{
    static if (is(typeof(&callable.opCall) == delegate))
        enum bool isCallable = true;
    else static if (is(typeof(&callable.opCall) V : V*) && is(V == function))
        enum bool isCallable = true;
    else static if (is(typeof(&callable.opCall!()) TemplateInstanceType))
        enum bool isCallable = isCallable!TemplateInstanceType;
    else static if (is(typeof(&callable!()) TemplateInstanceType))
        enum bool isCallable = isCallable!TemplateInstanceType;
    else
        enum bool isCallable = isSomeFunction!callable;
}


alias Unconst(T : const U, U) = U;

template Unqual(T : const U, U)
{
    static if (is(U == shared V, V))
        alias Unqual = V;
    else
        alias Unqual = U;
}

template Unsigned(T)
{
    static if (isUnsigned!T)
        alias Unsigned = T;
    else static if (is(T == long))
        alias Unsigned = ulong;
    else static if (is(T == int))
        alias Unsigned = uint;
    else static if (is(T == short))
        alias Unsigned = ushort;
    else static if (is(T == byte))
        alias Unsigned = ubyte;
    else static if (is(T == ulong) || is(T == ushort) || is(T == ubyte) || is(T == bool) || is(T == char) || is(T == wchar) || is(T == dchar))
        alias Unsigned = T;
    else static if (is(T == U*, U))
        alias Unsigned = Unsigned!U*;
    else static if (is(T == U[], U))
        alias Unsigned = Unsigned!U[];
    else static if (is(T == U[N], U, size_t N))
        alias Unsigned = Unsigned!U[N];
    else static if (is(T == U[T], U, T))
        alias Unsigned = Unsigned!U[T];
    else static if (is(T == __vector(U[T]), U, T))
        alias Unsigned = __vector(Unsigned!U[T]);
    else static if (is(T == const(U), U))
        alias Unsigned = const(Unsigned!U);
    else static if (is(T == immutable(U), U))
        alias Unsigned = immutable(Unsigned!U);
    else static if (is(T == shared(U), U))
        alias Unsigned = shared(Unsigned!U);
    else
        static assert(false, T.stringof ~ " does not have unsigned counterpart");
}

template Signed(T)
{
    static if (isSigned!T)
        alias Unsigned = T;
    else static if (is(T == ulong))
        alias Signed = long;
    else static if (is(T == uint))
        alias Signed = int;
    else static if (is(T == ushort))
        alias Signed = short;
    else static if (is(T == ubyte))
        alias Signed = byte;
    else static if (is(T == long) || is(T == short) || is(T == byte) || is(T == cent))
        alias Signed = T;
    else static if (is(T == U*, U))
        alias Signed = Signed!U*;
    else static if (is(T == U[], U))
        alias Signed = Signed!U[];
    else static if (is(T == U[N], U, size_t N))
        alias Signed = Signed!U[N];
    else static if (is(T == U[T], U, T))
        alias Signed = Signed!U[T];
    else static if (is(T == const(U), U))
        alias Signed = const(Signed!U);
    else static if (is(T == immutable(U), U))
        alias Signed = immutable(Signed!U);
    else static if (is(T == shared(U), U))
        alias Signed = shared(Signed!U);
    else
        static assert(false, T.stringof ~ " does not have signed counterpart");
}

template ReturnType(alias func)
    if (isCallable!func)
{
    static if (is(FunctionTypeOf!func R == return))
        alias ReturnType = R;
    else
        static assert(0, "argument has no return type");
}

template Parameters(alias func)
    if (isCallable!func)
{
    static if (is(FunctionTypeOf!func P == function))
        alias Parameters = P;
    else
        static assert(0, "argument has no parameters");
}

template ParameterIdentifierTuple(alias func)
    if (isCallable!func)
{
    static if (is(FunctionTypeOf!func PT == __parameters))
    {
        alias ParameterIdentifierTuple = AliasSeq!();
        static foreach (i; 0 .. PT.length)
        {
            static if (!isFunctionPointer!func && !isDelegate!func
                       // Unnamed parameters yield CT error.
                       && is(typeof(__traits(identifier, PT[i .. i+1])))
                           // Filter out unnamed args, which look like (Type) instead of (Type name).
                           && PT[i].stringof != PT[i .. i+1].stringof[1..$-1])
            {
                ParameterIdentifierTuple = AliasSeq!(ParameterIdentifierTuple,
                                                     __traits(identifier, PT[i .. i+1]));
            }
            else
            {
                ParameterIdentifierTuple = AliasSeq!(ParameterIdentifierTuple, "");
            }
        }
    }
    else
    {
        static assert(0, func.stringof ~ " is not a function");
        // avoid pointless errors
        alias ParameterIdentifierTuple = AliasSeq!();
    }
}

template FunctionTypeOf(alias func)
    if (isCallable!func)
{
    static if ((is(typeof(& func) Fsym : Fsym*) && is(Fsym == function)) || is(typeof(& func) Fsym == delegate))
        alias FunctionTypeOf = Fsym; // HIT: (nested) function symbol
    else static if (is(typeof(& func.opCall) Fobj == delegate) || is(typeof(& func.opCall!()) Fobj == delegate))
        alias FunctionTypeOf = Fobj; // HIT: callable object
    else static if ((is(typeof(& func.opCall) Ftyp : Ftyp*) && is(Ftyp == function)) ||
                    (is(typeof(& func.opCall!()) Ftyp : Ftyp*) && is(Ftyp == function)))
        alias FunctionTypeOf = Ftyp; // HIT: callable type
    else static if (is(func T) || is(typeof(func) T))
    {
        static if (is(T == function))
            alias FunctionTypeOf = T;    // HIT: function
        else static if (is(T Fptr : Fptr*) && is(Fptr == function))
            alias FunctionTypeOf = Fptr; // HIT: function pointer
        else static if (is(T Fdlg == delegate))
            alias FunctionTypeOf = Fdlg; // HIT: delegate
        else
            static assert(0);
    }
    else
        static assert(0);
}

// is T a primitive/builtin type?
enum isPrimitive(T) = isIntegral!T || isSomeFloat!T || (isEnum!T && isPrimitive!(enumType!T) ||
                      is(T == P*, P) || is(T == S[], S) || (is(T == A[N], A, size_t N) && isPrimitive!A) ||
                      is(T == R function(Args), R, Args...) || is(T == R delegate(Args), R, Args...));

enum isDefaultConstructible(T) = isPrimitive!T || (is(T == struct) && __traits(compiles, { T t; }));

enum isConstructible(T, Args...) = (isPrimitive!T && (Args.length == 0 || (Args.length == 1 && is(Args[0] : T)))) ||
                                   (is(T == struct) && __traits(compiles, (Args args) { T x = T(args); })); // this probably fails if the struct can't be assigned to x... TODO: use placement new?

// TODO: we need to know it's not calling an elaborate constructor...
//enum isTriviallyConstructible(T, Args...) = (isPrimitive!T && (Args.length == 0 || (Args.length == 1 && is(Args[0] : T)))) ||
//                                            (is(T == struct) && __traits(compiles, (Args args) { auto x = T(args); })); // this probably fails if the struct can't be assigned to x... TODO: use placement new?

//enum isCopyConstructible(T) = isPrimitive!T || (is(T == struct) && __traits(compiles, { T u = lvalueOf!T; }));
//enum isMoveConstructible(T) = isPrimitive!T || (is(T == struct) && __traits(compiles, { T u = rvalueOf!T; }));

enum isTriviallyDefaultConstructible(T) = isDefaultConstructible!T; // dlang doesn't have elaborate default constructors (YET...)
//enum isTriviallyCopyConstructible(T) = isPrimitive!T; // TODO: somehow find out if there is no copy constructor
//enum isTriviallyMoveConstructible(T) = isPrimitive!T || is(T == struct); // TODO: somehow find out if there is no move constructor

// helpers to test certain expressions
private struct __InoutWorkaroundStruct{}
@property T rvalueOf(T)(inout __InoutWorkaroundStruct = __InoutWorkaroundStruct.init) pure nothrow @nogc;
@property ref T lvalueOf(T)(inout __InoutWorkaroundStruct = __InoutWorkaroundStruct.init) pure nothrow @nogc;
