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

void main()
{
	loadConfig("conf/monitor.conf");

	// SolarEdge inverter<->meter comms
	ModbusProfile* se_meter_profile = new ModbusProfile;
	se_meter_profile.populateRegs(WND_WR_MB_Regs);
	Connection port1_mb = new Connection(streams["port1"], ModbusProtocol.RTU, ConnectionParams(Mode.SnoopBus, logDataStream: "log/se_meter"));
	ModbusServer solaredge_meter = new ModbusServer("solaredge_meter", port1_mb, 2, se_meter_profile);

	Device solaredge;
	solaredge.addComponent(createComponentForModbusServer("meter", "Meter", solaredge.addServer(solaredge_meter), solaredge_meter));
	solaredge.finalise();

	// GoodWe inverter<->meter comms
	ModbusProfile* goodwe_meter_profile = new ModbusProfile;
	goodwe_meter_profile.populateRegs(goodWeSmartMeterRegs);
	Connection port5_mb = new Connection(streams["port5"], ModbusProtocol.RTU, ConnectionParams(Mode.SnoopBus, logDataStream: "log/goodwe_meter"));
	ModbusServer goodwe_meter = new ModbusServer("goodwe_meter", port5_mb, 3, goodwe_meter_profile);

	Device goodwe;
	goodwe.addComponent(createComponentForModbusServer("meter", "Meter", goodwe.addServer(goodwe_meter), goodwe_meter));
	goodwe.finalise();

	// PACE BMS
	ModbusProfile* pace_bms_profile = new ModbusProfile;
	pace_bms_profile.populateRegs(paceBmsRegs);
	Connection port4_mb = new Connection(streams["port4"], ModbusProtocol.RTU, ConnectionParams(logDataStream: "log/pace"));
	ModbusServer[2] pace_bms = [
		new ModbusServer("pace_bms", port4_mb, 1, pace_bms_profile),
		new ModbusServer("pace_bms", port4_mb, 2, pace_bms_profile)
	];

	Device pace;
	pace.addComponent(createComponentForModbusServer("pack1", "Pack 1", pace.addServer(pace_bms[0]), pace_bms[0]));
	pace.addComponent(createComponentForModbusServer("pack2", "Pack 2", pace.addServer(pace_bms[1]), pace_bms[1]));
	pace.finalise();

/+
	// GoodWe inverter<->meter comms
	ModbusProfile* goodwe_profile = new ModbusProfile;
	goodwe_profile.populateRegs(goodWeInverterRegs);
	Connection port7_mb = Connection.createEthernetModbus(streams["port7"], ModbusProtocol.RTU, ConnectionParams());
	ModbusServer goodwe_inverter = new ModbusServer("goodwe_meter", port7_mb, 247, goodwe_profile);

	Device goodwe_inv;
	goodwe_inv.addComponent(createComponentForModbusServer("inverter", "Inverter", goodwe_inv.addServer(goodwe_inverter), goodwe_inverter));
	goodwe_inv.finalise();
+/

	int i = 0;
	while (true)
	{
		Stream.update();

		// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
		// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)

		port1_mb.poll();
		solaredge_meter.poll();
		solaredge.update();

		port5_mb.poll();
		goodwe_meter.poll();
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

		port4_mb.poll();
		pace_bms[0].poll();
		pace_bms[1].poll();
		pace.update();

//		port7_mb.poll();
//		goodwe_inverter.poll();
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

	ConfItem confRoot = parseConfigFile("conf/monitor.conf");

	foreach (ref item; confRoot.subItems)
	{
		if (item.name[] == "connections")
		{
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
		}
	}
}
