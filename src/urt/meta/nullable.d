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
	if (isBoolean!T)
{
	struct Nullable
	{
		enum ubyte NullValue = 0xFF;
		private ubyte _value = NullValue;

		this(T v)
		{
			_value = v;
		}

		bool value() const
			=> _value == 1;

		bool opCast(T : bool)() const
			=> value != NullValue;

		bool opEquals(typeof(null)) const
			=> _value == NullValue;
		bool opEquals(T v) const
			=> _value == cast(ubyte)v;

		void opAssign(typeof(null))
		{
			_value = NullValue;
		}
		void opAssign(U)(U v)
			if (is(U : T))
		{
			assert(v != NullValue);
			_value = cast(ubyte)v;
		}
	}
}

template Nullable(T)
	if (isSomeInt!T)
{
	struct Nullable
	{
		enum T NullValue = isSignedInt!T ? T.min : T.max;
		T value = NullValue;

		this(T v)
		{
			value = v;
		}

		bool opCast(T : bool)() const
			=> value != NullValue;

		bool opEquals(typeof(null)) const
			=> value == NullValue;
		bool opEquals(T v) const
			=> value != NullValue && value == v;

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
		enum T NullValue = T.nan;
		T value = NullValue;

		this(T v)
		{
			value = v;
		}

		bool opCast(T : bool)() const
			=> value !is NullValue;

		bool opEquals(typeof(null)) const
			=> value is NullValue;
		bool opEquals(T v) const
			=> value == v; // because nan doesn't compare with anything

		void opAssign(typeof(null))
		{
			value = NullValue;
		}
		void opAssign(U)(U v)
			if (is(U : T))
		{
			value = v;
		}
	}
}
