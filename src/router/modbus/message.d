module router.modbus.message;

import urt.endian;

import router.modbus.util;

enum ModbusMessageDataMaxLength = 252;

enum RegisterType : ubyte
{
	Coil = 0,
	DiscreteInput,
	InputRegister,
	HoldingRegister
}

enum FunctionCode : ubyte
{
	ReadCoils = 0x01, // Read the status of coils in a slave device
	ReadDiscreteInputs = 0x02, // Read the status of discrete inputs in a slave
	ReadHoldingRegisters = 0x03, // Read the contents of holding registers in the slave
	ReadInputRegisters = 0x04, // Read the contents of input registers in the slave
	WriteSingleCoil = 0x05, // Write a single coil in the slave
	WriteSingleRegister = 0x06, // Write a single holding register in the slave
	ReadExceptionStatus = 0x07, // Read the contents of eight Exception Status outputs in a slave
	Diagnostics = 0x08, // Various sub-functions for diagnostics and testing
	Program484 = 0x09, // EXOTIC: Program the 484
	Poll484 = 0x0A, // EXOTIC: Poll the 484
	GetComEventCounter = 0x0B, // Get the status of the communication event counter in the slave
	GetComEventLog = 0x0C, // Retrieve the slave's communication event log
	ProgramController = 0x0D, // EXOTIC: Program the controller
	PollController = 0x0E, // EXOTIC: Poll the controller
	WriteMultipleCoils = 0x0F, // Write multiple coils in a slave device
	WriteMultipleRegisters = 0x10, // Write multiple registers in a slave device
	ReportServerID = 0x11, // Request the unique identifier of a slave
	Program884_M84 = 0x12, // EXOTIC: Program the 884 or M84
	ResetCommLink = 0x13, // EXOTIC: Reset the communication link
	ReadFileRecord = 0x14, // Read the contents of a file record in the slave
	WriteFileRecord = 0x15, // Write to a file record in the slave
	MaskWriteRegister = 0x16, // Modify the contents of a register using a combination of AND and OR
	ReadAndWriteMultipleRegisters = 0x17, // Read and write multiple registers in a single transaction
	ReadFIFOQueue = 0x18, // Read from a FIFO queue of registers in the slave
	MEI = 0x2B // MODBUS Encapsulated Interface (MEI) Transport
}

enum FunctionCode_Diagnostic : ushort
{
	ReturnQueryData = 0x00, // Return Query Data
	RestartCommunicationsOption = 0x01, // Restart Communications Option
	ReturnDiagnosticRegister = 0x02, // Return Diagnostic Register
	ChangeAsciiInputDelimiter = 0x03, // Change ASCII Input Delimiter
	ForceListenOnlyMode = 0x04, // Force Listen Only Mode
	ClearCountersAndDiagnosticRegister = 0x0A, // Clear Counters and Diagnostic Register
	ReturnBusMessageCount = 0x0B, // Return Bus Message Count
	ReturnBusCommunicationErrorCount = 0x0C, // Return Bus Communication Error Count
	ReturnBusExceptionErrorCount = 0x0D, // Return Bus Exception Error Count
	ReturnSlaveMessageCount = 0x0E, // Return Slave Message Count
	ReturnSlaveNoResponseCount = 0x0F, // Return Slave No Response Count
	ReturnSlaveNakCount = 0x10, // Return Slave NAK Count
	ReturnSlaveBusyCount = 0x11, // Return Slave Busy Count
	ReturnBusCharacterOverrunCount = 0x12, // Return Bus Character Overrun Count
	ClearOverrunCounterAndFlag = 0x14, // Clear Overrun Counter and Flag
}

enum FunctionCode_MEI : ubyte
{
	CanOpenGeneralReferenceRequestAndResponsePDU = 0x0D,
	ReadDeviceIdentification = 0x0E,
}

enum FunctionCodeName(FunctionCode code) = getFunctionCodeName(code);

enum ExceptionCode : ubyte
{
	None = 0,
	IllegalFunction = 0x01, // The function code received in the query is not an allowable action for the slave
	IllegalDataAddress = 0x02, // The data address received in the query is not an allowable address for the slave
	IllegalDataValue = 0x03, // A value contained in the query data field is not an allowable value for the slave
	SlaveDeviceFailure = 0x04, // An unrecoverable error occurred while the slave was attempting to perform the requested action
	Acknowledge = 0x05, // The slave has accepted the request and is processing it, but a long duration of time is required
	SlaveDeviceBusy = 0x06, // The slave is engaged in processing a long–duration command. The master should retry later
	NegativeAcknowledge = 0x07, // The slave cannot perform the program function received in the query
	MemoryParityError = 0x08, // The slave detected a parity error in memory. The master can retry the request, but service may be required on the slave device
	GatewayPathUnavailable = 0x0A, // Specialized for Modbus gateways. Indicates a misconfigured gateway
	GatewayTargetDeviceFailedToRespond = 0x0B, // Specialized for Modbus gateways. Sent when slave fails to respond
}

enum ModbusProtocol : byte
{
	Unknown = -1,
	None = 0,
	RTU,
	ASCII,
	TCP
}

enum RequestType : byte
{
	Unknown = -1,
	Request = 0,
	Response
}

struct ModbusPDU
{
	this(FunctionCode functionCode, const(ubyte)[] data)
	{
		this.functionCode = functionCode;
		this.buffer[0 .. data.length] = data[];
		this.length = cast(ushort)data.length;
	}

	FunctionCode functionCode;
	ubyte[ModbusMessageDataMaxLength] buffer;
	ushort length;
	inout(ubyte)[] data() inout { return buffer[0..length]; }

	string toString() const
	{
		import std.format, std.digest;
		if (functionCode & 0x80)
			return format("exception: %d(%s) - %s", data[0], getFunctionCodeName(cast(FunctionCode)(functionCode & 0x7F)), getExceptionCodeString(cast(ExceptionCode)data[0]));
		return format("%s: %s", getFunctionCodeName(functionCode), data.toHexString);
	}
}

align(2) struct ModbusFrame
{
	ModbusProtocol protocol = ModbusProtocol.None;
	ubyte address;
	union
	{
		RTU rtu;
		TCP tcp;
	}

	struct RTU
	{
		ushort crc;
	}
	struct TCP
	{
		ushort transactionId;
		enum ushort protocolId = 0; // alwayus 0 (make this a variable if this is ever discovered to be not true
		ushort length;
	}

	string toString() const
	{
		import std.format;
		if (protocol == ModbusProtocol.RTU)
			return format("rtu(%d)", address);
		else if (protocol == ModbusProtocol.TCP)
			return format("tcp(%d, tx%d)", address, tcp.transactionId);
		else if (protocol == ModbusProtocol.None)
			return format("(%d)", address);
		assert(0);
	}
}

string getFunctionCodeName(FunctionCode functionCode)
{
	__gshared immutable string[FunctionCode.ReadFIFOQueue] functionCodeName = [
		"ReadCoils", "ReadDiscreteInputs", "ReadHoldingRegisters", "ReadInputRegisters", "WriteSingleCoil",
		"WriteSingleRegister", "ReadExceptionStatus", "Diagnostics", null, null, "GetComEventCounter", "GetComEventLog",
		null, null, "WriteMultipleCoils", "WriteMultipleRegisters", "ReportServerID", null, null, "ReadFileRecord",
		"WriteFileRecord", "MaskWriteRegister", "ReadAndWriteMultipleRegisters", "ReadFIFOQueue" ];

	if (--functionCode < FunctionCode.ReadFIFOQueue)
		return functionCodeName[functionCode];
	if (functionCode == FunctionCode.MEI - 1)
		return "MEI";
	return null;
}

string getExceptionCodeString(ExceptionCode exceptionCode)
{
	__gshared immutable string[ExceptionCode.GatewayTargetDeviceFailedToRespond] exceptionCodeName = [
		"IllegalFunction", "IllegalDataAddress", "IllegalDataValue", "SlaveDeviceFailure", "Acknowledge",
		"SlaveDeviceBusy", "NegativeAcknowledge", "MemoryParityError", "GatewayPathUnavailable", "GatewayTargetDeviceFailedToRespond" ];

	if (--exceptionCode < ExceptionCode.GatewayTargetDeviceFailedToRespond)
		return exceptionCodeName[exceptionCode];
	return null;
}

ModbusProtocol guessProtocol(const(ubyte)[] data)
{
	// TODO: modbus ascii?

	if (data.length < 4)
		return ModbusProtocol.Unknown;
	if (data.guessTCP())
		return ModbusProtocol.TCP;
	if (crawlForRTU(data) != null)
		return ModbusProtocol.RTU;
	return ModbusProtocol.Unknown;
}

ptrdiff_t getMessage(const(ubyte)[] data, out ModbusPDU msg, ModbusFrame* frame = null, ModbusProtocol protocol = ModbusProtocol.Unknown)
{
	ModbusFrame tFrame;
	if (!frame)
		frame = &tFrame;

	if (protocol == ModbusProtocol.TCP || (protocol == ModbusProtocol.Unknown && data.guessTCP()))
	{
		if (data.length < 8)
			return 0;

		frame.protocol = ModbusProtocol.TCP;
		frame.tcp.transactionId = data[0..2].bigEndianToNative!ushort;
		frame.tcp.length = data[4..6].bigEndianToNative!ushort;
		frame.address = data[6];

		if (data[2..4].bigEndianToNative!ushort != 0 ||
			frame.tcp.length < 2 || frame.tcp.length > ModbusMessageDataMaxLength + 2)
			return -1; // invalid frame
		if (6 + frame.tcp.length < data.length)
			return 0; // not enough data

		msg.functionCode = cast(FunctionCode)data[7];
		if (!msg.functionCode.validFunctionCode())
			return -1;

		msg.length = cast(short)(frame.tcp.length - 2);
		msg.buffer[0 .. msg.length] = data[8 .. 8 + msg.length];
		msg.buffer[msg.length .. $] = 0;

		return 6 + frame.tcp.length;
	}

	// TODO: if protocol is ASCII...

	if (data.length < 2)
		return 0;
	FunctionCode functionCode = cast(FunctionCode)data[1];
	if (!functionCode.validFunctionCode())
		return -1;
	if (data[0] > 247) // TODO: we can check if the address has ever been seen on this bus before... (except the first few messages)
		return -1;
	if (data.length < 4)
		return 0;

	ushort crc;
	const(ubyte)[] rtuPacket = data.crawlForRTU(&crc);
	if (!rtuPacket)
		return 0;

	frame.protocol = ModbusProtocol.RTU;
	frame.address = data[0];
	frame.rtu.crc = crc;

	msg.functionCode = functionCode;
	msg.length = cast(short)(rtuPacket.length - 4);
	if (msg.length > msg.buffer.length)
		return -1;

	msg.buffer[0 .. msg.length] = rtuPacket[2 .. $-2];
	msg.buffer[msg.length .. $] = 0;

	return rtuPacket.length;
}

ubyte[] frameRTUMessage(ubyte address, FunctionCode functionCode, const(ubyte)[] data, ubyte[] buffer = null)
{
	ubyte[] result;
	if (buffer.length >= data.length + 4)
		result = buffer[0 .. data.length + 4];
	else
		result = new ubyte[data.length + 4];

	result[0] = address;
	result[1] = functionCode;
	result[2..$-2] = data[];
	result[$-2..$][0..2] = result[0..$-2].calculateModbusCRC.nativeToLittleEndian;
	return result;
}

ubyte[] frameTCPMessage(ushort transactionId, ubyte unitId, FunctionCode functionCode, const(ubyte)[] data, ubyte[] buffer = null)
{
	ubyte[] result;
	if (buffer.length >= data.length + 8)
		result = buffer[0 .. data.length + 8];
	else
		result = new ubyte[data.length + 8];

	result[0..2] = transactionId.nativeToBigEndian;
	result[2..4] = 0;
	result[4..6] = (cast(ushort)(data.length + 2)).nativeToBigEndian;
	result[6] = unitId;
	result[7] = functionCode;
	result[8..$] = data[];
	return result;
}

ModbusPDU createMessage_Read(RegisterType type, ushort register, ushort registerCount = 1)
{
	ModbusPDU pdu;

	immutable FunctionCode[] codeForRegType = [
		FunctionCode.ReadCoils,
		FunctionCode.ReadDiscreteInputs,
		FunctionCode.ReadInputRegisters,
		FunctionCode.ReadHoldingRegisters
	];

	pdu.functionCode = codeForRegType[type];
	pdu.buffer[0..2] = register.nativeToBigEndian;
	pdu.buffer[2..4] = registerCount.nativeToBigEndian;
	pdu.length = 4;
	return pdu;
}

ModbusPDU createMessage_Write(RegisterType type, ushort register, ushort value)
{
	return createMessage_Write(type, register, (&value)[0..1]);
}

ModbusPDU createMessage_Write(RegisterType type, ushort register, ushort[] values)
{
	ModbusPDU pdu;

	if (type == RegisterType.Coil)
	{
		pdu.buffer[0..2] = register.nativeToBigEndian;

		if (values.length == 1)
		{
			pdu.functionCode = FunctionCode.WriteSingleCoil;
			pdu.buffer[2..4] = (cast(ushort)(values[0] ? 0xFF00 : 0x0000)).nativeToBigEndian;
			pdu.length = 4;
		}
		else
		{
			assert(values.length <= 1976, "Exceeded maximum modbus coils for a single write (1976)");

			pdu.functionCode = FunctionCode.WriteMultipleCoils;
			pdu.buffer[2..4] = (cast(ushort)values.length).nativeToBigEndian;
			pdu.buffer[4] = cast(ubyte)(values.length + 7) / 8;
			pdu.length = 5 + pdu.buffer[4];
			pdu.buffer[5 .. 5 + pdu.buffer[4]] = 0;
			for (size_t i = 0; i < values.length; ++i)
				pdu.buffer[5 + i/8] |= (values[i] ? 1 : 0) << (i % 8);
		}
	}
	else if (type == RegisterType.HoldingRegister)
	{
		pdu.buffer[0..2] = register.nativeToBigEndian;

		if (values.length == 1)
		{
			pdu.functionCode = FunctionCode.WriteSingleRegister;
			pdu.buffer[2..4] = values[0].nativeToBigEndian;
			pdu.length = 4;
		}
		else
		{
			assert(values.length <= 123, "Exceeded maximum modbus registers for a single write (123)");

			pdu.functionCode = FunctionCode.WriteMultipleRegisters;
			pdu.buffer[2..4] = (cast(ushort)values.length).nativeToBigEndian;
			pdu.buffer[4] = cast(ubyte)(values.length * 2);
			pdu.length = 5 + pdu.buffer[4];
			for (size_t i = 0; i < values.length; ++i)
				pdu.buffer[5 + i*2 .. 7 + i*2][0..2] = values[i].nativeToBigEndian;
		}
	}
	else
		assert(0);

	return pdu;
}

ModbusPDU createMessage_GetDeviceInformation()
{
	ModbusPDU pdu;
	pdu.functionCode = FunctionCode.MEI;
	pdu.buffer[0] = FunctionCode_MEI.ReadDeviceIdentification;
	pdu.buffer[1] = 0x01;
	pdu.buffer[2] = 0x00;
	pdu.length = 3;
	return pdu;
}


private:

inout(ubyte)[] parseRTU(inout(ubyte)[] data, ushort* rcrc = null)
{
	if (data.length < 4)
		return null;

	ushort crc = calculateModbusCRC(data[0 .. $-2]);
	if (crc == data[$-2..$][0..2].littleEndianToNative!ushort)
	{
		if (rcrc)
			*rcrc = crc;
		return data[0 .. $-2];
	}
	return null;
}

inout(ubyte)[] crawlForRTU(inout(ubyte)[] data, ushort* rcrc = null)
{
	if (data.length < 4)
		return null;

	enum NumCRC = 8;
	ushort[NumCRC] foundCRC;
	size_t[NumCRC] foundCRCPos;
	int numfoundCRC = 0;

	// crawl through the buffer accumulating a CRC and looking for the following bytes to match
	ushort crc = 0xFFFF;
	ushort next = data[0] | cast(ushort)data[1] << 8;
	size_t len = data.length < 256 ? data.length : 256;
	for (size_t pos = 2; pos < len; )
	{
		ubyte index = (next & 0xFF) ^ cast(ubyte)crc;
		crc = (crc >> 8) ^ crc_table[index];

		// get the next word in sequence
		next = next >> 8 | cast(ushort)data[pos++] << 8;

		// if the running CRC matches the next word, we probably have an RTU packet delimiter
		if (crc == next)
		{
			foundCRC[numfoundCRC] = crc;
			foundCRCPos[numfoundCRC++] = pos;
			if (numfoundCRC == NumCRC)
				break;
		}
	}

	if (numfoundCRC > 0)
	{
		int bestMatch = 0;

		if (numfoundCRC > 1)
		{
			// if we matched multiple CRC's in the buffer, then we need to work out which CRC is not a false-positive...
			int[NumCRC] score;
			for (int i = 0; i < numfoundCRC; ++i)
			{
				// if the CRC is at the end of the buffer, we have a single complete message, and that's a really good indicator
				if (foundCRCPos[i] == data.length)
					score[i] += 10;
				else if (foundCRCPos[i] <= data.length - 2)
				{
					// we can check the bytes following the CRC appear to begin a new message...
					// confirm the function code is valid
					if (validFunctionCode(cast(FunctionCode)data[foundCRCPos[i] + 1]))
						score[i] += 5;
					// we can also give a nudge if the address looks plausible
					ubyte addr = data[foundCRCPos[i]];
					if (addr >= 1 && addr <= 247)
					{
						if (addr <= 4 || addr >= 245)
							score[i] += 2; // very small or very big addresses are more likely
						else
							score[i] += 1;
					}
				}
			}
			for (int i = 1; i < numfoundCRC; ++i)
			{
				if (score[i] > score[i - 1])
					bestMatch = i;
			}
		}

		if (rcrc)
			*rcrc = foundCRC[bestMatch];
		return data[0 .. foundCRCPos[bestMatch]];
	}

	// didn't find anything...
	return null;
}

bool guessTCP(const(ubyte)[] data)
{
	if (data.length < 8)
		return false;

	// TODO: we could increase confidence by checking the function code is valid...

	ushort protoId = data[2..4].bigEndianToNative!ushort;
	ushort length = data[4..6].bigEndianToNative!ushort;
	if (protoId == 0 && length >= 2 && length <= ModbusMessageDataMaxLength + 2) // check the length is valid
	{
		// if the length matches the buffer size, it's a good bet!
		if (data.length == 6 + length)
			return true;

		// if there's additional bytes, we may have multiple packets in sequence...
		if (data.length >= 6 + length + 6)
		{
			// if the following bytes look like the start of another tcp packet, we'll go with it
			protoId = data[6 + length + 2 .. 6 + length + 4][0..2].bigEndianToNative!ushort;
			length = data[6 + length + 4 .. 6 + length + 6][0..2].bigEndianToNative!ushort;
			if (protoId == 0 && length >= 2 && length <= ModbusPDU.sizeof + 1)
				return true;
		}
	}

	return false;
}
