module router.modbus;

import urt.string.ascii;
import urt.conv;
import urt.io;
import urt.log;
import urt.mem.string;
import urt.string;

import manager;
import manager.config;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;
import manager.units;
import manager.value;

import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;
import router.modbus.server;
import router.stream;
import router.stream.tcp;


class ModbusPlugin : Plugin
{
	mixin RegisterModule!"modbus";

	ModbusProfile*[string] profiles;

	override void init()
	{
		import router.modbus.profile.solaredge_meter;
		import router.modbus.profile.goodwe;
		import router.modbus.profile.goodwe_inverter;
		import router.modbus.profile.goodwe_smart_meter;
		import router.modbus.profile.pace_bms;

		// populate some builtin modbus profiles...
		ModbusProfile* mb_profile = new ModbusProfile;
		mb_profile.populateRegs(WND_WR_MB_Regs);
		registerProfile("se_meter", mb_profile);

		mb_profile = new ModbusProfile;
		mb_profile.populateRegs(goodWeSmartMeterRegs);
		registerProfile("goodwe_meter", mb_profile);

		mb_profile = new ModbusProfile;
        mb_profile.populateRegs(goodWeInverterRegs);
		registerProfile("goodwe", mb_profile);
	}

	void registerProfile(string name, ModbusProfile* profile)
	{
		assert(!getProfile(name));
		profiles[name] = profile;
	}

	ModbusProfile* getProfile(const(char)[] name)
	{
		ModbusProfile** pProfile = name in profiles;
		if (!pProfile)
			return null;
		return *pProfile;
	}

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		Connection[string] connections;

		override void init()
		{
			// register modbus component
			app.registerComponentType("modbus-component", &createModbusComponent);
		}

		override void preUpdate()
		{
			// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
			// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)
			foreach (connection; connections)
				connection.poll();
		}

		override void parseConfig(ref ConfItem conf)
		{
			import router.stream;

			foreach (ref mb; conf.subItems) switch (mb.name)
			{
				case "connection":
					string name;
					Stream stream;
					Mode mode;
					ModbusProtocol protocol;
					const(char)[] logFile;
					int interval = ConnectionParams.init.pollingInterval, delay = ConnectionParams.init.pollingDelay, timeout = ConnectionParams.init.timeoutThreshold;

					foreach (ref param; mb.subItems) switch (param.name)
					{
						case "name":
							name = param.value.unQuote.idup;
							break;

						case "stream":
							const(char)[] streamName = param.value.unQuote;
							stream = app.moduleInstance!StreamModule.getStream(streamName);
							if (!stream)
								writeln("Invalid stream: ", streamName);
							break;

						case "tcp-server":
							break;

						case "tcp-client":
							const(char)[] addr, port, options = param.value;
							port = options.split!',';
							addr = port.split!':'.unQuote;
							ushort p = cast(ushort)port.parseInt;
							stream = new TCPStream(addr.idup, p ? p : 502, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
							break;

						case "udp-server":
							break;

						case "udp-client":
							break;

						case "serial":
							break;

						case "protocol":
							switch (param.value.unQuote.toLower)
							{
								case "tcp": protocol = ModbusProtocol.TCP; break;
								case "rtu": protocol = ModbusProtocol.RTU; break;
								case "ascii": protocol = ModbusProtocol.ASCII; break;
								default: writeln("Invalid modbus protocol: ", param.value);
							}
							break;

						case "mode":
							switch (param.value.unQuote.toLower)
							{
								case "master": mode = Mode.Master; break;
								case "client": mode = Mode.Master; break;
								case "slave": mode = Mode.Slave; break;
								case "server": mode = Mode.Slave; break;
								case "snoop": mode = Mode.SnoopBus; break;
								case "snoopbus": mode = Mode.SnoopBus; break;
								default: writeln("Invalid modbus connection mode: ", param.value);
							}
							break;

						case "interval":
							UnitDef val = parseUnitDef(param.value);
							interval = cast(int)val.normalise(1000);
							break;

						case "delay":
							UnitDef val = parseUnitDef(param.value);
							delay = cast(int)val.normalise(1000);
							break;

						case "timeout":
							UnitDef val = parseUnitDef(param.value);
							timeout = cast(int)val.normalise(1000);
							break;

						case "logFile":
							if (!param.value.empty)
								logFile = param.value.unQuote;
							else
							{
								assert(!name.empty, "Connection has no name for logfile.");
								logFile = "log/modbus/" ~ name;
							}
							break;

						default:
							writeln("Invalid token: ", param.name);
					}

					// TODO: make these runtime error messages instead of assert's...
					assert(name !in connections);
					assert(stream);
					assert(protocol != ModbusProtocol.Unknown);

					ConnectionParams params = ConnectionParams(mode:             mode,
															   pollingInterval:  interval,
															   pollingDelay:     delay,
															   timeoutThreshold: timeout,
															   logDataStream:    logFile.idup);

					connections[name] = new Connection(name, stream, protocol, params);
					break;

				case "slave":
					string name;
					const(char)[] connection;
					const(char)[] profileName;
					ubyte address;

					foreach (ref param; mb.subItems) switch (param.name)
					{
						case "name":
							name = param.value.unQuote.idup;
							break;

						case "connection":
							connection = param.value.unQuote;
							break;

						case "address":
							address = cast(ubyte)param.value.parseInt;
							break;

						case "profile":
							profileName = param.value.unQuote;
							break;

						default:
							writeln("Invalid token: ", param.name);
					}

					// TODO: all this should be warning messages, not asserts
					// TODO: messages should have config file+line
/+
					assert(name !in app.servers);
					if (connection !in connections)
					{
						writeWarning("CONFIG: No modbus connection '", connection, '\'');
						break;
					}

					Connection conn = connections[connection];

					ModbusProfile* profile = this.outer.getProfile(profileName);
					if (!profile)
					{
						import urt.mem.temp;
						// try and load profile...
						profile = loadModbusProfile(tconcat("conf/modbus_profiles/", profileName, ".conf"));
					}
					assert(profile);

					app.servers[name] = new ModbusServer(name, conn, address, profile);
+/
					break;

				case "master":
					foreach (ref param; mb.subItems)
					{
						switch (param.name)
						{
							case "name":
								break;

							case "address":
								foreach (ref addr; param.subItems) switch (addr.name)
								{
									case "type":
										break;

									case "registers":
										break;

									default:
										writeln("Invalid token: ", addr.name);
								}
								break;

							default:
								writeln("Invalid token: ", param.name);
						}
					}
					break;

				default:
					writeln("Invalid token: ", mb.name);
			}
		}

		Component* createModbusComponent(Device* device, ref ConfItem config)
		{
			string id, name, server;
			foreach (ref com; config.subItems) switch (com.name)
			{
				case "id":
					id = com.value.unQuote.idup;
					break;
				case "name":
					name = com.value.unQuote.idup;
					break;
				case "server":
					server = com.value.unQuote.idup;
					break;
				default:
					writeln("Invalid token: ", com.name);
			}
/+
			Server* pServer = server in app.servers;
			// TODO: proper error message
			assert(pServer, "No server");

			ModbusServer modbusServer = pServer ? cast(ModbusServer)*pServer : null;
			// TODO: proper error message
			assert(modbusServer, "Not a modbus server");

			Component* component = new Component;
			component.id = addString(id);
			component.name = addString(name);

			if (modbusServer.profile)
			{
				// Create elements for each modbus register
				Element[] elements = new Element[modbusServer.profile.registers.length];
				component.elements = elements;

				foreach (size_t i, ref const ModbusRegInfo reg; modbusServer.profile.registers)
				{
					elements[i].id = reg.desc.name;
					elements[i].name = reg.desc.description;
					elements[i].unit = reg.desc.displayUnits;
					elements[i].method = Element.Method.Sample;
					elements[i].type = modbusRegTypeToElementTypeMap[reg.type]; // maybe some numeric values should remain integer?
					elements[i].arrayLen = 0;
					elements[i].sampler = new Sampler(modbusServer, cast(void*)&reg);
					elements[i].sampler.convert = unitConversion(reg.units, reg.desc.displayUnits);
					elements[i].sampler.updateIntervalMs = updateIntervalMap[reg.desc.updateFrequency];
					elements[i].sampler.lessThan = &elementLessThan;
				}

				// populate the id lookup table
				foreach (ref Element element; component.elements)
					component.elementsById[element.id] = &element;
			}

			if (modbusServer.isBusSnooping())
				modbusServer.snoopBusMessageHandler = &(new SnoopHandler(component).snoopBusHandler);

			return component;
+/
			return null;
		}
	}
}


private:

immutable uint[Frequency.max + 1] updateIntervalMap = [
	50,		// realtime
	1000,	// high
	10000,	// medium
	60000,	// low
	0,		// constant
	0,		// configuration
];

static bool elementLessThan(Sampler* a, Sampler* b)
{
	debug
	{
		ModbusServer ma = cast(ModbusServer)a.server;
		ModbusServer mb = cast(ModbusServer)b.server;
		assert(ma && mb);
	}

	const ModbusRegInfo* areg = cast(ModbusRegInfo*)a.samplerData;
	const ModbusRegInfo* breg = cast(ModbusRegInfo*)b.samplerData;
	return areg.reg < breg.reg;
}

struct SnoopHandler
{
	Component* component;

	void snoopBusHandler(Response response, void[] userData)
	{
		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		string name = response.server.name;

		Response.KVP[string] values = response.values;
/+
		if (!modbusResponse.profile)
		{
			import std.algorithm : sort;
			import std.array : array;
			// HACK: no profile; we'll just print the data for diagnostic...
			foreach (v; values.byValue.array.sort!((a, b) => a.element[] < b.element[]))
			writeln(v.element, ": ", v.value);
			return;
		}
+/
		foreach (ref e; component.elements)
		{
			Response.KVP* kvp = e.id in values;
			if (kvp)
			{
				e.latest = kvp.value;
				switch (e.latest.type)
				{
					case Value.Type.Integer:
						if (e.type == Value.Type.Integer)
							break;
						assert(0);
					case Value.Type.Float:
						if (e.type == Value.Type.Integer)
							e.latest = Value(cast(long)e.latest.asFloat);
						else if (e.type == Value.Type.Float)
							break;
						else if (e.type == Value.Type.Bool)
							e.latest = Value(e.latest.asFloat != 0);
						assert(0);
					case Value.Type.String:
						if (e.type == Value.Type.String)
							break;
						assert(0);
					default:
						assert(0);
				}

				writeDebug("Modbus - ", name, '.', e.id, ": ", e.latest, e.unit);
			}
		}
	}
}

immutable Value.Type[] modbusRegTypeToElementTypeMap = [
	Value.Type.Float, // NOTE: seems crude to cast all numeric values to float...
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Float,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.Integer,
	Value.Type.String
];
static assert(modbusRegTypeToElementTypeMap.length == RecordType.max + 1);


import manager.console;
import manager.console.command;
import manager.console.session;

class ModbusCommand : Command
{
	ModbusPlugin.Instance instance;

	this(ref Console console, const(char)[] name, ModbusPlugin.Instance instance)
	{
		import urt.mem.string;

		super(console, String(name.addString));
		this.instance = instance;
	}

	override CommandState execute(Session session, const(char)[] cmdLine)
	{
		while (!cmdLine.empty)
		{
			cmdLine = cmdLine.trimCmdLine;
			if (cmdLine.frontIs('"'))
			{

				// scan for closing '"'
				//...

				cmdLine = cmdLine[1..$];
			}
			else
			{
				const(char)[] property = cmdLine.takeIdentifier;
				// check for identifiers: message, topics...
			}
		}


//		ctx.reply("Log module commands:");
//		ctx.reply("  /log help - Show this help");
		return null;
	}
}
