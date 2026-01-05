module protocol.modbus.message;

import urt.endian;


enum ModbusMessageDataMaxLength = 252;

enum RegisterType : ubyte
{
    invalid = cast(ubyte)-1,
    coil = 0,
    discrete_input = 1,
    input_register = 3,
    holding_register = 4
}

enum FunctionCode : ubyte
{
    read_coils = 0x01,                        // Read the status of coils in a slave device
    read_discrete_inputs = 0x02,              // Read the status of discrete inputs in a slave
    read_holding_registers = 0x03,            // Read the contents of holding registers in the slave
    read_input_registers = 0x04,              // Read the contents of input registers in the slave
    write_single_coil = 0x05,                 // Write a single coil in the slave
    write_single_register = 0x06,             // Write a single holding register in the slave
    read_exception_status = 0x07,             // Read the contents of eight Exception Status outputs in a slave
    diagnostics = 0x08,                       // Various sub-functions for diagnostics and testing
    program_484 = 0x09,                       // EXOTIC: Program the 484
    poll_484 = 0x0A,                          // EXOTIC: Poll the 484
    get_com_event_counter = 0x0B,             // Get the status of the communication event counter in the slave
    get_com_event_log = 0x0C,                 // Retrieve the slave's communication event log
    program_controller = 0x0D,                // EXOTIC: Program the controller
    poll_controller = 0x0E,                   // EXOTIC: Poll the controller
    write_multiple_coils = 0x0F,              // Write multiple coils in a slave device
    write_multiple_registers = 0x10,          // Write multiple registers in a slave device
    report_server_id = 0x11,                  // Request the unique identifier of a slave
    program_884_m84 = 0x12,                   // EXOTIC: Program the 884 or M84
    reset_comm_link = 0x13,                   // EXOTIC: Reset the communication link
    read_file_record = 0x14,                  // Read the contents of a file record in the slave
    write_file_record = 0x15,                 // Write to a file record in the slave
    mask_write_register = 0x16,               // Modify the contents of a register using a combination of AND and OR
    read_and_write_multiple_registers = 0x17, // Read and write multiple registers in a single transaction
    read_fifo_queue = 0x18,                   // Read from a FIFO queue of registers in the slave
    mei = 0x2B                                // MODBUS Encapsulated Interface (MEI) Transport
}

enum FunctionCode_Diagnostic : ushort
{
    return_query_data = 0x00,                       // Return Query Data
    restart_communications_option = 0x01,           // Restart Communications Option
    return_diagnostic_register = 0x02,              // Return Diagnostic Register
    change_ascii_input_delimiter = 0x03,            // Change ASCII Input Delimiter
    force_listen_only_mode = 0x04,                  // Force Listen Only Mode
    clear_counters_and_diagnostic_register = 0x0A,  // Clear Counters and Diagnostic Register
    return_bus_message_count = 0x0B,                // Return Bus Message Count
    return_bus_communication_error_count = 0x0C,    // Return Bus Communication Error Count
    return_bus_exception_error_count = 0x0D,        // Return Bus Exception Error Count
    return_slave_message_count = 0x0E,              // Return Slave Message Count
    return_slave_no_response_count = 0x0F,          // Return Slave No Response Count
    return_slave_nak_count = 0x10,                  // Return Slave NAK Count
    return_slave_busy_count = 0x11,                 // Return Slave Busy Count
    return_bus_character_overrun_count = 0x12,      // Return Bus Character Overrun Count
    clear_overrun_counter_and_flag = 0x14,          // Clear Overrun Counter and Flag
}

enum FunctionCode_MEI : ubyte
{
    can_open_general_reference_request_and_response_pdu = 0x0D,
    read_device_identification = 0x0E,
}

enum FunctionCodeName(FunctionCode code) = get_function_code_name(code);

enum ExceptionCode : ubyte
{
    none = 0,
    illegal_function = 0x01,            // The function code received in the query is not an allowable action for the slave
    illegal_data_address = 0x02,        // The data address received in the query is not an allowable address for the slave
    illegal_data_value = 0x03,          // A value contained in the query data field is not an allowable value for the slave
    slave_device_failure = 0x04,        // An unrecoverable error occurred while the slave was attempting to perform the requested action
    acknowledge = 0x05,                 // The slave has accepted the request and is processing it, but a long duration of time is required
    slave_device_busy = 0x06,           // The slave is engaged in processing a long–duration command. The master should retry later
    negative_acknowledge = 0x07,        // The slave cannot perform the program function received in the query
    memory_parity_error = 0x08,         // The slave detected a parity error in memory. The master can retry the request, but service may be required on the slave device
    undefined = 0x09,
    gateway_path_unavailable = 0x0A,    // Specialized for Modbus gateways. Indicates a misconfigured gateway
    gateway_target_device_failed_to_respond = 0x0B, // Specialized for Modbus gateways. Sent when slave fails to respond
}


struct ModbusPDU
{
nothrow @nogc:
    FunctionCode function_code;

    this(FunctionCode function_code, const(ubyte)[] data)
    {
        assert(data.length <= ModbusMessageDataMaxLength);
        this.function_code = function_code;
        this.buffer[0 .. data.length] = data[];
        this.length = cast(ubyte)data.length;
    }

    inout(ubyte)[] data() inout
        => buffer[0..length];

    const(char)[] toString() const
    {
        import urt.string.format;
        if (function_code & 0x80)
            return tformat("exception: {0}({1}) - {2}", data[0], get_function_code_name(cast(FunctionCode)(function_code & 0x7F)), get_exception_code_string(cast(ExceptionCode)data[0]));
        return tformat("{0}: {1}", get_function_code_name(function_code), cast(void[])data);
    }

private:
    ubyte[ModbusMessageDataMaxLength] buffer;
    ubyte length;
}


string get_function_code_name(FunctionCode function_code) nothrow @nogc
{
    __gshared immutable string[FunctionCode.read_fifo_queue] function_code_name = [
        "ReadCoils", "ReadDiscreteInputs", "ReadHoldingRegisters", "ReadInputRegisters", "WriteSingleCoil",
        "WriteSingleRegister", "ReadExceptionStatus", "Diagnostics", null, null, "GetComEventCounter", "GetComEventLog",
        null, null, "WriteMultipleCoils", "WriteMultipleRegisters", "ReportServerID", null, null, "ReadFileRecord",
        "WriteFileRecord", "MaskWriteRegister", "ReadAndWriteMultipleRegisters", "ReadFIFOQueue" ];

    if (--function_code < FunctionCode.read_fifo_queue)
        return function_code_name[function_code];
    if (function_code == FunctionCode.mei - 1)
        return "MEI";
    return null;
}

string get_exception_code_string(ExceptionCode exceptionCode) nothrow @nogc
{
    __gshared immutable string[ExceptionCode.gateway_target_device_failed_to_respond] exception_code_name = [
        "IllegalFunction", "IllegalDataAddress", "IllegalDataValue", "SlaveDeviceFailure", "Acknowledge",
        "SlaveDeviceBusy", "NegativeAcknowledge", "MemoryParityError", "GatewayPathUnavailable", "GatewayTargetDeviceFailedToRespond" ];

    if (--exceptionCode < ExceptionCode.gateway_target_device_failed_to_respond)
        return exception_code_name[exceptionCode];
    return null;
}


ModbusPDU createMessage_Read(RegisterType type, ushort register, ushort registerCount = 1) nothrow @nogc
{
    ModbusPDU pdu;

    __gshared immutable FunctionCode[5] code_for_reg_type = [
        FunctionCode.read_coils,
        FunctionCode.read_discrete_inputs,
        cast(FunctionCode)0,
        FunctionCode.read_input_registers,
        FunctionCode.read_holding_registers
    ];

    pdu.function_code = code_for_reg_type[type];
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

    if (type == RegisterType.coil)
    {
        pdu.buffer[0..2] = register.nativeToBigEndian;

        if (values.length == 1)
        {
            pdu.function_code = FunctionCode.write_single_coil;
            pdu.buffer[2..4] = (cast(ushort)(values[0] ? 0xFF00 : 0x0000)).nativeToBigEndian;
            pdu.length = 4;
        }
        else
        {
            assert(values.length <= 1976, "Exceeded maximum modbus coils for a single write (1976)");

            pdu.function_code = FunctionCode.write_multiple_coils;
            pdu.buffer[2..4] = (cast(ushort)values.length).nativeToBigEndian;
            pdu.buffer[4] = cast(ubyte)(values.length + 7) / 8;
            pdu.length = cast(ubyte)(5 + pdu.buffer[4]);
            pdu.buffer[5 .. 5 + pdu.buffer[4]] = 0;
            for (size_t i = 0; i < values.length; ++i)
                pdu.buffer[5 + i/8] |= (values[i] ? 1 : 0) << (i % 8);
        }
    }
    else if (type == RegisterType.holding_register)
    {
        pdu.buffer[0..2] = register.nativeToBigEndian;

        if (values.length == 1)
        {
            pdu.function_code = FunctionCode.write_single_register;
            pdu.buffer[2..4] = values[0].nativeToBigEndian;
            pdu.length = 4;
        }
        else
        {
            assert(values.length <= 123, "Exceeded maximum modbus registers for a single write (123)");

            pdu.function_code = FunctionCode.write_multiple_registers;
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
    pdu.function_code = FunctionCode.mei;
    pdu.buffer[0] = FunctionCode_MEI.read_device_identification;
    pdu.buffer[1] = 0x01;
    pdu.buffer[2] = 0x00;
    pdu.length = 3;
    return pdu;
}


private:
