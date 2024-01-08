module router.modbus.util;

import router.modbus.message : FunctionCode;

ushort bigEndianToNative(T)(ref const ubyte[2] bytes)
	if (is(T == ushort))
{
    return cast(ushort)bytes[0] << 8 | bytes[1];
}
ushort littleEndianToNative(T)(ref const ubyte[2] bytes)
	if (is(T == ushort))
{
    return bytes[0] | cast(ushort)bytes[1] << 8;
}


ubyte[2] nativeToBigEndian(ushort u16)
{
	ubyte[2] res = [ u16 >> 8, u16 & 0xFF ];
	return res;
}
ubyte[2] nativeToLittleEndian(ushort u16)
{
	ubyte[2] res = [ u16 & 0xFF, u16 >> 8 ];
	return res;
}


ushort calculateModbusCRC(const ubyte[] buf)
{
	ushort crc = 0xFFFF;
	for (size_t pos = 0; pos < buf.length; ++pos)
	{
		crc ^= buf[pos];                // XOR byte into least sig. byte of crc
		for (int i = 8; i != 0; i--)    // Loop over each bit
		{
			if ((crc & 0x0001) != 0)    // If the LSB is set
			{
				crc >>= 1;              // Shift right and XOR 0xA001
				crc ^= 0xA001;
			}
			else                        // Else LSB is not set
				crc >>= 1;              // Just shift right
		}
	}
	return crc;
}

bool validFunctionCode(FunctionCode functionCode)
{
	enum validCodes = 0b1111100111001100111111110;
	if ((1 << functionCode) & validCodes)
		return true;
	return functionCode == FunctionCode.Extension;
}
