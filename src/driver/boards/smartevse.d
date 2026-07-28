// SmartEVSE v3 control-pilot and power stage foundation.
//
// The private control routines retain the upstream function names and flow so
// that they can be audited against SmartEVSE-3.5. Derived from the MIT-licensed
// SmartEVSE v3 firmware, revision 5891a7716b8ecf222da9c4e6e58a0aa766c1a40f:
// SmartEVSE-3/src/main.cpp (SetCPDuty, SetCurrent, setPilot, setState, Pilot)
// SmartEVSE-3/src/esp32.cpp (ESP32 pin map and CP PWM setup).
module driver.boards.smartevse;

import urt.meta : AliasSeq;

import manager;
import manager.collection;
import manager.plugin;

version (Espressif)
    import urt.driver.gpio;
version (Espressif)
    enum has_smartevse_hw = true;
else
    enum has_smartevse_hw = false;

nothrow @nogc:


enum SmartEVSEState : ubyte
{
    a,
    b,
    c,
    b1,
    c1,
}

enum SmartEVSEPilot : ubyte
{
    invalid,
    v12 = 12,
    v9 = 9,
    v6 = 6,
    v3 = 3,
    diode = 1,
    short_ = 255,
}


class SmartEVSE : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("enabled", enabled),
                                 Prop!("current", current),
                                 Prop!("state", state, "status", "d"),
                                 Prop!("pilot", pilot, "status", "d"),
                                 Prop!("pwm", pwm, "status", "d"),
                                 Prop!("cable-limit", cable_limit, "status", "d"),
                                 Prop!("temperature", temperature, "status", "d"),
                                 Prop!("rcm-fault", rcm_fault, "status", "d"),
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

    bool enabled() const pure
        => _enabled;

    void enabled(bool value)
    {
        if (_enabled == value)
            return;
        _enabled = value;
        mark_set!(typeof(this), "enabled")();

        if (!running)
            return;
        if (value)
        {
            SetCurrent(_current);
            setState(SmartEVSEState.b);
        }
        else
            stop_charging();
    }

    // Deci-amps, matching the SmartEVSE control-pilot API: 160 means 16 A.
    ushort current() const pure
        => _current;

    void current(ushort value)
    {
        if (_current == value)
            return;
        _current = value;
        mark_set!(typeof(this), "current")();

        if (running && _enabled && (_state == SmartEVSEState.b || _state == SmartEVSEState.c))
            SetCurrent(value);
    }

    SmartEVSEState state() const pure
        => _state;

    SmartEVSEPilot pilot() const pure
        => _pilot;

    uint pwm() const pure
        => _current_pwm;

    ubyte cable_limit() const pure
        => _cable_limit;

    short temperature() const pure
        => _temperature;

    bool rcm_fault() const pure
        => _rcm_fault;

    bool contactor1() const pure
        => _contactor1;

    bool contactor2() const pure
        => _contactor2;

    // Future energy control calls this only after the pilot capture path has
    // established State C. It never closes either contactor on any other state.
    bool begin_charging()
    {
        if (!running || !_enabled || _rcm_fault || _pilot != SmartEVSEPilot.v6)
            return false;
        SetCurrent(_current);
        setState(SmartEVSEState.c);
        return true;
    }

    void stop_charging()
    {
        // The upstream C1 state first withdraws PWM so the car stops. This
        // foundation then opens contactors immediately: its timed C1 grace
        // period belongs with the future complete pilot state machine.
        setState(SmartEVSEState.c1);
        contactor1_off();
        contactor2_off();
        setState(SmartEVSEState.b1);
    }

    // Hardware capture calls this after a phase-correct CP measurement. It is
    // public for the upcoming ISR bridge and makes the classifier unit-testable.
    void on_cp_sample(ushort millivolts)
    {
        _cp_samples[_sample_index] = millivolts;
        if (++_sample_index == _cp_samples.length)
            _sample_index = 0;

        SmartEVSEPilot next = Pilot();
        if (_pilot == next)
            return;
        _pilot = next;
        mark_set!(typeof(this), "pilot")();

        if (_state == SmartEVSEState.c && next != SmartEVSEPilot.v6)
            stop_charging();
    }

protected:

    override bool validate() const pure
        => _current >= min_current && _current <= max_current;

    override CompletionStatus startup()
    {
        static if (has_smartevse_hw)
        {
            if (!platform_init())
            {
                log.error("could not initialise SmartEVSE control-pilot PWM");
                return CompletionStatus.error;
            }
            setState(SmartEVSEState.a);
            if (_enabled)
            {
                SetCurrent(_current);
                setState(SmartEVSEState.b);
            }
            return CompletionStatus.complete;
        }
        else
        {
            log.error("SmartEVSE is only supported on Espressif targets");
            return CompletionStatus.error;
        }
    }

    override CompletionStatus shutdown()
    {
        stop_charging();
        return CompletionStatus.complete;
    }

    override void update()
    {
        static if (has_smartevse_hw)
        {
            bool fault = gpio_input_read(pin_rcm_fault);
            if (_rcm_fault != fault)
            {
                _rcm_fault = fault;
                mark_set!(typeof(this), "rcm-fault")();
            }
            if (fault && _state == SmartEVSEState.c)
                stop_charging();
        }
    }

private:

    // SmartEVSE v3.0 pin map. v3.1 moves the actuator, RCM and RS485 pins;
    // that board revision selection belongs beside the ISR/ADC bridge.
    enum uint pin_rcm_fault = 13;
    enum uint pin_ssr1 = 32;
    enum uint pin_ssr2 = 27;
    enum uint pin_cp_out = 19;
    enum uint pin_cp_off = 15;

    enum ushort min_current = 60;
    enum ushort max_current = 800;
    enum uint pwm_full = 1024;

    bool _enabled;
    bool _contactor1;
    bool _contactor2;
    bool _rcm_fault;
    ushort _current = min_current;
    ubyte _cable_limit = 13;
    short _temperature;
    uint _current_pwm = pwm_full;
    ubyte _sample_index;
    SmartEVSEState _state = SmartEVSEState.a;
    SmartEVSEPilot _pilot = SmartEVSEPilot.invalid;
    ushort[25] _cp_samples;

    static if (has_smartevse_hw)
    {
        bool platform_init()
        {
            gpio_output_init(pin_ssr1, false);
            gpio_output_init(pin_ssr2, false);
            gpio_output_init(pin_cp_off, true);
            gpio_input_init(pin_rcm_fault, Pull.up);
            return ow_smartevse_pwm_init(cast(int)pin_cp_out) == 0;
        }
    }
    else
    {
        bool platform_init() => false;
    }

    // Upstream SetCPDuty. The control-pilot generator has 10-bit resolution;
    // duty=1024 represents a steady +12 V, rather than a charging PWM.
    void SetCPDuty(uint duty_cycle)
    {
        static if (has_smartevse_hw)
            ow_smartevse_pwm_set(duty_cycle);
        _current_pwm = duty_cycle;
        mark_set!(typeof(this), "pwm")();
    }

    // Upstream SetCurrent, translated without changing its arithmetic. The
    // IEC 61851 mapping switches formula at 51 A.
    void SetCurrent(ushort current)
    {
        uint duty_cycle;

        if (current >= min_current && current <= 510)
            duty_cycle = current * 10 / 6;
        else if (current > 510 && current <= max_current)
            duty_cycle = current * 2 / 5 + 640;
        else
            duty_cycle = 100;

        duty_cycle = duty_cycle * pwm_full / 1000;
        SetCPDuty(duty_cycle);
    }

    // Upstream setPilot. CP-off is active-high on the SmartEVSE hardware.
    void setPilot(bool on)
    {
        static if (has_smartevse_hw)
            gpio_output_set(pin_cp_off, !on);
    }

    // The mechanical outputs are intentionally private. Every public control
    // path goes through setState or stop_charging.
    void contactor1_on()
    {
        static if (has_smartevse_hw)
            gpio_output_set(pin_ssr1, true);
        _contactor1 = true;
        mark_set!(typeof(this), "contactor1")();
    }

    void contactor1_off()
    {
        static if (has_smartevse_hw)
            gpio_output_set(pin_ssr1, false);
        _contactor1 = false;
        mark_set!(typeof(this), "contactor1")();
    }

    void contactor2_on()
    {
        static if (has_smartevse_hw)
            gpio_output_set(pin_ssr2, true);
        _contactor2 = true;
        mark_set!(typeof(this), "contactor2")();
    }

    void contactor2_off()
    {
        static if (has_smartevse_hw)
            gpio_output_set(pin_ssr2, false);
        _contactor2 = false;
        mark_set!(typeof(this), "contactor2")();
    }

    // Faithful subset of upstream setState. It excludes UI, load balancing,
    // ISO 15118 and phase-switch policy; those decide when this primitive is
    // invoked, not how the pilot and power stage are driven.
    void setState(SmartEVSEState next)
    {
        switch (next)
        {
            case SmartEVSEState.a:
            case SmartEVSEState.b1:
                contactor1_off();
                contactor2_off();
                SetCPDuty(pwm_full);
                setPilot(next == SmartEVSEState.a);
                break;

            case SmartEVSEState.b:
                contactor1_off();
                contactor2_off();
                setPilot(true);
                SetCurrent(_current);
                break;

            case SmartEVSEState.c:
                contactor1_on();
                // SmartEVSE defaults to three-phase; phase switching remains
                // out of scope until topology owns the policy.
                contactor2_on();
                break;

            case SmartEVSEState.c1:
                SetCPDuty(pwm_full);
                break;

            default:
                assert(false, "invalid SmartEVSE state");
        }

        if (_state != next)
        {
            _state = next;
            mark_set!(typeof(this), "state")();
        }
    }

    // Upstream Pilot classification, expressed in calibrated millivolts. The
    // future capture bridge supplies samples taken 50 us after CP's rising edge.
    SmartEVSEPilot Pilot() const
    {
        ushort min = ushort.max;
        ushort max;
        foreach (sample; _cp_samples)
        {
            if (sample < min)
                min = sample;
            if (sample > max)
                max = sample;
        }

        if (min >= 3055)
            return SmartEVSEPilot.v12;
        if (min >= 2735 && max < 3055)
            return SmartEVSEPilot.v9;
        if (min >= 2400 && max < 2735)
            return SmartEVSEPilot.v6;
        if (min >= 2000 && max < 2400)
            return SmartEVSEPilot.v3;
        if (min >= 1600 && max < 2000)
            return SmartEVSEPilot.short_;
        if (min > 100 && max < 300)
            return SmartEVSEPilot.diode;
        return SmartEVSEPilot.invalid;
    }

    // Upstream ProximityPin thresholds. The physical PP ADC reader will call
    // this once the shared ESP32 ADC/timer ownership is established.
    static ubyte ProximityPin(ushort millivolts)
    {
        if (millivolts > 1200 && millivolts < 1400)
            return 16;
        if (millivolts > 500 && millivolts < 700)
            return 32;
        if (millivolts > 200 && millivolts < 400)
            return 63;
        return 13;
    }

    static uint current_pwm(ushort current)
    {
        uint duty_cycle;
        if (current >= min_current && current <= 510)
            duty_cycle = current * 10 / 6;
        else if (current > 510 && current <= max_current)
            duty_cycle = current * 2 / 5 + 640;
        else
            duty_cycle = 100;
        return duty_cycle * pwm_full / 1000;
    }

    version (Espressif) extern (C)
    {
        int ow_smartevse_pwm_init(int pin);
        void ow_smartevse_pwm_set(uint duty);
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
        g_app.console.register_collection!SmartEVSE();
    }

    override void update()
    {
        Collection!SmartEVSE().update_all();
    }
}


unittest
{
    assert(SmartEVSE.current_pwm(60) == 102);
    assert(SmartEVSE.current_pwm(160) == 272);
    assert(SmartEVSE.current_pwm(510) == 870);
    assert(SmartEVSE.current_pwm(800) == 983);
    assert(SmartEVSE.ProximityPin(1300) == 16);
    assert(SmartEVSE.ProximityPin(600) == 32);
    assert(SmartEVSE.ProximityPin(300) == 63);
}
