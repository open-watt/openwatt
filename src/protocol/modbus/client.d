module protocol.modbus.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.time;

import protocol.modbus;
import protocol.modbus.message;

import router.iface;
import router.iface.modbus : ModbusFrameType; // TODO: move this?

import manager;

nothrow @nogc:


enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusRequestHandler = void delegate(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusSnoopHandler = void delegate(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;

class ModbusClient
{
nothrow @nogc:

    ModbusProtocolModule m;

    String name;
    BaseInterface iface;

    ModbusRequestHandler requestHandler;
    ModbusSnoopHandler snoop_handler;

    bool snooping;

    this(ModbusProtocolModule m, String name, BaseInterface _interface, bool snooping = false) nothrow @nogc
    {
        this.m = m;
        this.name = name.move;
        this.iface = _interface;
        this.snooping = snooping;

        if (snooping)
            pending.pushBack(); // temp storage for the requests

        _interface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ow, ow_subtype: OW_SubType.modbus));
    }

    ~this()
    {
        iface.unsubscribe(&incoming_packet);
    }

    void setRequestHandler(ModbusRequestHandler handler) pure nothrow @nogc
    {
        requestHandler = handler;
    }

    void setSnoopHandler(ModbusSnoopHandler snoop_handler)
    {
        this.snoop_handler = snoop_handler;
    }

    bool isSnooping() const
        => snooping;

    void sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler response_handler, ModbusErrorHandler error_handler = null, ubyte numRetries = 0, ushort timeout = 500) nothrow @nogc
    {
        if (snooping)
        {
            writeWarning("Modbus client '", name[], "' can't send requests while snooping bus: ", iface.name[]);
            return;
        }

        SysTime now = getSysTime();
        PendingRequest* r = &pending.pushBack(PendingRequest(now, now, request, ++sequenceNumber, numRetries, timeout, server, response_handler, error_handler));

        sendPacket(server, sequenceNumber, request, ModbusFrameType.request);
    }

    void sendResponse(ref const MACAddress client, ushort sequenceNumber, ref const ModbusPDU response) nothrow @nogc
    {
        sendPacket(client, sequenceNumber, response, ModbusFrameType.response);
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
                    req.retryTime = now;
                    if (sendPacket(req.server, req.sequenceNumber, req.request, ModbusFrameType.request))
                    {
                        req.numRetries--;
                        if (req.error_handler)
                            req.error_handler(ModbusErrorType.Retrying, req.request, req.retryTime);
                    }
                }
                else
                {
                    req.error_handler(ModbusErrorType.Timeout, req.request, req.request_time);
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
        SysTime request_time;
        SysTime retryTime;
        ModbusPDU request;
        ushort sequenceNumber;
        ubyte numRetries;
        ushort timeout;
        MACAddress server;
        ModbusResponseHandler response_handler;
        ModbusErrorHandler error_handler;
    }

    ushort sequenceNumber = 0;
    Array!PendingRequest pending;

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        // we can't even identify what request a message belongs to if it's been truncated
        auto message = cast(const(ubyte)[])p.data;
        if (message.length < 5)
            return;

        ushort seq = message[0..2].bigEndianToNative!ushort;
        ModbusFrameType type = cast(ModbusFrameType)message[2];
        ubyte address = message[3];

        if (type == ModbusFrameType.request && (p.eth.dst == iface.mac || p.eth.dst.isBroadcast))
        {
            // check that we're accepting requests...
            if (!requestHandler)
                return;

            // it's a request for us...
            ModbusPDU request = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
            requestHandler(p.eth.src, seq, request, p.creation_time);
        }
        else if (!snooping)
        {
            foreach (i, ref PendingRequest req; pending)
            {
                if (p.eth.src != req.server)
                    continue;
                if (seq != req.sequenceNumber)
                    continue;

                // this appears to be the message we're waiting for!
                ModbusPDU response = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                req.response_handler(req.request, response, req.request_time, p.creation_time);

                pending.remove(i);
                return;
            }
        }
        else if (snoop_handler)
        {
            // if the sequence number changes, it must be a new transaction
            if (pending[0].sequenceNumber != seq)
            {
                if (type != ModbusFrameType.request)
                    return;

                pending[0].request_time = p.creation_time;
                pending[0].request = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                pending[0].sequenceNumber = seq;
                pending[0].server = p.eth.dst;
            }
            else
            {
                if (type != ModbusFrameType.response || pending[0].request_time == SysTime())
                    return;

                ModbusPDU response = ModbusPDU(cast(FunctionCode)message[4], message[5 .. $]);
                snoop_handler(p.eth.src, pending[0].request, response, pending[0].request_time, p.creation_time);
            }
        }
    }

    bool sendPacket(ref const MACAddress server, ushort sequenceNumber, ref const ModbusPDU message, ModbusFrameType type) nothrow @nogc
    {
        import router.iface.modbus;
        ServerMap* map = get_module!ModbusInterfaceModule().find_server_by_mac(server);
        if (!map)
            return false;

        ubyte[4 + ModbusMessageDataMaxLength] buffer = void;
        buffer[0..2] = sequenceNumber.nativeToBigEndian;
        buffer[2] = type;
        buffer[3] = map.universal_address;
        buffer[4] = message.function_code;
        buffer[5 .. 5 + message.data.length] = message.data[];

        Packet p;
        ref Ethernet hdr = p.init!Ethernet(buffer[0 .. 5 + message.data.length]);
        hdr.src = iface.mac;
        hdr.dst = server;
        hdr.ether_type = EtherType.ow;
        hdr.ow_sub_type = OW_SubType.modbus;

        return iface.forward(p) >= 0;
    }
}
