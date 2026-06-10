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
import urt.uuid;

import manager;
import manager.collection;

import router.iface;
import router.iface.priority_queue;

version = DebugBLEInterface;
version = SuppressAdvertisments;

nothrow @nogc:


// Advertising-channel PDU types (real link-layer values).
enum BLEAdvPDU : ubyte
{
    adv_ind         = 0x00,
    adv_direct_ind  = 0x01,
    adv_nonconn_ind = 0x02,
    scan_req        = 0x03,
    scan_rsp        = 0x04,
    connect_ind     = 0x05,
    adv_scan_ind    = 0x06,
    adv_ext_ind     = 0x07,
}

// Link-management events. These have no over-the-air encoding at any layer
// we can access (connection establishment is implicit in the LL); the
// vocabulary and semantics are modelled on the corresponding HCI events so
// a future raw-HCI backend maps 1:1.
enum BLEControl : ubyte
{
    connected       = 0x00,  // connection established (HCI: LE Connection Complete)
    connect_failed  = 0x01,  // connection attempt failed
    disconnect      = 0x02,  // request disconnect (HCI: Disconnect)
    disconnected    = 0x03,  // connection closed (HCI: Disconnection Complete)
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

enum BLEFrameKind : ubyte
{
    advert,   // advertising-channel PDU: code = BLEAdvPDU, payload = AD structures
    control,  // link management: code = BLEControl
    att,      // ATT: code mirrors payload[0] (ATTOpcode), payload = complete ATT PDU
}

struct BLEFrame
{
    enum Type = PacketType.ble;

    MACAddress src;           // originator
    MACAddress dst;           // destination
    BLEFrameKind kind;
    ubyte code;               // BLEAdvPDU / BLEControl / ATTOpcode by kind
    byte rssi;
    // 15 bytes used, 9 spare

    BLEAdvPDU adv_type() const pure nothrow @nogc
        => cast(BLEAdvPDU)code;
    BLEControl control() const pure nothrow @nogc
        => cast(BLEControl)code;

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!BLEFrame().src.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.ble) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!BLEFrame().dst.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.ble) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
        => (address & 0xFFFF_FFFF_FFFF) == 0xFFFF_FFFF_FFFF;

    // OW encapsulation wire codec: [src:6][dst:6][kind:1][code:1][rssi:1]
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        if (buffer.length < 15)
            return -1;
        ref const f = p.hdr!BLEFrame;
        buffer[0 .. 6] = f.src.b[];
        buffer[6 .. 12] = f.dst.b[];
        buffer[12] = f.kind;
        buffer[13] = f.code;
        buffer[14] = cast(ubyte)f.rssi;
        return 15;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        if (header.length < 15)
            return -1;
        p.type = PacketType.ble;
        ref f = p.hdr!BLEFrame;
        f.src = MACAddress(header[0 .. 6]);
        f.dst = MACAddress(header[6 .. 12]);
        f.kind = cast(BLEFrameKind)header[12];
        f.code = header[13];
        f.rssi = cast(byte)header[14];
        return 15;
    }
}
static assert(BLEFrame.sizeof <= 24);


enum uint ble_queue_timeout = 5000; // milliseconds

abstract class BLEInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("max-in-flight", max_in_flight));
nothrow @nogc:

    protected this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
        _mtu = 247; // BLE 5.x max ATT MTU (251 - 4 byte L2CAP header)
        _max_l2mtu = 251;
        _l2mtu = _max_l2mtu;

        mark_set!(typeof(this), "max-l2mtu")();
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

    final BLESession* find_session_by_peer(MACAddress peer)
    {
        foreach (s; _sessions[])
        {
            if (s.peer == peer)
                return s;
        }
        return null;
    }

    final BLESession* find_session_by_client(MACAddress client)
    {
        foreach (s; _sessions[])
        {
            if (s.client == client)
                return s;
        }
        return null;
    }

    final BLESession* find_session_by_transport(uint transport)
    {
        foreach (s; _sessions[])
        {
            if (s.transport == transport)
                return s;
        }
        return null;
    }

    // service the radio: drain backend events, reap dead sessions, pump the queue
    void service()
    {
        cleanup_dead_sessions();
        send_queued_messages();
    }

protected:

    override CompletionStatus startup()
    {
        _queue.init(_max_in_flight, 0, PCP.be, this);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
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

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();
        _queue.timeout_stale(getTime());
        send_queued_messages();
    }

    final override int transmit(ref Packet packet, MessageCallback callback = null)
    {
        if (packet.type != PacketType.ble)
        {
            add_tx_drop();
            return -1;
        }

        Packet p = packet;
        int tag = _queue.enqueue(p, &on_frame_complete);
        if (tag < 0)
        {
            add_tx_drop();
            return -1;
        }

        _pending[cast(ubyte)tag] = PendingMessage(callback, packet.hdr!BLEFrame,
            cast(ushort)packet.data.length, getTime());

        send_queued_messages();
        return tag;
    }

    override ushort pcap_type() const
        => 251; // DLT_BLUETOOTH_LE_LL

    // Backend hook: submit a dequeued frame to the transport. Return true if
    // the frame was accepted (completion signalled via _queue.complete), false
    // to fail the frame.
    abstract bool submit_frame(QueuedFrame* frame);

    // Backend hook: false when the backend can't accept further submissions
    // right now; dequeueing pauses until capacity frees up.
    bool submit_capacity()
        => true;

    // Backend hook: tear down the transport connection backing a session.
    void transport_close(BLESession* session)
    {
    }

    struct PendingMessage
    {
        MessageCallback callback;
        BLEFrame frame;
        ushort message_length;
        MonoTime send_time;
    }

    struct AdvEntry
    {
        MACAddress advertiser;
        MACAddress source;
    }

    ubyte _max_in_flight = 4;

    Array!(BLESession*) _sessions;

    PriorityPacketQueue _queue;
    Map!(ubyte, PendingMessage) _pending;

    enum max_adv_entries = 8;
    AdvEntry[max_adv_entries] _adv_table;
    ubyte _num_adv_entries;

    final MACAddress find_adv_source(MACAddress advertiser)
    {
        foreach (ref e; _adv_table[0 .. _num_adv_entries])
        {
            if (e.advertiser == advertiser)
                return e.source;
        }
        return MACAddress.init;
    }

    final void register_adv_source(MACAddress advertiser, MACAddress source)
    {
        foreach (ref e; _adv_table[0 .. _num_adv_entries])
        {
            if (e.advertiser == advertiser)
            {
                e.source = source;
                return;
            }
        }
        if (_num_adv_entries < max_adv_entries)
            _adv_table[_num_adv_entries++] = AdvEntry(advertiser, source);
    }

    // incoming packet handler - NAT rewriting and dispatch
    final void on_incoming(ref Packet p)
    {
        ref f = p.hdr!BLEFrame;

        final switch (f.kind)
        {
            case BLEFrameKind.advert:
                if (f.code == BLEAdvPDU.connect_ind)
                {
                    MACAddress server = find_adv_source(f.dst);
                    if (server)
                    {
                        f.dst = server;
                        log.info("incoming connection from ", f.src, " routed to ", server);
                    }
                    else
                        log.warning("incoming connection to unknown advertisement ", f.dst);
                }
                break;

            case BLEFrameKind.control:
                break;

            case BLEFrameKind.att:
                auto session = find_session_by_peer(f.src);
                if (session)
                    f.dst = session.client;
                break;
        }

        version (DebugBLEInterface)
            log_frame(f, cast(const(ubyte)[])p.data, PacketDirection.incoming);

        _status.rx_bytes += 14;
        dispatch(p);
    }

    // --- session lifecycle ---

    final BLESession* add_session(MACAddress client, MACAddress peer, uint transport)
    {
        auto session = defaultAllocator().allocT!BLESession;
        session.client = client;
        session.peer = peer;
        session.transport = transport;
        session.active = true;

        _sessions ~= session;
        return session;
    }

    final void cleanup_dead_sessions()
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

    final void destroy_session(BLESession* session)
    {
        transport_close(session);

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

    // --- submit pump ---

    final void send_queued_messages()
    {
        for (QueuedFrame* frame = _queue.dequeue(); frame !is null; frame = _queue.dequeue())
        {
            if (!submit_capacity())
                return;

            version (DebugBLEInterface)
                log_frame(frame.packet.hdr!BLEFrame, cast(const(ubyte)[])frame.packet.data, PacketDirection.outgoing);

            if (submit_frame(frame))
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

    final void on_frame_complete(int tag, MessageState state)
    {
        ubyte t = cast(ubyte)tag;
        if (auto pm = t in _pending)
        {
            if (state == MessageState.complete)
                add_tx_frame(pm.message_length + 14);
            else if (state != MessageState.in_flight)
                add_tx_drop();

            if (pm.callback)
                pm.callback(tag, state);
            _pending.remove(t);
        }
    }

    version (DebugBLEInterface)
    {
        final void log_frame(ref const BLEFrame f, const(ubyte)[] payload, PacketDirection dir)
        {
            const dir_str = dir == PacketDirection.incoming ? "<--" : "-->";

            final switch (f.kind)
            {
                case BLEFrameKind.advert:
                    switch (f.code)
                    {
                        case BLEAdvPDU.adv_ind:
                        case BLEAdvPDU.adv_nonconn_ind:
                        case BLEAdvPDU.adv_scan_ind:
                        case BLEAdvPDU.scan_rsp:
                            version (SuppressAdvertisments) {} else
                                log.trace(dir_str, " ADV ", f.adv_type, " ", f.src, " rssi=", f.rssi, " [ ", cast(void[])payload, " ]");
                            break;
                        case BLEAdvPDU.connect_ind:
                            log.trace(dir_str, " CONNECT_IND ", f.src, " -> ", f.dst);
                            break;
                        default:
                            log.trace(dir_str, " ADV ", f.adv_type, " ", f.src, " [ ", cast(void[])payload, " ]");
                            break;
                    }
                    break;

                case BLEFrameKind.control:
                    log.trace(dir_str, " CTRL ", f.control, " ", f.src, " -> ", f.dst);
                    break;

                case BLEFrameKind.att:
                    bool has_handle = false;
                    switch (f.code)
                    {
                        case ATTOpcode.read_req:
                        case ATTOpcode.write_req:
                        case ATTOpcode.write_cmd:
                        case ATTOpcode.notification:
                        case ATTOpcode.indication:
                            has_handle = payload.length >= 3;
                            break;
                        default:
                            break;
                    }

                    if (has_handle)
                        log.tracef("{0} ATT op={1,02x} handle={2,04x} {3}->{4} [ {5} ]",
                            dir_str, f.code, payload.ptr[1..3].littleEndianToNative!ushort, f.src, f.dst, cast(void[])payload);
                    else
                        log.tracef("{0} ATT op={1,02x} {2}->{3} [ {4} ]",
                            dir_str, f.code, f.src, f.dst, cast(void[])payload);
                    break;
            }
        }
    }
}


struct GattCharacteristic
{
    ushort handle;
    ushort cccd_handle;
    GUID service_uuid;
    GUID char_uuid;
    ushort properties;

    bool can_notify() const pure nothrow @nogc
        => (properties & 0x0030) != 0; // notify | indicate
}

struct BLESession
{
    MACAddress client;        // the internal endpoint that owns this connection
    MACAddress peer;          // the BLE device address
    uint transport = uint.max; // backend-private correlation tag (driver conn id, socket fd, ...)
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
