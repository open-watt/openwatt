module router.modbus.coding;

import std.conv;
import std.format;
import std.stdio;

import router.modbus.message;
import router.modbus.profile;
import router.modbus.util;

import util;


struct ModbusMessageData
{
	RequestType type;
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
					result = format("Read: %d (%d)", rw.readRegister, rw.readCount);
				if (rw.writeCount)
					result ~= format("%sWrite: %d (%d)", result ? ", " : "", rw.writeRegister, rw.writeCount);
				if (rw.values.length > 0)
				{
					result ~= format("%sValues: %s", result ? "\n  " : "", rw.values[]);

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
				break;
			default:
				break;
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


ModbusMessageData parseModbusMessage(RequestType type, ref const ModbusPDU pdu, void[] buffer = null)
{
	ModbusMessageData result;
	result.type = type;
	result.functionCode = pdu.functionCode;

	const(ubyte)[] data = pdu.data;

	switch (pdu.functionCode)
	{
		case FunctionCode.ReadCoils:
		case FunctionCode.ReadDiscreteInputs:
			if (type == RequestType.Request)
			{
				result.rw.readRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.readCount = data[2..4].bigEndianToNative!ushort;
			}
			else if (type == RequestType.Response)
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
			if (type == RequestType.Request)
			{
				result.rw.readRegister = data[0..2].bigEndianToNative!ushort;
				result.rw.readCount = data[2..4].bigEndianToNative!ushort;
			}
			else if (type == RequestType.Response)
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
			if (type == RequestType.Response)
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

				if (type == RequestType.Request) // response doesn't include data
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

				if (type == RequestType.Request) // response doesn't include data
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
			if (type == RequestType.Response)
				result.serverId = cast(const(char)[])data[1 .. 1 + data[0]];
			break;

		case FunctionCode.ReadFileRecord:
			break;

		case FunctionCode.WriteFileRecord:
			break;

		case FunctionCode.MaskWriteRegister:
			break;

		case FunctionCode.ReadAndWriteMultipleRegisters:
			break;

		case FunctionCode.ReadFIFOQueue:
			break;

		default:
			writeln("Unsupported Function Code");
			break;
	}

	return result;
}

/+
RegValue[] decodeValues(ref const ModbusPDU request, ref const ModbusPDU response, const ModbusProfile* profile, RegValue[] buffer = null)
{
	// assert that there are values in the response...
	// TODO:

	void[256] tmp = void;
	ModbusMessageData reqData = parseModbusMessage(RequestType.Request, request, tmp);
	ModbusMessageData resData = parseModbusMessage(RequestType.Response, response, tmp);
	return decodeValues(resData, profile, reqData.rw.readAddress, reqData.rw.readCount, buffer);
}

RegValue[] decodeValues(ref const ModbusMessageData messageData, const ModbusProfile* profile, ushort startRegister = 0, ushort count = 0, RegValue[] buffer = null)
{
	assert(profile);

	static immutable uint[] regAdjust = [ 0, 0, 10000, 40000, 30000, 0, 40000, 0, 0, 0, 0, 0, 40000 ];

	switch (messageData.functionCode)
	{
		case FunctionCode.ReadCoils:
		case FunctionCode.ReadDiscreteInputs:
		case FunctionCode.ReadHoldingRegisters:
		case FunctionCode.ReadInputRegisters:
			if (messageData.type == RequestType.Response)
				goto do_it;
			break;
		case FunctionCode.WriteSingleCoil:
		case FunctionCode.WriteSingleRegister:
		case FunctionCode.WriteMultipleCoils:
		case FunctionCode.WriteMultipleRegisters:
			if (messageData.type == RequestType.Request)
			{
				startRegister = messageData.rw.writeAddress;
				count = messageData.rw.writeCount;
				goto do_it;
			}
			break;
		default:
			break;
	}
	return null;

do_it:
	startRegister += regAdjust[messageData.functionCode];

	RegValue[] values;

	ushort i = 0;
	while (i < count)
	{
		ushort reg = cast(ushort)(startRegister + i);
		if (reg in profile.regById)
		{
			RegValue val = RegValue(profile.regById[reg]);

			final switch (val.info.type)
			{
				case RecordType.uint16:
				case RecordType.bf16:
				case RecordType.enum16:
					val.u = messageData.rw.values[i++];
					break;
				case RecordType.int16:
					val.i = cast(short)messageData.rw.values[i++];
					break;
				case RecordType.uint32:
				case RecordType.int32:
				case RecordType.float32:
				case RecordType.bf32:
				case RecordType.enum32:
					assert(val.info.seqLen == 2 && i < count - 1);
					const ModbusRegInfo* nextReg = profile.regById[reg + 1];
					assert(nextReg.refReg == reg && nextReg.seqOffset == 1);
					val.u = messageData.rw.values[i] << 16 | messageData.rw.values[i + 1];
					i += 2;
					if (val.info.type == RecordType.int32)
						val.i = cast(int)val.u;
					break;
				case RecordType.uint8H:
					val.u = messageData.rw.values[i++] >> 8;
					break;
				case RecordType.int8H:
					val.i = cast(byte)(messageData.rw.values[i++] >> 8);
					break;
				case RecordType.uint8L:
					val.u = messageData.rw.values[i++] && 0xFF;
					break;
				case RecordType.int8L:
					val.i = cast(byte)(messageData.rw.values[i++] && 0xFF);
					break;
				case RecordType.exp10:
					assert(false);
				case RecordType.str:
					assert(i + val.info.seqLen <= count);
					val.words[0 .. val.info.seqLen] = messageData.rw.values[i .. i + val.info.seqLen];
					i += val.info.seqLen;
					break;
			}

			values ~= val;
		}
		else
			++i;
	}

	return values;
}
+/
