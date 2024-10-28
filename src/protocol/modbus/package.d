module protocol.modbus;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.modbus.client;
import protocol.modbus.sampler;

import router.iface;
import router.iface.modbus;

import router.modbus.message;


class ModbusProtocolModule : Plugin
{
	mixin RegisterModule!"protocol.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;
    nothrow @nogc:

		Map!(const(char)[], ModbusClient) clients;

		override void init()
		{
			app.console.registerCommand!client_add("/protocol/modbus/client", this, "add");
			app.console.registerCommand!device_add("/protocol/modbus/device", this, "add");
			app.console.registerCommand!request_read("/protocol/modbus/client/request", this, "read");
			app.console.registerCommand!request_read_device_id("/protocol/modbus/client/request", this, "read-device-id");
		}

		override void update()
		{
			foreach(name, client; clients)
				client.update();
		}

		void client_add(Session session, const(char)[] name, const(char)[] _interface, Nullable!bool snoop)
		{
			auto mod_if = app.moduleInstance!InterfaceModule;

			BaseInterface i = mod_if.findInterface(_interface);
			if(i is null)
			{
				session.writeLine("Interface '", _interface, "' not found");
				return;
			}

            // TODO: generate name if not supplied
			String n = name.makeString(app.allocator);

			ModbusClient client = app.allocator.allocT!ModbusClient(this, n.move, i, snoop ? snoop.value : false);
			clients[client.name[]] = client;
		}

        void device_add(Session session, const(char)[] id, const(char)[] _client, const(char)[] slave, Nullable!(const(char)[]) name, Nullable!(const(char)[]) _profile)
        {
            if (id in app.devices)
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
                if (!target.fromString(slave))
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
            import manager.value;
            import router.modbus.profile;
            import urt.file;
            import urt.string.format;

            void[] file = load_file(tconcat("conf/modbus_profiles/", profileName, ".conf"), app.allocator);
            ModbusProfile* profile = parseModbusProfile(cast(char[])file, app.allocator);

            // create the device
            Device* device = app.allocator.allocT!Device();
            device.id = id.makeString(app.allocator);
            if (name)
                device.name = name.value.makeString(app.allocator);

            // create a sampler for this modbus server...
            ModbusSampler sampler = app.allocator.allocT!ModbusSampler(client, target);
            device.samplers ~= sampler;

            // create a bunch of componwnts from the profile template
            foreach (ref ct; profile.componentTemplates)
            {
                Component* c = app.allocator.allocT!Component();
                c.id = ct.id.move;
                c.template_ = ct.template_.move;

                foreach (ref el; ct.elements)
                {
                    Element* e = app.allocator.allocT!Element();
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
                                    app.allocator.freeT(e);
                                    continue;
                                }

                                // HACK HACK HACK: this is all one huge gross HACK!
                                __gshared immutable Value.Type[RecordType.str] typeMap = [
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Float,
                                    Value.Type.Float,
                                    Value.Type.Float,
                                    Value.Type.Float,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Integer,
                                    Value.Type.Float,
                                ];

                                e.unit = (*pReg).units.makeString(app.allocator);
                                e.type = (*pReg).type < RecordType.str ? typeMap[(*pReg).type] : Value.Type.String;
                                e.arrayLen = 0; // TODO: handle arrays?
                                e.access = cast(manager.element.Access)(*pReg).access; // HACK: delete the rh type!

                                // TODO: if values are bitfields or enums, we should record the keys...

                                // record samper data...
                                sampler.addElement(e, **pReg);
                                device.sampleElements ~= e; // TODO: remove this?
                                break;
                        }
                    }

                    c.elements ~= e;
                }

                device.components ~= c;
            }

            app.devices.insert(device.id, device);

            // clean up...
            app.allocator.freeT(profile);
            app.allocator.free(file);
        }

        RequestState request_read(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort first, ushort count = 1)
        {
            MACAddress addr;
            ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
            if (!c)
                return null;

            RegisterType ty;
            uint reg = 0;
            switch(reg_type)
            {
                case "0":
                case "coil":
                    ty = RegisterType.Coil;
                    break;
                case "1":
                case "discrete":
                    ty = RegisterType.DiscreteInput;
                    break;
                case "3":
                case "input":
                    ty = RegisterType.InputRegister;
                    break;
                case "4":
                case "holding":
                    ty = RegisterType.HoldingRegister;
                    break;
                default:
                    session.writeLine("Invalid register type '", reg_type, "'");
                    return null;
            }

            RequestState state = app.allocator.allocT!RequestState(session, slave);

            ModbusPDU msg = createMessage_Read(ty, first, count);
            c.sendRequest(addr, msg, &state.responseHandler, &state.errorHandler);

            return state;
        }

        RequestState request_read_device_id(Session session, const(char)[] client, const(char)[] slave)
        {
            MACAddress addr;
            ModbusClient c = lookupClientAndMAC(session, client, slave, addr);
            if (!c)
                return null;

            RequestState state = app.allocator.allocT!RequestState(session, slave);

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
            map = app.moduleInstance!ModbusInterfaceModule.findServerByName(slave);

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
                else if (!addr.fromString(slave))
                {
                    session.writeLine("Invalid slave identifier or address '", slave, "'");
                    return null;
                }
            }
            return c;
        }
	}
}

class RequestState : FunctionCommandState
{
nothrow @nogc:

    MutableString!0 slave;
    bool finished = false;

    this(Session session, const(char)[] slave)
    {
        super(session);
        this.slave = MutableString!0(slave);
    }

    override CommandCompletionState update()
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

        if (finished)
            return CommandCompletionState.Finished;
        return CommandCompletionState.InProgress;
    }

    void responseHandler(ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime)
    {
        session.writeLine("Response from ", slave[], " in ", (responseTime - requestTime).as!"msecs", "ms: ", toHexString(response.data[1..$], 2, 4, "_ "));
        finished = true;
    }

    void errorHandler(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime requestTime)
    {
        Duration reqDuration = getTime() - requestTime;
        if (errorType == ModbusErrorType.Timeout)
        {
            session.writeLine("Timeout waiting for response from ", slave[], " after ", reqDuration.as!"msecs", "ms");
            finished = true;
        }
        else if (errorType == ModbusErrorType.Retrying)
            session.writeLine("Timeout (", reqDuration.as!"msecs", "ms); retrying...");
    }
}
