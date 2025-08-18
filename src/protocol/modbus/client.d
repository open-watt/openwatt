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

import manager;

nothrow @nogc:


enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusRequestHandler = void delegate(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU request, SysTime requestTime) nothrow @nogc;
alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, SysTime requestTime, SysTime responseTime) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, SysTime requestTime) nothrow @nogc;
alias ModbusSnoopHandler = void delegate(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, SysTime requestTime, SysTime responseTime) nothrow @nogc;

class ModbusClient
{
nothrow @nogc:

    ModbusProtocolModule m;

    String name;
    BaseInterface iface;

    ModbusRequestHandler requestHandler;
    ModbusSnoopHandler snoopHandler;

    bool snooping;

    this(ModbusProtocolModule m, String name, BaseInterface _interface, bool snooping = false) nothrow @nogc
    {
        this.m = m;
        this.name = name.move;
        this.iface = _interface;
        this.snooping = snooping;

        if (snooping)
            pending.pushBack(); // temp storage for the requests

        _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.OW, owSubType: OW_SubType.Modbus));
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

        SysTime now = getSysTime();
        PendingRequest* r = &pending.pushBack(PendingRequest(now, now, request, ++sequenceNumber, numRetries, timeout, server, responseHandler, errorHandler));

        sendPacket(server, sequenceNumber, request, ModbusFrameType.Request);
    }

    void sendResponse(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU response) nothrow @nogc
    {
        sendPacket(client, sequenceNumber, response, ModbusFrameType.Response);
    }

    void update()
    {
        if (snooping)
            return;

        for (size_t i = 0; i < pending.length; )
        {
            PendingRequest* req = &pending[i];

            SysTime now = getSysTime();

            if (req.retryTime + msecs(req.timeout) < now)
            {
                if (req.numRetries > 0)
                {
                    req.numRetries--;
                    req.retryTime = now;
                    void[] msg = (cast(void*)&req.request)[0 .. 1 + req.request.data.length];
                    iface.send(req.server, msg, EtherType.OW, OW_SubType.Modbus);
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
        SysTime requestTime;
        SysTime retryTime;
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

    void incomingPacket(ref const Packet p, BaseInterface iface, PacketDirection dir, void* userData) nothrow @nogc
    {
        // we can't even identify what request a message belongs to if it's been truncated
        auto message = cast(const(ubyte)[])p.data;
        if (message.length < 5)
            return;

        ushort seq = message[0..2].bigEndianToNative!ushort;
        ModbusFrameType type = cast(ModbusFrameType)message[2];
        ubyte address = message[3];

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
                if (type != ModbusFrameType.Response || pending[0].requestTime == SysTime())
                    return;

                ModbusPDU response = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                snoopHandler(p.src, pending[0].request, response, pending[0].requestTime, p.creationTime);
            }
        }
    }

    void sendPacket(ref const MACAddress server, ushort sequenceNumber, ref const ModbusPDU message, ModbusFrameType type) nothrow @nogc
    {
        import router.iface.modbus;
        ServerMap* map = getModule!ModbusInterfaceModule().findServerByMac(server);
        if (!map)
            return;

        ubyte[4 + ModbusMessageDataMaxLength] buffer = void;
        buffer[0..2] = sequenceNumber.nativeToBigEndian;
        buffer[2] = type;
        buffer[3] = map.universalAddress;
        buffer[4] = message.functionCode;
        buffer[5 .. 5 + message.data.length] = message.data[];

        iface.send(server, buffer[0 .. 5 + message.data.length], EtherType.OW, OW_SubType.Modbus);
    }
}
