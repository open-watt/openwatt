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
import router.modbus.profile.goodwe_ems;
import router.modbus.profile.pace_bms;

import manager.component;
import manager.device;
import manager.element;

void main()
{

	// goodwe testing
//	ModbusProfile* goodwe_ems_profile = new ModbusProfile;
//	goodwe_ems_profile.populateRegs(goodWeEmsRegs);
//
//	Server goodwe_ems = new Server("goodwe_ems");
//	goodwe_ems.createEthernetModbus("192.168.3.7", 8001, EthernetMethod.TCP, 247, ModbusProtocol.RTU, goodwe_ems_profile);
//
//	enum baseReg = 30000;
//	ushort reg = 0;
//	ModbusPDU ems_req = createMessageRead(cast(ushort)(baseReg + reg++));
//	goodwe_ems.sendModbusRequest(&ems_req);


	// SolarEdge inverter<->meter comms
	ModbusProfile* se_meter_profile = new ModbusProfile;
	se_meter_profile.populateRegs(WND_WR_MB_Regs);
	Connection port1 = Connection.createEthernetModbus("192.168.3.7", 8001, EthernetMethod.TCP, ModbusProtocol.RTU, ConnectionParams(Mode.SnoopBus));
	ModbusServer solaredge_meter = new ModbusServer("solaredge_meter", port1, 2, se_meter_profile);

	// PACE BMS
	ModbusProfile* pace_bms_profile = new ModbusProfile;
	pace_bms_profile.populateRegs(paceBmsRegs);
	Connection port4 = Connection.createEthernetModbus("192.168.3.7", 8004, EthernetMethod.TCP, ModbusProtocol.RTU, ConnectionParams());
	ModbusServer[2] pace_bms = [
		new ModbusServer("pace_bms", port4, 1, pace_bms_profile),
		new ModbusServer("pace_bms", port4, 2, pace_bms_profile)
	];


	Device solaredge;
	solaredge.addComponent(createComponentForModbusServer("meter", "Meter", solaredge.addServer(solaredge_meter), solaredge_meter));
	solaredge.finalise();

	Device pace;
	pace.addComponent(createComponentForModbusServer("pack1", "Pack 1", pace.addServer(pace_bms[0]), pace_bms[0]));
	pace.addComponent(createComponentForModbusServer("pack2", "Pack 2", pace.addServer(pace_bms[1]), pace_bms[1]));
	pace.finalise();

	while (true)
	{
		// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
		// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)

		port1.poll();
		solaredge_meter.poll();
		solaredge.update();

		port4.poll();
		pace_bms[0].poll();
		pace_bms[1].poll();
		pace.update();


		// Process program logic
		// ...

		import core.thread;
		Thread.sleep(dur!"msecs"(1));
	}
}
