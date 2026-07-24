module protocol.gpio;

import urt.driver.gpio;
import urt.meta : AliasSeq;
import urt.result;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.element;
import manager.plugin;

nothrow @nogc:


class GpioBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("chip", chip),
                                 Prop!("rx-line", rx_line),
                                 Prop!("tx-line", tx_line),
                                 Prop!("element", element_path),
                                 Prop!("pull", pull),
                                 Prop!("debounce", debounce),
                                 Prop!("records", records, "status", "d"),
                                 Prop!("buckets", buckets, "status", "d"),
                                 Prop!("edge-rate", edge_rate, "status", "d"),
                                 Prop!("last-edge", last_edge, "status", "d"),
                                 Prop!("backend", backend, "status", "d"),
                                 Prop!("clock", clock, "status", "d"),
                                 Prop!("stream-start", stream_start, "status", "d"),
                                 Prop!("anchor-error", anchor_error, "status", "d"));
nothrow @nogc:

    enum type_name = "gpio-binding";
    enum path = "/binding/gpio";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GpioBinding, id, flags);
        _fmt.type = ValueType.bool_;
        _fmt.kind = SeriesKind.held;
        _fmt.clock = &_clock;
    }

    final uint chip() const pure
        => _chip;
    final void chip(uint value)
    {
        if (_chip == value)
            return;
        _chip = value;
        mark_set!(typeof(this), "chip")();
        restart();
    }

    final uint rx_line() const pure
        => _rx_line;
    final void rx_line(uint value)
    {
        if (_rx_line == value)
            return;
        _rx_line = value;
        mark_set!(typeof(this), "rx-line")();
        restart();
    }

    // reserved for the waveform generator (sink series / send functions); not consumed yet
    final uint tx_line() const pure
        => _tx_line;
    final void tx_line(uint value)
    {
        if (_tx_line == value)
            return;
        _tx_line = value;
        mark_set!(typeof(this), "tx-line")();
        restart();
    }

    final ref const(String) element_path() const pure
        => _element_path;
    final void element_path(String value)
    {
        if (value == _element_path)
            return;
        _element_path = value.move;
        mark_set!(typeof(this), "element")();
        restart();
    }

    final Pull pull() const pure
        => _pull;
    final void pull(Pull value)
    {
        if (_pull == value)
            return;
        _pull = value;
        mark_set!(typeof(this), "pull")();
        restart();
    }

    final Duration debounce() const pure
        => _debounce;
    final void debounce(Duration value)
    {
        if (_debounce == value)
            return;
        _debounce = value;
        mark_set!(typeof(this), "debounce")();
        restart();
    }

    final ulong records() const pure
        => _element ? _element.record_count : 0;

    final uint buckets() const pure
        => _element ? _element.bucket_count : 0;

    final uint edge_rate() const pure
        => _edge_rate;

    final SysTime last_edge() const pure
        => _element ? _element.last_update : SysTime();

    final const(char)[] backend() const pure
    {
        static if (has_gpio_sampler)
            return _sampler.backend_name();
        else
            return "none";
    }

    final uint clock() const pure
        => _clock.nominal_rate;

    final SysTime stream_start() const pure
        => _stream_start;

    final Duration anchor_error() const pure
        => _anchor_err;

    final inout(Element)* element() inout pure
        => _element;

    final override bool validate() const pure
        => _rx_line != uint.max && !_device.empty;

    override bool materialise()
    {
        Device* dev = _device[] in g_app.devices;
        if (!dev)
            return false;
        FormatId format = register_format(_fmt);
        Element* e = (*dev).find_or_create_element(
            _element_path.empty ? "state" : _element_path[], format);
        if (_element is null)
        {
            e.access = Access.read;
            e.sampling_mode = SamplingMode.report;
        }
        _element = e;
        return true;
    }

    static if (has_gpio_sampler)
    {
        override CompletionStatus startup()
        {
            if (!materialise())
                return CompletionStatus.error;

            Result r = gpio_sampler_open(_chip, _rx_line, _sampler, _pull, cast(uint)_debounce.as!"usecs");
            if (r.failed)
            {
                log.error("failed to open gpio sampler chip=", _chip, " line=", _rx_line, " (error ", r.system_code, ")");
                return CompletionStatus.error;
            }
            if (!g_app.watch_io(_sampler.fd, &on_edges, &on_io_error, _sampler.socket_backed))
            {
                _sampler.close();
                log.error("failed to register gpio sampler with the reactor");
                return CompletionStatus.error;
            }
            _watched = true;
            log.info("gpio sampler backend=", _sampler.backend_name(), " chip=", _chip, " line=", _rx_line);
            _element.ensure_history();   // scaffold retains everything; retention policy TODO
            _edges_at_window = _element.record_count;
            _window_start = getTime();
            _last_anchor = _window_start;
            _stream_start = SysTime();
            _clock.nominal_rate = _sampler.clock_hz();
            _clock.anchors.clear();     // new stream: sample-0 anchor is re-established on the first edge
            _have_stream = false;
            return CompletionStatus.complete;
        }

        override CompletionStatus shutdown()
        {
            if (_watched)
            {
                g_app.unwatch_io(_sampler.fd);
                _watched = false;
            }
            _sampler.close();
            if (_element)
                _element.mark_gap();
            return CompletionStatus.complete;
        }

        override void update()
        {
            MonoTime now = getTime();
            if (now - _window_start >= 1.seconds)
            {
                ulong count = _element.record_count;
                uint rate = cast(uint)(count - _edges_at_window);
                if (rate != _edge_rate)
                {
                    _edge_rate = rate;
                    mark_set!(typeof(this), "edge-rate")();
                }
                _edges_at_window = count;
                _window_start = now;
            }
            if (_have_stream && now - _last_anchor >= 10.seconds)
            {
                ulong tick_c;
                SysTime wall_c;
                ulong err_ns;
                if (_sampler.correlate(tick_c, wall_c, err_ns))    // adds an anchor to track sample-clock drift
                {
                    _clock.add_anchor(tick_c - _stream_first_tick, wall_c);
                    _anchor_err = nsecs(cast(long)(err_ns / 2));
                }
                _last_anchor = now;
            }
        }
    }
    else
    {
        override CompletionStatus startup()
        {
            log.error("gpio sampler is not supported on this platform");
            return CompletionStatus.error;
        }
    }

private:
    Element* _element;          // series owner in the device tree
    String _element_path;
    ClockDomain _clock;         // owned by this binding; _fmt.clock points at it
    DataFormat _fmt;
    Duration _debounce;
    Duration _anchor_err;
    uint _chip = 0;
    uint _rx_line = uint.max;
    uint _tx_line = uint.max;
    uint _edge_rate;
    ulong _edges_at_window;
    MonoTime _window_start;
    SysTime _stream_start;
    Pull _pull;

    static if (has_gpio_sampler)
    {
        GpioSampler _sampler;
        bool _watched;
        bool _have_stream;
        ulong _stream_first_tick;
        MonoTime _last_anchor;

        void on_edges(const(void)[] data, MonoTime rx_time)
        {
            GpioEdge[64] edges = void;
            for (size_t n = _sampler.decode(data, edges[]); n; n = _sampler.decode(data, edges[]))
            {
                if (!_have_stream)
                    anchor_stream(edges[0].tick);

                bool[64] levels = void;
                ulong[64] ticks = void;
                foreach (i; 0 .. n)
                {
                    levels[i] = edges[i].level;
                    ticks[i] = edges[i].tick - _stream_first_tick;
                }
                _element.write_samples(levels[0 .. n], ticks[0 .. n]);
            }
            mark_set!(typeof(this), ["records", "buckets", "last-edge"])();
        }

        // First sample of a stream: pin index 0 to its realtime via a fresh correlation, back-projected
        // from the correlation point to the first tick (the driver correlates just after the edge arrives).
        void anchor_stream(ulong first_tick)
        {
            _stream_first_tick = first_tick;
            _have_stream = true;

            // a restart resumes into the retained series; force a fresh bucket so the new stream's low
            // relative ticks can't underflow the old bucket's offset base (cross-segment wall: TODO)
            if (_element.record_count > 0)
                _element.mark_gap();

            ulong tick_c;
            SysTime wall_c;
            ulong err_ns;
            if (_sampler.correlate(tick_c, wall_c, err_ns))
            {
                _stream_start = wall_c - usecs(tick_c - first_tick);
                _anchor_err = nsecs(cast(long)(err_ns / 2));
            }
            else
            {
                _stream_start = getSysTime();   // correlate failed: pin index 0 to now, best effort
                _anchor_err = Duration();
            }
            _clock.add_anchor(0, _stream_start);    // always anchor, so to_wall never falls back to epoch
        }

        void on_io_error()
        {
            restart();
        }
    }
}


class GpioModule : Module
{
    mixin DeclareModule!"protocol.gpio";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!Pull();
        g_app.console.register_collection!GpioBinding();
    }
}
