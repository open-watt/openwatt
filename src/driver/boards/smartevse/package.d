/*
 * SmartEVSE v3.0 port status and parity ledger
 *
 * Upstream baseline:
 *   https://github.com/SmartEVSE/SmartEVSE-3
 *   5891a7716b8ecf222da9c4e6e58a0aa766c1a40f
 *
 * evse.d retains upstream function names, ordering and control flow where
 * practical. Any intentional behavioral difference belongs in this ledger.
 * Feature parity means reproducing the externally observable EVSE, protection
 * and board behavior. It does not mean copying upstream networking or UI
 * implementations when OpenWatt supplies the equivalent service.
 *
 * Supported product envelope:
 * - BOARD=smartevse-v30 selects the SmartEVSE v3.0 ESP32 pin map.
 * - Only a fixed, tethered cable is supported until the cable-lock driver and
 *   lock-position validation are implemented.
 * - Contactor 2 supports explicit always-follow and always-open policies.
 * - OpenWatt supplies current allocation, networking and remote management.
 *
 * Implemented:
 * - CP PWM and edge-relative sampling, composed from urt primitives via the
 *   link fabric: CP_OUT rising edge reloads a counter, the counter alarm runs
 *   a board @isr_safe handler that reads CP through the critical ADC path
 *   into a seqlock ring; pilot_snapshot hands D an oldest-first copy.
 * - ESP32 line-fitting ADC calibration for CP, PP and temperature, using
 *   factory eFuse values when present and upstream's 1100 mV fallback.
 *   Upstream's legacy esp_adc_cal_characterize calls are translated to the
 *   ESP-IDF 6 line-fitting API with the same unit, attenuation and 10-bit
 *   width; converted readings still flow through the upstream functions.
 * - Pilot and diode detection with the basic A/B/C/B1/C1 transitions.
 * - Upstream activation mode: after 30 seconds in B, pulse CP to 0% for
 *   3 seconds, restore the advertised current and retry State B once.
 * - PP cable-capacity sampling and current limiting.
 * - Configurable requested and maximum current in deci-amps.
 * - Temperature sampling and the upstream default thermal protection:
 *   stop above 65 C and resume below 55 C. The upstream 40-75 C maximum
 *   setting range is exposed; the 10 C recovery hysteresis remains fixed.
 * - Module-owned hardware lifetime and safe offline electrical outputs.
 * - Exclusive ActiveObject ownership, automatic charging on connection and
 *   explicit start/stop control.
 * - Event-driven Device binding for charge current, start/stop, installation
 *   limits, EVSE state, protection state and board diagnostics.
 * - RCM input monitoring. A cache-safe rising-edge callback first clears SSR1
 *   and SSR2, then latches a DRAM flag. The ActiveObject enters an error state
 *   and can acknowledge it only after the input clears.
 *
 * Intentional architecture deviations:
 * - OpenWatt scheduled events replace the upstream FreeRTOS 10 ms, 100 ms and
 *   1 second tasks. Events are rescheduled from their intended deadline.
 * - The Module owns initialized hardware while offline; one ActiveObject may
 *   claim it while online.
 * - OpenWatt properties and commands replace upstream menu/global mutation.
 * - OpenWatt protocols replace upstream WiFi, web/API, MQTT, OCPP and OTA.
 * - OpenWatt energy control will replace upstream Smart/Solar allocation,
 *   meter polling and multi-EVSE current distribution.
 * - STATE_ERROR is an OpenWatt extension. Upstream represents faults in a
 *   separate ErrorFlags bitmask.
 * - SmartEVSE v3.0 is selected explicitly. Upstream runtime v3.1 detection is
 *   deliberately not used by this BOARD.
 *
 * TODO - control-source parity:
 * - Restore the complete relevant upstream Timer10ms_singlerun,
 *   Timer100ms_singlerun and Timer1S_singlerun flow before reducing it.
 * - Port the full ErrorFlags model and gate every transition to power-available
 *   states on the applicable errors.
 * - Audit every transition and timer against the pinned upstream revision,
 *   including the 500 ms B-to-C and CP-short filters, C1 contactor delay,
 *   ChargeDelay and pilot-disconnect sequence.
 * - Restore the upstream OFF/ON/PAUSE access semantics or document the exact
 *   OpenWatt start/stop mapping.
 * - Decide how ventilation-request State D is represented. Upstream defines it
 *   but does not provide a complete ventilation implementation.
 * - Preserve a mechanically useful deviation list whenever upstream behavior
 *   is intentionally replaced.
 *
 * TODO - ADC and interrupt safety:
 * - Verify the C/IRAM CP path and locked sample/sensor handoff on hardware
 *   under normal load and during flash erase/write.
 *
 * TODO - RCM and fail-safe behavior:
 * - Measure the cache-safe RCM interrupt latency on hardware.
 * - A software interrupt cannot protect against disabled interrupts, a wedged
 *   CPU or arbitrary memory corruption. A guarantee under those failures
 *   requires an external hardware interlock from RCM fault to contactor drive.
 * - Upstream ESP32 v3 polls and double-checks RCM in its 10 ms task; it has no
 *   software-driven RCM self-test output. The upstream RCM test sequence is for
 *   the CH32 companion hardware, so it is not missing v3.0 behavior.
 * - Verify the physical RCM trip level, polarity, interruption time and reset
 *   behavior by fault injection on the actual board.
 *
 * TODO - contactors, cable and installation:
 * - Verify always-follow and always-open contactor-2 behavior on hardware.
 * - Add the remaining upstream contactor-2 policies when phase selection is
 *   integrated: solar-off, always-on and automatic 1P/3P switching.
 * - Define the fixed-cable capacity source. Upstream ignores PP in fixed-cable
 *   mode and uses the configured maximum cable current.
 * - Reject socket configuration until actuator drive, 600 ms lock/unlock
 *   pulses, lock-position feedback, retry timing and safe unlock behavior are
 *   implemented.
 * - Determine whether contactor auxiliary feedback is available. If it is,
 *   detect failure-to-close and welded/failure-to-open conditions.
 *
 * TODO - board feature parity:
 * - Cable lock actuator and lock-position input.
 * - LCD initialization, Offline indication, normal status/error screens,
 *   buttons and backlight.
 * - RGB status LED and buzzer behavior.
 * - External switch/button modes.
 * - RFID/OneWire reader, card storage and access policy.
 * - RS485 transport, supported energy meters, Sensorbox and multi-EVSE load
 *   balancing.
 * - Persistent EVSE settings and session/energy accounting.
 * - Delayed charging and phase-switching coordination.
 * - SmartEVSE v3.1 and v4 as separate explicit BOARD targets.
 *
 * TODO - OpenWatt integration:
 * - Define selective build components so the board can include IP, HTTP, TLS,
 *   API, sync and OTA without pulling unrelated modules.
 * - Build and size the actual UART-test and network/OTA feature sets
 *   independently. The current small FEATURES=switch image has no IP, HTTP or
 *   TLS and is only the first UART CLI test image.
 *
 * TODO - verification:
 * - Add host tests for pilot classification, diode gating, current-to-duty
 *   conversion, PP limits, all state transitions and every timer boundary.
 * - Add hardware tests for A/B/C, CP open/short/invalid levels, PP resistor
 *   values, unplug under load, start/stop, both contactor-2 policies, RCM trip
 *   and reset, thermal trip/recovery and reboot/watchdog while charging.
 * - Test CP and RCM interrupt behavior during flash erase/write and OTA.
 * - Measure calibrated CP, PP and temperature values on several boards and
 *   record acceptable production tolerances.
 * - Run the applicable IEC 61851-1 and IEC 62196 installation/product tests;
 *   firmware thresholds do not replace thermal-rise and electrical-safety
 *   validation of the complete EVSE.
 */
module driver.boards.smartevse;

version (SmartEVSE):

import urt.array : Array;
import urt.meta : AliasSeq;
import urt.meta.nullable : Nullable;
import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.attribute : critical;
import urt.driver.gpio;
import urt.result : Result;
import urt.si.quantity : Quantity;
import urt.si.unit : Ampere, ScaledUnit;
import urt.time : MonoTime, getTime, msecs;

import manager : g_app;
import manager.base : ActiveObject, CompletionStatus, ObjectFlags, Prop;
import manager.collection : CID, Collection, CollectionType, collection_type_info;
import manager.console.session : Session;
import manager.plugin : DeclareModule, Module;

import driver.boards.smartevse.display;
import driver.boards.smartevse.binding : SmartEVSEBinding;
import driver.boards.smartevse.hardware;

public import driver.boards.smartevse.evse;

nothrow @nogc:


alias DeciAmps = Quantity!(ushort, ScaledUnit(Ampere, -1));

struct SmartEVSEButton
{
    enum ubyte left   = 1 << 0;
    enum ubyte middle = 1 << 1;
    enum ubyte right  = 1 << 2;
}

struct SmartEVSEChange
{
    enum uint current             = 1 << 0;
    enum uint max_current         = 1 << 1;
    enum uint pp_max_current      = 1 << 2;
    enum uint stopped             = 1 << 3;
    enum uint state               = 1 << 4;
    enum uint pilot               = 1 << 5;
    enum uint pwm                 = 1 << 6;
    enum uint effective_current   = 1 << 7;
    enum uint pilot_min_mv        = 1 << 8;
    enum uint pilot_max_mv        = 1 << 9;
    enum uint pp_mv               = 1 << 10;
    enum uint temperature_mv      = 1 << 11;
    enum uint temperature         = 1 << 12;
    enum uint max_temperature     = 1 << 13;
    enum uint temperature_fault   = 1 << 14;
    enum uint rcm_input           = 1 << 15;
    enum uint rcm_fault           = 1 << 16;
    enum uint activation_wait     = 1 << 17;
    enum uint activation_pulse    = 1 << 18;
    enum uint contactor2_mode     = 1 << 19;
    enum uint contactor1          = 1 << 20;
    enum uint contactor2          = 1 << 21;
    enum uint buttons             = 1 << 22;
    enum uint backlight           = 1 << 23;
    enum uint frame               = 1 << 24;
    enum uint rcm_monitor         = 1 << 25;
    enum uint all                 = (1 << 26) - 1;
}

alias SmartEVSEChangeHandler = void delegate(SmartEVSE evse, uint changes) nothrow @nogc;
enum SmartEVSEState : ubyte
{
    a = STATE_A,
    b = STATE_B,
    c = STATE_C,
    activation = STATE_ACTSTART,
    b1 = STATE_B1,
    c1 = STATE_C1,
    error = STATE_ERROR,
}

enum SmartEVSEPilot : ubyte
{
    invalid = PILOT_NOK,
    diode = PILOT_DIODE,
    v3 = PILOT_3V,
    v6 = PILOT_6V,
    v9 = PILOT_9V,
    v12 = PILOT_12V,
    short_ = PILOT_SHORT,
}

enum SmartEVSEContactor2Mode : ubyte
{
    always_follow = CONTACTOR2_ALWAYS_FOLLOW,
    always_open = CONTACTOR2_ALWAYS_OPEN,
}

enum SmartEVSEADCCalibration : ubyte
{
    efuse_vref = 0,
    efuse_two_point = 1,
    default_vref = 2,
    unavailable = 255,
}


class SmartEVSE : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("current", current),
                                 Prop!("max-current", max_current),
                                 Prop!("pp-max-current", pp_max_current, "status", "d"),
                                 Prop!("stopped", stopped, "status", "d"),
                                 Prop!("state", state, "status", "d"),
                                 Prop!("pilot", pilot, "status", "d"),
                                 Prop!("pwm", pwm, "status", "d"),
                                 Prop!("effective-current", effective_current, "status", "d"),
                                 Prop!("pilot-min-mv", pilot_min_mv, "status", "d"),
                                 Prop!("pilot-max-mv", pilot_max_mv, "status", "d"),
                                 Prop!("pp-mv", pp_mv, "status", "d"),
                                 Prop!("temperature-mv", temperature_mv, "status", "d"),
                                 Prop!("adc-calibration", adc_calibration, "status", "d"),
                                 Prop!("temperature", temperature, "status", "d"),
                                 Prop!("max-temperature", max_temperature),
                                 Prop!("temperature-fault", temperature_fault, "status", "d"),
                                 Prop!("rcm-input", rcm_input, "status", "d"),
                                 Prop!("rcm-fault", rcm_fault, "status", "d"),
                                 Prop!("rcm-monitor", rcm_monitor),
                                 Prop!("activation-wait", activation_wait, "status", "d"),
                                 Prop!("activation-pulse", activation_pulse, "status", "d"),
                                 Prop!("contactor2-mode", contactor2_mode),
                                 Prop!("contactor1", contactor1, "status", "d"),
                                 Prop!("contactor2", contactor2, "status", "d"));
nothrow @nogc:

    enum type_name = "smartevse";
    enum path = "/driver/boards/smartevse";
    enum collection_id = CollectionType.smartevse;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SmartEVSE, id, flags);
    }

    void subscribe_changes(SmartEVSEChangeHandler handler)
    {
        foreach (existing; _change_handlers)
            assert(existing !is handler, "SmartEVSE change handler already subscribed");
        _change_handlers ~= handler;
    }

    void unsubscribe_changes(SmartEVSEChangeHandler handler) pure
    {
        _change_handlers.removeFirstSwapLast(handler);
    }

    DeciAmps current() const pure
        => _current;

    void current(DeciAmps value)
    {
        if (_current == value)
            return;
        _current = value;
        mark_set!(typeof(this), "current")();

        apply_current();
        sync_status(SmartEVSEChange.current);
    }

    DeciAmps max_current() const pure
        => _max_current;

    void max_current(DeciAmps value)
    {
        if (_max_current == value)
            return;
        _max_current = value;
        mark_set!(typeof(this), "max-current")();

        apply_current();
        sync_status(SmartEVSEChange.max_current);
    }

    DeciAmps pp_max_current() const pure
        => _pp_max_current;

    bool stopped() const pure
        => _stopped;

    SmartEVSEState state() const pure
        => _state;

    const(char)[] state(SmartEVSEState value)
    {
        if (value != SmartEVSEState.a)
            return "state is controlled by the EVSE; only state=a can acknowledge an RCM fault";
        return reset_fault();
    }

    SmartEVSEPilot pilot() const pure
        => _pilot;

    uint pwm() const pure
        => _current_pwm;

    DeciAmps effective_current() const pure
        => _effective_current;

    uint pilot_min_mv() const pure
        => _pilot_min_mv;

    uint pilot_max_mv() const pure
        => _pilot_max_mv;

    uint pp_mv() const pure
        => _pp_mv;

    uint temperature_mv() const pure
        => _temperature_mv;

    SmartEVSEADCCalibration adc_calibration() const
    {
        int source = adc_calibration_source(Hardware);
        return source < 0 ? SmartEVSEADCCalibration.unavailable
                          : cast(SmartEVSEADCCalibration)source;
    }

    short temperature() const pure
        => _temperature;

    short max_temperature() const pure
        => _max_temperature;

    void max_temperature(short value)
    {
        if (_max_temperature == value)
            return;
        _max_temperature = value;
        mark_set!(typeof(this), "max-temperature")();
        notify_changes(SmartEVSEChange.max_temperature);
        restart();
    }

    bool temperature_fault() const pure
        => _temperature_fault;

    bool rcm_input() const
        => gpio_input_read(RCMFAULT);

    bool rcm_fault() const pure
        => _rcm_fault;

    bool rcm_monitor() const pure
        => _rcm_monitor;

    void rcm_monitor(bool value)
    {
        if (_rcm_monitor == value)
            return;
        _rcm_monitor = value;
        mark_set!(typeof(this), "rcm-monitor")();
        sync_status(SmartEVSEChange.rcm_monitor);
        restart();
    }

    ubyte activation_wait() const pure
        => _activation_wait;

    ubyte activation_pulse() const pure
        => _activation_pulse;

    SmartEVSEContactor2Mode contactor2_mode() const pure
        => _contactor2_mode;

    const(char)[] contactor2_mode(SmartEVSEContactor2Mode value)
    {
        if (_contactor2_mode == value)
            return null;
        if (running && (CurrentState() == STATE_C || CurrentState() == STATE_C1))
            return "contactor2-mode cannot change while charging is active";
        _contactor2_mode = value;
        mark_set!(typeof(this), "contactor2-mode")();
        setContactor2Mode(cast(ubyte)value);
        sync_status(SmartEVSEChange.contactor2_mode);
        return null;
    }

    bool contactor1() const pure
        => _contactor1;

    bool contactor2() const pure
        => _contactor2;

    ubyte buttons() const pure
        => _buttons;

    bool backlight() const
        => display_backlight(g_display);

    void backlight(bool value)
    {
        if (display_backlight(g_display) == value)
            return;
        display_backlight(g_display, value);
        sync_status(SmartEVSEChange.backlight);
    }

    const(void)[] frame() const
        => display_frame(g_display);

    bool frame(const(void)[] value)
    {
        if (!display_frame(g_display, value))
            return false;
        sync_status(SmartEVSEChange.frame);
        return true;
    }

    const(char)[] start_charging()
    {
        if (_rcm_fault)
            return "RCM fault is latched";
        if (_temperature_fault)
            return "temperature is above the configured limit";
        if (!running)
            return "SmartEVSE is not online";

        if (_stopped)
        {
            _stopped = false;
            mark_set!(typeof(this), "stopped")();
        }
        setAccess(1);
        sync_status(SmartEVSEChange.stopped);
        return null;
    }

    const(char)[] stop_charging()
    {
        if (!running)
            return "SmartEVSE is not online";

        if (!_stopped)
        {
            _stopped = true;
            mark_set!(typeof(this), "stopped")();
        }
        setAccess(0);
        sync_status(SmartEVSEChange.stopped);
        return null;
    }

    void heartbeat(MonoTime)
    {
        uint changes;
        Timer1S_singlerun();
        if (sync_pp_max_current())
            changes |= SmartEVSEChange.pp_max_current;
        short next_temperature = TemperatureSensor();
        if (_temperature != next_temperature)
        {
            _temperature = next_temperature;
            mark_set!(typeof(this), "temperature")();
            changes |= SmartEVSEChange.temperature;
        }
        changes |= update_temperature_protection();
        sync_status(changes);
    }

protected:

    override bool validate() const pure
        => _current.value >= MIN_CURRENT * 10 && _current.value <= MAX_CURRENT
        && _max_current.value >= MIN_CURRENT * 10 && _max_current.value <= MAX_CURRENT
        && _max_temperature >= MIN_MAX_TEMPERATURE
        && _max_temperature <= MAX_MAX_TEMPERATURE
        && !_rcm_fault;

    override const(char)[] status_detail() const pure
        => _rcm_fault
         ? "Failed: RCM fault latched; clear the fault and set state=a"
         : null;

    override CompletionStatus startup()
    {
        if (!_hardware_ready)
        {
            log.error("SmartEVSE hardware is unavailable");
            return CompletionStatus.error;
        }
        if (_hardware_owner !is _hardware_module)
        {
            log.error("SmartEVSE hardware is already owned by another object");
            return CompletionStatus.error;
        }

        _hardware_owner = this;
        _active_hardware_owner = this;

        apply_current();
        setContactor2Mode(cast(ubyte)_contactor2_mode);
        RCmonCtrl(_rcm_monitor ? ENABLE : DISABLE);
        if (_rcm_monitor && (rcm_fault_signalled() || gpio_input_read(RCMFAULT)))
        {
            _rcm_fault = true;
            mark_set!(typeof(this), "rcm-fault")();
            setRCMFault(true);
            setState(STATE_ERROR);
            sync_status(SmartEVSEChange.rcm_fault);
            log.error("RCM fault active during SmartEVSE startup");
            return CompletionStatus.error;
        }

        setRCMFault(false);
        uint changes;
        if (sync_pp_max_current())
            changes |= SmartEVSEChange.pp_max_current;
        if (_stopped)
        {
            _stopped = false;
            mark_set!(typeof(this), "stopped")();
            changes |= SmartEVSEChange.stopped;
        }
        setState(STATE_A);
        setAccess(1);
        arm_control_tick(getTime() + msecs(10));
        sync_status(changes);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_active_hardware_owner !is this)
            return CompletionStatus.complete;

        if (_tick_armed)
        {
            g_app.cancel(&control_tick);
            _tick_armed = false;
        }

        setAccess(0);
        RCmonCtrl(DISABLE);
        uint changes;
        if (_stopped)
        {
            _stopped = false;
            mark_set!(typeof(this), "stopped")();
            changes |= SmartEVSEChange.stopped;
        }
        if (_rcm_fault)
        {
            setState(STATE_ERROR);
            sync_status(changes);
        }
        _active_hardware_owner = null;
        hardware_offline();
        _hardware_owner = _hardware_module;
        if (!_rcm_fault)
            sync_status(changes);
        return CompletionStatus.complete;
    }

private:

    bool _stopped;
    bool _contactor1;
    bool _contactor2;
    ubyte _buttons;
    bool _temperature_fault;
    bool _rcm_fault;
    bool _rcm_monitor;
    bool _rcm_input;
    bool _tick_armed;
    DeciAmps _current = DeciAmps(MIN_CURRENT * 10);
    DeciAmps _max_current = DeciAmps(MAX_CURRENT);
    DeciAmps _pp_max_current = DeciAmps(130);
    DeciAmps _effective_current;
    short _temperature;
    short _max_temperature = DEFAULT_MAX_TEMPERATURE;
    uint _current_pwm = 1024;
    uint _pilot_min_mv;
    uint _pilot_max_mv;
    uint _pp_mv;
    uint _temperature_mv;
    ubyte _activation_wait;
    ubyte _activation_pulse;
    SmartEVSEState _state = SmartEVSEState.a;
    SmartEVSEPilot _pilot = SmartEVSEPilot.invalid;
    SmartEVSEContactor2Mode _contactor2_mode = SmartEVSEContactor2Mode.always_follow;
    Array!SmartEVSEChangeHandler _change_handlers;

    void arm_control_tick(MonoTime when)
    {
        g_app.schedule(when, &control_tick);
        _tick_armed = true;
    }

    DeciAmps limited_current() const pure
    {
        ushort limit = _max_current.value < _pp_max_current.value
                     ? _max_current.value : _pp_max_current.value;
        return DeciAmps(_current.value < limit ? _current.value : limit);
    }

    void apply_current()
    {
        ChargeCurrent = limited_current().value;
        if (running && !_stopped && (CurrentState() == STATE_B || CurrentState() == STATE_C))
            SetCurrent(ChargeCurrent);
    }

    bool sync_pp_max_current()
    {
        MaxCapacity = ProximityPin();
        DeciAmps next = DeciAmps(cast(ushort)(MaxCapacity * 10));
        if (_pp_max_current == next)
            return false;

        _pp_max_current = next;
        mark_set!(typeof(this), "pp-max-current")();
        apply_current();
        return true;
    }

    uint update_temperature_protection()
    {
        if (!_temperature_fault && _temperature > _max_temperature)
        {
            _temperature_fault = true;
            mark_set!(typeof(this), "temperature-fault")();
            setTemperatureFault(true);
            setStatePowerUnavailable();
            log.error("SmartEVSE over-temperature fault");
            return SmartEVSEChange.temperature_fault;
        }
        else if (_temperature_fault
              && _temperature < _max_temperature - TEMPERATURE_HYSTERESIS)
        {
            _temperature_fault = false;
            mark_set!(typeof(this), "temperature-fault")();
            setTemperatureFault(false);
            log.info("SmartEVSE temperature recovered");
            return SmartEVSEChange.temperature_fault;
        }
        return 0;
    }

    const(char)[] reset_fault()
    {
        if (gpio_input_read(RCMFAULT))
            return "RCM input is still active";
        if (!_rcm_fault)
            return "no RCM fault is latched";

        residual_current_fired(Hardware);
        atomicStore!(MemoryOrder.release)(_rcm_fault_pending, 0);
        setRCMFault(false);
        _rcm_fault = false;
        mark_set!(typeof(this), "rcm-fault")();
        uint changes = SmartEVSEChange.rcm_input | SmartEVSEChange.rcm_fault;
        if (_state != SmartEVSEState.a)
        {
            _state = SmartEVSEState.a;
            mark_set!(typeof(this), "state")();
            changes |= SmartEVSEChange.state;
        }
        notify_changes(changes);
        restart();
        return null;
    }

    void control_tick(MonoTime scheduled)
    {
        _tick_armed = false;
        if (!running)
            return;

        if (_rcm_monitor
            && (rcm_fault_signalled() || gpio_input_read(RCMFAULT))
            && !_rcm_fault)
        {
            handle_rcm_fault();
            return;
        }

        sample_buttons();
        Timer10ms_singlerun();
        sync_status();

        MonoTime next = scheduled + msecs(10);
        MonoTime now = getTime();
        if (next <= now)
            next = now + msecs(10);
        arm_control_tick(next);
    }

    // display_buttons reports released bits and refuses while the panel bus is busy; invert to
    // pressed here so a busy sample reads as no-change rather than a phantom release.
    void sample_buttons()
    {
        ubyte pressed = (~display_buttons(g_display)) & 0x7;
        if (pressed == _buttons)
            return;
        _buttons = pressed;
        sync_status(SmartEVSEChange.buttons);
    }

    void handle_rcm_fault()
    {
        if (_rcm_fault)
            return;
        setRCMFault(true);
        _rcm_fault = true;
        mark_set!(typeof(this), "rcm-fault")();
        setState(STATE_ERROR);
        sync_status(SmartEVSEChange.rcm_fault);
        log.error("RCM fault latched");
        restart();
    }

    void sync_status(uint changes = 0)
    {
        SmartEVSEState next_state = cast(SmartEVSEState)CurrentState();
        if (_state != next_state)
        {
            _state = next_state;
            mark_set!(typeof(this), "state")();
            changes |= SmartEVSEChange.state;
        }

        SmartEVSEPilot next_pilot = cast(SmartEVSEPilot)Pilot();
        if (_pilot != next_pilot)
        {
            _pilot = next_pilot;
            mark_set!(typeof(this), "pilot")();
            changes |= SmartEVSEChange.pilot;
        }

        if (_current_pwm != CurrentPWM)
        {
            _current_pwm = CurrentPWM;
            mark_set!(typeof(this), "pwm")();
            changes |= SmartEVSEChange.pwm;
        }
        DeciAmps next_effective_current = DeciAmps(GetCurrent());
        if (_effective_current != next_effective_current)
        {
            _effective_current = next_effective_current;
            mark_set!(typeof(this), "effective-current")();
            changes |= SmartEVSEChange.effective_current;
        }
        if (_pilot_min_mv != PilotMinMV)
        {
            _pilot_min_mv = PilotMinMV;
            mark_set!(typeof(this), "pilot-min-mv")();
            changes |= SmartEVSEChange.pilot_min_mv;
        }
        if (_pilot_max_mv != PilotMaxMV)
        {
            _pilot_max_mv = PilotMaxMV;
            mark_set!(typeof(this), "pilot-max-mv")();
            changes |= SmartEVSEChange.pilot_max_mv;
        }
        if (_pp_mv != PPVoltageMV)
        {
            _pp_mv = PPVoltageMV;
            mark_set!(typeof(this), "pp-mv")();
            changes |= SmartEVSEChange.pp_mv;
        }
        if (_temperature_mv != TemperatureVoltageMV)
        {
            _temperature_mv = TemperatureVoltageMV;
            mark_set!(typeof(this), "temperature-mv")();
            changes |= SmartEVSEChange.temperature_mv;
        }
        bool next_rcm_input = gpio_input_read(RCMFAULT);
        if (_rcm_input != next_rcm_input)
        {
            _rcm_input = next_rcm_input;
            mark_set!(typeof(this), "rcm-input")();
            changes |= SmartEVSEChange.rcm_input;
        }
        if (_activation_wait != ActivationMode)
        {
            _activation_wait = ActivationMode;
            mark_set!(typeof(this), "activation-wait")();
            changes |= SmartEVSEChange.activation_wait;
        }
        if (_activation_pulse != ActivationTimer)
        {
            _activation_pulse = ActivationTimer;
            mark_set!(typeof(this), "activation-pulse")();
            changes |= SmartEVSEChange.activation_pulse;
        }
        if (_contactor1 != Contactor1)
        {
            _contactor1 = Contactor1;
            mark_set!(typeof(this), "contactor1")();
            changes |= SmartEVSEChange.contactor1;
        }
        if (_contactor2 != Contactor2)
        {
            _contactor2 = Contactor2;
            mark_set!(typeof(this), "contactor2")();
            changes |= SmartEVSEChange.contactor2;
        }

        notify_changes(changes);
    }

    void notify_changes(uint changes)
    {
        if (!changes)
            return;
        for (size_t i = 0; i < _change_handlers.length; )
        {
            SmartEVSEChangeHandler handler = _change_handlers[i];
            handler(this, changes);
            if (i < _change_handlers.length && _change_handlers[i] is handler)
                ++i;
        }
    }
}


class SmartEVSEModule : Module
{
    mixin DeclareModule!"driver.boards.smartevse";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!SmartEVSEState();
        g_app.register_enum!SmartEVSEPilot();
        g_app.register_enum!SmartEVSEContactor2Mode();
        g_app.register_enum!SmartEVSEADCCalibration();
        g_app.console.register_collection!SmartEVSE();
        g_app.console.register_collection!SmartEVSEBinding();
        g_app.console.register_command!(cmd_start, "start")("/driver/boards/smartevse", this);
        g_app.console.register_command!(cmd_stop, "stop")("/driver/boards/smartevse", this);
        g_app.console.register_command!(cmd_display, "display")("/driver/boards/smartevse", this);

        _hardware_module = this;
        _hardware_owner = this;
        if (setup() != 0)
        {
            hardware_shutdown();
            _hardware_owner = null;
            _hardware_module = null;
            log.error("could not initialise SmartEVSE hardware");
            return;
        }
        hardware_offline();
        _hardware_ready = true;
    }

    override void deinit()
    {
        _active_hardware_owner = null;
        if (_hardware_ready)
        {
            hardware_offline();
            hardware_shutdown();
        }
        _hardware_owner = null;
        _hardware_module = null;
        _hardware_ready = false;
    }

    override void update()
    {
        Collection!SmartEVSE().update_all();
        Collection!SmartEVSEBinding().update_all();
        if (_hardware_ready)
            display_update(g_display);
    }

    void cmd_display(Session session, const(char)[] what, Nullable!uint value, Nullable!(ubyte[]) data)
    {
        import urt.string.format : tconcat;

        ubyte port = value ? cast(ubyte)value.value : g_display.port;
        const(ubyte)[] bytes = data ? data.value : null;

        void report(bool ok, const(char)[] label)
            => session.write_line(ok ? tconcat(label, ": ok") : tconcat(label, ": failed (bus busy or timed out)"));

        if (what == "pins")
        {
            uint levels = display_probe_pins(g_display);
            if (levels == uint.max)
                session.write_line("pins: bus busy");
            else
                session.write_line(tconcat("pins: clk=", (levels >> 0) & 1, " mosi=", (levels >> 1) & 1,
                                           " a0=", (levels >> 2) & 1, " rst=", (levels >> 3) & 1,
                                           " led=", (levels >> 4) & 1));
            display_reinit(g_display, g_display.port);
        }
        else if (what == "backlight")
            display_backlight(g_display, value.value != 0);
        else if (what == "reinit")
            report(display_reinit(g_display, port) == Result.success, "reinit");
        else if (what == "cmd")
            report(display_transfer(g_display, false, bytes), "cmd");
        else if (what == "data")
            report(display_transfer(g_display, true, bytes), "data");
        else if (what == "bitbang")
            report(display_bitbang(g_display), "bitbang");
        else if (what == "bbcmd")
            report(display_bitbang_bytes(g_display, false, bytes), "bbcmd");
        else if (what == "bbdata")
            report(display_bitbang_bytes(g_display, true, bytes), "bbdata");
        else if (what == "font")
        {
            display_font_test(g_display);
            session.write_line("font: drawn");
        }
        else
            session.write_line("usage: pins|backlight|reinit|cmd|data|bitbang|bbcmd|bbdata|font [value=N] [data=0x..,0x..]");
    }

    void cmd_start(Session session, SmartEVSE evse)
    {
        const(char)[] error = evse.start_charging();
        session.write_line(error ? error : "SmartEVSE started");
    }

    void cmd_stop(Session session, SmartEVSE evse)
    {
        const(char)[] error = evse.stop_charging();
        session.write_line(error ? error : "SmartEVSE stopped");
    }
}


private:

// The reflex already dropped both contactors from NMI context; this only
// carries the trip into the software latch the control flow tests.
bool rcm_fault_signalled()
{
    if (residual_current_fired(Hardware))
        atomicStore!(MemoryOrder.release)(_rcm_fault_pending, 1);
    return atomicLoad!(MemoryOrder.acquire)(_rcm_fault_pending) != 0;
}

__gshared Object _hardware_owner;
__gshared SmartEVSEModule _hardware_module;
__gshared SmartEVSE _active_hardware_owner;
__gshared bool _hardware_ready;
shared uint _rcm_fault_pending;
