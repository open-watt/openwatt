module router.iface.i2c;

import urt.array;
import urt.driver.i2c;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.result;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.priority_queue;

nothrow @nogc:


enum I2CFrameType : ubyte
{
    request,
    response,
}

enum I2CFrameFlags : ubyte
{
    none = 0,
    ten_bit_address = 1 << 0,
}

struct I2CFrame
{
nothrow @nogc:
    enum Type = PacketType.i2c;

    ushort sequence_number;
    ushort address;
    ushort read_length;
    I2CFrameType type;
    I2CFrameFlags flags;

    static ulong extract_src(ref const Packet packet) pure
    {
        ref const frame = packet.hdr!I2CFrame;
        ulong address = frame.type == I2CFrameType.response ? universal_address(frame) : 0;
        address |= ulong(packet.vlan & 0xFFF) << 48;
        address |= ulong(PacketType.i2c) << 60;
        return address;
    }

    static ulong extract_dst(ref const Packet packet) pure
    {
        ref const frame = packet.hdr!I2CFrame;
        ulong address = frame.type == I2CFrameType.request ? universal_address(frame) : 0;
        address |= ulong(packet.vlan & 0xFFF) << 48;
        address |= ulong(PacketType.i2c) << 60;
        return address;
    }

    static bool is_multicast(ulong address) pure
        => (address & 0x3FF) == 0;

    static ptrdiff_t encode_ow_header(ref const Packet packet, ubyte[] buffer)
    {
        if (buffer.length < 8)
            return -1;
        ref const frame = packet.hdr!I2CFrame;
        buffer[0 .. 2] = frame.sequence_number.nativeToBigEndian;
        buffer[2 .. 4] = frame.address.nativeToBigEndian;
        buffer[4 .. 6] = frame.read_length.nativeToBigEndian;
        buffer[6] = frame.type;
        buffer[7] = frame.flags;
        return 8;
    }

    static ptrdiff_t decode_ow_header(ref Packet packet, const(ubyte)[] header)
    {
        if (header.length < 8)
            return -1;
        packet.type = PacketType.i2c;
        ref frame = packet.hdr!I2CFrame;
        frame.sequence_number = header[0 .. 2].bigEndianToNative!ushort;
        frame.address = header[2 .. 4].bigEndianToNative!ushort;
        frame.read_length = header[4 .. 6].bigEndianToNative!ushort;
        frame.type = cast(I2CFrameType)header[6];
        frame.flags = cast(I2CFrameFlags)header[7];
        return 8;
    }

private:
    static ulong universal_address(ref const I2CFrame frame) pure
    {
        ulong result = frame.address;
        if (frame.flags & I2CFrameFlags.ten_bit_address)
            result |= ulong(1) << 10;
        return result;
    }
}

class I2CInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("device", device),
                                 Prop!("frequency", frequency),
                                 Prop!("sda-gpio", sda_gpio),
                                 Prop!("scl-gpio", scl_gpio),
                                 Prop!("internal-pullups", internal_pullups),
                                 Prop!("last-error", last_error, "status", "d"));
nothrow @nogc:

    enum type_name = "i2c";
    enum path = "/interface/i2c";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!I2CInterface, id, flags);
        _max_l2mtu = 4096;
        _l2mtu = 256;
        mark_set!(typeof(this), "max-l2mtu")();

        _queue.init(1, 0, PCP.vo, this);
        _operation.user_data = cast(void*)this;
        _operation.callback = &operation_complete;
    }

    String device() const pure
        => _device;

    StringResult device(String value)
    {
        uint port = value.length == 4 && value[][0 .. 3] == "i2c" ? uint(value[][3] - '0') : uint.max;
        if (port >= i2c_count())
            return StringResult("invalid I2C device");
        _port = cast(byte)port;
        _device = value.move;
        mark_set!(typeof(this), "device")();
        restart();
        return StringResult.success;
    }

    uint frequency() const pure
        => _config.frequency;

    StringResult frequency(uint value)
    {
        if (value == 0)
            return StringResult("frequency must be greater than zero");
        _config.frequency = value;
        mark_set!(typeof(this), "frequency")();
        restart();
        return StringResult.success;
    }

    ubyte sda_gpio() const pure
        => _config.sda_gpio;

    void sda_gpio(ubyte value)
    {
        _config.sda_gpio = value;
        mark_set!(typeof(this), "sda-gpio")();
        restart();
    }

    ubyte scl_gpio() const pure
        => _config.scl_gpio;

    void scl_gpio(ubyte value)
    {
        _config.scl_gpio = value;
        mark_set!(typeof(this), "scl-gpio")();
        restart();
    }

    bool internal_pullups() const pure
        => _config.internal_pullups;

    void internal_pullups(bool value)
    {
        _config.internal_pullups = value;
        mark_set!(typeof(this), "internal-pullups")();
        restart();
    }

    I2cError last_error() const pure
        => _last_error;

    override void abort(int message_handle, MessageState reason = MessageState.aborted)
    {
        if (message_handle == _active_tag)
        {
            _active_cancelled = true;
            return;
        }
        _queue.abort(cast(ubyte)message_handle, reason);
    }

    override MessageState msg_state(int message_handle) const
    {
        ubyte tag = cast(ubyte)message_handle;
        if (_queue.is_queued(tag))
            return MessageState.queued;
        if (_queue.find_in_flight(tag))
            return MessageState.in_flight;
        return MessageState.complete;
    }

protected:

    override bool validate() const
    {
        return _port >= 0 && _port < i2c_count() && _config.frequency > 0 &&
               _config.sda_gpio != ubyte.max && _config.scl_gpio != ubyte.max && _config.sda_gpio != _config.scl_gpio;
    }

    override CompletionStatus startup()
    {
        import urt.atomic : atomicStore, MemoryOrder;

        atomicStore!(MemoryOrder.relaxed)(_completion_retry, 0u);
        if (_active_buses[_port] !is null && _active_buses[_port] !is this)
        {
            writeError("I2C controller is already in use");
            return CompletionStatus.error;
        }
        _active_buses[_port] = this;
        if (!i2c_open(_bus, cast(ubyte)_port, _config))
        {
            _active_buses[_port] = null;
            return CompletionStatus.error;
        }
        _last_error = I2cError.none;
        mark_set!(typeof(this), "last-error")();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_operation.is_done)
            service_completion();
        if (_operation.is_pending)
            return CompletionStatus.continue_;

        _queue.abort_all();
        _active_tag = 0;
        _active_cancelled = false;
        import urt.atomic : atomicStore, MemoryOrder;

        atomicStore!(MemoryOrder.release)(_completion_retry, 0u);
        if (_bus.is_open)
            i2c_close(_bus);
        if (_port >= 0 && _port < num_i2c && _active_buses[_port] is this)
            _active_buses[_port] = null;
        return CompletionStatus.complete;
    }

    override void update()
    {
        import urt.atomic : cas;

        // Normal completion is reactor-dispatched; this recovers a rejected event post.
        if (cas(&_completion_retry, 1u, 0u) && _operation.is_done)
            service_completion();
        drive_queue();
        super.update();
    }

    override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)* policy)
    {
        if (packet.type != PacketType.i2c)
        {
            add_tx_drop();
            return -1;
        }

        ref frame = packet.hdr!I2CFrame;
        bool ten_bit = (frame.flags & I2CFrameFlags.ten_bit_address) != 0;
        if (frame.type != I2CFrameType.request || (packet.data.length == 0 && frame.read_length == 0) ||
            packet.data.length > l2mtu || frame.read_length > l2mtu || (!ten_bit && frame.address > 0x7F) || (ten_bit && frame.address > 0x3FF))
        {
            add_tx_drop();
            return -1;
        }

        int tag = _queue.enqueue(packet, callback, policy);
        if (tag < 0)
        {
            add_tx_drop();
            return -1;
        }
        drive_queue();
        return tag;
    }

private:

    String _device;
    byte _port = -1;
    I2cBusConfig _config;
    I2cBus _bus;
    I2cOperation _operation;
    I2cError _last_error;
    PriorityPacketQueue _queue;
    Array!ubyte _read_buffer;
    ushort _sequence_number;
    ubyte _active_tag;
    bool _active_cancelled;
    shared uint _completion_retry;

    __gshared I2CInterface[num_i2c] _active_buses;

    // Queued completion events bind this stable trampoline rather than an interface instance, so
    // an interface destroyed while its event is still queued is simply absent from the sweep.
    static struct CompletionSweep
    {
        void event(MonoTime when) nothrow @nogc
        {
            foreach (bus; _active_buses)
                if (bus !is null)
                    bus.completion_event(when);
        }
    }
    __gshared CompletionSweep _completion_sweep;

    static bool operation_complete(ref I2cOperation operation, I2cCallbackContext context)
    {
        I2CInterface instance = cast(I2CInterface)operation.user_data;
        if (!instance || !g_app)
            return false;

        bool queued;
        bool higher_priority_task_woken;
        final switch (context)
        {
            case I2cCallbackContext.task:
                queued = g_app.post_event(&_completion_sweep.event, getTime(), EventPriority.control);
                break;
            case I2cCallbackContext.interrupt:
                higher_priority_task_woken = g_app.post_event_from_isr(&_completion_sweep.event, EventPriority.control, queued);
                break;
        }
        if (!queued)
        {
            import urt.atomic : atomicStore, MemoryOrder;
            atomicStore!(MemoryOrder.release)(instance._completion_retry, 1u);
        }
        return higher_priority_task_woken;
    }

    void completion_event(MonoTime)
    {
        if (_operation.is_done)
            service_completion();
    }

    void drive_queue()
    {
        if (!running || _operation.is_pending || _active_tag != 0)
            return;

        QueuedFrame* queued = _queue.dequeue();
        if (!queued)
            return;

        ref frame = queued.packet.hdr!I2CFrame;
        void[] read_data;
        if (frame.read_length)
        {
            _read_buffer.clear();
            read_data = _read_buffer.extend(frame.read_length);
        }

        I2cTransfer transfer;
        transfer.address = frame.address;
        transfer.address_mode = frame.flags & I2CFrameFlags.ten_bit_address ? I2cAddressMode.ten_bit : I2cAddressMode.seven_bit;
        transfer.write_data = queued.packet.data;
        transfer.read_data = read_data;
        transfer.timeout = 100.msecs;

        _operation.reset();
        _active_tag = queued.tag;
        _active_cancelled = false;
        if (!i2c_submit(_bus, _operation, transfer))
        {
            _last_error = I2cError.bus;
            mark_set!(typeof(this), "last-error")();
            _queue.complete(_active_tag, MessageState.failed);
            _active_tag = 0;
            add_tx_drop();
            drive_queue();
        }
    }

    void service_completion()
    {
        if (!_operation.is_done || _active_tag == 0)
            return;

        ubyte tag = _active_tag;
        const(QueuedFrame)* queued = _queue.find_in_flight(tag);
        if (!queued)
            return;

        I2cOperationState state = _operation.state;
        _last_error = _operation.error;
        mark_set!(typeof(this), "last-error")();

        MessageState message_state = state == I2cOperationState.complete ? MessageState.complete : MessageState.failed;
        if (_active_cancelled)
            message_state = MessageState.aborted;

        if (message_state == MessageState.complete)
        {
            ref request = queued.packet.hdr!I2CFrame;
            add_tx_frame(queued.packet.length);

            if (request.read_length)
            {
                Packet response;
                ref frame = response.init!I2CFrame(_read_buffer[0 .. request.read_length]);
                frame.sequence_number = request.sequence_number;
                frame.address = request.address;
                frame.read_length = 0;
                frame.type = I2CFrameType.response;
                frame.flags = request.flags;
                incoming_packet(response);
            }
        }
        else
        {
            add_tx_drop();
        }

        _queue.complete(tag, message_state);
        _active_tag = 0;
        _active_cancelled = false;
        _operation.reset();
        drive_queue();
    }
}

class I2CModule : Module
{
    mixin DeclareModule!"router.iface.i2c";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!I2CFrame();
        g_app.register_enum!I2CFrameType();
        g_app.register_enum!I2cError();
        g_app.console.register_collection!I2CInterface();
    }
}


unittest
{
    ubyte[4] payload = [ 1, 2, 3, 4 ];
    Packet packet;
    ref I2CFrame frame = packet.init!I2CFrame(payload[]);
    frame.sequence_number = 0x1234;
    frame.address = 0x351;
    frame.read_length = 7;
    frame.type = I2CFrameType.request;
    frame.flags = I2CFrameFlags.ten_bit_address;

    ubyte[8] header;
    assert(I2CFrame.encode_ow_header(packet, header[]) == 8);
    assert(I2CFrame.encode_ow_header(packet, header[0 .. 7]) == -1);

    Packet decoded;
    assert(I2CFrame.decode_ow_header(decoded, header[0 .. 7]) == -1);
    assert(I2CFrame.decode_ow_header(decoded, header[]) == 8);
    ref result = decoded.hdr!I2CFrame;
    assert(result.sequence_number == 0x1234 && result.address == 0x351 && result.read_length == 7 &&
           result.type == I2CFrameType.request && result.flags == I2CFrameFlags.ten_bit_address);
    assert(I2CFrame.extract_dst(packet) == I2CFrame.extract_dst(decoded));
}
