module router.modbus.profile;

import std.format;

enum RecordType : ubyte
{
	uint16 = 0,
	int16,
	uint32,
	int32,
	exp10, // power of 10
	float32,
	bf16,
	bf32,
	enum16,
	enum32,
	str
}
enum StringRecord(ushort len) = RecordType.str + len - 1;

immutable ubyte[] seqLens = [ 1, 1, 2, 2, 1, 2, 1, 2, 1, 2 ];
immutable string[] typeStrings = [ "u16", "i16", "u32", "i32", "e10", "f32", "bf16", "bf32", "enum16", "enum32", "str" ];

static assert(seqLens.length == RecordType.str);
static assert(typeStrings.length == RecordType.str + 1);

struct ModbusRegInfo
{
	ushort reg;
	ushort refReg;
	RecordType type = RecordType.uint16;
	ubyte seqLen = 1;
	ubyte seqOffset;
	string name;
	string desc;
	string[] fields;

	this(int reg, RecordType type = RecordType.uint16, string name = null, string desc = null, string[] fields = null)
	{
		this.reg = cast(ushort)reg;
		this.refReg = this.reg;
		this.type = type >= RecordType.str ? RecordType.str : type;
		this.seqLen = type >= RecordType.str ? cast(ubyte)(type - RecordType.str + 1) : seqLens[type];
		this.name = name ? name : format("reg%d", reg).idup;
		this.desc = desc;
		this.fields = fields;

		assert(this.type != RecordType.str || this.seqLen <= 8, "String is too long!");
	}
	this(int reg, string name, string desc = null)
	{
		this.reg = cast(ushort)reg;
		this.refReg = this.reg;
		this.type = RecordType.uint16;
		this.seqLen = seqLens[RecordType.uint16];
		this.name = name ? name : format("reg%d", reg).idup;
		this.desc = desc;
	}
	this(int reg, int refReg, int seqIndex)
	{
		this.reg = cast(ushort)reg;
		this.refReg = cast(ushort)refReg;
		this.seqOffset = cast(ubyte)seqIndex;
		this.name = null;
		this.desc = null;
		this.fields = null;
	}
}

struct RegValue
{
	this(ModbusRegInfo* info)
	{
		this.info = info;
		words[] = 0;
	}

	struct E
	{
		ushort val;
		ushort exp;
	}

	ModbusRegInfo* info;
	union
	{
		ushort u16;
		short i16;
		uint u32;
		int i32;
		float f32;
		E e;
		ushort[8] words;
	}

	string toString()
	{
		import std.conv : to;
		import std.math : pow;

		final switch (info.type) with (RecordType)
		{
			case uint16:
				return u16.to!string;
			case int16:
				return i16.to!string;
			case uint32:
				return u32.to!string;
			case int32:
				return i32.to!string;
			case exp10:
				return pow(cast(float)e.val, e.exp).to!string;
			case float32:
				return f32.to!string;
			case bf16:
				return "TODO";
			case bf32:
				return "TODO";
			case enum16:
				if (u16 < info.fields.length)
					return info.fields[u16];
				else
					return u16.to!string;
			case enum32:
				if (u32 < info.fields.length)
					return info.fields[u32];
				else
					return u32.to!string;
			case str:
				char[] s = (cast(char*)words.ptr)[0 .. words.sizeof];
				for (size_t i = 0; i < words.sizeof; ++i)
				{
					if (s[i] == '\0')
						return s[0 .. i].idup;
				}
				return s[].idup;
		}
	}
}

struct ModbusProfile
{
	ModbusRegInfo[int] regInfoById;
	ModbusRegInfo*[string] regByName;

//	RegValue[int] regValues;

	// TODO: populate from json, yaml, etc

	void populateRegs(ModbusRegInfo[] regs)
	{
		foreach (r; regs)
		{
			regInfoById[r.reg] = r;

			if (r.seqOffset == 0)
			{
				ModbusRegInfo* info = &regInfoById[r.reg];
				regByName[r.name] = info;
				for (int i = 1; i < r.seqLen; ++i)
					regInfoById[r.reg + i] = ModbusRegInfo(r.reg + i, r.reg, i);
//				regValues[r.reg] = RegValue(info);
			}
		}
	}
}
