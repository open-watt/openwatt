module protocol.modbus.client;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.modbus;
import protocol.modbus.iface : ModbusFrame, ModbusFrameType;
import protocol.modbus.message;

import router.iface;
import router.iface.packet : PacketType, PCP;

version = TrackLateResponses;

nothrow @nogc:


enum ModbusErrorType
{
    Retrying,
    Timeout,
    Failed,
}

alias ModbusRequestHandler = void delegate(ubyte client_address, ushort sequence_number, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;
alias ModbusErrorHandler = void delegate(ModbusErrorType errorType, ref const ModbusPDU request, SysTime request_time) nothrow @nogc;
alias ModbusSnoopHandler = void delegate(ubyte server_address, ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time) nothrow @nogc;

class ModbusClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("snoop", snoop));
nothrow @nogc:

    enum type_name = "mb-client";
    enum path = "/protocol/modbus/client";
    enum collection_id = CollectionType.mb_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ModbusClient, id, flags);
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
            _iface.unsubscribe(&iface_state_change);
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

    bool sendRequest(ubyte server_address, ref const ModbusPDU request, ModbusResponseHandler response_handler, ModbusErrorHandler error_handler = null, ubyte num_retries = 0, ushort timeout = 500, PCP pcp = PCP.be, bool dei = false) nothrow @nogc
    {
        if (_snooping)
        {
            writeWarning("Modbus client '", name[], "' can't send requests while snooping bus: ", _iface.name[]);
            return false;
        }

        SysTime now = getSysTime();
        ushort seq = ++_sequence_number;
        int tag = send_packet(server_address, seq, request, ModbusFrameType.request, pcp, dei);
        if (tag < 0)
        {
            // queue rejected immediately — notify caller
            if (error_handler)
                error_handler(ModbusErrorType.Failed, request, now);
            return false;
        }

        _pending.pushBack(PendingRequest(now, now, request, seq, num_retries, timeout, server_address, response_handler, error_handler, cast(ubyte) tag));
        return true;
    }

    void sendResponse(ubyte client_address, ushort sequence_number, ref const ModbusPDU response) nothrow @nogc
    {
        send_packet(client_address, sequence_number, response, ModbusFrameType.response);
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _iface !is null;

    override CompletionStatus startup()
    {
        if (!_iface)
            restart();
        if (!_iface.running)
            return CompletionStatus.continue_;

        if (_client_address == 0)
            _client_address = get_module!ModbusProtocolModule().allocate_universal_address(ephemeral: true);

        if (_snooping)
            _pending.pushBack(); // temp storage for snooped requests

        _iface.subscribe(&incoming_packet, PacketFilter(type: PacketType.modbus));
        _iface.subscribe(&iface_state_change);
        _subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        if (_client_address != 0)
        {
            get_module!ModbusProtocolModule().release_universal_address(_client_address);
            _client_address = 0;
        }

        // fail all pending requests
        foreach (ref req; _pending)
        {
            if (req.error_handler)
                req.error_handler(ModbusErrorType.Failed, req.request, req.request_time);
        }
        _pending.clear();

        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_snooping)
            return;

        // backstop timeout; primary timeout/failure handling is via queue callbacks (send_status)
        // TODO: do we actually need this now? maybe the queue can take over?
        for (size_t i = 0; i < _pending.length;)
        {
            PendingRequest* req = &_pending[i];

            SysTime now = getSysTime();

            if (req.retry_time + msecs(req.timeout * 2) < now)
            {
                long elapsed_ms = (now - req.request_time).as!"msecs";
                writeDebug(name[], ": backstop timeout seq=", req.sequence_number, " tag=", req.tag, " server=", req.server_address,
                    " elapsed=", elapsed_ms, "ms timeout=", req.timeout * 2, "ms", " retries=", req.num_retries);

                if (req.tag > 0)
                {
                    auto old_tag = req.tag;
                    req.tag = 0; // clear before abort so send_status won't remove this entry
                    _iface.abort(old_tag);
                }
                version (TrackLateResponses)
                    record_abandoned(*req);

                if (req.num_retries > 0)
                {
                    req.retry_time = now;
                    int new_tag = send_packet(req.server_address, req.sequence_number, req.request, ModbusFrameType.request);
                    if (new_tag >= 0)
                    {
                        req.tag = cast(ubyte)new_tag;
                        req.num_retries--;
                        if (req.error_handler)
                            req.error_handler(ModbusErrorType.Retrying, req.request, req.retry_time);
                    }
                }
                else
                {
                    if (req.error_handler)
                        req.error_handler(ModbusErrorType.Timeout, req.request, req.request_time);
                    _pending.remove(i);
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
        ubyte server_address;
        ModbusResponseHandler response_handler;
        ModbusErrorHandler error_handler;
        ubyte tag;
    }

    ObjectRef!BaseInterface _iface;
    bool _snooping;
    bool _subscribed;
    ubyte _client_address;
    ushort _sequence_number = 0;
    Array!PendingRequest _pending;

    version (TrackLateResponses)
    {
        struct AbandonedRequest
        {
            ushort sequence_number;
            SysTime abandon_time;
        }

        AbandonedRequest[8] _abandoned;
        ubyte _abandoned_pos;

        void record_abandoned(ref const PendingRequest req)
        {
            _abandoned[_abandoned_pos++ & 7] = AbandonedRequest(req.sequence_number, getSysTime());
        }
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        auto pdu = cast(const(ubyte)[])p.data;
        if (pdu.length < 1)
            return;

        ref const ModbusFrame hdr = p.hdr!ModbusFrame();

        if (hdr.type == ModbusFrameType.request && hdr.dst_address == _client_address)
        {
            if (!requestHandler)
                return;

            ModbusPDU request = ModbusPDU(cast(FunctionCode)pdu[0], pdu[1 .. $]);
            requestHandler(hdr.src_address, hdr.sequence_number, request, p.creation_time);
        }
        else if (!_snooping)
        {
            foreach (i, ref PendingRequest req; _pending)
            {
                if (hdr.src_address != req.server_address)
                    continue;
                if (hdr.sequence_number != req.sequence_number)
                    continue;

                ModbusPDU response = ModbusPDU(cast(FunctionCode)pdu[0], pdu[1 .. $]);
                req.response_handler(req.request, response, req.request_time, p.creation_time);

                _pending.remove(i);
                return;
            }

            version (TrackLateResponses)
            {
                foreach (ref ab; _abandoned)
                {
                    if (ab.sequence_number == hdr.sequence_number)
                    {
                        long late_ms = (p.creation_time - ab.abandon_time).as!"msecs";
                        log.debug_("late response from addr=", hdr.src_address, " seq=", hdr.sequence_number, " late=", late_ms, "ms");
                        return;
                    }
                }
            }
        }
        else if (snoop_handler)
        {
            // if the sequence number changes, it must be a new transaction
            if (_pending[0].sequence_number != hdr.sequence_number)
            {
                if (hdr.type != ModbusFrameType.request)
                    return;

                _pending[0].request_time = p.creation_time;
                _pending[0].request = ModbusPDU(cast(FunctionCode)pdu[0], pdu[1 .. $]);
                _pending[0].sequence_number = hdr.sequence_number;
                _pending[0].server_address = hdr.dst_address;
            }
            else
            {
                if (hdr.type != ModbusFrameType.response || _pending[0].request_time == SysTime())
                    return;

                ModbusPDU response = ModbusPDU(cast(FunctionCode)pdu[0], pdu[1 .. $]);
                snoop_handler(hdr.src_address, _pending[0].request, response, _pending[0].request_time, p.creation_time);
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
        foreach (i, ref PendingRequest req; _pending)
        {
            if (req.tag != tag)
                continue;

            version (TrackLateResponses)
                record_abandoned(req);
            if (req.error_handler)
                req.error_handler(ModbusErrorType.Failed, req.request, req.request_time);
            _pending.remove(i);
            break;
        }
    }

    int send_packet(ubyte dst_address, ushort sequence_number, ref const ModbusPDU message, ModbusFrameType type, PCP pcp = PCP.be, bool dei = false) nothrow @nogc
    {
        ubyte[1 + ModbusMessageDataMaxLength] buffer = void;
        buffer[0] = message.function_code;
        buffer[1 .. 1 + message.data.length] = message.data[];

        Packet p;
        ref ModbusFrame hdr = p.init!ModbusFrame(buffer[0 .. 1 + message.data.length]);
        hdr.sequence_number = sequence_number;
        hdr.type = type;
        hdr.function_code = message.function_code;
        hdr.src_address = _client_address;
        hdr.dst_address = dst_address;
        p.pcp = pcp;
        p.dei = dei;

        MessageCallback cb = type == ModbusFrameType.request ? &send_status : null;
        return _iface.forward(p, cb);
    }
}
