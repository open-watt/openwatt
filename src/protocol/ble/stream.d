module protocol.ble.stream;

import urt.array;
import urt.lifetime;
import urt.result;
import urt.string;
import urt.time;
import urt.util : min;
import urt.uuid;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

public import router.stream;

import protocol.ble.att;
import protocol.ble.client;

nothrow @nogc:


enum BLEWriteMode : ubyte
{
    auto_,
    command,
    request,
}

class BLESerialStream : Stream
{
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("service", service),
                                 Prop!("write", write_uuid),
                                 Prop!("notify", notify_uuid),
                                 Elem!("write-mode", BLEWriteMode, Default!(BLEWriteMode.auto_), OnChange!restart));
nothrow @nogc:

    enum type_name = "ble-serial";
    enum path = "/stream/ble-serial";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!BLESerialStream, id, flags, options);
    }

    // Properties...

    final inout(BLEClient) client() inout pure
        => _client.get;
    final void client(BLEClient value)
    {
        if (_client.get is value)
            return;
        release_client();
        _client = value;
        mark_set!(typeof(this), "client")();
        restart();
    }

    final ref const(String) service() const pure
        => _service_str;
    final StringResult service(String value)
    {
        if (value == _service_str)
            return StringResult.success;
        import protocol.ble : parse_ble_uuid;
        if (!parse_ble_uuid(value[], _service_uuid))
            return StringResult("invalid uuid");
        _service_str = value.move;
        mark_set!(typeof(this), "service")();
        restart();
        return StringResult.success;
    }

    final ref const(String) write_uuid() const pure
        => _write_str;
    final StringResult write_uuid(String value)
    {
        if (value == _write_str)
            return StringResult.success;
        import protocol.ble : parse_ble_uuid;
        if (!parse_ble_uuid(value[], _write_char))
            return StringResult("invalid uuid");
        _write_str = value.move;
        mark_set!(typeof(this), "write")();
        restart();
        return StringResult.success;
    }

    final ref const(String) notify_uuid() const pure
        => _notify_str;
    final StringResult notify_uuid(String value)
    {
        if (value == _notify_str)
            return StringResult.success;
        import protocol.ble : parse_ble_uuid;
        if (!parse_ble_uuid(value[], _notify_char))
            return StringResult("invalid uuid");
        _notify_str = value.move;
        mark_set!(typeof(this), "notify")();
        restart();
        return StringResult.success;
    }

    final BLEWriteMode write_mode() const
        => prop_read!(BLESerialStream, "write-mode");
    final void write_mode(BLEWriteMode value)
        => prop_write!(BLESerialStream, "write-mode")(value);

    // API...

    override const(char)[] status_message() const
    {
        if (running)
            return "Running";
        const BLEClient c = _client.get;
        if (!c || !c.running)
            return "Waiting for BLE client";
        return super.status_message();
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        size_t accepted = 0;
        foreach (d; data)
        {
            size_t space = max_tx_backlog - _tx_buffer.length;
            size_t n = min(d.length, space);
            if (n == 0)
                break;
            _tx_buffer ~= cast(const(ubyte)[])d[0 .. n];
            accepted += n;
            if (n < d.length)
                break;
        }
        service_tx();
        return accepted;
    }

    override size_t tx_backlog() const
        => _tx_buffer.length + (_await_ack ? 1 : 0);

protected:

    override bool validate() const
        => _client.get !is null && !_service_str.empty && !_write_str.empty;

    override CompletionStatus startup()
    {
        BLEClient c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        ushort wh = c.find_characteristic(_service_uuid, _write_char);
        if (wh == 0)
        {
            _fail_reason = "Write characteristic not found";
            return CompletionStatus.error;
        }

        // single-characteristic devices (HM-10 style) notify on the write characteristic
        GUID nc = _notify_str.empty ? _write_char : _notify_char;
        ushort nh = c.find_characteristic(_service_uuid, nc);
        if (nh == 0)
        {
            _fail_reason = "Notify characteristic not found";
            return CompletionStatus.error;
        }

        _use_request = write_mode == BLEWriteMode.request;
        if (write_mode == BLEWriteMode.auto_)
        {
            foreach (ref ch; c.characteristics)
            {
                if (ch.value_handle == wh)
                {
                    _use_request = !(ch.props & GattProps.write_without_response);
                    break;
                }
            }
        }

        _write_handle = wh;
        _notify_handle = nh;
        c.on_notify(nh, &on_rx);
        c.subscribe(&client_state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        release_client();
        _tx_buffer.clear();
        _await_ack = false;
        _write_handle = 0;
        _notify_handle = 0;

        if (_flags & ObjectFlags.temporary)
            destroy();

        return CompletionStatus.complete;
    }

private:
    ObjectRef!BLEClient _client;
    String _service_str;
    String _write_str;
    String _notify_str;
    GUID _service_uuid;
    GUID _write_char;
    GUID _notify_char;

    Array!ubyte _tx_buffer;
    ushort _write_handle;
    ushort _notify_handle;
    bool _subscribed;
    bool _await_ack;
    bool _use_request;
    bool _servicing;

    enum max_tx_backlog = 64 * 1024;

    void release_client()
    {
        if (!_subscribed)
            return;
        if (BLEClient c = _client.get)
            c.clear_notify(_notify_handle);
        _client.unsubscribe(&client_state_change);
        _subscribed = false;
    }

    void client_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void on_rx(ushort, const(ubyte)[] value)
    {
        incoming(value, getTime());
    }

    void on_write_ack(const(ubyte)[], ATTError error)
    {
        _await_ack = false;
        if (error == ATTError.none)
            service_tx();
        // a failed link fails the client; its offline signal restarts this stream
    }

    void service_tx()
    {
        if (_servicing)
            return;
        _servicing = true;
        scope (exit) _servicing = false;

        BLEClient c = _client.get;
        if (!c || !c.running || _write_handle == 0)
            return;

        size_t chunk_max = c.att_mtu - 3;
        while (_tx_buffer.length && !_await_ack)
        {
            size_t n = min(_tx_buffer.length, chunk_max);
            _await_ack = _use_request;
            if (!c.write(_write_handle, _tx_buffer[0 .. n], _use_request, _use_request ? &on_write_ack : null))
            {
                _await_ack = false;
                break;
            }
            add_tx_bytes(n);
            write_to_log(false, _tx_buffer[0 .. n]);
            _tx_buffer.remove(0, n);
        }
    }
}
