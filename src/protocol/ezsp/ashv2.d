module protocol.ezsp.ashv2;

import urt.array;
import urt.crc;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.result;
import urt.string;
import urt.time;

import manager.base;
import manager.collection;

import router.iface;
import router.stream;

//version = DebugASHMessageFlow;

alias ezsp_crc = calculate_crc!(Algorithm.crc16_ezsp);

nothrow @nogc:


//
// EZSP over UART wraps the command stream in a carrier protocol called "Asynchronous Serial Host" described here:
// https://www.silabs.com/documents/public/user-guides/ug101-uart-gateway-protocol-reference.pdf
//

class ASHInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("window", window),
                                 Prop!("retransmits", retransmits),
                                 Prop!("ack-timeout", ack_timeout));
nothrow @nogc:

    enum type_name = "ash";
    enum path = "/interface/ezsp/ash";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ASHInterface, id, flags);
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream stream)
    {
        if (_stream is stream)
            return;
        if (_subscribed)
        {
            _stream.release_rx_handler(&on_bytes);
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        _stream = stream;
        restart();
    }

    // ASH sliding-window depth: unacked DATA frames we'll keep on the wire (1-7). Reducing it
    // below the current flight count simply prevents new DATA until enough frames are acknowledged.
    final ubyte window() const pure
        => _max_in_flight;
    final StringResult window(ubyte value)
    {
        if (value < 1 || value > 7)
            return StringResult("window must be between 1 and 7");
        _max_in_flight = value;
        return StringResult.success;
    }

    final ubyte retransmits() const pure
        => _max_retransmits;
    final StringResult retransmits(ubyte value)
    {
        if (value < 1 || value > 4)
            return StringResult("retransmits must be between 1 and 4");
        _max_retransmits = value;
        return StringResult.success;
    }

    final ushort ack_timeout() const pure
        => _ack_timeout_ms;
    final StringResult ack_timeout(ushort value)
    {
        if (value < 50 || value > 3200)
            return StringResult("ack-timeout must be between 50ms and 3200ms");
        _ack_timeout_ms = value;
        return StringResult.success;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _stream !is null;

    override const(char)[] status_message() const
    {
        if (running)
            return super.status_message();
        if (!_stream || !_stream.running)
            return "Waiting for stream";
        if (!_connected)
            return "Waiting for RSTACK from NCP"; // RST attempt count is in the log + tx-packets
        return super.status_message();
    }

    override CompletionStatus startup()
    {
        if (!_stream || !_stream.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _stream.rx_handler = &on_bytes;
            _stream.subscribe(&stream_state_change);
            _subscribed = true;
        }

        MonoTime now = getTime();

        // periodically send RST until the NCP answers RSTACK (delivered via on_bytes)
        if (!_connected && now - _last_event > T_RSTACK_MAX.msecs)
        {
            ++_rst_attempts;
            // report what the NCP sent instead of an RSTACK: a stream of valid ASH DATA frames here
            // means the NCP is mid-session and our RST isn't getting through (usually a flow-control
            // misconfig starving the NCP's UART), not a dead dongle.
            if (_rx_since_rst)
            {
                log.warning("no RSTACK from '", _stream.name, "' (attempt ", _rst_attempts, "); NCP sent ",
                            _rx_since_rst, " bytes instead, first ", _rx_sample_len, ": ", cast(void[])_rx_sample[0 .. _rx_sample_len]);
                _rx_since_rst = 0;
                _rx_sample_len = 0;
            }
            else if (_rst_attempts <= 3 || _rst_attempts % 10 == 0)
                log.warning("no RSTACK from '", _stream.name, "' after ", _rst_attempts, " RST attempts; NCP is silent");
            else
                log.debug_("connecting on '", _stream.name, "'...");

            immutable ubyte[5] RST = [ ASH_CANCEL_BYTE, 0xC0, 0x38, 0xBC, ASH_FLAG_BYTE ];
            if (_stream.write(RST) != 5)
                add_tx_drop();
            else
                add_tx_frame(5);

            _last_event = now;

            // The reference protocol makes five reset attempts before declaring the serial path
            // unusable. Restart the stream as well as ASH: an ASH-only restart leaves a stopped or
            // saturated tty output queue intact and every later RST fails behind the same bytes.
            if (_rst_attempts >= 5)
            {
                log.error("no RSTACK after five attempts; restarting stream '", _stream.name, "'");
                _stream.restart();
                return CompletionStatus.continue_;
            }
        }

        return _connected ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _connected = false;

        _tx_seq = _rx_seq = 0;
        _tx_ack = 0;
        _rx_offset = 0;
        _rx_accum = 0;

        Message* next;
        while (_tx_in_flight)
        {
            next = _tx_in_flight.next;
            free_message(_tx_in_flight);
            _tx_in_flight = next;
        }
        while (_tx_queue)
        {
            next = _tx_queue.next;
            free_message(_tx_queue);
            _tx_queue = next;
        }
        _tx_queue_len = 0;

        _last_event = MonoTime();
        _rst_attempts = 0;
        _rx_since_rst = 0;
        _rx_sample_len = 0;
        _pending_cancel = false;
        _tx_stall_since = MonoTime();
        _reject_condition = false;

        if (_subscribed)
        {
            _stream.release_rx_handler(&on_bytes);
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        // rx arrives via on_bytes (the stream's rx_handler); only the retransmit timer remains.
        // no ack for the oldest unacked DATA frame within T_RX_ACK: resend it (and everything
        // behind it, since the NCP discards out-of-sequence frames) with the reTx bit set.
        MonoTime now = getTime();
        if (_tx_in_flight && now - _tx_in_flight.send_time >= retransmit_timeout(_tx_in_flight.retries))
        {
            if (_tx_in_flight.retries >= _max_retransmits)
            {
                log.error("link failed: no ack for seq ", _tx_in_flight.seq, " after ", _max_retransmits, " retransmits");
                _stream.restart();
                return;
            }
            resend_in_flight(now);
        }

        if (_tx_stall_since != MonoTime() && now - _tx_stall_since >= T_RSTACK_MAX.msecs)
        {
            log.error("serial output remained saturated; restarting stream '", _stream.name, "'");
            _stream.restart();
            return;
        }

        send_queued_messages();
    }

    override int transmit(ref Packet packet, MessageCallback, QueuePolicy)
    {
        if (packet.type != PacketType.raw)
            return -1;
        const(ubyte)[] message = cast(ubyte[])packet.data();
        if (message.length > ASH_MAX_MSG_LENGTH)
            return -1;

        // bound the tx queue; unbounded growth during a link stall just delays failure detection
        if (_tx_queue_len >= max_tx_queue)
        {
            log.warning("tx queue full (", max_tx_queue, "); rejecting frame");
            add_tx_drop();
            return -1;
        }

        Message* msg = alloc_message();
        msg.queue_time = getTime();
        msg.length = cast(ubyte)message.length;
        msg.buffer[0 .. message.length] = message[];
        if (tx_ahead() >= _max_in_flight || !send_msg(msg))
        {
            if (!_tx_queue)
                _tx_queue = msg;
            else
            {
                Message* m = _tx_queue;
                while (m.next)
                    m = m.next;
                m.next = msg;
                msg.next = null;
            }
            ++_tx_queue_len;
        }

        add_tx_frame(message.length);
        return 0;
    }

private:

    enum T_RSTACK_MAX           = 3200;

    enum ASH_CANCEL_BYTE        = 0x1A;
    enum ASH_FLAG_BYTE          = 0x7E;
    enum ASH_ESCAPE_BYTE        = 0x7D;
    enum ASH_SUBSTITUTE_BYTE    = 0x18;
    enum ASH_XON_BYTE           = 0x11;
    enum ASH_XOFF_BYTE          = 0x13;
    enum ASH_TIMEOUT            = -1;
    enum ASH_MAX_LENGTH         = 131;
    enum ASH_MAX_MSG_LENGTH     = 128;
    enum ASH_MAX_ENCODED_LENGTH = ASH_MAX_LENGTH * 2 + 1;

    enum max_tx_queue = 64;

    enum DataAction : ubyte
    {
        accept,
        acknowledge_duplicate,
        reject
    }

    Duration retransmit_timeout(ubyte retries) const
    {
        uint timeout = cast(uint)_ack_timeout_ms << retries;
        if (timeout > 3200)
            timeout = 3200;
        return msecs(timeout);
    }

    struct Message
    {
        Message* next;
        MonoTime queue_time;
        MonoTime send_time;
        ubyte seq;
        ubyte length;
        ubyte retries;
        ubyte[ASH_MAX_MSG_LENGTH] buffer;

        ubyte[] payload() pure nothrow @nogc
            => buffer[0 .. length];
    }

    ObjectRef!Stream _stream;
    MonoTime _last_event;
    MonoTime _tx_stall_since;
    uint _rst_attempts;     // RST frames sent without an RSTACK; surfaced in status_message
    uint _rx_since_rst;     // bytes received since the last RST while still unconnected
    ubyte _rx_sample_len;
    ubyte[64] _rx_sample;   // first bytes of that pre-connect RX, for diagnosis

    bool _connected;
    bool _subscribed;
    ubyte _ash_version;

    ubyte _max_in_flight = 3; // how many frames we will send without being ack-ed (1-7)
    ubyte _max_retransmits = 3; // resend attempts before declaring the link dead
    ushort _ack_timeout_ms = 800; // base T_RX_ACK; backs off 2x per retry

    ubyte _tx_seq; // the next frame to be sent
    ubyte _tx_ack = 0; // the next frame we expect an ack for

    ubyte tx_ahead() => _tx_seq >= _tx_ack ? cast(ubyte)(_tx_seq - _tx_ack) : cast(ubyte)(_tx_seq - _tx_ack + 8);

    ubyte _rx_seq = 0; // the next frame we expect to receive

    // TODO: received frames pending delivery because we missed one and sent a NAK
    Message* _tx_in_flight; // frames that have been sent but not yet ack-ed
    Message* _tx_queue;    // frames waiting to be sent
    Message* _free_list;
    ushort _tx_queue_len;
    bool _pending_cancel;   // a prior frame was truncated by CTS backpressure; prepend a CANCEL to
                            // the next frame so the NCP discards the leaked partial before parsing it
    bool _reject_condition;

    size_t _rx_offset;
    uint _rx_accum;     // stream bytes seen since the last completed frame (rx-rate stats)
    ubyte[ASH_MAX_ENCODED_LENGTH] _rx_buffer;

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void on_bytes(Stream, const(void)[] data, MonoTime rx_time)
    {
        const(ubyte)[] input = cast(const(ubyte)[])data;

        // before we're connected, keep a sample of whatever the NCP sends instead of RSTACK, so a
        // wedged/garbage dongle is diagnosable (logged each RST cycle before any hardware reset)
        if (!_connected)
        {
            _rx_since_rst += cast(uint)input.length;
            size_t take = _rx_sample.length - _rx_sample_len;
            if (take > input.length)
                take = input.length;
            _rx_sample[_rx_sample_len .. _rx_sample_len + take] = input[0 .. take];
            _rx_sample_len += cast(ubyte)take;
        }

        while (input.length)
        {
            size_t space = _rx_buffer.length - _rx_offset;
            if (space == 0)
            {
                add_rx_drop();
                reject_frame();
                _rx_offset = 0;
                space = _rx_buffer.length;
            }
            size_t take = input.length < space ? input.length : space;
            _rx_buffer[_rx_offset .. _rx_offset + take] = input[0 .. take];
            input = input[take .. $];
            parse_buffer(take, rx_time);
        }
    }

    void parse_buffer(size_t new_bytes, MonoTime now)
    {
        _rx_accum += cast(uint)new_bytes;

        // skip any XON/XOFF bytes
        size_t rxLen = _rx_offset;
        for (size_t i = _rx_offset; i < _rx_offset + new_bytes; ++i)
        {
            if (_rx_buffer[i] == ASH_XON_BYTE || _rx_buffer[i] == ASH_XOFF_BYTE)
                continue;
            _rx_buffer[rxLen++] = _rx_buffer[i];
        }

        // parse frames from stream delimited by 0x7E bytes
        size_t start = 0;
        size_t end = 0;
        bool inputError = false;
        outer: for (; end < rxLen; ++end)
        {
            if (_rx_buffer[end] == ASH_SUBSTITUTE_BYTE)
                inputError = true;
            else if (_rx_buffer[end] == ASH_CANCEL_BYTE)
            {
                start = end + 1;
                inputError = false;
            }

            if (_rx_buffer[end] != ASH_FLAG_BYTE)
                continue;

            if (inputError)
            {
                inputError = false;
                start = end + 1;
                add_rx_drop();
                reject_frame();
                continue;
            }

            // remove byte-stuffing from the frame
            size_t frameLen = unstuff_bytes(_rx_buffer[], start, end);
            if (frameLen == size_t.max)
            {
                start = end + 1;
                add_rx_drop();
                reject_frame();
                continue outer;
            }

            size_t frameStart = start;
            start = end + 1;

            if (frameLen < 3)
            {
                if (frameLen != 0)
                    add_rx_drop();
                continue;
            }

            // validate the frame
            size_t frameEnd = frameStart + frameLen - 2;
            ubyte[] frame = _rx_buffer[frameStart .. frameEnd];

            // check the crc
            const ushort crc = frame.ezsp_crc();
            if (_rx_buffer[frameEnd .. frameEnd + 2][0..2].bigEndianToNative!ushort != crc)
            {
                add_rx_drop();
                reject_frame();
                continue;
            }

            add_rx_frame(_rx_accum);
            _rx_accum = 0;
            process_frame(frame, now);
        }

        // shuffle any tail bytes (incomplete frames) to the start of the buffer...
        _rx_offset = rxLen - start;
        if (start > 0)
        {
            import urt.mem : memmove;
            memmove(_rx_buffer.ptr, _rx_buffer.ptr + start, _rx_offset);
        }
    }

    void process_frame(ubyte[] frame, MonoTime timestamp)
    {
        ubyte control = frame.popFront;

        // check for RSTACK
        if (control == 0xC1)
        {
            if (frame.length == 2)
            {
                _ash_version = frame[0];
                ubyte code = frame[1];

                if (_ash_version == 2)
                    _connected = true;

                if (_connected)
                {
                    log.info("connected, code=", code, " (after ", _rst_attempts, " RST attempts)");
                    _rst_attempts = 0;
                    _rx_since_rst = 0;
                    _rx_sample_len = 0;
                }
                else
                    log.warning("connection failed; unsupported ASH version=", _ash_version, " code=", code);
                return;
            }
        }
        if (!_connected)
            return;

        // check for ERROR
        if (control == 0xC2)
        {
            if (frame.length == 2)
            {
                ubyte ver = frame[0];
                ubyte code = frame[1];
                log.warning("received ERROR frame, code=", code);
            }
            _stream.restart();
            return;
        }

        bool data_frame = (control & 0x80) == 0;
        bool ack_frame = (control & 0xE0) == 0x80;
        bool nak_frame = (control & 0xE0) == 0xA0;
        if (!data_frame && !ack_frame && !nak_frame)
        {
            reject_frame();
            return;
        }

        ubyte ack_num = control & 7;
        int ack_ahead = ack_num >= _tx_ack ? ack_num - _tx_ack : ack_num - _tx_ack + 8;
        if (ack_ahead > tx_ahead())
        {
            reject_frame();
            return;
        }

        // ackNum is independent from the DATA payload and frmNum. It remains valid even when the
        // payload is a duplicate or out of sequence, so process it before DATA disposition.
        ack_in_flight(ack_num, timestamp);

        if (ack_frame)
        {
            version (DebugASHMessageFlow)
                log.tracef("<-- ACK [{0,02x}]", control);
            send_queued_messages();
            return;
        }
        if (nak_frame)
        {
            version (DebugASHMessageFlow)
                log.tracef("<-- NAK [{0,02x}]", control);
            if (_tx_in_flight)
            {
                log.debug_("NAK received; resending from seq ", _tx_in_flight.seq);
                resend_in_flight(getTime());
            }
            send_queued_messages();
            return;
        }

        // DATA frame
        if (frame.length < 3 || frame.length > ASH_MAX_MSG_LENGTH)
        {
            reject_frame();
            return;
        }

        ubyte frm_num = (control >> 4) & 7;
        bool retransmit = (control & 0x08) != 0;

        final switch (data_action(frm_num, _rx_seq, retransmit))
        {
            case DataAction.acknowledge_duplicate:
                ash_ack(_rx_seq, false);
                return;
            case DataAction.reject:
                reject_frame();
                return;
            case DataAction.accept:
                break;
        }

        ubyte[] data = void;
        ubyte[ASH_MAX_LENGTH] tmp = void;
        data = tmp[0 .. frame.length];

        randomise(frame, data);

        version (DebugASHMessageFlow)
            log.tracef("<-- [x{0, 02x}]: {1}", control, cast(void[])data);

        _rx_seq = (_rx_seq + 1) & 7;
        _reject_condition = false;
        ash_ack(_rx_seq, false);
        send_queued_messages();

        if (data.length > 0)
        {
            Packet p;
            p.init!RawFrame(data, timestamp);
            incoming_packet(p);
        }
    }

    void resend_in_flight(MonoTime now)
    {
        for (Message* m = _tx_in_flight; m; m = m.next)
        {
            log.warning("retransmit seq ", m.seq, " (attempt ", m.retries + 1, " of ", _max_retransmits, ")");
            m.send_time = now;
            if (!ash_send(m.payload(), m.seq, _rx_seq, true))
                break;
            ++m.retries;
        }
    }

    void reject_frame()
    {
        if (!_connected || _reject_condition)
            return;
        _reject_condition = true;
        ash_nak(_rx_seq, false);
    }

    void ack_in_flight(ubyte ack_num, MonoTime timestamp)
    {
        while (_tx_ack != ack_num)
        {
            if (!_tx_in_flight || _tx_in_flight.seq != _tx_ack)
            {
                log.errorf("ASH acknowledgement stream corrupt: expected seq {0}, got ack {1}; restarting link", _tx_ack, ack_num);
                restart();
                return;
            }

            Message* msg = _tx_in_flight;
            update_time_stats(msg, timestamp);
            _tx_in_flight = _tx_in_flight.next;
            free_message(msg);

            _tx_ack = (_tx_ack + 1) & 7;
        }

    }

    void send_queued_messages()
    {
        while (_tx_queue && tx_ahead < _max_in_flight)
        {
            Message* next = _tx_queue.next;
            if (!send_msg(_tx_queue))
                break;
            _tx_queue = next;
            --_tx_queue_len;
        }
    }

    Message* alloc_message()
    {
        Message* msg;
        if (_free_list)
        {
            msg = _free_list;
            _free_list = _free_list.next;
            msg.seq = 0;
            msg.next = null;
        }
        else
            msg = defaultAllocator.allocT!Message();
        msg.send_time = MonoTime();
        return msg;
    }

    void free_message(Message* message)
    {
        message.next = _free_list;
        _free_list = message;
    }

    void update_time_stats(Message* msg, MonoTime now)
    {
        uint wait_us = cast(uint)(msg.send_time - msg.queue_time).as!"usecs";
        uint service_us = cast(uint)(now - msg.send_time).as!"usecs";

        update_service_times(wait_us, service_us);
    }

    bool send_msg(Message* msg)
    {
        if (!_connected || !ash_send(msg.payload(), _tx_seq, _rx_seq, false))
            return false;

        msg.next = null;
        msg.send_time = getTime();
        msg.seq = _tx_seq;
        msg.retries = 0;
        if (!_tx_in_flight)
            _tx_in_flight = msg;
        else
        {
            Message* m = _tx_in_flight;
            while (m.next)
                m = m.next;
            m.next = msg;
        }
        _tx_seq = (_tx_seq + 1) & 7;

        return true;
    }

    bool ash_ack(ubyte ack, bool ready, bool nak = false)
    {
        ubyte control = 0x80 | (nak ? 0x20 : 0) | (ready << 3) | (ack & 7);

        version (DebugASHMessageFlow)
            log.tracef("--> {0} [x{1, 02x}]", nak ? "NAK" : "ACK", control);

        ubyte[4] ack_msg = [ control, 0, 0, ASH_FLAG_BYTE ];
        ack_msg[1..3] = ack_msg[0..1].ezsp_crc().nativeToBigEndian;
        return ash_emit(ack_msg[]);
    }

    bool ash_nak(ubyte ack, bool ready)
        => ash_ack(ack, ready, true);

    bool ash_send(const(ubyte)[] msg, ubyte seq, ubyte ack, bool retransmit)
    {
        ubyte[256] frame = void;

        ubyte control = ((seq & 7) << 4) | (ack & 7) | (retransmit << 3);
        frame[0] = control;

        randomise(msg, frame[1..$]);

        ushort crc = frame[0 .. 1 + msg.length].ezsp_crc();
        frame[1 + msg.length .. 3 + msg.length][0..2] = crc.nativeToBigEndian;

        ubyte[ASH_MAX_ENCODED_LENGTH] stuffed = void;
        size_t len = stuff_bytes(frame[0 .. 1 + msg.length + 2], stuffed[]);
        stuffed[len++] = 0x7E;

        version (DebugASHMessageFlow)
            log.tracef("--> [x{0, 02x}]: {1}", control, cast(void[])msg);

        return ash_emit(stuffed[0 .. len]);
    }

    // Write one complete ASH frame, recovering transparently from flow-control truncation. A short
    // write means CTS backpressure filled the kernel TX buffer mid-frame, leaking a headless partial
    // to the NCP; we flag it and prepend a CANCEL (0x1A) to the next frame so the NCP discards that
    // partial before parsing. The flag only clears once a frame is written in full (CANCEL included),
    // so a truncated CANCEL just re-arms for the following frame.
    bool ash_emit(const(ubyte)[] frame)
    {
        ubyte[ASH_MAX_ENCODED_LENGTH + 1] buf = void;
        size_t n = 0;
        if (_pending_cancel)
            buf[n++] = ASH_CANCEL_BYTE;
        buf[n .. n + frame.length] = frame[];
        n += frame.length;

        if (_stream.write(buf[0 .. n]) != n)
        {
            _pending_cancel = true;
            if (_tx_stall_since == MonoTime())
                _tx_stall_since = getTime();
            add_tx_drop();
            return false;
        }

        _pending_cancel = false;
        _tx_stall_since = MonoTime();
        add_tx_frame(frame.length);
        return true;
    }

    static size_t stuff_bytes(const(ubyte)[] input, ubyte[] output) pure
    {
        size_t len;
        foreach (b; input)
        {
            if (b == ASH_FLAG_BYTE || b == ASH_ESCAPE_BYTE || b == ASH_XON_BYTE ||
                b == ASH_XOFF_BYTE || b == ASH_SUBSTITUTE_BYTE || b == ASH_CANCEL_BYTE)
            {
                output[len++] = ASH_ESCAPE_BYTE;
                output[len++] = b ^ 0x20;
            }
            else
                output[len++] = b;
        }
        return len;
    }

    static DataAction data_action(ubyte frame_number, ubyte expected, bool retransmit) pure
    {
        if (frame_number == expected)
            return DataAction.accept;
        return retransmit ? DataAction.acknowledge_duplicate : DataAction.reject;
    }

    static size_t unstuff_bytes(ubyte[] buffer, size_t start, size_t end) pure
    {
        size_t len;
        for (size_t i = start; i < end; ++i)
        {
            ubyte b = buffer[i];
            if (b == ASH_ESCAPE_BYTE)
            {
                if (++i == end)
                    return size_t.max;
                b = buffer[i] ^ 0x20;
            }
            buffer[start + len++] = b;
        }
        return len;
    }

    static void randomise(const(ubyte)[] data, ubyte[] buffer) pure
    {
        ubyte rand = 0x42;
        foreach (i, b; data)
        {
            buffer[i] = b ^ rand;
            ubyte b1 = cast(ubyte)-(rand & 1) & 0xB8;
            rand = (rand >> 1) ^ b1;
        }
    }
}

unittest
{
    immutable ubyte[6] reserved = [ 0x7E, 0x7D, 0x11, 0x13, 0x18, 0x1A ];
    ubyte[131] original;
    foreach (i, ref b; original)
        b = reserved[i % reserved.length];

    ubyte[263] encoded = void;
    size_t encoded_len = ASHInterface.stuff_bytes(original[], encoded[]);
    assert(encoded_len == original.length * 2);

    size_t decoded_len = ASHInterface.unstuff_bytes(encoded[], 0, encoded_len);
    assert(decoded_len == original.length);
    assert(encoded[0 .. decoded_len] == original[]);

    encoded[0] = 0x7D;
    assert(ASHInterface.unstuff_bytes(encoded[], 0, 1) == size_t.max);

    assert(ASHInterface.data_action(3, 3, false) == ASHInterface.DataAction.accept);
    assert(ASHInterface.data_action(2, 3, true) == ASHInterface.DataAction.acknowledge_duplicate);
    assert(ASHInterface.data_action(4, 3, false) == ASHInterface.DataAction.reject);
}
