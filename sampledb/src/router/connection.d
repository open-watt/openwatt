module router.connection;

import std.container.array;
import std.datetime;
import std.socket;
import std.stdio;

import router.modbus.coding;
import router.modbus.message: getMessage, ModbusMessage, ModbusProtocol = Protocol;
import router.modbus.util;
import router.serial;

enum Transport
{
	Serial,
	Ethernet
};

enum Protocol
{
    Modbus,
    HTTPPoll,
    Other // Raw?
}

enum EthernetMethod
{
    TCP,
    UDP
}

struct Packet
{
    const(ubyte)[] raw;
    ModbusMessage* modbus;
}

class Connection
{
    bool openSerialModbus(string device, ref in SerialParams params, ubyte address)
	{
        transport = Transport.Serial;
        serial.device = device;
        serial.params = params;

        protocol = Protocol.Modbus;
        modbus.protocol = ModbusProtocol.RTU;
        modbus.address = address;

        // open serial stream...
        serial.serialPort.open(device, params);

        return true;
	}

	bool createEthernetModbus(string host, ushort port, EthernetMethod method, ubyte unitId, ModbusProtocol modbusProtocol = ModbusProtocol.Unknown)
	{
        transport = Transport.Ethernet;
        ethernet.host = host;
        ethernet.port = port;
        ethernet.method = method;

        protocol = Protocol.Modbus;
        modbus.protocol = modbusProtocol;
        modbus.address = unitId;

        switch (method)
		{
            case EthernetMethod.TCP:
			    // try and connect to server...
			    ethernet.socket = new TcpSocket();
			    ethernet.socket.connect(new InternetAddress(host, port));
                break;
            case EthernetMethod.UDP:
                // maybe we need to bind to receive messages?
                assert(0);
                break;
            default:
                assert(0);
		}

        return true;
	}

    bool linkEstablished()
	{
        return false;
	}

    bool poll(out Packet packet)
	{
		ubyte[1024] buffer;

        packet.raw = null;
        packet.modbus = null;

        switch (transport)
        {
            case Transport.Serial:
                ptrdiff_t length;
                do
				{
                    length = serial.serialPort.read(buffer);
                    if (length <= 0)
                        break;
                    appendInput(buffer[0 .. length]);
				}
                while (length == buffer.sizeof);
                break;
            case Transport.Ethernet:
                switch (ethernet.method)
				{
                    case EthernetMethod.TCP:
						SocketSet readSet = new SocketSet;
						readSet.add(ethernet.socket);
						if (Socket.select(readSet, null, null, dur!"usecs"(0)))
						{
							auto length = ethernet.socket.receive(buffer);
							if (length > 0)
								appendInput(buffer[0 .. length]);
						}
                        break;
                    case EthernetMethod.UDP:
                        assert(0);
                    default:
                        assert(0);
				}
                break;
            default:
                assert(0);
		}

        if (inputLen != 0)
		{
			// Check for complete packet based on the protocol
            switch (protocol)
			{
                case Protocol.Modbus:
                    packet.modbus = new ModbusMessage;
                    ptrdiff_t len = inputBuffer[0 .. inputLen].getMessage(*packet.modbus, modbus.protocol);
                    if (len < 0)
					{
                        // what to do? purge the buffer and start over maybe?
                        assert(0);
                        return false;
					}
                    if (len > 0)
					{
                        packet.raw = takeInput(len);
                        if (modbus.protocol == ModbusProtocol.Unknown)
                            modbus.protocol = packet.modbus.frame.protocol;
					}
                    return true;

                default:
                    assert(0);
			}
		}

        return true;
    }

    void write(const(ubyte[]) data)
	{
        switch (transport)
        {
            case Transport.Serial:
				serial.serialPort.write(data);
                break;
            case Transport.Ethernet:
                switch (ethernet.method)
				{
                    case EthernetMethod.TCP:
						ethernet.socket.send(data);
                        break;
                    case EthernetMethod.UDP:
                        assert(0);
                    default:
                        assert(0);
				}
                break;
            default:
                assert(0);
		}
    }

    Transport transport;
    Protocol protocol;

	union
	{
		Serial serial;
		Ethernet ethernet;
	}
    union
	{
        Modbus modbus;
	}

private:
	ubyte[] inputBuffer;
    size_t inputLen;

	struct Serial
	{
		string device;
		SerialParams params;
		SerialPort serialPort;
	}

	struct Ethernet
	{
		string host;
		ushort port;
		EthernetMethod method;
		Socket socket;
	}

    struct Modbus
	{
		ModbusProtocol protocol;
		ubyte address;
	}

    void appendInput(const(ubyte)[] data)
	{
		if (data.length > inputBuffer.length - inputLen)
		{
			if (inputBuffer.length == 0)
				inputBuffer = new ubyte[1024];
			else
			{
				ubyte[] newBuffer = new ubyte[inputBuffer.length * 2];
				newBuffer[0 .. inputLen] = inputBuffer[0 .. inputLen];
				inputBuffer = newBuffer;
			}
		}
		inputBuffer[inputLen .. inputLen + data.length] = data[];
		inputLen += data.length;
	}

    ubyte[] takeInput(size_t bytes)
	{
        assert(bytes <= inputLen);

        ubyte[] r = inputBuffer[0 .. bytes].dup;
		inputLen -= bytes;

		for (size_t i = 0; i < inputLen; i += bytes)
		{
			import std.algorithm : min;
			size_t copy = min(inputLen - i, bytes);
			inputBuffer[i .. i + copy] = inputBuffer[i + bytes .. i + bytes + copy];
		}

        return r;
	}
}
