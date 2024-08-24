module urt.traits;

alias AliasSeq(TList...) = TList;

enum isSomeChar(T) = is(T == char) || is(T == wchar) || is(T == dchar);
enum isSomeInt(T) = is(T == byte) || is(T == ubyte) || is(T == short) || is(T == ushort) || is(T == int) || is(T == uint) || is(T == long) || is(T == ulong);
enum isSomeFloat(T) = is(T == float) || is(T == double) || is(T == real);
enum isIntegral(T) = is(T == bool) || isSomeInt!T || isSomeChar!T;

enum isSignedInt(T) = is(T == byte) || is(T == short) || is(T == int) || is(T == long);
enum isUnsignedInt(T) = is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong);

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
	static if (is(T == long))
		alias Unsigned = ulong;
	else static if (is(T == int))
		alias Unsigned = uint;
	else static if (is(T == short))
		alias Unsigned = ushort;
	else static if (is(T == byte))
		alias Unsigned = ubyte;
	else static if (is(T == cent))
		alias Unsigned = ucent;
	else static if (is(T == ulong) || is(T == ushort) || is(T == ubyte) || is(T == ucent) || is(T == bool) || is(T == char) || is(T == wchar) || is(T == dchar))
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
	static if (is(T == ulong))
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
