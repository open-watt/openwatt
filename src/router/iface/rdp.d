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
//   window slots and give up the items whose turn has come; only the start of a fragmented message waits
//   for the hole. At most one message is partial at a time, so the receiver assembles with one buffer.
//   abort discards the partial message on its lane; it follows the aborted message's last chunk, and
//   frames already sent stay as sent.
//
// TODO: pause flag for flow control (a stream tunnel into a slow sink), rsvd bit 5 of byte 1
// TODO: authenticated sessions: a Noise handshake negotiated by the open flags, a keyed tag in the check slot
// TODO: congestion window, and delay-based shrink when a slow WAN uplink shows bufferbloat
// TODO: cut frames when the egress can take them, and carry the frame's PCP to the link

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
import router.iface.udp : udp_carrier_ether, udp_carrier_v4, udp_carrier_v6;

nothrow @nogc:


alias log = Log!"rdp";

enum ushort rdp_max_message = 1496;

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

    bool tx_ready(ref const InetAddress peer) const
    {
        const(RDPSession)* s = find(peer);
        return s ? s._queue.length < max_queue : !_connected && _sessions.length < _max_sessions;
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
        ushort tag = next_tag();
        s._queue ~= RDPSession.TxItem(kept, callback, 0, tag, kept.pcp);
        if (s._queue.length == max_queue)
            s._full = true;
        s.pump(now_time());
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

private:
    UDPEndpoint* _udp;
    RDPRecvHandler _on_recv;
    RDPEventHandler _on_event;
    Array!(RDPSession*) _sessions;
    UDPReceiveInfo* _rx_info;
    ushort _next_tag;
    ubyte _max_sessions;
    ubyte _depth;
    bool _connected;
    bool _closing;

    version (unittest)
    {
        void delegate(RDPEndpoint*, const(ubyte)[], ref const InetAddress) nothrow @nogc _test_wire;
        ushort _test_room;
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
        if (!s && type == type_open && !_closing)
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

    RDPSession* add(ref const InetAddress peer)
    {
        if (_sessions.length >= _max_sessions)
            return null;
        RDPSession* s = alloc!RDPSession();
        if (!s)
            return null;
        s._ep = &this;
        s._peer = peer;
        _sessions ~= s;
        return s;
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

    void transmit(const(ubyte)[] frame, ref const InetAddress peer)
    {
        version (unittest)
            if (_test_wire)
                return _test_wire(&this, frame, peer);
        _udp.sendto(frame, peer);
    }

    void reset_peer(ref const InetAddress peer)
    {
        ubyte[3] frame = [type_reset << 5, 0, 0];
        frame[2] = check(frame[0 .. 2], 0, 0, 0, 0);
        transmit(frame[], peer);
    }

    void event(ref const InetAddress peer, RDPEvent e)
    {
        if (_on_event)
            _on_event(&this, peer, e);
    }

    // handlers may close the endpoint or fail a session, so nothing is freed until the outermost entry leaves
    void enter()
    {
        ++_depth;
    }

    void leave()
    {
        if (--_depth)
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

    void destroy_now()
    {
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
enum lanes = 8;
enum ubyte no_lane = 0xFF;
enum max_queue = 32;
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
    Array!ubyte _assembly;
    Frame[window_max] _frames;
    Packet*[window_max] _held;
    MonoTime _timer_when;
    MonoTime _ack_deadline;
    MonoTime _open_deadline;
    uint _srtt_us;
    uint _rttvar_us;
    uint _rto_us;
    ushort _tx_una;
    ushort _tx_next;
    ushort _rx_next;
    ushort _rx_mask;
    ushort _rx_remaining;
    ushort _limit;
    ubyte[lanes] _tx_lane;
    ubyte[lanes] _rx_lane;
    ubyte[lanes] _unacked;     // chunks in frames not yet cumulatively acked: bounds the receiver's counter lag
    ubyte _isn;
    ubyte _nonce;
    ubyte _peer_nonce;
    ubyte _tx_partial;
    ubyte _abort_lane;
    ubyte _rx_partial;
    ubyte _backoff;
    ubyte _open_tries;
    Phase _phase;
    bool _timer_armed;
    bool _ack_pending;
    bool _pumping;
    bool _full;

    ~this()
    {
        disarm();
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
        _tx_partial = no_lane;
        _abort_lane = no_lane;
        _rx_partial = no_lane;
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
        acked_out();
        foreach (ref f; _frames)
        {
            packet_free(f.packet);
            f = Frame.init;
        }
        release_held();
        _rx_mask = 0;
        _assembly.clear();
        _full = false;
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
            {
                _tx_partial = no_lane;
                _abort_lane = item.lane;
            }
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
        bool more = !_queue.empty && in_flight < window_max;
        buf[1] = cast(ubyte)((buf[1] & flag_sack) | (_rx_next - 1) & 31 | (more ? flag_more : 0));
        if (buf[1] & flag_sack)
        {
            ushort sack = _rx_mask >> 1;
            buf[2] = cast(ubyte)sack;
            buf[3] = cast(ubyte)(sack >> 8);
        }
    }

    size_t frame_room() const
    {
        version (unittest)
            if (_ep._test_room)
                return _ep._test_room;
        return 1500 - (_peer.family == AddressFamily.ipv6 ? udp_carrier_v6 : _peer.family == AddressFamily.ether ? udp_carrier_ether : udp_carrier_v4);
    }

    void pump(MonoTime now)
    {
        bool outer = !_pumping;
        _pumping = true;
        while (cut_frame(now)) {}
        rearm(now);
        if (!outer)
            return;
        _pumping = false;
        if (_full && _queue.length < max_queue)
        {
            _full = false;
            _ep.event(_peer, RDPEvent.writable);
        }
    }

    size_t head_index(ubyte lane) const pure
    {
        foreach (i, ref it; _queue[])
            if (it.lane == lane)
                return i;
        return size_t.max;
    }

    bool cut_frame(MonoTime now)
    {
        if (_phase != Phase.established || in_flight >= window_max || (_queue.empty && _abort_lane == no_lane))
            return false;
        size_t room = frame_room();
        Packet* frame = alloc_packet!RawFrame(room);
        if (!frame)
            return false;
        ubyte[] buf = (cast(ubyte[])frame.payload)[0 .. room - 1];
        size_t start = write_header(buf, type_data, _tx_next, false);
        size_t pos = start;
        Frame f;

        if (_abort_lane != no_lane && lane_open(_abort_lane, f.chunks))
        {
            buf[pos++] = cast(ubyte)(item_continue | item_abort | _abort_lane << 4);
            buf[pos++] = _tx_lane[_abort_lane]++;
            ++f.chunks[_abort_lane];
            _abort_lane = no_lane;
        }

        // whole items by lane; a long message in progress yields only to the lanes above it
        foreach (lane; scheduling_order)
        {
            if (lane == _tx_partial)
                break;
            for (size_t i = head_index(lane); i != size_t.max && lane_open(lane, f.chunks); i = head_index(lane))
            {
                size_t len = _queue[i].packet.length;
                if (pos + item_header_size(len) + len > buf.length)
                    break;
                pos = write_item(buf, pos, lane, len);
                pos = cut_chunk(buf, pos, i, len, f, lane);
            }
        }

        // the partial message continues; failing one, the highest-priority head that did not fit whole starts one
        ubyte lane = _tx_partial;
        if (lane == no_lane && _abort_lane == no_lane)
        {
            foreach (l; scheduling_order)
            {
                size_t i = head_index(l);
                if (i != size_t.max && lane_open(l, f.chunks) && pos + item_header_size(_queue[i].packet.length) < buf.length)
                {
                    lane = l;
                    break;
                }
            }
        }
        if (lane != no_lane && lane_open(lane, f.chunks))
        {
            size_t i = head_index(lane);
            TxItem* it = &_queue[i];
            size_t remaining = it.packet.length - it.sent;
            size_t hdr = it.sent ? 2 : item_header_size(remaining);
            if (pos + hdr < buf.length)
            {
                size_t take = buf.length - pos - hdr;
                if (take > remaining)
                    take = remaining;
                pos = write_item(buf, pos, lane, it.sent ? continuation : remaining);
                _tx_partial = take < remaining ? lane : no_lane;
                pos = cut_chunk(buf, pos, i, take, f, lane);
            }
        }

        if (pos == start)
        {
            packet_free(frame);
            return false;
        }

        if (!_queue.empty && in_flight + 1 < window_max)
            buf[1] |= flag_more;
        frame.truncate(pos + 1);
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
        _ep.transmit(frame, _peer);
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
        _ep.transmit(buf[0 .. len + 1], _peer);
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
        rearm(now);
    }

    void on_frame(const(ubyte)[] frame, MonoTime now)
    {
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
        process_ack(ack, sack, now);
        if (type == type_data && _phase == Phase.established)
            on_data(seq, body, now);
    }

    void on_open(ubyte isn, ubyte nonce, ushort peer_max, bool is_ack, MonoTime now)
    {
        if (_phase == Phase.established)
        {
            if (nonce == _peer_nonce)
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
        if (!is_ack)
            send_control(type_open_ack, now);
    }

    void establish(ubyte isn, ubyte nonce, ushort peer_max, MonoTime now)
    {
        _peer_nonce = nonce;
        _rx_next = cast(ushort)(isn + 1);
        _rx_mask = 0;
        _rx_partial = no_lane;
        _rx_lane[] = 0;
        _assembly.clear();
        release_held();
        acked_out();
        _limit = peer_max < rdp_max_message ? peer_max : rdp_max_message;
        _phase = Phase.established;
        _ep.event(_peer, RDPEvent.established);
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

    void on_data(ushort seq, const(ubyte)[] body, MonoTime now)
    {
        uint d = cast(ushort)(seq - _rx_next);
        if (d >= window_max || (_rx_mask & (1 << d)))
            return request_ack(now, true);
        bool more = (body[1] & flag_more) != 0;
        if (d == 0)
        {
            // every earlier frame is consumed, so everything in this one is ready
            scan(body, true, now);
            if (_phase != Phase.established || !drained(body))
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
        uint run;
        while (run < window_max && (_rx_mask & (1 << run)))
            ++run;
        for (bool progress = _rx_mask != 0; progress && _phase == Phase.established;)
        {
            progress = false;
            foreach (k; 0 .. window_max)
                if (_rx_mask & (1 << k))
                    progress |= scan(cast(const(ubyte)[])_held[(_rx_next + k) & (window_max - 1)].data, k < run, now);
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

    // its lane's previous chunk is consumed; a long message starts only below a hole, where no earlier one
    // can still be missing, and only once the partial message ahead of it is done
    bool ready(ref const Item it, bool in_order) const pure
        => it.counter == _rx_lane[it.lane] && (it.abort || it.len == continuation || it.take == it.len || (in_order && _rx_partial == no_lane));

    bool scan(const(ubyte)[] frame, bool in_order, MonoTime now)
    {
        bool progress;
        size_t pos = items_at(frame);
        Item it;
        int r;
        while (_phase == Phase.established && (r = next_item(frame, pos, it)) > 0)
        {
            if (!ready(it, in_order))
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
        if (it.abort)
        {
            if (_rx_partial == lane)
            {
                _rx_partial = no_lane;
                _assembly.clear();
            }
            return;
        }
        if (it.len == continuation)
        {
            if (_rx_partial != lane || bytes.length > _rx_remaining)
                return cast(void)protocol_error(now);
            _assembly ~= bytes;
            _rx_remaining -= cast(ushort)bytes.length;
            if (_rx_remaining)
                return;
            _rx_partial = no_lane;
            deliver(lane, _assembly[]);
            _assembly.clear();
            return;
        }
        if (it.len > _limit)
            return cast(void)protocol_error(now);
        if (bytes.length == it.len)
            return deliver(lane, bytes);
        _rx_partial = lane;
        _rx_remaining = cast(ushort)(it.len - bytes.length);
        _assembly ~= bytes;
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
    }
}


unittest
{
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
        ubyte loss_percent;

        void carry(RDPEndpoint*, const(ubyte)[] frame, ref const InetAddress peer)
        {
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

        void on_message(RDPEndpoint*, const(void)[] message, PCP lane, ref UDPReceiveInfo) nothrow @nogc
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])message;
            ++count;
            if (bytes.length < 3 || bytes[0] != next[lane]++ || (bytes[1] | bytes[2] << 8) != bytes.length)
                ++bad;
            foreach (i, b; bytes[3 .. $])
                if (b != cast(ubyte)(bytes[0] * 7 + i))
                    ++bad;
            order ~= cast(ushort)(lane << 8 | bytes[0]);
        }
    }

    struct Events
    {
        uint established;
        uint closed;
        uint writable;

        void on_event(RDPEndpoint*, ref const InetAddress, RDPEvent e) nothrow @nogc
        {
            final switch (e)
            {
                case RDPEvent.established: ++established; break;
                case RDPEvent.closed:      ++closed;      break;
                case RDPEvent.writable:    ++writable;    break;
            }
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

    // 90-byte datagrams: a 1496-byte message overruns the 16-frame window
    static RDPEndpoint* make_endpoint(ref Wire wire, ref Sink sink, ref Events events, const(InetAddress)* remote)
    {
        RDPEndpoint* ep = rdp_create(&sink.on_message, &events.on_event, 4);
        ep._test_wire = &wire.carry;
        ep._test_room = 90;
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

    // with the window full, a small urgent message queued behind a long one takes the next frame
    assert(a.send(make_message(seqs[PCP.be]++, 1496, PCP.be), wire.addr_b, &done.done) > 0);
    assert(sa.in_flight == window_max && sa._queue.length == 1);
    assert(a.send(make_message(seqs[PCP.be]++, 300, PCP.be), wire.addr_b, &done.done) > 0);
    assert(a.send(make_message(seqs[PCP.nc]++, 12, PCP.nc), wire.addr_b, &done.done) > 0);
    wire.tick(1);
    assert(sink.count == 3 && sink.bad == 0);
    assert(sink.order[0] == (PCP.nc << 8 | 0) && sink.order[1] == (PCP.be << 8 | 0) && sink.order[2] == (PCP.be << 8 | 1));
    wire.tick(2);
    assert(done.complete == 3 && done.other == 0);
    assert(sa.in_flight == 0 && sa._cut.empty && sa._queue.empty && sb._rx_mask == 0 && sb._assembly.empty);

    // a long message does not yield to lanes below it
    assert(a.send(make_message(seqs[PCP.vo]++, 1496, PCP.vo), wire.addr_b, &done.done) > 0);
    foreach (_; 0 .. 3)
        assert(a.send(make_message(seqs[PCP.ca]++, 20, PCP.ca), wire.addr_b, &done.done) > 0);
    wire.tick(4);
    assert(sink.count == 7 && sink.bad == 0 && sink.order[3] == (PCP.vo << 8 | 0));
    assert(done.complete == 7);

    // an aborted message stops at the next frame and the lane carries on
    assert(a.send(make_message(seqs[PCP.be]++, 1496, PCP.be), wire.addr_b, &done.done) > 0);
    int big = a.send(make_message(seqs[PCP.be], 1496, PCP.be), wire.addr_b, &done.done);
    wire.flush(b);
    wire.flush(a);
    assert(big > 0 && a.msg_state(big) == MessageState.in_flight && sa._tx_partial == PCP.be);
    a.abort(big);
    assert(sa._tx_partial == no_lane && done.other == 1);
    assert(a.send(make_message(seqs[PCP.be]++, 12, PCP.be), wire.addr_b, &done.done) > 0);
    wire.tick(4);
    assert(sink.count == 9 && sink.bad == 0 && sb._rx_partial == no_lane && sb._assembly.empty);
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
    assert(sa.in_flight == 0 && sb._rx_mask == 0 && sb._rx_partial == no_lane && sa._srtt_us > 0);
    wire.loss_percent = 0;

    // a full queue reports writable once it drains
    uint writable = ev_a.writable;
    while (a.tx_ready(wire.addr_b))
        assert(a.send(make_message(seqs[PCP.ca]++, 200, PCP.ca), wire.addr_b) > 0);
    assert(sa._full && ev_a.writable == writable);
    wire.tick(8);
    assert(ev_a.writable == writable + 1 && sa._queue.empty && sink.bad == 0);
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
    int doomed = a.send(make_message(seqs[PCP.be], 1496, PCP.be), wire.addr_b, &done.done);
    assert(doomed > 0 && sa._tx_partial == PCP.be);
    a.abort(doomed);
    assert(a.send(make_message(seqs[PCP.nc]++, 12, PCP.nc), wire.addr_b, &done.done) > 0);
    wire.tick(8);
    wire.deliver(lost_head, b);
    wire.tick();
    assert(a.established(wire.addr_b) && sink.bad == 0 && sb._rx_partial == no_lane);
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

    // a peer that comes back with a new session nonce replaces the old session
    uint closed = ev_a.closed;
    wire.b.close();
    wire.clear();
    Sink sink_b2;
    Events ev_b2;
    wire.b = make_endpoint(wire, sink_b2, ev_b2, &wire.addr_a);
    wire.pump();
    assert(ev_a.closed == closed + 1 && a.established(wire.addr_b) && wire.b.established(wire.addr_a));
    assert(a.send(make_message(0, 30, PCP.ca), wire.addr_b) > 0);
    wire.tick();
    assert(sink_b2.count == 1 && sink_b2.bad == 0);
}
