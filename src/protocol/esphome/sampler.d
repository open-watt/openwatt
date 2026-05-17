module protocol.esphome.sampler;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.si.unit;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;

import protocol.esphome;
import protocol.esphome.client;

import tools.protobuf;

import router.iface.mac;

//version = DebugESPHomeBinding;

nothrow @nogc:


class ESPHomeBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:

    enum type_name = "esphome-binding";
    enum path = "/binding/esphome";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ESPHomeBinding, id, flags);
    }

    final inout(ESPHomeClient) client() inout pure
        => _client.get;
    final void client(ESPHomeClient value)
    {
        if (_client.get is value)
            return;
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
            _client.unsubscribe(&message_handler);
            _subscribed = false;
        }
        _client = value;
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        restart();
    }

    final override bool validate() const pure
    {
        return _client.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        ESPHomeClient c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        c.subscribe(&state_change);
        c.subscribe(&message_handler);
        _subscribed = true;

        c.send_message(DeviceInfoRequest());
        _init_state = 1;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
            _client.unsubscribe(&message_handler);
            _subscribed = false;
        }
        _elements.clear();
        _dev = null;
        _init_state = 0;
        return super.shutdown();
    }

    final override void update()
    {
    }

protected:
    final override const(char)[] profile_dir() const pure
        => "conf/ha_profiles/";
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override bool materialise()
    {
        if (!super.materialise())
            return false;
        if (!_dev)
        {
            Device* p = _device[] in g_app.devices;
            if (!p)
                return false;
            _dev = *p;
        }
        return true;
    }

    final override void add_handler(Device, Element* e, ref const ElementDesc, ubyte)
    {
        log.warning("element-map is not supported in ESPHome profiles (sensors are discovered at runtime); ignoring '", e.id, '\'');
    }

private:
    struct SampleElement
    {
        uint key;
        Element* element;
        ScaledUnit unit;
        float pre_scale = 1;
        String custom_unit;
    }

    ObjectRef!ESPHomeClient _client;
    String _profile_name;
    String _model_name;

    Device _dev;
    bool _subscribed;
    ubyte _init_state;

    Map!(uint, SampleElement) _elements;

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void message_handler(uint msg_type, const(ubyte)[] frame)
    {
        switch (msg_type)
        {
            case DeviceInfoResponse.id:
                DeviceInfoResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");

                // TODO: id should be `res.name`...

                if (res.friendly_name)
                    _dev.name = res.friendly_name;
                else
                    _dev.name = res.name;

                Element* e = _dev.find_or_create_element("info.name");
                if (res.friendly_name)
                    e.value = res.friendly_name.move;
                else
                    e.value = res.name.move;
                e = _dev.find_or_create_element("info.esphome_ver");
                e.value = res.esphome_version.move;
                e = _dev.find_or_create_element("info.compilation_time");
                SysTime comp_time;
                ptrdiff_t taken = comp_time.fromString(res.compilation_time[]);
                if (taken == res.compilation_time.length)
                    e.value = comp_time;
                if (res.manufacturer)
                {
                    e = _dev.find_or_create_element("info.manufacturer_name");
                    e.value = res.manufacturer.move;
                }
                if (res.model)
                {
                    e = _dev.find_or_create_element("info.model_id");
                    e.value = res.model.move;
                }
                if (res.friendly_name)
                {
                    e = _dev.find_or_create_element("info.model_name");
                    e.value = res.friendly_name.move;
                }

                // do we know if it's wifi or not?
                e = _dev.find_or_create_element("status.network.mode");
                e.value = StringLit!"wifi";

                if (res.webserver_port)
                {
                    e = _dev.find_or_create_element("status.network.webserver_port");
                    e.value = res.webserver_port;
                }
                if (res.mac_address)
                {
                    e = _dev.find_or_create_element("status.network.wifi.mac_address");
                    MACAddress addr;
                    taken = addr.fromString(res.mac_address[]);
                    if (taken == res.mac_address.length)
                        e.value = addr;
                }
                if (res.bluetooth_mac_address)
                {
                    e = _dev.find_or_create_element("status.network.bluetooth.mac_address");
                    e.value = MACAddress().fromString(res.bluetooth_mac_address[]);
                }

                Component c = _dev.find_component("info");
                c.template_ = StringLit!"DeviceInfo";
                c = _dev.find_component("status");
                if (c)
                    c.template_ = StringLit!"DeviceStatus";
                c = _dev.find_component("status.network");
                if (c)
                    c.template_ = StringLit!"DeviceStatus";
                c = _dev.find_component("status.network.wifi");
                if (c)
                    c.template_ = StringLit!"Wifi";
                c = _dev.find_component("status.network.bluetooth");
                if (c)
                    c.template_ = StringLit!"Bluetooth";

                _client.send_message(ListEntitiesRequest());
                _init_state = 2;
                break;

            case ListEntitiesDoneResponse.id:
                _client.send_message(SubscribeStatesRequest());
                _init_state = 3;
                break;

            case ListEntitiesBinarySensorResponse.id:
                ListEntitiesBinarySensorResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has BinarySensor: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesCoverResponse.id:
                ListEntitiesCoverResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Cover: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesFanResponse.id:
                ListEntitiesFanResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Fan: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesLightResponse.id:
                ListEntitiesLightResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Light: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesSensorResponse.id:
                ListEntitiesSensorResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");

                char[256] tmp = void;
                if (res.name.length > tmp.length)
                    break; // name too long!
                foreach (i, char c; res.name[])
                {
                    if (c.is_alpha)
                        c |= 0x20;
                    if (c == ' ')
                        c = '_';
                    tmp[i] = c;
                }
                const(char)[] id = tmp[0 .. res.name.length];

                Element* e = _dev.find_or_create_element(tconcat("sensors.", id));
                e.name = res.name.move;

                SampleElement entry;
                entry.key = res.key;
                entry.element = e;
                SampleElement* el = _elements.insert(res.key, entry);
                if (!el)
                {
                    // TODO: what went wrong?!
                    break;
                }

                // TODO: assert device_class (ie: "voltage") is matching to the units and/or is respected?

                if (res.unit_of_measurement)
                {
                    ScaledUnit unit;
                    float pre_scale = 1;
                    ptrdiff_t taken = unit.parse_unit(res.unit_of_measurement[], pre_scale, false);
                    if (taken == res.unit_of_measurement.length)
                    {
                        el.unit = unit;
                        el.pre_scale = pre_scale;
                    }
                    else
                        el.custom_unit = res.unit_of_measurement.move;
                }
                break;

            case ListEntitiesSwitchResponse.id:
                ListEntitiesSwitchResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Switch: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTextSensorResponse.id:
                ListEntitiesTextSensorResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has TextSensor: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesServicesResponse.id:
                ListEntitiesServicesResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Services: ", res.name);
                break;

            case ListEntitiesCameraResponse.id:
                ListEntitiesCameraResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Camera: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesClimateResponse.id:
                ListEntitiesClimateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Climate: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesWaterHeaterResponse.id:
                ListEntitiesWaterHeaterResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has WaterHeater: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesNumberResponse.id:
                ListEntitiesNumberResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Number: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesSelectResponse.id:
                ListEntitiesSelectResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Select: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesSirenResponse.id:
                ListEntitiesSirenResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Siren: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesLockResponse.id:
                ListEntitiesLockResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Lock: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesButtonResponse.id:
                ListEntitiesButtonResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Button: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesMediaPlayerResponse.id:
                ListEntitiesMediaPlayerResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has MediaPlayer: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesAlarmControlPanelResponse.id:
                ListEntitiesAlarmControlPanelResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has AlarmControlPanel: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTextResponse.id:
                ListEntitiesTextResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Text: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesDateResponse.id:
                ListEntitiesDateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Date: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTimeResponse.id:
                ListEntitiesTimeResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Time: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesEventResponse.id:
                ListEntitiesEventResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Event: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesValveResponse.id:
                ListEntitiesValveResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Valve: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesDateTimeResponse.id:
                ListEntitiesDateTimeResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has DateTime: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesUpdateResponse.id:
                ListEntitiesUpdateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Update: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesInfraredResponse.id:
                ListEntitiesInfraredResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                log.debug_("has Infrared: ", res.object_id, " (", res.device_id, ")");
                break;

            case SensorStateResponse.id:
                SensorStateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                if (res.missing_state)
                    break;
                if (SampleElement* el = res.key in _elements)
                {
                    el.element.value = Quantity!float(res.state * el.pre_scale, el.unit);
                    version (DebugESPHomeBinding)
                        log.trace("sample: ", el.element.id, " = ", el.element.value);
                }
                break;

            default:
                break;
        }
    }
}
