module router.modbus.coding;

import urt.endian;
import urt.string.format;
import urt.io;

import router.modbus.message;
import router.modbus.profile;
import router.modbus.util;

import router.iface.modbus;


struct ModbusMessageData
{
	ModbusFrameType type;
	FunctionCode functionCode;
	union
	{
		ReadWrite rw;
		Mask mask;
		const(char)[] serverId;
		ubyte exceptionStatus;
	}

	string toString() const
	{
		string result = null;
		switch (functionCode)
		{
			case FunctionCode.ReadCoils:
			case FunctionCode.ReadDiscreteInputs:
			case FunctionCode.ReadHoldingRegisters:
			case FunctionCode.ReadInputRegisters:
			case FunctionCode.WriteSingleCoil:
			case FunctionCode.WriteSingleRegister:
			case FunctionCode.WriteMultipleCoils:
			case FunctionCode.WriteMultipleRegisters:
				if (rw.readCount)
					result ~= tformat("Read: {0} ({1})", rw.readRegister, rw.readCount);
				if (rw.writeCount)
					result ~= tformat("%sWrite: {0} ({1})", result ? ", " : "", rw.writeRegister, rw.writeCount);
				if (rw.values.length > 0)
				{
					result ~= tformat("{0}Values: {1}", result ? "\n  " : "", rw.values[]);

//					import std.algorithm, std.range;
//					result ~= format("\n  hex: %s", rw.values[].map!(i => format("%04x ", i)).fold!((x, y) => x ~ y));
//					uint[] leInts, beInts;
//					float[] leFloats, beFloats;
//					for(size_t i = 0; i < rw.values.length - 1; i += 2)
//					{
//						uint le = rw.values[i] | cast(uint)rw.values[i + 1] << 16;
////						uint be = rw.values[i + 1] | cast(uint)rw.values[i] << 16;
//						float lef = *cast(float*)&le;
////						float bef = *cast(float*)&be;
//						leInts ~= le;
////						beInts ~= be;
//						leFloats ~= lef;
////						beFloats ~= bef;
//					}
////					result ~= format("\n  int-be: %s", beInts[]);
//					result ~= format("\n  int-le: %s", leInts[]);
////					result ~= format("\n  float-be: %s", beFloats[]);
//					result ~= format("\n  float-le: %s", leFloats[]);
				}
				break;
			case FunctionCode.ReadExceptionStatus:
			case FunctionCode.Diagnostics:
			case FunctionCode.GetComEventCounter:
			case FunctionCode.GetComEventLog:
			case FunctionCode.ReportServerID:
			case FunctionCode.ReadFileRecord:
			case FunctionCode.WriteFileRecord:
			case FunctionCode.MaskWriteRegister:
			case FunctionCode.ReadAndWriteMultipleRegisters:
			case FunctionCode.ReadFIFOQueue:
			default:
				assert(0);
		}
		return result;
	}

private:
	struct ReadWrite
	{
		ushort readRegister;
		ushort readCount;
		ushort writeRegister;
		ushort writeCount;
		ushort[] values;
	}
	struct Mask
	{
		ushort address;
		ushort andMask;
		ushort orMask;
	}
}


ModbusMessageData parseModbusMessage(ModbusFrameType type, ref const ModbusPDU pdu, void[] buffer = null)
{
	ModbusMessageData result;
	result.type = type;
	result.functionCode = pdu.functionCode;

	const(ubyte)[] data = pdu.data;

	if (pdu.functionCode >= 128)
	{
		result.exceptionStatus = pdu.data[0];
	}
	else switch (pdu.functionCode)
	{
		case FunctionCode.ReadCoils:
		case FunctionCode.ReadDiscreteInputs:
			if (type == ModbusFrameType.Request)
			{
				result.rw.readRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.readCount = data[2..4].bigEndianToNative!ushort;
			}
			else if (type == ModbusFrameType.Response)
			{
				ubyte byteCount = data[0];
				ushort count = byteCount * 8;

				if (count < buffer.length/2)
					result.rw.values = (cast(ushort[])buffer)[0 .. count];
				else
					result.rw.values = new ushort[count];

				for (size_t i = 0; i < byteCount * 8 && i < count; ++i)
					result.rw.values[i] = (data[1 + i/8] & (1 << (i%8))) ? 1 : 0;
			}
			break;

		case FunctionCode.ReadHoldingRegisters:
		case FunctionCode.ReadInputRegisters:
			if (type == ModbusFrameType.Request)
			{
				result.rw.readRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.readCount = data[2..4].bigEndianToNative!ushort;
			}
			else if (type == ModbusFrameType.Response)
			{
				ubyte byteCount = data[0];
				ushort count = byteCount / 2;

				if (count < buffer.length/2)
					result.rw.values = (cast(ushort[])buffer)[0 .. count];
				else
					result.rw.values = new ushort[count];

				for (size_t i = 0; i < byteCount; i += 2)
				{
					if (1 + i < data.length)
						result.rw.values[i/2] = data[1 + i .. 3 + i][0..2].bigEndianToNative!ushort;
				}
			} 
			break;

		case FunctionCode.WriteSingleCoil:
			if (data.length >= 4)
			{
				result.rw.writeRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.writeCount = 1;

				result.rw.values = (cast(ushort[])buffer)[0 .. 1];
				result.rw.values[0] = data[2..4].bigEndianToNative!ushort;
				assert(result.rw.values[0] == 0 || result.rw.values[0] == 0xFF00);
				if (result.rw.values[0] == 0xFF00)
					result.rw.values[0] = 1;
			}
			break;

		case FunctionCode.WriteSingleRegister:
			if (data.length >= 4)
			{
				result.rw.writeRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.writeCount = 1;

				result.rw.values = (cast(ushort[])buffer)[0 .. 1];
				result.rw.values[0] = data[2..4].bigEndianToNative!ushort;
			}
			break;

		case FunctionCode.ReadExceptionStatus:
			if (type == ModbusFrameType.Response)
				result.exceptionStatus = data[0];
			break;

		case FunctionCode.Diagnostics:
			assert(false);
			break;

		case FunctionCode.GetComEventCounter:
			assert(false);
			break;

		case FunctionCode.GetComEventLog:
			assert(false);
			break;

		case FunctionCode.WriteMultipleCoils:
			if (data.length >= 5)
			{
				result.rw.writeRegister = data[0..2].bigEndianToNative!ushort;
				ushort count = data[2..4].bigEndianToNative!ushort;
				result.rw.writeCount = count;

				if (type == ModbusFrameType.Request) // response doesn't include data
				{
					ubyte byteCount = data[4];
					assert(byteCount == (count + 7) / 8);

					if (count < buffer.length/2)
						result.rw.values = (cast(ushort[])buffer)[0 .. count];
					else
						result.rw.values = new ushort[count];

					for (size_t i = 0; i < byteCount * 8 && i < count; ++i)
						result.rw.values[i] = (data[5 + i/8] & (1 << (i%8))) ? 1 : 0;
				}
			}
			break;

		case FunctionCode.WriteMultipleRegisters:
			if (data.length >= 5)
			{
				result.rw.writeRegister = data[0..2].bigEndianToNative!ushort;
				ushort count = data[2..4].bigEndianToNative!ushort;
				result.rw.writeCount = count;

				if (type == ModbusFrameType.Request) // response doesn't include data
				{
					ubyte byteCount = data[4];
					assert(byteCount == count*2);

					if (count < buffer.length/2)
						result.rw.values = (cast(ushort[])buffer)[0 .. count];
					else
						result.rw.values = new ushort[count];

					for (size_t i = 0; i < byteCount; i += 2)
					{
						if (i + 1 < data.length)
							result.rw.values[i/2] = data[5 + i .. 7 + i][0..2].bigEndianToNative!ushort;
					}
				}
			}
			break;

		case FunctionCode.ReportServerID:
			if (type == ModbusFrameType.Response)
				result.serverId = cast(const(char)[])data[1 .. 1 + data[0]];
			break;

		case FunctionCode.ReadFileRecord:
			assert(0);
			break;

		case FunctionCode.WriteFileRecord:
			assert(0);
			break;

		case FunctionCode.MaskWriteRegister:
			assert(0);
			break;

		case FunctionCode.ReadAndWriteMultipleRegisters:
			assert(0);
			break;

		case FunctionCode.ReadFIFOQueue:
			assert(0);
			break;

		default:
			writeln("Unsupported Function Code");
			assert(0);
			break;
	}

	return result;
}
