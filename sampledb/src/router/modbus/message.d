module router.modbus.message;

import router.modbus.util;

enum ModbusMessageDataMaxLength = 252;

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
    GetComEventCounter = 0x0B, // Get the status of the communication event counter in the slave
    GetComEventLog = 0x0C, // Retrieve the slave's communication event log
    WriteMultipleCoils = 0x0F, // Write multiple coils in a slave device
    WriteMultipleRegisters = 0x10, // Write multiple registers in a slave device
    ReportServerID = 0x11, // Request the unique identifier of a slave
    ReadFileRecord = 0x14, // Read the contents of a file record in the slave
    WriteFileRecord = 0x15, // Write to a file record in the slave
    MaskWriteRegister = 0x16, // Modify the contents of a register using a combination of AND and OR
    ReadAndWriteMultipleRegisters = 0x17, // Read and write multiple registers in a single transaction
    ReadFIFOQueue = 0x18, // Read from a FIFO queue of registers in the slave
    Extension = 0x2B // Read Device Identification / Encapsulated Interface Transport
}

enum FunctionCodeName(FunctionCode code) = getFunctionCodeName(code);

enum Protocol : byte
{
    Unknown = -1,
    RTU = 0,
    TCP
}

struct ModbusPDU
{
    FunctionCode functionCode;
    ubyte[ModbusMessageDataMaxLength] buffer;
    ushort length;
    inout(ubyte)[] data() inout { return buffer[0..length]; }

    string toString() const
	{
        import std.format, std.digest;
        return format("%s: %s", getFunctionCodeName(functionCode), data.toHexString);
	}
}

align(2) struct ModbusFrame
{
	Protocol protocol;
	union
	{
		RTU rtu;
		TCP tcp;
	}

    struct RTU
	{
        ubyte address;
        align(1) ushort crc;
	}
    struct TCP
	{
        ubyte unitId;
        align(1) ushort transactionId;
        enum ushort protocolId = 0; // alwayus 0 (make this a variable if this is ever discovered to be not true
        align(1) ushort length;
	}

    string toString() const
	{
        import std.format;
        if (protocol == Protocol.RTU)
            return format("rtu(%d)", rtu.address);
        else if (protocol == Protocol.TCP)
            return format("tcp(%d, tx%d)", tcp.unitId, tcp.transactionId);
        assert(0);
	}
}

struct ModbusMessage
{
    ModbusFrame frame;
    ModbusPDU message;
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
    if (functionCode == FunctionCode.Extension - 1)
        return "Extension";
    return null;
}

Protocol guessProtocol(const(ubyte)[] data)
{
    // TODO: modbus ascii?

    if (data.length < 4)
        return Protocol.Unknown;
    if (data.guessTCP())
        return Protocol.TCP;
    if (crawlForRTU(data) != null)
        return Protocol.RTU;
	return Protocol.Unknown;
}

ptrdiff_t getMessage(const(ubyte)[] data, out ModbusMessage msg, Protocol protocol = Protocol.Unknown)
{
    if (protocol == Protocol.TCP || (protocol == Protocol.Unknown && data.guessTCP()))
	{
        msg.frame.protocol = Protocol.TCP;
        msg.frame.tcp.transactionId = data[0..2].bigEndianToNative!ushort;
        msg.frame.tcp.length = data[4..6].bigEndianToNative!ushort;
        msg.frame.tcp.unitId = data[6];

		if (data[2..4].bigEndianToNative!ushort != 0 ||
			msg.frame.tcp.length < 2 || msg.frame.tcp.length > ModbusMessageDataMaxLength + 2)
            return -1; // invalid frame
        if (6 + msg.frame.tcp.length < data.length)
            return 0; // not enough data

        msg.message.functionCode = cast(FunctionCode)data[7];
        if (!msg.message.functionCode.validFunctionCode())
            return -1;

        msg.message.length = cast(short)(msg.frame.tcp.length - 2);
        msg.message.buffer[0 .. msg.message.length] = data[8 .. 8 + msg.message.length];
        msg.message.buffer[msg.message.length .. $] = 0;

        return 6 + msg.frame.tcp.length;
	}

    // TODO: if protocol is ASCII...

    ushort crc;
    const(ubyte)[] rtuPacket = data.crawlForRTU(&crc);
    if (!rtuPacket)
        return 0;

    msg.frame.protocol = Protocol.RTU;
    msg.frame.rtu.address = data[0];
    msg.frame.rtu.crc = crc;

	msg.message.functionCode = cast(FunctionCode)data[1];
	if (!msg.message.functionCode.validFunctionCode())
		return -1;

	msg.message.length = cast(short)(rtuPacket.length - 4);
	msg.message.buffer[0 .. msg.message.length] = rtuPacket[2 .. $-2];
	msg.message.buffer[msg.message.length .. $] = 0;

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

private:

inout(ubyte)[] crawlForRTU(inout(ubyte)[] data, ushort* rcrc = null)
{
	// crawl through the buffer accumulating a CRC and looking for the following bytes to match
	ushort crc = 0xFFFF;
    ushort next = data[0] | cast(ushort)data[1] << 8;
	for (size_t pos = 0; pos < data.length - 2; ++pos)
	{
        // massage in the next byte
		crc ^= next & 0xFF;
		for (int i = 8; i != 0; i--)
		{
			if ((crc & 0x0001) != 0)
			{
				crc >>= 1;
				crc ^= 0xA001;
			}
			else
				crc >>= 1;
		}

        // get the next word in sequence
        next = next >> 8 | cast(ushort)data[pos + 2] << 8;

        // if the running CRC matches the next word, we probably have an RTU packet delimiter
        if (crc == next)
		{
            // TODO: should we check the function code is valid?

            if (rcrc)
                *rcrc = crc;
            return data[0 .. pos + 3];
		}
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
			return Protocol.TCP;

		// if there's additional bytes, we may have multiple packets in sequence...
		if (data.length >= 6 + length + 6)
		{
			// if the following bytes look like the start of another tcp packet, we'll go with it
			protoId = data[6 + length + 2 .. 6 + length + 4][0..2].bigEndianToNative!ushort;
			length = data[6 + length + 4 .. 6 + length + 6][0..2].bigEndianToNative!ushort;
            if (protoId == 0 && length >= 2 && length <= ModbusPDU.sizeof + 1)
                return Protocol.TCP;
		}
	}

	return false;
}
