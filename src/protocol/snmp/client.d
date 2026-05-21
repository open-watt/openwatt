module protocol.snmp.client;

import urt.array;
import urt.inet;
import urt.lifetime : move;
import urt.log;
import urt.meta : AliasSeq;
import urt.socket;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.snmp.asn1;
import protocol.snmp.oid;
import protocol.snmp.pdu;

nothrow @nogc:


enum SNMPClientErrorType
{
    timeout,
    failed,
    aborted,
}

alias SNMPResponseHandler = void delegate(ref PDU request, ref PDU response, SysTime request_time, SysTime response_time) nothrow @nogc;
alias SNMPClientErrorHandler = void delegate(SNMPClientErrorType err, ref PDU request, SysTime request_time) nothrow @nogc;


class SNMPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("community", community),
                                 Prop!("version", version_),
                                 Prop!("timeout", timeout),
                                 Prop!("retries", retries));
nothrow @nogc:

    enum type_name = "snmp-client";
    enum path = "/protocol/snmp/client";
    enum collection_id = CollectionType.snmp_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SNMPClient, id, flags);
        _community = StringLit!"public";
        _timeout = 1.seconds;
    }

    InetAddress remote() const pure
        => _remote;
    void remote(InetAddress value)
    {
        if (auto v4 = value.as_ipv4())
        {
            if (v4.port == 0)
                value = InetAddress(v4.addr, WellKnownPort.SNMP);
        }
        else if (auto v6 = value.as_ipv6())
        {
            if (v6.port == 0)
                value = InetAddress(v6.addr, WellKnownPort.SNMP);
        }
        if (value == _remote)
            return;
        _remote = value;
        restart();
    }

    ref const(String) community() const pure
        => _community;
    void community(String value)
    {
        if (value.empty)
            value = StringLit!"public";
        _community = value.move;
    }

    SNMPVersion version_() const pure
        => _version;
    void version_(SNMPVersion value)
    {
        _version = value;
    }

    Duration timeout() const pure
        => _timeout;
    void timeout(Duration value)
    {
        _timeout = value;
    }

    int retries() const pure
        => _retries;
    void retries(int value)
    {
        if (value < 0)
            value = 0;
        _retries = value;
    }

    // API...

    bool send_request(PDU pdu, SNMPResponseHandler response_handler, SNMPClientErrorHandler error_handler = null)
    {
        if (!running)
            return false;

        pdu.request_id = ++_next_request_id;
        if (pdu.request_id == 0)
            pdu.request_id = ++_next_request_id;

        SysTime now = getSysTime();
        if (!encode_and_send(pdu))
        {
            if (error_handler)
                error_handler(SNMPClientErrorType.failed, pdu, now);
            return false;
        }

        _pending ~= PendingRequest(pdu.move, response_handler, error_handler, now, now, cast(ubyte)_retries);
        return true;
    }

    bool get(Array!OID names, SNMPResponseHandler response_handler, SNMPClientErrorHandler error_handler = null)
        => send_named_request(PDUType.get_request, names.move, response_handler, error_handler);

    bool get_next(Array!OID names, SNMPResponseHandler response_handler, SNMPClientErrorHandler error_handler = null)
        => send_named_request(PDUType.get_next_request, names.move, response_handler, error_handler);

    bool get_bulk(Array!OID names, int non_repeaters, int max_repetitions,
                  SNMPResponseHandler response_handler, SNMPClientErrorHandler error_handler = null)
    {
        PDU pdu;
        pdu.type = PDUType.get_bulk_request;
        pdu.non_repeaters = non_repeaters;
        pdu.max_repetitions = max_repetitions;
        foreach (ref name; names)
        {
            VarBind vb;
            vb.name = name.move;
            vb.value = VarBindValue.make_null();
            pdu.varbinds ~= vb.move;
        }
        return send_request(pdu.move, response_handler, error_handler);
    }

    bool set_(Array!VarBind varbinds, SNMPResponseHandler response_handler, SNMPClientErrorHandler error_handler = null)
    {
        PDU pdu;
        pdu.type = PDUType.set_request;
        pdu.varbinds = varbinds.move;
        return send_request(pdu.move, response_handler, error_handler);
    }

protected:
    override bool validate() const
        => _remote.family == AddressFamily.ipv4 || _remote.family == AddressFamily.ipv6;

    override CompletionStatus startup()
    {
        AddressFamily af = _remote.family == AddressFamily.ipv6 ? AddressFamily.ipv6 : AddressFamily.ipv4;
        Result r = create_socket(af, SocketType.datagram, Protocol.udp, _socket);
        if (!r)
            return CompletionStatus.error;
        r = _socket.set_socket_option(SocketOption.non_blocking, true);
        if (!r)
        {
            _socket.close();
            _socket = null;
            return CompletionStatus.error;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_socket)
        {
            _socket.close();
            _socket = null;
        }
        foreach (ref req; _pending)
        {
            if (req.error_handler)
                req.error_handler(SNMPClientErrorType.aborted, req.request, req.request_time);
        }
        _pending.clear();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_socket)
            return;

        ubyte[1500] buffer = void;
        InetAddress sender;
        size_t bytes;
        while (_socket.recvfrom(buffer[], MsgFlags.none, &sender, &bytes))
        {
            if (bytes == 0)
                break;
            handle_response(buffer[0 .. bytes]);
        }

        SysTime now = getSysTime();
        for (size_t i = 0; i < _pending.length;)
        {
            ref PendingRequest req = _pending[i];
            if (now - req.send_time < _timeout)
            {
                ++i;
                continue;
            }
            if (req.retries_left > 0)
            {
                --req.retries_left;
                req.send_time = now;
                if (!encode_and_send(req.request))
                {
                    if (req.error_handler)
                        req.error_handler(SNMPClientErrorType.failed, req.request, req.request_time);
                    _pending.remove(i);
                    continue;
                }
                ++i;
            }
            else
            {
                if (req.error_handler)
                    req.error_handler(SNMPClientErrorType.timeout, req.request, req.request_time);
                _pending.remove(i);
            }
        }
    }

private:
    InetAddress _remote;
    String _community;
    SNMPVersion _version = SNMPVersion.v2c;
    Duration _timeout;
    int _retries = 3;

    Socket _socket;
    int _next_request_id = 0;

    struct PendingRequest
    {
        PDU request;
        SNMPResponseHandler response_handler;
        SNMPClientErrorHandler error_handler;
        SysTime request_time;
        SysTime send_time;
        ubyte retries_left;
    }
    Array!PendingRequest _pending;

    bool send_named_request(PDUType type, Array!OID names,
                            SNMPResponseHandler resp, SNMPClientErrorHandler err)
    {
        PDU pdu;
        pdu.type = type;
        foreach (ref name; names)
        {
            VarBind vb;
            vb.name = name.move;
            vb.value = VarBindValue.make_null();
            pdu.varbinds ~= vb.move;
        }
        return send_request(pdu.move, resp, err);
    }

    bool encode_and_send(ref const PDU pdu)
    {
        ubyte[1500] buffer = void;
        size_t length;
        if (!encode_message(_version, _community[], pdu, buffer[], length))
            return false;
        size_t sent;
        Result r = _socket.sendto(buffer[0 .. length], MsgFlags.none, &_remote, &sent);
        return cast(bool)r && sent == length;
    }

    void handle_response(const(ubyte)[] data)
    {
        SNMPMessage msg;
        if (!decode_message(data, msg))
        {
            log.debug_("malformed SNMP message");
            return;
        }
        if (msg.pdu.type != PDUType.response && msg.pdu.type != PDUType.report)
            return;

        SysTime now = getSysTime();
        foreach (i, ref req; _pending)
        {
            if (req.request.request_id != msg.pdu.request_id)
                continue;
            if (req.response_handler)
                req.response_handler(req.request, msg.pdu, req.request_time, now);
            _pending.remove(i);
            return;
        }
        log.debug_("orphan SNMP response, request_id=", msg.pdu.request_id);
    }
}
