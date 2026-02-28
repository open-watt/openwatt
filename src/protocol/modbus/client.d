module protocol.modbus.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.modbus;
import protocol.modbus.iface : ModbusFrameType; // TODO: move this?
import protocol.modbus.message;

import router.iface;
import router.iface.packet : PCP;

nothrow @nogc:


enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusRequestHandler = void delegate(ref const MACAddress client, ushort sequence_number, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusSnoopHandler = void delegate(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;

class ModbusClient : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("snoop", snoop)() ];
nothrow @nogc:

    enum type_name = "mb-client";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ModbusClient, name.move, flags);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            (cast(BaseObject) _iface.get()).unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        restart();
    }

    bool snoop() const pure
        => _snooping;
    void snoop(bool value)
    {
        if (_snooping == value)
            return;
        _snooping = value;
        restart();
    }

    // API

    ModbusRequestHandler requestHandler;
    ModbusSnoopHandler snoop_handler;

    void setRequestHandler(ModbusRequestHandler handler) pure nothrow @nogc
    {
        requestHandler = handler;
    }

    void setSnoopHandler(ModbusSnoopHandler handler)
    {
        snoop_handler = handler;
    }

    bool isSnooping() const
        => _snooping;

    bool sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler response_handler, ModbusErrorHandler error_handler = null, ubyte num_retries = 0, ushort timeout = 500, PCP pcp = PCP.be, bool dei = false) nothrow @nogc
    {
        if (_snooping)
        {
            writeWarning("Modbus client '", name[], "' can't send requests while snooping bus: ", _iface.name[]);
            return false;
        }

        SysTime now = getSysTime();
        ushort seq = ++_sequence_number;
        int tag = send_packet(server, seq, request, ModbusFrameType.request, pcp, dei);
        if (tag < 0)
        {
            // queue rejected immediately — notify caller
            if (error_handler)
                error_handler(ModbusErrorType.Failed, request, now);
            return false;
        }

        pending.pushBack(PendingRequest(now, now, request, seq, num_retries, timeout, server, response_handler, error_handler, cast(ubyte) tag));
        return true;
    }

    void sendResponse(ref const MACAddress client, ushort sequence_number, ref const ModbusPDU response) nothrow @nogc
    {
        send_packet(client, sequence_number, response, ModbusFrameType.response);
    }

protected:

    override bool validate() const pure
        => _iface !is null;

    override CompletionStatus validating()
    {
        _iface.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_iface)
            restart();
        if (!_iface.running)
            return CompletionStatus.continue_;

        if (_snooping)
            pending.pushBack(); // temp storage for snooped requests

        _iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ow, ow_subtype: OW_SubType.modbus));
        (cast(BaseObject) _iface.get()).subscribe(&iface_state_change);
        _subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            (cast(BaseObject) _iface.get()).unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        // fail all pending requests
        foreach (ref req; pending)
        {
            if (req.error_handler)
                req.error_handler(ModbusErrorType.Failed, req.request, req.request_time);
        }
        pending.clear();

        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_snooping)
            return;

        // backstop timeout; primary timeout/failure handling is via queue callbacks (send_status)
        // TODO: do we actually need this now? maybe the queue can take over?
        for (size_t i = 0; i < pending.length;)
        {
            PendingRequest* req = &pending[i];

            SysTime now = getSysTime();

            if (req.retry_time + msecs(req.timeout * 2) < now)
            {
                if (req.num_retries > 0)
                {
                    req.retry_time = now;
                    int new_tag = send_packet(req.server, req.sequence_number, req.request, ModbusFrameType.request);
                    if (new_tag >= 0)
                    {
                        req.tag = cast(ubyte) new_tag;
                        req.num_retries--;
                        if (req.error_handler)
                            req.error_handler(ModbusErrorType.Retrying, req.request, req.retry_time);
                    }
                }
                else
                {
                    if (req.error_handler)
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
        SysTime retry_time;
        ModbusPDU request;
        ushort sequence_number;
        ubyte num_retries;
        ushort timeout;
        MACAddress server;
        ModbusResponseHandler response_handler;
        ModbusErrorHandler error_handler;
        ubyte tag;
    }

    ObjectRef!BaseInterface _iface;
    bool _snooping;
    bool _subscribed;
    ushort _sequence_number = 0;
    Array!PendingRequest pending;

    void iface_state_change(BaseObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        // we can't even identify what request a message belongs to if it's been truncated
        auto message = cast(const(ubyte)[])p.data;
        if (message.length < 5)
            return;

        ushort seq = message[0 .. 2].bigEndianToNative!ushort;
        ModbusFrameType type = cast(ModbusFrameType) message[2];
        ubyte address = message[3];

        if (type == ModbusFrameType.request && (p.eth.dst == iface.mac || p.eth.dst.isBroadcast))
        {
            // check that we're accepting requests...
            if (!requestHandler)
                return;

            // it's a request for us...
            ModbusPDU request = ModbusPDU(cast(FunctionCode) message[4], message[5 .. $]);
            requestHandler(p.eth.src, seq, request, p.creation_time);
        }
        else if (!_snooping)
        {
            foreach (i, ref PendingRequest req; pending)
            {
                if (p.eth.src != req.server)
                    continue;
                if (seq != req.sequence_number)
                    continue;

                // this appears to be the message we're waiting for!
                ModbusPDU response = ModbusPDU(cast(FunctionCode) message[4], message[5 .. $]);
                req.response_handler(req.request, response, req.request_time, p.creation_time);

                pending.remove(i);
                return;
            }
        }
        else if (snoop_handler)
        {
            // if the sequence number changes, it must be a new transaction
            if (pending[0].sequence_number != seq)
            {
                if (type != ModbusFrameType.request)
                    return;

                pending[0].request_time = p.creation_time;
                pending[0].request = ModbusPDU(cast(FunctionCode) message[4], message[5 .. $]);
                pending[0].sequence_number = seq;
                pending[0].server = p.eth.dst;
            }
            else
            {
                if (type != ModbusFrameType.response || pending[0].request_time == SysTime())
                    return;

                ModbusPDU response = ModbusPDU(cast(FunctionCode) message[4], message[5 .. $]);
                snoop_handler(p.eth.src, pending[0].request, response, pending[0].request_time, p.creation_time);
            }
        }
    }

    void send_status(int msg_handle, MessageState state) nothrow @nogc
    {
        if (msg_handle < 0)
            return;

        // only act on failure states; successful delivery is handled by incoming_packet
        if (state < MessageState.failed)
            return;

        ubyte tag = cast(ubyte)msg_handle;
        foreach (i, ref PendingRequest req; pending)
        {
            if (req.tag != tag)
                continue;

            if (req.error_handler)
                req.error_handler(ModbusErrorType.Failed, req.request, req.request_time);
            pending.remove(i);
            break;
        }
    }

    int send_packet(ref const MACAddress server, ushort sequence_number, ref const ModbusPDU message, ModbusFrameType type, PCP pcp = PCP.be, bool dei = false) nothrow @nogc
    {
        ServerMap* map = get_module!ModbusProtocolModule().find_server_by_mac(server);
        if (!map)
            return -1;

        ubyte[4 + ModbusMessageDataMaxLength] buffer = void;
        buffer[0 .. 2] = sequence_number.nativeToBigEndian;
        buffer[2] = type;
        buffer[3] = map.universal_address;
        buffer[4] = message.function_code;
        buffer[5 .. 5 + message.data.length] = message.data[];

        Packet p;
        ref Ethernet hdr = p.init!Ethernet(buffer[0 .. 5 + message.data.length]);
        hdr.src = _iface.mac;
        hdr.dst = server;
        hdr.ether_type = EtherType.ow;
        hdr.ow_sub_type = OW_SubType.modbus;
        p.pcp = pcp;
        p.dei = dei;

        // only attach lifecycle callback for requests (not slave responses)
        MessageCallback cb = type == ModbusFrameType.request ? &send_status : null;
        return _iface.forward(p, cb);
    }
}
