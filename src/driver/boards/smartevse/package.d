// SmartEVSE board integration.
//
// The SmartEVSE owns hardware lifetime and application-thread scheduling.
// The upstream-shaped EVSE implementation remains in evse.d.
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
import manager.plugin : DeclareModule, Module;

public import driver.boards.smartevse.evse;

nothrow @nogc:


alias DeciAmps = Quantity!(ushort, ScaledUnit(Ampere, -1));

enum SmartEVSEState : ubyte
{
    a = STATE_A,
    b = STATE_B,
    c = STATE_C,
    b1 = STATE_B1,
    c1 = STATE_C1,
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

        if (running)
        {
            setAccess(value ? 1 : 0);
            sync_status();
        }
    }

    DeciAmps current() const pure
        => _current;

    void current(DeciAmps value)
    {
        if (_current == value)
            return;
        _current = value;
        mark_set!(typeof(this), "current")();

        ChargeCurrent = value.value;
        if (running && _enabled && (CurrentState() == STATE_B || CurrentState() == STATE_C))
            SetCurrent(ChargeCurrent);
        sync_status();
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
        if (!running || !_enabled || _rcm_fault)
            return false;
        setAccess(1);
        return true;
    }

    void stop_charging()
    {
        setStatePowerUnavailable();
        sync_status();
    }

    void heartbeat(MonoTime)
    {
        Timer1S_singlerun();
        short next_temperature = TemperatureSensor();
        if (_temperature != next_temperature)
        {
            _temperature = next_temperature;
            mark_set!(typeof(this), "temperature")();
        }
        sync_status();
    }

protected:

    override bool validate() const pure
        => _current.value >= MIN_CURRENT * 10 && _current.value <= MAX_CURRENT;

    override CompletionStatus startup()
    {
        if (_hardware_owner !is null)
        {
            log.error("SmartEVSE hardware is already owned by another object");
            return CompletionStatus.error;
        }

        _hardware_owner = this;
        if (setup(&hardware_complete) != 0)
        {
            hardware_shutdown();
            _hardware_owner = null;
            log.error("could not initialise SmartEVSE hardware");
            return CompletionStatus.error;
        }

        ChargeCurrent = _current.value;
        setState(STATE_A);
        RCmonCtrl(ENABLE);
        setAccess(_enabled ? 1 : 0);
        arm_control_tick(getTime() + msecs(10));
        sync_status();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_tick_armed)
        {
            g_app.cancel(&control_tick);
            _tick_armed = false;
        }

        setAccess(0);
        setState(STATE_A);
        RCmonCtrl(DISABLE);
        hardware_shutdown();
        _hardware_owner = null;
        sync_status();
        return CompletionStatus.complete;
    }

private:

    bool _enabled;
    bool _contactor1;
    bool _contactor2;
    bool _rcm_fault;
    bool _tick_armed;
    DeciAmps _current = DeciAmps(MIN_CURRENT * 10);
    ubyte _cable_limit = 13;
    short _temperature;
    uint _current_pwm = 1024;
    SmartEVSEState _state = SmartEVSEState.a;
    SmartEVSEPilot _pilot = SmartEVSEPilot.invalid;

    void arm_control_tick(MonoTime when)
    {
        g_app.schedule(when, &control_tick);
        _tick_armed = true;
    }

    void control_tick(MonoTime scheduled)
    {
        _tick_armed = false;
        if (!running)
            return;

        bool fault = gpio_input_read(RCMFAULT);
        setRCMFault(fault);
        if (_rcm_fault != fault)
        {
            _rcm_fault = fault;
            mark_set!(typeof(this), "rcm-fault")();
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
        if (_cable_limit != MaxCapacity)
        {
            _cable_limit = MaxCapacity;
            mark_set!(typeof(this), "cable-limit")();
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

__gshared SmartEVSE _hardware_owner;

extern(C) bool hardware_complete(ushort cp, ushort pp, ushort temperature)
{
    if (_hardware_owner is null)
        return false;
    return ADC1_2_IRQHandler(cp, pp, temperature);
}
