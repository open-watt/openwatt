module protocol.ble.iface;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.result;
import urt.string;
import urt.time;

import manager;
import manager.collection;

import router.iface;
import router.iface.priority_queue;

import protocol.ble.device : ADSection, ADType;

import sys.baremetal.ble;

import urt.uuid;

version = DebugBLEInterface;
version = SuppressAdvertisments;

nothrow @nogc:


enum BLELLType : ubyte
{
    // advertising channel PDU types
    adv_ind         = 0x00,
    adv_direct_ind  = 0x01,
    adv_nonconn_ind = 0x02,
    scan_req        = 0x03,
    scan_rsp        = 0x04,
    connect_ind     = 0x05,
    adv_scan_ind    = 0x06,
    adv_ext_ind     = 0x07,

    // data channel LLID
    data_continue   = 0x10,
    data_start      = 0x11,
    control         = 0x13,

    // internal connection management (not over-the-air)
    connect_rsp     = 0x20,  // connection established
    disconnect_ind  = 0x21,  // connection lost/closed
}

enum ATTOpcode : ubyte
{
    error_rsp               = 0x01,
    exchange_mtu_req        = 0x02,
    exchange_mtu_rsp        = 0x03,
    find_information_req    = 0x04,
    find_information_rsp    = 0x05,
    find_by_type_value_req  = 0x06,
    find_by_type_value_rsp  = 0x07,
    read_by_type_req        = 0x08,
    read_by_type_rsp        = 0x09,
    read_req                = 0x0A,
    read_rsp                = 0x0B,
    read_blob_req           = 0x0C,
    read_blob_rsp           = 0x0D,
    read_multiple_req       = 0x0E,
    read_multiple_rsp       = 0x0F,
    read_by_group_type_req  = 0x10,
    read_by_group_type_rsp  = 0x11,
    write_req               = 0x12,
    write_rsp               = 0x13,
    write_cmd               = 0x52,
    signed_write_cmd        = 0xD2,
    prepare_write_req       = 0x16,
    prepare_write_rsp       = 0x17,
    execute_write_req       = 0x18,
    execute_write_rsp       = 0x19,
    notification            = 0x1B,
    indication              = 0x1D,
    confirmation            = 0x1E,
}


// packet header for Link Layer PDUs (connection management, raw radio)
struct BLELLFrame
{
    enum Type = PacketType.ble_ll;

    MACAddress src;           // originator
    MACAddress dst;           // destination
    BLELLType pdu_type;
    byte rssi;
    // 14 bytes used, 10 spare
}

// packet header for ATT operations (GATT data, most common)
// payload is the raw ATT PDU parameters (handle + value, varies by opcode)
struct BLEATTFrame
{
    enum Type = PacketType.ble_att;

    MACAddress src;           // originator (local routing)
    MACAddress dst;           // destination (local routing)
    ATTOpcode opcode;
    byte rssi;
    // 14 bytes used, 10 spare
}

static assert(BLELLFrame.sizeof <= 24);
static assert(BLEATTFrame.sizeof <= 24);



enum uint ble_queue_timeout = 5000; // milliseconds

class BLEInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("max-in-flight", max_in_flight));
nothrow @nogc:

    enum type_name = "ble";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BLEInterface, id, flags);
        _mtu = 247; // BLE 5.x max ATT payload (251 - 4 byte L2CAP header)
        _max_l2mtu = 251;
        _l2mtu = _max_l2mtu;
    }


    // Properties...

    ubyte max_in_flight() const pure
        => _max_in_flight;
    StringResult max_in_flight(ubyte value)
    {
        if (value == 0)
            return StringResult("max-in-flight must be non-zero");
        _max_in_flight = value;
        return StringResult.success;
    }


    // API...

    final override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle >= 0 && msg_handle <= 0xFF, "invalid msg_handle");

        ubyte t = cast(ubyte)msg_handle;
        if (auto pm = t in _pending)
        {
            if (pm.callback)
                pm.callback(msg_handle, reason);
            _pending.remove(t);
        }
        _queue.abort(t);
    }

    final override MessageState msg_state(int msg_handle) const
    {
        if (cast(ubyte)msg_handle in _pending)
            return MessageState.in_flight;
        if (_queue.is_queued(cast(ubyte)msg_handle))
            return MessageState.queued;
        return MessageState.complete;
    }

protected:

    override bool validate() const
        => true;

    override CompletionStatus startup()
    {
        _queue.init(_max_in_flight, 0, PCP.be, &_status);

        static if (num_ble > 0)
        {
            BLEConfig cfg;
            auto r = ble_open(_ble, 0, cfg);
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

            _active_radios[0] = this;

            BLEScanConfig scan_cfg;
            ble_scan_start(_ble, scan_cfg);

            log.info("BLE started on interface '", name, "'");
        }
        else
            return CompletionStatus.error;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        static if (num_ble > 0)
        {
            if (_ble.is_open)
            {
                ble_close(_ble);
                _active_radios[_ble.port] = null;
            }
        }

        _num_adv_entries = 0;

        while (_sessions.length > 0)
            destroy_session(_sessions[0]);

        foreach (kvp; _pending[])
        {
            if (kvp.value.callback)
                kvp.value.callback(kvp.key, MessageState.aborted);
        }
        _pending.clear();
        _queue.abort_all();

        _num_pending_ops = 0;
        _pending_connect_tag = -1;

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        static if (num_ble > 0)
        {
            if (_ble.is_open)
                ble_poll(_ble);
        }

        cleanup_dead_sessions();
        _queue.timeout_stale(getTime());
        send_queued_messages();
    }

    final override int transmit(ref Packet packet, MessageCallback callback = null)
    {
        if (packet.type != PacketType.ble_ll && packet.type != PacketType.ble_att)
        {
            ++_status.tx_dropped;
            return -1;
        }

        Packet p = packet;
        int tag = _queue.enqueue(p, &on_frame_complete);
        if (tag < 0)
        {
            ++_status.tx_dropped;
            return -1;
        }

        _pending[cast(ubyte)tag] = PendingMessage(callback,
            packet.type == PacketType.ble_att ? packet.hdr!BLEATTFrame : BLEATTFrame.init,
            cast(ushort)packet.data.length, getTime());

        send_queued_messages();
        return tag;
    }

    override ushort pcap_type() const
        => 251; // DLT_BLUETOOTH_LE_LL

package:

    struct PendingMessage
    {
        MessageCallback callback;
        BLEATTFrame att;
        ushort message_length;
        MonoTime send_time;
    }

    struct AdvEntry
    {
        MACAddress advertiser;
        MACAddress source;
        BLEAdv adv_handle;
    }

    // pending GATT op — correlates driver callback to queue tag
    struct PendingGattOp
    {
        ubyte tag;
        ubyte conn_id;
        ushort handle;
        bool is_read; // true = read, false = write
    }

    ubyte _max_in_flight = 4;

    Array!(BLESession*) _sessions;

    PriorityPacketQueue _queue;
    Map!(ubyte, PendingMessage) _pending;

    enum max_adv_entries = 8;
    AdvEntry[max_adv_entries] _adv_table;
    ubyte _num_adv_entries;

    // pending connect state
    int _pending_connect_tag = -1;
    MACAddress _pending_connect_client;
    MACAddress _pending_connect_peer;

    // pending GATT operations
    enum max_pending_ops = 8;
    PendingGattOp[max_pending_ops] _pending_ops;
    ubyte _num_pending_ops;

    static if (num_ble > 0)
        BLE _ble;

    MACAddress find_adv_source(MACAddress advertiser)
    {
        foreach (ref e; _adv_table[0 .. _num_adv_entries])
        {
            if (e.advertiser == advertiser)
                return e.source;
        }
        return MACAddress.init;
    }

    void register_adv_source(MACAddress advertiser, MACAddress source, BLEAdv adv_handle)
    {
        foreach (ref e; _adv_table[0 .. _num_adv_entries])
        {
            if (e.advertiser == advertiser)
            {
                e.source = source;
                static if (num_ble > 0)
                {
                    if (e.adv_handle.is_valid)
                        ble_adv_stop(_ble, e.adv_handle);
                }
                e.adv_handle = adv_handle;
                return;
            }
        }
        if (_num_adv_entries < max_adv_entries)
            _adv_table[_num_adv_entries++] = AdvEntry(advertiser, source, adv_handle);
    }

    BLESession* find_session_by_peer(MACAddress peer)
    {
        foreach (s; _sessions[])
        {
            if (s.peer == peer)
                return s;
        }
        return null;
    }

    BLESession* find_session_by_client(MACAddress client)
    {
        foreach (s; _sessions[])
        {
            if (s.client == client)
                return s;
        }
        return null;
    }

    BLESession* find_session_by_conn(ubyte conn_id)
    {
        foreach (s; _sessions[])
        {
            if (s.conn.id == conn_id)
                return s;
        }
        return null;
    }

    // incoming packet handler — NAT rewriting and dispatch
    void on_incoming(ref Packet p)
    {
        if (p.type == PacketType.ble_ll)
        {
            ref ll = p.hdr!BLELLFrame;

            switch (ll.pdu_type)
            {
                case BLELLType.adv_ind:
                case BLELLType.adv_nonconn_ind:
                case BLELLType.adv_scan_ind:
                case BLELLType.adv_direct_ind:
                case BLELLType.scan_rsp:
                    import protocol.ble;
                    get_module!BLEModule.on_advert(ll.src, ll.rssi,
                        ll.pdu_type == BLELLType.adv_ind,
                        ll.pdu_type == BLELLType.scan_rsp,
                        cast(const(ubyte)[])p.data);
                    break;

                case BLELLType.connect_ind:
                    MACAddress server = find_adv_source(ll.dst);
                    if (server)
                    {
                        ll.dst = server;
                        log.info("incoming connection from ", ll.src, " routed to ", server);
                    }
                    else
                        log.warning("incoming connection to unknown advertisement ", ll.dst);
                    break;

                default:
                    break;
            }

            version (DebugBLEInterface)
                log_ll_packet(ll, cast(const(ubyte)[])p.data, PacketDirection.incoming);
        }
        else if (p.type == PacketType.ble_att)
        {
            ref att = p.hdr!BLEATTFrame;

            auto session = find_session_by_peer(att.src);
            if (session)
                att.dst = session.client;

            version (DebugBLEInterface)
                log_att_packet(att, cast(const(ubyte)[])p.data, PacketDirection.incoming);
        }

        _status.rx_bytes += 14;
        dispatch(p);
    }

    // --- session lifecycle ---

    void cleanup_dead_sessions()
    {
        uint i = 0;
        while (i < _sessions.length)
        {
            if (!_sessions[i].active)
                destroy_session(_sessions[i]);
            else
                i++;
        }
    }

    void destroy_session(BLESession* session)
    {
        static if (num_ble > 0)
        {
            if (_ble.is_open && session.conn.is_valid)
                ble_disconnect(_ble, session.conn);
        }

        foreach (i, s; _sessions[])
        {
            if (s is session)
            {
                _sessions.remove(i);
                break;
            }
        }

        defaultAllocator().freeT(session);
    }

    // --- pending GATT op tracking ---

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

    bool submit_ll(QueuedFrame* frame)
    {
        ref ll = frame.packet.hdr!BLELLFrame;

        switch (ll.pdu_type)
        {
            case BLELLType.adv_ind:
            case BLELLType.adv_nonconn_ind:
            case BLELLType.adv_scan_ind:
            case BLELLType.adv_direct_ind:
                static if (num_ble > 0)
                {
                    BLEAdvConfig cfg;
                    cfg.adv_data = cast(const(ubyte)[])frame.packet.data;
                    auto adv = ble_adv_start(_ble, cfg);
                    if (adv.is_valid)
                    {
                        register_adv_source(ll.src, ll.src, adv);
                        _queue.complete(frame.tag, MessageState.complete);
                        return true;
                    }
                    return false;
                }
                else
                    return false;

            case BLELLType.connect_ind:
                static if (num_ble > 0)
                {
                    if (_pending_connect_tag >= 0)
                    {
                        log.warning("connection already in progress");
                        return false;
                    }

                    BLEConnConfig conn_cfg;
                    auto r = ble_connect(_ble, ll.dst.b, BLEAddrType.public_, conn_cfg);
                    if (!r)
                        return false;

                    _pending_connect_tag = frame.tag;
                    _pending_connect_client = ll.src;
                    _pending_connect_peer = ll.dst;
                    return true;
                }
                else
                    return false;

            case BLELLType.disconnect_ind:
                auto session = find_session_by_client(ll.src);
                if (session !is null)
                {
                    log.info("disconnecting from ", session.peer);
                    destroy_session(session);
                }
                _queue.complete(frame.tag, MessageState.complete);
                return true;

            case BLELLType.data_start:
            case BLELLType.data_continue:
                assert(false, "TODO: LL data PDU defragmentation not implemented");

            default:
                return false;
        }
    }

    bool submit_att(QueuedFrame* frame)
    {
        ref att = frame.packet.hdr!BLEATTFrame;
        const(ubyte)[] payload = cast(const(ubyte)[])frame.packet.data;

        if (payload.length < 2)
        {
            log.warning("ATT send: payload too short");
            return false;
        }

        ushort handle = payload.ptr[0..2].littleEndianToNative!ushort;

        auto session = find_session_by_client(att.src);
        if (session is null)
        {
            log.warning("ATT send: no session for ", att.src);
            return false;
        }

        if (session.find_char(handle) is null)
        {
            log.warning("ATT send: unknown handle ", handle);
            return false;
        }

        static if (num_ble > 0)
        {
            switch (att.opcode)
            {
                case ATTOpcode.read_req:
                    if (!push_pending_op(frame.tag, session.conn.id, handle, true))
                        return false;
                    auto r = ble_gatt_read(_ble, session.conn, handle);
                    if (!r)
                    {
                        pop_pending_op(session.conn.id, handle, true);
                        return false;
                    }
                    return true;

                case ATTOpcode.write_req:
                case ATTOpcode.write_cmd:
                    bool with_response = att.opcode == ATTOpcode.write_req;
                    const(ubyte)[] data = payload.length > 2 ? payload[2 .. $] : null;

                    if (with_response)
                    {
                        if (!push_pending_op(frame.tag, session.conn.id, handle, false))
                            return false;
                    }

                    auto r = ble_gatt_write(_ble, session.conn, handle, data, with_response);
                    if (!r)
                    {
                        if (with_response)
                            pop_pending_op(session.conn.id, handle, false);
                        return false;
                    }

                    if (!with_response)
                        _queue.complete(frame.tag, MessageState.complete);
                    return true;

                default:
                    return false;
            }
        }
        else
            return false;
    }

    void send_queued_messages()
    {
        for (QueuedFrame* frame = _queue.dequeue(); frame !is null; frame = _queue.dequeue())
        {
            if (_num_pending_ops >= max_pending_ops)
                return;

            version (DebugBLEInterface)
            {
                if (frame.packet.type == PacketType.ble_ll)
                    log_ll_packet(frame.packet.hdr!BLELLFrame, cast(const(ubyte)[])frame.packet.data, PacketDirection.outgoing);
                else if (frame.packet.type == PacketType.ble_att)
                    log_att_packet(frame.packet.hdr!BLEATTFrame, cast(const(ubyte)[])frame.packet.data, PacketDirection.outgoing);
            }

            bool submitted = false;

            if (frame.packet.type == PacketType.ble_ll)
                submitted = submit_ll(frame);
            else if (frame.packet.type == PacketType.ble_att)
                submitted = submit_att(frame);

            if (submitted)
            {
                if (auto pm = frame.tag in _pending)
                {
                    if (pm.callback)
                        pm.callback(frame.tag, MessageState.in_flight);
                }
            }
            else
                _queue.complete(frame.tag, MessageState.failed);
        }
    }

    void on_frame_complete(int tag, MessageState state)
    {
        ubyte t = cast(ubyte)tag;
        if (auto pm = t in _pending)
        {
            if (state == MessageState.complete)
            {
                ++_status.tx_packets;
                _status.tx_bytes += pm.message_length + 14;
            }
            else if (state != MessageState.in_flight)
                ++_status.tx_dropped;

            if (pm.callback)
                pm.callback(tag, state);
            _pending.remove(t);
        }
    }

    // --- driver callback handlers ---

    static if (num_ble > 0)
    {
        __gshared BLEInterface[num_ble] _active_radios;

        // scan result → advertisement packet
        static void scan_dispatch(BLE ble, ref const BLEAdvReport report) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_scan_report(report);
        }

        // connection state change
        static void conn_dispatch(BLE ble, BLEConn conn, bool connected, BLEError error) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_conn_event(conn, connected, error);
        }

        // GATT discovery complete
        static void discover_dispatch(BLE ble, BLEConn conn, const(BLEGattChar)[] chars, BLEError error) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_discover_complete(conn, chars, error);
        }

        // GATT read complete
        static void read_dispatch(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data, BLEError error) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_read_complete(conn, handle, data, error);
        }

        // GATT write complete
        static void write_dispatch(BLE ble, BLEConn conn, ushort handle, BLEError error) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_write_complete(conn, handle, error);
        }

        // notification/indication received
        static void notify_dispatch(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data) nothrow @nogc
        {
            if (ble.port < num_ble)
                if (auto iface = _active_radios[ble.port])
                    iface.on_notification(conn, handle, data);
        }
    }

    void on_scan_report(ref const BLEAdvReport report)
    {
        MACAddress addr = MACAddress(report.addr);

        Packet p;
        ref ll = p.init!BLELLFrame(report.data);
        ll.src = addr;
        ll.dst = MACAddress.broadcast;
        ll.pdu_type = report.adv_type == BLEAdvType.connectable ? BLELLType.adv_ind : BLELLType.adv_nonconn_ind;
        ll.rssi = report.rssi;

        on_incoming(p);
    }

    void on_conn_event(BLEConn conn, bool connected, BLEError error)
    {
        if (connected)
        {
            auto session = defaultAllocator().allocT!BLESession;
            session.client = _pending_connect_client;
            session.peer = _pending_connect_peer;
            session.conn = conn;
            session.active = true;

            _sessions ~= session;
            log.info("connected to ", session.peer);

            // complete the connect request
            if (_pending_connect_tag >= 0)
            {
                _queue.complete(cast(ubyte)_pending_connect_tag, MessageState.complete);
                _pending_connect_tag = -1;
                _pending_connect_client = MACAddress.init;
                _pending_connect_peer = MACAddress.init;
            }

            // start GATT discovery
            static if (num_ble > 0)
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
                _pending_connect_tag = -1;
                _pending_connect_client = MACAddress.init;
                return;
            }

            // existing connection lost
            auto session = find_session_by_conn(conn.id);
            if (session !is null)
            {
                log.info("disconnected from ", session.peer);

                // notify subscribers via disconnect packet
                Packet p;
                ref ll = p.init!BLELLFrame(null);
                ll.src = mac;
                ll.dst = session.client;
                ll.pdu_type = BLELLType.disconnect_ind;
                on_incoming(p);

                session.active = false;
            }
        }
    }

    void on_discover_complete(BLEConn conn, const(BLEGattChar)[] chars, BLEError error)
    {
        auto session = find_session_by_conn(conn.id);
        if (session is null)
            return;

        if (error != BLEError.none)
        {
            log.error("GATT discovery failed");
            return;
        }

        session.num_chars = 0;
        foreach (ref c; chars)
        {
            if (session.num_chars >= session.chars.length)
                break;
            auto gc = &session.chars[session.num_chars++];
            gc.handle = c.handle;
            gc.service_uuid = c.service_uuid;
            gc.char_uuid = c.char_uuid;
            gc.properties = c.properties;
        }

        log.info("GATT discovery complete: ", session.num_chars, " characteristics");

        // auto-subscribe to notifications/indications
        static if (num_ble > 0)
        {
            foreach (ref gc; session.chars[0 .. session.num_chars])
            {
                if (gc.properties & (GattCharProps.notify | GattCharProps.indicate))
                    ble_gatt_subscribe(_ble, conn, gc.handle, true);
            }
        }
    }

    void on_read_complete(BLEConn conn, ushort handle, const(ubyte)[] data, BLEError error)
    {
        int tag = pop_pending_op(conn.id, handle, true);

        auto session = find_session_by_conn(conn.id);
        MACAddress client, peer;
        if (session !is null)
        {
            client = session.client;
            peer = session.peer;
        }

        if (error == BLEError.none)
        {
            Packet p;
            ref att = p.init!BLEATTFrame(data);
            att.src = peer;
            att.dst = client;
            att.opcode = ATTOpcode.read_rsp;
            on_incoming(p);
        }

        if (tag >= 0)
            _queue.complete(cast(ubyte)tag, error == BLEError.none ? MessageState.complete : MessageState.failed);

        send_queued_messages();
    }

    void on_write_complete(BLEConn conn, ushort handle, BLEError error)
    {
        int tag = pop_pending_op(conn.id, handle, false);

        auto session = find_session_by_conn(conn.id);
        MACAddress client, peer;
        if (session !is null)
        {
            client = session.client;
            peer = session.peer;
        }

        if (error == BLEError.none)
        {
            Packet p;
            ref att = p.init!BLEATTFrame(null);
            att.src = peer;
            att.dst = client;
            att.opcode = ATTOpcode.write_rsp;
            on_incoming(p);
        }

        if (tag >= 0)
            _queue.complete(cast(ubyte)tag, error == BLEError.none ? MessageState.complete : MessageState.failed);

        send_queued_messages();
    }

    void on_notification(BLEConn conn, ushort handle, const(ubyte)[] data)
    {
        auto session = find_session_by_conn(conn.id);
        if (session is null)
            return;

        // notification payload is [handle(2)][value...]
        ubyte[249] buf = void;
        if (2 + data.length > buf.length)
            return;
        buf[0 .. 2] = handle.nativeToLittleEndian;
        buf[2 .. 2 + data.length] = cast(const(ubyte)[])data[];

        Packet p;
        ref att = p.init!BLEATTFrame(buf[0 .. 2 + data.length]);
        att.src = session.peer;
        att.dst = session.client;
        att.opcode = ATTOpcode.notification;

        on_incoming(p);
    }

    version (DebugBLEInterface)
    {
        void log_ll_packet(ref const BLELLFrame ll, const(ubyte)[] payload, PacketDirection dir)
        {
            const dir_str = dir == PacketDirection.incoming ? "<--" : "-->";
            switch (ll.pdu_type)
            {
                case BLELLType.adv_ind:
                    version (SuppressAdvertisments) {} else
                        log.trace(dir_str, " ADV_IND  ", ll.src, " rssi=", ll.rssi, " [ ", cast(void[])payload, " ]");
                    break;
                case BLELLType.adv_nonconn_ind:
                    version (SuppressAdvertisments) {} else
                        log.trace(dir_str, " ADV_NONCONN ", ll.src, " rssi=", ll.rssi, " [ ", cast(void[])payload, " ]");
                    break;
                case BLELLType.scan_rsp:
                    version (SuppressAdvertisments) {} else
                        log.trace(dir_str, " SCAN_RSP ", ll.src, " rssi=", ll.rssi, " [ ", cast(void[])payload, " ]");
                    break;
                case BLELLType.connect_ind:
                    log.trace(dir_str, " CONN_IND ", ll.src, " -> ", ll.dst);
                    break;
                case BLELLType.connect_rsp:
                    log.trace(dir_str, " CONN_RSP ", ll.src, " -> ", ll.dst);
                    break;
                case BLELLType.disconnect_ind:
                    log.trace(dir_str, " DISCONN  ", ll.src, " -> ", ll.dst);
                    break;
                default:
                    log.trace(dir_str, " LL type=", cast(ubyte)ll.pdu_type, " ", ll.src, " [ ", cast(void[])payload, " ]");
                    break;
            }
        }

        void log_att_packet(ref const BLEATTFrame att, const(ubyte)[] payload, PacketDirection dir)
        {
            const(char)[] dir_str = dir == PacketDirection.incoming ? "<--" : "-->";

            bool has_handle = false;
            switch (att.opcode)
            {
                case ATTOpcode.read_req:
                case ATTOpcode.write_req:
                case ATTOpcode.write_cmd:
                case ATTOpcode.notification:
                case ATTOpcode.indication:
                    has_handle = payload.length >= 2;
                    break;
                default:
                    break;
            }

            if (has_handle)
                log.tracef("{0} ATT op={1,02x} handle={2,04x} {3}->{4} [ {5} ]",
                    dir_str, cast(ubyte)att.opcode, payload.ptr[0..2].littleEndianToNative!ushort, att.src, att.dst, cast(void[])payload);
            else
                log.tracef("{0} ATT op={1,02x} {2}->{3} [ {4} ]",
                    dir_str, cast(ubyte)att.opcode, att.src, att.dst, cast(void[])payload);
        }
    }
}


package:

struct GattCharacteristic
{
    ushort handle;
    GUID service_uuid;
    GUID char_uuid;
    GattCharProps properties;
}

struct BLESession
{
    MACAddress client;       // the internal endpoint that owns this connection
    MACAddress peer;         // the BLE device address
    BLEConn conn;            // driver connection handle
    GattCharacteristic[32] chars;
    ubyte num_chars;
    bool active;

    GattCharacteristic* find_char(ushort handle) nothrow @nogc
    {
        foreach (ref c; chars[0 .. num_chars])
        {
            if (c.handle == handle)
                return &c;
        }
        return null;
    }
}
