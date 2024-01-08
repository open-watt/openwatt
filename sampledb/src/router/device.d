module router.device;

import std.stdio;

import router.client : Request;
import router.connection;
import router.modbus.message : frameRTUMessage, frameTCPMessage, ModbusPDU, ModbusProtocol = Protocol;
import router.modbus.profile;
import router.serial : SerialParams;

class Device
{
    this(string name)
	{
		this.name = name;
	}

	bool createModbus(Connection connection, const ModbusProfile* profile = null)
	{
        this.connection = connection;

        protocol = Protocol.Modbus;
        modbus.profile = profile;

        return true;
	}

    bool createSerialModbus(string device, ref in SerialParams params, ubyte address, const ModbusProfile* profile = null)
	{
        connection = new Connection;
        connection.openSerialModbus(device, params, address);

        protocol = Protocol.Modbus;
        modbus.profile = profile;

        return true;
	}

	bool createEthernetModbus(string host, ushort port, EthernetMethod method, ubyte unitId, ModbusProtocol modbusProtocol, const ModbusProfile* profile = null)
	{
        assert(modbusProtocol != ModbusProtocol.Unknown, "Can't guess modbus protocol for slave devices");

		connection = new Connection;
        connection.createEthernetModbus(host, port, method, unitId, modbusProtocol);

        protocol = Protocol.Modbus;
        modbus.profile = profile;

        return true;
	}

    bool linkEstablished()
	{
        return false;
	}

    bool requestData(Request* request)
	{
        // request data by high-level id
        return false;
	}

    bool sendModbusRequest(Request* request)
	{
        assert(protocol == Protocol.Modbus);
        assert(request.client.protocol == Protocol.Modbus);

        if (connection.modbus.protocol != ModbusProtocol.TCP)
		{
            // if there's a request in flight, we need to queue...
            if (modbus.pendingRequests.length > 0)
                modbus.requestQueue ~= request;
            return true;
		}

        if (request.client.modbus.profile != modbus.profile &&
            request.client.modbus.profile && modbus.profile)
		{
			// TODO: if the profiles are mismatching, then we need to translate...
            assert(0);
		}

        ubyte[1024] buffer;
        ubyte[] packet;
        switch (connection.modbus.protocol)
		{
            case ModbusProtocol.RTU:
                packet = frameRTUMessage(connection.modbus.address,
										 request.packet.modbus.message.functionCode,
										 request.packet.modbus.message.data,
										 buffer);
                modbus.pendingRequests ~= PendingRequest(request, 0);
                break;
            case ModbusProtocol.TCP:
                packet = frameTCPMessage(modbus.nextTransactionId,
										 connection.modbus.address,
										 request.packet.modbus.message.functionCode,
										 request.packet.modbus.message.data,
										 buffer);
                modbus.pendingRequests ~= PendingRequest(request, modbus.nextTransactionId++);
                break;
            default:
                assert(0);
		}

        connection.write(packet);

        return true;
	}

    Response* poll()
	{
		Response* response = null;

		Packet packet;
		bool success = connection.poll(packet);
        if (success && packet.raw)
		{
            response = new Response;
            response.device = this;
            response.packet = packet;
		}

        if (protocol == Protocol.Modbus)
		{
            response.request = popPendingRequest(connection.modbus.protocol == ModbusProtocol.TCP ? packet.modbus.frame.tcp.transactionId : 0);

            if (connection.modbus.protocol != ModbusProtocol.TCP)
		    {
                // there are requests in the queue; we'll dispatch the next one...
                Request* req = popModbusRequest();
                if (req)
                    sendModbusRequest(req);
			}
		}
        else
		{
            // TODO: how do we associate the request?
            assert(0);
		}

        return response;
	}

public:
    string name;
    Connection connection;

    Protocol protocol;
    union
	{
        Modbus modbus;
	}

private:
    struct Modbus
	{
		const(ModbusProfile)* profile;
        PendingRequest[] pendingRequests;
        Request*[] requestQueue;
		RegValue[int] regValues;
        short nextTransactionId;
	}

    Request* popModbusRequest()
	{
        if (modbus.requestQueue.length == 0)
            return null;
        Request* next = modbus.requestQueue[0];
        for (size_t i = 1; i < modbus.requestQueue.length; ++i)
            modbus.requestQueue[i - 1] = modbus.requestQueue[i];
        --modbus.requestQueue.length;
        return next;
	}

	Request* popPendingRequest(ushort transactionId)
	{
        assert(modbus.pendingRequests.length > 0);

        Request* r = null;
        size_t i = 0;
        for (; i < modbus.pendingRequests.length; ++i)
		{
            if (modbus.pendingRequests[i].transactionId == transactionId)
			{
                r = modbus.pendingRequests[i].request;
                break;
			}
		}
		for (; i < modbus.pendingRequests.length - 1; ++i)
            modbus.pendingRequests[i] = modbus.pendingRequests[i + 1];
        --modbus.pendingRequests.length;
        return r;
	}

    struct PendingRequest
	{
        Request* request;
        ushort transactionId;
	}
}

struct Response
{
    Device device;
    Request* request;
	Packet packet;
}
