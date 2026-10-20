module router.iface.rdp;

// Reliable message delivery over any datagram parent (UDP, raw 802.15.4, a framed serial trunk): a
// selective-repeat ARQ with a 16-frame window, tuned for media of hundreds of kbit/s and frames of
// hundreds of bytes. Consumers submit raw packets up to max-message; the layer packs them into parent
// frames, fragments the ones that do not fit, and delivers them whole in order. The lane is the packet's
// PCP: a frame is cut highest lane first, so a small urgent message rides at the head of the next frame
// while a long one streams, a long message only yields to lanes above its own, and loss on one lane
// never holds up another.
//
// Frame: [type:3 seq:5][sack:1 more:1 rsvd:1 ack:5] ([sack bitmap:16 LE])? payload
//   type 0 data, 1 ack-only, 2 open, 3 open-ack, 4 reset. ack is the cumulative point, bit n of the
//   bitmap acknowledges ack+2+n. open and open-ack carry [nonce][max-message/8] and their seq is the
//   initial sequence; the first data frame follows it. more says the sender will send again before it
//   needs an ack, so the receiver holds its ack until a frame without it.
// Item: [0 lane:3 ext:1 len:3] ([len low:8])? [counter:8] bytes, or [1 lane:3 abort:1 rsvd:3] [counter:8] bytes
//   The first form opens a message of len bytes; a chunk short of len ends its frame and the lane's next
//   chunk, in the second form, continues it to the end of its own frame. The counter orders chunks
//   within a lane, so a lost frame stalls only the lanes it carried: frames past a hole wait in their
//   window slots and give up the items whose turn has come; only the start of a fragmented message waits
//   for the hole. At most one message is partial at a time, so the receiver assembles with one buffer.
//   abort discards the partial message on its lane; it follows the aborted message's last chunk, and
//   frames already sent stay as sent.
//
// The parent must not deliver a frame later than one window of newer, acknowledged frames: the 5-bit
// sequence cannot tell such a straggler from fresh data. Nothing here enforces it; the parent's link must.
//
// TODO: pause flag for flow control (a stream tunnel into a slow sink), rsvd bit 5 of byte 1
// TODO: HMAC trailer as a session property, authenticating an implicit extended sequence so stragglers
//       on WAN UDP are rejected
// TODO: delay-based window shrink when a slow WAN uplink shows bufferbloat
// TODO: per-peer instances spawned on a multi-drop parent

import urt.array;
import urt.lifetime;
import urt.mem;
import urt.mem.pagepool;
import urt.rand : rand;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

import router.iface;

nothrow @nogc:


final class RDPInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("window", window),
                                 Prop!("max-message", max_message),
                                 Prop!("rtt", rtt, "status"),
                                 Prop!("retransmits", retransmits, "traffic"));
nothrow @nogc:

    ~this() {}

    enum type_name = "rdp";
    enum path = "/interface/rdp";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!RDPInterface, id, flags);
        _caps = cast(InterfaceCaps)(InterfaceCaps.reliable | InterfaceCaps.ordered);
        set_l2mtu(default_max_message);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure
        => _iface.get;
    final void iface(BaseInterface value)
    {
        if (_iface.get is value)
            return;
        unsubscribe_parent();
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    final ubyte window() const pure
        => _window;
    final const(char)[] window(ubyte value)
    {
        if (value == 0 || value > window_max)
            return "window must be between 1 and 16";
        _window = value;
        mark_set!(typeof(this), "window")();
        return null;
    }

    final ushort max_message() const pure
        => _max_message;
    final const(char)[] max_message(ushort value)
    {
        if (value < min_message || value > message_limit)
            return "max-message must be between 64 and 2040";
        value &= ~7;
        if (value == _max_message)
            return null;
        _max_message = value;
        mark_set!(typeof(this), "max-message")();
        restart();
        return null;
    }

    final bool established() const pure
        => _session == Session.established;
    final Milliseconds rtt() const
        => Milliseconds(float(_srtt_us) / 1000);
    final ulong retransmits() const pure
        => _retransmits;

    // API...

    override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        foreach (i, ref it; _queue[])
        {
            if (it.tag != msg_handle)
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
            return;
        }
    }

    override MessageState msg_state(int msg_handle) const
    {
        foreach (ref it; _queue[])
            if (it.tag == msg_handle)
                return it.sent ? MessageState.in_flight : MessageState.queued;
        foreach (ref it; _cut[])
            if (it.tag == msg_handle)
                return MessageState.in_flight;
        return MessageState.complete;
    }

    override bool tx_ready() const
        => _queue.length < max_queue;

protected:

    override bool validate() const
        => _iface !is null;

    override CompletionStatus startup()
    {
        BaseInterface parent = _iface.get;
        if (!parent || !parent.running)
            return CompletionStatus.continue_;
        _tables = alloc!Tables();
        if (!_tables)
        {
            log.error("out of memory");
            return CompletionStatus.error;
        }

        PacketFilter filter = PacketFilter(PacketType.unknown, PacketDirection.incoming);
        parent.subscribe(&on_parent_packet, filter);
        parent.subscribe(&parent_state_change);
        _subscribed = true;

        _nonce = cast(ubyte)rand();
        _isn = cast(ubyte)(rand() & seq_mask);
        _tx_una = _tx_next = next_seq(_isn);
        _tx_partial = no_lane;
        _abort_lane = no_lane;
        _srtt_us = 0;
        _rttvar_us = 0;
        _rto_us = initial_rto_us;
        _backoff = 0;
        _open_tries = 0;
        set_l2mtu(_max_message);

        _session = Session.opening;
        MonoTime now = now_time();
        send_open(now);
        rearm(now);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_parent();
        disarm();
        _session = Session.closed;
        if (_tables)
        {
            foreach (ref f; _tables.frames)
                packet_free(f.packet);
            release_held();
            free(_tables);
            _tables = null;
        }
        while (!_queue.empty)
        {
            TxItem item = _queue.pop_back();
            finish(item.packet, item.callback, item.tag, MessageState.aborted);
        }
        while (!_cut.empty)
        {
            Pending item = _cut.pop_back();
            finish(null, item.callback, item.tag, MessageState.aborted);
        }
        _assembly.clear();
        _rx_partial = no_lane;
        return CompletionStatus.complete;
    }

    override bool carrier() const
        => _session == Session.established;

    override int transmit(Packet* packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
    {
        if (packet.type != PacketType.raw || _queue.length >= max_queue)
            return drop_tx(packet);
        Packet* kept = packet_keep(packet);
        if (kept !is packet)
            packet_free(packet);
        if (!kept)
            return drop_tx(null);
        ushort tag = next_tag();
        _queue ~= TxItem(kept, callback, 0, tag, kept.pcp);
        if (_queue.length == max_queue)
            _full = true;
        pump(now_time());
        return tag;
    }

    version (unittest) void test_start()
    {
        assert(startup() == CompletionStatus.complete);
        _state = State.running;
        online();
    }

private:
    enum ushort default_max_message = 1500;
    enum ushort min_message = 64;
    enum ushort message_limit = 2040;
    enum frame_limit = 2048;
    enum window_max = 16;
    enum seq_mask = 31;
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

    enum Session : ubyte
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
        ubyte last_seq;
    }

    struct Frame
    {
        Packet* packet;
        MonoTime sent;
        ubyte retries;
        bool retransmitted;
        bool fast;
        ubyte[lanes] chunks;
    }

    // one allocation at startup: in the class they would be emitted whole in its init image
    struct Tables
    {
        Frame[window_max] frames;
        Packet*[window_max] held;
        ubyte[lanes] tx_lane;
        ubyte[lanes] rx_lane;
        ubyte[lanes] unacked;     // chunks in frames not yet cumulatively acked: bounds the receiver's counter lag
    }

    static immutable ubyte[lanes] scheduling_order = [7, 6, 5, 4, 3, 2, 0, 1];

    ObjectRef!BaseInterface _iface;
    Array!TxItem _queue;
    Array!Pending _cut;
    Array!ubyte _assembly;
    Tables* _tables;
    MonoTime _timer_when;
    MonoTime _ack_deadline;
    MonoTime _open_deadline;
    ulong _retransmits;
    uint _srtt_us;
    uint _rttvar_us;
    uint _rto_us = initial_rto_us;
    ushort _max_message = default_max_message;
    ushort _rx_mask;
    ushort _rx_remaining;
    ushort _next_tag;
    ubyte _window = window_max;
    ubyte _isn;
    ubyte _nonce;
    ubyte _peer_nonce;
    ubyte _tx_una;
    ubyte _tx_next;
    ubyte _rx_next;
    ubyte _tx_partial = no_lane;
    ubyte _abort_lane = no_lane;
    ubyte _rx_partial = no_lane;
    ubyte _backoff;
    ubyte _open_tries;
    Session _session;
    bool _subscribed;
    bool _timer_armed;
    bool _ack_pending;
    bool _pumping;
    bool _full;

    static ubyte next_seq(ubyte seq) pure
        => cast(ubyte)((seq + 1) & seq_mask);

    static uint seq_distance(ubyte from, ubyte to) pure
        => (to - from) & seq_mask;

    uint in_flight() const pure
        => seq_distance(_tx_una, _tx_next);

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
        buf[pos++] = _tables.tx_lane[lane]++;
        return pos;
    }

    bool lane_open(ubyte lane, ref const ubyte[lanes] chunks) const pure
        => _tables.unacked[lane] + chunks[lane] < lane_budget;

    // the ack fields are rewritten on every send, so a retransmitted frame never carries a stale one
    size_t write_header(ubyte[] buf, ubyte type, ubyte seq, bool more) const pure
    {
        buf[0] = cast(ubyte)(type << 5 | seq);
        ubyte flags = cast(ubyte)((_rx_next - 1) & seq_mask | (more ? flag_more : 0));
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
        bool more = !_queue.empty && in_flight < _window;
        buf[1] = cast(ubyte)((buf[1] & flag_sack) | (_rx_next - 1) & seq_mask | (more ? flag_more : 0));
        if (buf[1] & flag_sack)
        {
            ushort sack = _rx_mask >> 1;
            buf[2] = cast(ubyte)sack;
            buf[3] = cast(ubyte)(sack >> 8);
        }
    }

    void pump(MonoTime now)
    {
        bool outer = !_pumping;
        _pumping = true;
        while (cut_frame(now)) {}
        if (_session == Session.established && (_ack_pending || (!_queue.empty && in_flight < _window)))
        {
            BaseInterface parent = _iface.get;
            if (parent && !parent.tx_ready && parent.tx_handler !is &on_parent_tx)
                parent.tx_handler(&on_parent_tx);
        }
        rearm(now);
        if (outer)
        {
            _pumping = false;
            if (_full && tx_ready)
            {
                _full = false;
                invite_tx();
            }
        }
    }

    // a response slot on a polled carrier is an opportunity: an ack owed goes out in it
    bool on_parent_tx(BaseInterface)
    {
        MonoTime now = now_time();
        pump(now);
        if (_ack_pending)
            send_ack(now);
        return !_queue.empty && in_flight < _window;
    }

    ushort next_tag()
    {
        for (;;)
        {
            if (++_next_tag == 0)
                _next_tag = 1;
            if (!tag_live(_next_tag))
                return _next_tag;
        }
    }

    bool tag_live(ushort tag) const pure
    {
        foreach (ref it; _queue[])
            if (it.tag == tag)
                return true;
        foreach (ref it; _cut[])
            if (it.tag == tag)
                return true;
        return false;
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
        if (_session != Session.established || in_flight >= _window || (_queue.empty && _abort_lane == no_lane))
            return false;
        BaseInterface parent = _iface.get;
        if (!parent || !parent.running || !parent.tx_ready)
            return false;
        size_t room = parent.actual_mtu;
        if (room > frame_limit)
            room = frame_limit;
        if (room < 8)
            return false;

        Packet* frame = alloc_packet!RawFrame(room);
        if (!frame)
        {
            add_tx_drop();
            return false;
        }
        ubyte[] buf = cast(ubyte[])frame.payload;
        size_t start = write_header(buf, type_data, _tx_next, false);
        size_t pos = start;
        Frame f;

        if (_abort_lane != no_lane && lane_open(_abort_lane, f.chunks))
        {
            buf[pos++] = cast(ubyte)(item_continue | item_abort | _abort_lane << 4);
            buf[pos++] = _tables.tx_lane[_abort_lane]++;
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

        if (!_queue.empty && in_flight + 1 < _window)
            buf[1] |= flag_more;
        frame.truncate(pos);
        f.packet = frame;
        f.sent = now;
        foreach (l, c; f.chunks)
            _tables.unacked[l] += c;
        Frame* slot = &_tables.frames[_tx_next & (window_max - 1)];
        *slot = f;
        _tx_next = next_seq(_tx_next);
        acked_out();
        send_frame(slot, now);
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
            add_tx_frame(it.packet.length);
            _cut ~= Pending(it.callback, it.tag, _tx_next);
            packet_free(it.packet);
            _queue.remove(i);
        }
        return pos + take;
    }

    void send_frame(Frame* slot, MonoTime now)
    {
        BaseInterface parent = _iface.get;
        if (!parent)
            return;
        StackPacket view;
        view.init!RawFrame(slot.packet.data, now);
        foreach (lane; scheduling_order)
        {
            if (slot.chunks[lane])
            {
                view.pcp = cast(PCP)lane;
                break;
            }
        }
        parent.forward(&view.packet);
    }

    void resend(Frame* slot, MonoTime now)
    {
        slot.retransmitted = true;
        slot.sent = now;
        ++_retransmits;
        mark_set!(typeof(this), "retransmits")();
        refresh_header(cast(ubyte[])slot.packet.payload);
        send_frame(slot, now);
    }

    void send_control(ubyte type, MonoTime now)
    {
        BaseInterface parent = _iface.get;
        if (!parent)
            return;
        ubyte[6] buf = void;
        size_t len;
        if (type == type_ack)
            len = write_header(buf, type_ack, 0, false);
        else
        {
            buf[0] = cast(ubyte)(type << 5 | (type == type_reset ? 0 : _isn));
            buf[1] = 0;
            len = 2;
            if (type != type_reset)
            {
                buf[2] = _nonce;
                buf[3] = cast(ubyte)(_max_message / 8);
                len = 4;
            }
        }
        StackPacket view;
        view.init!RawFrame(buf[0 .. len], now);
        view.pcp = PCP.nc;
        parent.forward(&view.packet);
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

    void process_ack(ubyte ack, ushort sack, MonoTime now)
    {
        uint fl = in_flight;
        if (!fl)
            return;
        uint d = seq_distance(_tx_una, ack);
        MonoTime newest;
        bool clean;
        if (d < fl)
        {
            foreach (k; 0 .. d + 1)
            {
                ubyte s = cast(ubyte)((_tx_una + k) & seq_mask);
                release_frame(s, newest, clean);
                complete_items(s);
                Frame* f = &_tables.frames[s & (window_max - 1)];
                foreach (l, c; f.chunks)
                    _tables.unacked[l] -= c;
                f.chunks[] = 0;
            }
            _tx_una = next_seq(ack);
            fl = in_flight;
        }

        ubyte highest = no_lane;
        foreach (n; 0 .. 16)
        {
            if (!(sack & (1 << n)))
                continue;
            ubyte s = cast(ubyte)((ack + 2 + n) & seq_mask);
            if (seq_distance(_tx_una, s) < fl)
            {
                release_frame(s, newest, clean);
                highest = s;
            }
        }
        if (clean)
            rtt_sample(now - newest);
        if (highest != no_lane)
        {
            foreach (k; 0 .. seq_distance(_tx_una, highest))
            {
                Frame* f = &_tables.frames[(_tx_una + k) & (window_max - 1)];
                if (f.packet && !f.fast)
                {
                    f.fast = true;
                    resend(f, now);
                }
            }
        }
        pump(now);
    }

    // the newest frame an ack releases is the sample least inflated by a repaired hole
    void release_frame(ubyte seq, ref MonoTime newest, ref bool clean)
    {
        Frame* f = &_tables.frames[seq & (window_max - 1)];
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

    void complete_items(ubyte seq)
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
        mark_set!(typeof(this), "rtt")();
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
            Frame* f = &_tables.frames[(_tx_una + k) & (window_max - 1)];
            if (f.packet)
                return f;
        }
        return null;
    }

    void rearm(MonoTime now)
    {
        MonoTime next = _ack_deadline;
        if (_session == Session.opening && (next == MonoTime.init || _open_deadline < next))
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
        if (_session == Session.closed)
            return;
        MonoTime now = now_time();
        if (_ack_deadline != MonoTime.init && now >= _ack_deadline)
            send_ack(now);
        if (_session == Session.opening && now >= _open_deadline)
            send_open(now);
        if (Frame* f = oldest_frame())
        {
            if (now - f.sent >= effective_rto)
            {
                if (f.retries >= max_retries)
                {
                    log.warning("peer unresponsive: no ack after ", max_retries, " retransmits");
                    return fail_session(now);
                }
                ++f.retries;
                resend(f, now);
                if (_backoff < 4)
                    ++_backoff;
            }
        }
        rearm(now);
    }

    void on_parent_packet(const(Packet)* p, BaseInterface, PacketDirection, void*)
    {
        if (p.type != PacketType.raw && p.type != PacketType.udp)
            return;
        const(ubyte)[] frame = cast(const(ubyte)[])p.data;
        if (frame.length < 2)
            return;
        MonoTime now = p.creation_time;
        ubyte type = frame[0] >> 5;
        ubyte seq = frame[0] & seq_mask;
        ubyte ack = frame[1] & seq_mask;
        size_t pos = 2;
        ushort sack;
        if (frame[1] & flag_sack)
        {
            if (frame.length < 4)
                return;
            sack = cast(ushort)(frame[2] | frame[3] << 8);
            pos = 4;
        }

        switch (type)
        {
            case type_open:
            case type_open_ack:
                if (frame.length < pos + 2)
                    return;
                on_open(seq, frame[pos], cast(ushort)(frame[pos + 1] * 8), type == type_open_ack, now);
                return;
            case type_reset:
                if (_session != Session.closed)
                {
                    _session = Session.closed;
                    restart_deferred();
                }
                return;
            case type_ack:
                if (_session == Session.established)
                    process_ack(ack, sack, now);
                return;
            case type_data:
                if (_session != Session.established)
                    return send_control(type_reset, now);
                process_ack(ack, sack, now);
                if (_session == Session.established)
                    on_data(seq, p, now);
                return;
            default:
                return;
        }
    }

    void on_open(ubyte isn, ubyte nonce, ushort peer_max, bool is_ack, MonoTime now)
    {
        final switch (_session)
        {
            case Session.closed:
                return;
            case Session.opening:
                establish(isn, nonce, peer_max, now);
                if (!is_ack)
                    send_control(type_open_ack, now);
                return;
            case Session.established:
                if (nonce == _peer_nonce)
                {
                    if (!is_ack)
                        send_control(type_open_ack, now);
                }
                else if (!is_ack)
                    fail_session(now, false);
                return;
        }
    }

    void establish(ubyte isn, ubyte nonce, ushort peer_max, MonoTime now)
    {
        _peer_nonce = nonce;
        _rx_next = next_seq(isn);
        _rx_mask = 0;
        _rx_partial = no_lane;
        _assembly.clear();
        release_held();
        acked_out();
        set_l2mtu(peer_max < _max_message ? peer_max : _max_message);
        _session = Session.established;
        set_link(true);
        pump(now);
    }

    void fail_session(MonoTime now, bool notify = true)
    {
        if (notify)
            send_control(type_reset, now);
        _session = Session.closed;
        restart_deferred();
    }

    void on_data(ubyte seq, const(Packet)* p, MonoTime now)
    {
        uint d = seq_distance(_rx_next, seq);
        if (d >= window_max || (_rx_mask & (1 << d)))
            return request_ack(now, true);
        const(ubyte)[] frame = cast(const(ubyte)[])p.data;
        bool more = (frame[1] & flag_more) != 0;
        if (d == 0)
        {
            // every earlier frame is consumed, so everything in this one is ready
            scan(frame, true, now);
            if (_session != Session.established || !drained(frame))
                return cast(void)protocol_error(now);
            _rx_mask >>= 1;
            _rx_next = next_seq(_rx_next);
        }
        else
        {
            Packet* kept = packet_retain(p);
            if (!kept)
                return;
            _tables.held[seq & (window_max - 1)] = kept;
            _rx_mask |= cast(ushort)(1 << d);
        }
        drain_held(now, more);
        if (_session == Session.established)
            request_ack(now, _rx_mask != 0 || !more);
    }

    // held frames give up their ready items until none is left; the run the hole no longer blocks is freed
    void drain_held(MonoTime now, ref bool more)
    {
        uint run;
        while (run < window_max && (_rx_mask & (1 << run)))
            ++run;
        for (bool progress = _rx_mask != 0; progress && _session == Session.established;)
        {
            progress = false;
            foreach (k; 0 .. window_max)
                if (_rx_mask & (1 << k))
                    progress |= scan(cast(const(ubyte)[])_tables.held[(_rx_next + k) & (window_max - 1)].data, k < run, now);
        }
        while (_session == Session.established && (_rx_mask & 1))
        {
            Packet** slot = &_tables.held[_rx_next & (window_max - 1)];
            const(ubyte)[] frame = cast(const(ubyte)[])(*slot).data;
            if (!drained(frame))
                return cast(void)protocol_error(now);
            more = (frame[1] & flag_more) != 0;
            packet_free(*slot);
            *slot = null;
            _rx_mask >>= 1;
            _rx_next = next_seq(_rx_next);
        }
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
        => it.counter == _tables.rx_lane[it.lane] && (it.abort || it.len == continuation || it.take == it.len || (in_order && _rx_partial == no_lane));

    bool scan(const(ubyte)[] frame, bool in_order, MonoTime now)
    {
        bool progress;
        size_t pos = items_at(frame);
        Item it;
        int r;
        while (_session == Session.established && (r = next_item(frame, pos, it)) > 0)
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
            if (cast(byte)(it.counter - _tables.rx_lane[it.lane]) >= 0)
                return false;
        return true;
    }

    void consume(ref const Item it, const(ubyte)[] bytes, MonoTime now)
    {
        ubyte lane = it.lane;
        ++_tables.rx_lane[lane];
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
            deliver(lane, _assembly[], now);
            _assembly.clear();
            return;
        }
        if (it.len > _l2mtu)
            return cast(void)protocol_error(now);
        if (bytes.length == it.len)
            return deliver(lane, bytes, now);
        _rx_partial = lane;
        _rx_remaining = cast(ushort)(it.len - bytes.length);
        _assembly ~= bytes;
    }

    bool protocol_error(MonoTime now)
    {
        log.warning("peer violated the message framing; resetting session");
        fail_session(now);
        return false;
    }

    void request_ack(MonoTime now, bool immediate)
    {
        _ack_pending = true;
        pump(now);
        if (!_ack_pending)
            return;
        BaseInterface parent = _iface.get;
        if (immediate && parent && parent.tx_ready)
            return send_ack(now);
        if (_ack_deadline == MonoTime.init)
        {
            _ack_deadline = now + ack_delay;
            rearm(now);
        }
    }

    void deliver(ubyte lane, const(ubyte)[] bytes, MonoTime now)
    {
        StackPacket message;
        message.init!RawFrame(bytes, now);
        message.pcp = cast(PCP)lane;
        incoming_packet(&message.packet);
    }

    void release_held()
    {
        foreach (ref h; _tables.held)
        {
            packet_free(h);
            h = null;
        }
    }

    void parent_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline || signal == StateSignal.destroyed)
            restart();
    }

    void unsubscribe_parent()
    {
        if (!_subscribed)
            return;
        if (BaseInterface parent = _iface.get)
        {
            parent.unsubscribe(&on_parent_packet);
            parent.unsubscribe(&parent_state_change);
            parent.release_tx_handler(&on_parent_tx);
        }
        _subscribed = false;
    }
}


private:

version (unittest) __gshared MonoTime g_test_time;

MonoTime now_time()
{
    version (unittest)
        if (g_test_time != MonoTime.init)
            return g_test_time;
    return getTime();
}


unittest
{
    enum lanes = RDPInterface.lanes;

    static final class TestLink : BaseInterface
    {
        enum type_name = "rdp-test-link";
    nothrow @nogc:

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestLink, id, flags);
            _state = State.running;
            set_l2mtu(100);
        }

        TestLink peer;
        Array!(Packet*) wire;
        uint sent;
        uint dropped;
        uint seed;
        ubyte loss_percent;

        override bool tx_ready() const
            => wire.empty;

        override int transmit(Packet* packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
        {
            ++sent;
            seed = seed * 1103515245 + 12345;
            if (loss_percent && (seed >> 16) % 100 < loss_percent)
            {
                ++dropped;
                packet_free(packet);
                return 0;
            }
            Packet* kept = packet_keep(packet);
            if (kept !is packet)
                packet_free(packet);
            wire ~= kept;
            return 0;
        }

        void receive(Packet* frame)
            => incoming_packet(frame);

        void pump()
        {
            do
            {
                while (!wire.empty)
                    peer.incoming_packet(wire.pop_front());
                invite_tx();
            }
            while (!wire.empty);
        }
    }

    struct Sink
    {
        uint count;
        uint bad;
        ubyte[lanes] next;
        Array!ushort order;

        void on_packet(const(Packet)* p, BaseInterface, PacketDirection, void*) nothrow @nogc
        {
            const(ubyte)[] bytes = cast(const(ubyte)[])p.data;
            ++count;
            ubyte lane = p.pcp;
            if (bytes.length < 3 || bytes[0] != next[lane]++ || (bytes[1] | bytes[2] << 8) != bytes.length)
                ++bad;
            foreach (i, b; bytes[3 .. $])
                if (b != cast(ubyte)(bytes[0] * 7 + i))
                    ++bad;
            order ~= cast(ushort)(lane << 8 | bytes[0]);
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

    g_test_time = MonoTime(1_000_000_000);
    scope(exit) g_test_time = MonoTime.init;

    TestLink la = Collection!TestLink().create("rdp-test-la");
    TestLink lb = Collection!TestLink().create("rdp-test-lb");
    RDPInterface a = Collection!RDPInterface().create("rdp-test-a");
    RDPInterface b = Collection!RDPInterface().create("rdp-test-b");
    scope(exit)
    {
        a.destroy();
        b.destroy();
        la.destroy();
        lb.destroy();
        Collection!BaseInterface().update_all();
    }
    la.peer = lb;
    lb.peer = la;
    la.seed = 7;
    lb.seed = 13;
    a.iface(la);
    b.iface(lb);
    a.test_start();
    b.test_start();
    assert(!a.established && !b.established);
    la.pump();
    lb.pump();
    la.pump();
    assert(a.established && b.established);
    assert(a.actual_mtu == 1496 && b.actual_mtu == 1496);

    Sink sink;
    PacketFilter raw = PacketFilter(PacketType.raw, PacketDirection.incoming);
    b.subscribe(&sink.on_packet, raw);
    Completions done;
    ubyte[lanes] seqs;

    static void settle(TestLink la, TestLink lb, RDPInterface a, RDPInterface b, uint steps = 4)
    {
        foreach (_; 0 .. steps)
        {
            la.pump();
            lb.pump();
            g_test_time = g_test_time + 25.msecs;
            a.on_timer(g_test_time);
            b.on_timer(g_test_time);
        }
    }

    // a small urgent message overtakes a long one mid-stream: the parent holds one frame, so the
    // second cut happens after the urgent message is queued
    assert(a.forward(make_message(seqs[PCP.be]++, 500, PCP.be), &done.done) > 0);
    assert(la.wire.length == 1 && a.in_flight == 1);
    assert(a.forward(make_message(seqs[PCP.nc]++, 12, PCP.nc), &done.done) > 0);
    assert(la.wire.length == 1 && a._queue.length == 2);
    la.pump();
    assert(sink.count == 2 && sink.bad == 0);
    assert(sink.order.length == 2 && sink.order[0] == (PCP.nc << 8 | 0) && sink.order[1] == (PCP.be << 8 | 0));
    assert(a.in_flight == 6 && done.complete == 0);
    settle(la, lb, a, b, 1);
    assert(done.complete == 2 && done.other == 0);
    assert(a.in_flight == 0 && a._cut.empty && a._queue.empty && b._rx_mask == 0 && b._assembly.empty);

    // a long low-priority message does not yield to lanes below it
    assert(a.forward(make_message(seqs[PCP.vo]++, 300, PCP.vo), &done.done) > 0);
    foreach (_; 0 .. 3)
        assert(a.forward(make_message(seqs[PCP.be]++, 20, PCP.be), &done.done) > 0);
    la.pump();
    assert(sink.count == 6 && sink.bad == 0 && sink.order[2] == (PCP.vo << 8 | 0));
    settle(la, lb, a, b, 1);
    assert(done.complete == 6);

    // an aborted message stops at the next frame and the lane carries on
    int big = a.forward(make_message(seqs[PCP.be], 500, PCP.be), &done.done);
    assert(big > 0 && a.in_flight == 1 && a._tx_partial == PCP.be);
    a.abort(big);
    assert(a._tx_partial == RDPInterface.no_lane && done.other == 1);
    assert(a.forward(make_message(seqs[PCP.be]++, 12, PCP.be), &done.done) > 0);
    la.pump();
    settle(la, lb, a, b, 1);
    assert(sink.count == 7 && sink.bad == 0 && b._rx_partial == RDPInterface.no_lane && b._assembly.empty);
    assert(done.complete == 7 && done.other == 1 && a.in_flight == 0);

    // sustained traffic across three lanes with 20% loss each way
    la.loss_percent = 20;
    lb.loss_percent = 20;
    static immutable PCP[3] pcps = [PCP.be, PCP.ca, PCP.vo];
    enum total = 90;
    uint submitted;
    uint steps;
    while ((sink.count < total + 7 || done.complete < total + 7) && steps < 20_000)
    {
        while (submitted < total && a.tx_ready)
        {
            PCP pcp = pcps[submitted % 3];
            ushort len = cast(ushort)(3 + (submitted * 37) % 230);
            assert(a.forward(make_message(seqs[pcp]++, len, pcp), &done.done) > 0);
            ++submitted;
        }
        la.pump();
        lb.pump();
        g_test_time = g_test_time + 5.msecs;
        a.on_timer(g_test_time);
        b.on_timer(g_test_time);
        ++steps;
    }
    assert(sink.count == total + 7 && sink.bad == 0);
    assert(done.complete == total + 7 && done.other == 1);
    assert(la.dropped > 0 && lb.dropped > 0 && a.retransmits > 0);
    assert(a.in_flight == 0 && b._rx_mask == 0 && b._rx_partial == RDPInterface.no_lane);
    assert(a._srtt_us > 0);

    // a producer waiting on tx_ready is invited back as the queue drains
    la.loss_percent = 0;
    lb.loss_percent = 0;
    struct Producer
    {
        uint remaining;
        ubyte* seq;
        bool offer(BaseInterface sink) nothrow @nogc
        {
            while (remaining && sink.tx_ready)
            {
                sink.forward(make_message((*seq)++, 40, PCP.ca));
                --remaining;
            }
            return remaining > 0;
        }
    }
    Producer producer = Producer(100, &seqs[PCP.ca]);
    a.tx_handler(&producer.offer);
    settle(la, lb, a, b, 40);
    assert(producer.remaining == 0 && sink.count == total + 107 && sink.bad == 0);

    // frames past a hole wait in their slots and are delivered in order when it fills
    assert(a.forward(make_message(seqs[PCP.ca]++, 80, PCP.ca), &done.done) > 0);
    Packet* hole = la.wire.pop_front();
    foreach (_; 0 .. 4)
        assert(a.forward(make_message(seqs[PCP.ca]++, 80, PCP.ca), &done.done) > 0);
    la.pump();
    assert(sink.count == total + 107 && b._rx_mask != 0);
    lb.receive(hole);
    assert(sink.count == total + 112 && sink.bad == 0 && b._rx_mask == 0);
    settle(la, lb, a, b);

    // a retransmitted frame acknowledges what its sender holds now, not what it held when first sent
    assert(a.forward(make_message(seqs[PCP.ca]++, 30, PCP.ca), &done.done) > 0);
    Packet* stale = la.wire.pop_front();
    foreach (i; 0 .. 3)
        assert(b.forward(make_message(cast(ubyte)i, 30, PCP.ca)) > 0);
    lb.pump();
    la.pump();
    g_test_time = g_test_time + 3.seconds;
    a.on_timer(g_test_time);
    assert(la.wire.length == 1 && ((cast(const(ubyte)[])la.wire[0].data)[1] & 31) == ((a._rx_next - 1) & 31));
    packet_free(stale);
    settle(la, lb, a, b);
    assert(sink.count == total + 113 && sink.bad == 0 && done.other == 1);

    // aborting a message under loss leaves the earlier message on its lane, and the session, intact
    assert(a.forward(make_message(seqs[PCP.be]++, 300, PCP.be), &done.done) > 0);
    Packet* lost_head = la.wire.pop_front();
    la.pump();
    assert(b._rx_mask != 0 && a._queue.empty);
    int doomed = a.forward(make_message(seqs[PCP.be], 300, PCP.be), &done.done);
    assert(doomed > 0 && a._tx_partial == PCP.be);
    a.abort(doomed);
    assert(a.forward(make_message(seqs[PCP.nc]++, 12, PCP.nc), &done.done) > 0);
    la.pump();
    assert(sink.count == total + 114 && sink.order[$ - 1] >> 8 == PCP.nc);
    lb.receive(lost_head);
    settle(la, lb, a, b, 8);
    assert(a.established && b.established && sink.bad == 0 && b._rx_partial == RDPInterface.no_lane);
    assert(sink.count == total + 115 && done.other == 2 && a.in_flight == 0);

    // a hole on one lane does not hold up another
    assert(a.forward(make_message(seqs[PCP.be]++, 80, PCP.be), &done.done) > 0);
    Packet* lost = la.wire.pop_front();
    assert(a.forward(make_message(seqs[PCP.nc]++, 30, PCP.nc), &done.done) > 0);
    la.pump();
    assert(sink.count == total + 116 && sink.order[$ - 1] >> 8 == PCP.nc && b._rx_mask != 0);
    lb.receive(lost);
    assert(sink.count == total + 117 && sink.bad == 0 && b._rx_mask == 0);
    settle(la, lb, a, b);

    // a lane's counter budget holds while a hole persists, so no chunk is ever taken for an old one
    assert(a.forward(make_message(seqs[PCP.bk]++, 3, PCP.bk), &done.done) > 0);
    Packet* gap = la.wire.pop_front();
    uint tiny = 1;
    foreach (_; 0 .. 50)
    {
        while (tiny < 200 && a.tx_ready)
        {
            assert(a.forward(make_message(seqs[PCP.bk]++, 3, PCP.bk), &done.done) > 0);
            ++tiny;
        }
        la.pump();
    }
    assert(a._tables.unacked[PCP.bk] < RDPInterface.lane_budget && a._tables.unacked[PCP.bk] > 100);
    lb.receive(gap);
    for (uint n = 0; (tiny < 200 || sink.count < total + 317) && n < 400; ++n)
    {
        while (tiny < 200 && a.tx_ready)
        {
            assert(a.forward(make_message(seqs[PCP.bk]++, 3, PCP.bk), &done.done) > 0);
            ++tiny;
        }
        settle(la, lb, a, b, 1);
    }
    settle(la, lb, a, b);
    assert(sink.count == total + 317 && sink.bad == 0 && done.other == 2 && a.in_flight == 0);

    // fragmented messages on four lanes over a lossy link, across seeds
    static immutable PCP[4] mixed = [PCP.be, PCP.ca, PCP.vo, PCP.bk];
    foreach (uint seed; 1 .. 9)
    {
        TestLink x = Collection!TestLink().create("rdp-stress-x");
        TestLink y = Collection!TestLink().create("rdp-stress-y");
        RDPInterface sp = Collection!RDPInterface().create("rdp-stress-p");
        RDPInterface sq = Collection!RDPInterface().create("rdp-stress-q");
        x.peer = y;
        y.peer = x;
        x.seed = seed;
        y.seed = seed * 7 + 3;
        sp.iface(x);
        sq.iface(y);
        sp.test_start();
        sq.test_start();
        x.pump();
        y.pump();
        x.pump();
        assert(sp.established && sq.established);
        Sink sk;
        sq.subscribe(&sk.on_packet, raw);
        Completions dn;
        ubyte[lanes] next;
        x.loss_percent = 25;
        y.loss_percent = 25;
        uint sent, step;
        while ((sk.count < 150 || dn.complete < 150) && step < 40_000)
        {
            while (sent < 150 && sp.tx_ready)
            {
                PCP pcp = mixed[(sent * 5 + seed) % 4];
                assert(sp.forward(make_message(next[pcp]++, cast(ushort)(3 + (sent * 37 + seed * 11) % 400), pcp), &dn.done) > 0);
                ++sent;
            }
            x.pump();
            y.pump();
            g_test_time = g_test_time + 5.msecs;
            sp.on_timer(g_test_time);
            sq.on_timer(g_test_time);
            ++step;
        }
        assert(sk.count == 150 && sk.bad == 0 && dn.complete == 150 && dn.other == 0 && sq.established);
        sq.unsubscribe(&sk.on_packet);
        sp.destroy();
        sq.destroy();
        x.destroy();
        y.destroy();
        Collection!BaseInterface().update_all();
    }

    // a peer that comes back with a new session nonce tears the old one down
    b.unsubscribe(&sink.on_packet);
    assert(b.shutdown() == CompletionStatus.complete);
    b.test_start();
    lb.pump();
    assert(!a.established);
}
