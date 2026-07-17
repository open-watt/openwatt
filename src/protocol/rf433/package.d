module protocol.rf433;

// DESIGN SKETCH (2026-07-16) - not yet buildable. This binds a captured RF remote (a profile)
// to a STATEFUL device we both drive and observe. Missing pieces:
//   1. Profile-parser support for the `codes:`/`ook:` directives (profile.d).
//   2. A signal-GENERATOR capability on GpioBinding (TX mirror of its edge sampler; asserts a
//      timed pulse train on tx-line; pigpio DMA waves interim on the Pi).
//   3. An OOK decoder over the radio's RX edge series (or consume rtl_433) so we can FOLLOW the
//      physical remote and keep our state model synced.
//   4. "Commands" - mapping a state-element write to the code(s) to send, including the toggle
//      state-machine (light/direction). Not expressible in profiles yet (ancient TODO), so it
//      lives here as model-specific logic for now.
//
// Why state matters: we can't read the fan directly. Our elements are an INFERRED model kept
// current by optimistic-update-on-send and by decoding the remote off the air. Toggles are the
// crux: to command "light off" we must know whether it's on, else we toggle the wrong way. That
// is exactly why the RX/decode side is load-bearing, not optional.
//
// Radio is NOT a new object: reference the existing GpioBinding (a signal sampler/generator,
// e.g. rx433 with tx-line=17). See conf/rf_profiles/brilliant_22034.conf.

import urt.array;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.plugin;
import manager.profile;

import protocol.gpio : GpioBinding;

nothrow @nogc:


struct OokTiming
{
    uint short_us = 250;
    uint long_us = 740;
    uint sync_us = 8000;
    bool bit1_short = true;
}


class RF433Binding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("radio", radio),
                                 Prop!("profile", profile),
                                 Prop!("model", model),
                                 Prop!("repeat", repeat),
                                 Prop!("spacing", spacing));
nothrow @nogc:

    enum type_name = "rf433-binding";
    enum path = "/binding/rf433";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!RF433Binding, id, flags);
    }

    final inout(GpioBinding) radio() inout pure => _radio.get;
    final void radio(GpioBinding value) { if (_radio.get is value) return; _radio = value; mark_set!(typeof(this), "radio")(); restart(); }

    final ref const(String) profile() const pure => _profile_name;
    final void profile(String value) { if (value == _profile_name) return; _profile_name = value.move; mark_set!(typeof(this), "profile")(); restart(); }

    final ref const(String) model() const pure => _model_name;
    final void model(String value) { if (value == _model_name) return; _model_name = value.move; mark_set!(typeof(this), "model")(); restart(); }

    final uint repeat() const pure => _repeat;               // 0 => profile default
    final void repeat(uint value) { _repeat = value; mark_set!(typeof(this), "repeat")(); }

    final Duration spacing() const pure => _spacing;         // Duration.init => profile default
    final void spacing(Duration value) { _spacing = value; mark_set!(typeof(this), "spacing")(); }

    final override bool validate() const pure
        => _radio.get !is null && !_profile_name.empty && !_device.empty;

protected:
    final override const(char)[] profile_dir() const pure => "conf/rf_profiles/";
    final override const(char)[] profile_name() const pure => _profile_name[];
    final override const(char)[] model_name() const pure => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        // Bind the state elements (fan.speed, fan.direction, fan.timer, light.on). Writable ones
        // subscribe so a write drives the radio (TX). All are updated by the RX decoder below.
        if (e.access & Access.write)
            e.add_subscriber(&on_element_change);
        // TODO: remember which element is which (speed/direction/timer/light) for the mapping.
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;
        // TODO: subscribe to the radio's decoded RF packets (its RX edge series + an OOK decoder,
        //       or an rtl_433 feed) so the physical remote keeps our state synced:
        //   _radio.subscribe_decoded(&on_rx_code);
        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        // TODO: _radio.unsubscribe_decoded(&on_rx_code);
        foreach (ref b; _bound)
            if (b.element)
                b.element.remove_subscriber(&on_element_change);
        _bound.clear();
        return super.shutdown();
    }

private:
    ObjectRef!GpioBinding _radio;
    String _profile_name;
    String _model_name;
    uint _repeat;
    Duration _spacing;

    struct BoundElement { Element* element; ubyte kind; }   // speed / direction / timer / light
    Array!BoundElement _bound;

    // TX: someone wrote a state element. Work out the command to reach that state and send it.
    // Absolute controls (speed) map value->code directly. TOGGLES (light.on, direction) send a
    // press ONLY if the current (inferred) state differs from the requested one - hence we must
    // trust our state model, which is why RX sync matters.
    void on_element_change(Element* e, ref const Variant val, SysTime, Subscriber who)
    {
        GpioBinding r = _radio.get;
        if (!r || who is cast(Subscriber)this)   // ignore our own RX-driven state updates
            return;
        // TODO (model-specific "command" logic, the unsolved bit):
        //   speed:     code = codes["speed"~val] (or fan_off);           send
        //   direction: if val != current: code = codes["reverse"];       send
        //   light.on:  if val != current: code = codes["light"];         send
        //   build OOK pulse train (timing from profile, repeat/spacing overrides) -> r.transmit_ook(...)
    }

    // RX: the physical remote (or our own echo) was decoded. Update the inferred state so the
    // model tracks reality. Speed codes set speed; reverse toggles direction; light toggles on.
    void on_rx_code(ulong code, ubyte nbits)
    {
        // TODO: split code -> button nibble -> function; update the matching element with
        //       who=this so on_element_change ignores it (no re-transmit). Toggle buttons flip
        //       the tracked state; absolute buttons set it. Also stamp status.last_command.
    }
}


class RF433Module : Module
{
    mixin DeclareModule!"protocol.rf433";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!RF433Binding();
    }
}
