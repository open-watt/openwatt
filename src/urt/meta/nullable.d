module urt.meta.nullable;

import urt.traits;


template Nullable(T)
	if (is(T == class))
{
	alias Nullable T;
}

template Nullable(T)
	if (is(T == U*, U))
{
	alias Nullable T;
}

template Nullable(T)
	if (isSomeInt!T)
{
	struct Nullable
	{
		enum T NullValue = isSignedInt!T ? T.min : T.max;
		T value = NullValue;

		bool opEquals(typeof(null)) const => value == NullValue;
		bool opEquals(T v) const => value != NullValue && value == v;

		bool opCast(t)() const if (T == bool) => value != NullValue;

		void opAssign(typeof(null))
		{
			value = NullValue;
		}
		void opAssign(U)(U v)
			if (is(U : T))
		{
			assert(v != NullValue);
			value = v;
		}
	}
}

template Nullable(T)
	if (isSomeFloat!T)
{
	struct Nullable
	{
		T value = T.nan;

		bool opEquals(typeof(null)) const
			=> value is T.nan;
		bool opEquals(T v) const
			=> value == v; // because nan doesn't compare with anything

		bool opCast(T : bool)() const
			=> value !is T.nan;

		void opAssign(typeof(null))
		{
			value = T.nan;
		}
		void opAssign(U)(U v)
			if (is(U : T))
		{
			value = v;
		}
	}
}


unittest
{


}
