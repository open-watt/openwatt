module driver.rtc.pcf85063;

import urt.log;
import urt.result;
import urt.time;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.i2c;

nothrow @nogc:

enum PCF85063Error : ubyte
{
    none,
    transport,
    oscillator_stopped,
    invalid_time,
}


class PCF85063 : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("address", address),
                                 Prop!("time", time),
                                 Prop!("last-error", last_error, "status", "d"));
nothrow @nogc:

    enum type_name = "pcf85063";
    enum path = "/driver/rtc/pcf85063";
    enum collection_id = CollectionType.rtc;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PCF85063, id, flags);
    }

    inout(I2CInterface) iface() inout pure
        => _iface;

    void iface(I2CInterface value)
    {
        if (_iface.get is value)
            return;
        unsubscribe();
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    ushort address() const pure
        => _address;

    void address(ushort value)
    {
        if (_address == value)
            return;
        _address = value;
        mark_set!(typeof(this), "address")();
        restart();
    }

    SysTime time() const pure
        => _time;

    PCF85063Error last_error() const pure
        => _last_error;

    StringResult time(SysTime value)
    {
        I2CInterface interface_ = _iface.get;
        if (!interface_ || !interface_.running)
            return StringResult("RTC interface is offline");
        if (_operation != Operation.none)
            return StringResult("RTC is busy");

        DateTime date_time = get_date_time(value);
        if (!begin_write(date_time))
            return StringResult("RTC write could not be queued");

        _writing = true;
        set_utc_time(unix_time_ns(value));
        _writing = false;

        _time = value;
        _time_valid = true;
        mark_set!(typeof(this), "time")();
        return StringResult.success;
    }

    override const(char)[] status_message() const pure
    {
        if (running && !_time_valid)
            return "Waiting for clock source";
        return super.status_message();
    }

protected:

    override bool validate() const
    {
        return _iface !is null && _address <= 0x7F;
    }

    override CompletionStatus startup()
    {
        I2CInterface interface_ = _iface.get;
        if (!interface_ || !interface_.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            interface_.subscribe(&packet_handler, PacketFilter(type: PacketType.i2c, direction: PacketDirection.incoming));
            interface_.subscribe(&interface_state_change);
            subscribe_clock_change(&clock_changed);
            _subscribed = true;
        }

        if (_operation == Operation.none)
        {
            set_last_error(PCF85063Error.none);
            if (!begin_read())
            {
                set_last_error(PCF85063Error.transport);
                return CompletionStatus.error;
            }
            return CompletionStatus.continue_;
        }

        if (_request_failed)
        {
            if (_last_error == PCF85063Error.oscillator_stopped)
            {
                log.info("RTC has never been set; waiting for a clock source");
                set_last_error(PCF85063Error.none);
                reset_operation();
                return CompletionStatus.complete;
            }
            if (_last_error == PCF85063Error.none)
                set_last_error(PCF85063Error.transport);
            log.error("failed to read RTC at address ", _address);
            reset_operation();
            return CompletionStatus.error;
        }
        if (!_message_done || !_response_received)
            return CompletionStatus.continue_;

        _time = get_sys_time(_response_time);
        _time_valid = true;
        set_utc_time(unix_time_ns(_time));
        mark_set!(typeof(this), "time")();
        log.info("restored UTC time ", _response_time);
        reset_operation();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        I2CInterface interface_ = _iface.get;
        if (_message_handle > 0 && interface_ && interface_.running)
        {
            interface_.abort(_message_handle);
            return CompletionStatus.continue_;
        }
        unsubscribe();
        reset_operation();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_operation == Operation.write && _message_done)
        {
            if (_request_failed)
                log.error("failed to persist updated UTC time");
            else
            {
                _time = get_sys_time();
                _time_valid = true;
                mark_set!(typeof(this), "time")();
                set_last_error(PCF85063Error.none);
            }
            reset_operation();
        }
    }

private:

    enum Operation : ubyte
    {
        none,
        read,
        write,
    }

    ObjectRef!I2CInterface _iface;
    ushort _address = 0x51;
    ushort _sequence;
    int _message_handle;
    Operation _operation;
    bool _subscribed;
    bool _message_done;
    bool _response_received;
    bool _request_failed;
    bool _writing;
    bool _time_valid;
    PCF85063Error _last_error;
    SysTime _time;
    DateTime _response_time;

    void unsubscribe()
    {
        if (!_subscribed)
            return;
        _iface.unsubscribe(&interface_state_change);
        _iface.unsubscribe(&packet_handler);
        unsubscribe_clock_change(&clock_changed);
        _subscribed = false;
    }

    void interface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void clock_changed(long)
    {
        if (_writing || !_iface || !wall_time_set())
            return;
        if (_operation == Operation.none)
            begin_write(get_date_time());
    }

    bool begin_read()
    {
        ubyte register_ = 0x04;
        return send(Operation.read, (&register_)[0 .. 1], 7);
    }

    bool begin_write(DateTime value)
    {
        if (value.year < 2000 || value.year > 2099 || value.month < Month.January || value.month > Month.December ||
            value.day < 1 || value.day > 31 || value.hour > 23 || value.minute > 59 || value.second > 59)
            return false;

        ubyte[8] data = [
            0x04,
            to_bcd(value.second),
            to_bcd(value.minute),
            to_bcd(value.hour),
            to_bcd(value.day),
            cast(ubyte)value.wday,
            to_bcd(cast(uint)value.month),
            to_bcd(cast(uint)value.year - 2000),
        ];
        return send(Operation.write, data[], 0);
    }

    bool send(Operation operation, const(void)[] data, ushort read_length)
    {
        I2CInterface interface_ = _iface.get;
        if (!interface_ || !interface_.running || _operation != Operation.none)
            return false;

        Packet request;
        ref frame = request.init!I2CFrame(data);
        frame.sequence_number = ++_sequence;
        frame.address = _address;
        frame.read_length = read_length;
        frame.type = I2CFrameType.request;
        frame.flags = I2CFrameFlags.none;

        _operation = operation;
        _message_done = false;
        _response_received = false;
        _request_failed = false;
        int handle = interface_.forward(request, &message_complete);
        if (handle <= 0)
        {
            reset_operation();
            return false;
        }
        if (!_message_done)
            _message_handle = handle;
        return true;
    }

    void message_complete(int handle, MessageState state)
    {
        if (_operation == Operation.none)
            return;
        bool recover = _operation == Operation.write && !running;
        _message_handle = 0;
        _message_done = true;
        if (state != MessageState.complete)
        {
            _request_failed = true;
            set_last_error(PCF85063Error.transport);
        }
        if (recover)
        {
            bool complete = state == MessageState.complete;
            if (complete)
                set_last_error(PCF85063Error.none);
            reset_operation();
            if (complete)
                restart();
        }
    }

    void packet_handler(ref const Packet packet, BaseInterface, PacketDirection direction, void*)
    {
        if (direction != PacketDirection.incoming || packet.type != PacketType.i2c || _operation != Operation.read)
            return;

        ref frame = packet.hdr!I2CFrame;
        if (frame.type != I2CFrameType.response || frame.sequence_number != _sequence || frame.address != _address || packet.data.length != 7)
            return;

        DateTime value;
        PCF85063Error error = decode_time(cast(const(ubyte)[])packet.data, value);
        set_last_error(error);
        if (error != PCF85063Error.none)
        {
            _request_failed = true;
            return;
        }
        _response_time = value;
        _response_received = true;
    }

    void reset_operation()
    {
        _message_handle = 0;
        _operation = Operation.none;
        _message_done = false;
        _response_received = false;
        _request_failed = false;
    }

    void set_last_error(PCF85063Error error)
    {
        if (_last_error == error)
            return;
        _last_error = error;
        mark_set!(typeof(this), "last-error")();
    }

    static PCF85063Error decode_time(const(ubyte)[] data, out DateTime value)
    {
        if (data.length != 7)
            return PCF85063Error.invalid_time;
        if (data[0] & 0x80)
            return PCF85063Error.oscillator_stopped;

        ubyte[6] bcd = [ data[0] & 0x7F, data[1] & 0x7F, data[2] & 0x3F, data[3] & 0x3F, data[5] & 0x1F, data[6] ];
        foreach (digits; bcd)
            if ((digits & 0x0F) > 9 || (digits >> 4) > 9)
                return PCF85063Error.invalid_time;

        uint second = from_bcd(bcd[0]);
        uint minute = from_bcd(bcd[1]);
        uint hour = from_bcd(bcd[2]);
        uint day = from_bcd(bcd[3]);
        uint weekday = data[4] & 0x07;
        uint month = from_bcd(bcd[4]);
        uint year = from_bcd(bcd[5]);

        if (second > 59 || minute > 59 || hour > 23 || day < 1 || day > 31 || weekday > 6 || month < 1 || month > 12)
            return PCF85063Error.invalid_time;

        value = DateTime(cast(short)(2000 + year), cast(Month)month, cast(Day)weekday, cast(ubyte)day,
                         cast(ubyte)hour, cast(ubyte)minute, cast(ubyte)second);
        return PCF85063Error.none;
    }
}

class PCF85063Module : Module
{
    mixin DeclareModule!"driver.rtc.pcf85063";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!PCF85063Error();
        g_app.console.register_collection!PCF85063();
    }

    override void update()
    {
        Collection!PCF85063().update_all();
    }
}


private:

uint from_bcd(ubyte value)
{
    return (value >> 4) * 10 + (value & 0x0F);
}

ubyte to_bcd(uint value)
{
    return cast(ubyte)((value / 10) << 4 | value % 10);
}


unittest
{
    assert(to_bcd(59) == 0x59);
    assert(from_bcd(0x59) == 59);

    DateTime value;
    ubyte[7] regs = [ 0x30, 0x59, 0x23, 0x28, 0x06, 0x02, 0x26 ];  // sat 2026-02-28 23:59:30
    assert(PCF85063.decode_time(regs[], value) == PCF85063Error.none);
    assert(value.year == 2026 && value.month == Month.February && value.day == 28 &&
           value.hour == 23 && value.minute == 59 && value.second == 30);

    assert(PCF85063.decode_time(regs[0 .. 6], value) == PCF85063Error.invalid_time);

    ubyte[7] stopped = regs;
    stopped[0] |= 0x80;
    assert(PCF85063.decode_time(stopped[], value) == PCF85063Error.oscillator_stopped);

    ubyte[7] bad_digit = regs;
    bad_digit[0] = 0x1A;  // nibble > 9 must not decode as 20 seconds
    assert(PCF85063.decode_time(bad_digit[], value) == PCF85063Error.invalid_time);

    ubyte[7] bad_range = regs;
    bad_range[2] = 0x24;  // hour 24
    assert(PCF85063.decode_time(bad_range[], value) == PCF85063Error.invalid_time);
}
