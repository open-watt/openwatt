module main;

import router.client;
import router.server;

import router.modbus.coding;
import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;
import router.modbus.server;
import router.mqtt.broker;
import router.stream;

import manager;
import manager.component;
import manager.console.session;
import manager.config;
import manager.device;
import manager.element;
import manager.instance;
import manager.units;

import urt.io;
import urt.log;
import urt.mem.string;
import urt.string;
import urt.string.format;


void main()
{
	// init the string heap with 1mb!
//	initStringHeap(1024*1024); // TODO: uncomment when remove the module constructor...

	// TODO: prime the string cache with common strings, like unit names and common variable names
	//       the idea is to make dedup lookups much faster...

	ApplicationInstance app = getGlobalInstance.createInstance("app");

	// execute startup script
	string conf;
	try
	{
		import std.file : readText;
		conf = "conf/startup.conf".readText();
	}
	catch (Exception e)
	{
		// TODO: warn user that can't load profile...
		assert(false);
	}
	ConsoleSession s = new ConsoleSession(&app.console);
	s.setInput(conf);

	// load config files
	app.loadConfig("conf/monitor.conf");


//	ModbusProfile* profile = loadModbusProfile("conf/modbus_profiles/pace_bms.conf");
//	for (size_t i = 0; i < profile.registers.length; ++i)
//		dbgAssert(modbus_profiles["se_meter"].registers[i] == profile.registers[i]);

//	import router.goodwe.aa55;
//	GoodWeServer goodwe = new GoodWeServer("GW5000-SBP-G2", "192.168.3.4");
//
//	void respFun(Response response, void[] userData) {
//		GoodWeResponse r = cast(GoodWeResponse)response;
//		if (r)
//		{
//			writeln(r.values);
//		}
//		ModbusResponse r2 = cast(ModbusResponse)response;
//		if (r2)
//		{
//			writeln(r2.values);
//		}
//	}
//
//	goodwe.sendRequest(new GoodWeRequest(&respFun, GoodWeRequestData(controlCode: GoodWeControlCode.Read, GoodWeFunctionCode.QueryIdInfo)));
////	goodwe.sendRequest(new GoodWeRequest(&respFun, GoodWeRequestData(controlCode: GoodWeControlCode.Register, GoodWeFunctionCode.OfflineQuery)));
//
//	goodwe.sendRequest(new ModbusRequest(&respFun, FunctionCode.ReadHoldingRegisters, [0x88, 0xB8, 0x00, 0x21], 0xF7));

	/+
-	35000 - 33  Device infio
-	37000 - 15  BMS info
-	47504 - 11  Export power control
-	37060 - 16  Battery SN
-	write multiple: 45200 - 3 [6148, 1550, 8461]  UPDATE THE CLOCK
	47504 - 11
-	47595 - 3   Load switch settings
	35000 - 33
-	35100 - 125 Inverter running data
-	36000 - 27  Meter data
	37000 - 15
	37060 - 16
-	45248 - 7   Some operating params
-	36043 - 6   Meter sub-data
-	47745 - 18  UNKNOWN
-	36197 - 1   UNKNOWN
-	47001 - 2   Meter check...
-	47000 - 1   Operating mode
-	45350 - 9   Battery charge.discharge protection params
-	35365 - 1   No idea; near some meter energy stats
	47504 - 11
	35000 - 33
	35100 - 125
	36000 - 27
	37000 - 15
	37060 - 16
	45248 - 7
	36043 - 6
	47745 - 18
	47595 - 3
	36197 - 1
	47001 - 2
	47000 - 1
	45350 - 9
	35365 - 1
	47504 - 11
	35000 - 33
	35100 - 125
	36000 - 27
	37000 - 15
	37060 - 16
	+/


	int i = 0;
	while (true)
	{
		getGlobalInstance.update();

//		goodwe.poll();

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
		import core.time : std_dur = dur;
		Thread.sleep(std_dur!"msecs"(1));
	}
}
