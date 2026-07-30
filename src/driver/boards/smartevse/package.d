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
 * - CP PWM and edge-relative sampling. The 1 kHz ISR is entirely C/IRAM,
 *   samples CP only, and hands D a locked 25-sample snapshot.
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
 * - RCM input monitoring. A cache-safe level interrupt first clears SSR1 and
 *   SSR2 directly in GPIO registers, then latches a DRAM flag. The ActiveObject
 *   enters an error state and can acknowledge it only after the input clears.
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
 * - Measure the cache-safe level-triggered RCM interrupt latency on hardware.
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
 * - Bind EVSE state, requested/available current, faults, temperature,
 *   contactor policy and session start/stop into the Device data model.
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

import urt.meta : AliasSeq;
import urt.driver.gpio;
import urt.si.quantity : Quantity;
import urt.si.unit : Ampere, ScaledUnit;
import urt.time : MonoTime, getTime, msecs;

import manager : g_app;
import manager.base : ActiveObject, CompletionStatus, ObjectFlags, Prop;
import manager.collection : CID, Collection, CollectionType, collection_type_info;
import manager.console.session : Session;
import manager.plugin : DeclareModule, Module;

import driver.boards.smartevse.hardware;

public import driver.boards.smartevse.evse;

nothrow @nogc:


alias DeciAmps = Quantity!(ushort, ScaledUnit(Ampere, -1));

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

    DeciAmps current() const pure
        => _current;

    void current(DeciAmps value)
    {
        if (_current == value)
            return;
        _current = value;
        mark_set!(typeof(this), "current")();

        apply_current();
        sync_status();
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
        sync_status();
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
        restart();
    }

    bool temperature_fault() const pure
        => _temperature_fault;

    bool rcm_input() const
        => gpio_input_read(RCMFAULT);

    bool rcm_fault() const pure
        => _rcm_fault;

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
        sync_status();
        return null;
    }

    bool contactor1() const pure
        => _contactor1;

    bool contactor2() const pure
        => _contactor2;

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
        sync_status();
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
        sync_status();
        return null;
    }

    void heartbeat(MonoTime)
    {
        Timer1S_singlerun();
        sync_pp_max_current();
        short next_temperature = TemperatureSensor();
        if (_temperature != next_temperature)
        {
            _temperature = next_temperature;
            mark_set!(typeof(this), "temperature")();
        }
        update_temperature_protection();
        sync_status();
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
        RCmonCtrl(ENABLE);
        if (residual_current_fault_latched(Hardware) ||
            gpio_input_read(RCMFAULT))
        {
            _rcm_fault = true;
            mark_set!(typeof(this), "rcm-fault")();
            setRCMFault(true);
            setState(STATE_ERROR);
            sync_status();
            log.error("RCM fault active during SmartEVSE startup");
            return CompletionStatus.error;
        }

        setRCMFault(false);
        sync_pp_max_current();
        if (_stopped)
        {
            _stopped = false;
            mark_set!(typeof(this), "stopped")();
        }
        setState(STATE_A);
        setAccess(1);
        arm_control_tick(getTime() + msecs(10));
        sync_status();
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
        if (_stopped)
        {
            _stopped = false;
            mark_set!(typeof(this), "stopped")();
        }
        if (_rcm_fault)
        {
            setState(STATE_ERROR);
            sync_status();
        }
        _active_hardware_owner = null;
        hardware_offline();
        _hardware_owner = _hardware_module;
        if (!_rcm_fault)
            sync_status();
        return CompletionStatus.complete;
    }

private:

    bool _stopped;
    bool _contactor1;
    bool _contactor2;
    bool _temperature_fault;
    bool _rcm_fault;
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

    void sync_pp_max_current()
    {
        MaxCapacity = ProximityPin();
        DeciAmps next = DeciAmps(cast(ushort)(MaxCapacity * 10));
        if (_pp_max_current == next)
            return;

        _pp_max_current = next;
        mark_set!(typeof(this), "pp-max-current")();
        apply_current();
    }

    void update_temperature_protection()
    {
        if (!_temperature_fault && _temperature > _max_temperature)
        {
            _temperature_fault = true;
            mark_set!(typeof(this), "temperature-fault")();
            setTemperatureFault(true);
            setStatePowerUnavailable();
            log.error("SmartEVSE over-temperature fault");
        }
        else if (_temperature_fault
              && _temperature < _max_temperature - TEMPERATURE_HYSTERESIS)
        {
            _temperature_fault = false;
            mark_set!(typeof(this), "temperature-fault")();
            setTemperatureFault(false);
            log.info("SmartEVSE temperature recovered");
        }
    }

    const(char)[] reset_fault()
    {
        if (gpio_input_read(RCMFAULT))
            return "RCM input is still active";
        if (!_rcm_fault)
            return "no RCM fault is latched";

        if (!residual_current_clear(Hardware))
            return "RCM input is still active";
        setRCMFault(false);
        _rcm_fault = false;
        mark_set!(typeof(this), "rcm-fault")();
        if (_state != SmartEVSEState.a)
        {
            _state = SmartEVSEState.a;
            mark_set!(typeof(this), "state")();
        }
        restart();
        return null;
    }

    void control_tick(MonoTime scheduled)
    {
        _tick_armed = false;
        if (!running)
            return;

        if ((residual_current_fault_latched(Hardware) ||
             gpio_input_read(RCMFAULT))
            && !_rcm_fault)
        {
            setRCMFault(true);
            _rcm_fault = true;
            mark_set!(typeof(this), "rcm-fault")();
            setState(STATE_ERROR);
            sync_status();
            log.error("RCM fault latched");
            restart();
            return;
        }

        Timer10ms_singlerun();
        sync_status();

        MonoTime next = scheduled + msecs(10);
        MonoTime now = getTime();
        if (next <= now)
            next = now + msecs(10);
        arm_control_tick(next);
    }

    void sync_status()
    {
        SmartEVSEState next_state = cast(SmartEVSEState)CurrentState();
        if (_state != next_state)
        {
            _state = next_state;
            mark_set!(typeof(this), "state")();
        }

        SmartEVSEPilot next_pilot = cast(SmartEVSEPilot)Pilot();
        if (_pilot != next_pilot)
        {
            _pilot = next_pilot;
            mark_set!(typeof(this), "pilot")();
        }

        if (_current_pwm != CurrentPWM)
        {
            _current_pwm = CurrentPWM;
            mark_set!(typeof(this), "pwm")();
        }
        DeciAmps next_effective_current = DeciAmps(GetCurrent());
        if (_effective_current != next_effective_current)
        {
            _effective_current = next_effective_current;
            mark_set!(typeof(this), "effective-current")();
        }
        if (_pilot_min_mv != PilotMinMV)
        {
            _pilot_min_mv = PilotMinMV;
            mark_set!(typeof(this), "pilot-min-mv")();
        }
        if (_pilot_max_mv != PilotMaxMV)
        {
            _pilot_max_mv = PilotMaxMV;
            mark_set!(typeof(this), "pilot-max-mv")();
        }
        if (_pp_mv != PPVoltageMV)
        {
            _pp_mv = PPVoltageMV;
            mark_set!(typeof(this), "pp-mv")();
        }
        if (_temperature_mv != TemperatureVoltageMV)
        {
            _temperature_mv = TemperatureVoltageMV;
            mark_set!(typeof(this), "temperature-mv")();
        }
        if (_activation_wait != ActivationMode)
        {
            _activation_wait = ActivationMode;
            mark_set!(typeof(this), "activation-wait")();
        }
        if (_activation_pulse != ActivationTimer)
        {
            _activation_pulse = ActivationTimer;
            mark_set!(typeof(this), "activation-pulse")();
        }
        if (_contactor1 != Contactor1)
        {
            _contactor1 = Contactor1;
            mark_set!(typeof(this), "contactor1")();
        }
        if (_contactor2 != Contactor2)
        {
            _contactor2 = Contactor2;
            mark_set!(typeof(this), "contactor2")();
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
        g_app.console.register_command!cmd_start(
            "/driver/boards/smartevse", this, "start");
        g_app.console.register_command!cmd_stop(
            "/driver/boards/smartevse", this, "stop");

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

__gshared Object _hardware_owner;
__gshared SmartEVSEModule _hardware_module;
__gshared SmartEVSE _active_hardware_owner;
__gshared bool _hardware_ready;
