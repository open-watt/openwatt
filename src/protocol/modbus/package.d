module protocol.modbus;

import urt.map;
import urt.mem;
import urt.string;
import urt.time;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;
import protocol.modbus.client;
import router.iface;
import router.iface.modbus;

import router.modbus.message;


class ModbusProtocolModule : Plugin
{
	mixin RegisterModule!"protocol.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		Map!(const(char)[], ModbusClient) clients;
//		Server[string] servers;

		override void init()
		{
			app.console.registerCommand!client_add("/protocol/modbus/client", this, "add");
			app.console.registerCommand!request_read("/protocol/modbus/client/request", this, "read");
		}

		override void update() nothrow @nogc
		{
			foreach(name, client; clients)
				client.update();
		}

		void client_add(Session session, const(char)[] name, const(char)[] _interface) nothrow @nogc
		{
			auto mod_if = app.moduleInstance!InterfaceModule;

			BaseInterface i = mod_if.findInterface(_interface);
			if(i is null)
			{
				session.writeLine("Interface '", _interface, "' not found");
				return;
			}

			String n = name.makeString(defaultAllocator());

			ModbusClient client = defaultAllocator().allocT!ModbusClient(this, n.move, i);
			clients[client.name[]] = client;
		}

        RequestState request_read(Session session, const(char)[] client, const(char)[] slave, const(char)[] reg_type, ushort first, ushort count = 1) nothrow @nogc
        {
            auto mod_if = app.moduleInstance!ModbusInterfaceModule;

            auto c = client in clients;
            if(c is null)
            {
                session.writeLine("Client '", client, "' doesn't exist");
                return null;
            }

            MACAddress addr;
            // TODO: this should be a global MAC->name table, not a modbus specific table...
            ServerMap* map = mod_if.findServerByName(slave);
            if (map)
                addr = map.mac;
            else if (!addr.fromString(slave))
            {
                session.writeLine("Invalid slave identifier or address '", slave, "'");
                return null;
            }

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

    override CommandCompletionState update() nothrow @nogc
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

        if (finished)
            return CommandCompletionState.Finished;
        return CommandCompletionState.InProgress;
    }

    void responseHandler(ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime) nothrow @nogc
    {
        session.writeLine("Response from ", slave[], " in ", (responseTime - requestTime).as!"msecs", "ms: ", toHexString(response.data[1..$], 2, 4, "_ "));
        finished = true;
    }

    void errorHandler(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime requestTime) nothrow @nogc
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
