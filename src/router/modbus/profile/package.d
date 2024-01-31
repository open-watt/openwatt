module router.modbus.profile;

import std.algorithm : map;
import std.ascii : toLower;
import std.format;

import router.modbus.message : RegisterType;

enum RecordType : ubyte
{
	uint16 = 0,
	int16,
	uint32,
	int32,
	uint8H,	// masked access
	uint8L, // masked access
	int8H, // masked access
	int8L, // masked access
	exp10, // power of 10
	float32,
	bf16,
	bf32,
	enum16,
	enum32,
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
	Configuration
}

struct ModbusRegInfo
{
	ushort reg;			// register address; 5 digits with register type; ie 30001, 40001, etc
	ushort refReg;
	RegisterType regType = RegisterType.HoldingRegister;
	RecordType type = RecordType.uint16; // register type; ie uint16, float, etc. Strings use RecordType_str!(len)
	Access access = Access.Read;
	ubyte seqLen = 1;
	ubyte seqOffset;
	string name;		// field name; ie "soc", "voltage", "power", etc
	string units;		// units of measure; ie "%", "kWh", "10mV+1000", etc
	string displayUnits;
	Frequency updateFrequency = Frequency.Medium;
	string desc;		// readable field description
	string[] fields;	// enum or bitfield names; ie [ "off", "on" ], [ "charging", "discharging" ], etc
	string[] fieldDesc;

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

		this.refReg = this.reg;
		parseTypeString(type);
		this.name = name ? name : format("reg%d", reg).idup;
		this.units = units;
		this.displayUnits = displayUnits ? displayUnits : units;
		this.updateFrequency = updateFrequency;
		this.desc = desc;
		this.fields = fields;
		this.fieldDesc = fieldDesc;
	}

	this(int reg, int refReg, int seqIndex)
	{
		this.reg = cast(ushort)reg;
		this.refReg = cast(ushort)refReg;
		this.seqOffset = cast(ubyte)seqIndex;
		this.name = null;
		this.units = null;
		this.desc = null;
		this.fields = null;
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

	void populateRegs(ModbusRegInfo[] regs)
	{
		registers = regs;

		foreach (ref r; regs)
		{
			regById[r.reg] = &r;
			regByName[r.name] = &r;
		}
	}
}

private:

immutable ubyte[] seqLens = [ 1, 1, 2, 2, 1, 1, 1, 1, 1, 2, 1, 2, 1, 2 ];
immutable string[] typeStrings = [ "u16", "i16", "u32", "i32", "u8", "u8", "i8", "i8", "e10", "f32", "bf16", "bf32", "enum16", "enum32", "str" ];

static assert(seqLens.length == RecordType.max);
static assert(typeStrings.length == RecordType.max + 1);
