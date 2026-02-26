module protocol.esphome.sampler;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.temp : tconcat;
import urt.si.unit;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.variant;

import manager.base;
import manager.component;
import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;

import protocol.esphome;
import protocol.esphome.client;
import protocol.esphome.protobuf;

import router.iface.mac;

//version = DebugESPHomeSampler;

nothrow @nogc:


class ESPHomeSampler : Sampler
{
    nothrow @nogc:

    this(Device device, ESPHomeClient client)
    {
        _device = device;
        _client = client;
        _client.subscribe(&client_state_handler);
        _client.subscribe(&message_handler);
    }

    final override void update()
    {
        if (_client.detached)
        {
            if (!_client.try_reattach())
                return;
        }
        if (!_client.running)
            return;

        if (_init_state == 0)
        {
            _client.send_message(DeviceInfoRequest());
            _init_state = 1;
        }

        // TODO: propagate any changes...
    }

    final override void remove_element(Element* element)
    {
        // TODO...
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

    Device _device;
    ObjectRef!ESPHomeClient _client;

    Map!(uint, SampleElement) _elements;

    ubyte _init_state = 0;

    void client_state_handler(BaseObject object, StateSignal signal)
    {
        if (signal == StateSignal.online)
        {
            if (_init_state == 2)
            {
                _client.send_message(SubscribeStatesRequest());
                _init_state = 3;
            }
        }
        else if (signal == StateSignal.offline)
        {
            if (_init_state == 3)
                _init_state = 2;
        }
        else if (signal == StateSignal.destroyed)
        {
            _client.unsubscribe(&client_state_handler);
            _client = null;
            _init_state = 0;
        }
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
                    _device.name = res.friendly_name;
                else
                    _device.name = res.name;

                Element* e = _device.find_or_create_element("info.name");
                if (res.friendly_name)
                    e.value = res.friendly_name.move;
                else
                    e.value = res.name.move;
                e = _device.find_or_create_element("info.esphome_ver");
                e.value = res.esphome_version.move;
                e = _device.find_or_create_element("info.compilation_time");
                SysTime comp_time;
                ptrdiff_t taken = comp_time.fromString(res.compilation_time[]);
                if (taken == res.compilation_time.length)
                    e.value = comp_time;
                if (res.manufacturer)
                {
                    e = _device.find_or_create_element("info.manufacturer_name");
                    e.value = res.manufacturer.move;
                }
                if (res.model)
                {
                    e = _device.find_or_create_element("info.model_id");
                    e.value = res.model.move;
                }
                if (res.friendly_name)
                {
                    e = _device.find_or_create_element("info.model_name");
                    e.value = res.friendly_name.move;
                }

                // do we know if it's wifi or not?
                e = _device.find_or_create_element("status.network.mode");
                e.value = StringLit!"wifi";

                if (res.webserver_port)
                {
                    e = _device.find_or_create_element("status.network.webserver_port");
                    e.value = res.webserver_port;
                }
                if (res.mac_address)
                {
                    e = _device.find_or_create_element("status.network.wifi.mac_address");
                    MACAddress addr;
                    taken = addr.fromString(res.mac_address[]);
                    if (taken == res.mac_address.length)
                        e.value = addr;
                }
                if (res.bluetooth_mac_address)
                {
                    e = _device.find_or_create_element("status.network.bluetooth.mac_address");
                    e.value = MACAddress().fromString(res.bluetooth_mac_address[]);
                }

                Component c = _device.find_component("info");
                c.template_ = StringLit!"DeviceInfo";
                c = _device.find_component("status");
                if (c)
                    c.template_ = StringLit!"DeviceStatus";
                c = _device.find_component("status.network");
                if (c)
                    c.template_ = StringLit!"DeviceStatus";
                c = _device.find_component("status.network.wifi");
                if (c)
                    c.template_ = StringLit!"Wifi";
                c = _device.find_component("status.network.bluetooth");
                if (c)
                    c.template_ = StringLit!"Bluetooth";

                _client.send_message(ListEntitiesRequest());
                _init_state = 2;
                break;

            case ListEntitiesDoneResponse.id:
                // subscribe for updates
                _client.send_message(SubscribeStatesRequest());
                _init_state = 3;
                break;

            case ListEntitiesBinarySensorResponse.id:
                ListEntitiesBinarySensorResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has BinarySensor: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesCoverResponse.id:
                ListEntitiesCoverResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Cover: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesFanResponse.id:
                ListEntitiesFanResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Fan: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesLightResponse.id:
                ListEntitiesLightResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Light: ", res.object_id, " (", res.device_id, ")");
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

                Element* e = _device.find_or_create_element(tconcat("sensors.", id));
                e.name = res.name.move;

                // record the element...
                SampleElement* el = _elements.insert(res.key, SampleElement(key: res.key, element: e));
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
                writeDebug(_client.name, " has Switch: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTextSensorResponse.id:
                ListEntitiesTextSensorResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has TextSensor: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesServicesResponse.id:
                ListEntitiesServicesResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Services: ", res.name);
                break;

            case ListEntitiesCameraResponse.id:
                ListEntitiesCameraResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Camera: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesClimateResponse.id:
                ListEntitiesClimateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Climate: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesWaterHeaterResponse.id:
                ListEntitiesWaterHeaterResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has WaterHeater: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesNumberResponse.id:
                ListEntitiesNumberResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Number: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesSelectResponse.id:
                ListEntitiesSelectResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Select: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesSirenResponse.id:
                ListEntitiesSirenResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Siren: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesLockResponse.id:
                ListEntitiesLockResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Lock: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesButtonResponse.id:
                ListEntitiesButtonResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Button: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesMediaPlayerResponse.id:
                ListEntitiesMediaPlayerResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has MediaPlayer: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesAlarmControlPanelResponse.id:
                ListEntitiesAlarmControlPanelResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has AlarmControlPanel: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTextResponse.id:
                ListEntitiesTextResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Text: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesDateResponse.id:
                ListEntitiesDateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Date: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesTimeResponse.id:
                ListEntitiesTimeResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Time: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesEventResponse.id:
                ListEntitiesEventResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Event: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesValveResponse.id:
                ListEntitiesValveResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Valve: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesDateTimeResponse.id:
                ListEntitiesDateTimeResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has DateTime: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesUpdateResponse.id:
                ListEntitiesUpdateResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Update: ", res.object_id, " (", res.device_id, ")");
                break;

            case ListEntitiesInfraredResponse.id:
                ListEntitiesInfraredResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");
                writeDebug(_client.name, " has Infrared: ", res.object_id, " (", res.device_id, ")");
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
                    version (DebugESPHomeSampler)
                        writeDebug("esphome - sample: ", el.element.id, " = ", el.element.value);
                }
                break;

            default:
                break;
        }
    }
}
