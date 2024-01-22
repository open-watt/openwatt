module util;

import std.format;

string toHexString(const(ubyte[]) data)
{
	import std.algorithm : map;
	import std.array : join;
	return data.map!(b => format("%02x", b)).join(" ");
}
