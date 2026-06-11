module driver.baremetal.ble;

// BLEInterface backed by the urt BLE driver layer. Covers any platform
// whose BLE is provided by a host stack behind urt.driver.ble (windows
// WinRT, esp32 NimBLE). The host stack owns GATT, so this backend maps
// ATT data PDUs onto driver GATT ops and answers from driver callbacks.

import urt.array;
import urt.endian;
import urt.log;
import urt.map;
import urt.mem.temp;
import urt.uuid;

import manager;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

import router.iface;
import router.iface.priority_queue;

import protocol.ble.att;
import protocol.ble.iface;

import urt.driver.ble;

nothrow @nogc:

static if (has_all && num_ble > 0):


class BuiltinBLEInterface : BLEInterface
{
    alias Properties = AliasSeq!(Prop!("port", port));
nothrow @nogc:

    enum type_name = "ble";
    enum path = "/interface/ble";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinBLEInterface, id, flags);
    }

    // Properties...

    final ubyte port() const pure
        => _port;
    final void port(ubyte value)
    {
        if (_port == value)
            return;
        _port = value;
        restart();
    }

    override void service()
    {
        if (_ble.is_open)
            ble_poll(_ble);
        drain_emu_responses();
        super.service();
    }

protected:

    override bool validate() const
        => _port < num_ble;

    override CompletionStatus startup()
    {
        CompletionStatus s = super.startup();
        if (s != CompletionStatus.complete)
            return s;

        BLEConfig cfg;
        auto r = ble_open(_ble, _port, cfg);
        if (!r)
        {
            log.error("BLE radio init failed");
            return CompletionStatus.error;
        }

        ble_set_scan_callback(_ble, &scan_dispatch);
        ble_set_conn_callback(_ble, &conn_dispatch);
        ble_set_discover_callback(_ble, &discover_dispatch);
        ble_set_read_callback(_ble, &read_dispatch);
        ble_set_write_callback(_ble, &write_dispatch);
        ble_set_notify_callback(_ble, &notify_dispatch);
        ble_set_wake_callback(_ble, &wake_dispatch);

        _active_radios[_port] = this;

        BLEScanConfig scan_cfg;
        ble_scan_start(_ble, scan_cfg);

        log.info("BLE started on interface '", name, "'");
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_ble.is_open)
        {
            _active_radios[_ble.port] = null;
            ble_close(_ble);
        }

        _num_pending_ops = 0;
        _pending_connect_tag = -1;
        _adv_handles.clear();
        _addr_types.clear();

        foreach (p; _emu_responses[])
            p.free_clone();
        _emu_responses.clear();

        return super.shutdown();
    }

    override bool submit_capacity()
        => _num_pending_ops < max_pending_ops;

    override bool submit_frame(QueuedFrame* frame)
    {
        ref f = frame.packet.hdr!BLEFrame;

        final switch (f.kind)
        {
            case BLEFrameKind.advert:
                return submit_advert(frame, f);
            case BLEFrameKind.control:
                return submit_control(frame, f);
            case BLEFrameKind.att:
                return submit_att(frame, f);
        }
    }

    override void transport_close(BLESession* session)
    {
        if (_ble.is_open && session.transport != uint.max)
            ble_disconnect(_ble, session_conn(session));
    }

private:

    // pending GATT op - correlates driver callback to queue tag
    struct PendingGattOp
    {
        ubyte tag;
        ubyte conn_id;
        ushort handle;
        bool is_read; // true = read, false = write
    }

    BLE _ble;
    ubyte _port;

    // pending connect state
    int _pending_connect_tag = -1;
    MACAddress _pending_connect_client;
    MACAddress _pending_connect_peer;

    // pending GATT operations
    enum max_pending_ops = 8;
    PendingGattOp[max_pending_ops] _pending_ops;
    ubyte _num_pending_ops;

    Map!(MACAddress, BLEAdv) _adv_handles;
    Map!(MACAddress, BLEAddrType) _addr_types; // LE address type by device, learnt from adverts
    Array!(Packet*) _emu_responses;

    BLEConn session_conn(const BLESession* session) const pure
        => BLEConn(cast(ubyte)session.transport);

    bool push_pending_op(ubyte tag, ubyte conn_id, ushort handle, bool is_read)
    {
        if (_num_pending_ops >= max_pending_ops)
            return false;
        _pending_ops[_num_pending_ops++] = PendingGattOp(tag, conn_id, handle, is_read);
        return true;
    }

    int pop_pending_op(ubyte conn_id, ushort handle, bool is_read)
    {
        foreach (i; 0 .. _num_pending_ops)
        {
            ref op = _pending_ops[i];
            if (op.conn_id == conn_id && op.handle == handle && op.is_read == is_read)
            {
                ubyte tag = op.tag;
                --_num_pending_ops;
                if (i < _num_pending_ops)
                    _pending_ops[i] = _pending_ops[_num_pending_ops];
                return tag;
            }
        }
        return -1;
    }

    // --- submit helpers ---

    bool submit_advert(QueuedFrame* frame, ref BLEFrame f)
    {
        switch (f.code)
        {
            case BLEAdvPDU.adv_ind:
            case BLEAdvPDU.adv_nonconn_ind:
            case BLEAdvPDU.adv_scan_ind:
            case BLEAdvPDU.adv_direct_ind:
                BLEAdvConfig cfg;
                cfg.adv_data = cast(const(ubyte)[])frame.packet.data;
                auto adv = ble_adv_start(_ble, cfg);
                if (!adv.is_valid)
                    return false;
                if (BLEAdv* old = f.src in _adv_handles)
                {
                    if ((*old).is_valid)
                        ble_adv_stop(_ble, *old);
                    *old = adv;
                }
                else
                    _adv_handles[f.src] = adv;
                register_adv_source(f.src, f.src);
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            case BLEAdvPDU.connect_ind:
                if (_pending_connect_tag >= 0)
                {
                    log.warning("connection already in progress");
                    return false;
                }

                BLEAddrType* peer_type = f.dst in _addr_types;

                BLEConnConfig conn_cfg;
                auto r = ble_connect(_ble, f.dst.b, peer_type ? *peer_type : BLEAddrType.public_, conn_cfg);
                if (!r)
                    return false;

                _pending_connect_tag = frame.tag;
                _pending_connect_client = f.src;
                _pending_connect_peer = f.dst;
                return true;

            default:
                return false;
        }
    }

    bool submit_control(QueuedFrame* frame, ref BLEFrame f)
    {
        switch (f.code)
        {
            case BLEControl.disconnect:
                auto session = find_session_by_client(f.src);
                if (session !is null)
                {
                    log.info("disconnecting from ", session.peer);
                    destroy_session(session);
                }
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            default:
                return false;
        }
    }

    // The host stack owns GATT, so the ATT data plane is emulated here: simple
    // data PDUs map to driver GATT ops, and the discovery procedures are
    // answered as a minimal (spec-legal) ATT server backed by the cache the
    // platform built at connect time. Decl handles are synthesized as
    // value_handle-1 and service ranges from the grouped cache; reads/writes
    // only ever use real value handles, so the approximation is self-consistent.
    bool submit_att(QueuedFrame* frame, ref BLEFrame f)
    {
        const(ubyte)[] pdu = cast(const(ubyte)[])frame.packet.data;

        if (pdu.length < 1)
            return false;

        auto session = find_session_by_client(f.src);
        if (session is null)
        {
            log.warning("ATT send: no session for ", f.src);
            return false;
        }

        switch (pdu[0])
        {
            case ATTOpcode.exchange_mtu_req:
            {
                // TODO: report the platform's real negotiated MTU when the
                //       driver API grows an accessor for it
                ubyte[3] rsp = void;
                rsp[0] = ATTOpcode.exchange_mtu_rsp;
                rsp[1 .. 3] = nativeToLittleEndian(ushort(att_emu_mtu));
                emu_respond(f, rsp[]);
                _queue.complete(frame.tag, MessageState.complete);
                return true;
            }

            case ATTOpcode.read_by_group_type_req:
                if (pdu.length < 7)
                    return false;
                emulate_services(session, f, pdu);
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            case ATTOpcode.read_by_type_req:
                if (pdu.length < 7)
                    return false;
                emulate_chars(session, f, pdu);
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            case ATTOpcode.find_information_req:
                if (pdu.length < 5)
                    return false;
                emulate_descriptors(session, f, pdu);
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            case ATTOpcode.read_req:
            {
                if (pdu.length < 3)
                    return false;
                ushort handle = pdu.ptr[1 .. 3].littleEndianToNative!ushort;

                if (session.find_char(handle) is null)
                {
                    emu_error(f, pdu[0], handle, ATTError.invalid_handle);
                    _queue.complete(frame.tag, MessageState.complete);
                    return true;
                }

                BLEConn conn = session_conn(session);
                if (!push_pending_op(frame.tag, conn.id, handle, true))
                    return false;
                auto r = ble_gatt_read(_ble, conn, handle);
                if (!r)
                {
                    pop_pending_op(conn.id, handle, true);
                    return false;
                }
                return true;
            }

            case ATTOpcode.write_req:
            case ATTOpcode.write_cmd:
            {
                if (pdu.length < 3)
                    return false;
                ushort handle = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
                bool with_response = pdu[0] == ATTOpcode.write_req;
                const(ubyte)[] data = pdu.length > 3 ? pdu[3 .. $] : null;
                BLEConn conn = session_conn(session);

                // CCCD write -> platform subscribe
                foreach (ref c; session.chars[0 .. session.num_chars])
                {
                    if (handle != 0 && emu_cccd(c) == handle)
                    {
                        bool enable = data.length >= 1 && (data[0] & 0x03) != 0;
                        ble_gatt_subscribe(_ble, conn, c.handle, enable);
                        if (with_response)
                        {
                            ubyte[1] rsp = [ ATTOpcode.write_rsp ];
                            emu_respond(f, rsp[]);
                        }
                        _queue.complete(frame.tag, MessageState.complete);
                        return true;
                    }
                }

                if (session.find_char(handle) is null)
                {
                    if (with_response)
                        emu_error(f, pdu[0], handle, ATTError.invalid_handle);
                    _queue.complete(frame.tag, MessageState.complete);
                    return true;
                }

                if (with_response)
                {
                    if (!push_pending_op(frame.tag, conn.id, handle, false))
                        return false;
                }

                auto r = ble_gatt_write(_ble, conn, handle, data, with_response);
                if (!r)
                {
                    if (with_response)
                        pop_pending_op(conn.id, handle, false);
                    return false;
                }

                if (!with_response)
                    _queue.complete(frame.tag, MessageState.complete);
                return true;
            }

            default:
                // a minimal ATT server: anything we can't map is legally unsupported
                emu_error(f, pdu[0], 0, ATTError.request_not_supported);
                _queue.complete(frame.tag, MessageState.complete);
                return true;
        }
    }

    // --- ATT server emulation ---

    enum ushort att_emu_mtu = 247;

    // Platform drivers don't all report real CCCD handles (WinRT hides CCCDs
    // entirely); synthesize value_handle+1 for notify-capable chars so the
    // client's descriptor discovery and CCCD writes have something to land on.
    static ushort emu_cccd(ref const GattCharacteristic c)
    {
        if (c.cccd_handle)
            return c.cccd_handle;
        if (c.can_notify)
            return cast(ushort)(c.handle + 1);
        return 0;
    }

    // synthesized service grouping over the flat platform cache: chars arrive
    // grouped by service, decl = value_handle-1, service start leaves room for
    // the service declaration, end abuts the next group
    struct EmuGroup
    {
        ushort start;
        ushort end;
        uint first; // index of first char in session.chars
        uint count;
        GUID uuid;
    }

    uint compute_groups(BLESession* session, ref EmuGroup[16] groups)
    {
        uint num;
        foreach (i; 0 .. session.num_chars)
        {
            ref const GattCharacteristic c = session.chars[i];
            if (num > 0 && groups[num - 1].uuid == c.service_uuid)
            {
                ++groups[num - 1].count;
                continue;
            }
            if (num == groups.length)
                break;
            EmuGroup* g = &groups[num++];
            g.start = c.handle > 2 ? cast(ushort)(c.handle - 2) : 1;
            g.first = i;
            g.count = 1;
            g.uuid = c.service_uuid;
        }

        // the platform cache isn't necessarily handle-ascending; sort groups
        // before assigning range ends so each group's chars fall in its range
        foreach (i; 1 .. num)
        {
            EmuGroup g = groups[i];
            uint j = i;
            for (; j > 0 && groups[j - 1].start > g.start; --j)
                groups[j] = groups[j - 1];
            groups[j] = g;
        }

        foreach (i; 0 .. num)
            groups[i].end = i + 1 < num ? cast(ushort)(groups[i + 1].start - 1) : 0xFFFF;

        return num;
    }

    void emulate_services(BLESession* session, ref BLEFrame f, const(ubyte)[] pdu)
    {
        ushort start = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
        ushort end = pdu.ptr[3 .. 5].littleEndianToNative!ushort;

        if (pdu.length != 7 || pdu.ptr[5 .. 7].littleEndianToNative!ushort != GattAttributeType.primary_service)
        {
            emu_error(f, pdu[0], start, ATTError.unsupported_group);
            return;
        }

        EmuGroup[16] groups = void;
        uint num = compute_groups(session, groups);

        ubyte[2 + 12 * 20] rsp = void;
        rsp[0] = ATTOpcode.read_by_group_type_rsp;
        rsp[1] = 20;
        size_t len = 2;

        foreach (i; 0 .. num)
        {
            ref const EmuGroup g = groups[i];
            if (g.start < start || g.start > end)
                continue;
            if (len + 20 > rsp.length)
                break;
            rsp[len .. len + 2] = g.start.nativeToLittleEndian;
            rsp[len + 2 .. len + 4] = g.end.nativeToLittleEndian;
            guid_to_att_uuid(g.uuid, rsp[len + 4 .. len + 20][0 .. 16]);
            len += 20;
        }

        if (len == 2)
            emu_error(f, pdu[0], start, ATTError.attribute_not_found);
        else
            emu_respond(f, rsp[0 .. len]);
    }

    void emulate_chars(BLESession* session, ref BLEFrame f, const(ubyte)[] pdu)
    {
        ushort start = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
        ushort end = pdu.ptr[3 .. 5].littleEndianToNative!ushort;

        if (pdu.length != 7 || pdu.ptr[5 .. 7].littleEndianToNative!ushort != GattAttributeType.characteristic)
        {
            emu_error(f, pdu[0], start, ATTError.attribute_not_found);
            return;
        }

        ubyte[2 + 11 * 21] rsp = void;
        rsp[0] = ATTOpcode.read_by_type_rsp;
        rsp[1] = 21;
        size_t len = 2;

        foreach (i; 0 .. session.num_chars)
        {
            ref const GattCharacteristic c = session.chars[i];
            ushort decl = c.handle >= 1 ? cast(ushort)(c.handle - 1) : 1;
            if (decl < start || decl > end)
                continue;
            if (len + 21 > rsp.length)
                break;
            rsp[len .. len + 2] = decl.nativeToLittleEndian;
            rsp[len + 2] = cast(ubyte)c.properties;
            rsp[len + 3 .. len + 5] = c.handle.nativeToLittleEndian;
            guid_to_att_uuid(c.char_uuid, rsp[len + 5 .. len + 21][0 .. 16]);
            len += 21;
        }

        if (len == 2)
            emu_error(f, pdu[0], start, ATTError.attribute_not_found);
        else
            emu_respond(f, rsp[0 .. len]);
    }

    void emulate_descriptors(BLESession* session, ref BLEFrame f, const(ubyte)[] pdu)
    {
        ushort start = pdu.ptr[1 .. 3].littleEndianToNative!ushort;
        ushort end = pdu.ptr[3 .. 5].littleEndianToNative!ushort;

        ubyte[2 + 32 * 4] rsp = void;
        rsp[0] = ATTOpcode.find_information_rsp;
        rsp[1] = 1; // 16-bit uuid format
        size_t len = 2;

        foreach (i; 0 .. session.num_chars)
        {
            ref const GattCharacteristic c = session.chars[i];
            ushort cccd = emu_cccd(c);
            if (cccd == 0 || cccd < start || cccd > end)
                continue;
            if (len + 4 > rsp.length)
                break;
            rsp[len .. len + 2] = cccd.nativeToLittleEndian;
            rsp[len + 2 .. len + 4] = nativeToLittleEndian(ushort(GattAttributeType.cccd));
            len += 4;
        }

        if (len == 2)
            emu_error(f, pdu[0], start, ATTError.attribute_not_found);
        else
            emu_respond(f, rsp[0 .. len]);
    }

    void emu_error(ref BLEFrame req, ubyte req_op, ushort handle, ATTError error)
    {
        ubyte[5] pdu = void;
        pdu[0] = ATTOpcode.error_rsp;
        pdu[1] = req_op;
        pdu[2 .. 4] = handle.nativeToLittleEndian;
        pdu[4] = error;
        emu_respond(req, pdu[]);
    }

    // Emulated responses are delivered from service() rather than inline:
    // submit_att runs inside the send_queued_messages loop, and dispatching a
    // response synchronously would re-enter the client engine (and this queue)
    // mid-iteration.
    void emu_respond(ref BLEFrame req, const(ubyte)[] pdu)
    {
        Packet p;
        ref f = p.init!BLEFrame(pdu);
        f.src = req.dst;
        f.dst = req.src;
        f.kind = BLEFrameKind.att;
        f.code = pdu[0];
        _emu_responses ~= p.clone();

        import protocol.ble : BLEModule;
        get_module!BLEModule.request_service();
    }

    void drain_emu_responses()
    {
        while (_emu_responses.length > 0)
        {
            Packet* p = _emu_responses[0];
            _emu_responses.remove(0);
            on_incoming(*p);
            p.free_clone();
        }
    }

    // --- driver callback handlers ---

    __gshared BuiltinBLEInterface[num_ble] _active_radios;

    static void scan_dispatch(BLE ble, ref const BLEAdvReport report)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_scan_report(report);
    }

    static void conn_dispatch(BLE ble, BLEConn conn, bool connected, BLEError error)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_conn_event(conn, connected, error);
    }

    static void discover_dispatch(BLE ble, BLEConn conn, const(BLEGattChar)[] chars, BLEError error)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_discover_complete(conn, chars, error);
    }

    static void read_dispatch(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data, BLEError error)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_read_complete(conn, handle, data, error);
    }

    static void write_dispatch(BLE ble, BLEConn conn, ushort handle, BLEError error)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_write_complete(conn, handle, error);
    }

    static void notify_dispatch(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data)
    {
        if (ble.port < num_ble)
            if (auto iface = _active_radios[ble.port])
                iface.on_notification(conn, handle, data);
    }

    static void wake_dispatch()
    {
        import protocol.ble : BLEModule;
        get_module!BLEModule.request_service();
    }

    void on_scan_report(ref const BLEAdvReport report)
    {
        MACAddress addr = MACAddress(report.addr);

        // remember the LE address type for connectable devices; connecting needs it
        if (report.adv_type == BLEAdvType.connectable)
        {
            if (_addr_types.length >= 256)
                _addr_types.clear(); // crude bound; re-learnt from live adverts
            _addr_types[addr] = report.addr_type;
        }

        Packet p;
        ref f = p.init!BLEFrame(report.data);
        f.src = addr;
        f.dst = MACAddress.broadcast;
        f.kind = BLEFrameKind.advert;
        f.code = report.adv_type == BLEAdvType.connectable ? BLEAdvPDU.adv_ind : BLEAdvPDU.adv_nonconn_ind;
        f.rssi = report.rssi;

        on_incoming(p);
    }

    void on_conn_event(BLEConn conn, bool connected, BLEError error)
    {
        if (connected)
        {
            auto session = add_session(_pending_connect_client, _pending_connect_peer, conn.id);
            log.info("connected to ", session.peer, ", caching GATT...");

            // the connect request completes when the GATT cache is warm, so
            // the client's ATT discovery always answers immediately
            ble_gatt_discover(_ble, conn);
        }
        else
        {
            // connection failed or disconnected
            if (_pending_connect_tag >= 0 && !conn.is_valid)
            {
                // connect attempt failed
                log.error("connection failed");
                _queue.complete(cast(ubyte)_pending_connect_tag, MessageState.failed);
                clear_pending_connect();
                return;
            }

            // existing connection lost
            auto session = find_session_by_transport(conn.id);
            if (session !is null)
            {
                log.info("disconnected from ", session.peer);

                // dropped while the GATT cache was still warming
                if (_pending_connect_tag >= 0 && session.peer == _pending_connect_peer)
                {
                    _queue.complete(cast(ubyte)_pending_connect_tag, MessageState.failed);
                    clear_pending_connect();
                }

                // notify subscribers via disconnect frame
                Packet p;
                ref f = p.init!BLEFrame(null);
                f.src = mac;
                f.dst = session.client;
                f.kind = BLEFrameKind.control;
                f.code = BLEControl.disconnected;
                on_incoming(p);

                session.active = false;
            }
        }
    }

    void clear_pending_connect()
    {
        _pending_connect_tag = -1;
        _pending_connect_client = MACAddress.init;
        _pending_connect_peer = MACAddress.init;
    }

    void on_discover_complete(BLEConn conn, const(BLEGattChar)[] chars, BLEError error)
    {
        auto session = find_session_by_transport(conn.id);
        if (session is null)
            return;

        bool pending = _pending_connect_tag >= 0 && session.peer == _pending_connect_peer;

        if (error != BLEError.none)
        {
            log.error("GATT discovery failed");
            if (pending)
            {
                _queue.complete(cast(ubyte)_pending_connect_tag, MessageState.failed);
                clear_pending_connect();
            }
            session.active = false;
            return;
        }

        session.num_chars = 0;
        foreach (ref c; chars)
        {
            if (session.num_chars >= session.chars.length)
                break;
            auto gc = &session.chars[session.num_chars++];
            gc.handle = c.handle;
            gc.cccd_handle = c.cccd_handle;
            gc.service_uuid = c.service_uuid;
            gc.char_uuid = c.char_uuid;
            gc.properties = c.properties;
        }

        log.info("GATT cache ready: ", session.num_chars, " characteristics");
        foreach (i; 0 .. session.num_chars)
        {
            ref const GattCharacteristic gc = session.chars[i];
            log.trace("  char handle=", gc.handle, " cccd=", gc.cccd_handle, " props=", gc.properties, " svc=", gc.service_uuid, " uuid=", gc.char_uuid);
        }

        if (pending)
        {
            _queue.complete(cast(ubyte)_pending_connect_tag, MessageState.complete);
            clear_pending_connect();
        }
    }

    void on_read_complete(BLEConn conn, ushort handle, const(ubyte)[] data, BLEError error)
    {
        int tag = pop_pending_op(conn.id, handle, true);

        auto session = find_session_by_transport(conn.id);
        MACAddress client, peer;
        if (session !is null)
        {
            client = session.client;
            peer = session.peer;
        }

        if (error == BLEError.none)
        {
            // read_rsp PDU is [opcode][value...] (correlation is by outstanding request)
            ubyte[513] buf = void;
            size_t n = data.length;
            if (n > buf.length - 1)
                n = buf.length - 1;
            buf[0] = ATTOpcode.read_rsp;
            buf[1 .. 1 + n] = data[0 .. n];

            Packet p;
            ref f = p.init!BLEFrame(buf[0 .. 1 + n]);
            f.src = peer;
            f.dst = client;
            f.kind = BLEFrameKind.att;
            f.code = ATTOpcode.read_rsp;
            on_incoming(p);
        }

        if (tag >= 0)
            _queue.complete(cast(ubyte)tag, error == BLEError.none ? MessageState.complete : MessageState.failed);

        send_queued_messages();
    }

    void on_write_complete(BLEConn conn, ushort handle, BLEError error)
    {
        int tag = pop_pending_op(conn.id, handle, false);

        auto session = find_session_by_transport(conn.id);
        MACAddress client, peer;
        if (session !is null)
        {
            client = session.client;
            peer = session.peer;
        }

        if (error == BLEError.none)
        {
            ubyte[1] buf = [ ATTOpcode.write_rsp ];

            Packet p;
            ref f = p.init!BLEFrame(buf[]);
            f.src = peer;
            f.dst = client;
            f.kind = BLEFrameKind.att;
            f.code = ATTOpcode.write_rsp;
            on_incoming(p);
        }

        if (tag >= 0)
            _queue.complete(cast(ubyte)tag, error == BLEError.none ? MessageState.complete : MessageState.failed);

        send_queued_messages();
    }

    void on_notification(BLEConn conn, ushort handle, const(ubyte)[] data)
    {
        auto session = find_session_by_transport(conn.id);
        if (session is null)
            return;

        // notification PDU is [opcode][handle(2)][value...]
        ubyte[250] buf = void;
        if (3 + data.length > buf.length)
            return;
        buf[0] = ATTOpcode.notification;
        buf[1 .. 3] = handle.nativeToLittleEndian;
        buf[3 .. 3 + data.length] = data[];

        Packet p;
        ref f = p.init!BLEFrame(buf[0 .. 3 + data.length]);
        f.src = session.peer;
        f.dst = session.client;
        f.kind = BLEFrameKind.att;
        f.code = ATTOpcode.notification;

        on_incoming(p);
    }
}


class BuiltinBLEModule : Module
{
    mixin DeclareModule!"interface.ble.builtin";
nothrow @nogc:

    override void pre_init()
    {
        // builtin radios are fixed hardware; rediscovered each boot, not persisted
        foreach (ubyte i; 0 .. num_ble)
        {
            auto iface = Collection!BuiltinBLEInterface().create(tconcat("ble", i + 1), ObjectFlags.dynamic);
            iface.port = i;
        }
    }

    override void init()
    {
        g_app.console.register_collection!BuiltinBLEInterface();
    }
}
