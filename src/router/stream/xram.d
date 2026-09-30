module router.stream.xram;

version (BL808):

import urt.atomic;
import urt.meta;
import urt.time;
import urt.driver.bl_common.xram;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

import router.stream;

nothrow @nogc:


// A byte stream to the other BL808 core over an XRAM ring pair. Each core adds one per channel.
final class XramStream : Stream
{
    alias Properties = AliasSeq!(Prop!("channel", channel));
nothrow @nogc:

    enum type_name = "xram";
    enum path = "/stream/xram";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!XramStream, id, flags);
    }

    // Properties

    final ubyte channel() const pure => _channel;
    final void channel(ubyte value)
    {
        if (value == _channel)
            return;
        _channel = value;
        mark_set!(typeof(this), "channel")();
        restart();
    }

    // API

    override ptrdiff_t write(const(void[])[] data...)
    {
        size_t total;
        foreach (d; data)
        {
            size_t put = xram_write(_channel, d);
            if (put && _logging)
                write_to_log(false, d[0 .. put]);
            total += put;
            if (put < d.length)
                break;
        }
        add_tx_bytes(total);
        return total;
    }

    override size_t tx_request() const
        => running ? xram_tx_space(_channel) : 0;

protected:

    override bool validate() const pure
        => _channel < xram_channels;

    override CompletionStatus startup()
    {
        if (_streams[_channel] !is null)
            return CompletionStatus.error;
        _streams[_channel] = this;
        xram_open(_channel, &doorbell);
        drain(getTime());
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_streams[_channel] is this)
        {
            xram_close(_channel);
            _streams[_channel] = null;
        }
        atomicStore(_events, 0u);
        atomicStore(_queued, 0u);
        return CompletionStatus.complete;
    }

private:

    shared uint _events;
    shared uint _queued;
    ubyte _channel;

    // A post lost to a full event queue is retried by the peer's next doorbell.
    static void doorbell(uint channel, XramEvent events)
    {
        XramStream stream = _streams[channel];
        if (stream is null || g_app is null)
            return;
        atomicOp!"|="(stream._events, uint(events));
        if (cas(&stream._queued, 0u, 1u) && !g_app.post_event_from_isr(&_sweep.event, EventPriority.bulk))
            atomicStore(stream._queued, 0u);
    }

    // Queued events bind this stable trampoline, so a stream destroyed while one is in flight is simply absent.
    static struct Sweep
    {
        void event(MonoTime when) nothrow @nogc
        {
            foreach (stream; _streams)
                if (stream !is null)
                    stream.service(when);
        }
    }
    __gshared Sweep _sweep;
    __gshared XramStream[xram_channels] _streams;

    void service(MonoTime when)
    {
        atomicStore(_queued, 0u);
        uint events = atomicExchange(&_events, 0u);
        if (!running)
            return;
        if (events & XramEvent.data)
            drain(when);
        if (events & XramEvent.space)
            pump_tx();
    }

    void drain(MonoTime when)
    {
        ubyte[256] buffer = void;
        while (size_t n = xram_read(_channel, buffer[]))
            incoming(buffer[0 .. n], when);
    }
}


final class XramStreamModule : Module
{
    mixin DeclareModule!"stream.xram";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!XramStream();
    }
}
