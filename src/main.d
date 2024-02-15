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

import util.string;

Stream[string] streams;
Connection[string] modbus_connections;
ModbusServer[string] modbus_servers;
ModbusProfile*[string] modbus_profiles;

void main()
{
	// populate some builtin modbus profiles...
	ModbusProfile* mb_profile = new ModbusProfile;
	mb_profile.populateRegs(WND_WR_MB_Regs);
	modbus_profiles["se_meter_profile"] = mb_profile;

	mb_profile = new ModbusProfile;
	mb_profile.populateRegs(goodWeSmartMeterRegs);
	modbus_profiles["goodwe_meter_profile"] = mb_profile;

	mb_profile = new ModbusProfile;
	mb_profile.populateRegs(paceBmsRegs);
	modbus_profiles["pace_bms_profile"] = mb_profile;

	mb_profile = new ModbusProfile;
	mb_profile.populateRegs(goodWeInverterRegs);
	modbus_profiles["goodwe_profile"] = mb_profile;

	// load config files
	loadConfig("conf/monitor.conf");


	// TODO: transform into config...

	// SolarEdge inverter<->meter comms
	Server solaredge_meter = modbus_servers["se_meter"];

	Device solaredge;
	solaredge.addComponent(createComponentForModbusServer("meter", "Meter", solaredge.addServer(solaredge_meter), solaredge_meter));
	solaredge.finalise();

	// GoodWe inverter<->meter comms
	Server goodwe_meter = modbus_servers["goodwe_meter"];

	Device goodwe;
	goodwe.addComponent(createComponentForModbusServer("meter", "Meter", goodwe.addServer(goodwe_meter), goodwe_meter));
	goodwe.finalise();

	// PACE BMS
	Server[2] pace_bms = [
		modbus_servers["pace_bms_pack1"],
		modbus_servers["pace_bms_pack2"]
	];

	Device pace;
	pace.addComponent(createComponentForModbusServer("pack1", "Pack 1", pace.addServer(pace_bms[0]), pace_bms[0]));
	pace.addComponent(createComponentForModbusServer("pack2", "Pack 2", pace.addServer(pace_bms[1]), pace_bms[1]));
	pace.finalise();

/+
	// GoodWe inverter<->meter comms
	Server goodwe_inverter = modbus_servers["goodwe_ems"];

	Device goodwe_inv;
	goodwe_inv.addComponent(createComponentForModbusServer("inverter", "Inverter", goodwe_inv.addServer(goodwe_inverter), goodwe_inverter));
	goodwe_inv.finalise();
+/

	int i = 0;
	while (true)
	{
		Stream.update();

		foreach (connection; modbus_connections)
			connection.poll();
		foreach (server; modbus_servers)
			server.poll();

		// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
		// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)

		solaredge.update();
		goodwe.update();

		if (i++ == 10)
		{
			auto power1 = solaredge.components["meter"].elementsById["PowerFast1"].currentValue;
			auto power2 = goodwe.components["meter"].elementsById["power1_1"].currentValue;

			auto voltage1 = solaredge.components["meter"].elementsById["VoltAN"].currentValue;
			auto voltage2 = goodwe.components["meter"].elementsById["voltage"].currentValue;
			auto current1 = solaredge.components["meter"].elementsById["Current1"].currentValue;
			auto current2 = goodwe.components["meter"].elementsById["current"].currentValue;
			auto pf1 = solaredge.components["meter"].elementsById["PowerFactor1"].currentValue;
			auto pf2 = goodwe.components["meter"].elementsById["pf1_1"].currentValue;

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
			writeln("shed: ", power2.asFloat - power1.asFloat, " or ", power1.asFloat - power2.asFloat);
			writeln("shed: ", power2.asFloat + power1.asFloat);
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

		pace.update();

//		goodwe_inv.update();

		// Process program logic
		// ...

		import core.thread;
		Thread.sleep(dur!"msecs"(1));
	}
}


void loadConfig(string file)
{
	import std.conv: to;
	import std.uni : toLower;

	ConfItem confRoot = parseConfigFile("conf/monitor.conf");

	foreach (ref item; confRoot.subItems)
	{
		switch (item.name)
		{
			case "global":
				// read global settings:
				//  loglevel
				//  ...
				break;

			case "connections":
				foreach (ref conn; item.subItems)
				{
					if (conn.name[] == "tcp-client")
					{
						string name, addr, port, options = conn.value;
						name = options.split!','();
						port = options.split!','();
						addr = port.split!':'();
						streams[name] = new TCPStream(addr, port.to!ushort, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
					}
				}
				break;

			case "modbus":
				foreach (ref mb; item.subItems)
				{
					switch (mb.name)
					{
						case "connection":
							string name;
							Stream stream;
							Mode mode;
							ModbusProtocol protocol;
							string logFile;

							foreach (ref param; mb.subItems)
							{
								switch (param.name)
								{
									case "name":
										name = param.value;
										break;

									case "tcp-server":
										break;

									case "tcp-client":
										string addr, port, options = param.value;
										port = options.split!','();
										addr = port.split!':'();
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
										switch (param.value.toLower)
										{
											case "tcp": protocol = ModbusProtocol.TCP; break;
											case "rtu": protocol = ModbusProtocol.RTU; break;
											case "ascii": protocol = ModbusProtocol.ASCII; break;
											default: writeln("Invalid modbus protocol: ", param.value);
										}
										break;

									case "mode":
										switch (param.value)
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
											logFile = param.value;
										else
										{
											assert(!name.empty, "Connection has no name for logfile.");
											logFile = "log/modbus/" ~ name;
										}
										break;

									default:
										writeln("Invalid token: ", param.name);
								}
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
							string profile;

							foreach (ref param; mb.subItems)
							{
								switch (param.name)
								{
									case "name":
										name = param.value;
										break;

									case "connection":
										connection = param.value;
										break;

									case "address":
										address = param.value.to!ubyte;
										break;

									case "profile":
										profile = param.value;
										break;

									default:
										writeln("Invalid token: ", param.name);
								}
							}

							assert(name !in modbus_servers);
							assert(connection in modbus_connections);
							assert(profile in modbus_profiles);

							modbus_servers[name] = new ModbusServer(name, modbus_connections[connection], address, modbus_profiles[profile]);
							break;

						case "master":
							foreach (ref param; mb.subItems)
							{
								switch (param.name)
								{
									case "name":
										break;

									case "address":
										foreach (ref addr; param.subItems)
										{
											switch (addr.name)
											{
												case "type":
													break;

												case "registers":
													break;

												default:
													writeln("Invalid token: ", addr.name);
											}
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
				break;

			default:
				writeln("Invalid token: ", item.name);
		}
	}
}
