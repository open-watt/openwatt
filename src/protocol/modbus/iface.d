module protocol.modbus.iface;

import urt.array;
import urt.conv;
import urt.crc;
import urt.endian;
import urt.log;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.modbus;
import protocol.modbus.message;

import router.iface;
import router.iface.packet;
import router.iface.priority_queue;
import router.stream;

alias modbus_crc = calculate_crc!(Algorithm.crc16_modbus);
alias modbus_crc_2 = calculate_crc_2!(Algorithm.crc16_modbus);

nothrow @nogc:


enum ModbusProtocol : byte
{
    unknown = -1,
    rtu,
    tcp,
    ascii
}

enum ModbusFrameType : ubyte
{
    unknown,
    request,
    response
}


class ModbusInterface : BaseInterface
{
    __gshared Property[3] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("protocol", protocol)(),
                                         Property.create!("master", master)() ];
nothrow @nogc:

    enum type_name = "modbus";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ModbusInterface, name.move, flags);

        // this is the proper value for modbus, irrespective of the L2 MTU
        // modbus jumbo's are theoretically possible if all hops support it... (fragmentation is not possible)
        _mtu = 253; // function + 252 byte payload (address is considered framing (?))

        // this would be 253 for the RS485 bus, or larger if another carrier...?
        _max_l2mtu = _mtu;
        _l2mtu = _max_l2mtu;

        // master defaults to false, so we'll generate a mac for the remote bus master...
        _master_mac = generate_mac_address();
        _master_mac.b[5] = 0xFF;
        add_address(_master_mac, this);

        // TODO: warn the user if they configure an interface to use modbus tcp over a serial line
        //       user should be warned that data corruption may occur!

        // TODO: assert that recvBufferLen and sendBufferLen are both larger than a single PDU (254 bytes)!
    }

    // Properties...

    ModbusProtocol protocol() const pure
        => _protocol;
    const(char)[] protocol(ModbusProtocol value)
    {
        if (value == ModbusProtocol.unknown)
            return "Error: Invalid modbus protocol 'unknown'";
        _protocol = value;
        _support_simultaneous_requests = value == ModbusProtocol.tcp;

        if (_protocol == ModbusProtocol.tcp && _stream)
        {
            import router.stream.serial : SerialStream;
            if (cast(SerialStream)_stream)
                writeWarning("Modbus interface '", name[], "': Modbus-TCP has no CRC; using TCP framing over a serial line may cause silent data corruption");
        }

        return null;
    }

    bool master() const pure
        => _is_bus_master;
    void master(bool value)
    {
        if (_is_bus_master == value)
            return;

        _is_bus_master = value;
        if (value)
        {
            remove_address(_master_mac);
            _master_mac = MACAddress();
            if (_protocol == ModbusProtocol.unknown)
                restart();
        }
        else
        {
            _master_mac = generate_mac_address();
            _master_mac.b[5] = 0xFF;
            add_address(_master_mac, this);
        }
    }

    uint baud() const pure
        => _user_baud;
    void baud(uint value)
    {
        _user_baud = value;
        restart();
    }

    bool estimate_baud() const pure
        => _estimate_baud;
    void estimate_baud(bool value)
    {
        _estimate_baud = value;
    }

    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _stream = value;

        if (_stream)
        {
            if (_protocol == ModbusProtocol.tcp)
            {
                import router.stream.serial : SerialStream;
                if (cast(SerialStream)_stream)
                    writeWarning("Modbus interface '", name[], "': Modbus-TCP has no CRC; using TCP framing over a serial line may cause silent data corruption");
            }

            // if we're not the master, we can't write to the bus unless we are responding...
            // and if the stream is TCP, we'll never know if the remote has dropped the connection
            // we'll enable keep-alive in tcp streams to to detect this...
            import router.stream.tcp : TCPStream;
            auto tcpStream = cast(TCPStream)_stream;
            if (tcpStream)
                tcpStream.enable_keep_alive(true, seconds(10), seconds(1), 10);
        }

        // flush messages and the address mapping tables
        restart();
        return null;
    }


    // API...

    override bool validate() const
        => _stream !is null && (!master || _protocol != ModbusProtocol.unknown);

    override CompletionStatus validating()
    {
        _stream.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_stream)
            return CompletionStatus.error;
        if (!_stream.running)
            return CompletionStatus.continue_;

        if (!_is_bus_master && _protocol == ModbusProtocol.unknown)
        {
            // listen for a frame and detect the protocol...
            assert(false, "TODO");
        }
        if (_protocol != ModbusProtocol.unknown)
        {
            _local_to_uni.insert(ubyte(0), ubyte(0));
            _uni_to_local.insert(ubyte(0), ubyte(0));

            // compute timing parameters from baud rate
            if (!_support_simultaneous_requests)
            {
                import router.stream.serial : SerialStream;
                if (auto serial = cast(SerialStream)_stream)
                {
                    compute_timing(serial.baud_rate);
                    _baud_estimated = true;
                }
                else
                {
                    uint baud = _user_baud != 0 ? _user_baud : _estimated_baud != 0 ? _estimated_baud : 9_600;
                    compute_timing(baud);
                    _gap_time_us = 0;
                    _baud_estimated = _user_baud != 0 || _estimated_baud != 0;
                }
            }

            _queue.init(_support_simultaneous_requests ? 8 : 1, 0, PCP.be, &_status);
            _queue.set_queue_timeout(_queue_timeout.msecs);
            _queue.set_transport_timeout(_request_timeout.msecs);
            return CompletionStatus.complete;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _sequence_number = 0;
        _expect_message_type = ModbusFrameType.unknown;
        _last_receive_event = SysTime();
        _baud_estimated = false;

        foreach (kvp; _pending[])
        {
            if (kvp.value.callback)
                kvp.value.callback(kvp.key, MessageState.aborted);
        }
        _pending.clear();
        _queue.abort_all();

        _local_to_uni.clear();
        _uni_to_local.clear();

        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_stream || !_stream.running)
            return restart();

        super.update();

        SysTime now = getSysTime();

        _queue.timeout_stale(getTime());

        // estimate remote baud rate for TCP bridges after collecting stats
        if (_estimate_baud && !_baud_estimated && !_support_simultaneous_requests && _status.send_packets >= 20)
            estimate_remote_baud();

        send_queued_messages();

        // check for data
        ubyte[1024] buffer = void;
        buffer[0 .. _tail_bytes] = _tail[0 .. _tail_bytes];
        ptrdiff_t read_offset = _tail_bytes;
        ptrdiff_t length = _tail_bytes;
        _tail_bytes = 0;
        read_loop: while (true)
        {
            assert(length < 260);

            ptrdiff_t r = stream.read(buffer[read_offset .. $]);
            if (r < 0)
            {
                assert(false, "TODO: what causes read to fail?");
                break read_loop;
            }
            if (r == 0)
            {
                // if there were no extra bytes available, stash the _tail until later
                _tail[0 .. length] = buffer[0 .. length];
                _tail_bytes = cast(ushort)length;
                break read_loop;
            }
            length += r;
            assert(length <= buffer.sizeof);

//            if (connParams.logDataStream)
//                logStream.rawWrite(buffer[0 .. length]);

            size_t offset = 0;
            while (offset < length)
            {
                // parse packets from the stream...
                const(void)[] message = void;
                ModbusFrameInfo frame_info = void;
                size_t taken = 0;
                final switch (protocol)
                {
                    case ModbusProtocol.unknown:
                        assert(false, "Modbus protocol not specified");
                        break;
                    case ModbusProtocol.rtu:
                        taken = parse_rtu(buffer[offset .. length], message, frame_info);
                        break;
                    case ModbusProtocol.tcp:
                        taken = parse_tcp(buffer[offset .. length], message, frame_info);
                        break;
                    case ModbusProtocol.ascii:
                        taken = parse_ascii(buffer[offset .. length], message, frame_info);
                        break;
                }

                if (taken == 0)
                {
                    import urt.util : min;

                    // we didn't parse any packets
                    // we might have a split packet, so we'll shuffle unread data to the front of the buffer
                    // ...but we'll only keep at most one message worth!
                    size_t remain = length - offset;
                    size_t keepBytes = min(remain, 259);
                    size_t trunc = remain - keepBytes;
                    memmove(buffer.ptr, buffer.ptr + offset + trunc, keepBytes);
                    length = keepBytes;
                    read_offset = keepBytes;
                    offset = 0;
                    continue read_loop;
                }
                offset += taken;

                incoming_packet(message, now, frame_info);
            }

            // we've eaten the whole buffer...
            length = 0;
        }
    }

    protected override int transmit(ref const Packet packet, MessageCallback callback = null) nothrow @nogc
    {
        // can only handle modbus packets
        if (packet.eth.ether_type != EtherType.ow || packet.eth.ow_sub_type != OW_SubType.modbus || packet.data.length < 5)
        {
            log.debug_("tx-drop: not a modbus packet");
            ++_status.send_dropped;
            return -1;
        }

        auto mod_mb = get_module!ModbusProtocolModule();

        ushort seq = (cast(ubyte[])packet.data)[0..2].bigEndianToNative!ushort;
        ModbusFrameType packetType = *cast(ModbusFrameType*)&packet.data[2];
        ubyte packetAddress = *cast(ubyte*)&packet.data[3];

        if (_is_bus_master)
        {
            assert(packetType == ModbusFrameType.request);

            ubyte local_address = 0;
            if (!packet.eth.dst.isBroadcast)
            {
                ServerMap* map = mod_mb.find_server_by_mac(packet.eth.dst);
                if (!map || map.iface !is this)
                {
                    log.debug_("tx-drop: unknown server MAC");
                    ++_status.send_dropped;
                    return -1;
                }
                local_address = map.local_address;
            }

            Packet p = packet;
            int tag = _queue.enqueue(p, &on_frame_complete);
            if (tag < 0)
            {
                log.debug_("tx-drop: queue full");
                ++_status.send_dropped;
                return -1;
            }

            _pending[cast(ubyte)tag] = PendingModbus(packet.eth.src, seq, local_address, callback);

            send_queued_messages();
            return tag;
        }
        else
        {
            assert(packetType == ModbusFrameType.response);

            if (packet.eth.dst != _master_mac)
            {
                log.debug_("tx-drop: response dst != master MAC");
                ++_status.send_dropped;
                return -1;
            }

            ubyte address = packetAddress;
            ServerMap* map = mod_mb.find_server_by_universal_address(packetAddress);
            if (!map)
            {
                log.debug_("tx-drop: unknown universal address ", packetAddress);
                ++_status.send_dropped;
                return -1;
            }

            if (map.iface is this)
            {
                assert(false, "This should be impossible; it should have served its own response...?");
                address = map.local_address;
            }
            else
            {
                debug assert(packetAddress == map.universal_address, "Packet address does not match dest address?!");
                address = map.universal_address;
            }

            const(ubyte)[] pdu = cast(ubyte[])packet.data[4 .. $];
            return frame_and_send(address, pdu);
        }
    }

    override ushort pcap_type() const
        => 147; // DLT_USER

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(const void[] packetData) nothrow @nogc sink) const
    {
        // write the address and pdu
        sink(packet.data[3..$]);

        // calculate and write the crc
        ushort crc = packet.data[3 .. $].modbus_crc();
        sink(crc.nativeToLittleEndian());
    }

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

package:
    final MACAddress generate_mac_address() pure
        => super.generate_mac_address();

private:

    struct PendingModbus
    {
        MACAddress request_from;
        ushort sequence_number;
        ubyte local_server_address;
        MessageCallback callback;
    }

    ObjectRef!Stream _stream;

    ModbusProtocol _protocol;
    bool _is_bus_master;
    bool _support_simultaneous_requests = false;
    uint _request_timeout = 800;   // ms — computed from baud rate in startup()
    uint _queue_timeout = 2500;    // ms — computed from baud rate in startup()
    uint _gap_time_us = 4000;      // microseconds — computed from baud rate in startup()
    uint _user_baud;               // explicit remote baud rate (0 = not set)
    uint _estimated_baud;          // estimated remote baud rate for TCP bridges
    bool _estimate_baud;           // enable auto-estimation of remote baud rate
    bool _baud_estimated;
    SysTime _last_receive_event;

    // bus master: message queue and pending metadata
    PriorityPacketQueue _queue;
    Map!(ubyte, PendingModbus) _pending;

    // if we are not the bus master
    package(router.iface) MACAddress _master_mac; // TODO: `package` because bridge interface backdoors this!... rethink?
    ushort _sequence_number;
    ModbusFrameType _expect_message_type = ModbusFrameType.unknown;

    package Map!(ubyte, ubyte) _local_to_uni;
    package Map!(ubyte, ubyte) _uni_to_local;

    ubyte[260] _tail;
    ushort _tail_bytes;

    int frame_and_send(ubyte address, const(ubyte)[] pdu)
    {
        ushort length = 0;
        ubyte[520] buffer = void;

        final switch (protocol)
        {
            case ModbusProtocol.unknown:
                assert(false, "Modbus protocol not specified");
            case ModbusProtocol.rtu:
                length = cast(ushort)(1 + pdu.length);
                buffer[0] = address;
                buffer[1 .. length] = pdu[];
                buffer[length .. length + 2][0 .. 2] = buffer[0 .. length].modbus_crc().nativeToLittleEndian;
                length += 2;
                break;
            case ModbusProtocol.tcp:
                assert(false);
            case ModbusProtocol.ascii:
                ubyte lrc = address;
                foreach (b; cast(ubyte[])pdu[])
                    lrc += cast(ubyte)b;
                lrc = cast(ubyte)-lrc;

                buffer[0] = ':';
                format_int(address, cast(char[])buffer[1..3], 16, 2, '0');
                length = cast(ushort)(3 + toHexString(pdu[], cast(char[])buffer[3..$]).length);
                format_int(lrc, cast(char[])buffer[length .. length + 2], 16, 2, '0');
                (cast(char[])buffer)[length + 2 .. length + 4] = "\r\n";
                length += 4;
        }

        ptrdiff_t written = stream.write(buffer[0 .. length]);
        if (written != length)
        {
            log.debug_("tx-drop: write failed (wrote ", written, " of ", length, ")");
            ++_status.send_dropped;
            return -1;
        }

        ++_status.send_packets;
        _status.send_bytes += length;
        return 0;
    }

    void send_queued_messages()
    {
        if (!_support_simultaneous_requests && getSysTime() - _last_receive_event < _gap_time_us.usecs)
            return;

        for (QueuedFrame* frame = _queue.dequeue(); frame !is null; frame = _queue.dequeue())
        {
            ubyte tag = frame.tag;
            auto pm = tag in _pending;
            if (!pm)
            {
                log.debug_("dispatch: no pending entry for tag ", tag);
                _queue.complete(tag, MessageState.failed);
                continue;
            }

            const(ubyte)[] pdu = cast(ubyte[])frame.packet.data[4 .. $];

            if (frame_and_send(pm.local_server_address, pdu) < 0)
            {
                log.debug_("dispatch: frame_and_send failed for addr ", pm.local_server_address);
                _queue.complete(tag, MessageState.failed);
                continue;
            }

            if (pm.callback)
                pm.callback(tag, MessageState.in_flight);
        }
    }

    void on_frame_complete(int tag, MessageState state)
    {
        if (state != MessageState.complete && state != MessageState.in_flight)
            log.debug_("queue event: tag=", tag, " state=", cast(int)state);

        ubyte t = cast(ubyte)tag;
        if (auto pm = t in _pending)
        {
            if (pm.callback)
                pm.callback(tag, state);
            _pending.remove(t);
        }
    }

    // Compute inter-frame gap, transport timeout, and queue timeout from baud rate.
    // Modbus RTU spec section 2.5.1.1:
    //   baud <= 19200: t3.5 = 3.5 character times (11 bits/char)
    //   baud > 19200: t3.5 = 1.75ms fixed
    void compute_timing(uint baud)
    {
        if (baud == 0)
            return;

        // inter-frame gap in microseconds: 3.5 × 11 × 1_000_000 / baud
        _gap_time_us = baud <= 19_200 ? 38_500_000 / baud : 1_750;

        // transport timeout: 2× max frame time + 200ms processing margin
        // max RTU frame = 256 bytes × 11 bits/char
        uint max_frame_us = 256 * 11 * (1_000_000 / baud);
        _request_timeout = max_frame_us * 2 / 1000 + 200;

        // queue timeout: full queue drain time + 1s safety margin
        uint single_tx_us = max_frame_us + _gap_time_us;
        _queue_timeout = 32 * (single_tx_us / 1000) + 1000;
    }

    void estimate_remote_baud()
    {
        if (_status.send_packets < 20 || _status.avg_service_us == 0)
            return;

        uint avg_bytes = cast(uint)((_status.send_bytes + _status.recv_bytes) / _status.send_packets);
        if (avg_bytes == 0)
            return;

        // subtract estimated device processing overhead (5ms)
        uint serial_time_us = _status.avg_service_us > 5000 ? _status.avg_service_us - 5000 : _status.avg_service_us;
        if (serial_time_us == 0)
            return;

        uint estimated = avg_bytes * 11 * (1_000_000 / serial_time_us);

        // snap to nearest standard baud rate
        static immutable uint[8] standard_bauds = [1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600, 115_200];
        uint closest = standard_bauds[0];
        uint min_diff = uint.max;
        foreach (baud; standard_bauds)
        {
            uint diff = estimated > baud ? estimated - baud : baud - estimated;
            if (diff < min_diff)
            {
                min_diff = diff;
                closest = baud;
            }
        }

        _estimated_baud = closest;
        _baud_estimated = true;

        // recompute timeouts from estimated baud (but keep gap=0 for TCP)
        compute_timing(closest);
        _gap_time_us = 0;

        _queue.set_queue_timeout(_queue_timeout.msecs);
        _queue.set_transport_timeout(_request_timeout.msecs);

        writeInfo("Modbus interface '", name[], "': estimated remote baud rate ", closest);
    }

    final void incoming_packet(const(void)[] message, SysTime recvTime, ref ModbusFrameInfo frame_info)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        // if we are the bus master, then we can only receive responses...
        ModbusFrameType type = _is_bus_master ? ModbusFrameType.response : frame_info.frame_type;
        if (type == ModbusFrameType.unknown && _expect_message_type != ModbusFrameType.unknown)
        {
            // if we haven't seen a packet for longer than the timeout interval, then we can't trust our guess
            if (recvTime - _last_receive_event > _request_timeout.msecs)
                _expect_message_type = ModbusFrameType.unknown;
            else
                type = _expect_message_type;
        }

        _last_receive_event = recvTime;

        MACAddress frame_mac = void;
        ubyte address = 0;

        if (frame_info.address == 0)
            frame_mac = MACAddress.broadcast;
        else
        {
            auto mod_mb = get_module!ModbusProtocolModule();

            // we probably need to find a way to cache these lookups.
            // doing this every packet feels kinda bad...

            // if we are the bus master, then incoming packets are responses from slaves
            //    ...so the address must be their local bus address
            // if we are not the bus master, then it could be a request from a master to a local or remote slave, or a response from a local slave
            //    ...the response is local, so it can only be a universal address if it's a request!
            ServerMap* map = mod_mb.find_server_by_local_address(frame_info.address, this);
            if (!map && type == ModbusFrameType.request)
                map = mod_mb.find_server_by_universal_address(frame_info.address);
            if (!map)
            {
                // apparently this is the first time we've seen this guy...
                // this should be impossible if we're the bus master, because we must know anyone we sent a request to...
                // so, it must be a communication from a local master with a local slave we don't know...

                // let's confirm and then record their existence...
                if (_is_bus_master)
                {
                    // if we are the bus-master, it should have been impossible to receive a packet from an unknown guy
                    // it's possibly a false packet from a corrupt bitstream, or there's another master on the bus!
                    // we'll drop this packet to be safe...
                    log.debug_("rx-drop: unknown local address ", frame_info.address);
                    ++_status.recv_dropped;
                    return;
                }

                map = mod_mb.add_remote_server(null, this, frame_info.address, null, null);
            }
            address = map.universal_address;
            frame_mac = map.mac;
        }

        ubyte[255] buffer = void;
        buffer[3] = address;
        buffer[2] = type;
        buffer[4 .. 4 + message.length] = cast(ubyte[])message[];

        Packet p;
        p.init!Ethernet(buffer[0 .. 4 + message.length]);
        p.creation_time = recvTime;
        p.vlan = _pvid;
        p.eth.ether_type = EtherType.ow;
        p.eth.ow_sub_type = OW_SubType.modbus;

        if (_is_bus_master)
        {
            if (!_support_simultaneous_requests)
            {
                // find the single in-flight entry (RTU: max_in_flight=1)
                ubyte matched_tag = 0;
                bool found = false;
                foreach (kvp; _pending[])
                {
                    if (!_queue.is_queued(kvp.key))
                    {
                        matched_tag = kvp.key;
                        found = true;
                        break;
                    }
                }

                if (!found)
                {
                    log.debug_("rx-drop: response but no in-flight request");
                    ++_status.recv_dropped;
                    return;
                }

                auto pm = matched_tag in _pending;
                if (pm.local_server_address == frame_info.address)
                {
                    p.eth.src = frame_mac;
                    p.eth.dst = pm.request_from;
                    buffer[0..2] = nativeToBigEndian(pm.sequence_number);
                    dispatch(p);
                    _queue.complete(matched_tag, MessageState.complete);
                }
                else
                {
                    log.debug_("rx-drop: address mismatch (got ", frame_info.address,
                        " expected ", pm.local_server_address, ")");
                    ++_status.recv_dropped;
                    _queue.complete(matched_tag, MessageState.failed);
                }

                send_queued_messages();
            }
            else
            {
                if (!frame_info.has_sequence_number)
                    assert(false);

                ushort seq = frame_info.sequence_number;
                ubyte matched_tag = 0;
                bool found = false;

                foreach (kvp; _pending[])
                {
                    if (kvp.value.local_server_address == frame_info.address && kvp.value.sequence_number == seq)
                    {
                        matched_tag = kvp.key;
                        found = true;
                        break;
                    }
                }

                if (found)
                {
                    auto pm = matched_tag in _pending;
                    p.eth.src = frame_mac;
                    p.eth.dst = pm.request_from;
                    buffer[0..2] = nativeToBigEndian(seq);
                    dispatch(p);
                    _queue.complete(matched_tag, MessageState.complete);
                }
                else
                {
                    log.debug_("rx-drop: no pending match for addr=", frame_info.address, " seq=", seq);
                    ++_status.recv_dropped;
                }

                send_queued_messages();
            }
        }
        else
        {
            if (type != ModbusFrameType.request)
            {
                if (frame_mac == mac)
                {
                    debug assert(type != ModbusFrameType.response, "This seems like a request, but the FrameInfo disagrees!");
                    buffer[2] = type = ModbusFrameType.request;
                }
                else if (type == ModbusFrameType.unknown)
                {
                    // we can't dispatch this message if we don't know if its a request or a response...
                    // we'll need to discard messages until we get one that we know, and then we can predict future messages from there
                    log.debug_("rx-drop: unknown frame type, can't dispatch");
                    ++_status.recv_dropped;
                    return;
                }
            }

            p.eth.src = type == ModbusFrameType.request ? _master_mac : frame_mac;
            p.eth.dst = type == ModbusFrameType.request ? frame_mac : _master_mac;

            ushort seq = frame_info.sequence_number;
            if (!frame_info.has_sequence_number)
            {
                if (type == ModbusFrameType.request)
                    ++_sequence_number;
                seq = _sequence_number;
            }
            buffer[0..2] = nativeToBigEndian(seq);

            dispatch(p);

            _expect_message_type = type == ModbusFrameType.request ? ModbusFrameType.response : ModbusFrameType.request;
        }
    }
}


private:

struct ModbusFrameInfo
{
    bool has_sequence_number;
    bool has_crc;
    ushort sequence_number;
    ushort crc;
    ModbusFrameType frame_type = ModbusFrameType.unknown;
    ubyte address;
    FunctionCode function_code;
    ExceptionCode exception_code = ExceptionCode.none;
}

__gshared immutable ushort[25] function_lens = [
    0x0000, 0x2306, 0x2306, 0x2306, 0x2306, 0x0606, 0x0606, 0x0302,
    0xFFFF, 0xFFFF, 0xFFFF, 0x0602, 0x2302, 0xFFFF, 0xFFFF, 0x0667,
    0x0667, 0x2302, 0xFFFF, 0xFFFF, 0x3232, 0x3232, 0x0808, 0x23AB,
    0x3404
];

int parse_frame(const(ubyte)[] data, out ModbusFrameInfo frame_info)
{
    // RTU has no sync markers, so we need to get pretty creative to validate frames!
    // 1: packets are delimited by a 2-byte CRC, so any sequence of bytes where the running CRC is followed by 2 bytes with that value might be a frame...
    // 2: but 2-byte CRC's aren't good enough protection against false positives! (they appear semi-regularly), so...
    // 3:  a. we can exclude packets that start with an invalid function code
    //     b. we can exclude packets to the broadcast address (0), with a function code that can't broadcast
    //     c. we can then try and determine the expected packet length, and check for CRC only at the length offsets
    //     d. failing all that, we can crawl the buffer for a CRC...
    //     e. if we don't find a packet, repeat starting at the next BYTE...

    // ... losing stream sync might have a high computational cost!
    // we might determine that in practise it's superior to just drop the whole buffer and wait for new data which is probably aligned to the bitstream to arrive?

    // NOTE: it's also worth noting, that some of our stream validity checks exclude non-standard protocol...
    //       for instance, we exclude any function code that's not in the spec. What if an implementation invents their own function codes?
    //       maybe it should be an interface flag to control whether it accepts non-standard streams, and relax validation checking?

    if (data.length < 4) // @unlikely
        return 0;

    // check the address is in the valid range
    ubyte address = data[0];
    if (address >= 248 && address <= 255) // @unlikely
        return 0;
    frame_info.address = address;

    // frames must start with a valid function code...
    ubyte f = data[1];
    FunctionCode fc = cast(FunctionCode)(f & 0x7F);
    ushort fn_data = fc < function_lens.length ? function_lens[fc] : fc == 0x2B ? 0xFFFF : 0;
    if (fn_data == 0) // @unlikely
        return 0;
    frame_info.function_code = fc;
    frame_info.has_crc = true;

    // exceptions are always 3 bytes
    ubyte req_length = void;
    ubyte res_length = void;
    if (f & 0x80) // @unlikely
    {
        frame_info.exception_code = cast(ExceptionCode)data[2];
        frame_info.frame_type = ModbusFrameType.response;
        req_length = 3;
        res_length = 3;
    }

    // zero bytes (broadcast address) are common in data streams, and if the function code can't broadcast, we can exclude this packet
    // NOTE: this can only catch 10 bad bytes in the second byte position... maybe not worth the if()?
//    else if (address == 0 && (fFlags & 2) == 0) // @unlikely
//    {
//        frameId.invalidFrame = true;
//        return false;
//    }

    // if the function code can determine the length...
    else if (fn_data != 0xFFFF) // @likely
    {
        // TODO: we can instead load these bytes separately if the bit-shifting is worse than loads...
        req_length = fn_data & 0xF;
        ubyte req_extra = (fn_data >> 4) & 0xF;
        res_length = (fn_data >> 8) & 0xF;
        ubyte res_extra = fn_data >> 12;
        if (req_extra && req_extra < data.length)
            req_length += data[req_extra];
        if (res_extra)
            res_length += data[res_extra];
    }
    else
    {
        // function length can't be determined; scan for a CRC...

        // realistically, this is almost always a result of stream corruption...
        // and the implementation is quite a lot of code!
        const(ubyte)[] message = crawl_for_rtu(data, &frame_info.crc);
        if (message != null)
            return cast(int)message.length;
        return 0;
    }

    int fail_result = 0;
    if (req_length != res_length) // @likely
    {
        ubyte length = void, smaller_length = void;
        ModbusFrameType type = void, smaller_type = void;
        if (req_length > res_length)
        {
            length = req_length;
            smaller_length = res_length;
            type = ModbusFrameType.request;
            smaller_type = ModbusFrameType.response;
        }
        else
        {
            length = res_length;
            smaller_length = req_length;
            type = ModbusFrameType.response;
            smaller_type = ModbusFrameType.request;
        }

        if (data.length >= length + 2) // @likely
        {
            uint crc2 = data[0 .. length].modbus_crc_2(smaller_length);

            if ((crc2 >> 16) == (data[smaller_length] | cast(ushort)data[smaller_length + 1] << 8))
            {
                frame_info.frame_type = smaller_type;
                frame_info.crc = crc2 >> 16;
                return smaller_length;
            }
            if ((crc2 & 0xFFFF) == (data[length] | cast(ushort)data[length + 1] << 8))
            {
                frame_info.frame_type = type;
                frame_info.crc = crc2 & 0xFFFF;
                return length;
            }
            return 0;
        }
        else
        {
            fail_result = -1;
            req_length = smaller_length;
            frame_info.frame_type = smaller_type;
        }
    }

    // check we have enough data...
    if (data.length < req_length + 2) // @unlikely
        return -1;

    ushort crc = data[0 .. req_length].modbus_crc();

    if (crc == (data[req_length] | cast(ushort)data[req_length + 1] << 8))
    {
        frame_info.crc = crc;
        return req_length;
    }

    return fail_result;
}


size_t parse_rtu(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frame_info)
{
    if (data.length < 4)
        return 0;

    // the stream might have corruption or noise, RTU frames could be anywhere, so we'll scan forward searching for the next frame...
    size_t offset = 0;
    for (; offset < data.length - 4; ++offset)
    {
        int length = parse_frame(data[offset .. data.length], frame_info);
        if (length < 0)
            return 0;
        if (length == 0)
            continue;

        message = data[offset + 1 .. offset + length];
        return offset + length + 2;
    }

    // no packet was found in the stream... how odd!
    return 0;
}

size_t parse_tcp(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frame_info)
{
    assert(false);
    return 0;
}

size_t parse_ascii(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frame_info)
{
    assert(false);
    return 0;
}

inout(ubyte)[] crawl_for_rtu(inout(ubyte)[] data, ushort* rcrc = null)
{
    alias modbus_crc_table = crc_table!(Algorithm.crc16_modbus);

//    if (data.length < 4)
//        return null;

    enum num_crc = 8;
    ushort[num_crc] found_crc = void;
    size_t[num_crc] found_crc_pos = void;
    int num_found_crc = 0;

    // crawl through the buffer accumulating a CRC and looking for the following bytes to match
    ushort crc = 0xFFFF;
    ushort next = data[0] | cast(ushort)data[1] << 8;
    size_t len = data.length < 256 ? data.length : 256;
    for (size_t pos = 2; pos < len; )
    {
        ubyte index = (next & 0xFF) ^ cast(ubyte)crc;
        crc = (crc >> 8) ^ modbus_crc_table[index];

        // get the next word in sequence
        next = next >> 8 | cast(ushort)data[pos++] << 8;

        // if the running CRC matches the next word, we probably have an RTU packet delimiter
        if (crc == next)
        {
            found_crc[num_found_crc] = crc;
            found_crc_pos[num_found_crc++] = pos;
            if (num_found_crc == num_crc)
                break;
        }
    }

    if (num_found_crc > 0)
    {
        int best_match = 0;

        // TODO: this is a lot of code!
        // we should do some statistics to work out which conditions actually lead to better outcomes and compress the logic to only what is iecessary

        if (num_found_crc > 1)
        {
            // if we matched multiple CRC's in the buffer, then we need to work out which CRC is not a false-positive...
            int[num_crc] score;
            for (int i = 0; i < num_found_crc; ++i)
            {
                // if the CRC is at the end of the buffer, we have a single complete message, and that's a really good indicator
                if (found_crc_pos[i] == data.length)
                    score[i] += 10;
                else if (found_crc_pos[i] <= data.length - 2)
                {
                    // we can check the bytes following the CRC appear to begin a new message...
                    // confirm the function code is valid
                    if (valid_function_code(cast(FunctionCode)data[found_crc_pos[i] + 1]))
                        score[i] += 5;
                    // we can also give a nudge if the address looks plausible
                    ubyte addr = data[found_crc_pos[i]];
                    if (addr <= 247)
                    {
                        if (addr == 0)
                            score[i] += 1; // broadcast address is unlikely
                        else if (addr <= 4 || addr >= 245)
                            score[i] += 3; // very small or very big addresses are more likely
                        else
                            score[i] += 2;
                    }
                }
            }
            for (int i = 1; i < num_found_crc; ++i)
            {
                if (score[i] > score[i - 1])
                    best_match = i;
            }
        }

        if (rcrc)
            *rcrc = found_crc[best_match];
        return data[0 .. found_crc_pos[best_match]];
    }

    // didn't find anything...
    return null;
}

bool valid_function_code(FunctionCode function_code)
{
    if (function_code & 0x80)
        function_code ^= 0x80;

    version (X86_64) // TODO: use something more general!
    {
        enum ulong valid_codes = 0b10000000000000000001111100111001100111111110;
        if (function_code >= 64) // TODO: REMOVE THIS LINE (DMD BUG!)
            return false;       // TODO: REMOVE THIS LINE (DMD BUG!)
        return ((1uL << function_code) & valid_codes) != 0;
    }
    else
    {
        enum uint valid_codes = 0b1111100111001100111111110;
        if (function_code >= 25) // highest bit in valid_codes is 24; codes above are only MEI
            return function_code == FunctionCode.mei;
        return ((1u << function_code) & valid_codes) != 0;
    }
}
