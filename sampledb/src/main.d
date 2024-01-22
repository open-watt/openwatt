module main;

import std.format;
import std.stdio;

import router.client;
import router.connection;
import router.device;

import router.modbus.coding;
import router.modbus.message; alias ModbusProtocol = router.modbus.message.Protocol;
import router.modbus.profile;
import router.modbus.profile.solaredge_meter;
import router.modbus.profile.goodwe_ems;
import router.modbus.profile.pace_bms;


void main()
{
	ModbusProfile* se_meter_profile = new ModbusProfile;
	se_meter_profile.populateRegs(solarEdgeRegs);
	ModbusProfile* goodwe_ems_profile = new ModbusProfile;
	goodwe_ems_profile.populateRegs(goodWeEmsRegs);
	ModbusProfile* pace_bms_profile = new ModbusProfile;
	pace_bms_profile.populateRegs(paceBmsRegs);

	import std.digest : toHexString;

	ModbusPDU tmp;
	tmp = createMessage_Read(40000 + 0x0000, 10);
	frameRTUMessage(0, tmp.functionCode, tmp.data).toHexString.writeln;
	tmp = createMessage_Read(40000 + 0x0000, 10);
	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;
	tmp = createMessage_Read(40000 + 0x0000, 10);
	frameRTUMessage(2, tmp.functionCode, tmp.data).toHexString.writeln;
//	tmp = createMessage_Read(30000 + 0x0010, 3);
//	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;
//	tmp = createMessage_Read(30000 + 0x0100, 2);
//	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;
//	tmp = createMessage_Read(30000 + 0x0200, 8);
//	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;
//	tmp = createMessage_Read(30000 + 0x0210, 5);
//	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;
//	tmp = createMessage_Read(30000 + 0x0500, 44);
//	frameRTUMessage(1, tmp.functionCode, tmp.data).toHexString.writeln;


//	tmp = createMessage_Read(40001, 1);
//	msg = frameRTUMessage(1, tmp.functionCode, tmp.data);
//	writeln(msg[]);

	Client se_inverter = new Client("se_inverter");
	se_inverter.createEthernetModbus("192.168.3.7", 8003, EthernetMethod.TCP, 2, ModbusProtocol.RTU, se_meter_profile);
	Device se_meter = new Device("se_meter");
	se_meter.createEthernetModbus("192.168.3.7", 8006, EthernetMethod.TCP, 2, ModbusProtocol.RTU, se_meter_profile);

	// goodwe/pace testing
//	Device goodwe_ems = new Device("goodwe_ems");
//	goodwe_ems.createEthernetModbus("192.168.3.7", 8001, EthernetMethod.TCP, 247, ModbusProtocol.RTU, goodwe_ems_profile);

//	enum baseReg = 30000;
//	ushort reg = 0;
//	ModbusPDU ems_req = createMessageRead(cast(ushort)(baseReg + reg++));
//	goodwe_ems.sendModbusRequest(&ems_req);

	Device[2] pace_bms = [ new Device("pace_bms"), new Device("pace_bms") ];
	pace_bms[0].createEthernetModbus("192.168.3.7", 8008, EthernetMethod.TCP, 1, ModbusProtocol.RTU, pace_bms_profile);
	pace_bms[1].createEthernetModbus("192.168.3.7", 8008, EthernetMethod.TCP, 2, ModbusProtocol.RTU, pace_bms_profile);

	int bmsId = 0;
	ModbusPDU bms_req = createMessage_Read(40000, 37);
	pace_bms[bmsId].sendModbusRequest(&bms_req);


	import std.datetime;
	auto time = MonoTime.currTime;

	while (true)
	{
		// goodwe/pace testing: send some test requests...
//		ModbusPDU bms_req = createMessageRead(40001, 1);
//		pace_bms.sendModbusRequest(&bms_req);

		// solaredge meter relay
		Request* req = se_inverter.poll();
		if (req)
		{
			writeln(req.toString);
			se_meter.forwardModbusRequest(req);
		}
		Response* resp = se_meter.poll();
		if (resp)
		{
			writeln(resp.toString);
			se_inverter.sendModbusResponse(resp);
		}

		// goodwe/pace testing
//		resp = goodwe_ems.poll();
//		if (resp)
//		{
////			if (!(resp.packet.modbus.message.functionCode & 0x80))
//			{
//				writeln("Query reg: ", reg - 1, resp.toString);
//			}
//		}
//		if (resp || (MonoTime.currTime - time).total!"msecs" > 100)
//		{
//			if (!resp)
//				writeln("Timeout: ", reg - 1);
//
//			ems_req = createMessageRead(cast(ushort)(baseReg + reg));
//			goodwe_ems.sendModbusRequest(&ems_req);
//			time = MonoTime.currTime;
//
//			reg += 10;
//		}
		resp = pace_bms[0].poll();
		if (!resp)
			resp = pace_bms[1].poll();
		if (resp)
		{
			if (resp)
			{
				if (resp.status == RequestStatus.Success)
					parseModbusMessage(RequestType.Response, resp.packet.modbus.message).writeln;
				else
					writeln(resp.toString);
				bmsId = 1 - bmsId;
			}

			bms_req = createMessage_Read(40000, 37);
			pace_bms[bmsId].sendModbusRequest(&bms_req);
		}



//		const(ubyte)[] packet = tcpConnection.poll();
//		const(ubyte)[] packet2 = tcpConnection2.poll();
//		const(ubyte)[] packet3 = serialConnection.poll();

/+
		if (packet)
		{
			tcpConnection2.write(packet);

			if (tcpConnection.protocol == ConnectionProtocol.ModbusRTU)
			{
				ModbusRTUFrame frame = decodeModbusRTUFrame(packet, RequestType.Request);
				writeln(format("1 (Req) -> %s", frame));

				pending.src = tcpConnection;
				pending.dest = tcpConnection2;
				pending.reqFrame = frame;
			}
			else if (tcpConnection.protocol == ConnectionProtocol.ModbusTCP)
			{
				ModbusTCPFrame frame = decodeModbusTCPFrame(packet, RequestType.Request);
				writeln(format("1 (Req) -> %s", frame));
			}
			else
			{
				writeln(format("1 -> %s", packet));
			}
		}
		if (packet2)
		{
			if (tcpConnection2.protocol == ConnectionProtocol.ModbusRTU)
			{
				ModbusRTUFrame respFrame = decodeModbusRTUFrame(packet2, RequestType.Response);

				ModbusData* reqData = &pending.reqFrame.data;
				ushort[] responseValues = respFrame.data.val.values;

				assert(reqData.val.readCount == responseValues.length);

				for (ushort i = 0; i < reqData.val.readCount; ++i)
				{
					scope ModbusRegInfo* info = &se_meter.regInfoById[reqData.val.readAddress + i];
					se_meter.regValues[info.refReg].words[info.seqOffset] = responseValues[i];
				}

				string output;
				for (ushort i = reqData.val.readAddress; i < reqData.val.readAddress + reqData.val.readCount; ++i)
				{
					scope ModbusRegInfo* info = &se_meter.regInfoById[i];
					if (info.seqOffset == 0)
					{
						scope RegValue* val = &se_meter.regValues[i];
						output ~= format("%s: %s, ", info.name, val.toString);
					}
				}
				writeln("2 (Res) -> ", output);

				pending.src.write(packet2);

				pending.src = null;
				pending.dest = null;
			}
			else if (tcpConnection2.protocol == ConnectionProtocol.ModbusTCP)
			{
				ModbusTCPFrame frame = decodeModbusTCPFrame(packet2, RequestType.Response);
				writeln("2 (Res) -> %s", frame);

				pending.src.write(packet2);
			}
			else
			{
				writeln("2 -> %s", packet2);
			}
		}
		+/

		// Process program logic
		// ...

		import core.thread;
		Thread.sleep(dur!"msecs"(10));
	}
}
