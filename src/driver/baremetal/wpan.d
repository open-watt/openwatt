module driver.baremetal.wpan;

import urt.driver.wpan;

static if (num_wpan > 0)
{

import urt.atomic;
import urt.log;
import urt.mem.page : Page;
import urt.mem.pagepool : page_release;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.mac;
import router.iface.packet;
import router.iface.priority_queue;
import router.iface.wpan;

nothrow @nogc:


final class BuiltinWpan : WpanInterface
{
    alias Properties = AliasSeq!(Prop!("cca", cca, "radio"));
nothrow @nogc:

    enum type_name = "wpan";
    enum path = "/interface/wpan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinWpan, id, flags);
    }

    final bool cca() const pure
        => _cca;
    final void cca(bool value)
    {
        _cca = value;
        mark_set!(typeof(this), "cca")();
    }

    override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)* policy)
    {
        if (packet.type != PacketType.wpan || !_wpan.is_open || packet.length == 0 || packet.length > _max_l2mtu)
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
        if (policy)
            arm_deadline();
        send_next();
        return tag;
    }

    final override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle > 0 && msg_handle <= 0xFF, "invalid msg_handle");
        _queue.abort(cast(ubyte)msg_handle, reason);
    }

    final override MessageState msg_state(int msg_handle) const
    {
        if (_queue.find_in_flight(cast(ubyte)msg_handle))
            return MessageState.in_flight;
        if (_queue.is_queued(cast(ubyte)msg_handle))
            return MessageState.queued;
        return MessageState.complete;
    }

    override void heartbeat(MonoTime now)
    {
        super.heartbeat(now);
        service();
    }

protected:

    override CompletionStatus startup()
    {
        WpanConfig cfg;
        cfg.channel = channel;
        cfg.tx_power = tx_power;
        cfg.pan_id = pan_id;
        cfg.short_address = short_address;
        cfg.extended_address = extended_address.b;
        cfg.promiscuous = promiscuous;

        if (wpan_open(_wpan, 0, cfg).failed)
        {
            log.error("802.15.4 radio init failed");
            return CompletionStatus.error;
        }

        ubyte[8] eui = void;
        if (wpan_get_extended_address(_wpan, eui))
            adopt_extended_address(EUI64(eui));

        _queue.init(1, 0, PCP.be, this);
        _active_radios[_wpan.port] = this;
        wpan_set_rx_callback(_wpan, &rx_dispatch);
        wpan_set_tx_callback(_wpan, &tx_dispatch);
        wpan_set_ready_callback(&request_service);
        set_link_speed(250_000);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_wpan.is_open)
        {
            wpan_set_ready_callback(null);
            wpan_set_rx_callback(_wpan, null);
            wpan_set_tx_callback(_wpan, null);
            _active_radios[_wpan.port] = null;
            wpan_close(_wpan);
        }
        if (_deadline_armed)
        {
            g_app.cancel(&deadline_event);
            _deadline_armed = false;
        }
        _queue.abort_all();
        _in_flight = -1;
        return CompletionStatus.complete;
    }

    override void on_channel_changed(ubyte value)
    {
        if (_wpan.is_open && wpan_set_channel(_wpan, value).failed)
            log.warning("802.15.4 set channel ", value, " failed");
    }

    override void on_tx_power_changed(byte value)
    {
        if (_wpan.is_open && wpan_set_tx_power(_wpan, value).failed)
            log.warning("802.15.4 set tx-power failed");
    }

    override void on_pan_id_changed(ushort value)
    {
        if (_wpan.is_open)
            wpan_set_pan_id(_wpan, value);
    }

    override void on_short_address_changed(ushort value)
    {
        if (_wpan.is_open)
            wpan_set_short_address(_wpan, value);
    }

    override void on_promiscuous_changed(bool value)
    {
        if (_wpan.is_open)
            wpan_set_promiscuous(_wpan, value);
    }

private:
    PriorityPacketQueue _queue;
    int _in_flight = -1;
    Wpan _wpan;
    bool _cca = true;
    bool _deadline_armed;

    __gshared BuiltinWpan[num_wpan] _active_radios;
    __gshared shared(uint) _service_pending;

    void service()
    {
        if (!_wpan.is_open)
            return;
        if (wpan_service(_wpan))
            request_service();
        uint dropped = wpan_take_rx_drops(_wpan);
        if (dropped != 0)
        {
            _status.rx_dropped += dropped;
            mark_set!(typeof(this), "rx-dropped")();
        }
    }

    void send_next()
    {
        _queue.timeout_stale(getTime());
        while (_in_flight < 0)
        {
            QueuedFrame* frame = _queue.dequeue();
            if (frame is null)
                return;
            if (wpan_tx(_wpan, cast(const(ubyte)[])frame.packet.data, _cca).succeeded)
            {
                _in_flight = frame.tag;
                return;
            }
            add_tx_drop();
            _queue.complete(frame.tag, MessageState.failed);
        }
    }

    void on_tx_done(WpanTxError error)
    {
        int tag = _in_flight;
        _in_flight = -1;
        // null when the frame was aborted while the radio held it; _in_flight gated the radio until now
        if (const(QueuedFrame)* frame = tag < 0 ? null : _queue.find_in_flight(cast(ubyte)tag))
        {
            if (error == WpanTxError.none)
            {
                add_tx_frame(frame.packet.length);
                _queue.complete(cast(ubyte)tag, MessageState.complete);
            }
            else
            {
                add_tx_drop();
                _queue.complete(cast(ubyte)tag, error == WpanTxError.no_ack || error == WpanTxError.invalid_ack ? MessageState.delivery_failed : MessageState.failed);
            }
        }
        send_next();
    }

    void arm_deadline()
    {
        if (_deadline_armed)
        {
            g_app.cancel(&deadline_event);
            _deadline_armed = false;
        }
        MonoTime when;
        if (_queue.next_due(when))
        {
            g_app.schedule(when, &deadline_event);
            _deadline_armed = true;
        }
    }

    void deadline_event(MonoTime)
    {
        _deadline_armed = false;
        send_next();
        arm_deadline();
    }

    void on_rx(Page* page, ref const WpanRxInfo info)
    {
        scope(exit) page_release(page);

        const(ubyte)[] frame = cast(const(ubyte)[])page.data;
        Packet pkt;
        auto hdr = &pkt.init!WpanFrame(frame);
        if (hdr.parse(frame) == 0)
        {
            add_rx_drop();
            return;
        }
        hdr.rssi = info.rssi;
        hdr.lqi = info.lqi;
        incoming_packet(pkt);
    }

    // may run in the radio ISR; a post the reactor refuses is retried by the next radio event or the heartbeat
    static void request_service()
    {
        if (g_app is null || !cas(&_service_pending, 0u, 1u))
            return;
        bool queued;
        g_app.post_event_from_isr(&_service_sweep.event, EventPriority.bulk, queued);
        if (!queued)
            atomicStore!(MemoryOrder.release)(_service_pending, 0u);
    }

    // a posted event cannot be recalled, so it must not retain a radio that may be destroyed before it runs
    static struct ServiceSweep
    {
        void event(MonoTime) nothrow @nogc
        {
            atomicStore!(MemoryOrder.release)(_service_pending, 0u);
            foreach (radio; _active_radios)
                if (radio !is null)
                    radio.service();
        }
    }
    __gshared ServiceSweep _service_sweep;

    static void rx_dispatch(Wpan wpan, Page* frame, ref const WpanRxInfo info)
    {
        auto radio = wpan.port < num_wpan ? _active_radios[wpan.port] : null;
        if (radio !is null && radio.running)
            radio.on_rx(frame, info);
        else
            page_release(frame);
    }

    static void tx_dispatch(Wpan wpan, WpanTxError error, const(ubyte)[], ref const WpanRxInfo)
    {
        auto radio = wpan.port < num_wpan ? _active_radios[wpan.port] : null;
        if (radio !is null)
            radio.on_tx_done(error);
    }
}


final class BuiltinWpanModule : Module
{
    mixin DeclareModule!"interface.wpan.builtin";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BuiltinWpan();
    }
}

}
