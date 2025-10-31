module protocol.modbus;

import urt.endian;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;
import manager.profile;
import manager.sampler;

import protocol.modbus.client;
import protocol.modbus.message;
import protocol.modbus.sampler;

import router.iface;
import router.iface.modbus;


class ModbusProtocolModule : Module
{
    mixin DeclareModule!"protocol.modbus";
nothrow @nogc:

    Map!(const(char)[], ModbusClient) clients;

    override void init()
    {
        g_app.console.register_command!client_add("/protocol/modbus/client", this, "add");
        g_app.console.register_command!device_add("/protocol/modbus/device", this, "add");
        g_app.console.register_command!request_raw("/protocol/modbus/client/request", this, "raw");
        g_app.console.register_command!request_read("/protocol/modbus/client/request", this, "read");
        g_app.console.register_command!request_write("/protocol/modbus/client/request", this, "write");
        g_app.console.register_command!request_read_device_id("/protocol/modbus/client/request", this, "read-device-id");
    }

    override void update()
    {
        foreach(client; clients.values)
            client.update();
    }

    void client_add(Session session, const(char)[] name, BaseInterface _interface, Nullable!bool snoop)
    {
        // TODO: generate name if not supplied
        String n = name.makeString(g_app.allocator);

        ModbusClient client = g_app.allocator.allocT!ModbusClient(this, n.move, _interface, snoop ? snoop.value : false);
        clients[client.name[]] = client;
    }

    void device_add(Session session, const(char)[] id, const(char)[] _client, const(char)[] slave, Nullable!(const(char)[]) name, Nullable!(const(char)[]) _profile)
    {
        import manager.component;
        import manager.device;
        import manager.element;
        import urt.file;
        import urt.si;
        import urt.string.format;

        ServerMap* map;
        ModbusClient client = lookupClientAndSlave(session, _client, slave, map);
        if (!client)
            return;

        MACAddress target;
        const(char)[] profileName;
        if (map)
        {
            if (!map.profile)
            {
                session.write_line("Slave '", slave, "' doesn't have a profile specified");
                return;
            }
            target = map.mac;
            profileName = map.profile;
        }
        else
        {
            if (target.fromString(slave) != slave.length)
            {
                session.write_line("Invalid slave identifier or address '", slave, "'");
                return;
            }
            if (!_profile)
            {
                session.write_line("No profile specified");
                return;
            }
            profileName = _profile.value;
        }

        void[] file = load_file(tconcat("conf/modbus_profiles/", profileName, ".conf"), g_app.allocator);
        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);

        // create a sampler for this modbus server...
        ModbusSampler sampler = g_app.allocator.allocT!ModbusSampler(client, target);

        Device device = create_device_from_profile(*profile, null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            assert(desc.type == ElementType.modbus);
            ref const ElementDesc_Modbus mb = profile.get_mb(desc.element);

            // write a null value of the proper type
            ubyte[256] tmp = void;
            tmp[0 .. mb.value_desc.data_length] = 0;
            e.value = sample_value(tmp.ptr, mb.value_desc);

            // record samper data...
            sampler.add_element(e, desc, mb);
            device.sample_elements ~= e; // TODO: remove this?
        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            return;
        }
        device.samplers ~= sampler;
    }

    ModbusRequestState sendRequest(Session session, const(char)[] client, const(char)[] slave, ref ModbusPDU msg)
    {
        MACAddress addr;
        ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
        if (!c)
            return null;

        ModbusRequestState state = g_app.allocator.allocT!ModbusRequestState(session, slave);
        c.sendRequest(addr, msg, &state.response_handler, &state.error_handler);

        return state;
    }

    ModbusRequestState request_raw(Session session, const(char)[] client, const(char)[] slave, ubyte[] message)
    {
        if (message.length == 0)
        {
            session.write_line("Message must contain at least one byte (function code).");
            return null;
        }
        ModbusPDU msg = ModbusPDU(cast(FunctionCode)message[0], message[1..$]);
        return sendRequest(session, client, slave, msg);
    }

    ModbusRequestState request_read(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort register, Nullable!ushort count, Nullable!(const(char)[]) data_type)
    {
        RegisterType ty = parseRegisterType(reg_type);
        if (ty == RegisterType.invalid)
        {
            session.write_line("Invalid register type '", reg_type, "'");
            return null;
        }

        ModbusPDU msg = createMessage_Read(ty, register, count ? count.value : 1);
        return sendRequest(session, client, slave, msg);
    }

    ModbusRequestState request_write(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort register, Nullable!ushort value, Nullable!(ushort[]) values)
    {
        if (!value && !values)
        {
            session.write_line("No `value` or `values` specified for write request");
            return null;
        }

        RegisterType ty = parseRegisterType(reg_type);
        if (ty == RegisterType.invalid)
        {
            session.write_line("Invalid register type '", reg_type, "'");
            return null;
        }

        ModbusPDU msg = createMessage_Write(ty, register, values ? values.value : (&value.value)[0..1]);
        return sendRequest(session, client, slave, msg);
    }

    ModbusRequestState request_read_device_id(Session session, const(char)[] client, const(char)[] slave)
    {
        MACAddress addr;
        ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
        if (!c)
            return null;

        ModbusRequestState state = g_app.allocator.allocT!ModbusRequestState(session, slave);

        ModbusPDU msg = createMessage_GetDeviceInformation();
        c.sendRequest(addr, msg, &state.response_handler, &state.error_handler);

        return state;
    }

    ModbusClient lookupClientAndSlave(Session session, const(char)[] client, const(char)[] slave, out ServerMap* map)
    {
        auto c = client in clients;
        if(c is null)
        {
            session.write_line("Client '", client, "' doesn't exist");
            return null;
        }

        // TODO: this should be a global MAC->name table, not a modbus specific table...
        map = get_module!ModbusInterfaceModule.find_server_by_name(slave);
        if (!map)
        {
            MACAddress addr;
            if (addr.fromString(slave))
                map = get_module!ModbusInterfaceModule.find_server_by_mac(addr);
        }

        return *c;
    }

    ModbusClient lookupClientAndMAC(Session session, const(char)[] client, const(char)[] slave, out MACAddress addr)
    {
        ServerMap* map;
        ModbusClient c = lookupClientAndSlave(session, client, slave, map);
        if (c)
        {
            if (map)
                addr = map.mac;
            else if (addr.fromString(slave) != slave.length)
            {
                session.write_line("Invalid slave identifier or address '", slave, "'");
                return null;
            }
        }
        return c;
    }

    RegisterType parseRegisterType(const(char)[] type)
    {
        switch(type)
        {
            case "0":
            case "coil":
                return RegisterType.coil;
            case "1":
            case "discrete":
                return RegisterType.discrete_input;
            case "3":
            case "input":
                return RegisterType.input_register;
            case "4":
            case "holding":
                return RegisterType.holding_register;
            default:
                return RegisterType.invalid;
        }
    }
}


class ModbusRequestState : FunctionCommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;

    String slave;

    this(Session session, const(char)[] slave)
    {
        super(session);
        this.slave = slave.makeString(defaultAllocator);
    }

    override CommandCompletionState update()
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

        return state;
    }

    override void request_cancel()
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...
    }

    void response_handler(ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time)
    {
        if (response.function_code & 0x80)
        {
            import urt.meta : enum_key_from_value;
            session.write_line("Exception response from ", slave[], ", code: ", enum_key_from_value!ExceptionCode(response.data[0]));
        }
        else
        {
            session.write_line("Response from ", slave[], " in ", (response_time - request_time).as!"msecs", "ms: ", toHexString(response.data));
            switch (response.function_code)
            {
                case FunctionCode.read_coils:
                case FunctionCode.read_discrete_inputs:
                case FunctionCode.read_input_registers:
                case FunctionCode.read_holding_registers:
                    ubyte byteCount = response.data[0];
                    ushort first = request.data[0..2].bigEndianToNative!ushort;
                    ushort count = request.data[2..4].bigEndianToNative!ushort;
                    switch (response.function_code)
                    {
                        case FunctionCode.read_coils:
                        case FunctionCode.read_discrete_inputs:
                            if (byteCount * 8 < count)
                            {
                                session.write_line("Invalid byte count in response...");
                                break;
                            }
                            for (ushort i = 0; i < count; i++)
                            {
                                bool value = (response.data[1 + i / 8] & (1 << (i % 8))) != 0;
                                session.write_line("  ", first + i, ": ", value ? "ON" : "OFF");
                            }
                            break;
                        case FunctionCode.read_input_registers:
                        case FunctionCode.read_holding_registers:
                            if (byteCount != count * 2)
                            {
                                session.write_line("Invalid byte count in response...");
                                break;
                            }
                            if (count == 2)
                            {
                                uint value = response.data[1 .. 5].bigEndianToNative!uint;
                                session.writef("  {0}: {1, 04x}_{2, 04x} (i: {3}, f: {4})\n", first, value >> 16, value & 0xFFFF, int(value), *cast(float*)&value);
                            }
                            else
                            {
                                for (ushort i = 0; i < count; i++)
                                {
                                    uint offset = 1 + i*2;
                                    ushort value = response.data[offset .. offset + 2][0..2].bigEndianToNative!ushort;
                                    session.writef("  {0}: {1, 04x} ({2})\n", first + i, value, value);
                                }
                            }
                            break;
                        default:
                            assert(0); // unreachable
                    }
                    break;
                case FunctionCode.write_single_coil:
                case FunctionCode.write_single_register:
                    ushort reg = request.data[0..2].bigEndianToNative!ushort;
                    ushort value = request.data[2..4].bigEndianToNative!ushort;
                    session.writef("  {0}: {1, 04x} ({2})\n", reg, value, value);
                    break;
                case FunctionCode.write_multiple_coils:
                case FunctionCode.write_multiple_registers:
                    assert(false, "TODO: pretty-print the output?");
//                    session.write_line("Starting register: ", toHexString(response.data[0..2], 2, 4, "_ "));
//                    session.write_line("Number of registers written: ", toHexString(response.data[2..4], 2, 4, "_ "));
                    break;
                default:
                    break;
            }
        }
        state = CommandCompletionState.finished;
    }

    void error_handler(ModbusErrorType errorType, ref const ModbusPDU request, SysTime request_time)
    {
        Duration reqDuration = getTime() - request_time;
        if (errorType == ModbusErrorType.Timeout)
        {
            session.write_line("Timeout waiting for response from ", slave[], " after ", reqDuration.as!"msecs", "ms");
            state = CommandCompletionState.timeout;
        }
        else if (errorType == ModbusErrorType.Retrying)
            session.write_line("Timeout (", reqDuration.as!"msecs", "ms); retrying...");
        else
            state = CommandCompletionState.error;
    }
}
