module urt.string;

public import urt.string.ascii;
public import urt.string.string;
public import urt.string.tailstring;

enum TempStringBufferLen = 1024;
enum TempStringMaxLen = TempStringBufferLen / 2;

static char[TempStringBufferLen] s_tempStringBuffer;
static size_t s_tempStringBufferPos = 0;

char[] allocTempString(size_t len) nothrow @nogc
{
	assert(len <= TempStringMaxLen);

	if (len <= TempStringBufferLen - s_tempStringBufferPos)
	{
		char[] s = s_tempStringBuffer[s_tempStringBufferPos .. s_tempStringBufferPos + len];
		s_tempStringBufferPos += len;
		return s;
	}
	s_tempStringBufferPos = len;
	return s_tempStringBuffer[0 .. len];
}

public import urt.mem : strlen;

bool empty(T)(T[] arr)
{
	return arr.length == 0;
}

bool startsWith(const(char)[] s, const(char)[] prefix) pure nothrow @nogc
{
    if (s.length < prefix.length)
        return false;
    for (size_t i = 0; i < prefix.length; ++i)
    {
        if (s[i] != prefix[i])
            return false;
    }
    return true;
}

ref inout(char) popFront(ref inout(char)[] buffer) pure nothrow @nogc
{
	debug assert(buffer.length > 0);
	buffer = buffer.ptr[1..buffer.length];
	return buffer.ptr[-1];
}

ref inout(char) popBack(ref inout(char)[] buffer) pure nothrow @nogc
{
	debug assert(buffer.length > 0);
	buffer = buffer.ptr[0..buffer.length - 1];
	return buffer.ptr[buffer.length];
}

inout(char)[] trim(bool Front = true, bool Back = true)(inout(char)[] s) pure nothrow @nogc
{
	size_t first = 0, last = s.length;
	static if (Front)
	{
		while (first < s.length && isWhitespace(s.ptr[first]))
			++first;
	}
	static if (Back)
	{
		while (last > first && isWhitespace(s.ptr[last - 1]))
			--last;
	}
	return s.ptr[first .. last];
}

alias trimFront = trim!(true, false);

alias trimBack = trim!(false, true);

inout(char)[] trimComment(char Delimiter)(inout(char)[] s)
{
	size_t i = 0;
	for (; i < s.length; ++i)
	{
		if (s[i] == Delimiter)
			break;
	}
	while(i > 0 && (s[i-1] == ' ' || s[i-1] == '\t'))
		--i;
	return s[0 .. i];
}

inout(char)[] takeFront(ref inout(char)[] s, size_t count) pure nothrow @nogc
{
	assert(count <= s.length);
	inout(char)[] t = s.ptr[0 .. count];
	s = s.ptr[count .. s.length];
	return t;
}

inout(char)[] takeBack(ref inout(char)[] s, size_t count) pure nothrow @nogc
{
	assert(count <= s.length);
	inout(char)[] t = s.ptr[s.length - count .. s.length];
	s = s.ptr[0 .. s.length - count];
	return t;
}

inout(char)[] takeLine(ref inout(char)[] s) pure nothrow @nogc
{
	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] == '\n')
		{
			inout(char)[] t = s[0 .. i];
			s = s[i + 1 .. $];
			return t;
		}
		else if (s.length > i+1 && s[i] == '\r' && s[i+1] == '\n')
		{
			inout(char)[] t = s[0 .. i];
			s = s[i + 2 .. $];
			return t;
		}
	}
	inout(char)[] t = s;
	s = s[$ .. $];
	return t;
}

inout(char)[] split(char Separator)(ref inout(char)[] s)
{
	int inQuotes = 0;
	size_t i = 0;
	for (; i < s.length; ++i)
	{
		if (s[i] == Separator && !inQuotes)
			break;
		if (s[i] == '"' && !(inQuotes & 0x6))
			inQuotes = 1 - inQuotes;
		else if (s[i] == '\'' && !(inQuotes & 0x5))
			inQuotes = 2 - inQuotes;
		else if (s[i] == '`' && !(inQuotes & 0x3))
			inQuotes = 4 - inQuotes;
	}
	inout(char)[] t = s[0 .. i].trimBack;
	s = i < s.length ? s[i+1 .. $].trimFront : null;
	return t;
}

inout(char)[] split(Separator...)(ref inout(char)[] s, out char sep)
{
	sep = '\0';
	int inQuotes = 0;
	size_t i = 0;
	loop: for (; i < s.length; ++i)
	{
		static foreach (S; Separator)
		{
			static assert(is(typeof(S) == char), "Only single character separators supported");
			if (s[i] == S && !inQuotes)
			{
				sep = s[i];
				break loop;
			}
		}
		if (s[i] == '"' && !(inQuotes & 0x6))
			inQuotes = 1 - inQuotes;
		else if (s[i] == '\'' && !(inQuotes & 0x5))
			inQuotes = 2 - inQuotes;
		else if (s[i] == '`' && !(inQuotes & 0x3))
			inQuotes = 4 - inQuotes;
	}
	inout(char)[] t = s[0 .. i].trimBack;
	s = i < s.length ? s[i+1 .. $].trimFront : null;
	return t;
}

char[] unQuote(const(char)[] s, char[] buffer) pure nothrow @nogc
{
	// TODO: should this scan and match quotes rather than assuming there are no rogue closing quotes in the middle of the string?
	if (s.empty)
		return null;
	if (s[0] == '"' && s[$-1] == '"' || s[0] == '\'' && s[$-1] == '\'')
	{
		if (s is buffer)
			return buffer[1 .. $-1].unEscape;
		return s[1 .. $-1].unEscape(buffer);
	}
	bool quote = s[0] == '`' && s[$-1] == '`';
	if (s is buffer)
		return quote ? buffer[1 .. $-1] : buffer;
	s = quote ? s[1 .. $-1] : s;
	buffer[0 .. s.length] = s[];
	return buffer;
}

char[] unQuote(char[] s) pure nothrow @nogc
{
	return unQuote(s, s);
}

char[] unQuote(const(char)[] s) nothrow @nogc
{
	import urt.mem.temp : talloc;
	return unQuote(s, cast(char[])talloc(s.length));
}

char[] unEscape(inout(char)[] s, char[] buffer) pure nothrow @nogc
{
	if (s.empty)
		return null;

	bool same = s is buffer;

	size_t len = 0;
	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] == '\\')
		{
			if (s.length > ++i)
			{
				switch (s[i])
				{
					case '0':	buffer[len++] = '\0';	break;
					case 'n':	buffer[len++] = '\n';	break;
					case 'r':	buffer[len++] = '\r';	break;
					case 't':	buffer[len++] = '\t';	break;
//					case '\\':	buffer[len++] = '\\';	break;
//					case '\'':	buffer[len++] = '\'';	break;
					default:	buffer[len++] = s[i];
				}
			}
		}
		else if (!same || len < i)
			buffer[len++] = s[i];
	}
	return buffer[0..len];
}

char[] unEscape(char[] s) pure nothrow @nogc
{
	return unEscape(s, s);
}


char[] toHexString(const(ubyte[]) data, char[] buffer, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -") pure nothrow @nogc
{
	import urt.util : isPowerOf2;
	assert(group.isPowerOf2);
	assert(secondaryGroup.isPowerOf2);
	assert(secondaryGroup == 0 || seps.length > 1, "Secondary grouping requires additional separator");

	if (buffer.length < 2)
		return null;

	__gshared immutable char[16] hex = "0123456789ABCDEF";
	size_t mask = group - 1;
	size_t secondMask = secondaryGroup - 1;

	size_t offset = 0;
	for (size_t i = 0; true;)
	{
		buffer[offset++] = hex[data[i] >> 4];
		buffer[offset++] = hex[data[i] & 0xF];

		bool sep = (i & mask) == mask;
		if (++i == data.length || offset + 2 + sep > buffer.length)
			return buffer[0 .. offset];
		if (sep)
			buffer[offset++] = ((i & secondMask) == 0 ? seps[1] : seps[0]);
	}
}

char[] toHexString(const(ubyte[]) data, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -") nothrow @nogc
{
	import urt.mem.temp;

	size_t len = data.length*2;
	if (group && len > 0)
		len += (data.length-1) / group;
	return data.toHexString(cast(char[])talloc(len), group, secondaryGroup, seps);
}

unittest
{
	ubyte[] data = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF];
	assert(data.toHexString(0) == "0123456789ABCDEF");
	assert(data.toHexString(1) == "01 23 45 67 89 AB CD EF");
	assert(data.toHexString(2) == "0123 4567 89AB CDEF");
	assert(data.toHexString(4) == "01234567 89ABCDEF");
	assert(data.toHexString(8) == "0123456789ABCDEF");
	assert(data.toHexString(2, 4, "_ ") == "0123_4567 89AB_CDEF");
}


bool wildcardMatch(const(char)[] wildcard, const(char)[] value)
{
	// TODO: write this function...

	// HACK: we just use this for tail wildcards right now...
	for (size_t i = 0; i < wildcard.length; ++i)
	{
		if (wildcard[i] == '*')
			return true;
		if (wildcard[i] != value[i])
			return false;
	}
	return wildcard.length == value.length;
}

uint fnv1aHash(const(ubyte)[] s) pure nothrow @nogc
{
	uint hash = 0x811C9DC5; // 32-bit FNV offset basis
	foreach (ubyte c; s)
	{
		hash ^= c;
		hash *= 0x01000193; // 32-bit FNV prime
	}
	return hash;
}

ulong fnv1aHash64(const(ubyte)[] s) pure nothrow @nogc
{
	ulong hash = 0XCBF29CE484222325; // 64-bit FNV offset basis
	foreach (ubyte c; s)
	{
		hash ^= c;
		hash *= 0x100000001B3; // 64-bit FNV prime
	}
	return hash;
}
