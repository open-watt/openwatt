module protocol.ble.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;
import urt.uuid;

import manager;
import manager.base;
import manager.collection;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ble.att;
import protocol.ble.iface;

version = DebugBLEClient;

nothrow @nogc:


alias NotifyDelegate = void delegate(ushort handle, const(ubyte)[] value) nothrow @nogc;
alias DiscoveryDoneDelegate = void delegate() nothrow @nogc;


class BLEClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("peer", peer));
nothrow @nogc:

    enum type_name = "ble-client";
    enum path = "/protocol/ble/client";
    enum collection_id = CollectionType.ble_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BLEClient, id, flags);
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
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    MACAddress peer() const pure
        => _peer;
    void peer(MACAddress value)
    {
        if (_peer == value)
            return;
        _peer = value;
        mark_set!(typeof(this), "peer")();
        restart();
    }

    // API

    bool discovery_complete() const pure
        => _connected && _att_phase == ATTPhase.ready;

    ushort att_mtu() const pure
        => _mtu;

    const(GattService)[] services() const pure
        => _services[];

    const(GattChar)[] characteristics() const pure
        => _chars[];

    ushort find_characteristic(GUID service, GUID char_uuid) const
    {
        foreach (ref c; _chars[])
        {
            if (c.uuid == char_uuid && _services[c.service].uuid == service)
                return c.value_handle;
        }
        return 0;
    }

    bool write(ushort handle, const(ubyte)[] data, bool with_response = true, ATTResponseDelegate callback = null)
    {
        if (!_connected || handle == 0 || _att_phase != ATTPhase.ready)
            return false;
        if (3 + data.length > _mtu)
            return false;

        version (DebugBLEClient)
            log.trace("write ", with_response ? "req" : "cmd", " handle=", handle, " ", data.length, " bytes");

        if (!with_response)
        {
            // write command: not a request, no serialization or response
            ubyte[max_att_pdu] pdu = void;
            pdu[0] = ATTOpcode.write_cmd;
            pdu[1 .. 3] = handle.nativeToLittleEndian;
            pdu[3 .. 3 + data.length] = data[];
            bool r = att_send(pdu[0 .. 3 + data.length]);
            if (r && callback)
                callback(null, ATTError.none);
            return r;
        }

        UserOp op;
        op.buf[0] = ATTOpcode.write_req;
        op.buf[1 .. 3] = handle.nativeToLittleEndian;
        op.buf[3 .. 3 + data.length] = data[];
        op.len = cast(ushort)(3 + data.length);
        op.cb = callback;
        return submit_op(op);
    }

    bool read(ushort handle, ATTResponseDelegate callback = null)
    {
        if (!_connected || handle == 0 || _att_phase != ATTPhase.ready)
            return false;
        if (callback is null)
            callback = &log_read_response;

        UserOp op;
        op.buf[0] = ATTOpcode.read_req;
        op.buf[1 .. 3] = handle.nativeToLittleEndian;
        op.len = 3;
        op.cb = callback;
        return submit_op(op);
    }

    void on_notify(ushort handle, NotifyDelegate callback)
    {
        _notify_handlers ~= NotifyHandler(handle, callback);
        if (_att_phase == ATTPhase.ready)
            att_subscribe(handle, true);
    }

    void clear_notify(ushort handle)
    {
        for (size_t i = 0; i < _notify_handlers.length;)
        {
            if (_notify_handlers[i].handle == handle)
                _notify_handlers.remove(i);
            else
                ++i;
        }
    }

    void on_discovery_done(DiscoveryDoneDelegate callback)
    {
        _discovery_handlers ~= callback;
    }

    void clear_discovery_done(DiscoveryDoneDelegate callback)
    {
        for (size_t i = 0; i < _discovery_handlers.length; ++i)
        {
            if (_discovery_handlers[i] is callback)
            {
                _discovery_handlers.remove(i);
                return;
            }
        }
    }

protected:

    override bool validate() const
        => _iface !is null && cast(bool)_peer && (cast(const(BLEInterface))_iface.get) !is null;

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }
        if (_connect_handle >= 0)
            return CompletionStatus.continue_;
        if (_connected)
            return CompletionStatus.complete;

        // send connect_ind to the interface
        Packet p;
        ref f = p.init!BLEFrame(null);
        f.src = local_mac;
        f.dst = _peer;
        f.kind = BLEFrameKind.advert;
        f.code = BLEAdvPDU.connect_ind;

        _connect_handle = _iface.forward(p, &on_connect_complete);

        if (_connect_handle < 0)
        {
            log.error("failed to submit connect request");
            return CompletionStatus.error;
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        att_reset();

        if (_connect_handle >= 0)
        {
            _iface.abort(_connect_handle);
            _connect_handle = -1;
        }

        if (_connected)
        {
            // send disconnect to the interface
            Packet p;
            ref f = p.init!BLEFrame(null);
            f.src = local_mac;
            f.dst = _peer;
            f.kind = BLEFrameKind.control;
            f.code = BLEControl.disconnect;
            _iface.forward(p);
            _connected = false;
        }

        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        att_update(getTime());
    }

    // transmit a complete ATT PDU to the peer; the engine's only transport
    // edge, overridable so tests can drive the protocol without an interface
    bool att_send(const(ubyte)[] pdu)
    {
        if (!_iface)
            return false;
        Packet p;
        ref f = p.init!BLEFrame(pdu);
        f.src = local_mac;
        f.dst = _peer;
        f.kind = BLEFrameKind.att;
        f.code = pdu[0];
        return _iface.forward(p) >= 0;
    }

private:
    struct NotifyHandler
    {
        ushort handle;
        NotifyDelegate callback;
    }

    ObjectRef!BaseInterface _iface;
    MACAddress _peer;
    MACAddress _local_mac;
    int _connect_handle = -1;
    bool _subscribed;
    bool _connected;
    Array!NotifyHandler _notify_handlers;
    Array!DiscoveryDoneDelegate _discovery_handlers;

    package MACAddress local_mac()
    {
        if (!_local_mac)
        {
            import urt.crc;
            uint crc = name[].calculate_crc!(Algorithm.crc32_iso_hdlc);
            _local_mac = MACAddress(0x02, 0x13, 0x37, crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF);
        }
        return _local_mac;
    }

    void on_connect_complete(int handle, MessageState state)
    {
        if (state < MessageState.complete)
            return;

        _connect_handle = -1;

        if (state == MessageState.complete)
        {
            _connected = true;
            log.info("connected to ", _peer);
            att_start(_iface.mtu);
        }
        else
        {
            log.error("connection to ", _peer, " failed");
            restart();
        }
    }

    void log_read_response(const(ubyte)[] value, ATTError error)
    {
        if (error != ATTError.none)
            log.warning("read failed: error=", error);
        else
            log.info("read_rsp: [ ", cast(void[])value, " ]");
    }

    package void incoming_frame(ref const Packet p, BaseInterface iface)
    {
        ref f = p.hdr!BLEFrame;

        final switch (f.kind)
        {
            case BLEFrameKind.advert:
                break;

            case BLEFrameKind.control:
                if (f.code == BLEControl.disconnected)
                {
                    _connected = false;
                    log.info("disconnected from ", _peer);
                    restart();
                }
                break;

            case BLEFrameKind.att:
                att_on_pdu(cast(const(ubyte)[])p.data);
                break;
        }
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    // ====================================================================
    // ATT client engine
    //
    // Runs the GATT client procedures over att_send()/att_on_pdu(): MTU
    // exchange, service/characteristic/descriptor discovery, the
    // one-outstanding-request rule, and notification/indication delivery.
    // PDUs are complete real ATT PDUs (opcode byte included), so the same
    // logic runs against a kernel L2CAP socket, a raw HCI backend, or a
    // smart driver emulating an ATT server.
    // ====================================================================

    enum max_att_pdu = 247;

    enum ATTPhase : ubyte
    {
        idle,
        mtu,
        services,
        chars,
        descriptors,
        ready,
        failed,
    }

    struct UserOp
    {
        ubyte[max_att_pdu] buf = void;
        ushort len;
        ATTResponseDelegate cb;
    }

    Array!GattService _services;
    Array!GattChar _chars;
    Array!UserOp _user_ops;

    MonoTime _req_time;
    ushort _preferred_mtu = 247;
    ushort _mtu = 23;
    ushort _svc_cursor;
    ushort _walk_handle;
    ubyte _pending_req;
    ATTPhase _att_phase;

    // begin MTU exchange + discovery against a fresh connection
    void att_start(ushort preferred_mtu)
    {
        att_reset();
        _preferred_mtu = preferred_mtu;

        _att_phase = ATTPhase.mtu;
        ubyte[3] pdu = void;
        pdu[0] = ATTOpcode.exchange_mtu_req;
        pdu[1 .. 3] = _preferred_mtu.nativeToLittleEndian;
        send_request(pdu[]);
    }

    void att_reset()
    {
        _att_phase = ATTPhase.idle;
        _mtu = 23;
        _pending_req = 0;
        _services.clear();
        _chars.clear();
        _user_ops.clear();
        _svc_cursor = 0;
        _walk_handle = 0;
    }

    // drive transaction timeouts
    void att_update(MonoTime now)
    {
        if (_pending_req != 0 && now - _req_time > att_transaction_timeout)
        {
            log.warning("ATT transaction timeout (opcode ", _pending_req, ")");
            att_fail();
        }
    }

    // feed a complete incoming ATT PDU
    void att_on_pdu(const(ubyte)[] pdu)
    {
        if (pdu.length < 1)
            return;

        switch (pdu[0])
        {
            case ATTOpcode.notification:
            case ATTOpcode.indication:
                if (pdu.length < 3)
                    return;
                ushort handle = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
                const(ubyte)[] value = pdu.length > 3 ? pdu[3 .. $] : null;
                bool indication = pdu[0] == ATTOpcode.indication;
                if (indication)
                {
                    ubyte[1] confirm = [ ATTOpcode.confirmation ];
                    att_send(confirm[]);
                }
                att_notify(handle, value, indication);
                return;

            default:
                break;
        }

        if (_pending_req == 0)
            return; // unsolicited response; ignore

        if (pdu[0] == ATTOpcode.error_rsp)
        {
            if (pdu.length < 5 || pdu[1] != _pending_req)
                return;
            ubyte req = _pending_req;
            _pending_req = 0;
            on_error_rsp(req, cast(ATTError)pdu[4]);
            return;
        }

        // responses are req opcode + 1
        if (pdu[0] != _pending_req + 1)
            return;
        _pending_req = 0;
        on_response(pdu);
    }

    // enable/disable notifications or indications by writing the CCCD
    bool att_subscribe(ushort value_handle, bool enable, ATTResponseDelegate cb = null)
    {
        const(GattChar)* c = find_char_by_handle(value_handle);
        if (c is null || c.cccd == 0)
            return false;

        ushort value = 0;
        if (enable)
            value = (c.props & GattProps.notify) ? 0x0001 : 0x0002;

        ubyte[2] v = value.nativeToLittleEndian;
        return write(c.cccd, v[], true, cb);
    }

    void att_notify(ushort handle, const(ubyte)[] value, bool indication)
    {
        size_t matched = 0;
        foreach (ref h; _notify_handlers[])
        {
            if (h.handle == handle)
            {
                ++matched;
                h.callback(handle, value);
            }
        }
        version (DebugBLEClient)
            log.trace(indication ? "indication" : "notification",
                      " handle=", handle, " ", value.length, " bytes, ", matched, " handler(s)");
    }

    void att_fail()
    {
        _pending_req = 0;
        _att_phase = ATTPhase.failed;
        foreach (ref op; _user_ops[])
        {
            if (op.cb)
                op.cb(null, ATTError.send_failed);
        }
        _user_ops.clear();

        log.error("ATT failure on connection to ", _peer);
        restart();
    }

    const(GattChar)* find_char_by_handle(ushort value_handle) const
    {
        foreach (ref c; _chars[])
        {
            if (c.value_handle == value_handle)
                return &c;
        }
        return null;
    }

    bool send_request(const(ubyte)[] pdu)
    {
        _pending_req = pdu[0];
        _req_time = getTime();
        if (!att_send(pdu))
        {
            att_fail();
            return false;
        }
        return true;
    }

    bool submit_op(ref UserOp op)
    {
        _user_ops ~= op;
        if (_pending_req == 0)
            send_next_op();
        return true;
    }

    void send_next_op()
    {
        if (_user_ops.length == 0)
            return;
        send_request(_user_ops[0].buf[0 .. _user_ops[0].len]);
    }

    void complete_op(const(ubyte)[] value, ATTError error)
    {
        debug assert(_user_ops.length > 0);
        ATTResponseDelegate cb = _user_ops[0].cb;
        _user_ops.remove(0);
        if (cb)
            cb(value, error);
        send_next_op();
    }

    // --- discovery walk ---

    void request_services()
    {
        ubyte[7] pdu = void;
        pdu[0] = ATTOpcode.read_by_group_type_req;
        pdu[1 .. 3] = _walk_handle.nativeToLittleEndian;
        pdu[3 .. 5] = nativeToLittleEndian(ushort(0xFFFF));
        pdu[5 .. 7] = nativeToLittleEndian(ushort(GattAttributeType.primary_service));
        send_request(pdu[]);
    }

    void request_chars()
    {
        ubyte[7] pdu = void;
        pdu[0] = ATTOpcode.read_by_type_req;
        pdu[1 .. 3] = _walk_handle.nativeToLittleEndian;
        pdu[3 .. 5] = _services[_svc_cursor].end.nativeToLittleEndian;
        pdu[5 .. 7] = nativeToLittleEndian(ushort(GattAttributeType.characteristic));
        send_request(pdu[]);
    }

    void request_descriptors()
    {
        ubyte[5] pdu = void;
        pdu[0] = ATTOpcode.find_information_req;
        pdu[1 .. 3] = _walk_handle.nativeToLittleEndian;
        pdu[3 .. 5] = _services[_svc_cursor].end.nativeToLittleEndian;
        send_request(pdu[]);
    }

    void next_service_chars()
    {
        for (++_svc_cursor; _svc_cursor < _services.length; ++_svc_cursor)
        {
            ref const GattService s = _services[_svc_cursor];
            if (s.start <= s.end)
            {
                _walk_handle = s.start;
                request_chars();
                return;
            }
        }
        // all services walked; descriptor phase
        _att_phase = ATTPhase.descriptors;
        _svc_cursor = ushort.max; // next_service_descriptors pre-increments
        next_service_descriptors();
    }

    void next_service_descriptors()
    {
        for (++_svc_cursor; _svc_cursor < _services.length; ++_svc_cursor)
        {
            ref const GattService s = _services[_svc_cursor];
            if (s.start <= s.end)
            {
                _walk_handle = s.start;
                request_descriptors();
                return;
            }
        }
        att_discovery_ready();
    }

    void begin_char_walk()
    {
        if (_services.length == 0)
        {
            att_discovery_ready();
            return;
        }
        _att_phase = ATTPhase.chars;
        _svc_cursor = ushort.max;
        next_service_chars();
    }

    void att_discovery_ready()
    {
        _att_phase = ATTPhase.ready;
        log.debug_("GATT discovery complete: ", _services.length, " services, ", _chars.length, " characteristics, mtu=", _mtu);

        // subscribe any notify handlers registered ahead of discovery
        foreach (ref h; _notify_handlers[])
            att_subscribe(h.handle, true);

        foreach (cb; _discovery_handlers[])
            cb();
    }

    void on_error_rsp(ubyte req, ATTError error)
    {
        final switch (_att_phase)
        {
            case ATTPhase.mtu:
                // server doesn't support MTU exchange; default MTU stands
                _walk_handle = 0x0001;
                _att_phase = ATTPhase.services;
                request_services();
                return;

            case ATTPhase.services:
                if (error == ATTError.attribute_not_found)
                {
                    begin_char_walk();
                    return;
                }
                break;

            case ATTPhase.chars:
                if (error == ATTError.attribute_not_found)
                {
                    next_service_chars();
                    return;
                }
                break;

            case ATTPhase.descriptors:
                if (error == ATTError.attribute_not_found)
                {
                    next_service_descriptors();
                    return;
                }
                break;

            case ATTPhase.ready:
                complete_op(null, error);
                return;

            case ATTPhase.idle:
            case ATTPhase.failed:
                return;
        }

        log.warning("ATT request ", req, " failed: error=", error);
        att_fail();
    }

    void on_response(const(ubyte)[] pdu)
    {
        final switch (_att_phase)
        {
            case ATTPhase.mtu:
                if (pdu[0] == ATTOpcode.exchange_mtu_rsp && pdu.length >= 3)
                {
                    ushort server_mtu = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
                    ushort m = server_mtu < _preferred_mtu ? server_mtu : _preferred_mtu;
                    _mtu = m > 23 ? m : 23;
                }
                _walk_handle = 0x0001;
                _att_phase = ATTPhase.services;
                request_services();
                return;

            case ATTPhase.services:
                on_services_rsp(pdu);
                return;

            case ATTPhase.chars:
                on_chars_rsp(pdu);
                return;

            case ATTPhase.descriptors:
                on_descriptors_rsp(pdu);
                return;

            case ATTPhase.ready:
                switch (pdu[0])
                {
                    case ATTOpcode.read_rsp:
                        complete_op(pdu.length > 1 ? pdu[1 .. $] : null, ATTError.none);
                        return;
                    case ATTOpcode.write_rsp:
                        complete_op(null, ATTError.none);
                        return;
                    default:
                        return;
                }

            case ATTPhase.idle:
            case ATTPhase.failed:
                return;
        }
    }

    void on_services_rsp(const(ubyte)[] pdu)
    {
        if (pdu[0] != ATTOpcode.read_by_group_type_rsp || pdu.length < 2)
            return att_fail();

        ubyte entry_len = pdu[1];
        if (entry_len != 6 && entry_len != 20)
            return att_fail();

        const(ubyte)[] list = pdu[2 .. $];
        ushort last_end = 0;
        while (list.length >= entry_len)
        {
            GattService s;
            s.start = list.ptr[0 .. 2].littleEndianToNative!ushort;
            s.end = list.ptr[2 .. 4].littleEndianToNative!ushort;
            s.uuid = att_uuid_to_guid(list[4 .. entry_len]);
            _services ~= s;
            last_end = s.end;
            list = list[entry_len .. $];
        }

        if (last_end >= 0xFFFF)
        {
            begin_char_walk();
            return;
        }
        _walk_handle = cast(ushort)(last_end + 1);
        request_services();
    }

    void on_chars_rsp(const(ubyte)[] pdu)
    {
        if (pdu[0] != ATTOpcode.read_by_type_rsp || pdu.length < 2)
            return att_fail();

        ubyte entry_len = pdu[1];
        if (entry_len != 7 && entry_len != 21)
            return att_fail();

        const(ubyte)[] list = pdu[2 .. $];
        ushort last_decl = 0;
        while (list.length >= entry_len)
        {
            GattChar c;
            c.decl = list.ptr[0 .. 2].littleEndianToNative!ushort;
            c.props = list[2];
            c.value_handle = list.ptr[3 .. 5].littleEndianToNative!ushort;
            c.uuid = att_uuid_to_guid(list[5 .. entry_len]);
            c.service = _svc_cursor;
            _chars ~= c;
            last_decl = c.decl;
            list = list[entry_len .. $];
        }

        ref const GattService s = _services[_svc_cursor];
        if (last_decl >= s.end)
        {
            next_service_chars();
            return;
        }
        _walk_handle = cast(ushort)(last_decl + 1);
        request_chars();
    }

    void on_descriptors_rsp(const(ubyte)[] pdu)
    {
        if (pdu[0] != ATTOpcode.find_information_rsp || pdu.length < 2)
            return att_fail();

        ubyte format = pdu[1];
        if (format != 1 && format != 2)
            return att_fail();
        size_t entry_len = format == 1 ? 4 : 18;

        const(ubyte)[] list = pdu[2 .. $];
        ushort last_handle = 0;
        while (list.length >= entry_len)
        {
            ushort handle = list.ptr[0 .. 2].littleEndianToNative!ushort;
            bool is_cccd = false;
            if (format == 1)
                is_cccd = list.ptr[2 .. 4].littleEndianToNative!ushort == GattAttributeType.cccd;
            else
                is_cccd = att_uuid_to_guid(list[2 .. 18]) == uuid16_to_guid(GattAttributeType.cccd);

            if (is_cccd)
                assign_cccd(handle);

            last_handle = handle;
            list = list[entry_len .. $];
        }

        ref const GattService s = _services[_svc_cursor];
        if (last_handle >= s.end)
        {
            next_service_descriptors();
            return;
        }
        _walk_handle = cast(ushort)(last_handle + 1);
        request_descriptors();
    }

    // a CCCD belongs to the characteristic (in the current service) with the
    // greatest value handle below it
    void assign_cccd(ushort handle)
    {
        GattChar* owner = null;
        foreach (ref c; _chars[])
        {
            if (c.service != _svc_cursor || c.value_handle >= handle)
                continue;
            if (owner is null || c.value_handle > owner.value_handle)
                owner = &c;
        }
        if (owner !is null)
            owner.cccd = handle;
    }
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    import urt.mem.allocator;

    // A BLEClient allocated directly (no Application/collection harness),
    // with the transport edge overridden so the test scripts the peer.
    static class TestClient : BLEClient
    {
    nothrow @nogc:
        ubyte[64] last_req;
        size_t req_len;
        uint sends;
        uint ready_count;
        uint notify_count;
        ushort notify_handle;
        uint reads_done;
        ubyte[4] read_value;
        bool sub_done;

        this()
        {
            super(CID(1));
        }

        override bool att_send(const(ubyte)[] pdu)
        {
            last_req[0 .. pdu.length] = pdu[];
            req_len = pdu.length;
            ++sends;
            return true;
        }

        void on_ready() { ++ready_count; }
        void on_value(ushort handle, const(ubyte)[] value) { ++notify_count; notify_handle = handle; }
        void on_sub(const(ubyte)[] v, ATTError e) { sub_done = e == ATTError.none; }
        void on_read1(const(ubyte)[] v, ATTError e) { ++reads_done; read_value[0 .. v.length] = v[]; }
        void on_read2(const(ubyte)[] v, ATTError e) { ++reads_done; }
    }

    enum GUID vendor_svc = UUID!"12345678-9ABC-DEF0-1234-56789ABCDEF0";
    enum GUID vendor_chr = UUID!"0FEDCBA9-8765-4321-0FED-CBA987654321";

    TestClient c = defaultAllocator().allocT!TestClient();
    scope (exit) defaultAllocator().freeT(c);

    c.on_discovery_done(&c.on_ready);
    c._connected = true; // the engine is driven below the connect machinery

    // scripted peripheral: battery service (0x180F) with one notifying char
    // (0x2A19 + CCCD), then a 128-bit vendor service with one read/write char
    c.att_start(247);

    // MTU exchange
    static immutable ubyte[3] exp_mtu_req = [ATTOpcode.exchange_mtu_req, 247, 0];
    assert(c.last_req[0 .. 3] == exp_mtu_req[]);
    static immutable ubyte[3] mtu_rsp = [ATTOpcode.exchange_mtu_rsp, 185, 0];
    c.att_on_pdu(mtu_rsp[]);
    assert(c.att_mtu == 185);

    // service discovery: expect read_by_group_type 0x0001-0xFFFF
    static immutable ubyte[4] exp_walk1 = [1, 0, 0xFF, 0xFF];
    assert(c.last_req[0] == ATTOpcode.read_by_group_type_req);
    assert(c.last_req[1 .. 5] == exp_walk1[]);
    // respond: battery service 0x0010-0x001F (16-bit uuid form)
    static immutable ubyte[8] svc_rsp1 = [ATTOpcode.read_by_group_type_rsp, 6,
                                          0x10, 0x00, 0x1F, 0x00, 0x0F, 0x18];
    c.att_on_pdu(svc_rsp1[]);
    // engine continues from 0x0020
    static immutable ubyte[4] exp_walk2 = [0x20, 0, 0xFF, 0xFF];
    assert(c.last_req[0] == ATTOpcode.read_by_group_type_req);
    assert(c.last_req[1 .. 5] == exp_walk2[]);
    // respond: vendor service 0x0020-0xFFFF (128-bit uuid form)
    ubyte[22] svc_rsp2 = void;
    svc_rsp2[0] = ATTOpcode.read_by_group_type_rsp;
    svc_rsp2[1] = 20;
    svc_rsp2[2 .. 4] = nativeToLittleEndian(ushort(0x0020));
    svc_rsp2[4 .. 6] = nativeToLittleEndian(ushort(0xFFFF));
    guid_to_att_uuid(vendor_svc, svc_rsp2[6 .. 22][0 .. 16]);
    c.att_on_pdu(svc_rsp2[]);

    // char discovery for battery service
    static immutable ubyte[6] exp_chars1 = [0x10, 0x00, 0x1F, 0x00, 0x03, 0x28];
    assert(c.last_req[0] == ATTOpcode.read_by_type_req);
    assert(c.last_req[1 .. 7] == exp_chars1[]);
    // respond: battery level char: decl 0x0011, props notify|read, value 0x0012, uuid 0x2A19
    static immutable ubyte[9] chr_rsp1 = [ATTOpcode.read_by_type_rsp, 7,
                                          0x11, 0x00, GattProps.read | GattProps.notify, 0x12, 0x00, 0x19, 0x2A];
    c.att_on_pdu(chr_rsp1[]);
    // continues from 0x0012; respond not found -> next service
    static immutable ubyte[2] exp_cont = [0x12, 0x00];
    assert(c.last_req[0] == ATTOpcode.read_by_type_req);
    assert(c.last_req[1 .. 3] == exp_cont[]);
    static immutable ubyte[5] nf_chars1 = [ATTOpcode.error_rsp, ATTOpcode.read_by_type_req, 0x12, 0x00, ATTError.attribute_not_found];
    c.att_on_pdu(nf_chars1[]);

    // char discovery for vendor service
    static immutable ubyte[4] exp_chars2 = [0x20, 0x00, 0xFF, 0xFF];
    assert(c.last_req[0] == ATTOpcode.read_by_type_req);
    assert(c.last_req[1 .. 5] == exp_chars2[]);
    ubyte[23] chr_rsp2 = void;
    chr_rsp2[0] = ATTOpcode.read_by_type_rsp;
    chr_rsp2[1] = 21;
    chr_rsp2[2 .. 4] = nativeToLittleEndian(ushort(0x0021));
    chr_rsp2[4] = GattProps.read | GattProps.write;
    chr_rsp2[5 .. 7] = nativeToLittleEndian(ushort(0x0022));
    guid_to_att_uuid(vendor_chr, chr_rsp2[7 .. 23][0 .. 16]);
    c.att_on_pdu(chr_rsp2[]);
    static immutable ubyte[5] nf_chars2 = [ATTOpcode.error_rsp, ATTOpcode.read_by_type_req, 0x22, 0x00, ATTError.attribute_not_found];
    c.att_on_pdu(nf_chars2[]);

    // descriptor discovery: battery service range
    static immutable ubyte[4] exp_descs1 = [0x10, 0x00, 0x1F, 0x00];
    assert(c.last_req[0] == ATTOpcode.find_information_req);
    assert(c.last_req[1 .. 5] == exp_descs1[]);
    // respond: CCCD at 0x0013 (16-bit format)
    static immutable ubyte[6] desc_rsp = [ATTOpcode.find_information_rsp, 1, 0x13, 0x00, 0x02, 0x29];
    c.att_on_pdu(desc_rsp[]);
    // continues from 0x0014; not found -> next service
    static immutable ubyte[5] nf_descs1 = [ATTOpcode.error_rsp, ATTOpcode.find_information_req, 0x14, 0x00, ATTError.attribute_not_found];
    c.att_on_pdu(nf_descs1[]);
    // vendor service descriptors: none
    assert(c.last_req[0] == ATTOpcode.find_information_req);
    static immutable ubyte[5] nf_descs2 = [ATTOpcode.error_rsp, ATTOpcode.find_information_req, 0x20, 0x00, ATTError.attribute_not_found];
    c.att_on_pdu(nf_descs2[]);

    // discovery complete
    assert(c.ready_count == 1);
    assert(c.discovery_complete);
    assert(c.services.length == 2);
    assert(c.characteristics.length == 2);
    assert(c.characteristics[0].value_handle == 0x0012);
    assert(c.characteristics[0].cccd == 0x0013);
    assert(c.characteristics[1].value_handle == 0x0022);
    assert(c.characteristics[1].cccd == 0);
    assert(c.find_characteristic(uuid16_to_guid(0x180F), uuid16_to_guid(0x2A19)) == 0x0012);
    assert(c.find_characteristic(vendor_svc, vendor_chr) == 0x0022);

    // subscribe: writes 0x0001 to the CCCD
    c.att_subscribe(0x0012, true, &c.on_sub);
    static immutable ubyte[5] exp_sub = [ATTOpcode.write_req, 0x13, 0x00, 0x01, 0x00];
    assert(c.last_req[0 .. 5] == exp_sub[]);
    static immutable ubyte[1] write_rsp = [ATTOpcode.write_rsp];
    c.att_on_pdu(write_rsp[]);
    assert(c.sub_done);

    // read with queued second op (one outstanding request)
    c.read(0x0012, &c.on_read1);
    c.read(0x0022, &c.on_read2);
    static immutable ubyte[3] exp_read1 = [ATTOpcode.read_req, 0x12, 0x00];
    assert(c.last_req[0 .. 3] == exp_read1[]);
    uint sends_before = c.sends;
    static immutable ubyte[2] read_rsp1 = [ATTOpcode.read_rsp, 64];
    c.att_on_pdu(read_rsp1[]);
    assert(c.reads_done == 1 && c.read_value[0] == 64);
    assert(c.sends == sends_before + 1); // second read sent on completion
    static immutable ubyte[3] exp_read2 = [ATTOpcode.read_req, 0x22, 0x00];
    assert(c.last_req[0 .. 3] == exp_read2[]);
    static immutable ubyte[4] read_rsp2 = [ATTOpcode.read_rsp, 1, 2, 3];
    c.att_on_pdu(read_rsp2[]);
    assert(c.reads_done == 2);

    // notification dispatch + indication confirmation
    c.on_notify(0x0012, &c.on_value); // triggers a CCCD write (already subscribed; harmless)
    c.att_on_pdu(write_rsp[]);
    static immutable ubyte[4] notif = [ATTOpcode.notification, 0x12, 0x00, 99];
    c.att_on_pdu(notif[]);
    assert(c.notify_count == 1 && c.notify_handle == 0x0012);
    sends_before = c.sends;
    static immutable ubyte[4] indic = [ATTOpcode.indication, 0x12, 0x00, 98];
    c.att_on_pdu(indic[]);
    assert(c.notify_count == 2);
    assert(c.sends == sends_before + 1 && c.last_req[0] == ATTOpcode.confirmation);
}
