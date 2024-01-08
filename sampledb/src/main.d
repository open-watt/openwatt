module main;

import std.format;
import std.stdio;

import router.client;
import router.connection;
import router.device;

import router.modbus.coding;
import router.modbus.message : ModbusProtocol = Protocol;
import router.modbus.profile;
import router.modbus.profile.solaredge_meter;


void main()
{
    ModbusProfile* se_meter_profile = new ModbusProfile;
    se_meter_profile.populateRegs(solarEdgeRegs);

    Client se_inverter = new Client();
    se_inverter.createEthernetModbus("192.168.3.7", 8001, EthernetMethod.TCP, 2, ModbusProtocol.RTU, se_meter_profile);

    Device se_meter = new Device("se_meter");
    se_meter.createEthernetModbus("192.168.3.7", 8002, EthernetMethod.TCP, 2, ModbusProtocol.RTU, se_meter_profile);


    while (true)
	{
        Request* req = se_inverter.poll();
        Response* resp = se_meter.poll();

//        const(ubyte)[] packet = tcpConnection.poll();
//        const(ubyte)[] packet2 = tcpConnection2.poll();
//        const(ubyte)[] packet3 = serialConnection.poll();

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
