module protocol.modbus.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.time;

import protocol.modbus;

import router.iface;
import router.iface.modbus : ModbusFrameType; // TODO: move this?
import router.modbus.message;

enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusRequestHandler = void delegate(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU request, MonoTime requestTime) nothrow @nogc;
alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime requestTime) nothrow @nogc;
alias ModbusSnoopHandler = void delegate(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime) nothrow @nogc;

class ModbusClient
{
nothrow @nogc:

    ModbusProtocolModule.Instance m;

    String name;
    BaseInterface iface;

    ModbusRequestHandler requestHandler;
    ModbusSnoopHandler snoopHandler;

    bool snooping;

    this(ModbusProtocolModule.Instance m, String name, BaseInterface _interface, bool snooping = false) nothrow @nogc
    {
        this.m = m;
        this.name = name.move;
        this.iface = _interface;
        this.snooping = snooping;

        if (snooping)
            pending.pushBack(); // temp storage for the requests

        _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
    }

    ~this()
    {
        // TODO: unsubscribe!
    }

    void setRequestHandler(ModbusRequestHandler handler) pure nothrow @nogc
    {
        requestHandler = handler;
    }

    void setSnoopHandler(ModbusSnoopHandler snoopHandler)
    {
        this.snoopHandler = snoopHandler;
    }

    bool isSnooping() const
        => snooping;

    void sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler responseHandler, ModbusErrorHandler errorHandler = null, ubyte numRetries = 0, ushort timeout = 500) nothrow @nogc
    {
        if (snooping)
        {
            writeWarning("Modbus client '", name[], "' can't send requests while snooping bus: ", iface.name[]);
            return;
        }

        MonoTime now = getTime();
        PendingRequest* r = &pending.pushBack(PendingRequest(now, now, request, ++sequenceNumber, numRetries, timeout, server, responseHandler, errorHandler));

        import router.iface.modbus;
        ServerMap* map = m.app.moduleInstance!ModbusInterfaceModule().findServerByMac(server);
        if (!map)
            return;

        // send the packet
        ubyte[4 + ModbusMessageDataMaxLength] buffer = void;
        buffer[0] = map.universalAddress;
        buffer[1] = ModbusFrameType.Request;
        buffer[2..4] = nativeToBigEndian(sequenceNumber);
        buffer[4] = request.functionCode;
        buffer[5 .. 5 + request.data.length] = request.data[];

        iface.send(server, buffer[0 .. 5 + request.data.length], EtherType.ENMS, ENMS_SubType.Modbus);
    }

    void sendResponse(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU response) nothrow @nogc
    {
        import router.iface.modbus;
        ServerMap* map = m.app.moduleInstance!ModbusInterfaceModule().findServerByMac(client);
        if (!map)
            return;

        ubyte[4 + ModbusMessageDataMaxLength] message = void;
        message[0] = map.universalAddress;
        message[1] = ModbusFrameType.Response;
        message[2..4] = sequenceNumber.nativeToBigEndian;
        message[4] = response.functionCode;
        message[5 .. 5 + response.data.length] = response.data[];

        iface.send(client, message[0 .. 3 + response.data.length], EtherType.ENMS, ENMS_SubType.Modbus);
    }

    void update()
    {
        if (snooping)
            return;

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
        ushort sequenceNumber;
        ubyte numRetries;
        ushort timeout;
        MACAddress server;
        ModbusResponseHandler responseHandler;
        ModbusErrorHandler errorHandler;
    }

    ushort sequenceNumber = 0;
    Array!PendingRequest pending;

    void incomingPacket(ref const Packet p, BaseInterface iface, void* userData) nothrow @nogc
    {
        // we can't even identify what request a message belongs to if it's been truncated
        auto message = cast(const(ubyte)[])p.data;
        if (message.length < 5)
            return;

        ubyte address = *cast(ubyte*)&p.data[0];
        ModbusFrameType type = *cast(ModbusFrameType*)&p.data[1];
        ushort seq = message[2..4].bigEndianToNative!ushort;

        if (type == ModbusFrameType.Request && (p.dst == iface.mac || p.dst.isBroadcast))
        {
            // check that we're accepting requests...
            if (!requestHandler)
                return;

            // it's a request for us...
            ModbusPDU request = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
            requestHandler(p.src, seq, request, p.creationTime);
        }
        else if (!snooping)
        {
            foreach (i, ref PendingRequest req; pending)
            {
                if (p.src != req.server)
                    continue;
                if (seq != req.sequenceNumber)
                    continue;

                // this appears to be the message we're waiting for!
                ModbusPDU response = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                req.responseHandler(req.request, response, req.requestTime, p.creationTime);

                pending.remove(i);
                return;
            }
        }
        else if (snoopHandler)
        {
            // if the sequence number changes, it must be a new transaction
            if (pending[0].sequenceNumber != seq)
            {
                if (type != ModbusFrameType.Request)
                    return;

                pending[0].requestTime = p.creationTime;
                pending[0].request = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                pending[0].sequenceNumber = seq;
                pending[0].server = p.dst;
            }
            else
            {
                if (type != ModbusFrameType.Response || pending[0].requestTime == MonoTime())
                    return;

                ModbusPDU response = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                snoopHandler(p.src, pending[0].request, response, pending[0].requestTime, p.creationTime);
            }
        }
    }
}
