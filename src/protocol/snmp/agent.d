module protocol.snmp.agent;

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


alias MIBGetHandler = bool delegate(ref const OID name, out VarBindValue value, ref const InetAddress sender) nothrow @nogc;
alias MIBGetNextHandler = bool delegate(ref const OID name, out OID next, out VarBindValue value, ref const InetAddress sender) nothrow @nogc;
alias MIBSetHandler = SNMPError delegate(ref const OID name, ref const VarBindValue value, ref const InetAddress sender) nothrow @nogc;
alias TrapHandler = void delegate(ref const SNMPMessage msg, ref const InetAddress sender) nothrow @nogc;


class SNMPAgent : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port),
                                 Prop!("trap-port", trap_port),
                                 Prop!("bind-address", bind_address),
                                 Prop!("community", community));
nothrow @nogc:

    enum type_name = "snmp-agent";
    enum path = "/protocol/snmp/agent";
    enum collection_id = CollectionType.snmp_agent;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SNMPAgent, id, flags);
        _community = StringLit!"public";
    }

    ushort port() const pure
        => _port;
    void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        restart();
    }

    ushort trap_port() const pure
        => _trap_port;
    void trap_port(ushort value)
    {
        if (_trap_port == value)
            return;
        _trap_port = value;
        restart();
    }

    IPAddr bind_address() const pure
        => _bind_address;
    void bind_address(IPAddr value)
    {
        if (_bind_address == value)
            return;
        _bind_address = value;
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

    // API...

    MIBGetHandler get_handler;
    MIBGetNextHandler get_next_handler;
    MIBSetHandler set_handler;
    TrapHandler trap_handler;

protected:
    override CompletionStatus startup()
    {
        if (_port != 0)
        {
            Result r = create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, _request_socket);
            if (!r)
                return CompletionStatus.error;
            r = _request_socket.set_socket_option(SocketOption.non_blocking, true);
            if (r)
                _request_socket.set_socket_option(SocketOption.reuse_address, true);
            if (r)
                r = _request_socket.bind(InetAddress(_bind_address, _port));
            if (!r)
            {
                _request_socket.close();
                _request_socket = null;
                return CompletionStatus.error;
            }
        }

        if (_trap_port != 0)
        {
            Result r = create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, _trap_socket);
            if (!r)
            {
                if (_request_socket)
                {
                    _request_socket.close();
                    _request_socket = null;
                }
                return CompletionStatus.error;
            }
            r = _trap_socket.set_socket_option(SocketOption.non_blocking, true);
            if (r)
                _trap_socket.set_socket_option(SocketOption.reuse_address, true);
            if (r)
                r = _trap_socket.bind(InetAddress(_bind_address, _trap_port));
            if (!r)
            {
                _trap_socket.close();
                _trap_socket = null;
                if (_request_socket)
                {
                    _request_socket.close();
                    _request_socket = null;
                }
                return CompletionStatus.error;
            }
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_request_socket)
        {
            _request_socket.close();
            _request_socket = null;
        }
        if (_trap_socket)
        {
            _trap_socket.close();
            _trap_socket = null;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        ubyte[1500] buffer = void;
        InetAddress sender;
        size_t bytes;

        if (_request_socket)
        {
            while (_request_socket.recvfrom(buffer[], MsgFlags.none, &sender, &bytes))
            {
                if (bytes == 0)
                    break;
                handle_request(buffer[0 .. bytes], sender);
            }
        }
        if (_trap_socket)
        {
            while (_trap_socket.recvfrom(buffer[], MsgFlags.none, &sender, &bytes))
            {
                if (bytes == 0)
                    break;
                handle_trap(buffer[0 .. bytes], sender);
            }
        }
    }

private:
    ushort _port = WellKnownPort.SNMP;
    ushort _trap_port = 162;
    IPAddr _bind_address = IPAddr.any;
    String _community;

    Socket _request_socket;
    Socket _trap_socket;

    void handle_request(const(ubyte)[] data, ref const InetAddress sender)
    {
        SNMPMessage msg;
        if (!decode_message(data, msg))
        {
            log.debug_("malformed SNMP request from ", sender);
            return;
        }
        if (msg.community[] != _community[])
        {
            log.debug_("rejecting request with bad community from ", sender);
            return;
        }

        PDU response;
        response.type = PDUType.response;
        response.request_id = msg.pdu.request_id;

        switch (msg.pdu.type)
        {
            case PDUType.get_request:
                process_get(msg.pdu, response, sender);
                break;
            case PDUType.get_next_request:
                process_get_next(msg.pdu, response, sender);
                break;
            case PDUType.get_bulk_request:
                process_get_bulk(msg.pdu, response, sender);
                break;
            case PDUType.set_request:
                process_set(msg.pdu, response, sender);
                break;
            default:
                return;
        }

        ubyte[1500] out_buf = void;
        size_t length;
        if (!encode_message(msg.version_, _community[], response, out_buf[], length))
        {
            log.warning("failed to encode SNMP response to ", sender);
            return;
        }
        size_t sent;
        _request_socket.sendto(out_buf[0 .. length], MsgFlags.none, &sender, &sent);
    }

    void handle_trap(const(ubyte)[] data, ref const InetAddress sender)
    {
        SNMPMessage msg;
        if (!decode_message(data, msg))
            return;
        if (trap_handler)
            trap_handler(msg, sender);
    }

    void process_get(ref const PDU req, ref PDU resp, ref const InetAddress sender)
    {
        foreach (i, ref vb; req.varbinds)
        {
            VarBind out_vb;
            out_vb.name = OID(vb.name.arcs[]);
            if (get_handler && get_handler(vb.name, out_vb.value, sender))
            {
                // value populated by handler
            }
            else
                out_vb.value = VarBindValue(VarBindType.no_such_object);
            resp.varbinds ~= out_vb.move;
        }
    }

    void process_get_next(ref const PDU req, ref PDU resp, ref const InetAddress sender)
    {
        foreach (i, ref vb; req.varbinds)
        {
            VarBind out_vb;
            if (get_next_handler && get_next_handler(vb.name, out_vb.name, out_vb.value, sender))
            {
                // populated
            }
            else
            {
                out_vb.name = OID(vb.name.arcs[]);
                out_vb.value = VarBindValue(VarBindType.end_of_mib_view);
            }
            resp.varbinds ~= out_vb.move;
        }
    }

    void process_get_bulk(ref const PDU req, ref PDU resp, ref const InetAddress sender)
    {
        int nr = req.non_repeaters;
        int mr = req.max_repetitions;
        if (nr < 0) nr = 0;
        if (nr > cast(int)req.varbinds.length)
            nr = cast(int)req.varbinds.length;
        if (mr < 0) mr = 0;

        foreach (i; 0 .. nr)
        {
            VarBind out_vb;
            if (get_next_handler && get_next_handler(req.varbinds[i].name, out_vb.name, out_vb.value, sender))
            {
            }
            else
            {
                out_vb.name = OID(req.varbinds[i].name.arcs[]);
                out_vb.value = VarBindValue(VarBindType.end_of_mib_view);
            }
            resp.varbinds ~= out_vb.move;
        }

        size_t repeating_count = req.varbinds.length - nr;
        if (repeating_count == 0 || mr == 0)
            return;

        Array!OID cursors;
        foreach (i; nr .. req.varbinds.length)
            cursors ~= OID(req.varbinds[i].name.arcs[]);

        foreach (rep; 0 .. mr)
        {
            bool any_progress = false;
            foreach (j; 0 .. cursors.length)
            {
                VarBind out_vb;
                bool ok = get_next_handler && get_next_handler(cursors[j], out_vb.name, out_vb.value, sender);
                if (ok)
                {
                    cursors[j].arcs.clear();
                    cursors[j].arcs ~= out_vb.name.arcs[];
                    any_progress = true;
                }
                else
                {
                    out_vb.name = OID(cursors[j].arcs[]);
                    out_vb.value = VarBindValue(VarBindType.end_of_mib_view);
                }
                resp.varbinds ~= out_vb.move;
            }
            if (!any_progress)
                break;
        }
    }

    void process_set(ref const PDU req, ref PDU resp, ref const InetAddress sender)
    {
        foreach (i, ref vb; req.varbinds)
        {
            SNMPError err = SNMPError.no_error;
            if (set_handler)
                err = set_handler(vb.name, vb.value, sender);
            else
                err = SNMPError.not_writable;

            if (err != SNMPError.no_error && resp.error_status == SNMPError.no_error)
            {
                resp.error_status = err;
                resp.error_index = cast(int)(i + 1);
            }

            VarBind echo;
            echo.name = OID(vb.name.arcs[]);
            echo.value = vb.value.type == VarBindType.null_ ? VarBindValue.make_null() : copy_value(vb.value);
            resp.varbinds ~= echo.move;
        }
    }

    static VarBindValue copy_value(ref const VarBindValue v)
    {
        VarBindValue r;
        r.type = v.type;
        r.int_val = v.int_val;
        r.uint_val = v.uint_val;
        r.ip_val = v.ip_val;
        r.octets ~= v.octets[];
        r.oid_val = OID(v.oid_val.arcs[]);
        return r;
    }
}
