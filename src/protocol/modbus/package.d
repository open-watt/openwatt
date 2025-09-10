module protocol.modbus;

import urt.endian;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.modbus.client;
import protocol.modbus.sampler;

import router.iface;
import router.iface.modbus;

import router.modbus.message;


class ModbusProtocolModule : Module
{
    mixin DeclareModule!"protocol.modbus";
nothrow @nogc:

    Map!(const(char)[], ModbusClient) clients;

    override void init()
    {
        g_app.console.registerCommand!client_add("/protocol/modbus/client", this, "add");
        g_app.console.registerCommand!device_add("/protocol/modbus/device", this, "add");
        g_app.console.registerCommand!request_raw("/protocol/modbus/client/request", this, "raw");
        g_app.console.registerCommand!request_read("/protocol/modbus/client/request", this, "read");
        g_app.console.registerCommand!request_write("/protocol/modbus/client/request", this, "write");
        g_app.console.registerCommand!request_read_device_id("/protocol/modbus/client/request", this, "read-device-id");
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
        if (id in g_app.devices)
        {
            session.writeLine("Device '", id, "' already exists");
            return;
        }

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
                session.writeLine("Slave '", slave, "' doesn't have a profile specified");
                return;
            }
            target = map.mac;
            profileName = map.profile;
        }
        else
        {
            if (target.fromString(slave) != slave.length)
            {
                session.writeLine("Invalid slave identifier or address '", slave, "'");
                return;
            }
            if (!_profile)
            {
                session.writeLine("No profile specified");
                return;
            }
            profileName = _profile.value;
        }

        import manager.component;
        import manager.device;
        import manager.element;
        import router.modbus.profile;
        import urt.file;
        import urt.string.format;

        void[] file = load_file(tconcat("conf/modbus_profiles/", profileName, ".conf"), g_app.allocator);
        ModbusProfile* profile = parseModbusProfile(cast(char[])file, g_app.allocator);

        // create the device
        Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        if (name)
            device.name = name.value.makeString(g_app.allocator);

        // create a sampler for this modbus server...
        ModbusSampler sampler = g_app.allocator.allocT!ModbusSampler(client, target);
        device.samplers ~= sampler;

        Component createComponent(ref ComponentTemplate ct)
        {
            Component c = g_app.allocator.allocT!Component(ct.id.move);
            c.template_ = ct.template_.move;

            foreach (ref child; ct.components)
            {
                Component childComponent = createComponent(child);
                c.components ~= childComponent;
            }

            foreach (ref el; ct.elements)
            {
                Element* e = g_app.allocator.allocT!Element();
                e.id = el.id.move;

                if (el.value.length > 0)
                {
                    final switch (el.type)
                    {
                        case ElementTemplate.Type.Constant:
                            e.latest.fromString(el.value);
                            break;

                        case ElementTemplate.Type.Map:
                            const(char)[] mapReg = el.value.unQuote;
                            ModbusRegInfo** pReg;
                            if (mapReg.length >= 2 && mapReg[0] == '@')
                                pReg = mapReg[1..$] in profile.regByName;
                            if (!pReg)
                            {
                                session.writeLine("Invalid register specified for element-map '", e.id, "': ", mapReg);
                                g_app.allocator.freeT(e);
                                continue;
                            }

                            // HACK: rework this whole function, it's all old and rubbish
                            import urt.si;
                            ScaledUnit unit;
                            float scale;
                            ptrdiff_t taken = unit.parseUnit((*pReg).units[], scale);
                            if (taken != (*pReg).units.length)
                            {
                                assert(false, "Unit was not parsed correctly...?");
                            }

                            e.access = cast(manager.element.Access)(*pReg).access; // HACK: delete the rh type!

                            // init the value with the proper type and unit if specified...
                            switch ((*pReg).type)
                            {
                                case RecordType.uint16:
                                case RecordType.int16:
                                case RecordType.uint32le:
                                case RecordType.uint32:
                                case RecordType.int32le:
                                case RecordType.int32:
                                case RecordType.uint64le:
                                case RecordType.uint64:
                                case RecordType.int64le:
                                case RecordType.int64:
                                case RecordType.uint8H:
                                case RecordType.uint8L:
                                case RecordType.int8H:
                                case RecordType.int8L:
                                case RecordType.bf16:
                                case RecordType.bf32:
                                case RecordType.bf64:
                                case RecordType.enum16:
                                case RecordType.enum32:
                                    e.value = Quantity!uint(0, unit);
                                    break;
                                case RecordType.exp10:
                                case RecordType.float32le:
                                case RecordType.float32:
                                case RecordType.float64le:
                                case RecordType.float64:
                                case RecordType.enum32_float:
                                    e.value = Quantity!float(0.0, unit);
                                    break;
                                default:
                                    e.value = "";
                                    break;
                            }

                            // TODO: if values are bitfields or enums, we should record the keys...

                            // record samper data...
                            sampler.addElement(e, **pReg);
                            device.sample_elements ~= e; // TODO: remove this?
                            break;
                    }
                }

                c.elements ~= e;
            }

            return c;
        }

        // create a bunch of components from the profile template
        foreach (ref ct; profile.componentTemplates)
        {
            Component c = createComponent(ct);
            device.components ~= c;
        }

        g_app.devices.insert(device.id, device);

        // clean up...
        g_app.allocator.freeT(profile);
        g_app.allocator.free(file);
    }

    RequestState sendRequest(Session session, const(char)[] client, const(char)[] slave, ref ModbusPDU msg)
    {
        MACAddress addr;
        ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
        if (!c)
            return null;

        RequestState state = g_app.allocator.allocT!RequestState(session, slave);
        c.sendRequest(addr, msg, &state.responseHandler, &state.errorHandler);

        return state;
    }

    RequestState request_raw(Session session, const(char)[] client, const(char)[] slave, ubyte[] message)
    {
        if (message.length == 0)
        {
            session.writeLine("Message must contain at least one byte (function code).");
            return null;
        }
        ModbusPDU msg = ModbusPDU(cast(FunctionCode)message[0], message[1..$]);
        return sendRequest(session, client, slave, msg);
    }

    RequestState request_read(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort register, Nullable!ushort count, Nullable!(const(char)[]) data_type)
    {
        RegisterType ty = parseRegisterType(reg_type);
        if (ty == RegisterType.Invalid)
        {
            session.writeLine("Invalid register type '", reg_type, "'");
            return null;
        }

        ModbusPDU msg = createMessage_Read(ty, register, count ? count.value : 1);
        return sendRequest(session, client, slave, msg);
    }

    RequestState request_write(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort register, Nullable!ushort value, Nullable!(ushort[]) values)
    {
        if (!value && !values)
        {
            session.writeLine("No `value` or `values` specified for write request");
            return null;
        }

        RegisterType ty = parseRegisterType(reg_type);
        if (ty == RegisterType.Invalid)
        {
            session.writeLine("Invalid register type '", reg_type, "'");
            return null;
        }

        ModbusPDU msg = createMessage_Write(ty, register, values ? values.value : (&value.value)[0..1]);
        return sendRequest(session, client, slave, msg);
    }

    RequestState request_read_device_id(Session session, const(char)[] client, const(char)[] slave)
    {
        MACAddress addr;
        ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
        if (!c)
            return null;

        RequestState state = g_app.allocator.allocT!RequestState(session, slave);

        ModbusPDU msg = createMessage_GetDeviceInformation();
        c.sendRequest(addr, msg, &state.responseHandler, &state.errorHandler);

        return state;
    }

    ModbusClient lookupClientAndSlave(Session session, const(char)[] client, const(char)[] slave, out ServerMap* map)
    {
        auto c = client in clients;
        if(c is null)
        {
            session.writeLine("Client '", client, "' doesn't exist");
            return null;
        }

        // TODO: this should be a global MAC->name table, not a modbus specific table...
        map = get_module!ModbusInterfaceModule.findServerByName(slave);
        if (!map)
        {
            MACAddress addr;
            if (addr.fromString(slave))
                map = get_module!ModbusInterfaceModule.findServerByMac(addr);
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
                session.writeLine("Invalid slave identifier or address '", slave, "'");
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
                return RegisterType.Coil;
            case "1":
            case "discrete":
                return RegisterType.DiscreteInput;
            case "3":
            case "input":
                return RegisterType.InputRegister;
            case "4":
            case "holding":
                return RegisterType.HoldingRegister;
            default:
                return RegisterType.Invalid;
        }
    }
}


class RequestState : FunctionCommandState
{
nothrow @nogc:

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

    void responseHandler(ref const ModbusPDU request, ref ModbusPDU response, SysTime requestTime, SysTime responseTime)
    {
        if (response.functionCode & 0x80)
        {
            import urt.meta : enum_keys;
            session.writeLine("Exception response from ", slave[], ", code: ", enum_keys!ExceptionCode[response.data[0]]);
        }
        else
        {
            session.writeLine("Response from ", slave[], " in ", (responseTime - requestTime).as!"msecs", "ms: ", toHexString(response.data));
            switch (response.functionCode)
            {
                case FunctionCode.ReadCoils:
                case FunctionCode.ReadDiscreteInputs:
                case FunctionCode.ReadInputRegisters:
                case FunctionCode.ReadHoldingRegisters:
                    ubyte byteCount = response.data[0];
                    ushort first = request.data[0..2].bigEndianToNative!ushort;
                    ushort count = request.data[2..4].bigEndianToNative!ushort;
                    switch (response.functionCode)
                    {
                        case FunctionCode.ReadCoils:
                        case FunctionCode.ReadDiscreteInputs:
                            if (byteCount * 8 < count)
                            {
                                session.writeLine("Invalid byte count in response...");
                                break;
                            }
                            for (ushort i = 0; i < count; i++)
                            {
                                bool value = (response.data[1 + i / 8] & (1 << (i % 8))) != 0;
                                session.writeLine("  ", first + i, ": ", value ? "ON" : "OFF");
                            }
                            break;
                        case FunctionCode.ReadInputRegisters:
                        case FunctionCode.ReadHoldingRegisters:
                            if (byteCount != count * 2)
                            {
                                session.writeLine("Invalid byte count in response...");
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
                case FunctionCode.WriteSingleCoil:
                case FunctionCode.WriteSingleRegister:
                    ushort reg = request.data[0..2].bigEndianToNative!ushort;
                    ushort value = request.data[2..4].bigEndianToNative!ushort;
                    session.writef("  {0}: {1, 04x} ({2})\n", reg, value, value);
                    break;
                case FunctionCode.WriteMultipleCoils:
                case FunctionCode.WriteMultipleRegisters:
                    assert(false, "TODO: pretty-print the output?");
//                    session.writeLine("Starting register: ", toHexString(response.data[0..2], 2, 4, "_ "));
//                    session.writeLine("Number of registers written: ", toHexString(response.data[2..4], 2, 4, "_ "));
                    break;
                default:
                    break;
            }
        }
        state = CommandCompletionState.Finished;
    }

    void errorHandler(ModbusErrorType errorType, ref const ModbusPDU request, SysTime requestTime)
    {
        Duration reqDuration = getTime() - requestTime;
        if (errorType == ModbusErrorType.Timeout)
        {
            session.writeLine("Timeout waiting for response from ", slave[], " after ", reqDuration.as!"msecs", "ms");
            state = CommandCompletionState.Timeout;
        }
        else if (errorType == ModbusErrorType.Retrying)
            session.writeLine("Timeout (", reqDuration.as!"msecs", "ms); retrying...");
        else
            state = CommandCompletionState.Error;
    }
}
