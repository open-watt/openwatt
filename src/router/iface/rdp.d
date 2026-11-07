module router.iface.rdp;

// Reliable message delivery between UDP endpoints of any address family: a selective-repeat ARQ with a
// 16-frame window, tuned for media of hundreds of kbit/s and frames of hundreds of bytes. An RDPEndpoint is
// a UDP endpoint carrying one session per peer; messages up to rdp_max_message are packed into datagrams,
// fragmented where they do not fit, and delivered whole in order. The lane is the message's PCP: a frame is
// cut highest lane first, so a small urgent message rides at the head of the next frame while a long one
// streams, a long message only yields to lanes above its own, and loss on one lane never holds up another.
//
// Frame: [type:3 seq:5][sack:1 more:1 rsvd:1 ack:5] ([sack bitmap:16 LE])? payload [check:8]
//   type 0 data, 1 ack-only, 2 open, 3 open-ack, 4 reset. ack is the cumulative point, bit n of the
//   bitmap acknowledges ack+2+n. open and open-ack carry [flags][nonce][max-message/8] and their seq is the
//   initial sequence; the first data frame follows it. more says the sender will send again before it
//   needs an ack, so the receiver holds its ack until a frame without it.
//   check is a CRC-8 over both nonces, the generations (sequence / 32) of seq and ack, and the frame, so a
//   frame held past a sequence cycle, or left over from an earlier session, is dropped. Handshake frames
//   check with zeros.
// Item: [0 lane:3 ext:1 len:3] ([len low:8])? [counter:8] bytes, or [1 lane:3 abort:1 rsvd:3] [counter:8] bytes
//   The first form opens a message of len bytes; a chunk short of len ends its frame and the lane's next
//   chunk, in the second form, continues it to the end of its own frame. The counter orders chunks
//   within a lane, so a lost frame stalls only the lanes it carried: frames past a hole wait in their
//   window slots and give up the items whose turn has come. Each lane assembles its own message, so a
//   higher lane's long message interrupts a lower one's, which resumes after it. abort discards the
//   partial message on its lane; it follows the aborted message's last chunk, and frames already sent
//   stay as sent.
//
// TODO: pause flag for flow control (a stream tunnel into a slow sink), rsvd bit 5 of byte 1
// TODO: authenticated sessions: a Noise handshake negotiated by the open flags, a keyed tag in the check slot
// TODO: congestion window, and delay-based shrink when a slow WAN uplink shows bufferbloat

import urt.array;
import urt.crc;
import urt.inet;
import urt.lifetime : move;
import urt.log;
import urt.mem;
import urt.rand : rand;
import urt.time;

import manager;

import router.iface;
import router.iface.endpoint;
import router.iface.ethernet : EthernetStation;

nothrow @nogc:


alias log = Log!"rdp";

enum ushort rdp_max_message = 1200;

enum RDPEvent : ubyte
{
    established,
    closed,
    writable,
}

alias RDPRecvHandler = void delegate(RDPEndpoint* ep, const(void)[] message, PCP lane, ref UDPReceiveInfo info) nothrow @nogc;
alias RDPEventHandler = void delegate(RDPEndpoint* ep, ref const InetAddress peer, RDPEvent event) nothrow @nogc;

// A remote holds one session open to that peer for the endpoint's life; without one, a session opens to
// any peer that sends an open or is sent a message, and closes when it fails.
RDPEndpoint* rdp_open(const(InetAddress)* local, const(InetAddress)* remote, RDPRecvHandler on_recv, RDPEventHandler on_event, EthernetStation iface = null, ubyte max_sessions = 16)
{
    RDPEndpoint* ep = rdp_create(on_recv, on_event, max_sessions);
    if (!ep)
        return null;
    ep._udp = udp_open(local, remote, &ep.on_datagram, iface);
    if (!ep._udp || (remote && !ep.connect(*remote)))
    {
        ep.close();
        return null;
    }
    return ep;
}


struct RDPEndpoint
{
nothrow @nogc:

    bool established(ref const InetAddress peer) const
    {
        const(RDPSession)* s = find(peer);
        return s && s._phase == RDPSession.Phase.established;
    }

    // bulk is refused at half the queue; the rest is kept for control frames, which are sent without asking
    ubyte tx_floor(ref const InetAddress peer) const
    {
        const(RDPSession)* s = find(peer);
        if (!s)
            return !_connected && (live_sessions() < _max_sessions || idlest()) ? 0 : tx_full;
        return s.queue_floor();
    }

    bool tx_ready(ref const InetAddress peer, PCP pcp = PCP.be) const
        => pcp_priority_map[pcp] >= tx_floor(peer);

    // a session heard from by nothing for this long, with nothing in flight, sends an empty frame its peer must
    // ack; zero never probes, and a dead or rebooted peer otherwise goes unnoticed while the session is idle
    Duration idle_probe = 15.seconds;

    // the handler sees closed; without notify the peer hears nothing and its handshake backoff paces it
    void close_session(ref const InetAddress peer, bool notify = true)
    {
        enter();
        if (RDPSession* s = find(peer))
            if (s._phase != RDPSession.Phase.closed)
                s.fail_session(now_time(), notify);
        leave();
    }

    ushort message_limit(ref const InetAddress peer) const
    {
        const(RDPSession)* s = find(peer);
        return s ? s.limit : rdp_max_message;
    }

    // takes the message; its PCP is the lane
    int send(Packet* message, InetAddress dst, MessageCallback callback = null)
    {
        enter();
        scope (exit) leave();
        RDPSession* s = _closing ? null : session_for(dst);
        if (!s || message.length > s.limit || s._queue.length >= max_queue)
        {
            packet_free(message);
            return -1;
        }
        Packet* kept = packet_keep(message);
        if (kept !is message)
            packet_free(message);
        if (!kept)
            return -1;
        s._active = now_time();
        ushort tag = next_tag();
        s._queue ~= RDPSession.TxItem(kept, callback, 0, tag, kept.pcp);
        ubyte floor = s.queue_floor();
        if (floor > s._floor)
            s._floor = floor;
        s.pump(now_time(), false, true);
        return tag;
    }

    void abort(int handle, MessageState reason = MessageState.aborted)
    {
        enter();
        foreach (s; _sessions[])
            if (s.abort(handle, reason))
                break;
        leave();
    }

    MessageState msg_state(int handle) const
    {
        foreach (s; _sessions[])
        {
            foreach (ref it; s._queue[])
                if (it.tag == handle)
                    return it.sent ? MessageState.in_flight : MessageState.queued;
            foreach (ref it; s._cut[])
                if (it.tag == handle)
                    return MessageState.in_flight;
        }
        return MessageState.complete;
    }

    // Safe to call from a handler; established peers are told with a reset.
    void close()
    {
        if (_closing)
            return;
        _closing = true;
        enter();
        foreach (s; _sessions[])
            if (s._phase == RDPSession.Phase.established)
                reset_peer(s._peer);
        leave();
    }

    version (unittest)
    {
        void delegate(RDPEndpoint*, const(ubyte)[], ref const InetAddress) nothrow @nogc _test_wire;
        bool _test_blocked;

        void test_deliver(const(void)[] data, ref UDPReceiveInfo info)
            => on_datagram(null, data, info);

        // the next pass, for tests without an Application
        void test_next_pass()
        {
            foreach (s; _sessions[])
                if (s._writable_due)
                    s.announce_writable(MonoTime());
        }
    }

private:
    UDPEndpoint* _udp;
    RDPRecvHandler _on_recv;
    RDPEventHandler _on_event;
    Array!(RDPSession*) _sessions;
    UDPReceiveInfo* _rx_info;
    ushort _next_tag;
    ubyte _max_sessions;
    ubyte _depth;
    ubyte _turns;
    bool _connected;
    bool _closing;
    bool _reclaim_due;

    version (unittest)
    {
        ushort _test_room;
        PCP _test_pcp;
    }

    bool connect(ref const InetAddress remote)
    {
        RDPSession* s = add(remote);
        if (!s)
            return false;
        _connected = true;
        s.start_open(now_time());
        return true;
    }

    void on_datagram(UDPEndpoint*, const(void)[] data, ref UDPReceiveInfo info)
    {
        const(ubyte)[] frame = cast(const(ubyte)[])data;
        if (frame.length < 3)
            return;
        ubyte type = frame[0] >> 5;
        enter();
        _rx_info = &info;
        RDPSession* s = find(info.source);
        if (!s && type == type_open && !_closing && frame.length == open_size && !(frame[1] & flag_sack) && frame[$ - 1] == check(frame[0 .. $ - 1], 0, 0, 0, 0))
            s = add(info.source);
        if (s)
            s.on_frame(frame, info.rx_time);
        else if (type == type_data)
            reset_peer(info.source);
        _rx_info = null;
        leave();
    }

    inout(RDPSession)* find(ref const InetAddress peer) inout
    {
        foreach (s; _sessions[])
            if (s._peer == peer)
                return s;
        return null;
    }

    RDPSession* session_for(ref const InetAddress peer)
    {
        if (RDPSession* s = find(peer))
        {
            if (s._phase == RDPSession.Phase.closed)
                s.start_open(now_time());
            return s;
        }
        if (_connected)
            return null;
        RDPSession* s = add(peer);
        if (s)
            s.start_open(now_time());
        return s;
    }

    // a full listener makes room by retiring its longest-idle session; it is swept when the handlers return
    RDPSession* add(ref const InetAddress peer)
    {
        if (live_sessions() >= _max_sessions)
        {
            RDPSession* idle = idlest();
            if (!idle)
                return null;
            idle.fail_session(now_time(), true);
            if (_closing || live_sessions() >= _max_sessions)
                return null;
        }
        RDPSession* s = alloc!RDPSession();
        if (!s)
            return null;
        s._ep = &this;
        s._peer = peer;
        s._waiter = TxWaiter(&s.on_egress);
        s._active = now_time();
        _sessions ~= s;
        return s;
    }

    size_t live_sessions() const
    {
        size_t n;
        foreach (s; _sessions[])
            n += s._phase != RDPSession.Phase.closed;
        return n;
    }

    // a connected endpoint retires none
    inout(RDPSession)* idlest() inout
    {
        if (_connected)
            return null;
        inout(RDPSession)* idle;
        foreach (s; _sessions[])
            if (s._phase != RDPSession.Phase.closed && s._queue.empty && s._cut.empty && !s.in_flight && (!idle || s._active < idle._active))
                idle = s;
        return idle;
    }

    ushort next_tag()
    {
        for (;;)
        {
            if (++_next_tag == 0)
                _next_tag = 1;
            if (msg_state(_next_tag) == MessageState.complete)
                return _next_tag;
        }
    }

    void transmit(const(ubyte)[] frame, ref const InetAddress peer, PCP pcp)
    {
        version (unittest)
        {
            if (_test_wire)
            {
                _test_pcp = pcp;
                return _test_wire(&this, frame, peer);
            }
        }
        _udp.sendto(frame, peer, pcp);
    }

    bool egress_ready(ref const InetAddress peer, PCP pcp)
    {
        version (unittest)
            if (_test_wire)
                return !_test_blocked;
        return _udp.tx_ready(peer, pcp);
    }

    void wait_egress(ref const InetAddress peer, ref TxWaiter waiter)
    {
        version (unittest)
            if (_test_wire)
                return;
        _udp.wait_tx(peer, waiter);
    }

    size_t frame_room(ref const InetAddress peer)
    {
        version (unittest)
            if (_test_room)
                return _test_room;
        return _udp.frame_room(peer);
    }

    void reset_peer(ref const InetAddress peer)
    {
        ubyte[3] frame = [type_reset << 5, 0, 0];
        frame[2] = check(frame[0 .. 2], 0, 0, 0, 0);
        transmit(frame[], peer, PCP.nc);
    }

    void event(ref const InetAddress peer, RDPEvent e)
    {
        if (_on_event)
            _on_event(&this, peer, e);
    }

    // handlers may close the endpoint or fail a session, so nothing is freed until the outermost entry leaves;
    // an egress turn's waiter is read by its interface after the turn returns, so freeing then waits a loop pass
    void enter()
    {
        ++_depth;
    }

    void leave()
    {
        if (--_depth)
            return;
        if (_turns && !_reclaim_due)
        {
            _reclaim_due = true;
            version (unittest)
                if (!g_app)
                    return;
            g_app.schedule(getTime(), &reclaim);
            return;
        }
        if (_turns)
            return;
        if (_closing)
            return destroy_now();
        for (size_t i = _sessions.length; i-- > 0; )
        {
            if (_sessions[i]._phase != RDPSession.Phase.closed)
                continue;
            free(_sessions[i]);
            _sessions.removeSwapLast(i);
        }
    }

    void reclaim(MonoTime)
    {
        _reclaim_due = false;
        enter();
        leave();
    }

    void destroy_now()
    {
        if (_reclaim_due && g_app)
            g_app.cancel(&reclaim);
        ++_depth;
        foreach (s; _sessions[])
        {
            s._phase = RDPSession.Phase.closed;
            s.teardown(MessageState.aborted);
        }
        foreach (s; _sessions[])
            free(s);
        _sessions.clear();
        if (_udp)
            _udp.close();
        free(&this);
    }
}


private:

enum window_max = 16;
// the window's last slots are kept for frames led by control traffic (PCP ca and above)
enum reserved_slots = 2;
enum lanes = 8;
enum ubyte no_lane = 0xFF;
enum max_queue = 32;
enum bulk_queue = max_queue / 2;
enum max_retries = 8;
enum ack_delay = 20.msecs;
enum uint initial_rto_us = 200_000;
enum uint rto_min_us = 20_000;
enum uint rto_max_us = 2_000_000;
enum uint clock_granularity_us = 1000;

enum ubyte type_data = 0;
enum ubyte type_ack = 1;
enum ubyte type_open = 2;
enum ubyte type_open_ack = 3;
enum ubyte type_reset = 4;
enum ubyte flag_sack = 0x80;
enum ubyte flag_more = 0x40;
enum ubyte item_continue = 0x80;
enum ubyte item_abort = 0x08;
enum ushort continuation = ushort.max;
enum lane_budget = 127;
// [type isn][0][0][nonce][max/8][check]
enum open_size = 6;
// a header, a selective ack, one item header, a byte and the check
enum min_frame = 4 + 3 + 1 + 1;

static immutable ubyte[lanes] scheduling_order = [7, 6, 5, 4, 3, 2, 0, 1];

RDPEndpoint* rdp_create(RDPRecvHandler on_recv, RDPEventHandler on_event, ubyte max_sessions)
{
    if (!on_recv || !max_sessions)
        return null;
    RDPEndpoint* ep = alloc!RDPEndpoint();
    if (!ep)
        return null;
    ep._on_recv = on_recv;
    ep._on_event = on_event;
    ep._max_sessions = max_sessions;
    return ep;
}

ubyte check(const(ubyte)[] frame, ubyte from, ubyte to, ushort seq, ushort ack) pure
{
    ubyte[4] prefix = [from, to, cast(ubyte)(seq >> 5), cast(ubyte)(ack >> 5)];
    return calculate_crc!(Algorithm.crc8_smbus)(frame, calculate_crc!(Algorithm.crc8_smbus)(prefix[]));
}

// a 5-bit field read as the nearest extended sequence at most hi ahead of base
ushort expand(ushort base, uint low, uint hi) pure
{
    uint d = (low - base) & 31;
    return cast(ushort)(base + (d > hi ? d - 32 : d));
}

version (unittest) __gshared MonoTime g_test_time;

MonoTime now_time()
{
    version (unittest)
        if (g_test_time != MonoTime.init)
            return g_test_time;
    return getTime();
}


// Sequences are extended to 16 bits on both ends from the initial sequence; the wire carries the low 5.
struct RDPSession
{
nothrow @nogc:

    enum Phase : ubyte
    {
        closed,
        opening,
        established,
    }

    struct TxItem
    {
        Packet* packet;
        MessageCallback callback;
        ushort sent;
        ushort tag;
        ubyte lane;
    }

    struct Pending
    {
        MessageCallback callback;
        ushort tag;
        ushort last_seq;
    }

    struct Frame
    {
        Packet* packet;
        MonoTime sent;
        ushort seq;
        ubyte retries;
        bool retransmitted;
        bool fast;
        PCP pcp;
        ubyte[lanes] chunks;
    }

    struct Item
    {
        size_t at;
        size_t take;
        size_t len;
        ubyte lane;
        ubyte counter;
        bool abort;
    }

    RDPEndpoint* _ep;
    InetAddress _peer = void;
    Array!TxItem _queue;
    Array!Pending _cut;
    Frame[window_max] _frames;
    Packet*[window_max] _held;
    Packet*[lanes] _rx_msg;
    TxWaiter _waiter;
    MonoTime _timer_when;
    MonoTime _ack_deadline;
    MonoTime _active;
    MonoTime _quiet_since;
    MonoTime _open_deadline;
    uint _srtt_us;
    uint _rttvar_us;
    uint _rto_us;
    ushort _tx_una;
    ushort _tx_next;
    ushort _rx_next;
    ushort _rx_mask;
    ushort _limit;
    ushort[lanes] _rx_fill;
    ubyte[lanes] _tx_lane;
    ubyte[lanes] _rx_lane;
    ubyte[lanes] _unacked;     // chunks in frames not yet cumulatively acked: bounds the receiver's counter lag
    ubyte _isn;
    ubyte _nonce;
    ubyte _peer_nonce;
    ubyte _peer_isn;
    ubyte _abort_lanes;
    ubyte _backoff;
    ubyte _open_tries;
    Phase _phase;
    bool _timer_armed;
    bool _ack_pending;
    bool _pumping;
    ubyte _floor;       // the highest floor not yet announced as fallen
    bool _starved;
    bool _turning;
    bool _writable_due;
    bool _receiving;

    ~this()
    {
        disarm();
        cancel_writable();
        _waiter.cancel();
    }

    ushort limit() const pure
        => _phase == Phase.established ? _limit : rdp_max_message;

    uint in_flight() const pure
        => cast(ushort)(_tx_next - _tx_una);

    void begin()
    {
        _nonce = cast(ubyte)rand();
        _isn = cast(ubyte)(rand() & 31);
        _tx_una = _tx_next = cast(ushort)(_isn + 1);
        _tx_lane[] = 0;
        _unacked[] = 0;
        _abort_lanes = 0;
        _srtt_us = 0;
        _rttvar_us = 0;
        _rto_us = initial_rto_us;
        _backoff = 0;
        _open_tries = 0;
        _phase = Phase.opening;
    }

    void start_open(MonoTime now)
    {
        begin();
        send_open(now);
        rearm(now);
    }

    // messages complete with reason; queue and window are swapped out first, as a callback may send again
    void teardown(MessageState reason)
    {
        disarm();
        cancel_writable();
        _waiter.cancel();
        _starved = false;
        acked_out();
        foreach (ref f; _frames)
        {
            packet_free(f.packet);
            f = Frame.init;
        }
        if (!_receiving)
            release_held();
        _rx_mask = 0;
        _floor = 0;
        Array!TxItem queue = _queue.move;
        Array!Pending cut = _cut.move;
        foreach (ref item; queue[])
            finish(item.packet, item.callback, item.tag, reason);
        foreach (ref item; cut[])
            finish(null, item.callback, item.tag, reason);
    }

    bool abort(int handle, MessageState reason)
    {
        foreach (i, ref it; _queue[])
        {
            if (it.tag != handle)
                continue;
            TxItem item = it;
            _queue.remove(i);
            if (item.sent)
                _abort_lanes |= 1 << item.lane;
            finish(item.packet, item.callback, item.tag, reason);
            pump(now_time());
            return true;
        }
        return false;
    }

    static size_t item_header_size(size_t len) pure
        => len < 8 ? 2 : 3;

    size_t write_item(ubyte[] buf, size_t pos, ubyte lane, size_t len)
    {
        if (len == continuation)
            buf[pos++] = cast(ubyte)(item_continue | lane << 4);
        else if (len < 8)
            buf[pos++] = cast(ubyte)(lane << 4 | len);
        else
        {
            buf[pos++] = cast(ubyte)(lane << 4 | 8 | len >> 8);
            buf[pos++] = cast(ubyte)len;
        }
        buf[pos++] = _tx_lane[lane]++;
        return pos;
    }

    bool lane_open(ubyte lane, ref const ubyte[lanes] chunks) const pure
        => _unacked[lane] + chunks[lane] < lane_budget;

    // the ack fields are rewritten on every send, so a retransmitted frame never carries a stale one
    size_t write_header(ubyte[] buf, ubyte type, ushort seq, bool more) const pure
    {
        buf[0] = cast(ubyte)(type << 5 | seq & 31);
        ubyte flags = cast(ubyte)((_rx_next - 1) & 31 | (more ? flag_more : 0));
        ushort sack = _rx_mask >> 1;
        if (!sack)
        {
            buf[1] = flags;
            return 2;
        }
        buf[1] = cast(ubyte)(flag_sack | flags);
        buf[2] = cast(ubyte)sack;
        buf[3] = cast(ubyte)(sack >> 8);
        return 4;
    }

    void refresh_header(ubyte[] buf)
    {
        bool more = window_open();
        buf[1] = cast(ubyte)((buf[1] & flag_sack) | (_rx_next - 1) & 31 | (more ? flag_more : 0));
        if (buf[1] & flag_sack)
        {
            ushort sack = _rx_mask >> 1;
            buf[2] = cast(ubyte)sack;
            buf[3] = cast(ubyte)(sack >> 8);
        }
    }

    // a writer's own send never hears writable inside it; the fall is announced on the next pass
    bool pump(MonoTime now, bool once = false, bool sending = false)
    {
        bool outer = !_pumping;
        _pumping = true;
        bool cut;
        while (!(cut && once) && cut_frame(now))
            cut = true;
        rearm(now);
        if (!outer)
            return cut;
        _pumping = false;
        ubyte floor = queue_floor();
        if (floor < _floor)
        {
            _floor = floor;
            if (sending)
            {
                if (!_writable_due)
                {
                    _writable_due = true;
                    if (g_app)
                        g_app.schedule(getTime(), &announce_writable);
                }
            }
            else
            {
                cancel_writable();
                _ep.event(_peer, RDPEvent.writable);
            }
        }
        return cut;
    }

    void announce_writable(MonoTime)
    {
        _writable_due = false;
        if (_phase != Phase.established)
            return;
        _ep.enter();
        _ep.event(_peer, RDPEvent.writable);
        _ep.leave();
    }

    void cancel_writable()
    {
        if (!_writable_due)
            return;
        _writable_due = false;
        if (g_app)
            g_app.cancel(&announce_writable);
    }

    // the egress's turn: one frame, or the ack it is owed when there is none to carry it
    bool on_egress(BaseInterface)
    {
        RDPEndpoint* ep = _ep;
        if (ep._closing)
            return false;
        ep.enter();
        ++ep._turns;
        scope (exit)
        {
            ep.leave();
            --ep._turns;
        }
        if (_phase != Phase.established)
            return false;
        MonoTime now = now_time();
        _turning = true;
        bool cut = pump(now, true);
        _turning = false;
        if (!cut && _ack_pending)
            send_ack(now);
        return !ep._closing && window_open();
    }

    ubyte queue_floor() const pure
        => _queue.length < bulk_queue ? 0 : _queue.length < max_queue ? pcp_priority_map[PCP.ca] : tx_full;

    bool window_open(uint cutting = 0) const pure
    {
        ubyte lane = top_lane();
        return lane != no_lane && in_flight + cutting < (pcp_priority_map[lane] >= pcp_priority_map[PCP.ca] ? window_max : window_max - reserved_slots);
    }

    ubyte top_lane() const pure
    {
        foreach (lane; scheduling_order)
            if (((_abort_lanes & 1 << lane) || head_index(lane) != size_t.max) && _unacked[lane] < lane_budget)
                return lane;
        return no_lane;
    }

    size_t head_index(ubyte lane) const pure
    {
        foreach (i, ref it; _queue[])
            if (it.lane == lane)
                return i;
        return size_t.max;
    }

    bool cut_frame(MonoTime now, bool probe = false)
    {
        if (_phase != Phase.established || !(probe || window_open()))
            return false;
        if (!_ep.egress_ready(_peer, probe ? PCP.nc : cast(PCP)top_lane()))
        {
            if (!_turning)
                _ep.wait_egress(_peer, _waiter);
            return false;
        }
        size_t room = _ep.frame_room(_peer);
        if (room < min_frame)
            return false;
        Packet* frame = alloc_packet!RawFrame(room);
        if (!frame)
        {
            _starved = true;
            return false;
        }
        ubyte[] buf = (cast(ubyte[])frame.payload)[0 .. room - 1];
        size_t start = write_header(buf, type_data, _tx_next, false);
        size_t pos = start;
        Frame f;

        // lanes in priority order give up an abort marker, then whole messages; the first message that does not fit
        // whole, new or under way, takes the rest of the frame, as a continuation runs to the frame's end
        next_lane: foreach (lane; scheduling_order)
        {
            if (_abort_lanes & 1 << lane)
            {
                if (!lane_open(lane, f.chunks) || pos + 2 > buf.length)
                    continue;
                buf[pos++] = cast(ubyte)(item_continue | item_abort | lane << 4);
                buf[pos++] = _tx_lane[lane]++;
                ++f.chunks[lane];
                _abort_lanes &= ~(1 << lane);
            }
            for (size_t i = head_index(lane); i != size_t.max && lane_open(lane, f.chunks); i = head_index(lane))
            {
                TxItem* it = &_queue[i];
                size_t remaining = it.packet.length - it.sent;
                size_t hdr = it.sent ? 2 : item_header_size(remaining);
                if (!it.sent && pos + hdr + remaining <= buf.length)
                {
                    pos = write_item(buf, pos, lane, remaining);
                    pos = cut_chunk(buf, pos, i, remaining, f, lane);
                    continue;
                }
                if (pos + hdr < buf.length)
                {
                    size_t take = buf.length - pos - hdr;
                    if (take > remaining)
                        take = remaining;
                    pos = write_item(buf, pos, lane, it.sent ? continuation : remaining);
                    pos = cut_chunk(buf, pos, i, take, f, lane);
                }
                break next_lane;
            }
        }

        if (pos == start && !probe)
        {
            packet_free(frame);
            return false;
        }

        if (!probe && window_open(1))
            buf[1] |= flag_more;
        frame.truncate(pos + 1);
        f.pcp = PCP.nc;
        foreach (lane; scheduling_order)
        {
            if (f.chunks[lane])
            {
                f.pcp = cast(PCP)lane;
                break;
            }
        }
        f.packet = frame;
        f.sent = now;
        f.seq = _tx_next;
        foreach (l, c; f.chunks)
            _unacked[l] += c;
        Frame* slot = &_frames[_tx_next & (window_max - 1)];
        *slot = f;
        ++_tx_next;
        acked_out();
        send_frame(slot);
        return true;
    }

    size_t cut_chunk(ubyte[] buf, size_t pos, size_t i, size_t take, ref Frame f, ubyte lane)
    {
        TxItem* it = &_queue[i];
        buf[pos .. pos + take] = cast(const(ubyte)[])it.packet.data[it.sent .. it.sent + take];
        it.sent += cast(ushort)take;
        ++f.chunks[lane];
        if (it.sent == it.packet.length)
        {
            _cut ~= Pending(it.callback, it.tag, _tx_next);
            packet_free(it.packet);
            _queue.remove(i);
        }
        return pos + take;
    }

    void send_frame(Frame* slot)
    {
        ubyte[] frame = cast(ubyte[])slot.packet.data;
        frame[$ - 1] = check(frame[0 .. $ - 1], _nonce, _peer_nonce, slot.seq, cast(ushort)(_rx_next - 1));
        _ep.transmit(frame, _peer, slot.pcp);
    }

    void resend(Frame* slot, MonoTime now)
    {
        slot.retransmitted = true;
        slot.sent = now;
        refresh_header(cast(ubyte[])slot.packet.data);
        send_frame(slot);
    }

    void send_control(ubyte type, MonoTime now)
    {
        ubyte[8] buf = void;
        size_t len;
        ubyte sum;
        if (type == type_ack)
        {
            len = write_header(buf, type_ack, 0, false);
            sum = check(buf[0 .. len], _nonce, _peer_nonce, 0, cast(ushort)(_rx_next - 1));
        }
        else
        {
            buf[0] = cast(ubyte)(type << 5 | _isn);
            buf[1] = 0;
            buf[2] = 0;
            buf[3] = _nonce;
            buf[4] = rdp_max_message / 8;
            len = 5;
            sum = check(buf[0 .. len], 0, 0, 0, 0);
        }
        buf[len] = sum;
        _ep.transmit(buf[0 .. len + 1], _peer, PCP.nc);
    }

    void send_open(MonoTime now)
    {
        send_control(type_open, now);
        uint wait = _rto_us << (_open_tries < 4 ? _open_tries : 4);
        if (wait > rto_max_us)
            wait = rto_max_us;
        ++_open_tries;
        _open_deadline = now + wait.usecs;
    }

    void acked_out()
    {
        _ack_pending = false;
        _ack_deadline = MonoTime.init;
    }

    void send_ack(MonoTime now)
    {
        send_control(type_ack, now);
        acked_out();
    }

    void finish(Packet* packet, MessageCallback callback, int tag, MessageState state)
    {
        packet_free(packet);
        if (callback)
            callback(tag, state);
    }

    void process_ack(ushort ack, ushort sack, MonoTime now)
    {
        uint fl = in_flight;
        if (!fl)
            return;
        uint acked = cast(ushort)(ack + 1 - _tx_una);
        MonoTime newest;
        bool clean;
        if (acked <= fl)
        {
            foreach (k; 0 .. acked)
            {
                ushort s = cast(ushort)(_tx_una + k);
                release_frame(s, newest, clean);
                complete_items(s);
                Frame* f = &_frames[s & (window_max - 1)];
                foreach (l, c; f.chunks)
                    _unacked[l] -= c;
                f.chunks[] = 0;
            }
            _tx_una = cast(ushort)(ack + 1);
            fl = in_flight;
        }

        ushort highest = _tx_una;
        foreach (n; 0 .. 16)
        {
            if (!(sack & (1 << n)))
                continue;
            ushort s = cast(ushort)(ack + 2 + n);
            if (cast(ushort)(s - _tx_una) < fl)
            {
                release_frame(s, newest, clean);
                highest = s;
            }
        }
        if (clean)
            rtt_sample(now - newest);
        foreach (k; 0 .. cast(ushort)(highest - _tx_una))
        {
            Frame* f = &_frames[(_tx_una + k) & (window_max - 1)];
            if (f.packet && !f.fast)
            {
                f.fast = true;
                resend(f, now);
            }
        }
        pump(now);
    }

    // the newest frame an ack releases is the sample least inflated by a repaired hole
    void release_frame(ushort seq, ref MonoTime newest, ref bool clean)
    {
        Frame* f = &_frames[seq & (window_max - 1)];
        if (!f.packet)
            return;
        if (f.sent > newest)
        {
            newest = f.sent;
            clean = !f.retransmitted;
        }
        packet_free(f.packet);
        f.packet = null;
    }

    void complete_items(ushort seq)
    {
        for (size_t i = 0; i < _cut.length;)
        {
            if (_cut[i].last_seq != seq)
            {
                ++i;
                continue;
            }
            Pending item = _cut[i];
            _cut.remove(i);
            finish(null, item.callback, item.tag, MessageState.complete);
        }
    }

    void rtt_sample(Duration rtt)
    {
        uint r = cast(uint)rtt.as!"usecs";
        if (!r)
            r = 1;
        if (!_srtt_us)
        {
            _srtt_us = r;
            _rttvar_us = r / 2;
        }
        else
        {
            uint diff = _srtt_us > r ? _srtt_us - r : r - _srtt_us;
            _rttvar_us = (3 * _rttvar_us + diff) / 4;
            _srtt_us = (7 * _srtt_us + r) / 8;
        }
        uint var = 4 * _rttvar_us;
        uint rto = _srtt_us + (var > clock_granularity_us ? var : clock_granularity_us);
        if (rto < rto_min_us)
            rto = rto_min_us;
        if (rto > rto_max_us)
            rto = rto_max_us;
        _rto_us = rto;
        _backoff = 0;
    }

    Duration effective_rto() const
    {
        uint rto = _rto_us << _backoff;
        return (rto > rto_max_us ? rto_max_us : rto).usecs;
    }

    Frame* oldest_frame()
    {
        foreach (k; 0 .. in_flight)
        {
            Frame* f = &_frames[(_tx_una + k) & (window_max - 1)];
            if (f.packet)
                return f;
        }
        return null;
    }

    void rearm(MonoTime now)
    {
        MonoTime next = _ack_deadline;
        if (_phase == Phase.opening && (next == MonoTime.init || _open_deadline < next))
            next = _open_deadline;
        if (Frame* f = oldest_frame())
        {
            MonoTime due = f.sent + effective_rto;
            if (next == MonoTime.init || due < next)
                next = due;
        }
        if (_starved && (next == MonoTime.init || now + ack_delay < next))
            next = now + ack_delay;
        if (probe_armed && (next == MonoTime.init || _quiet_since + _ep.idle_probe < next))
            next = _quiet_since + _ep.idle_probe;
        if (next == MonoTime.init)
            return disarm();
        if (_timer_armed && next == _timer_when)
            return;
        disarm();
        if (g_app)
            g_app.schedule(next, &on_timer);
        _timer_armed = true;
        _timer_when = next;
    }

    void disarm()
    {
        if (!_timer_armed)
            return;
        if (g_app)
            g_app.cancel(&on_timer);
        _timer_armed = false;
    }

    void on_timer(MonoTime)
    {
        _timer_armed = false;
        RDPEndpoint* ep = _ep;
        ep.enter();
        tick(now_time());
        ep.leave();
    }

    void tick(MonoTime now)
    {
        if (_phase == Phase.closed)
            return;
        if (_ack_deadline != MonoTime.init && now >= _ack_deadline)
            send_ack(now);
        if (_phase == Phase.opening && now >= _open_deadline)
        {
            if (!_ep._connected && _open_tries > max_retries)
                return fail_session(now, false);
            send_open(now);
        }
        if (Frame* f = oldest_frame())
        {
            if (now - f.sent >= effective_rto)
            {
                if (f.retries >= max_retries)
                {
                    log.warning(_peer, " unresponsive: no ack after ", max_retries, " retransmits");
                    return fail_session(now, true);
                }
                ++f.retries;
                resend(f, now);
                if (_backoff < 4)
                    ++_backoff;
            }
        }
        if (_starved)
        {
            _starved = false;
            pump(now);
        }
        if (probe_armed && now - _quiet_since >= _ep.idle_probe)
        {
            _quiet_since = now;
            cut_frame(now, true);
        }
        rearm(now);
    }

    // nothing in flight and nothing waiting to go, so the probe frame stays empty
    bool probe_armed() const
        => _phase == Phase.established && !in_flight && _queue.empty && !_abort_lanes && _ep.idle_probe > Duration.zero;

    void on_frame(const(ubyte)[] frame, MonoTime now)
    {
        _active = now;
        const(ubyte)[] body = frame[0 .. $ - 1];
        ubyte type = body[0] >> 5;
        if (type > type_reset)
            return;
        ushort sack;
        size_t pos = 2;
        if (body[1] & flag_sack)
        {
            if (body.length < 4)
                return;
            sack = cast(ushort)(body[2] | body[3] << 8);
            pos = 4;
        }

        if (type >= type_open)
        {
            if (frame[$ - 1] != check(body, 0, 0, 0, 0))
                return;
            if (type == type_reset)
            {
                if (_phase != Phase.closed)
                    fail_session(now, false);
            }
            else if (body.length >= pos + 3)
                on_open(body[0] & 31, body[pos + 1], cast(ushort)(body[pos + 2] * 8), type == type_open_ack, now);
            return;
        }

        if (_phase != Phase.established)
        {
            if (type == type_data)
                _ep.reset_peer(_peer);
            return;
        }
        ushort ack = expand(cast(ushort)(_tx_una - 1), body[1] & 31, window_max);
        ushort seq = type == type_data ? expand(_rx_next, body[0] & 31, window_max - 1) : 0;
        if (frame[$ - 1] != check(body, _peer_nonce, _nonce, seq, ack))
            return;
        _quiet_since = now;
        process_ack(ack, sack, now);
        if (type == type_data && _phase == Phase.established)
            on_data(seq, body, now);
    }

    void on_open(ubyte isn, ubyte nonce, ushort peer_max, bool is_ack, MonoTime now)
    {
        if (_phase == Phase.established)
        {
            if (nonce == _peer_nonce && isn == _peer_isn)
            {
                if (!is_ack)
                    send_control(type_open_ack, now);
                return;
            }
            if (is_ack)
                return;
            fail_session(now, false);
            if (_ep._closing)
                return;
        }
        if (_phase != Phase.opening)
        {
            if (is_ack)
                return;
            begin();
        }
        establish(isn, nonce, peer_max, now);
        // the established handler may have refused the session
        if (!is_ack && _phase == Phase.established && !_ep._closing)
            send_control(type_open_ack, now);
    }

    void establish(ubyte isn, ubyte nonce, ushort peer_max, MonoTime now)
    {
        _peer_nonce = nonce;
        _peer_isn = isn;
        _rx_next = cast(ushort)(isn + 1);
        _rx_mask = 0;
        _rx_lane[] = 0;
        release_held();
        acked_out();
        _limit = peer_max < rdp_max_message ? peer_max : rdp_max_message;
        _phase = Phase.established;
        _quiet_since = now;
        _ep.event(_peer, RDPEvent.established);
        if (_phase == Phase.established)
            pump(now);
    }

    // a held endpoint reopens at once; any other session is swept when the endpoint's handlers return
    void fail_session(MonoTime now, bool notify)
    {
        if (notify)
            _ep.reset_peer(_peer);
        _phase = Phase.closed;
        teardown(MessageState.failed);
        _ep.event(_peer, RDPEvent.closed);
        if (_ep._connected && _phase == Phase.closed && !_ep._closing)
            start_open(now);
    }

    // a handler may retire the session mid-delivery: what it reads stays until delivery unwinds, and the
    // retirement is the end, not a framing error
    void on_data(ushort seq, const(ubyte)[] body, MonoTime now)
    {
        _receiving = true;
        receive(seq, body, now);
        _receiving = false;
        if (_phase != Phase.established)
            release_held();
    }

    void receive(ushort seq, const(ubyte)[] body, MonoTime now)
    {
        uint d = cast(ushort)(seq - _rx_next);
        if (d >= window_max || (_rx_mask & (1 << d)))
            return request_ack(now, true);
        bool more = (body[1] & flag_more) != 0;
        if (d == 0)
        {
            // every earlier frame is consumed, so everything in this one is ready
            scan(body, now);
            if (_phase != Phase.established)
                return;
            if (!drained(body))
                return cast(void)protocol_error(now);
            _rx_mask >>= 1;
            ++_rx_next;
        }
        else
        {
            Packet* kept = alloc_packet!RawFrame(body);
            if (!kept)
                return;
            _held[seq & (window_max - 1)] = kept;
            _rx_mask |= cast(ushort)(1 << d);
        }
        drain_held(now, more);
        if (_phase == Phase.established)
            request_ack(now, _rx_mask != 0 || !more);
    }

    // held frames give up their ready items until none is left; the run the hole no longer blocks is freed
    void drain_held(MonoTime now, ref bool more)
    {
        for (bool progress = _rx_mask != 0; progress && _phase == Phase.established;)
        {
            progress = false;
            foreach (k; 0 .. window_max)
                if (_rx_mask & (1 << k))
                    progress |= scan(cast(const(ubyte)[])_held[(_rx_next + k) & (window_max - 1)].data, now);
        }
        while (_phase == Phase.established && (_rx_mask & 1))
        {
            Packet** slot = &_held[_rx_next & (window_max - 1)];
            const(ubyte)[] frame = cast(const(ubyte)[])(*slot).data;
            if (!drained(frame))
                return cast(void)protocol_error(now);
            more = (frame[1] & flag_more) != 0;
            packet_free(*slot);
            *slot = null;
            _rx_mask >>= 1;
            ++_rx_next;
        }
    }

    // 1 for an item, 0 at the end of the frame, -1 for a malformed one
    static int next_item(const(ubyte)[] frame, ref size_t pos, out Item it) pure
    {
        if (pos >= frame.length)
            return 0;
        ubyte b = frame[pos++];
        it.lane = (b >> 4) & 7;
        it.len = continuation;
        if (b & item_continue)
            it.abort = (b & item_abort) != 0;
        else
        {
            it.len = b & 7;
            if (b & 8)
            {
                if (pos >= frame.length)
                    return -1;
                it.len = it.len << 8 | frame[pos++];
            }
        }
        if (pos >= frame.length)
            return -1;
        it.counter = frame[pos++];
        it.at = pos;
        size_t room = frame.length - pos;
        it.take = it.abort ? 0 : it.len < room ? it.len : room;
        pos += it.take;
        return 1;
    }

    static size_t items_at(const(ubyte)[] frame) pure
        => (frame[1] & flag_sack) ? 4 : 2;

    bool scan(const(ubyte)[] frame, MonoTime now)
    {
        bool progress;
        size_t pos = items_at(frame);
        Item it;
        int r;
        while (_phase == Phase.established && (r = next_item(frame, pos, it)) > 0)
        {
            if (it.counter != _rx_lane[it.lane])
                continue;
            consume(it, frame[it.at .. it.at + it.take], now);
            progress = true;
        }
        if (r < 0)
            protocol_error(now);
        return progress;
    }

    bool drained(const(ubyte)[] frame) const
    {
        size_t pos = items_at(frame);
        Item it;
        while (next_item(frame, pos, it) > 0)
            if (cast(byte)(it.counter - _rx_lane[it.lane]) >= 0)
                return false;
        return true;
    }

    void consume(ref const Item it, const(ubyte)[] bytes, MonoTime now)
    {
        ubyte lane = it.lane;
        ++_rx_lane[lane];
        Packet* msg = _rx_msg[lane];
        if (it.abort)
            return drop_assembly(lane);
        if (it.len == continuation)
        {
            ushort fill = _rx_fill[lane];
            if (!msg || bytes.length > msg.length - fill)
                return cast(void)protocol_error(now);
            (cast(ubyte[])msg.data)[fill .. fill + bytes.length] = bytes[];
            _rx_fill[lane] = cast(ushort)(fill + bytes.length);
            if (_rx_fill[lane] < msg.length)
                return;
            _rx_msg[lane] = null;
            deliver(lane, cast(const(ubyte)[])msg.data);
            packet_free(msg);
            return;
        }
        if (it.len > _limit || msg)
            return cast(void)protocol_error(now);
        if (bytes.length == it.len)
            return deliver(lane, bytes);
        msg = alloc_packet!RawFrame(it.len);
        if (!msg)
        {
            log.warning(_peer, ": no memory to assemble a message; resetting session");
            return fail_session(now, true);
        }
        (cast(ubyte[])msg.data)[0 .. bytes.length] = bytes[];
        _rx_msg[lane] = msg;
        _rx_fill[lane] = cast(ushort)bytes.length;
    }

    void drop_assembly(ubyte lane)
    {
        packet_free(_rx_msg[lane]);
        _rx_msg[lane] = null;
    }

    bool protocol_error(MonoTime now)
    {
        log.warning(_peer, " violated the message framing; resetting session");
        fail_session(now, true);
        return false;
    }

    void request_ack(MonoTime now, bool immediate)
    {
        _ack_pending = true;
        pump(now);
        if (!_ack_pending)
            return;
        if (immediate)
            return send_ack(now);
        if (_ack_deadline == MonoTime.init)
        {
            _ack_deadline = now + ack_delay;
            rearm(now);
        }
    }

    void deliver(ubyte lane, const(ubyte)[] bytes)
    {
        if (!_ep._closing)
            _ep._on_recv(_ep, bytes, cast(PCP)lane, *_ep._rx_info);
    }

    void release_held()
    {
        foreach (ref h; _held)
        {
            packet_free(h);
            h = null;
        }
        foreach (ubyte lane; 0 .. lanes)
            drop_assembly(lane);
    }
}


unittest
{
    import urt.mem.page : page_free_generation;

    struct Wire
    {
    nothrow @nogc:
        struct Datagram
        {
            Array!ubyte bytes;
            InetAddress from;
        }

        RDPEndpoint* a;
        RDPEndpoint* b;
        InetAddress addr_a;
        InetAddress addr_b;
        Array!Datagram to_a;
        Array!Datagram to_b;
        uint seed = 7;
        uint dropped;
        uint probes;
        ubyte loss_percent;

        void carry(RDPEndpoint*, const(ubyte)[] frame, ref const InetAddress peer)
        {
            if (frame[0] >> 5 == type_data && frame.length == RDPSession.items_at(frame) + 1)
                ++probes;
            seed = seed * 1103515245 + 12345;
            if (loss_percent && (seed >> 16) % 100 < loss_percent)
            {
                ++dropped;
                return;
            }
            bool forward = peer == addr_b;
            Datagram d;
            d.bytes ~= frame;
            d.from = forward ? addr_a : addr_b;
            (forward ? to_b : to_a) ~= d.move;
        }

        void deliver(ref Datagram d, RDPEndpoint* to)
        {
            UDPReceiveInfo info;
            info.source = d.from;
            info.rx_time = g_test_time;
            to.on_datagram(null, d.bytes[], info);
        }

        // one direction only, so the replies wait
        void flush(RDPEndpoint* to)
        {
            Array!Datagram* q = to is b ? &to_b : &to_a;
            while (!q.empty)
            {
                Datagram d = q.pop_front();
                deliver(d, to);
            }
        }

        void pump()
        {
            while (!to_a.empty || !to_b.empty)
            {
                flush(b);
                flush(a);
            }
        }

        void tick(uint steps = 4, Duration step = 25.msecs)
        {
            foreach (_; 0 .. steps)
            {
                pump();
                g_test_time = g_test_time + step;
                foreach (s; a._sessions[])
                    s.on_timer(g_test_time);
                foreach (s; b._sessions[])
                    s.on_timer(g_test_time);
            }
        }

        void clear()
        {
            to_a.clear();
            to_b.clear();
        }
    }

    struct Sink
    {
        uint count;
        uint bad;
        ubyte[lanes] next;
        Array!ushort order;
        bool close_on_message;
        bool held_kept;
        uint freed_at_close;

        void on_message(RDPEndpoint* ep, const(void)[] message, PCP lane, ref UDPReceiveInfo info) nothrow @nogc
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])message;
            ++count;
            if (bytes.length < 3 || bytes[0] != next[lane]++ || (bytes[1] | bytes[2] << 8) != bytes.length)
                ++bad;
            foreach (i, b; bytes[3 .. $])
                if (b != cast(ubyte)(bytes[0] * 7 + i))
                    ++bad;
            order ~= cast(ushort)(lane << 8 | bytes[0]);
            if (!close_on_message)
                return;
            ep.close_session(info.source);
            if (RDPSession* s = ep.find(info.source))
                foreach (h; s._held)
                    held_kept |= h !is null;
            freed_at_close = page_free_generation();
        }
    }

    struct Events
    {
        uint established;
        uint closed;
        uint writable;
        bool close_on_writable;
        bool refuse;

        void on_event(RDPEndpoint* ep, ref const InetAddress peer, RDPEvent e) nothrow @nogc
        {
            final switch (e)
            {
                case RDPEvent.established: ++established; break;
                case RDPEvent.closed:      ++closed;      break;
                case RDPEvent.writable:    ++writable;    break;
            }
            if (e == RDPEvent.writable && close_on_writable)
                ep.close();
            if (e == RDPEvent.established && refuse)
                ep.close_session(peer, false);
        }
    }

    struct Completions
    {
        uint complete;
        uint other;
        void done(int, MessageState state) nothrow @nogc
        {
            if (state == MessageState.complete)
                ++complete;
            else
                ++other;
        }
    }

    static Packet* make_message(ubyte seq, ushort len, PCP pcp)
    {
        Packet* p = alloc_packet!RawFrame(len);
        ubyte[] b = cast(ubyte[])p.payload;
        b[0] = seq;
        b[1] = cast(ubyte)len;
        b[2] = cast(ubyte)(len >> 8);
        foreach (i, ref v; b[3 .. $])
            v = cast(ubyte)(seq * 7 + i);
        p.pcp = pcp;
        return p;
    }

    // 80-byte datagrams: a message of rdp_max_message overruns the 16-frame window
    static RDPEndpoint* make_endpoint(ref Wire wire, ref Sink sink, ref Events events, const(InetAddress)* remote)
    {
        RDPEndpoint* ep = rdp_create(&sink.on_message, &events.on_event, 4);
        ep._test_wire = &wire.carry;
        ep._test_room = 80;
        if (remote)
            assert(ep.connect(*remote));
        return ep;
    }

    static immutable ubyte[6] mac_a = [0x02, 0, 0, 0, 0, 0x0A];
    static immutable ubyte[6] mac_b = [0x02, 0, 0, 0, 0, 0x0B];

    g_test_time = MonoTime(1_000_000_000);
    scope(exit) g_test_time = MonoTime.init;

    Wire wire;
    wire.addr_a = InetAddress(mac_a, 4000);
    wire.addr_b = InetAddress(mac_b, 4000);
    Sink sink, sink_a;
    Events ev_a, ev_b;
    // b listens; a holds a session to b
    wire.b = make_endpoint(wire, sink, ev_b, null);
    wire.a = make_endpoint(wire, sink_a, ev_a, &wire.addr_b);
    RDPEndpoint* a = wire.a;
    RDPEndpoint* b = wire.b;
    scope(exit)
    {
        wire.a.close();
        wire.b.close();
        wire.clear();
    }
    wire.pump();
    assert(a.established(wire.addr_b) && b.established(wire.addr_a));
    assert(ev_a.established == 1 && ev_b.established == 1);
    RDPSession* sa = a._sessions[0];
    RDPSession* sb = b._sessions[0];
    assert(sa._limit == rdp_max_message && sb._limit == rdp_max_message);

    Completions done;
    ubyte[lanes] seqs;

    // bulk stops short of the window's reserved slots, so a small urgent message queued behind it is sent at once
    assert(a.send(make_message(seqs[PCP.be]++, rdp_max_message, PCP.be), wire.addr_b, &done.done) > 0);
    assert(sa.in_flight == window_max - reserved_slots && sa._queue.length == 1);
    assert(a.send(make_message(seqs[PCP.be]++, 300, PCP.be), wire.addr_b, &done.done) > 0);
    assert(sa.in_flight == window_max - reserved_slots);
    assert(a.send(make_message(seqs[PCP.nc]++, 12, PCP.nc), wire.addr_b, &done.done) > 0);
    assert(sa.in_flight == window_max - reserved_slots + 1);
    wire.tick(1);
    assert(sink.count == 3 && sink.bad == 0);
    assert(sink.order[0] == (PCP.nc << 8 | 0) && sink.order[1] == (PCP.be << 8 | 0) && sink.order[2] == (PCP.be << 8 | 1));
    wire.tick(2);
    assert(done.complete == 3 && done.other == 0);
    assert(sa.in_flight == 0 && sa._cut.empty && sa._queue.empty && sb._rx_mask == 0 && sb._rx_msg == (Packet*[lanes]).init);

    // a long message does not yield to lanes below it
    assert(a.send(make_message(seqs[PCP.vo]++, rdp_max_message, PCP.vo), wire.addr_b, &done.done) > 0);
    foreach (_; 0 .. 3)
        assert(a.send(make_message(seqs[PCP.ca]++, 20, PCP.ca), wire.addr_b, &done.done) > 0);
    wire.tick(4);
    assert(sink.count == 7 && sink.bad == 0 && sink.order[3] == (PCP.vo << 8 | 0));
    assert(done.complete == 7);

    // an aborted message stops at the next frame and the lane carries on
    assert(a.send(make_message(seqs[PCP.be]++, rdp_max_message, PCP.be), wire.addr_b, &done.done) > 0);
    int big = a.send(make_message(seqs[PCP.be], rdp_max_message, PCP.be), wire.addr_b, &done.done);
    wire.flush(b);
    wire.flush(a);
    assert(big > 0 && a.msg_state(big) == MessageState.in_flight && sa._queue[sa.head_index(PCP.be)].sent > 0);
    a.abort(big);
    assert(sa.head_index(PCP.be) == size_t.max && done.other == 1);
    assert(a.send(make_message(seqs[PCP.be]++, 12, PCP.be), wire.addr_b, &done.done) > 0);
    wire.tick(4);
    assert(sink.count == 9 && sink.bad == 0 && sb._rx_msg == (Packet*[lanes]).init);
    assert(done.complete == 9 && done.other == 1 && sa.in_flight == 0);

    // sustained traffic across three lanes with 20% loss each way
    wire.loss_percent = 20;
    static immutable PCP[3] pcps = [PCP.be, PCP.ca, PCP.vo];
    enum total = 90;
    uint submitted;
    uint steps;
    while ((sink.count < total + 9 || done.complete < total + 9) && steps < 20_000)
    {
        while (submitted < total && a.tx_ready(wire.addr_b))
        {
            PCP pcp = pcps[submitted % 3];
            ushort len = cast(ushort)(3 + (submitted * 37) % 230);
            assert(a.send(make_message(seqs[pcp]++, len, pcp), wire.addr_b, &done.done) > 0);
            ++submitted;
        }
        wire.tick(1, 5.msecs);
        ++steps;
    }
    assert(sink.count == total + 9 && sink.bad == 0);
    assert(done.complete == total + 9 && done.other == 1);
    assert(wire.dropped > 0);
    assert(sa.in_flight == 0 && sb._rx_mask == 0 && sb._rx_msg == (Packet*[lanes]).init && sa._srtt_us > 0);
    wire.loss_percent = 0;

    // a full queue reports writable once it drains
    uint writable = ev_a.writable;
    while (a.tx_ready(wire.addr_b))
        assert(a.send(make_message(seqs[PCP.ca]++, 200, PCP.ca), wire.addr_b) > 0);
    assert(sa._floor && ev_a.writable == writable && sa._queue.length == bulk_queue);
    // control still finds room past the bulk floor, as a frame sent without asking does
    assert(!a.tx_ready(wire.addr_b) && a.tx_ready(wire.addr_b, PCP.ca));
    assert(a.send(make_message(seqs[PCP.be]++, 20, PCP.be), wire.addr_b) > 0);
    wire.tick(8);
    assert(ev_a.writable == writable + 1 && sa._queue.empty && sink.bad == 0);

    // a queue full to the last slot announces each class it admits again
    a._test_blocked = true;
    while (a.tx_ready(wire.addr_b, PCP.ca))
        assert(a.send(make_message(seqs[PCP.ca]++, 20, PCP.ca), wire.addr_b) > 0);
    assert(sa._queue.length == max_queue && !a.tx_ready(wire.addr_b, PCP.nc));
    a._test_blocked = false;
    sa._waiter.handler(null);
    assert(ev_a.writable == writable + 2 && a.tx_ready(wire.addr_b, PCP.ca) && !a.tx_ready(wire.addr_b));
    wire.tick(8);
    assert(ev_a.writable == writable + 3 && sa._queue.empty && sink.bad == 0);

    // a send from a completion callback does not hide a reopening that no pump has announced yet
    static struct Chain
    {
        RDPEndpoint* ep;
        InetAddress dst;
        int second;
        ubyte* seq;
        Packet* function(ubyte, ushort, PCP) nothrow @nogc make;

        void first(int, MessageState state) nothrow @nogc
        {
            if (state != MessageState.aborted || !second)
                return;
            int h = second;
            second = 0;
            ep.abort(h);
        }

        void last(int, MessageState state) nothrow @nogc
        {
            if (state == MessageState.aborted)
                assert(ep.send(make((*seq)++, 20, PCP.ca), dst) > 0);
        }
    }
    Chain chain = Chain(a, wire.addr_b, 0, &seqs[PCP.ca], &make_message);
    a._test_blocked = true;
    int head = a.send(make_message(0, 20, PCP.ee), wire.addr_b, &chain.first);
    chain.second = a.send(make_message(0, 20, PCP.ee), wire.addr_b, &chain.last);
    assert(head > 0 && chain.second > 0);
    while (a.tx_ready(wire.addr_b, PCP.ca))
        assert(a.send(make_message(seqs[PCP.ca]++, 20, PCP.ca), wire.addr_b) > 0);
    assert(sa._queue.length == max_queue);
    a.abort(head);
    a.test_next_pass();
    assert(sa._queue.length == max_queue - 1 && ev_a.writable > writable && !sa._writable_due, "the room the chain left is announced");
    a._test_blocked = false;
    sa.pump(g_test_time);
    wire.tick(8);
    assert(sa._queue.empty && sink.bad == 0);
    uint base = sink.count;

    // frames past a hole wait in their slots and are delivered in order when it fills
    assert(a.send(make_message(seqs[PCP.ca]++, 80, PCP.ca), wire.addr_b, &done.done) > 0);
    Wire.Datagram hole = wire.to_b.pop_front();
    foreach (_; 0 .. 4)
        assert(a.send(make_message(seqs[PCP.ca]++, 80, PCP.ca), wire.addr_b, &done.done) > 0);
    wire.flush(b);
    assert(sink.count == base && sb._rx_mask != 0);
    wire.deliver(hole, b);
    assert(sink.count == base + 5 && sink.bad == 0 && sb._rx_mask == 0);
    wire.tick();

    // a retransmitted frame acknowledges what its sender holds now, not what it held when first sent
    assert(a.send(make_message(seqs[PCP.ca]++, 30, PCP.ca), wire.addr_b, &done.done) > 0);
    Wire.Datagram stale = wire.to_b.pop_front();
    foreach (i; 0 .. 3)
        assert(b.send(make_message(cast(ubyte)i, 30, PCP.ca), wire.addr_a) > 0);
    wire.flush(a);
    wire.flush(b);
    g_test_time = g_test_time + 3.seconds;
    sa.on_timer(g_test_time);
    assert(wire.to_b.length == 1 && (wire.to_b[0].bytes[1] & 31) == ((sa._rx_next - 1) & 31));
    wire.tick();
    assert(sink.count == base + 6 && sink.bad == 0 && sink_a.count == 3 && done.other == 1);

    // aborting a message under loss leaves the earlier message on its lane, and the session, intact
    assert(a.send(make_message(seqs[PCP.be]++, 300, PCP.be), wire.addr_b, &done.done) > 0);
    Wire.Datagram lost_head = wire.to_b.pop_front();
    wire.flush(b);
    assert(sb._rx_mask != 0 && sa._queue.empty);
    int doomed = a.send(make_message(seqs[PCP.be], rdp_max_message, PCP.be), wire.addr_b, &done.done);
    assert(doomed > 0 && sa._queue[sa.head_index(PCP.be)].sent > 0);
    a.abort(doomed);
    assert(a.send(make_message(seqs[PCP.nc]++, 12, PCP.nc), wire.addr_b, &done.done) > 0);
    wire.tick(8);
    wire.deliver(lost_head, b);
    wire.tick();
    assert(a.established(wire.addr_b) && sink.bad == 0 && sb._rx_msg == (Packet*[lanes]).init);
    assert(sink.count == base + 8 && done.other == 2 && sa.in_flight == 0);

    // a hole on one lane does not hold up another
    assert(a.send(make_message(seqs[PCP.be]++, 80, PCP.be), wire.addr_b, &done.done) > 0);
    Wire.Datagram lost = wire.to_b.pop_front();
    assert(a.send(make_message(seqs[PCP.nc]++, 30, PCP.nc), wire.addr_b, &done.done) > 0);
    wire.flush(b);
    assert(sink.count == base + 9 && sink.order[$ - 1] >> 8 == PCP.nc && sb._rx_mask != 0);
    wire.deliver(lost, b);
    assert(sink.count == base + 10 && sink.bad == 0 && sb._rx_mask == 0);
    wire.tick();

    // under a steady stream every frame is cut dense; the lane's counter budget still bounds the window
    uint tiny;
    Wire.Datagram gap;
    foreach (n; 0 .. 48)
    {
        while (tiny < 1000 && a.tx_ready(wire.addr_b))
        {
            assert(a.send(make_message(seqs[PCP.bk]++, 3, PCP.bk), wire.addr_b, &done.done) > 0);
            ++tiny;
        }
        Wire.Datagram d = wire.to_b.pop_front();
        if (n == 40)
            gap = d.move;
        else
            wire.deliver(d, b);
        g_test_time = g_test_time + 25.msecs;
        sb.on_timer(g_test_time);
        wire.flush(a);
    }
    assert(sa._unacked[PCP.bk] == lane_budget);
    wire.deliver(gap, b);
    wire.tick(8);
    assert(sink.count == base + 10 + tiny && sink.bad == 0 && done.other == 2 && sa.in_flight == 0);

    // a frame held past a full sequence cycle fails its check, and the fresh frame with its number is taken
    assert(a.send(make_message(seqs[PCP.ca]++, 30, PCP.ca), wire.addr_b, &done.done) > 0);
    Wire.Datagram straggler = wire.to_b.pop_front();
    g_test_time = g_test_time + 3.seconds;
    sa.on_timer(g_test_time);
    wire.tick();
    foreach (_; 0 .. 31)
    {
        assert(a.send(make_message(seqs[PCP.ca]++, 30, PCP.ca), wire.addr_b, &done.done) > 0);
        wire.tick(1);
    }
    uint before = sink.count;
    assert(a.send(make_message(seqs[PCP.ca]++, 30, PCP.ca), wire.addr_b, &done.done) > 0);
    Wire.Datagram fresh = wire.to_b.pop_front();
    assert(fresh.bytes[0] == straggler.bytes[0]);
    wire.deliver(straggler, b);
    assert(sink.count == before && a.established(wire.addr_b));
    wire.deliver(fresh, b);
    wire.tick();
    assert(sink.count == before + 1 && sink.bad == 0 && done.other == 2);

    // under loss, a long urgent message interrupts a long bulk one, which resumes whole after it
    uint interrupted = sink.count;
    uint completed = done.complete;
    wire.loss_percent = 20;
    assert(a.send(make_message(seqs[PCP.bk]++, rdp_max_message, PCP.bk), wire.addr_b, &done.done) > 0);
    assert(sa._queue[sa.head_index(PCP.bk)].sent > 0);
    assert(a.send(make_message(seqs[PCP.vo]++, rdp_max_message, PCP.vo), wire.addr_b, &done.done) > 0);
    for (uint turns; (sink.count < interrupted + 2 || sa.in_flight) && turns < 20_000; ++turns)
        wire.tick(1, 5.msecs);
    wire.loss_percent = 0;
    assert(sink.count == interrupted + 2 && sink.bad == 0 && sb._rx_msg == (Packet*[lanes]).init);
    assert(sink.order[interrupted] == (PCP.vo << 8 | (seqs[PCP.vo] - 1)) && sink.order[interrupted + 1] == (PCP.bk << 8 | (seqs[PCP.bk] - 1)));
    assert(done.complete == completed + 2 && done.other == 2);

    // an idle session probes its peer: a busy one never does, a vanished peer fails it, and a rebooted one resets it
    {
        Wire w;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.a.idle_probe = 1.seconds;
        w.b.idle_probe = Duration.zero;
        w.pump();
        assert(w.a.established(w.addr_b));

        ubyte n;
        foreach (_; 0 .. 20)
        {
            assert(w.a.send(make_message(n++, 20, PCP.be), w.addr_b) > 0);
            w.tick(2, 200.msecs);
        }
        assert(w.probes == 0 && sk.count == 20, "a session in use never probes");

        w.tick(16, 250.msecs);
        assert(w.probes != 0 && w.a.established(w.addr_b) && ex.closed == 0, "an idle one probes, and the ack keeps it");

        Sink sk2;
        Events ey2;
        w.b.close();
        w.clear();
        w.b = make_endpoint(w, sk2, ey2, null);
        w.b.idle_probe = Duration.zero;
        w.tick(8, 250.msecs);
        assert(ex.closed == 1, "a rebooted peer answers the probe with a reset");
        w.tick(8, 250.msecs);
        assert(w.a.established(w.addr_b), "and the held session reopens to it");

        RDPSession* probing = w.a.find(w.addr_b);
        w.a._test_blocked = true;
        assert(w.a.send(make_message(n++, 20, PCP.be), w.addr_b) > 0);
        assert(!probing.probe_armed, "a queued message is not swept into a probe");
        w.a._test_blocked = false;
        probing.pump(g_test_time);
        w.tick(8, 250.msecs);
        assert(probing._queue.empty);

        uint probes = w.probes;
        UDPReceiveInfo forged;
        forged.source = w.addr_b;
        foreach (_; 0 .. 12)
        {
            // a well-formed ack for the live session, its check flipped
            ushort acked = cast(ushort)(probing._tx_una - 1);
            ubyte[3] junk = [type_ack << 5, cast(ubyte)(acked & 31), 0];
            junk[2] = cast(ubyte)(check(junk[0 .. 2], probing._peer_nonce, probing._nonce, 0, acked) ^ 1);
            forged.rx_time = g_test_time;
            w.a.on_datagram(null, junk[], forged);
            w.tick(1, 250.msecs);
        }
        assert(w.probes > probes, "frames that fail the session's check do not count as hearing the peer");

        w.loss_percent = 100;
        w.tick(200, 250.msecs);
        assert(ex.closed == 2, "a vanished peer fails the session once the probe's retries run out");
        w.a.close();
        w.b.close();
    }

    // a listener that refuses a session in its established handler sends no ack and no reset; the opener retries
    {
        Wire w;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        ey.refuse = true;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.flush(w.b);
        assert(ey.established == 1 && ey.closed == 1 && w.to_a.empty, "refused without a word");
        assert(!w.a.established(w.addr_b) && ex.closed == 0);
        ey.refuse = false;
        w.tick(40, 100.msecs);
        assert(w.a.established(w.addr_b) && w.b.established(w.addr_a), "the opener's retry is taken once accepted");
        w.a.close();
        w.b.close();
    }

    // a handler that retires the session while a message is delivered, in order or from a held frame, ends it once
    foreach (held; 0 .. 2)
    {
        Wire w;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.pump();
        assert(w.a.established(w.addr_b) && w.b.established(w.addr_a));
        sk.close_on_message = true;
        w.a._test_room = min_frame + 20;
        // be goes out at once; vo follows in the second datagram, and its own lane makes it ready while the first is missing
        assert(w.a.send(make_message(0, 20, PCP.be), w.addr_b) > 0);
        assert(w.a.send(make_message(0, 20, PCP.vo), w.addr_b) > 0);
        assert(w.to_b.length >= 2);
        w.to_a.clear();
        Wire.Datagram first = w.to_b[0].move;
        Wire.Datagram second = w.to_b[1].move;
        w.to_b.clear();
        w.deliver(held ? second : first, w.b);
        assert(sk.count == 1 && sk.bad == 0 && ey.closed == 1 && !w.b.established(w.addr_a), "retired once, the rest dropped");
        size_t resets;
        foreach (ref d; w.to_a[])
            if (d.bytes.length && d.bytes[0] >> 5 == type_reset)
                ++resets;
        assert(resets == 1, "the delivery that retired the session raised one reset, no framing error after it");
        if (held)
            assert(sk.held_kept && page_free_generation() != sk.freed_at_close, "the held page outlives the callback, and goes when delivery unwinds");
        w.a.close();
        w.b.close();
    }

    // a malformed open from a stranger cannot claim a full listener's slot
    {
        Wire w;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.pump();
        static immutable ubyte[6] mac_d = [0x02, 0, 0, 0, 0, 0x0D];
        foreach (ubyte i; 1 .. 4)
            w.b.add(InetAddress(mac_d, cast(ushort)(7000 + i))).start_open(g_test_time);
        w.clear();
        UDPReceiveInfo info;
        info.source = InetAddress(mac_d, 7100);
        info.rx_time = g_test_time;
        ubyte[3] runt = [type_open << 5, 0, 0];
        w.b.on_datagram(null, runt[], info);
        ubyte[open_size] sacked = [type_open << 5, flag_sack, 0, 0x55, rdp_max_message / 8, 0];
        sacked[$ - 1] = check(sacked[0 .. $ - 1], 0, 0, 0, 0);
        w.b.on_datagram(null, sacked[], info);
        assert(w.b.live_sessions() == 4 && !w.b.find(info.source) && w.b.established(w.addr_a));
        w.a.close();
        w.b.close();
        w.clear();
    }

    // a lane held by its counter budget does not lend its window slots to the bulk lane below it
    sa._unacked[PCP.vo] = lane_budget;
    assert(a.send(make_message(seqs[PCP.vo]++, 30, PCP.vo), wire.addr_b) > 0);
    assert(sa.top_lane() == no_lane && !sa.window_open());
    sa._unacked[PCP.vo] = 0;
    assert(sa.pump(g_test_time));
    wire.tick();

    // closing from inside an egress turn keeps the session, and its waiter, until the turn has returned
    {
        Wire w;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.pump();
        RDPSession* s = w.a._sessions[0];
        w.a._test_blocked = true;
        while (w.a.tx_ready(w.addr_b))
            assert(w.a.send(make_message(0, 30, PCP.be), w.addr_b) > 0);
        w.a._test_blocked = false;
        ex.close_on_writable = true;
        assert(!s._waiter.handler(null));
        assert(w.a._closing && w.a._reclaim_due && !s._waiter.waiting && ex.writable == 1);
        size_t queued = s._queue.length;
        assert(!s._waiter.handler(null) && s._queue.length == queued, "a closing endpoint's parked sessions send nothing");
        w.a.reclaim(MonoTime());
        w.b.close();
        w.clear();
    }

    // fragmented messages on four lanes over a lossy link, across seeds
    static immutable PCP[4] mixed = [PCP.be, PCP.ca, PCP.vo, PCP.bk];
    foreach (uint seed; 1 .. 9)
    {
        Wire w;
        w.seed = seed;
        w.addr_a = wire.addr_a;
        w.addr_b = wire.addr_b;
        Sink sk, unused;
        Events ex, ey;
        w.b = make_endpoint(w, sk, ey, null);
        w.a = make_endpoint(w, unused, ex, &w.addr_b);
        w.pump();
        assert(w.a.established(w.addr_b));
        Completions dn;
        ubyte[lanes] next;
        w.loss_percent = 25;
        uint sent, step;
        while ((sk.count < 150 || dn.complete < 150) && step < 40_000)
        {
            while (sent < 150 && w.a.tx_ready(w.addr_b))
            {
                PCP pcp = mixed[(sent * 5 + seed) % 4];
                assert(w.a.send(make_message(next[pcp]++, cast(ushort)(3 + (sent * 37 + seed * 11) % 400), pcp), w.addr_b, &dn.done) > 0);
                ++sent;
            }
            w.tick(1, 5.msecs);
            ++step;
        }
        assert(sk.count == 150 && sk.bad == 0 && dn.complete == 150 && dn.other == 0 && w.b.established(w.addr_a));
        w.a.close();
        w.b.close();
        w.clear();
    }

    // a blocked egress holds the cut; its turn sends one frame at its lead lane's class, and the ack goes as control
    a._test_blocked = true;
    assert(a.send(make_message(seqs[PCP.vo]++, 30, PCP.vo), wire.addr_b) > 0);
    assert(a.send(make_message(seqs[PCP.be]++, 30, PCP.be), wire.addr_b) > 0);
    assert(wire.to_b.empty && sa._queue.length == 2);
    a._test_blocked = false;
    assert(!sa._waiter.handler(null) && wire.to_b.length == 1 && a._test_pcp == PCP.vo && sa._queue.empty);
    wire.flush(b);
    assert(b._test_pcp == PCP.nc);
    wire.tick();
    assert(sink.bad == 0 && sa.in_flight == 0);

    // a full listener retires its longest-idle session to admit a new peer
    static immutable ubyte[6] mac_c = [0x02, 0, 0, 0, 0, 0x0C];
    foreach (ubyte i; 1 .. 4)
    {
        g_test_time = g_test_time + 1.seconds;
        RDPSession* quiet = b.add(InetAddress(mac_c, cast(ushort)(5000 + i)));
        assert(quiet);
        quiet.start_open(g_test_time);
    }
    sb._active = g_test_time;
    assert(b.live_sessions() == 4 && b.idlest()._peer == InetAddress(mac_c, 5001));
    InetAddress newcomer = InetAddress(mac_c, 6000);
    assert(b.tx_ready(newcomer) && b.session_for(newcomer));
    assert(b.live_sessions() == 4 && b.find(InetAddress(mac_c, 5001))._phase == RDPSession.Phase.closed);
    b.enter();
    b.leave();
    assert(b._sessions.length == 4 && !b.find(InetAddress(mac_c, 5001)) && b.established(wire.addr_a));
    wire.clear();

    // markers for aborted messages on several lanes never outrun a small frame; what does not fit waits
    {
        ushort room = a._test_room;
        a._test_room = min_frame;
        sa._abort_lanes = 1 << PCP.bk | 1 << PCP.be | 1 << PCP.ee | 1 << PCP.nc;
        assert(sa.pump(g_test_time, true) && a._test_pcp == PCP.nc, "the highest lane leads the frame it was admitted for");
        assert(sa.pump(g_test_time));
        assert(sa._abort_lanes == 0);
        a._test_room = room;
        wire.tick();
        assert(sink.bad == 0 && a.established(wire.addr_b));
    }

    // a peer that comes back replaces the old session, whether its nonce or only its initial sequence is new
    Sink[2] sink_reborn;
    Events[2] ev_reborn;
    foreach (i; 0 .. 2)
    {
        uint closed = ev_a.closed;
        const(RDPSession)* old_b = wire.b.find(wire.addr_a);
        ubyte old_nonce = old_b._nonce;
        ubyte old_isn = old_b._isn;
        wire.b.close();
        wire.clear();
        wire.b = make_endpoint(wire, sink_reborn[i], ev_reborn[i], &wire.addr_a);
        wire.clear();
        RDPSession* reborn = wire.b.find(wire.addr_a);
        reborn._nonce = cast(ubyte)(i ? old_nonce : old_nonce + 1);
        reborn._isn = i ? (old_isn + 1) & 31 : old_isn;
        reborn._tx_una = reborn._tx_next = cast(ushort)(reborn._isn + 1);
        reborn.send_open(g_test_time);
        wire.pump();
        assert(ev_a.closed == closed + 1 && a.established(wire.addr_b) && wire.b.established(wire.addr_a));
        assert(a.send(make_message(0, 30, PCP.ca), wire.addr_b) > 0);
        wire.tick();
        assert(sink_reborn[i].count == 1 && sink_reborn[i].bad == 0);
    }

    // through real stations, endpoints and interface rounds: an egress queue that admits by class
    egress_scenarios(false);
    egress_scenarios(true);
}

version (unittest)
{
    import manager.base : CID, ObjectFlags;
    import manager.collection : Collection, collection_type_info;

    // a station whose egress queue admits bulk two frames deep and control four; drain() hands frames to the
    // station they are addressed to, highest class first or in order sent
    final class TestStation : EthernetStation
    {
        enum type_name = "rdp-test-station";
    nothrow @nogc:

        struct Sent
        {
            Array!ubyte bytes;
            MACAddress dst;
            PCP pcp;
        }

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestStation, id, flags);
            _state = State.running;
        }

        void address(MACAddress m)
        {
            adopt_mac(m);
        }

        override void medium_tx(Packet* packet)
        {
            Sent sent;
            sent.bytes ~= cast(const(ubyte)[])packet.data;
            sent.dst = packet.eth.dst;
            sent.pcp = packet.pcp;
            queue ~= sent.move;
            packet_free(packet);
        }

        override ubyte tx_floor() const
        {
            foreach (ubyte rank, limit; limits)
                if (queue.length < limit)
                    return rank;
            return tx_full;
        }

        // one frame onto the medium; true while frames remain
        bool drain(TestStation[] hub)
        {
            if (queue.empty)
                return false;
            size_t pick = 0;
            if (!fifo)
                foreach (i, ref q; queue[])
                    if (pcp_priority_map[q.pcp] > pcp_priority_map[queue[pick].pcp])
                        pick = i;
            Sent sent = queue[pick].move;
            queue.remove(pick);
            ahead ~= sent.pcp;
            foreach (st; hub)
            {
                if (st is this || st.mac != sent.dst)
                    continue;
                StackPacket frame;
                ref eth = frame.init!Ethernet(sent.bytes[]);
                eth.src = mac;
                eth.dst = sent.dst;
                eth.ether_type = EtherType.ow;
                frame.pcp = sent.pcp;
                st.incoming_packet(&frame.packet);
            }
            invite_tx();
            return true;
        }

        // the loop pass a deferred invitation waits for
        bool resume()
        {
            if (!_tx_deferred)
                return false;
            invite_tx();
            return true;
        }

        bool waiters() const
            => _tx_head !is null;

        static immutable ubyte[8] limits = [2, 2, 2, 3, 3, 4, 4, 4];
        Array!Sent queue;
        Array!PCP ahead;
        bool fifo;
    }

    struct EgressSink
    {
        uint count;
        uint bad;
        ubyte[lanes] next;
        Array!ushort order;

        void on_message(RDPEndpoint*, const(void)[] message, PCP lane, ref UDPReceiveInfo) nothrow @nogc
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])message;
            ++count;
            if (bytes.length < 3 || bytes[0] != next[lane]++ || (bytes[1] | bytes[2] << 8) != bytes.length)
                ++bad;
            order ~= cast(ushort)(lane << 8 | bytes[0]);
        }
    }

    struct EgressEvents
    {
        uint writable;
        bool close_on_writable;

        void on_event(RDPEndpoint* ep, ref const InetAddress, RDPEvent e) nothrow @nogc
        {
            if (e != RDPEvent.writable)
                return;
            ++writable;
            if (close_on_writable)
                ep.close();
        }
    }

    struct EtherInput
    {
        void input(Packet* packet, BaseInterface iface) nothrow @nogc
        {
            ether_transport_input(packet, iface);
        }
    }

    Packet* egress_message(ubyte seq, ushort len, PCP pcp)
    {
        Packet* p = alloc_packet!RawFrame(len);
        ubyte[] b = cast(ubyte[])p.payload;
        b[0] = seq;
        b[1] = cast(ubyte)len;
        b[2] = cast(ubyte)(len >> 8);
        p.pcp = pcp;
        return p;
    }

    void egress_scenarios(bool fifo)
    {
        static immutable ubyte[6][3] macs = [[0x02, 0, 0, 0, 0x5E, 0x0A], [0x02, 0, 0, 0, 0x5E, 0x0B], [0x02, 0, 0, 0, 0x5E, 0x0C]];
        EtherInput ether;
        assert(register_frame_handler(PacketType.ethernet, &ether.input));
        scope (exit) unregister_frame_handler(PacketType.ethernet);

        TestStation[3] hub;
        foreach (i, ref st; hub)
        {
            st = Collection!TestStation().create(i == 0 ? "rdp-test-a" : i == 1 ? "rdp-test-b" : "rdp-test-c");
            st.address(MACAddress(macs[i]));
            st.fifo = fifo;
        }
        scope (exit)
        {
            foreach (st; hub)
                st.destroy();
            Collection!BaseInterface().update_all();
        }

        InetAddress[3] at;
        foreach (i; 0 .. 3)
            at[i] = InetAddress(macs[i], 4000);
        EgressSink[3] sinks;
        EgressEvents[3] events;
        RDPEndpoint*[3] eps;
        foreach (i; 0 .. 3)
        {
            eps[i] = rdp_open(&at[i], null, &sinks[i].on_message, &events[i].on_event, hub[i]);
            assert(eps[i]);
        }
        scope (exit)
        {
            foreach (ep; eps)
                if (ep)
                    ep.close();
        }

        void settle()
        {
            for (bool busy = true; busy;)
            {
                busy = false;
                foreach (st; hub)
                {
                    while (st.drain(hub[]))
                        busy = true;
                    busy |= st.resume();
                }
                foreach (ep; eps)
                    if (ep)
                        foreach (s; ep._sessions[])
                            s.tick(g_test_time);
            }
        }

        RDPEndpoint* a = eps[0];
        ubyte[2] bulk;
        foreach (peer; 1 .. 3)
            assert(a.send(egress_message(bulk[peer - 1]++, 20, PCP.bk), at[peer]) > 0);
        settle();
        assert(a.established(at[1]) && a.established(at[2]) && sinks[1].count == 1 && sinks[2].count == 1);

        // bulk to two peers saturates the egress; the sessions wait on it rather than queue frames in it
        foreach (_; 0 .. 30)
            foreach (peer; 1 .. 3)
                if (a.tx_ready(at[peer]))
                    assert(a.send(egress_message(bulk[peer - 1]++, 300, PCP.bk), at[peer]) > 0);
        assert(hub[0].queue.length == TestStation.limits[0] && hub[0].waiters);

        // an urgent message is admitted past the bulk floor at once and overtakes everything still queued for the wire
        ubyte urgent_seq;
        assert(a.send(egress_message(urgent_seq++, 20, PCP.vo), at[1]) > 0);
        assert(hub[0].queue.length == TestStation.limits[0] + 1);
        hub[0].ahead.clear();
        size_t before = sinks[1].order.length;
        bool arrived()
        {
            foreach (o; sinks[1].order[before .. $])
                if (o >> 8 == PCP.vo)
                    return true;
            return false;
        }
        while (!arrived())
            assert(hub[0].drain(hub[]));
        size_t bulk_ahead;
        foreach (pcp; hub[0].ahead[])
            bulk_ahead += pcp != PCP.vo;
        assert(bulk_ahead == (fifo ? TestStation.limits[0] : 0), "bulk ahead of the urgent frame is bounded by the floor");

        // both peers drain, frame for frame, while the egress paces them
        uint start1 = sinks[1].count, start2 = sinks[2].count;
        foreach (step; 0 .. 40)
        {
            hub[0].drain(hub[]);
            hub[1].drain(hub[]);
            hub[2].drain(hub[]);
            hub[0].resume();
            uint got1 = sinks[1].count - start1, got2 = sinks[2].count - start2;
            assert((got1 > got2 ? got1 - got2 : got2 - got1) <= 8, "neither peer starves while both have backlog");
        }
        assert(sinks[1].count - start1 > 2 && sinks[2].count - start2 > 2);
        settle();
        assert(sinks[1].bad == 0 && sinks[2].bad == 0);
        assert(sinks[1].count + sinks[2].count == bulk[0] + bulk[1] + urgent_seq && !hub[0].waiters);

        // a refused class leaves its sessions parked, with nothing deferred to spin on
        foreach (_; 0 .. 6)
            foreach (peer; 1 .. 3)
                assert(a.send(egress_message(bulk[peer - 1]++, 300, PCP.bk), at[peer]) > 0);
        assert(hub[0].waiters && !hub[0].resume());

        // closing the endpoint from inside a real interface round frees nothing until the round has returned
        events[0].close_on_writable = true;
        foreach (_; 0 .. 30)
            foreach (peer; 1 .. 3)
                if (a.tx_ready(at[peer]))
                    assert(a.send(egress_message(bulk[peer - 1]++, 300, PCP.bk), at[peer]) > 0);
        while (!a._closing && hub[0].drain(hub[])) {}
        assert(a._closing && a._reclaim_due);
        a.reclaim(MonoTime());
        eps[0] = null;
        assert(!hub[0].waiters);
        settle();
    }
}
