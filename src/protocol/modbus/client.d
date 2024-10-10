module protocol.modbus.client;

import urt.array;
import urt.lifetime;
import urt.string;
import urt.time;

import protocol.modbus;

import router.iface;
import router.modbus.message;

enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime requestTime) nothrow @nogc;

class ModbusClient
{
nothrow @nogc:

    ModbusProtocolModule.Instance m;

    String name;
    BaseInterface iface;

    this(ModbusProtocolModule.Instance m, String name, BaseInterface _interface) nothrow @nogc
    {
        this.m = m;
        this.name = name.move;
        this.iface = _interface;

        _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
    }

    ~this()
    {
        // TODO: unsubscribe!
    }

    void sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler responseHandler, ModbusErrorHandler errorHandler = null, ubyte numRetries = 0, ushort timeout = 500) nothrow @nogc
    {
        MonoTime now = getTime();
        PendingRequest* r = &pending.pushBack(PendingRequest(now, now, request, numRetries, timeout, server, responseHandler, errorHandler));

        // send the packet
        void[] msg = (cast(void*)&request)[0 .. 1 + request.data.length];
        iface.send(server, msg, EtherType.ENMS, ENMS_SubType.Modbus);
    }

    void update()
    {
        for (size_t i = 0; i < pending.length; )
        {
            PendingRequest* req = &pending[i];

            MonoTime now = getTime();

            if (req.retryTime + msecs(req.timeout) < now)
            {
                if (req.numRetries > 0)
                {
                    req.numRetries--;
                    req.retryTime = now;
                    void[] msg = (cast(void*)&req.request)[0 .. 1 + req.request.data.length];
                    iface.send(req.server, msg, EtherType.ENMS, ENMS_SubType.Modbus);
                    req.errorHandler(ModbusErrorType.Retrying, req.request, req.retryTime);
                }
                else
                {
                    req.errorHandler(ModbusErrorType.Timeout, req.request, req.requestTime);
                    pending.remove(i);
                    continue;
                }
            }
            ++i;
        }
    }

private:
    struct PendingRequest
    {
        MonoTime requestTime;
        MonoTime retryTime;
        ModbusPDU request;
        ubyte numRetries;
        ushort timeout;
        MACAddress server;
        ModbusResponseHandler responseHandler;
        ModbusErrorHandler errorHandler;
    }

    Array!PendingRequest pending;

    void incomingPacket(ref const Packet p, BaseInterface iface, void* userData) nothrow @nogc
    {
        foreach (i, ref PendingRequest req; pending)
        {
            if (p.src != req.server)
                continue;

            // this appears to be the message we're waiting for!
            auto message = cast(const(ubyte)[])p.data[];
            ModbusPDU response = ModbusPDU(cast(FunctionCode)message[0], message[1 .. $]);
            req.responseHandler(req.request, response, req.requestTime, p.creationTime);

            pending.remove(i);
            return;
        }
    }
}
