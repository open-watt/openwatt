// SmartEVSE v3 control-pilot and power stage foundation.
//
// The extern(C) control routines at the bottom retain the upstream names,
// layout and comments so they can be audited against SmartEVSE-3.5. Derived
// from the MIT-licensed SmartEVSE v3 firmware at revision
// 5891a7716b8ecf222da9c4e6e58a0aa766c1a40f:
// SmartEVSE-3/src/main.cpp (SetCPDuty, SetCurrent, setPilot, setState, Pilot)
// SmartEVSE-3/src/esp32.cpp (ProximityPin and ESP32 pin/PWM setup).
module driver.boards.smartevse;

version (SmartEVSE):

import urt.meta : AliasSeq;

import manager : g_app;
import manager.base : ActiveObject, CompletionStatus, ObjectFlags, Prop;
import manager.collection : CID, Collection, CollectionType, collection_type_info;
import manager.plugin : DeclareModule, Module;

import urt.driver.gpio;

nothrow @nogc:


enum SmartEVSEState : ubyte
{
    a = 0,
    b = 1,
    c = 2,
    b1 = 9,
    c1 = 10,
}

enum SmartEVSEPilot : ubyte
{
    invalid = 0,
    diode = 1,
    v3 = 3,
    v6 = 6,
    v9 = 9,
    v12 = 12,
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
            ChargeCurrent = _current;
            SetCurrent(ChargeCurrent);
            setState(STATE_B);
        }
        else
            stop_charging();
        sync_status();
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

        ChargeCurrent = value;
        if (running && _enabled && (CurrentState() == STATE_B || CurrentState() == STATE_C))
        {
            SetCurrent(ChargeCurrent);
            sync_status();
        }
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

    bool begin_charging()
    {
        if (!running || !_enabled || _rcm_fault || _pilot != SmartEVSEPilot.v6)
            return false;
        SetCurrent(ChargeCurrent);
        setState(STATE_C);
        sync_status();
        return true;
    }

    void stop_charging()
    {
        // C1 withdraws PWM first. Until the complete upstream timer path is
        // present, open both contactors immediately and continue to B1.
        setState(STATE_C1);
        contactor1_off();
        contactor2_off();
        setState(STATE_B1);
        sync_status();
    }

    // The capture bridge supplies calibrated millivolts sampled 50 us after
    // the rising edge of the control pilot.
    void on_cp_sample(ushort millivolts)
    {
        ADCsamples[ADCsampleIndex] = millivolts;
        if (++ADCsampleIndex == ADCsamples.length)
            ADCsampleIndex = 0;

        SmartEVSEPilot next = cast(SmartEVSEPilot)Pilot();
        if (_pilot != next)
        {
            _pilot = next;
            mark_set!(typeof(this), "pilot")();
        }

        if (CurrentState() == STATE_C && next != SmartEVSEPilot.v6)
            stop_charging();
    }

    void on_pp_sample(ushort millivolts)
    {
        PPVoltage = millivolts;
        ubyte next = ProximityPin();
        if (_cable_limit != next)
        {
            _cable_limit = next;
            mark_set!(typeof(this), "cable-limit")();
        }
    }

protected:

    override bool validate() const pure
        => _current >= MIN_CURRENT * 10 && _current <= MAX_CURRENT;

    override CompletionStatus startup()
    {
        if (!platform_init())
        {
            log.error("could not initialise SmartEVSE control-pilot PWM");
            return CompletionStatus.error;
        }

        ChargeCurrent = _current;
        setState(STATE_A);
        if (_enabled)
        {
            SetCurrent(ChargeCurrent);
            setState(STATE_B);
        }
        sync_status();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        setState(STATE_A);
        sync_status();
        return CompletionStatus.complete;
    }

    override void update()
    {
        bool fault = gpio_input_read(PIN_RCM_FAULT);
        if (_rcm_fault != fault)
        {
            _rcm_fault = fault;
            mark_set!(typeof(this), "rcm-fault")();
        }
        if (fault && CurrentState() == STATE_C)
            stop_charging();
        sync_status();
    }

private:

    bool _enabled;
    bool _contactor1;
    bool _contactor2;
    bool _rcm_fault;
    ushort _current = MIN_CURRENT * 10;
    ubyte _cable_limit = 13;
    short _temperature;
    uint _current_pwm = 1024;
    SmartEVSEState _state = SmartEVSEState.a;
    SmartEVSEPilot _pilot = SmartEVSEPilot.invalid;

    void sync_status()
    {
        SmartEVSEState next_state = cast(SmartEVSEState)CurrentState();
        if (_state != next_state)
        {
            _state = next_state;
            mark_set!(typeof(this), "state")();
        }
        if (_current_pwm != CurrentPWM)
        {
            _current_pwm = CurrentPWM;
            mark_set!(typeof(this), "pwm")();
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
        g_app.console.register_collection!SmartEVSE();
    }

    override void update()
    {
        Collection!SmartEVSE().update_all();
    }
}


private:

// SmartEVSE C-port. Keep this section shaped like the pinned upstream source;
// hardware API substitutions and D grammar are the intended differences.
extern(C):

enum ubyte STATE_A = 0;
enum ubyte STATE_B = 1;
enum ubyte STATE_C = 2;
enum ubyte STATE_B1 = 9;
enum ubyte STATE_C1 = 10;

enum ubyte PILOT_12V = 12;
enum ubyte PILOT_9V = 9;
enum ubyte PILOT_6V = 6;
enum ubyte PILOT_3V = 3;
enum ubyte PILOT_DIODE = 1;
enum ubyte PILOT_NOK = 0;
enum ubyte PILOT_SHORT = 255;

enum ushort MIN_CURRENT = 6;
enum ushort MAX_CURRENT = 800;

enum uint PIN_RCM_FAULT = 13;
enum uint PIN_SSR = 32;
enum uint PIN_SSR2 = 27;
enum uint PIN_CP_OUT = 19;
enum uint PIN_CPOFF = 15;

__gshared ubyte State = STATE_A;
__gshared ushort ChargeCurrent = MIN_CURRENT * 10;
__gshared uint CurrentPWM = 1024;
__gshared bool Contactor1;
__gshared bool Contactor2;
__gshared ushort[25] ADCsamples;
__gshared ubyte ADCsampleIndex;
__gshared uint PPVoltage;

int ow_smartevse_pwm_init(int pin);
void ow_smartevse_pwm_set(uint duty);

ubyte CurrentState()
{
    return State;
}

bool platform_init()
{
    gpio_output_init(PIN_SSR, false);
    gpio_output_init(PIN_SSR2, false);
    gpio_output_init(PIN_CPOFF, true);
    gpio_input_init(PIN_RCM_FAULT, Pull.up);
    return ow_smartevse_pwm_init(cast(int)PIN_CP_OUT) == 0;
}

void contactor1_on()
{
    gpio_output_set(PIN_SSR, true);
    Contactor1 = true;
}

void contactor1_off()
{
    gpio_output_set(PIN_SSR, false);
    Contactor1 = false;
}

void contactor2_on()
{
    gpio_output_set(PIN_SSR2, true);
    Contactor2 = true;
}

void contactor2_off()
{
    gpio_output_set(PIN_SSR2, false);
    Contactor2 = false;
}

// Write duty cycle to pin
// Value in range 0 (0% duty) to 1024 (100% duty) for ESP32
void SetCPDuty(uint DutyCycle)
{
    ow_smartevse_pwm_set(DutyCycle);                                        // update PWM signal
    CurrentPWM = DutyCycle;
}

// Set Charge Current
// Current in Amps * 10 (160 = 16A)
void SetCurrent(ushort current)
{
    uint DutyCycle;

    if ((current >= (MIN_CURRENT * 10)) && (current <= 510))
        DutyCycle = cast(uint)(current / 0.6);
                                                                            // calculate DutyCycle from current
    else if ((current > 510) && (current <= 800))
        DutyCycle = cast(uint)((current / 2.5) + 640);
    else
        DutyCycle = 100;                                                    // invalid, use 6A
    DutyCycle = DutyCycle * 1024 / 1000;                                    // conversion to 1024 = 100%
    SetCPDuty(DutyCycle);
}

// this replaces old CP_OFF and CP_ON and PILOT_CONNECTED and
// PILOT_DISCONNECTED macros
// setPilot(true) switches the PILOT ON (CONNECT), setPilot(false) switches it OFF
void setPilot(bool On)
{
    if (On)
    {
        gpio_output_set(PIN_CPOFF, false);
    }
    else
        gpio_output_set(PIN_CPOFF, true);
}

void setState(ubyte NewState)
{
    switch (NewState)
    {
        case STATE_B1:
            setPilot(false);
            goto case STATE_A;

        case STATE_A:
            contactor1_off();
            contactor2_off();
            SetCPDuty(1024);                                                // PWM off, channel 0, duty cycle 100%
            if (NewState == STATE_A)
                setPilot(true);
            break;

        case STATE_B:
            setPilot(true);
            contactor1_off();
            contactor2_off();
            break;

        case STATE_C:
            contactor1_on();
            contactor2_on();
            break;

        case STATE_C1:
            SetCPDuty(1024);                                                // PWM off, channel 0, duty cycle 100%
            break;

        default:
            break;
    }

    State = NewState;
}

// Determine the state of the Pilot signal
ubyte Pilot()
{
    uint sample, Min = 3300, Max = 0;
    uint voltage;
    ubyte n;

    // calculate Min/Max of last 25 CP measurements
    for (n = 0; n < 25; ++n)
    {
        sample = ADCsamples[n];
        voltage = sample;                                                   // capture bridge supplies calibrated mV
        if (voltage < Min)
            Min = voltage;                                                  // store lowest value
        if (voltage > Max)
            Max = voltage;                                                  // store highest value
    }

    // test Min/Max against fixed levels
    if (Min >= 3055)
        return PILOT_12V;                                                   // Pilot at 12V (min 11.0V)
    if ((Min >= 2735) && (Max < 3055))
        return PILOT_9V;                                                    // Pilot at 9V
    if ((Min >= 2400) && (Max < 2735))
        return PILOT_6V;                                                    // Pilot at 6V
    if ((Min >= 2000) && (Max < 2400))
        return PILOT_3V;                                                    // Pilot at 3V
    if ((Min >= 1600) && (Max < 2000))
        return PILOT_SHORT;                                                 // Pilot short or open
    if ((Min > 100) && (Max < 300))
        return PILOT_DIODE;                                                 // Diode Check OK
    return PILOT_NOK;                                                       // Pilot NOT ok
}

// Sample the Proximity Pin, and determine the maximum current the cable can handle.
ubyte ProximityPin()
{
    uint voltage = PPVoltage;
    ubyte MaxCap = 13;                                                      // No resistor, Max cable current = 13A

    if ((voltage > 1200) && (voltage < 1400))
        MaxCap = 16;                                                        // Max cable current = 16A 680R
    if ((voltage > 500) && (voltage < 700))
        MaxCap = 32;                                                        // Max cable current = 32A 220R
    if ((voltage > 200) && (voltage < 400))
        MaxCap = 63;                                                        // Max cable current = 63A 100R

    return MaxCap;
}
