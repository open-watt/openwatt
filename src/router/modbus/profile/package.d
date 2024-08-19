module router.modbus.profile;

import std.algorithm : map;
import std.ascii : toLower;
import std.format;
import std.stdio;

import manager.component;
import manager.config;
import manager.device;
import manager.instance;

import router.modbus.message : RegisterType;

import urt.mem.string;
import urt.string;

version = IncludeDescription;


enum RecordType : ubyte
{
	uint16 = 0,
	int16,
	uint32le,
	uint32,
	int32le,
	int32,
	uint64le,
	uint64,
	int64le,
	int64,
	uint8H,	// masked access
	uint8L, // masked access
	int8H, // masked access
	int8L, // masked access
	exp10, // power of 10
	float32le,
	float32,
	float64le,
	float64,
	bf16,
	bf32,
	bf64,
	enum16,
	enum32,
	enum32_float,
	str
}
enum RecordType_str(ushort len) = cast(RecordType)(RecordType.str + len - 1);

enum Access : ubyte
{
	Read,
	Write,
	ReadWrite
}

enum Frequency : ubyte
{
	Realtime = 0,
	High,	// ie, seconds
	Medium,	// ie, 10s seconds
	Low,	// ie, minutes
	Constant,
	OnDemand,
	Configuration
}

struct ModbusRegDesc
{
	this() @disable;

	static ModbusRegDesc* makeDesc(const(char)[] name, const(char)[] displayUnits, Frequency updateFrequency, const(char)[] description, const(char[])[] fields, const(char[])[] fieldDesc)
	{
		version (IncludeDescription)
			enum descOffset = 1;
		else
			enum descOffset = 0;

		const(char)[][descOffset + 32] tailStrings = void;
		String[descOffset + 33] temp = void;

		size_t numStrings = descOffset + fields.length + fieldDesc.length;
		assert(numStrings <= tailStrings.length, "TODO: alloc some scratch mem!");

		version (IncludeDescription)
			tailStrings[0] = description;
		for (uint i = 0; i < fields.length; ++i)
			tailStrings[descOffset + i] = fields[i];
		for (uint i = 0; i < fieldDesc.length; ++i)
			tailStrings[descOffset + i + fields.length] = fieldDesc[i];

		size_t size = ModbusRegDesc.sizeof + fields.length*TailString2.sizeof + fieldDesc.length*TailString2.sizeof;
		ModbusRegDesc* desc = cast(ModbusRegDesc*)allocWithStringCache(size, temp[0 .. numStrings], tailStrings[0 .. numStrings]);

		desc.name = addString(name);
		desc.displayUnits = addString(displayUnits);
		version (IncludeDescription)
			desc.description = temp[0];
		desc.updateFrequency = updateFrequency;

		assert(fields.length < 256, "Too many fields");
		assert(fieldDesc.length < 256, "Too many fields");
		desc.numFields = cast(ubyte)fields.length;
		desc.numFieldDesc = cast(ubyte)fieldDesc.length;

		for (uint i = 0; i < desc.numFields; ++i)
			desc.fields[i] = temp[1 + i];
		for (uint i = 0; i < desc.numFieldDesc; ++i)
			desc.fieldDesc[i] = temp[1 + desc.numFields + i];

		return desc;
	}

	CacheString name;			// field name; ie "soc", "voltage", "power", etc
	CacheString displayUnits;
	version (IncludeDescription)
		TailString1 description;	// readable field description
	else
		String description() const pure nothrow @nogc => String(null);

	Frequency updateFrequency = Frequency.Medium;
	ubyte numFields = 0;
	ubyte numFieldDesc = 0;

	// enum or bitfield names; ie [ "off", "on" ], [ "charging", "discharging" ], etc
	inout(TailString2)[] fields() inout pure nothrow @nogc => tail()[0 .. numFields];
	inout(TailString2)[] fieldDesc() inout pure nothrow @nogc => tail()[numFields .. numFields + numFieldDesc];

	inout(TailString2)* tail() inout pure nothrow @nogc => cast(TailString2*)((&this) + 1);
}

struct ModbusRegInfo
{
	ushort reg;			// register address; 5 digits with register type; ie 30001, 40001, etc
	RegisterType regType = RegisterType.HoldingRegister;
	Access access = Access.Read;
	RecordType type = RecordType.uint16; // register type; ie uint16, float, etc. Strings use RecordType_str!(len)
	ubyte seqLen = 1;
	CacheString units;		// units of measure; ie "%", "kWh", "10mV+1000", etc
	ModbusRegDesc* desc;

	this(int reg, string type = "u16", string name = null, string units = null, string displayUnits = null, Frequency updateFrequency = Frequency.Medium, string desc = null, string[] fields = null, string[] fieldDesc = null)
	{
		if (reg < 10000)
		{
			this.regType = RegisterType.Coil;
			this.reg = cast(ushort)reg;
		}
		else if (reg < 20000)
		{
			this.regType = RegisterType.DiscreteInput;
			this.reg = cast(ushort)(reg - 10000);
		}
		else if (reg < 30000)
			assert(false, "Invalod register type");
		else if (reg < 40000)
		{
			this.regType = RegisterType.InputRegister;
			this.reg = cast(ushort)(reg - 30000);
		}
		else
		{
			this.regType = RegisterType.HoldingRegister;
			this.reg = cast(ushort)(reg - 40000);
		}

		parseTypeString(type);
		this.units = addString(units);

		char[16] temp;
		this.desc = ModbusRegDesc.makeDesc(name ? name : format(temp, "reg{0}", reg), displayUnits ? displayUnits : units, updateFrequency, desc, fields, fieldDesc);
	}

	this(int reg, int refReg, int seqIndex)
	{
		this.reg = cast(ushort)reg;
		this.units = null;
		this.desc = null;
	}

private:
	void parseTypeString(string type)
	{
		foreach (ty; 0 .. RecordType.max + 1)
		{
			string ts = typeStrings[ty];
			if (type.length < ts.length || type[0..ts.length] != ts[])
				continue;

			this.type = cast(RecordType)ty;

			size_t i = ts.length;
			if (ty == RecordType.str)
			{
				assert(type.length > 3, "String type needs length, eg: \"str10\"");
				this.seqLen = 0;
				for (; i < type.length; ++i)
				{
					if (type[i] < '0' || type[i] > '9')
						break;
					this.seqLen = cast(ubyte)(this.seqLen*10 + type[i] - '0');
				}
				assert(this.seqLen > 0, "String length must be greater than 0");
			}
			else
				this.seqLen = seqLens[this.type];

			if (i < type.length && type[i] == '/' && i + 1 < type.length)
			{
				++i;
				if (type[i] == 'R')
				{
					if (i + 1 < type.length && type[i + 1] == 'W')
						this.access = Access.ReadWrite;
					else
						this.access = Access.Read;
				}
				else if (type[i] == 'W')
					this.access = Access.Write;
			}
			break;
		}
	}
}

struct ModbusProfile
{
	ModbusRegInfo[] registers;
	ModbusRegInfo*[int] regById;
	ModbusRegInfo*[string] regByName;

	// TODO: populate from json, yaml, etc

	this(ModbusRegInfo[] regs)
	{
		populateRegs(regs);
	}

	void populateRegs(ModbusRegInfo[] regs)
	{
		registers = regs;

		foreach (ref r; regs)
		{
			regById[r.reg] = &r;
			regByName[r.desc.name] = &r;
		}
	}
}


ModbusProfile* loadModbusProfile(const(char)[] filename)
{
	ConfItem root = parseConfigFile(filename);
	return parseModbusProfile(root);
}

ModbusProfile* parseModbusProfile(string conf)
{
	ConfItem root = parseConfig(conf);
	return parseModbusProfile(root);
}

ModbusProfile* parseModbusProfile(ConfItem conf)
{
	import std.conv : to;
	import std.uni : toLower;

	ModbusRegInfo[] registers;

	foreach (ref rootItem; conf.subItems) switch (rootItem.name)
	{
		case "registers":
			foreach (ref regItem; rootItem.subItems) switch (regItem.name)
			{
				case "reg":
					// parse register details
					string register, type, units, id, displayUnits, freq, desc;
					string[] fields, fieldDesc;

					string extra, tail = regItem.value;
					char sep;
					register = tail.split!(',', ':')(sep);
					assert(sep == ',');
					type = tail.split!(',', ':')(sep).unQuote.idup;
					assert(sep == ',');
					string t = tail.split!(',', ':')(sep);
					if (sep == ':')
						extra = t;
					else
					{
						units = t.unQuote.idup;
						extra = tail.split!':';
					}
					if (!extra.empty)
						regItem.subItems = ConfItem(extra, tail) ~ regItem.subItems;

					foreach (ref regConf; regItem.subItems) switch (regConf.name)
					{
						case "desc":
							tail = regConf.value;
							id = tail.split!','.unQuote.idup;
							displayUnits = tail.split!','.unQuote.idup;
							freq = tail.split!','.unQuote.idup;
							desc = tail.split!','.unQuote.idup;
							// TODO: if !tail.empty, warn about unexpected data...
							break;

						case "valueid":
							tail = regConf.value;
							// TODO: make this a warning message, no asserts!
							assert(!tail.empty);
							do
								fields ~= tail.split!','(sep).unQuote.idup;
							while (sep != '\0');
							break;

						case "valuedesc":
							tail = regConf.value;
							// TODO: make this a warning message, no asserts!
							assert(!tail.empty);
							do
								fieldDesc ~= tail.split!','(sep).unQuote.idup;
							while (sep != '\0');
							break;

						case "map-local":
							// TODO:
							break;

						case "map-mb":
							// TODO:
							break;

						default:
							writeln("Invalid token: ", regConf.name);
					}

					Frequency frequency = Frequency.Medium;
					if (!freq.empty) switch (freq.toLower)
					{
						case "realtime":	frequency = Frequency.Realtime;			break;
						case "high":		frequency = Frequency.High;				break;
						case "medium":		frequency = Frequency.Medium;			break;
						case "low":			frequency = Frequency.Low;				break;
						case "const":		frequency = Frequency.Constant;			break;
						case "ondemand":	frequency = Frequency.OnDemand;			break;
						case "config":		frequency = Frequency.Configuration;	break;
						default: writeln("Invalid frequency value: ", freq);
					}

					registers ~= ModbusRegInfo(register.to!int, type, id, units, displayUnits, frequency, desc, fields, fieldDesc);
					break;

				default:
					writeln("Invalid token: ", regItem.name);
			}
			break;

		default:
			writeln("Invalid token: ", rootItem.name);
	}

	if (registers.empty)
		return null;

	return new ModbusProfile(registers);
}


private:

immutable ubyte[] seqLens = [ 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 1, 1, 1, 1, 1, 2, 2, 4, 4, 1, 2, 4, 1, 2, 2 ];
immutable string[] typeStrings = [ "u16", "i16", "u32le", "u32", "i32le", "i32", "u64le", "u64", "i64le", "i64", "u8h", "u8l", "i8h", "i8l", "e10", "f32le", "f32", "f64le", "f64", "bf16", "bf32", "bf64", "enum16", "enum32", "enumf32", "str" ];

static assert(seqLens.length == RecordType.max);
static assert(typeStrings.length == RecordType.max + 1);
