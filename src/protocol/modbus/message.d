module protocol.modbus.message;

import urt.endian;


enum ModbusMessageDataMaxLength = 252;

enum RegisterType : ubyte
{
    Invalid = cast(ubyte)-1,
    Coil = 0,
    DiscreteInput = 1,
    InputRegister = 3,
    HoldingRegister = 4
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
    _Undefined = 0x09,
    GatewayPathUnavailable = 0x0A, // Specialized for Modbus gateways. Indicates a misconfigured gateway
    GatewayTargetDeviceFailedToRespond = 0x0B, // Specialized for Modbus gateways. Sent when slave fails to respond
}


struct ModbusPDU
{
nothrow @nogc:
    FunctionCode functionCode;

    this(FunctionCode functionCode, const(ubyte)[] data)
    {
        assert(data.length <= ModbusMessageDataMaxLength);
        this.functionCode = functionCode;
        this.buffer[0 .. data.length] = data[];
        this.length = cast(ubyte)data.length;
    }

    inout(ubyte)[] data() inout
        => buffer[0..length];

    const(char)[] toString() const
    {
        import urt.string.format;
        if (functionCode & 0x80)
            return tformat("exception: {0}({1}) - {2}", data[0], getFunctionCodeName(cast(FunctionCode)(functionCode & 0x7F)), getExceptionCodeString(cast(ExceptionCode)data[0]));
        return tformat("{0}: {1}", getFunctionCodeName(functionCode), cast(void[])data);
    }

private:
    ubyte[ModbusMessageDataMaxLength] buffer;
    ubyte length;
}


string getFunctionCodeName(FunctionCode functionCode) nothrow @nogc
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

string getExceptionCodeString(ExceptionCode exceptionCode) nothrow @nogc
{
    __gshared immutable string[ExceptionCode.GatewayTargetDeviceFailedToRespond] exceptionCodeName = [
        "IllegalFunction", "IllegalDataAddress", "IllegalDataValue", "SlaveDeviceFailure", "Acknowledge",
        "SlaveDeviceBusy", "NegativeAcknowledge", "MemoryParityError", "GatewayPathUnavailable", "GatewayTargetDeviceFailedToRespond" ];

    if (--exceptionCode < ExceptionCode.GatewayTargetDeviceFailedToRespond)
        return exceptionCodeName[exceptionCode];
    return null;
}


ModbusPDU createMessage_Read(RegisterType type, ushort register, ushort registerCount = 1) nothrow @nogc
{
    ModbusPDU pdu;

    __gshared immutable FunctionCode[5] codeForRegType = [
        FunctionCode.ReadCoils,
        FunctionCode.ReadDiscreteInputs,
        cast(FunctionCode)0,
        FunctionCode.ReadInputRegisters,
        FunctionCode.ReadHoldingRegisters
    ];

    pdu.functionCode = codeForRegType[type];
    pdu.buffer[0..2] = register.nativeToBigEndian;
    pdu.buffer[2..4] = registerCount.nativeToBigEndian;
    pdu.length = 4;
    return pdu;
}

ModbusPDU createMessage_Write(RegisterType type, ushort register, ushort value) nothrow @nogc
{
    return createMessage_Write(type, register, (&value)[0..1]);
}

ModbusPDU createMessage_Write(RegisterType type, ushort register, ushort[] values) nothrow @nogc
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
            pdu.length = cast(ubyte)(5 + pdu.buffer[4]);
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
            pdu.length = cast(ubyte)(5 + pdu.buffer[4]);
            for (size_t i = 0; i < values.length; ++i)
                pdu.buffer[5 + i*2 .. 7 + i*2][0..2] = values[i].nativeToBigEndian;
        }
    }
    else
        assert(0);

    return pdu;
}

ModbusPDU createMessage_GetDeviceInformation() nothrow @nogc
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
