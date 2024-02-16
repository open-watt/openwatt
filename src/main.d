module main;

import std.format;
import std.stdio;

import router.client;
import router.server;

import router.modbus.coding;
import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;
import router.modbus.profile.solaredge_meter;
import router.modbus.profile.goodwe;
import router.modbus.profile.goodwe_ems;
import router.modbus.profile.goodwe_inverter;
import router.modbus.profile.goodwe_smart_meter;
import router.modbus.profile.pace_bms;
import router.stream;

import manager.component;
import manager.config;
import manager.device;
import manager.element;

import util.dbg;
import util.string;

Stream[string] streams;
Connection[string] modbus_connections;
ModbusServer[string] modbus_servers;
ModbusProfile*[string] modbus_profiles;
Device*[string] devices;

void main()
{
	// populate some builtin modbus profiles...
	ModbusProfile* mb_profile = new ModbusProfile;
	mb_profile.populateRegs(WND_WR_MB_Regs);
	modbus_profiles["se_meter"] = mb_profile;

	mb_profile = new ModbusProfile;
	mb_profile.populateRegs(goodWeSmartMeterRegs);
	modbus_profiles["goodwe_meter"] = mb_profile;

	mb_profile = new ModbusProfile;
	mb_profile.populateRegs(goodWeInverterRegs);
	modbus_profiles["goodwe"] = mb_profile;

	// load config files
	loadConfig("conf/monitor.conf");

//	ModbusProfile* profile = loadModbusProfile("conf/modbus_profiles/pace_bms.conf");
//	for (size_t i = 0; i < profile.registers.length; ++i)
//		dbgAssert(modbus_profiles["se_meter"].registers[i] == profile.registers[i]);

	int i = 0;
	while (true)
	{
		Stream.update();

		// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
		// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)
		foreach (connection; modbus_connections)
			connection.poll();
		foreach (server; modbus_servers)
			server.poll();
		foreach (device; devices)
			device.update();

/+
		if (i++ == 10)
		{
			Device* solaredge = devices["se_meter"];
			Device* goodwe = devices["goodwe_meter"];

			auto power1 = solaredge.components["meter"].elementsById["PowerFast1"].currentValue;
			auto power2 = goodwe.components["meter"].elementsById["power1_1"].currentValue;

			auto voltage1 = solaredge.components["meter"].elementsById["VoltAN"].currentValue;
			auto voltage2 = goodwe.components["meter"].elementsById["voltage"].currentValue;
			auto current1 = solaredge.components["meter"].elementsById["Current1"].currentValue;
			auto current2 = goodwe.components["meter"].elementsById["current"].currentValue;
			auto pf1 = solaredge.components["meter"].elementsById["PowerFactor1"].currentValue;
			auto pf2 = goodwe.components["meter"].elementsById["pf1_1"].currentValue;

			static double shedPower = 0;
			shedPower = shedPower*0.95 + (power2.asFloat + power1.asFloat)*0.05;

			writeln("VoltAN: ", solaredge.components["meter"].elementsById["VoltAN"].currentValue);
			writeln("voltage: ", goodwe.components["meter"].elementsById["voltage"].currentValue);
			writeln("Freq: ", solaredge.components["meter"].elementsById["Freq"].currentValue);
			writeln("freq: ", goodwe.components["meter"].elementsById["freq"].currentValue);
			writeln("Current1: ", solaredge.components["meter"].elementsById["Current1"].currentValue);
			writeln("current: ", goodwe.components["meter"].elementsById["current"].currentValue);
			writeln("Power1: ", solaredge.components["meter"].elementsById["Power1"].currentValue);
			writeln("PowerFast1: ", power1, " calc: ", current1.asFloat * voltage1.asFloat * pf1.asFloat);
			writeln("power1_1: ", power2, " calc: ", current2.asFloat * voltage2.asFloat * pf2.asFloat);
			writeln("power1_2: ", goodwe.components["meter"].elementsById["power1_2"].currentValue);
			writeln("shed: ", shedPower);
			writeln("PowerReac1: ", solaredge.components["meter"].elementsById["PowerReac1"].currentValue);
			writeln("reactive1_1: ", goodwe.components["meter"].elementsById["reactive1_1"].currentValue);
			writeln("reactive1_2: ", goodwe.components["meter"].elementsById["reactive1_2"].currentValue);
			writeln("PowerApp1: ", solaredge.components["meter"].elementsById["PowerApp1"].currentValue, " calc: ", current1.asFloat * voltage1.asFloat);
			writeln("apparent1_1: ", goodwe.components["meter"].elementsById["apparent1_1"].currentValue, " calc: ", current2.asFloat * voltage2.asFloat);
			writeln("apparent1_2: ", goodwe.components["meter"].elementsById["apparent1_2"].currentValue);
			writeln("PowerFactor1: ", solaredge.components["meter"].elementsById["PowerFactor1"].currentValue);
			writeln("pf1_1: ", goodwe.components["meter"].elementsById["pf1_1"].currentValue);
			writeln("pf1_2: ", goodwe.components["meter"].elementsById["pf1_2"].currentValue);
			writeln("reg307: ", goodwe.components["meter"].elementsById["reg307"].currentValue);
			writeln("reg312: ", goodwe.components["meter"].elementsById["reg312"].currentValue);
			writeln("reg340: ", goodwe.components["meter"].elementsById["reg340"].currentValue);
			writeln("reg341: ", goodwe.components["meter"].elementsById["reg341"].currentValue);
			i = 0;
		}
+/

		// Process program logic
		// ...

		import core.thread;
		Thread.sleep(dur!"msecs"(1));
	}
}


void loadConfig(string file)
{
	import std.conv : to;
	import std.uni : toLower;

	ConfItem confRoot = parseConfigFile("conf/monitor.conf");

	foreach (ref item; confRoot.subItems) switch (item.name)
	{
		case "global":
			foreach (ref opt; item.subItems) switch (opt.name)
			{
				case "loglevel":
					import util.log;
					foreach (i, level; levelNames)
					{
						if (opt.value.unQuote.toLower[] == level.toLower[])
							logLevel = cast(Level)i;
					}
					break;

				default:
					writeln("Invalid token: ", opt.name);
			}
			break;

		case "connections":
			foreach (ref conn; item.subItems)
			{
				if (conn.name[] == "tcp-client")
				{
					string name, addr, port, options, tail = conn.value;
					name = tail.split!','.unQuote;
					port = tail.split!',';
					addr = port.split!':'.unQuote;
					options = tail.split!',';
					// TODO: if !tail.empty, warn about unexpected data...
					streams[name] = new TCPStream(addr, port.to!ushort, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
				}
			}
			break;

		case "device":
			Device* device = new Device;

			foreach (ref dev; item.subItems) switch (dev.name)
			{
				case "id":
					device.id = dev.value.unQuote;
					break;

				case "name":
					device.name = dev.value.unQuote;
					break;

				case "component":
					break;

				case "modbus-component":
					string id, name, server;
					foreach (ref com; dev.subItems) switch (com.name)
					{
						case "id":
							id = com.value.unQuote;
							break;
						case "name":
							name = com.value.unQuote;
							break;
						case "server":
							server = com.value.unQuote;
							break;
						default:
							writeln("Invalid token: ", com.name);
					}

					// TODO: proper error message
					assert(server in modbus_servers);

					ModbusServer srv = modbus_servers[server];

					int serverId = device.addServer(srv);
					Component* component = createComponentForModbusServer(id, name, serverId, srv);
					device.addComponent(component);
					break;

				default:
					writeln("Invalid token: ", dev.name);
			}

			device.finalise();

			// TODO: proper error message
			assert(device.id);
			devices[device.id] = device;
			break;

		case "modbus":
			foreach (ref mb; item.subItems) switch (mb.name)
			{
				case "connection":
					string name;
					Stream stream;
					Mode mode;
					ModbusProtocol protocol;
					string logFile;

					foreach (ref param; mb.subItems) switch (param.name)
					{
						case "name":
							name = param.value.unQuote;
							break;

						case "tcp-server":
							break;

						case "tcp-client":
							string addr, port, options = param.value;
							port = options.split!',';
							addr = port.split!':'.unQuote;
							ushort p = port.to!ushort;
							stream = new TCPStream(addr, p ? p : 502, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
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
					assert(name !in modbus_connections);
					assert(stream);
					assert(protocol != ModbusProtocol.Unknown);

					modbus_connections[name] = new Connection(stream, protocol, ConnectionParams(mode, logDataStream: logFile));
					break;

				case "slave":
					string name;
					string connection;
					ubyte address;
					string profileName;

					foreach (ref param; mb.subItems) switch (param.name)
					{
						case "name":
							name = param.value.unQuote;
							break;

						case "connection":
							connection = param.value.unQuote;
							break;

						case "address":
							address = param.value.to!ubyte;
							break;

						case "profile":
							profileName = param.value.unQuote;
							break;

						default:
							writeln("Invalid token: ", param.name);
					}

					if (profileName !in modbus_profiles)
					{
						// try and load profile...
						string filename = "conf/modbus_profiles/" ~ profileName ~ ".conf";
						try
						{
							import std.file : readText;
							string conf = filename.readText();
							ModbusProfile* profile = parseModbusProfile(conf);
							modbus_profiles[profileName] = profile;
						}
						catch (Exception e)
						{
							// TODO: warn user that can't load profile...
						}
					}

					// TODO: all this should me warning messages, not asserts
					assert(name !in modbus_servers);
					assert(connection in modbus_connections);
					assert(profileName in modbus_profiles);

					modbus_servers[name] = new ModbusServer(name, modbus_connections[connection], address, modbus_profiles[profileName]);
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
			break;

		default:
			writeln("Invalid token: ", item.name);
	}
}

ModbusProfile* loadModbusProfile(string filename)
{
	ConfItem root = parseConfigFile(filename);
	return parseModbusProfile(root);
}

ModbusProfile* parseModbusProfile(string conf)
{
	ConfItem root = parseConfig(conf);
	return parseModbusProfile(root);
}

ModbusProfile* parseModbusProfile(ConfItem conf)
{
	import std.conv : to;
	import std.uni : toLower;

	ModbusRegInfo[] registers;

	foreach (ref rootItem; conf.subItems) switch (rootItem.name)
	{
		case "registers":
			foreach (ref regItem; rootItem.subItems) switch (regItem.name)
			{
				case "reg":
					// parse register details
					string register, type, units, id, displayUnits, freq, desc;
					string[] fields, fieldDesc;

					string extra, tail = regItem.value;
					char sep;
					register = tail.split!(',', ':')(sep);
					assert(sep == ',');
					type = tail.split!(',', ':')(sep).unQuote;
					assert(sep == ',');
					string t = tail.split!(',', ':')(sep);
					if (sep == ':')
						extra = t;
					else
					{
						units = t.unQuote;
						extra = tail.split!':';
					}
					if (!extra.empty)
						regItem.subItems = ConfItem(extra, tail) ~ regItem.subItems;

					foreach (ref regConf; regItem.subItems) switch (regConf.name)
					{
						case "desc":
							tail = regConf.value;
							id = tail.split!','.unQuote;
							displayUnits = tail.split!','.unQuote;
							freq = tail.split!','.unQuote;
							desc = tail.split!','.unQuote;
							// TODO: if !tail.empty, warn about unexpected data...
							break;

						case "valueid":
							tail = regConf.value;
							// TODO: make this a warning message, no asserts!
							assert(!tail.empty);
							do
							{
								fields ~= tail.split!','(sep).unQuote;
							}
							while (sep != '\0');
							break;

						case "valuedesc":
							tail = regConf.value;
							// TODO: make this a warning message, no asserts!
							assert(!tail.empty);
							do
							{
								fieldDesc ~= tail.split!','(sep).unQuote;
							}
							while (sep != '\0');
							break;

						case "map-local":
							// TODO:
							break;

						case "map-mb":
							// TODO:
							break;

						default:
							writeln("Invalid token: ", regConf.name);
					}

					Frequency frequency = Frequency.Medium;
					if (!freq.empty) switch (freq.toLower)
					{
						case "realtime":	frequency = Frequency.Realtime;			break;
						case "high":		frequency = Frequency.High;				break;
						case "medium":		frequency = Frequency.Medium;			break;
						case "low":			frequency = Frequency.Low;				break;
						case "const":		frequency = Frequency.Constant;			break;
						case "ondemand":	frequency = Frequency.OnDemand;			break;
						case "config":		frequency = Frequency.Configuration;	break;
						default: writeln("Invalid frequency value: ", freq);
					}

					registers ~= ModbusRegInfo(register.to!int, type, id, units, displayUnits, frequency, desc, fields, fieldDesc);
					break;

				default:
					writeln("Invalid token: ", regItem.name);
			}
			break;

		default:
			writeln("Invalid token: ", rootItem.name);
	}

	if (registers.empty)
		return null;

	return new ModbusProfile(registers);
}
