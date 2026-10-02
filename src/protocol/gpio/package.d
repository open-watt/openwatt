module protocol.gpio;

import urt.atomic;
import urt.attribute : critical, isr_safe;
import urt.driver.event;
import urt.driver.gpio;
import urt.driver.pwm;
import urt.driver.ws2812;
import urt.meta : AliasSeq;
import urt.result;
import urt.si.quantity : Quantity;
import urt.si.unit : Percent;
import urt.string;
import urt.time;
import urt.variant : Variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.panel : ButtonEvent, Colour, LightEffect;
import manager.plugin;
import manager.reactor;

nothrow @nogc:


enum GpioKind : ubyte
{
    capture,
    button,
    switch_,
    light,
}

enum ActiveLevel : ubyte
{
    high,
    low,
}

enum PwmChannel : ubyte
{
    none,
    hardware,
    software,
}

enum LightDrive : ubyte
{
    io,
    pwm,
    ws2812,
}

final class GpioBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("kind", kind),
                                 Prop!("chip", chip),
                                 Prop!("gpio", gpio),
                                 Prop!("component", component),
                                 Prop!("active", active),
                                 Prop!("pull", pull),
                                 Prop!("debounce", debounce),
                                 Prop!("hold", hold),
                                 Prop!("click-gap", click_gap),
                                 Prop!("drive", drive),
                                 Prop!("index", index),
                                 Prop!("pwm-channel", pwm_channel, "status"),
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

    final GpioKind kind() const pure
        => _kind;
    final void kind(GpioKind value)
    {
        if (_kind == value)
            return;
        _kind = value;
        mark_set!(typeof(this), "kind")();
        restart();
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

    final uint gpio() const pure
        => _gpio;
    final void gpio(uint value)
    {
        if (_gpio == value)
            return;
        _gpio = value;
        mark_set!(typeof(this), "gpio")();
        restart();
    }

    final ref const(String) component() const pure
        => _component;
    final void component(String value)
    {
        if (value == _component)
            return;
        _component = value.move;
        mark_set!(typeof(this), "component")();
        restart();
    }

    final ActiveLevel active() const pure
        => _active;
    final void active(ActiveLevel value)
    {
        if (_active == value)
            return;
        _active = value;
        mark_set!(typeof(this), "active")();
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
        => (_props_set & (1UL << prop_index!(GpioBinding, "debounce"))) ? _debounce : msecs(default_debounce_ms[_kind]);
    final void debounce(Duration value)
    {
        if (_debounce == value)
            return;
        _debounce = value;
        mark_set!(typeof(this), "debounce")();
        restart();
    }

    final Duration hold() const pure
        => _hold;
    final void hold(Duration value)
    {
        if (_hold == value)
            return;
        _hold = value;
        mark_set!(typeof(this), "hold")();
    }

    final Duration click_gap() const pure
        => _click_gap;
    final void click_gap(Duration value)
    {
        if (_click_gap == value)
            return;
        _click_gap = value;
        mark_set!(typeof(this), "click-gap")();
    }

    final LightDrive drive() const pure
        => _drive;
    final void drive(LightDrive value)
    {
        if (_drive == value)
            return;
        _drive = value;
        mark_set!(typeof(this), "drive")();
        restart();
    }

    final ubyte index() const pure
        => _index;
    final void index(ubyte value)
    {
        if (_index == value)
            return;
        _index = value;
        mark_set!(typeof(this), "index")();
        restart();
    }

    final PwmChannel pwm_channel() const
        => !_pwm.is_open ? PwmChannel.none : _pwm.is_hardware ? PwmChannel.hardware : PwmChannel.software;

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
        if (_kind == GpioKind.button)
            return _link.is_open ? "interrupt" : "sampled";
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

    final override bool validate() const
    {
        if (_device.empty || _gpio == uint.max)
            return false;
        if (_kind == GpioKind.capture)
            return true;
        if (_component.empty || _chip != 0 || _gpio >= gpio_count())
            return false;
        if ((_pull == Pull.up && !has_pull_up) || (_pull == Pull.down && !has_pull_down))
            return false;
        return _kind != GpioKind.button || debounce > Duration.zero;
    }

    override bool materialise()
    {
        DeviceBuilder builder = g_app.devices.open(_device[]);
        _bound_device = builder.device;
        Component c = _component.empty ? _bound_device : builder.component(_component[], templates[_kind]);
        final switch (_kind)
        {
            case GpioKind.capture:
            {
                Element* e = bind_element(builder, c, "state", register_format(_fmt));
                if (_element is null)
                    e.sampling_mode = SamplingMode.report;
                _element = e;
                break;
            }
            case GpioKind.button:
            {
                builder.constant(c, "mode", "momentary");
                _element = report(bind_element(builder, c, "state", register_value_format!bool()));
                DataFormat event = data_format_of!ButtonEvent();
                event.kind = SeriesKind.point;
                _event = report(bind_element(builder, c, "event", register_format(event)));
                break;
            }
            case GpioKind.light:
            {
                _effect = report(bind_element(builder, c, "effect", register_value_format!LightEffect(), Access.read_write));
                _indicate = report(bind_element(builder, c, "indicate", register_value_format!LightEffect(), Access.read_write));
                DataFormat pulse = data_format_of!bool();
                pulse.kind = SeriesKind.point;
                _pulse = report(bind_element(builder, c, "pulse", register_format(pulse), Access.write));
                _level = _pwm.is_open || _ws.is_open ? report(bind_element(builder, c, "level", register_value_format!Level(), Access.read_write)) : null;
                _colour = _ws.is_open ? report(bind_element(builder, c, "colour", register_value_format!Colour(), Access.read_write)) : null;
                _indicate_colour = _ws.is_open ? report(bind_element(builder, c, "indicate_colour", register_value_format!Colour(), Access.read_write)) : null;
                if (_ws.is_open)
                    builder.constant(c, "channels", "RGB");
                goto case;
            }
            case GpioKind.switch_:
                _element = report(bind_element(builder, c, "switch", register_value_format!bool(), Access.read_write));
                break;
        }
        return true;
    }

    override CompletionStatus startup()
    {
        if (_kind == GpioKind.light)
        {
            final switch (_drive)
            {
                case LightDrive.io:
                    break;
                case LightDrive.pwm:
                    if (!pwm_acquire(_pwm, PwmConfig(GpioLine(_chip, _gpio), pwm_frequency, pwm_period, 0, _active == ActiveLevel.low)))
                        log.warning("no PWM channel for gpio ", _gpio, "; it switches on and off only");
                    mark_set!(typeof(this), "pwm-channel")();
                    break;
                case LightDrive.ws2812:
                    if (!ws2812_open(_ws, GpioLine(_chip, _gpio)))
                    {
                        log.error("cannot drive a WS2812 chain on gpio ", _gpio);
                        return CompletionStatus.error;
                    }
                    _pixel = _index;
                    break;
            }
        }
        if (!materialise())
            return CompletionStatus.error;
        final switch (_kind)
        {
            case GpioKind.capture:
                return start_capture();
            case GpioKind.button:
                return start_button();
            case GpioKind.switch_:
            case GpioKind.light:
                return start_output();
        }
    }

    // releases what startup acquired; the setters may already have changed kind and gpio
    override CompletionStatus shutdown()
    {
        static if (has_gpio_sampler)
        {
            if (_watched)
                _element.mark_gap();
            detach_watch();
            _sampler.close();
        }
        link_close(_link);
        g_app.cancel(&baseline);
        g_app.cancel(&settle);
        g_app.cancel(&sample);
        g_app.cancel(&hold_elapsed);
        g_app.cancel(&gap_elapsed);
        g_app.cancel(&phase_elapsed);
        g_app.cancel(&pulse_elapsed);
        g_app.cancel(&breathe_step);
        g_app.cancel(&rainbow_step);
        Element*[7] outputs = [ _element, _effect, _indicate, _pulse, _level, _colour, _indicate_colour ];
        foreach (e; outputs)
        {
            if (e)
                e.unsubscribe(&output_changed);
        }
        if (_ws.is_open)
        {
            ws2812_set(_ws, _pixel, 0);
            ws2812_close(_ws);
        }
        pwm_close(_pwm);
        static if (has_gpio)
        {
            if (_claimed != uint.max)
                gpio_release(_claimed);
        }
        _claimed = uint.max;
        _element = null;
        _effect = _indicate = _pulse = _level = _colour = _indicate_colour = null;
        _clicks = 0;
        _unsettled = false;
        return super.shutdown();
    }

    // A sweep the event queue refused leaves its binding signalled; the heartbeat collects it.
    final void heartbeat(MonoTime now)
    {
        if (_link.is_open && cas(&_signalled, 1u, 0u))
            edged();
    }

    static if (has_gpio_sampler)
    {
        override void update()
        {
            if (_kind != GpioKind.capture)
                return;
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

private:
    enum bool has_gpio = num_gpio > 0;

    static immutable string[GpioKind.max + 1] templates = [ null, "Button", "Switch", "Light" ];
    static immutable ushort[GpioKind.max + 1] default_debounce_ms = [ 0, 30, 0, 0 ];
    static immutable ButtonEvent[3] click_events = [ ButtonEvent.click, ButtonEvent.double_, ButtonEvent.triple ];
    static immutable ushort[2][LightEffect.max + 1] effect_ms = [ [0, 0], [500, 500], [125, 125], [1000, 1000], [100, 900], [0, 0] ];
    enum pulse_length = 50.msecs;
    enum breathe_step_time = 20.msecs;
    enum ubyte breathe_steps = 100;
    enum uint pwm_frequency = 4000;
    enum uint pwm_period = 256;

    alias Level = Quantity!(ubyte, Percent);

    Element* _element;          // capture series, button state, or output switch
    union
    {
        Element* _event;
        struct
        {
            Element* _effect;
            Element* _indicate;
            Element* _pulse;
            Element* _level;
            Element* _colour;
            Element* _indicate_colour;
        }
    }
    String _component;
    ClockDomain _clock;         // owned by this binding; _fmt.clock points at it
    DataFormat _fmt;
    Duration _debounce;
    Duration _hold = 1.seconds;
    Duration _click_gap = 300.msecs;
    Duration _anchor_err;
    uint _chip = 0;
    uint _gpio = uint.max;
    uint _claimed = uint.max;
    uint _edge_rate;
    ulong _edges_at_window;
    MonoTime _window_start;
    SysTime _stream_start;
    Link _link;
    Pwm _pwm;
    Ws2812 _ws;
    shared uint _signalled;
    GpioKind _kind;
    ActiveLevel _active;
    Pull _pull;
    LightEffect _pattern;
    ubyte _clicks;
    ubyte _step;
    LightDrive _drive;
    ubyte _index;
    ubyte _pixel;
    bool _indicating;
    bool _pressed;
    bool _unsettled;
    bool _phase;

    static Element* report(Element* e)
    {
        e.sampling_mode = SamplingMode.report;
        return e;
    }

    CompletionStatus start_capture()
    {
        static if (has_gpio_sampler)
        {
            Result r = gpio_sampler_open(_chip, _gpio, _sampler, _pull, cast(uint)debounce.as!"usecs");
            if (r.failed)
            {
                log.error("failed to open gpio sampler chip=", _chip, " line=", _gpio, " (error ", r.system_code, ")");
                return CompletionStatus.error;
            }
            if (!g_app.reactor.watch_fd(_sampler.fd, false, &on_ready))
            {
                _sampler.close();
                log.error("failed to register gpio sampler with the reactor");
                return CompletionStatus.error;
            }
            _watched = true;
            log.info("gpio sampler backend=", _sampler.backend_name(), " chip=", _chip, " line=", _gpio);
            _element.ensure_history();   // scaffold retains everything; retention policy TODO
            _edges_at_window = _element.record_count;
            _window_start = getTime();
            _last_anchor = _window_start;
            _stream_start = SysTime();
            _clock.nominal_rate = _sampler.clock_hz();
            _clock.anchors.clear();     // new stream: sample-0 anchor is re-established on the first edge
            _have_stream = false;
            set_device_online(true);
            return CompletionStatus.complete;
        }
        else
        {
            log.error("gpio capture is not supported on this platform");
            return CompletionStatus.error;
        }
    }

    CompletionStatus start_button()
    {
        static if (has_gpio)
        {
            gpio_input_init(_gpio, _pull);
            _claimed = _gpio;
            g_app.schedule(getTime() + debounce, &baseline);
            set_device_online(true);
            return CompletionStatus.complete;
        }
        else
        {
            log.error("no gpio on this platform");
            return CompletionStatus.error;
        }
    }

    // a line just configured has not settled, so its level is taken a debounce later and raises no event
    void baseline(MonoTime now)
    {
        _pressed = read_pressed();
        _element.value(_pressed);
        if (!link_acquire(_link, gpio_event(GpioLine(_chip, _gpio), GpioInterruptTrigger.change), isr_task!input_edge(cast(void*)this)))
            g_app.schedule(now + debounce, &sample);
    }

    bool read_pressed()
    {
        static if (has_gpio)
            return gpio_input_read(_gpio) != (_active == ActiveLevel.low);
        else
            return false;
    }

    // Button edges arrive in interrupt context; the sweep carries them to the main loop.
    @isr_safe @critical static bool input_edge(void* context, LinkContext)
    {
        atomicStore!(MemoryOrder.release)((cast(GpioBinding)context)._signalled, 1u);
        if (g_app is null || !cas(&_sweep_pending, 0u, 1u))
            return false;
        bool queued;
        immutable woke = g_app.post_event_from_isr(&_sweep.event, EventPriority.control, queued);
        if (!queued)
            atomicStore!(MemoryOrder.release)(_sweep_pending, 0u);
        return woke;
    }

    // A posted event cannot be recalled, so it finds its bindings by walking the collection.
    static struct EdgeSweep
    {
        void event(MonoTime) nothrow @nogc
        {
            atomicStore!(MemoryOrder.release)(_sweep_pending, 0u);
            foreach (GpioBinding b; Collection!GpioBinding().values)
            {
                if (b._link.is_open && cas(&b._signalled, 1u, 0u))
                    b.edged();
            }
        }
    }
    __gshared EdgeSweep _sweep;
    static shared uint _sweep_pending;

    void edged()
    {
        g_app.cancel(&settle);
        g_app.schedule(getTime() + debounce, &settle);
    }

    void settle(MonoTime)
    {
        bool pressed = read_pressed();
        if (pressed != _pressed)
            transition(pressed);
    }

    // No edge link on this platform: a level must hold for two samples to count.
    void sample(MonoTime now)
    {
        bool pressed = read_pressed();
        if (pressed == _pressed)
            _unsettled = false;
        else if (_unsettled)
        {
            _unsettled = false;
            transition(pressed);
        }
        else
            _unsettled = true;
        g_app.schedule(now + debounce, &sample);
    }

    void transition(bool pressed)
    {
        _pressed = pressed;
        _element.value(pressed);
        MonoTime now = getTime();
        if (pressed)
        {
            g_app.cancel(&gap_elapsed);
            g_app.schedule(now + _hold, &hold_elapsed);
        }
        else if (!g_app.cancel(&hold_elapsed))
            _event.value(ButtonEvent.release);
        else if (++_clicks == click_events.length)
            gap_elapsed(now);
        else
            g_app.schedule(now + _click_gap, &gap_elapsed);
    }

    void hold_elapsed(MonoTime)
    {
        _clicks = 0;
        _event.value(ButtonEvent.hold);
    }

    void gap_elapsed(MonoTime)
    {
        _event.value(click_events[_clicks - 1]);
        _clicks = 0;
    }

    CompletionStatus start_output()
    {
        static if (has_gpio)
        {
            if (_element.value.isNull)
                _element.value(false);
            if (_kind == GpioKind.light)
            {
                if (_effect.value.isNull)
                    _effect.value(LightEffect.none);
                if (_indicate.value.isNull)
                    _indicate.value(LightEffect.none);
                _effect.subscribe(&output_changed);
                _indicate.subscribe(&output_changed);
                _pulse.subscribe(&output_changed);
                if (_level)
                {
                    if (_level.value.isNull)
                        _level.value(Level(100));
                    _level.subscribe(&output_changed);
                }
                if (_colour)
                {
                    if (_colour.value.isNull)
                        _colour.value(Colour(255, 255, 255));
                    _colour.subscribe(&output_changed);
                    _indicate_colour.subscribe(&output_changed);
                }
            }
            _element.subscribe(&output_changed);
            if (!_pwm.is_open && !_ws.is_open)
            {
                gpio_output_init(_gpio, _active == ActiveLevel.low);
                _claimed = _gpio;
            }
            render();
            set_device_online(true);
            return CompletionStatus.complete;
        }
        else
        {
            log.error("no gpio on this platform");
            return CompletionStatus.error;
        }
    }

    void output_changed(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        if (update.element is _pulse)
            pulse();
        else
            render();
    }

    // a steady light inverts briefly; a pattern already shows its own motion
    void pulse()
    {
        if (_pattern != LightEffect.none)
            return;
        g_app.cancel(&pulse_elapsed);
        show(!_phase);
        g_app.schedule(getTime() + pulse_length, &pulse_elapsed);
    }

    void pulse_elapsed(MonoTime)
    {
        show(_phase);
    }

    // indicate overrides the owner's state; while it is none the owner's switch and effect show
    void render()
    {
        g_app.cancel(&phase_elapsed);
        g_app.cancel(&pulse_elapsed);
        g_app.cancel(&breathe_step);
        g_app.cancel(&rainbow_step);
        bool lit = _element.value.asBool;
        _pattern = LightEffect.none;
        if (_kind == GpioKind.light)
        {
            LightEffect indicate = cast(LightEffect)_indicate.value.asLong;
            _indicating = indicate != LightEffect.none;
            if (_indicating)
            {
                lit = true;
                _pattern = indicate;
            }
            else if (lit)
                _pattern = cast(LightEffect)_effect.value.asLong;
        }
        _phase = lit;
        if (_pattern == LightEffect.rainbow && !_ws.is_open)
            _pattern = LightEffect.none;
        if (_pattern == LightEffect.breathe && (_pwm.is_open || _ws.is_open))
        {
            _step = 0;
            breathe_step(getTime());
            return;
        }
        if (_pattern == LightEffect.rainbow)
        {
            _step = 0;
            rainbow_step(getTime());
            return;
        }
        show(lit);
        if (_pattern != LightEffect.none)
            g_app.schedule(getTime() + msecs(effect_ms[_pattern][0]), &phase_elapsed);
    }

    // a triangle over breathe_steps, squared so the fade looks even to the eye
    void breathe_step(MonoTime scheduled)
    {
        uint t = _step < breathe_steps / 2 ? _step : breathe_steps - _step;
        output(brightness() * t * t / (breathe_steps / 2 * breathe_steps / 2));
        if (++_step == breathe_steps)
            _step = 0;
        g_app.schedule(scheduled + breathe_step_time, &breathe_step);
    }

    // one turn of the hue wheel every 256 steps
    void rainbow_step(MonoTime scheduled)
    {
        pixel(wheel(_step++), brightness());
        g_app.schedule(scheduled + breathe_step_time, &rainbow_step);
    }

    static Colour wheel(ubyte position)
    {
        if (position < 85)
            return Colour(cast(ubyte)(255 - position * 3), cast(ubyte)(position * 3), 0);
        if (position < 170)
            return Colour(0, cast(ubyte)(255 - (position - 85) * 3), cast(ubyte)((position - 85) * 3));
        return Colour(cast(ubyte)((position - 170) * 3), 0, cast(ubyte)(255 - (position - 170) * 3));
    }

    // the owner's level out of pwm_period, squared for the eye
    uint brightness()
    {
        uint p = _level ? (cast(Level)_level.value.asQuantity()).value : 100;
        if (p > 100)
            p = 100;
        return p * p * pwm_period / 10_000;
    }

    void phase_elapsed(MonoTime scheduled)
    {
        _phase = !_phase;
        show(_phase);
        g_app.schedule(scheduled + msecs(effect_ms[_pattern][_phase ? 0 : 1]), &phase_elapsed);
    }

    void show(bool on)
    {
        output(on ? brightness() : 0);
    }

    // intensity runs to pwm_period
    void output(uint intensity)
    {
        if (_ws.is_open)
            pixel(colour(), intensity);
        else if (_pwm.is_open)
            pwm_set_duty(_pwm, intensity);
        else static if (has_gpio)
            gpio_output_set(_gpio, (intensity != 0) != (_active == ActiveLevel.low));
    }

    void pixel(Colour c, uint intensity)
    {
        ws2812_set(_ws, _pixel, (c.r * intensity / pwm_period) << 16 | (c.g * intensity / pwm_period) << 8 | c.b * intensity / pwm_period);
    }

    Colour colour()
    {
        Variant v;
        if (_indicating)
            v = _indicate_colour.value;
        if (!v.isUser!Colour)
            v = _colour.value;
        return v.isUser!Colour ? v.asUser!Colour : Colour(255, 255, 255);
    }

    static if (has_gpio_sampler)
    {
        GpioSampler _sampler;
        bool _watched;
        bool _have_stream;
        ulong _stream_first_tick;
        MonoTime _last_anchor;

        void on_ready(IoReady ready)
        {
            GpioEdge[64] edges = void;
            GpioDrainStatus status = GpioDrainStatus.drained;
            if (ready & IoReady.readable)
            {
                size_t count;
                do
                {
                    status = _sampler.drain(edges[], count);
                    if (count)
                        write_edges(edges[0 .. count]);
                }
                while (status == GpioDrainStatus.drained && count == edges.length);
            }

            if (status != GpioDrainStatus.drained || (ready & IoReady.error))
            {
                detach_watch();
                set_device_online(false);
                restart();
            }
        }

        void write_edges(const(GpioEdge)[] edges)
        {
            if (!_have_stream)
                anchor_stream(edges[0].tick);

            bool[64] levels = void;
            ulong[64] ticks = void;
            foreach (i, ref edge; edges)
            {
                levels[i] = edge.level;
                ticks[i] = edge.tick - _stream_first_tick;
            }
            _element.write_samples(levels[0 .. edges.length], ticks[0 .. edges.length]);
            mark_set!(typeof(this), ["records", "buckets", "last-edge"])();
        }

        void detach_watch()
        {
            if (_watched)
            {
                g_app.unwatch_io(_sampler.fd);
                _watched = false;
            }
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
    }
}


final class GpioModule : Module
{
    mixin DeclareModule!"protocol.gpio";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!Pull();
        g_app.register_enum!GpioKind();
        g_app.register_enum!ActiveLevel();
        g_app.register_enum!PwmChannel();
        g_app.console.register_collection!GpioBinding();
    }
}
