module router.stream.serial;

import urt.array;
import urt.driver.uart;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.pagepool;
import urt.result;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import router.port;
public import router.stream;

public import urt.driver.uart : FlowControl, Parity, StopBits, UartLines;

nothrow @nogc:


final class SerialStream : Stream
{
    static if (uart_has_pin_select)
        alias Pins = AliasSeq!(Elem!("tx-gpio", byte, Default!(-1), OnChange!restart),
                               Elem!("rx-gpio", byte, Default!(-1), OnChange!restart),
                               Elem!("rts-gpio", byte, Default!(-1), OnChange!restart),
                               Elem!("cts-gpio", byte, Default!(-1), OnChange!restart));
    else
        alias Pins = AliasSeq!();

    static if (uart_has_rs485)
        alias Rs485 = AliasSeq!(Elem!("de-gpio", byte, Default!(-1), OnChange!restart));
    else
        alias Rs485 = AliasSeq!();

    static if (uart_reports_rx_gap)
        alias RxGap = AliasSeq!(Elem!("rx-gap", float, Default!3.5f, Min!0.1f, Max!25.5f, OnChange!reconfigure),
                                Prop!("actual-rx-gap", actual_rx_gap, null, "d"));
    else
        alias RxGap = AliasSeq!();

    alias Properties = AliasSeq!(Prop!("device", device),
                                 Elem!("baud-rate", uint, Default!9600, Min!1, OnChange!reconfigure),
                                 Elem!("data-bits", ubyte, Default!8, Min!5, Max!8, Check!data_bits_check, OnChange!reconfigure),
                                 Elem!("parity", Parity, Default!(Parity.none), Check!parity_check, OnChange!reconfigure),
                                 Elem!("stop-bits", StopBits, Default!(StopBits.one), Check!stop_bits_check, OnChange!reconfigure),
                                 Elem!("flow-control", FlowControl, Default!(FlowControl.none), Check!flow_control_check, OnChange!reconfigure),
                                 Pins, Rs485,
                                 Elem!("rx-latency", Duration, Default!(usecs(350)), Check!rx_latency_check, OnChange!reconfigure),
                                 Prop!("actual-rx-latency", actual_rx_latency, null, "d"),
                                 RxGap);
nothrow @nogc:

    ~this() {}

    enum type_name = "serial";
    enum path = "/stream/serial";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!SerialStream, id, flags, options);
    }

    // Properties...

    // Any name the platform knows the port by; a host's device may come and go, so it is looked up when the port opens.
    final String device() const pure
        => _device;
    final StringResult device(String value)
    {
        if (!value)
            return StringResult("device cannot be empty");
        if (_device == value)
            return StringResult.success;
        _device = value.move;
        mark_set!(typeof(this), "device");
        restart();
        return StringResult.success;
    }

    final uint baud_rate() const
        => prop_read!(SerialStream, "baud-rate");
    final void baud_rate(uint value)
        => prop_write!(SerialStream, "baud-rate")(value);

    final ubyte data_bits() const
        => prop_read!(SerialStream, "data-bits");
    final void data_bits(ubyte value)
        => prop_write!(SerialStream, "data-bits")(value);

    final Parity parity() const
        => prop_read!(SerialStream, "parity");
    final void parity(Parity value)
        => prop_write!(SerialStream, "parity")(value);

    final StopBits stop_bits() const
        => prop_read!(SerialStream, "stop-bits");
    final void stop_bits(StopBits value)
        => prop_write!(SerialStream, "stop-bits")(value);

    final FlowControl flow_control() const
        => prop_read!(SerialStream, "flow-control");
    final void flow_control(FlowControl value)
        => prop_write!(SerialStream, "flow-control")(value);

    // What the port runs with once its hardware has clamped the request; zero while it is closed.
    final Duration actual_rx_latency() const
        => usecs(uart_rx_timing(_uart).latency_us);

    final float actual_rx_gap() const
        => uart_rx_timing(_uart).gap / 10.0f;

    static const(char)[] data_bits_check(ref ubyte value)
        => (uart_data_bits >> value) & 1 ? null : "the UART does not take that many data bits";
    static const(char)[] parity_check(ref Parity value)
        => (uart_parities >> value) & 1 ? null : "the UART does not support that parity";
    static const(char)[] stop_bits_check(ref StopBits value)
        => (uart_stop_bits >> value) & 1 ? null : "the UART does not support that many stop bits";
    static const(char)[] flow_control_check(ref FlowControl value)
        => (uart_flow_controls >> value) & 1 ? null : "the UART does not support that flow control";
    static const(char)[] rx_latency_check(ref Duration value)
        => value > Duration.zero && value <= usecs(uint.max) ? null : "rx-latency must be positive";

    // An open port takes new settings in place, so a peer watching its modem lines sees no reopen; a frame the change
    // ended goes up at once.
    void reconfigure()
    {
        if (!running)
            return;
        if (!uart_reconfigure(_uart, uart_config()))
            return restart();
        deliver(getTime());
    }

    // API...

    // a UART signals one bit per baud, so the configured baud is the wire rate outright
    final override ulong tx_link_speed() const
        => baud_rate;
    final override ulong rx_link_speed() const
        => baud_rate;

    final override bool validate() const
        => !_device.empty;

    override CompletionStatus startup()
    {
        immutable ubyte port = uart_find(_device[]);
        immutable uint slot = uart_slot(port);
        if (slot >= num_uarts)
        {
            log.error("no serial device ", _device);
            return CompletionStatus.error;
        }
        if (_streams[slot] !is null && _streams[slot] !is this)
        {
            log.error("serial device ", _device, " is already in use");
            return CompletionStatus.error;
        }
        import urt.atomic : atomicStore, MemoryOrder;
        atomicStore!(MemoryOrder.relaxed)(_events, 0u);
        _streams[slot] = this;
        immutable cfg = uart_config();
        if (!uart_open(_uart, port, cfg, &rx_ready, &tx_ready))
        {
            _streams[slot] = null;
            log.error("failed to open serial device ", _device);
            return CompletionStatus.error;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_uart.is_open)
        {
            immutable uint slot = uart_slot(_uart.port);
            uart_close(_uart);
            if (slot < num_uarts && _streams[slot] is this)
                _streams[slot] = null;
        }
        import urt.atomic : atomicStore, MemoryOrder;
        atomicStore!(MemoryOrder.release)(_events, 0u);
        return CompletionStatus.complete;
    }

    // the driver takes each page and frees it once sent, up to the queue's watermark in flight
    override size_t tx_request() const
    {
        immutable size_t queued = uart_tx_queued(_uart);
        return running && queued < tx_queue_limit ? tx_queue_limit - queued : 0;
    }

    override void queue_tx_page(Page* page)
    {
        for (Page* p = page; p; p = p.next)
            sent(p.data);
        if (running && uart_send(_uart, page))
            return;
        while (page)
        {
            Page* next = page.next;
            page_free(page);
            page = next;
        }
    }

    // A write past the watermark is refused; one under it goes whole, so a frame is never split.
    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!running || uart_tx_queued(_uart) >= tx_queue_limit)
            return 0;
        size_t total;
        foreach (d; data)
        {
            immutable size_t taken = uart_write(_uart, d);
            sent(d[0 .. taken]);
            total += taken;
            if (taken < d.length)
                break;
        }
        return total;
    }

    // Drives a modem line by hand, for devices with reset wired to RTS or DTR; a line flow control owns is refused.
    final bool set_rts(bool asserted)
        => uart_set_line(_uart, UartLine.rts, asserted);
    final bool set_dtr(bool asserted)
        => uart_set_line(_uart, UartLine.dtr, asserted);

    final UartLines modem_lines()
        => uart_lines(_uart);

    final UartCounters counters()
        => uart_counters(_uart);

private:
    enum UartEvent : uint
    {
        rx = 1,
        tx = 2,
    }

    Uart _uart;
    shared uint _events;    // UartEvent bits raised by the callbacks, taken by the sweep
    String _device;

    __gshared SerialStream[num_uarts] _streams;
    __gshared ubyte _doorbell;

    UartConfig uart_config() const
    {
        UartConfig cfg;
        cfg.baud_rate = baud_rate;
        cfg.data_bits = data_bits;
        cfg.stop_bits = stop_bits;
        cfg.parity = parity;
        cfg.flow_control = flow_control;
        cfg.rx_latency_us = cast(uint)prop_read!(SerialStream, "rx-latency").as!"usecs";
        static if (uart_reports_rx_gap)
            cfg.rx_gap = cast(ubyte)(prop_read!(SerialStream, "rx-gap") * 10 + 0.5f);
        static if (uart_has_pin_select)
        {
            static foreach (pin; [ "tx", "rx", "rts", "cts" ])
            {{
                immutable byte gpio = prop_read!(SerialStream, pin ~ "-gpio");
                if (gpio >= 0)
                    mixin("cfg." ~ pin ~ "_gpio") = cast(ubyte)gpio;
            }}
        }
        static if (uart_has_rs485)
        {
            immutable byte de = prop_read!(SerialStream, "de-gpio");
            if (de >= 0)
            {
                cfg.rs485.enabled = true;
                cfg.rs485.de_gpio = cast(ubyte)de;
            }
        }
        return cfg;
    }

    void sent(const(void)[] data)
    {
        if (_logging || has_tap)
            write_to_log(false, data);
        add_tx_bytes(data.length);
    }

    // Each frame goes up whole, dated by when its last byte arrived; a frame still arriving goes up as it stands, dated
    // now.
    void deliver(MonoTime now)
    {
        Page* chain = uart_rx_take(_uart);
        foreach (i; 0 .. uart_burst_count(chain))
        {
            UartBurst burst = uart_burst(chain, i);
            immutable MonoTime time = burst.end ? burst.end : now;
            for (size_t at = 0; at < burst.length; )
            {
                const(void)[] span = page_chain_span(chain, burst.offset + at, burst.length - at);
                incoming(span, time);
                at += span.length;
            }
        }
        while (chain)
        {
            Page* next = chain.next;
            page_free(chain);
            chain = next;
        }
    }

    void uart_event(uint events, MonoTime when)
    {
        if (!_uart.is_open || !running)
            return;
        if (events & UartEvent.rx)
        {
            if (uart_check_errors(_uart) & UartError.lost)
                return restart();
            deliver(when);
        }
        if (events & UartEvent.tx)
            invite_tx();
    }

    static bool rx_ready(Uart uart, UartCallbackContext context)
        => raise(uart, UartEvent.rx, context);

    static bool tx_ready(Uart uart, UartCallbackContext context)
        => raise(uart, UartEvent.tx, context);

    // From the UART's interrupt, or a host's I/O thread: the bits gather until the sweep takes them.
    static bool raise(Uart uart, uint event, UartCallbackContext context)
    {
        immutable uint slot = uart_slot(uart.port);
        if (slot >= num_uarts)
            return false;
        SerialStream instance = _streams[slot];
        if (instance is null)
            return false;

        import urt.atomic : atomicLoad, cas, MemoryOrder;
        uint pending;
        do
            pending = atomicLoad!(MemoryOrder.acquire)(instance._events);
        while (!cas(&instance._events, pending, pending | event));
        if (pending)
            return false;   // the ring already pending takes this event too
        if (context == UartCallbackContext.interrupt)
            return ring_from_isr(_doorbell);
        ring(_doorbell);
        return false;
    }

    static void sweep(MonoTime when)
    {
        import urt.atomic : atomicExchange, MemoryOrder;
        foreach (stream; _streams)
        {
            if (stream is null)
                continue;
            uint events = atomicExchange!(MemoryOrder.acq_rel)(&stream._events, 0u);
            if (events)
                stream.uart_event(events, when);
        }
    }
}


final class SerialStreamModule : Module
{
    mixin DeclareModule!"stream.serial";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!StopBits();
        g_app.register_enum!Parity();
        g_app.register_enum!FlowControl();

        g_app.console.register_collection!SerialStream();
        SerialStream._doorbell = register_doorbell(&SerialStream.sweep, EventPriority.bulk);
        g_app.console.register_command!(serial_lines, "lines")("/stream/serial", this);
        g_app.console.register_command!(serial_devices, "devices")("/stream/serial", this);
        version (Embedded) {} else
            sync_ports(getTime());
    }

    // /stream/serial/lines <name> - live modem-line state and line counters; the observability layer for flow-control
    // experiments.
    void serial_lines(Session session, const(char)[] name)
    {
        SerialStream s = Collection!SerialStream().get(name);
        if (!s)
        {
            session.write_line(tconcat("no such serial stream: ", name));
            return;
        }

        UartLines l = s.modem_lines();
        if (!l.valid)
            session.write_line(tconcat("'", name, "': port not open or line query unsupported"));
        else if (l.outputs_valid)
            session.write_line(tconcat("'", name, "': RTS=", cast(int)l.rts, " DTR=", cast(int)l.dtr,
                                       "  <-  CTS=", cast(int)l.cts, " DSR=", cast(int)l.dsr, " DCD=", cast(int)l.dcd, " RI=", cast(int)l.ri));
        else
            session.write_line(tconcat("'", name, "': CTS=", cast(int)l.cts, " DSR=", cast(int)l.dsr,
                                       " DCD=", cast(int)l.dcd, " RI=", cast(int)l.ri, " (outputs not readable on this platform)"));

        UartCounters c = s.counters();
        session.write_line(tconcat("counters: rx=", c.rx_bytes, " tx=", c.tx_bytes, " frame=", c.framing,
                                   " parity=", c.parity, " overrun=", c.overrun, " noise=", c.noise, " brk=", c.breaks));
    }

    void serial_devices(Session session)
    {
        uint cursor, count;
        UartPortInfo info;
        while (uart_enumerate(cursor, info))
        {
            session.write_line(info.name, info.description.length ? tconcat("  (", info.description, ")") : "");
            ++count;
        }
        if (count == 0)
            session.write_line("No serial devices found");
    }

private:
    version (Embedded) {} else
    {
        version (Windows)
            enum id_prefix = "windows:serial:";
        else
            enum id_prefix = "linux:serial:";

        // One registry entry per device the platform enumerates, with what it can say of the hardware behind it.
        void sync_ports(MonoTime now)
        {
            g_app.schedule(now + 2.seconds, &sync_ports);
            Array!String seen;
            uint cursor;
            UartPortInfo info;
            while (uart_enumerate(cursor, info))
            {
                size_t slash;
                foreach (i, c; info.name)
                {
                    if (c == '/' || c == '\\')
                        slash = i + 1;
                }
                auto id = tconcat(id_prefix, info.name);
                PortUsb usb = PortUsb(info.usb_vid, info.usb_pid, info.manufacturer, info.product, info.serial);
                port_add(PortKind.serial, id, info.name[slash .. $], info.name, ModuleName, info.description,
                         info.removable ? PortFlags.removable : PortFlags.none, usb);
                seen ~= id.make_string();
            }

            Array!String gone;
            foreach (ref p; port_list())
            {
                if (p.kind != PortKind.serial || p.driver[] != ModuleName)
                    continue;
                bool still_there;
                foreach (ref id; seen[])
                    still_there |= p.id[] == id[];
                if (!still_there)
                    gone ~= p.id;
            }
            foreach (ref id; gone[])
                port_remove(PortKind.serial, id[]);
        }
    }
}
