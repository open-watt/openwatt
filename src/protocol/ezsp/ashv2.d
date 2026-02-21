module protocol.ezsp.ashv2;

import urt.array;
import urt.crc;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
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

struct ASHFrame
{
    enum Type = PacketType.ash;
}

class ASHInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("stream", stream)() ];
nothrow @nogc:

    enum type_name = "ash";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ASHInterface, name.move, flags);
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
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        _stream = stream;
        restart();
    }

    // BaseInterface overrides...

    override bool validate() const pure
        => _stream !is null;

    override CompletionStatus validating()
    {
        _stream.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_stream || !_stream.running)
            return CompletionStatus.continue_;

        MonoTime now = getTime();

        // periodically send RST until we get RSTACK
        if (!_connected && now - _last_event > T_RSTACK_MAX.msecs)
        {
            writeDebug("ASHv2: connecting on '", _stream.name, "'...");

            immutable ubyte[5] RST = [ ASH_CANCEL_BYTE, 0xC0, 0x38, 0xBC, ASH_FLAG_BYTE ];
            if (_stream.write(RST) != 5)
                ++_status.send_dropped;
            else
            {
                ++_status.send_packets;
                _status.send_bytes += 5;
            }

            _last_event = now;
        }

        // poll for incoming RSTACK response
        service_stream();

        if (_connected)
        {
            _stream.subscribe(&stream_state_change);
            _subscribed = true;
            return CompletionStatus.complete;
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _connected = false;

        _tx_seq = _rx_seq = 0;
        _tx_ack = 0;
        _rx_offset = 0;

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

        _last_event = MonoTime();

        if (_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        service_stream();

        // retransmit timeout
        MonoTime now = getTime();
        if (_tx_in_flight && now - _tx_in_flight.send_time >= 250.msecs)
        {
            ash_nak(_tx_in_flight.seq, false);
            _tx_in_flight.send_time = now;
        }
    }

protected:
    override int transmit(ref Packet packet, MessageCallback)
    {
        if (packet.type != PacketType.ash)
            return -1;
        const(ubyte)[] message = cast(ubyte[])packet.data();
        if (message.length > ASH_MAX_MSG_LENGTH)
            return -1;

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
        }

        ++_status.send_packets;
        _status.send_bytes += message.length;
        return 0;
    }

    void stream_state_change(BaseObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
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

    struct Message
    {
        Message* next;
        MonoTime queue_time;
        MonoTime send_time;
        ubyte seq;
        ubyte length;
        ubyte[ASH_MAX_MSG_LENGTH] buffer;

        ubyte[] payload() pure nothrow @nogc
            => buffer[0 .. length];
    }

    ObjectRef!Stream _stream;
    MonoTime _last_event;

    bool _connected;
    bool _subscribed;
    ubyte _ash_version;

    ubyte _max_in_flight = 3; // how many frames we will send without being ack-ed (1-7)

    ubyte _tx_seq; // the next frame to be sent
    ubyte _tx_ack = 0; // the next frame we expect an ack for

    ubyte tx_ahead() => _tx_seq >= _tx_ack ? cast(ubyte)(_tx_seq - _tx_ack) : cast(ubyte)(_tx_seq - _tx_ack + 8);

    ubyte _rx_seq = 0; // the next frame we expect to receive

    // TODO: received frames pending delivery because we missed one and sent a NAK
    Message* _tx_in_flight; // frames that have been sent but not yet ack-ed
    Message* _tx_queue;    // frames waiting to be sent
    Message* _free_list;

    ubyte _rx_offset;
    ubyte[128] _rx_buffer;

    void service_stream()
    {
        do
        {
            MonoTime now = getTime();
            ptrdiff_t r = _stream.read(_rx_buffer[_rx_offset..$]);
            if (r <= 0)
                break;

            _status.recv_bytes += r;

            // skip any XON/XOFF bytes
            ubyte rxLen = _rx_offset;
            for (ubyte i = _rx_offset; i < _rx_offset + r; ++i)
            {
                if (_rx_buffer[i] == ASH_XON_BYTE || _rx_buffer[i] == ASH_XOFF_BYTE)
                    continue;
                _rx_buffer[rxLen++] = _rx_buffer[i];
            }

            // parse frames from stream delimited by 0x7E bytes
            ubyte start = 0;
            ubyte end = 0;
            bool inputError = false;
            outer: for (; end < rxLen; ++end)
            {
                if (_rx_buffer[end] == ASH_SUBSTITUTE_BYTE)
                    inputError = true;
                else if (_rx_buffer[end] == ASH_CANCEL_BYTE)
                    start = cast(ubyte)(end + 1);

                if (_rx_buffer[end] != ASH_FLAG_BYTE)
                    continue;

                if (inputError)
                {
                    inputError = false;
                    start = cast(ubyte)(end + 1);
                    ++_status.recv_dropped;
                    continue;
                }

                // remove byte-stuffing from the frame
                ubyte frameLen = 0;
                for (ubyte i = start; i < end; ++i)
                {
                    ubyte b = _rx_buffer[i];
                    if (b == ASH_ESCAPE_BYTE)
                    {
                        if (++i == end)
                        {
                            start = cast(ubyte)(end + 1);
                            continue outer;
                        }
                        _rx_buffer[start + frameLen++] = _rx_buffer[i] ^ 0x20;
                    }
                    else
                        _rx_buffer[start + frameLen++] = b;
                }

                ubyte frameStart = start;
                start = cast(ubyte)(end + 1);

                if (frameLen < 2)
                {
                    if (frameLen != 0)
                        ++_status.recv_dropped;
                    continue;
                }

                // validate the frame
                int frameEnd = frameStart + frameLen - 2;
                ubyte[] frame = _rx_buffer[frameStart .. frameEnd];

                // check the crc
                const ushort crc = frame.ezsp_crc();
                if (_rx_buffer[frameEnd .. frameEnd + 2][0..2].bigEndianToNative!ushort != crc)
                {
                    ++_status.recv_dropped;
                    continue;
                }

                ++_status.recv_packets;
                process_frame(frame, now);
            }

            // shuffle any tail bytes (incomplete frames) to the start of the buffer...
            _rx_offset = cast(ubyte)(rxLen - start);
            if (start > 0)
            {
                import urt.mem : memmove;
                memmove(_rx_buffer.ptr, _rx_buffer.ptr + start, _rx_offset);
            }
        }
        while(true);
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

                writeDebug(_connected ? "ASHv2: connected! code=" : "ASHv2: connection failed; unsupported version! code=", code);
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
                writeDebug("ASHv2: <-- ERROR. code=", code);
            }
            restart();
            return;
        }

        ubyte ack_num = control & 7;
        int ack_ahead = ack_num >= _tx_ack ? ack_num - _tx_ack : ack_num - _tx_ack + 8;
        if (ack_ahead > tx_ahead())
            return; // discard frames with invalid ack_num

        // check for other control codes
        if (control & 0x80)
        {
            if ((control & 0x60) == 0)
            {
                // ACK
                version (DebugASHMessageFlow)
                    writeDebugf("ASHv2: <-- ACK [{0,02x}]", control);
                ack_in_flight(ack_num, timestamp);
            }
            else if ((control & 0x60) == 0x20)
            {
                // NAK
                version (DebugASHMessageFlow)
                    writeDebugf("ASHv2: <-- NAK [{0,02x}]", control);
            }
            else
            {
                debug assert(false, "TODO: should we do anything here, or just return?");
            }
            return;
        }

        // DATA frame
        ubyte frm_num = control >> 4;
        bool retransmit = (control & 0x08) != 0;

        if (frm_num != _rx_seq)
        {
            ash_nak(_rx_seq, false);
            return;
        }

        ubyte[] data = void;
        ubyte[ASH_MAX_LENGTH] tmp = void;
        data = tmp[0 .. frame.length];

        randomise(frame, data);

        version (DebugASHMessageFlow)
            writeDebugf("ASHv2: <-- [x{0, 02x}]: {1}", control, cast(void[])data);

        _rx_seq = (_rx_seq + 1) & 7;
        ash_ack(_rx_seq, false);

        if (data.length > 0)
        {
            Packet p;
            p.init!ASHFrame(data, cast(SysTime)timestamp);
            dispatch(p);
        }

        ack_in_flight(ack_num, timestamp);
    }

    void ack_in_flight(ubyte ack_num, MonoTime timestamp)
    {
        while (_tx_ack != ack_num)
        {
            if (!_tx_in_flight || _tx_in_flight.seq != _tx_ack)
            {
                assert(false, "We've gone off the rails!");
            }

            Message* msg = _tx_in_flight;
            update_time_stats(msg, timestamp);
            _tx_in_flight = _tx_in_flight.next;
            free_message(msg);

            _tx_ack = (_tx_ack + 1) & 7;
        }

        // we can send any queued frames here...
        while (_tx_queue && tx_ahead < _max_in_flight)
        {
            Message* next = _tx_queue.next;
            if (!send_msg(_tx_queue))
                break;
            _tx_queue = next;
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

        _status.avg_queue_us = (_status.avg_queue_us * 7 + wait_us) / 8;
        _status.avg_service_us = (_status.avg_service_us * 7 + service_us) / 8;

        if (service_us > _status.max_service_us)
            _status.max_service_us = service_us;
    }

    bool send_msg(Message* msg)
    {
        if (!_connected || !ash_send(msg.payload(), _tx_seq, _rx_seq, false))
            return false;

        msg.next = null;
        msg.send_time = getTime();
        msg.seq = _tx_seq;
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
            writeDebugf("ASHv2: --> {0} [x{1, 02x}]", nak ? "NAK" : "ACK", control);

        ubyte[4] ack_msg = [ control, 0, 0, ASH_FLAG_BYTE ];
        ack_msg[1..3] = ack_msg[0..1].ezsp_crc().nativeToBigEndian;
        if (_stream.write(ack_msg) != 4)
        {
            ++_status.send_dropped;
            return false;
        }
        ++_status.send_packets;
        _status.send_bytes += 4;
        return true;
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

        // byte-stuffing
        ubyte[256] stuffed = void;
        size_t len = 0;
        foreach (i, b; frame[0 .. 1 + msg.length + 2])
        {
            if (b == 0x7E || b == 0x7D || b == 0x11 || b == 0x13 || b == 0x18 || b == 0x1A)
            {
                stuffed[len++] = ASH_ESCAPE_BYTE;
                stuffed[len++] = b ^ 0x20;
            }
            else
                stuffed[len++] = b;
        }

        stuffed[len++] = 0x7E;

        version (DebugASHMessageFlow)
            writeDebugf("ASHv2: --> [x{0, 02x}]: {1}", control, cast(void[])msg);

        ptrdiff_t r = _stream.write(stuffed[0..len]);
        if (r != len)
        {
            version (DebugASHMessageFlow)
                writeDebug("ASHv2: stream write failed!");
            ++_status.send_dropped;
            return false;
        }

        ++_status.send_packets;
        _status.send_bytes += r;
        return true;
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
