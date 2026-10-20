module router.iface.reliable;

// Reliable message delivery over any datagram parent (UDP, raw 802.15.4, a framed serial trunk): a
// selective-repeat ARQ with a 16-frame window, tuned for media of hundreds of kbit/s and frames of
// hundreds of bytes. Consumers submit raw packets up to max-message; the layer packs them into parent
// frames, fragments the ones that do not fit, and delivers them whole in order within their lane.
// The lane is the packet's PCP: lanes are ordered independently, so a loss on one never stalls another
// and a small urgent message rides at the head of the next frame cut while a long one streams.
//
// Frame: [type:3 seq:5][sack:1 rsvd:2 ack:5] ([sack bitmap:16 LE])? payload
//   type 0 data, 1 ack-only, 2 open, 3 open-ack, 4 reset. ack is the cumulative point, bit n of the
//   bitmap acknowledges ack+2+n. open and open-ack carry [nonce][max-message/8] and their seq is the
//   initial sequence; the first data frame follows it.
// Item: [rsvd:1 lane:3 ext:1 len:3] ([len low:8])? [lane counter:8] bytes
//   len is the bytes of the message still to come from this chunk on. A chunk short of len ends its
//   frame and the lane's next chunk continues the message, so at most one message is partial at a
//   time and the receiver assembles with one buffer.
//
// TODO: pause flag for flow control (a stream tunnel into a slow sink), rsvd bit 6 of byte 1
// TODO: HMAC trailer as a session property; it also closes the 5-bit straggler window on UDP
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


final class ReliableInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("window", window),
                                 Prop!("max-message", max_message),
                                 Prop!("rto-min", rto_min),
                                 Prop!("retries", retries),
                                 Prop!("established", established, "status", "d"),
                                 Prop!("rtt", rtt, "status"),
                                 Prop!("rto", rto, "status"),
                                 Prop!("retransmits", retransmits, "traffic"));
nothrow @nogc:

    ~this() {}

    enum type_name = "reliable";
    enum path = "/interface/reliable";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ReliableInterface, id, flags);
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

    final Duration rto_min() const pure
        => _rto_min;
    final void rto_min(Duration value)
    {
        _rto_min = value;
        mark_set!(typeof(this), "rto-min")();
    }

    final ubyte retries() const pure
        => _max_retries;
    final const(char)[] retries(ubyte value)
    {
        if (value == 0)
            return "retries must be at least 1";
        _max_retries = value;
        mark_set!(typeof(this), "retries")();
        return null;
    }

    final bool established() const pure
        => _session == Session.established;
    final Milliseconds rtt() const
        => Milliseconds(float(_srtt_us) / 1000);
    final Milliseconds rto() const
        => Milliseconds(float(_rto_us) / 1000);
    final ulong retransmits() const pure
        => _retransmits;

    // API...

    override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        foreach (i, ref it; _queue[])
        {
            if (it.tag != msg_handle)
                continue;
            if (it.sent)
                return;
            TxItem item = it;
            _queue.remove(i);
            finish(item, reason);
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

        PacketFilter filter = PacketFilter(PacketType.unknown, PacketDirection.incoming);
        parent.subscribe(&on_parent_packet, filter);
        parent.subscribe(&parent_state_change);
        _subscribed = true;

        _nonce = cast(ubyte)rand();
        _isn = cast(ubyte)(rand() & seq_mask);
        _tx_una = _tx_next = next_seq(_isn);
        _tx_lane[] = 0;
        _lane_unacked[] = 0;
        _tx_partial = no_lane;
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
        foreach (ref f; _frames)
        {
            packet_free(f.packet);
            f.packet = null;
        }
        while (!_queue.empty)
            finish(_queue.pop_back(), MessageState.aborted);
        while (!_cut.empty)
            finish(_cut.pop_back(), MessageState.aborted);
        release_parked();
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
        int tag = _tags.alloc();
        if (tag < 0)
            return drop_tx(kept);
        _queue ~= TxItem(kept, callback, 0, cast(ubyte)tag, kept.pcp, 0);
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
    enum lane_unacked_max = 127;
    enum max_queue = 32;
    enum max_parked = 64;
    enum ack_every = 8;
    enum ack_delay = 20.msecs;
    enum uint initial_rto_us = 200_000;
    enum uint rto_max_us = 2_000_000;
    enum uint clock_granularity_us = 1000;

    enum ubyte type_data = 0;
    enum ubyte type_ack = 1;
    enum ubyte type_open = 2;
    enum ubyte type_open_ack = 3;
    enum ubyte type_reset = 4;
    enum ubyte flag_sack = 0x80;

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
        ubyte tag;
        ubyte lane;
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

    struct Parked
    {
        Packet* packet;
        ushort offset;
        ushort length;
        ushort declared;
        ubyte lane;
        ubyte counter;
    }

    static immutable ubyte[lanes] scheduling_order = [7, 6, 5, 4, 3, 2, 0, 1];

    ObjectRef!BaseInterface _iface;
    Array!TxItem _queue;
    Array!TxItem _cut;
    Array!Parked _parked;
    Array!ubyte _assembly;
    Frame[window_max] _frames;
    TagAllocator _tags;
    MonoTime _timer_when;
    MonoTime _ack_deadline;
    MonoTime _open_deadline;
    Duration _rto_min = 20.msecs;
    ulong _retransmits;
    uint _srtt_us;
    uint _rttvar_us;
    uint _rto_us = initial_rto_us;
    ushort _max_message = default_max_message;
    ushort _session_max = default_max_message;
    ushort _rx_mask;
    ushort _rx_remaining;
    ubyte[lanes] _tx_lane;
    ubyte[lanes] _rx_lane;
    ubyte[lanes] _lane_unacked;
    ubyte _window = window_max;
    ubyte _max_retries = 8;
    ubyte _isn;
    ubyte _nonce;
    ubyte _peer_nonce;
    ubyte _tx_una;
    ubyte _tx_next;
    ubyte _rx_next;
    ubyte _rx_since_ack;
    ubyte _tx_partial = no_lane;
    ubyte _rx_partial = no_lane;
    ubyte _backoff;
    ubyte _open_tries;
    Session _session;
    bool _subscribed;
    bool _timer_armed;
    bool _ack_pending;

    static ubyte next_seq(ubyte seq) pure
        => cast(ubyte)((seq + 1) & seq_mask);

    static uint seq_distance(ubyte from, ubyte to) pure
        => (to - from) & seq_mask;

    uint in_flight() const pure
        => seq_distance(_tx_una, _tx_next);

    static size_t item_header_size(size_t len) pure
        => len < 8 ? 2 : 3;

    static size_t write_item(ubyte[] buf, size_t pos, ubyte lane, size_t len, ubyte counter) pure
    {
        if (len < 8)
            buf[pos++] = cast(ubyte)(lane << 4 | len);
        else
        {
            buf[pos++] = cast(ubyte)(lane << 4 | 8 | len >> 8);
            buf[pos++] = cast(ubyte)len;
        }
        buf[pos++] = counter;
        return pos;
    }

    size_t write_header(ubyte[] buf, ubyte type, ubyte seq) const pure
    {
        buf[0] = cast(ubyte)(type << 5 | seq);
        ubyte ack = cast(ubyte)((_rx_next - 1) & seq_mask);
        ushort sack = _rx_mask >> 1;
        if (!sack)
        {
            buf[1] = ack;
            return 2;
        }
        buf[1] = cast(ubyte)(flag_sack | ack);
        buf[2] = cast(ubyte)sack;
        buf[3] = cast(ubyte)(sack >> 8);
        return 4;
    }


    void pump(MonoTime now)
    {
        while (cut_frame(now)) {}
        if (!_queue.empty && _session == Session.established && in_flight < _window)
        {
            BaseInterface parent = _iface.get;
            if (parent && !parent.tx_ready && parent.tx_handler !is &on_parent_tx)
                parent.tx_handler(&on_parent_tx);
        }
        rearm(now);
    }

    bool on_parent_tx(BaseInterface)
    {
        pump(now_time());
        return !_queue.empty && in_flight < _window;
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
        if (_session != Session.established || in_flight >= _window || _queue.empty)
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
        size_t pos = write_header(buf, type_data, _tx_next);
        ubyte[lanes] chunks;
        bool wrote;

        foreach (lane; scheduling_order)
        {
            if (lane == _tx_partial)
                continue;
            for (size_t i = 0; i < _queue.length;)
            {
                TxItem* it = &_queue[i];
                if (it.lane != lane)
                {
                    ++i;
                    continue;
                }
                if (_lane_unacked[lane] + chunks[lane] >= lane_unacked_max)
                    break;
                size_t len = it.packet.length;
                if (pos + item_header_size(len) + len > buf.length)
                    break;
                pos = write_item(buf, pos, lane, len, _tx_lane[lane]++);
                buf[pos .. pos + len] = cast(const(ubyte)[])it.packet.data;
                pos += len;
                ++chunks[lane];
                wrote = true;
                it.last_seq = _tx_next;
                add_tx_frame(len);
                _cut ~= *it;
                _queue.remove(i);
            }
        }

        if (_tx_partial != no_lane)
        {
            ubyte lane = _tx_partial;
            TxItem* it = &_queue[head_index(lane)];
            size_t remaining = it.packet.length - it.sent;
            size_t hdr = item_header_size(remaining);
            if (pos + hdr < buf.length && _lane_unacked[lane] + chunks[lane] < lane_unacked_max)
            {
                size_t take = buf.length - pos - hdr;
                if (take > remaining)
                    take = remaining;
                pos = write_item(buf, pos, lane, remaining, _tx_lane[lane]++);
                buf[pos .. pos + take] = cast(const(ubyte)[])it.packet.data[it.sent .. it.sent + take];
                pos += take;
                it.sent += cast(ushort)take;
                ++chunks[lane];
                wrote = true;
                if (take == remaining)
                {
                    it.last_seq = _tx_next;
                    add_tx_frame(it.packet.length);
                    _cut ~= *it;
                    _queue.remove(head_index(lane));
                    _tx_partial = no_lane;
                }
            }
        }
        else
        {
            foreach (lane; scheduling_order)
            {
                size_t i = head_index(lane);
                if (i == size_t.max || _lane_unacked[lane] + chunks[lane] >= lane_unacked_max)
                    continue;
                TxItem* it = &_queue[i];
                size_t len = it.packet.length;
                size_t hdr = item_header_size(len);
                if (pos + hdr >= buf.length)
                    continue;
                size_t take = buf.length - pos - hdr;
                if (take >= len)
                    continue;
                pos = write_item(buf, pos, lane, len, _tx_lane[lane]++);
                buf[pos .. pos + take] = cast(const(ubyte)[])it.packet.data[0 .. take];
                pos += take;
                it.sent = cast(ushort)take;
                ++chunks[lane];
                wrote = true;
                _tx_partial = lane;
                break;
            }
        }

        if (!wrote)
        {
            packet_free(frame);
            return false;
        }

        frame.truncate(pos);
        Frame* slot = &_frames[_tx_next & (window_max - 1)];
        *slot = Frame(frame, now, 0, false, false, chunks);
        foreach (lane, c; chunks)
            _lane_unacked[lane] += c;
        _tx_next = next_seq(_tx_next);
        acked_out();
        send_frame(slot, now);
        return true;
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
            len = write_header(buf, type_ack, 0);
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
        _rx_since_ack = 0;
        _ack_deadline = MonoTime.init;
    }

    void send_ack(MonoTime now)
    {
        send_control(type_ack, now);
        acked_out();
    }

    void finish(TxItem item, MessageState state)
    {
        packet_free(item.packet);
        _tags.free(item.tag);
        if (item.callback)
            item.callback(item.tag, state);
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
                Frame* f = &_frames[(_tx_una + k) & (window_max - 1)];
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
        Frame* f = &_frames[seq & (window_max - 1)];
        if (!f.packet)
            return;
        if (f.sent > newest)
        {
            newest = f.sent;
            clean = !f.retransmitted;
        }
        foreach (lane, c; f.chunks)
            _lane_unacked[lane] -= c;
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
            TxItem item = _cut[i];
            _cut.remove(i);
            finish(item, MessageState.complete);
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
        uint floor = cast(uint)_rto_min.as!"usecs";
        if (rto < floor)
            rto = floor;
        if (rto > rto_max_us)
            rto = rto_max_us;
        _rto_us = rto;
        _backoff = 0;
        mark_set!(typeof(this), [ "rtt", "rto" ])();
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
                if (f.retries >= _max_retries)
                {
                    log.warning("peer unresponsive: no ack after ", _max_retries, " retransmits");
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
                    on_data(seq, frame[pos .. $], p, now);
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
        _rx_lane[] = 0;
        _rx_partial = no_lane;
        _assembly.clear();
        release_parked();
        acked_out();
        _session_max = peer_max < _max_message ? peer_max : _max_message;
        set_l2mtu(_session_max);
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

    void on_data(ubyte seq, const(ubyte)[] items, const(Packet)* p, MonoTime now)
    {
        uint d = seq_distance(_rx_next, seq);
        if (d >= window_max || (_rx_mask & (1 << d)))
            return request_ack(now, true);
        if (!parse_items(items, p, now) || _session != Session.established)
            return;
        _rx_mask |= cast(ushort)(1 << d);
        while (_rx_mask & 1)
        {
            _rx_mask >>= 1;
            _rx_next = next_seq(_rx_next);
        }
        request_ack(now, _rx_mask != 0 || ++_rx_since_ack >= ack_every);
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

    bool parse_items(const(ubyte)[] items, const(Packet)* p, MonoTime now)
    {
        Packet* kept;
        size_t pos;
        while (pos < items.length)
        {
            ubyte b = items[pos++];
            ubyte lane = (b >> 4) & 7;
            size_t len = b & 7;
            if (b & 8)
            {
                if (pos >= items.length)
                    break;
                len = len << 8 | items[pos++];
            }
            if ((b & 0x80) || pos >= items.length)
                break;
            ubyte counter = items[pos++];
            size_t take = items.length - pos;
            if (take > len)
                take = len;
            byte age = cast(byte)(counter - _rx_lane[lane]);
            if (age == 0 && can_consume(lane, take, len))
            {
                consume_chunk(lane, items[pos .. pos + take], len, now);
                if (_session != Session.established)
                    return false;
                drain_parked(lane, now);
            }
            else if (age >= 0 && !parked_has(lane, counter))
            {
                if (_parked.length >= max_parked)
                    return false;
                kept = kept ? packet_retain(kept) : packet_retain(p);
                if (!kept)
                    return false;
                _parked ~= Parked(kept, cast(ushort)(pos + (items.ptr - cast(const(ubyte)*)p.data.ptr)), cast(ushort)take, cast(ushort)len, lane, counter);
            }
            pos += take;
        }
        if (pos != items.length)
        {
            log.warning("malformed frame from peer; resetting session");
            fail_session(now);
            return false;
        }
        return true;
    }

    // a second long message waits for the partial one, however its lane fares, so one buffer assembles
    bool can_consume(ubyte lane, size_t length, size_t declared) const pure
        => lane == _rx_partial || length == declared || _rx_partial == no_lane;

    bool parked_has(ubyte lane, ubyte counter) const pure
    {
        foreach (ref pk; _parked[])
            if (pk.lane == lane && pk.counter == counter)
                return true;
        return false;
    }

    void consume_chunk(ubyte lane, const(ubyte)[] bytes, size_t declared, MonoTime now)
    {
        ++_rx_lane[lane];
        if (_rx_partial == lane)
        {
            if (declared != _rx_remaining || bytes.length > declared)
                return protocol_error(now);
            _assembly ~= bytes;
            _rx_remaining -= cast(ushort)bytes.length;
            if (_rx_remaining)
                return;
            _rx_partial = no_lane;
            deliver(lane, _assembly[], now);
            _assembly.clear();
            foreach (other; 0 .. lanes)
                drain_parked(cast(ubyte)other, now);
            return;
        }
        if (bytes.length == declared)
            return deliver(lane, bytes, now);
        if (declared > _session_max)
            return protocol_error(now);
        _rx_partial = lane;
        _rx_remaining = cast(ushort)(declared - bytes.length);
        _assembly ~= bytes;
    }

    void protocol_error(MonoTime now)
    {
        log.warning("peer violated the message framing; resetting session");
        fail_session(now);
    }

    void deliver(ubyte lane, const(ubyte)[] bytes, MonoTime now)
    {
        StackPacket message;
        message.init!RawFrame(bytes, now);
        message.pcp = cast(PCP)lane;
        incoming_packet(&message.packet);
    }

    void drain_parked(ubyte lane, MonoTime now)
    {
        bool found = true;
        while (found && _session == Session.established)
        {
            found = false;
            foreach (i, ref pk; _parked[])
            {
                if (pk.lane != lane)
                    continue;
                byte age = cast(byte)(pk.counter - _rx_lane[lane]);
                if (age < 0)
                {
                    packet_free(pk.packet);
                    _parked.remove(i);
                    found = true;
                    break;
                }
                if (age > 0 || !can_consume(lane, pk.length, pk.declared))
                    continue;
                Parked chunk = pk;
                _parked.remove(i);
                const(ubyte)[] bytes = (cast(const(ubyte)[])chunk.packet.data)[chunk.offset .. chunk.offset + chunk.length];
                consume_chunk(lane, bytes, chunk.declared, now);
                packet_free(chunk.packet);
                found = true;
                break;
            }
        }
    }

    void release_parked()
    {
        foreach (ref pk; _parked[])
            packet_free(pk.packet);
        _parked.clear();
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
    enum lanes = ReliableInterface.lanes;

    static final class TestLink : BaseInterface
    {
        enum type_name = "reliable-test-link";
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

    TestLink la = Collection!TestLink().create("reliable-test-la");
    TestLink lb = Collection!TestLink().create("reliable-test-lb");
    ReliableInterface a = Collection!ReliableInterface().create("reliable-test-a");
    ReliableInterface b = Collection!ReliableInterface().create("reliable-test-b");
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

    // a small urgent message overtakes a long one mid-stream: the parent holds one frame, so the
    // second cut happens after the urgent message is queued
    assert(a.forward(make_message(0, 500, PCP.be), &done.done) > 0);
    assert(la.wire.length == 1 && a.in_flight == 1);
    assert(a.forward(make_message(0, 12, PCP.nc), &done.done) > 0);
    assert(la.wire.length == 1 && a._queue.length == 2);
    la.pump();
    assert(sink.count == 2 && sink.bad == 0);
    assert(sink.order.length == 2);
    assert(sink.order[0] == 1792);
    assert(sink.order[1] == 0);
    assert(a.in_flight == 6 && done.complete == 0);
    g_test_time = g_test_time + 25.msecs;
    b.on_timer(g_test_time);
    lb.pump();
    assert(done.complete == 2 && done.other == 0);
    assert(a.in_flight == 0 && a._cut.empty && a._queue.empty && b._parked.empty && b._assembly.empty);

    // sustained traffic across three lanes with 20% loss each way
    la.loss_percent = 20;
    lb.loss_percent = 20;
    static immutable PCP[3] pcps = [PCP.be, PCP.ca, PCP.vo];
    ubyte[lanes] seqs;
    seqs[PCP.be] = 1;
    enum total = 90;
    uint submitted;
    uint steps;
    while ((sink.count < total + 2 || done.complete < total + 2) && steps < 20_000)
    {
        while (submitted < total && a.tx_ready)
        {
            PCP pcp = pcps[submitted % 3];
            ushort len = cast(ushort)(3 + (submitted * 37) % 230);
            int r = a.forward(make_message(seqs[pcp]++, len, pcp), &done.done);
            assert(r > 0);
            ++submitted;
        }
        la.pump();
        lb.pump();
        g_test_time = g_test_time + 5.msecs;
        a.on_timer(g_test_time);
        b.on_timer(g_test_time);
        ++steps;
    }
    assert(sink.count == total + 2 && sink.bad == 0);
    assert(done.complete == total + 2 && done.other == 0);
    assert(la.dropped > 0 && lb.dropped > 0 && a.retransmits > 0);
    assert(a.in_flight == 0 && b._parked.empty && b._rx_partial == ReliableInterface.no_lane);
    assert(a._srtt_us > 0);

    // a peer that comes back with a new session nonce tears the old one down
    la.loss_percent = 0;
    lb.loss_percent = 0;
    b.unsubscribe(&sink.on_packet);
    assert(b.shutdown() == CompletionStatus.complete);
    b.test_start();
    lb.pump();
    assert(!a.established);
}
