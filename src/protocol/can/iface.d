module protocol.can.iface;

import urt.endian;
import urt.log;
import urt.mem;
import urt.mem.string;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.stream;

import urt.driver.can;

// SocketCAN is the linux backend for `adapter`; Espressif's is the on-chip TWAI
// controller behind urt.driver.can. They are mutually exclusive per platform.
version (linux)
{
    import urt.array : Array;
    import urt.result : StringResult;
    import urt.internal.sys.posix : pollfd, POLLIN;
    import driver.linux.raw : CANSocket, can_frame,
                              CAN_EFF_FLAG, CAN_RTR_FLAG, CAN_ERR_FLAG, CAN_EFF_MASK, CAN_SFF_MASK;
    import driver.linux.netlink_write : netlink_ifindex, netlink_set_link_up,
                                        netlink_set_can_bitrate, netlink_get_can_bitrate;
    import driver.linux.sysfs : read_link_type, ARPHRD_CAN;
    import driver.linux.fdwatch : add_fd_watcher, remove_fd_watcher, fd_watch_changed;
    enum has_socketcan = true;
}
else
    enum has_socketcan = false;

version(Espressif)
    version = HasGPIO;

//version = DebugCANInterface;

nothrow @nogc:


enum CANInterfaceProtocol : byte
{
    unknown = -1,
    ebyte
}

struct CANFrame
{
    enum Type = PacketType.can;

    uint id;
    bool remote_transmission_request;
    bool extended;

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!CANFrame().id;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.can) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.can) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
        => true; // CAN is always broadcast

    // OW encapsulation wire codec: [id:4 BE][flags:1] (bit0 = extended, bit1 = rtr)
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        import urt.endian : nativeToBigEndian;
        if (buffer.length < 5)
            return -1;
        ref const f = p.hdr!CANFrame;
        buffer[0 .. 4] = f.id.nativeToBigEndian;
        buffer[4] = (f.extended ? 1 : 0) | (f.remote_transmission_request ? 2 : 0);
        return 5;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        import urt.endian : bigEndianToNative;
        if (header.length < 5)
            return -1;
        p.type = PacketType.can;
        ref f = p.hdr!CANFrame;
        f.id = header[0 .. 4].bigEndianToNative!uint;
        f.extended = (header[4] & 1) != 0;
        f.remote_transmission_request = (header[4] & 2) != 0;
        return 5;
    }
}


class CANInterface : BaseInterface
{
    version(HasGPIO)
        alias Properties = AliasSeq!(Prop!("stream", stream),
                                     Prop!("protocol", protocol),
                                     Prop!("adapter", adapter),
                                     Prop!("baud-rate", baud_rate),
                                     Prop!("tx-gpio", tx_gpio),
                                     Prop!("rx-gpio", rx_gpio));
    else
        alias Properties = AliasSeq!(Prop!("stream", stream),
                                     Prop!("protocol", protocol),
                                     Prop!("adapter", adapter),
                                     Prop!("baud-rate", baud_rate));

nothrow @nogc:

    enum type_name = "can";
    enum path = "/interface/can";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CANInterface, id, flags);

        // this is the proper value for canbus, irrespective of the L2 MTU
        // can jumbo's are theoretically possible if all hops support it... (fragmentation is not possible (?))
        mtu = 8; // or 64 for FD-CAN...

        // this would be 8 or 64 for physical canbus, or larger if another carrier...?
        _max_l2mtu = mtu;
        l2mtu = _max_l2mtu;

        mark_set!(typeof(this), "max-l2mtu")();
    }


    // Properties...

    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _stream = value;
        _adapter = String();
        mark_set!(typeof(this), [ "stream", "adapter" ])();

        if (!_stream || !_stream.running)
            restart();
        return null;
    }

    CANInterfaceProtocol protocol() const pure
        => _protocol;
    const(char)[] protocol(CANInterfaceProtocol value)
    {
        import urt.mem.temp;
        if (value != CANInterfaceProtocol.ebyte)
            return tconcat("Invalid CAN protocol '", protocol, "': expect 'ebyte|??'.");
        _protocol = value;
        _adapter = String();
        mark_set!(typeof(this), [ "protocol", "adapter" ])();
        return null;
    }

    // The OS/hardware CAN controller this interface binds to, mutually exclusive with
    // `stream`. Spelled as a netdev name on linux ("can0"), as "twaiN" on Espressif.
    final const(char)[] adapter() const pure
        => _adapter[];
    final const(char)[] adapter(const(char)[] value)
    {
        if (!value.empty && !valid_adapter_name(value))
            return "invalid CAN adapter";
        bool changed = _adapter[] != value;
        if (!value.empty)
            changed |= _stream !is null || _protocol != CANInterfaceProtocol.unknown;
        if (!changed)
        {
            mark_assigned!(typeof(this), [ "adapter", "stream", "protocol" ])();
            return null;
        }

        _adapter = value.makeString(defaultAllocator);
        static if (!has_socketcan && num_can > 0)
            _can_port = value.empty ? -1 : cast(byte)(value[4] - '0');
        if (!value.empty)
        {
            _stream = null;
            _protocol = CANInterfaceProtocol.unknown;
        }
        mark_set!(typeof(this), [ "adapter", "stream", "protocol" ])();
        restart();
        return null;
    }

    final uint baud_rate() const pure
        => _baud_rate;
    final void baud_rate(uint value)
    {
        if (_baud_rate == value)
        {
            mark_assigned!(typeof(this), "baud-rate")();
            return;
        }
        _baud_rate = value;
        mark_set!(typeof(this), "baud-rate")();
        restart();
    }

    version(HasGPIO)
    {
        final ubyte tx_gpio() const pure
            => _tx_gpio;
        final void tx_gpio(ubyte value)
        {
            if (_tx_gpio == value)
            {
                mark_assigned!(typeof(this), "tx-gpio")();
                return;
            }
            _tx_gpio = value;
            mark_set!(typeof(this), "tx-gpio")();
            restart();
        }

        final ubyte rx_gpio() const pure
            => _rx_gpio;
        final void rx_gpio(ubyte value)
        {
            if (_rx_gpio == value)
            {
                mark_assigned!(typeof(this), "rx-gpio")();
                return;
            }
            _rx_gpio = value;
            mark_set!(typeof(this), "rx-gpio")();
            restart();
        }
    }


    override const(char)[] status_message() const
    {
        static if (has_socketcan)
        {
            if (!_adapter.empty && _baud_rate == 0)
                return "the CAN link has no bit timing; set baud-rate to configure the bus";
        }
        return super.status_message();
    }


    // API...

protected:

    override bool validate() const
    {
        // `adapter` and `stream` are mutually exclusive: each setter clears the other, so
        // both being set means the config was assembled some other way and is incoherent.
        if (!_adapter.empty)
        {
            if (_stream !is null)
                return false;
            static if (has_socketcan)
            {
                // A CAN link cannot be raised without bit timing. A discovered controller
                // that has none reads back 0, and stays invalid until given a rate.
                return _baud_rate > 0;
            }
            else static if (num_can > 0)
                return _baud_rate > 0;
            else
                return false;
        }
        return _stream !is null && _protocol == CANInterfaceProtocol.ebyte;
    }

    override CompletionStatus startup()
    {
        if (!_adapter.empty)
        {
            static if (has_socketcan)
            {
                if (!_sock.valid)
                {
                    // Two interfaces on one controller would both bounce the link and both
                    // ingest every frame; the Espressif path refuses the same way.
                    foreach (e; Collection!CANInterface().values)
                    {
                        if (e !is this && e.running && e.adapter == _adapter[])
                        {
                            log.error("CAN adapter '", _adapter, "' is already claimed by '", e.name, "'");
                            return CompletionStatus.error;
                        }
                    }

                    if (!configure_link())
                        return CompletionStatus.error;
                    StringResult r = _sock.open(_adapter[]);
                    if (r.failed)
                    {
                        log.error(r.message);
                        return CompletionStatus.error;
                    }
                }
                register_fdwatch();
            }
            else static if (num_can > 0)
            {
                import urt.atomic : atomicStore, MemoryOrder;

                atomicStore!(MemoryOrder.relaxed)(_native_rx_pending, 0u);
                atomicStore!(MemoryOrder.relaxed)(_native_rx_retry, 0u);
                can_init();
                CanConfig cfg;
                cfg.bitrate = _baud_rate;
                version(HasGPIO)
                {
                    cfg.tx_gpio = _tx_gpio;
                    cfg.rx_gpio = _rx_gpio;
                }
                ubyte port = cast(ubyte)_can_port;
                if (_native_interfaces[port] !is null && _native_interfaces[port] !is this)
                {
                    can_deinit();
                    writeError("CAN controller is already in use");
                    return CompletionStatus.error;
                }
                _native_interfaces[port] = this;
                auto result = can_open(_can, port, cfg, &native_rx_ready);
                if (!result)
                {
                    _native_interfaces[port] = null;
                    can_deinit();
                    writeError("CAN init failed for '", name, "'");
                    return CompletionStatus.error;
                }
            }
            return CompletionStatus.complete;
        }

        if (!_stream)
            return CompletionStatus.error;
        if (_stream.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override void online()
    {
        super.online();

        // an ebyte module hides the CAN bus behind a UART, and its bus bitrate is configured out of band,
        // so the serial link is both the rate we know and the one that actually limits us
        if (!_adapter.empty)
            set_link_speed(_baud_rate);
        else if (Stream s = _stream)
            set_link_speed(s.tx_link_speed, s.rx_link_speed);
    }

    override CompletionStatus shutdown()
    {
        _tail_bytes = 0;
        _resyncing = false;
        static if (has_socketcan)
        {
            unregister_fdwatch();
            _sock.close();
        }
        if (_can.is_open)
        {
            ubyte port = _can.port;
            can_set_rx_callback(_can, null);
            can_close(_can);
            import urt.atomic : atomicStore, MemoryOrder;
            atomicStore!(MemoryOrder.release)(_native_rx_pending, 0u);
            atomicStore!(MemoryOrder.release)(_native_rx_retry, 0u);
            static if (num_can > 0)
                if (port < num_can && _native_interfaces[port] is this)
                    _native_interfaces[port] = null;
            can_deinit();
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        static if (has_socketcan)
        {
            if (_sock.valid)
            {
                super.update();     // frames arrive through the fd watcher, not a tick
                return;
            }
        }

        if (_can.is_open)
        {
            import urt.atomic : cas;
            if (cas(&_native_rx_retry, 1u, 0u))
                native_rx_event(getTime());
            super.update();
            return;
        }

        if (!_stream || !_stream.running)
            return restart();

        super.update();

        MonoTime now = getTime();

        // check for data
        ubyte[1024] buffer = void;
        buffer[0 .. _tail_bytes] = _tail[0 .. _tail_bytes];
        ptrdiff_t readOffset = _tail_bytes;
        ptrdiff_t length = _tail_bytes;
        _tail_bytes = 0;
        read_loop: while (true)
        {
            assert(length < LargestProtocolFrame);

            ptrdiff_t r = stream.read(buffer[readOffset .. $]);
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

            // TODO: implement stream dump...
//            if (connParams.logDataStream)
//                logStream.rawWrite(buffer[0 .. length]);

            Packet packet;

            size_t offset = 0;
            parse_loop: while (offset < length)
            {
                ref CANFrame can = packet.init!CANFrame(null, now);

                size_t taken = 0;
                switch (protocol)
                {
                    case CANInterfaceProtocol.ebyte:
                        if (length - offset < EbyteFrameSize)
                            break parse_loop;

                        const ubyte[] ebyte_frame = buffer[offset .. offset + EbyteFrameSize];
                        if (!validate_ebyte_frame(ebyte_frame))
                        {
                            // out of sync; slide one byte and try again
                            if (!_resyncing)
                            {
                                add_rx_drop();
                                _resyncing = true;
                            }
                            ++offset;
                            continue parse_loop;
                        }

                        // confidence check: if any bytes follow, validate as much of the next frame as we can
                        size_t next = offset + EbyteFrameSize;
                        if (next < length)
                        {
                            size_t avail = length - next;
                            if (!validate_ebyte_frame(buffer[next .. next + min(avail, EbyteFrameSize)]))
                            {
                                if (!_resyncing)
                                {
                                    add_rx_drop();
                                    _resyncing = true;
                                }
                                ++offset;
                                continue parse_loop;
                            }
                        }

                        _resyncing = false;

                        can.remote_transmission_request = (ebyte_frame[0] & 0x40) != 0;
                        can.extended = (ebyte_frame[0] & 0x80) != 0;
                        can.id = ebyte_frame[1 .. 5].bigEndianToNative!uint;
                        packet.data = ebyte_frame[5 .. 5 + (ebyte_frame[0] & 0xF)];
                        taken = EbyteFrameSize;
                        break;

                    default:
                        assert(false);
                }

                offset += taken;

                version (DebugCANInterface)
                    writeDebug("CAN packet received from interface '", name, "': id=", can.id, " (", packet.length , ")[ ", packet.data, " - ", packet.data.bin_to_ascii(), " ]");

                incoming_packet(packet);
            }

            // shuffle remaining unparsed bytes to the front for the next read
            size_t remain = length - offset;
            if (remain > 0 && offset > 0)
                memmove(buffer.ptr, buffer.ptr + offset, remain);
            length = remain;
            readOffset = remain;
        }
    }

    override int transmit(ref const Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        // can only handle can packets
        if (packet.type != PacketType.can)
        {
            add_tx_drop();
            return -1;
        }

        if (packet.data.length > 8)
        {
            version (DebugCANInterface)
                writeDebug("CAN packet dropped on interface '", name, "': invalid frame - data too long");
            add_tx_drop();
            return -1;
        }

        ref can = packet.hdr!CANFrame;

        static if (has_socketcan)
        {
            if (_sock.valid)
            {
                can_frame f;
                f.can_id = (can.id & (can.extended ? CAN_EFF_MASK : CAN_SFF_MASK))
                         | (can.extended ? CAN_EFF_FLAG : 0)
                         | (can.remote_transmission_request ? CAN_RTR_FLAG : 0);
                f.len = cast(ubyte)packet.data.length;
                f.data[0 .. f.len] = cast(const ubyte[])packet.data[];
                if (!_sock.send(f))
                {
                    add_tx_drop();
                    return -1;
                }
                add_tx_frame(packet.data.length);
                return 0;
            }
        }

        if (_can.is_open)
        {
            CanFrame hw = void;
            hw.id = can.id;
            hw.extended = can.extended;
            hw.rtr = can.remote_transmission_request;
            hw.dlc = cast(ubyte)packet.data.length;
            hw.data[0 .. hw.dlc] = cast(const ubyte[])packet.data[];
            if (!can_transmit(_can, hw))
            {
                add_tx_drop();
                return -1;
            }
            add_tx_frame(packet.data.length);
            return 0;
        }

        // frame it up and send via stream...
        ubyte[LargestProtocolFrame] buffer = void;
        size_t length = 0;

        switch (protocol)
        {
            case CANInterfaceProtocol.ebyte:
                ubyte dataLen = cast(ubyte)packet.length;
                buffer[0] = (can.extended << 7) | (can.remote_transmission_request << 6) | dataLen;
                buffer[1 .. 5] = can.id.nativeToBigEndian;
                buffer[5 .. 5 + packet.length] = cast(ubyte[])packet.data[];
                buffer[5 + packet.length .. EbyteFrameSize] = 0;
                length = EbyteFrameSize;
                break;

            default:
                assert(false);
        }

        ptrdiff_t written = stream.write(buffer[0 .. length]);

        version (DebugCANInterface)
        {
            if (written <= 0)
                writeDebug("CAN packet send failed on interface '", name, "'");
            else
                writeDebug("CAN packet sent on interface '", name, "': id=", can.id, " (", packet.length, ")[ ", packet.data, " - ", packet.data.bin_to_ascii(), " ]");
        }

        if (written <= 0)
        {
            add_tx_drop();
            return -1;
        }

        add_tx_frame(length);
        return 0;
    }

    override ushort pcap_type() const
        => 227; // CAN_SOCKETCAN

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(const void[] packetData) nothrow @nogc sink) const
    {
        // write socket_can struct...
        struct socket_can
        {
            ubyte[4] id;
            ubyte len;
            ubyte __pad;
            ubyte __res0;
            ubyte len8_dlc; // optional DLC for 8 byte payload length (9 .. 15) (????)
            ubyte[8] data;
        }
        static assert(socket_can.sizeof == 16);

        ref can = packet.hdr!CANFrame;

        socket_can f;
        f.id = can.id.nativeToBigEndian;
        f.id[0] |= can.extended << 7;
        f.id[0] |= can.remote_transmission_request << 6;
        f.len = cast(ubyte)packet.length;
        f.data[0 .. f.len] = cast(const ubyte[])packet.data[];

        // TODO: what's the go with the error bit (bit 29 of ID)???

        sink((cast(ubyte*)&f)[0 .. socket_can.sizeof]);
    }

private:
    ObjectRef!Stream _stream;
    CANInterfaceProtocol _protocol;
    String _adapter;
    byte _can_port = -1;
    uint _baud_rate = 500_000;
    ubyte[LargestProtocolFrame] _tail;
    ushort _tail_bytes;
    bool _resyncing;

    version(HasGPIO)
    {
        ubyte _tx_gpio;
        ubyte _rx_gpio;
    }

    Can _can;
    shared uint _native_rx_pending;
    shared uint _native_rx_retry;

    static bool valid_adapter_name(const(char)[] value)
    {
        static if (has_socketcan)
            return value.length < 16;
        else static if (num_can > 0)
            return value.length == 5 && value[0 .. 4] == "twai" &&
                   value[4] >= '0' && value[4] <= '9' && value[4] - '0' < num_can;
        else
            return false;
    }

    static if (has_socketcan)
    {
        CANSocket _sock;
        can_frame _rx_frame;    // a member, so a published packet slice outlives drain_socket()
        bool _fdwatch_registered;

        void register_fdwatch()
        {
            if (!_fdwatch_registered && add_fd_watcher(&service_io, &collect_fds))
            {
                _fdwatch_registered = true;
                fd_watch_changed();
            }
        }

        void unregister_fdwatch()
        {
            if (_fdwatch_registered)
            {
                remove_fd_watcher(&service_io);
                _fdwatch_registered = false;
                fd_watch_changed();
            }
        }

        void collect_fds(ref Array!pollfd fds)
        {
            if (_sock.valid)
                fds ~= pollfd(_sock.fd, POLLIN);
        }

        void service_io()
        {
            // `running` matters: destroy() announces itself and goes offline a pass before the
            // state machine runs shutdown(), and the pool drain fires in that window
            if (running && _sock.valid)
                drain_socket();
        }

        // The link is bounced only when `baud-rate` actually differs from what the link
        // already carries, so adopting a bus leaves its timing untouched and changing the
        // property is what pushes a new rate down.
        bool configure_link()
        {
            // Confirm this really is a CAN controller before touching it. `adapter` is a free
            // string, and downing whatever netdev the name resolves to would cost an operator
            // their management NIC over a typo.
            if (read_link_type(_adapter[]) != ARPHRD_CAN)
            {
                log.error("'", _adapter, "' is not a CAN controller");
                return false;
            }

            int ifindex = netlink_ifindex(_adapter[]);
            if (ifindex == 0)
            {
                log.error("no such CAN adapter '", _adapter, "'");
                return false;
            }

            if (netlink_get_can_bitrate(ifindex) != _baud_rate)
            {
                // the kernel only accepts bit timing while the link is down
                int down = netlink_set_link_up(ifindex, false);
                if (down != 0)
                {
                    log.error("failed to take '", _adapter, "' down: ", down);
                    return false;
                }

                int set = netlink_set_can_bitrate(ifindex, _baud_rate);
                if (set != 0)
                {
                    log.error("failed to set bitrate ", _baud_rate, " on '", _adapter, "': ", set);
                    // raise it again rather than leaving a bus we downed permanently dead; if
                    // it had no timing to begin with this fails harmlessly and it was down anyway
                    netlink_set_link_up(ifindex, true);
                    return false;
                }
            }

            int up = netlink_set_link_up(ifindex, true);
            if (up != 0)
            {
                log.error("failed to bring up '", _adapter, "': ", up);
                return false;
            }
            return true;
        }

        void drain_socket()
        {
            MonoTime ts;
            while (true)
            {
                int res = _sock.poll(_rx_frame, ts);
                if (res == 0)
                    break;
                if (res < 0)
                {
                    // The link went down under us or the netdev vanished. The socket stays
                    // open and simply reports EAGAIN forever after, so it would sit there
                    // deaf and claiming to run. Close it; update() sees an invalid socket
                    // with no stream behind it and restarts us.
                    log.error("receive failed on '", _adapter, "': errno=", _sock.last_recv_error.system_code);
                    _sock.close();
                    return;
                }

                if (_rx_frame.can_id & CAN_ERR_FLAG)    // bus diagnostics, not traffic
                    continue;

                Packet packet;
                bool extended = (_rx_frame.can_id & CAN_EFF_FLAG) != 0;
                ubyte len = _rx_frame.len > 8 ? 8 : _rx_frame.len;
                ref CANFrame can = packet.init!CANFrame(_rx_frame.data[0 .. len], ts);
                can.id = _rx_frame.can_id & (extended ? CAN_EFF_MASK : CAN_SFF_MASK);
                can.extended = extended;
                can.remote_transmission_request = (_rx_frame.can_id & CAN_RTR_FLAG) != 0;
                incoming_packet(packet);
            }
        }
    }

    static if (num_can > 0)
    {
        __gshared CANInterface[num_can] _native_interfaces;

        // Queued RX events bind this stable trampoline rather than an interface instance, so an
        // interface destroyed while its event is still queued is simply absent from the sweep.
        static struct RxSweep
        {
            void event(MonoTime when) nothrow @nogc
            {
                import urt.atomic : atomicLoad, MemoryOrder;
                foreach (iface; _native_interfaces)
                    if (iface !is null && atomicLoad!(MemoryOrder.acquire)(iface._native_rx_pending) != 0)
                        iface.native_rx_event(when);
            }
        }
        __gshared RxSweep _rx_sweep;
    }

    static bool native_rx_ready(Can can, CanCallbackContext context)
    {
        static if (num_can == 0)
            return false;
        else
        {
            if (can.port >= num_can || g_app is null)
                return false;
            CANInterface instance = _native_interfaces[can.port];
            if (instance is null)
                return false;

            import urt.atomic : atomicStore, cas, MemoryOrder;
            if (!cas(&instance._native_rx_pending, 0u, 1u))
                return false;

            bool queued;
            bool higher_priority_task_woken;
            final switch (context)
            {
                case CanCallbackContext.thread:
                    queued = g_app.post_event(&_rx_sweep.event, getTime(), EventPriority.bulk);
                    break;
                case CanCallbackContext.interrupt:
                    higher_priority_task_woken = g_app.post_event_from_isr(&_rx_sweep.event, EventPriority.bulk, queued);
                    break;
            }
            if (!queued)
            {
                atomicStore!(MemoryOrder.release)(instance._native_rx_pending, 0u);
                atomicStore!(MemoryOrder.release)(instance._native_rx_retry, 1u);
            }
            return higher_priority_task_woken;
        }
    }

    void native_rx_event(MonoTime when)
    {
        import urt.atomic : atomicStore, MemoryOrder;
        atomicStore!(MemoryOrder.release)(_native_rx_pending, 0u);
        atomicStore!(MemoryOrder.release)(_native_rx_retry, 0u);
        if (_can.is_open && running)
            drain_native(when);
    }

    void drain_native(MonoTime now)
    {
        CanFrame hw = void;

        while (can_receive(_can, hw))
        {
            Packet packet;
            ref CANFrame can = packet.init!CANFrame(hw.data[0 .. hw.dlc], now);
            can.id = hw.id;
            can.extended = hw.extended;
            can.remote_transmission_request = hw.rtr;
            incoming_packet(packet);
        }

        uint dropped = can_take_rx_drops(_can);
        if (dropped != 0)
        {
            _status.rx_dropped += dropped;
            mark_set!(typeof(this), "rx-dropped")();
            log.warning("deferred RX queue dropped ", dropped, " frame", dropped == 1 ? "" : "s");
        }
    }
}


private:

enum EbyteFrameSize = 13;
enum LargestProtocolFrame = EbyteFrameSize;

bool valid_ebyte_header(ubyte b) pure nothrow @nogc
    => (b & 0x30) == 0 && (b & 0xF) <= 8;

bool validate_ebyte_frame(const ubyte[] f) pure nothrow @nogc
    in (f.length >= 1 && f.length <= EbyteFrameSize)
{
    if (!valid_ebyte_header(f[0]))
        return false;
    bool extended = (f[0] & 0x80) != 0;
    if (extended)
    {
        if (f.length >= 2 && (f[1] & 0xE0) != 0)
            return false;
    }
    else
    {
        if (f.length >= 2 && f[1] != 0)
            return false;
        if (f.length >= 3 && f[2] != 0)
            return false;
        if (f.length >= 4 && (f[3] & 0xF8) != 0)
            return false;
    }
    size_t pad_start = 5 + (f[0] & 0xF);
    if (f.length > pad_start)
    {
        foreach (b; f[pad_start .. $])
        {
            if (b != 0)
                return false;
        }
    }
    return true;
}

version (DebugCANInterface)
{
    // TODO: maybe this function is cool in other palces where we log binary?
    char[] bin_to_ascii(const void[] bin)
    {
        import urt.mem.temp : talloc;
        char[] t = cast(char[])talloc(bin.length);
        t[] = cast(char[])bin[];
        foreach (ref c; t)
            c = is_control_char(c) ? '.' : c;
        return t;
    }
}
