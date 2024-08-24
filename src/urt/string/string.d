module urt.string.string;

import urt.mem.allocator;
import urt.mem.string : CacheString;
import urt.string : fnv1aHash, fnv1aHash64;
import urt.string.tailstring : TailString;

import core.lifetime : move;


enum String StringLit(string s) = s.makeString;

String makeString(const(char)[] s) nothrow
{
	if (s.length == 0)
		return String(null);
	return makeString(s, new char[s.length + (s.length < 128 ? 1 : 2)]);
}

String makeString(const(char)[] s, NoGCAllocator a) nothrow @nogc
{
	if (s.length == 0)
		return String(null);
	return makeString(s, cast(char[])a.alloc(s.length + (s.length < 128 ? 1 : 2)));
}

String makeString(const(char)[] s, char[] buffer, size_t* bytes = null) nothrow @nogc
{
	if (s.length == 0)
	{
		if (bytes)
			*bytes = 0;
		return String(null);
	}

	size_t lenBytes = s.length < 128 ? 1 : 2;
	assert(buffer.length >= s.length + lenBytes, "Not enough memory for string");
	writeString(buffer.ptr, s);
	if (bytes)
		*bytes = s.length + lenBytes;
	return String(buffer.ptr + lenBytes, null);
}


struct String
{
	alias toString this;

	const(char)* ptr;

	this(typeof(null)) pure nothrow @nogc
	{
		ptr = null;
	}

	this(T)(const(TailString!T) ts) pure nothrow @nogc
	{
		ptr = ts.ptr;
	}

	this(const(CacheString) cs) nothrow @nogc
	{
		ptr = cs.ptr;
	}

	~this() nothrow @nogc
	{
		// TODO: uncomment this when we allow strings to carry an allocator...
/+
		if (!ptr)
			return;
		uint preamble = ptr[-1];
		uint preambleLen = void;
		uint len = void;
		uint allocIndex = void;
		if ((preamble >> 6) < 3)
		{
			preambleLen = 1;
			len = preamble & 0x3F;
			allocIndex = preamble >> 6;
		}
		else
		{
			// get the prior byte...
		}

		if (allocIndex == 0)
			return;

		// free the string...
		stringAllocators[allocIndex - 1].free(cast(char[])ptr[0 .. preambleLen + len]);
+/
	}

	const(char)[] toString() const pure nothrow @nogc
	{
		return ptr[0 .. length()];
	}

	size_t length() const pure nothrow @nogc
	{
		if (!ptr)
			return 0;
		ushort len = ptr[-1];
		if (len < 128)
			return len;
		return ((len << 7) & 0x7F) | (ptr[-2] & 0x7F);
	}

	bool opCast(T : bool)() const pure nothrow @nogc
	{
		return ptr != null && ptr[-1] != 0;
	}

	void opAssign(typeof(null)) pure nothrow @nogc
	{
		ptr = null;
	}

	void opAssign(T)(const(TailString!T) ts) pure nothrow @nogc
	{
		ptr = ts.ptr;
	}

	void opAssign(const(CacheString) cs) nothrow @nogc
	{
		ptr = cs.ptr;
	}

	bool opEquals(const(char)[] rhs) const pure nothrow @nogc
	{
		size_t len = length();
		return len == rhs.length && (ptr == rhs.ptr || ptr[0 .. len] == rhs[]);
	}

	size_t toHash() const pure nothrow @nogc
	{
		static if (size_t.sizeof == 4)
			return fnv1aHash(ptr[0 .. length]);
		else
			return fnv1aHash64(ptr[0 .. length]);
	}

private:
	auto __debugOverview() => toString;
	auto __debugExpanded() => toString;
	auto __debugStringView() => toString;

	this(const(char)* str, typeof(null)) pure nothrow @nogc
	{
		ptr = str;
	}
 }


private:

__gshared NoGCAllocator[4] stringAllocators;

void writeString(char* buffer, const(char)[] str) pure nothrow @nogc
{
	size_t lenBytes = str.length < 128 ? 1 : 2;
	if (lenBytes == 1)
		buffer[0] = cast(char)str.length;
	else
	{
		buffer[0] = cast(char)(str.length & 0x7F) | 0x80;
		buffer[1] = cast(char)(str.length >> 7) | 0x80;
	}
	buffer[lenBytes .. lenBytes + str.length] = str[];
}
