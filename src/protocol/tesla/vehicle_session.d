module protocol.tesla.vehicle_session;

import urt.array;
import urt.crypto.aes : aes_gcm_encrypt;
import urt.crypto.random : crypto_random_bytes;
import urt.digest.hmac;
import urt.digest.sha;
import urt.lifetime : move;
import urt.log;
import urt.result;
import urt.si;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.secret;

import protocol.ble;
import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;
import protocol.tesla.vehicle_codec;
import protocol.tesla.vehicle_crypto;
import protocol.tesla.vehicle_scanner;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import tools.protobuf;

nothrow @nogc:

enum Bar = ScaledUnit(Pascal, 5);

enum VehicleCommandKind : ubyte
{
    unknown,
    get_charge_state,
    get_climate_state,
    get_vehicle_state,
    charging_start,
    charging_stop,
    set_charging_amps,
    climate_power,
    climate_temperature,
    schedule_charging,
}

static immutable vehicle_command_names = make_table!([
    "command",
    "get-charge",
    "get-climate",
    "get-vehicle",
    "charge-start",
    "charge-stop",
    "set-amps",
    "climate",
    "set-temperature",
    "schedule-charging",
]);

class TeslaVehicleSession : ActiveObject
{
nothrow @nogc:

    enum type_name = "tesla-vehicle-session";
    enum path = "/protocol/tesla/session";
    enum collection_id = CollectionType.tesla_vehicle_session;

    enum Phase : ubyte
    {
        connecting,
        gatt_ready,
        session_info_xchg,
        awaiting_approval,
        info_xchg,
        ready,
        failed,
    }

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaVehicleSession, id, flags);
    }

    const(char)[] vin() const pure
        => name[];

    MACAddress peer() const pure
        => _peer;

    inout(BLEClient) client() inout pure
        => _client;

    Phase session_state() const pure
        => _phase;

    inout(TeslaVehicleScanner) scanner() inout pure
        => _scanner;

    bool is_ready() const pure => _phase == Phase.ready;

    bool has_charge_state() const pure => _has_charge_state;
    bool has_climate_state() const pure => _has_climate_state;
    ref const(TeslaChargeState) charge_state() const pure => _charge_state;
    ref const(TeslaClimateState) climate_state() const pure => _climate_state;

    bool refresh_charge_state()
        => send_signed_action(TeslaDomain.infotainment, build_action_get_charge_state()[], VehicleCommandKind.get_charge_state);

    bool refresh_climate_state()
        => send_signed_action(TeslaDomain.infotainment, build_action_get_climate_state()[], VehicleCommandKind.get_climate_state);

    bool refresh_vehicle_state()
        => send_signed_action(TeslaDomain.infotainment, build_action_get_vehicle_state()[], VehicleCommandKind.get_vehicle_state);

    bool charging_start()
        => send_signed_action(TeslaDomain.infotainment, build_action_charging_start_stop(true)[], VehicleCommandKind.charging_start);
    bool charging_stop()
        => send_signed_action(TeslaDomain.infotainment, build_action_charging_start_stop(false)[], VehicleCommandKind.charging_stop);

    bool set_charging_amps(int amps)
        => send_signed_action(TeslaDomain.infotainment, build_action_set_charging_amps(amps)[], VehicleCommandKind.set_charging_amps);

    bool climate_power(bool enabled)
        => send_signed_action(TeslaDomain.infotainment, build_action_climate_power(enabled)[], VehicleCommandKind.climate_power);

    bool climate_temperature(float celsius)
        => send_signed_action(TeslaDomain.infotainment, build_action_climate_temperature(celsius, celsius)[], VehicleCommandKind.climate_temperature);

    bool schedule_charging(bool enabled, TimeOfDay start)
    {
        int minutes_after_midnight = cast(int)start.hour * 60 + start.minute;
        return send_signed_action(TeslaDomain.infotainment, build_action_schedule_charging(enabled, minutes_after_midnight)[], VehicleCommandKind.schedule_charging);
    }

    MonoTime last_seen() const pure
        => _last_seen;

package:
    void attach(TeslaVehicleScanner scanner, MACAddress peer)
    {
        _scanner = scanner;
        _peer = peer;
        _last_seen = getTime();
    }

    void mark_seen(MACAddress peer)
    {
        _last_seen = getTime();
        if (_peer == peer)
            return;

        log.info("Tesla vehicle '", name[], "' changed BLE address from ", _peer, " to ", peer, ", reconnecting");
        _peer = peer;
        restart();
    }

protected:
    override bool validate() const
        => _scanner !is null && cast(bool)_peer;

    override const(char)[] status_message() const
    {
        if (_state != State.starting && _state != State.running)
            return super.status_message();

        final switch (_phase)
        {
            case Phase.connecting:
                return _client is null ? "Waiting for BLE client" : "Connecting to vehicle";
            case Phase.gatt_ready:
            case Phase.session_info_xchg:
            case Phase.info_xchg:         return "Establishing session";
            case Phase.awaiting_approval: return "Tap an enrolled key card on the console to authorise";
            case Phase.ready:
            case Phase.failed:            return super.status_message();
        }
    }

    override CompletionStatus startup()
    {
        if (_client is null)
        {
            BaseInterface iface = _scanner.iface;
            if (!iface)
                return CompletionStatus.continue_;
            _client = Collection!BLEClient().create(Collection!BLEClient().generate_name(name[]), cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("interface", iface), NamedArgument("peer", _peer));
            if (_client is null)
                return CompletionStatus.continue_;
        }

        if (!_client.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _client.subscribe(&client_state_change);
            _subscribed = true;
            _phase = Phase.connecting;
            _rx_buffer.clear();
            _counter = 0;
            _routing_seeded = false;
            _last_rx_time = getTime();
        }

        return advance();
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_vehicle_controls();
        if (_subscribed)
        {
            _client.unsubscribe(&client_state_change);
            _subscribed = false;
        }
        if (_client !is null && _rx_handle != 0)
            _client.clear_notify(_rx_handle);
        _tx_handle = 0;
        _rx_handle = 0;
        _rx_buffer.clear();
        _aes_key[] = 0;
        _vehicle_pubkey[] = 0;
        _epoch[] = 0;
        _routing_address[] = 0;
        _request_uuid[] = 0;
        _counter = 0;
        _pending_commands[] = PendingCommand.init;
        _charge_state = TeslaChargeState.init;
        _climate_state = TeslaClimateState.init;
        _has_charge_state = false;
        _has_climate_state = false;
        _cap = CapacitySamplerState.init;
        _last_poll_time = MonoTime.init;
        _last_climate_poll_time = MonoTime.init;
        _last_vehicle_poll_time = MonoTime.init;

        if (Device* vehicle = name[] in g_app.devices)
            (*vehicle).set_element("connected", false);
        _routing_seeded = false;
        _phase = Phase.connecting;
        if (_client !is null)
        {
            _client.destroy();
            _client = null;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (advance() == CompletionStatus.error)
            restart();
    }

private:
    CompletionStatus advance()
    {
        // WinRT can report a dead GATT channel as connected.
        if (getTime() - _last_rx_time > link_timeout)
        {
            version (DebugTeslaSession)
                log.trace("no vehicle traffic for ", link_timeout, ", reconnecting");
            return CompletionStatus.error;
        }

        final switch (_phase)
        {
            case Phase.connecting:
                if (!_client.discovery_complete())
                    return CompletionStatus.continue_;
                _tx_handle = _client.find_characteristic(TESLA_SERVICE_UUID, TESLA_TX_CHAR_UUID);
                _rx_handle = _client.find_characteristic(TESLA_SERVICE_UUID, TESLA_RX_CHAR_UUID);
                if (_tx_handle == 0 || _rx_handle == 0)
                {
                    log.error("Tesla GATT characteristics not found on peer ", _client.peer);
                    return CompletionStatus.error;
                }
                _client.on_notify(_rx_handle, &on_notification);
                _last_rx_time = getTime();
                version (DebugTeslaSession)
                    log.trace("GATT discovery complete, tx=", _tx_handle, " rx=", _rx_handle, ", state=gatt_ready");
                _phase = Phase.gatt_ready;
                return CompletionStatus.continue_;

            case Phase.gatt_ready:
                send_session_info_request(TeslaDomain.vehicle_security);
                version (DebugTeslaSession)
                    log.trace("sent SessionInfoRequest, state=session_info_xchg");
                _phase = Phase.session_info_xchg;
                return CompletionStatus.continue_;

            case Phase.session_info_xchg:
                if (getTime() - _last_request_time > retry_interval)
                    send_session_info_request(TeslaDomain.vehicle_security);
                return CompletionStatus.continue_;

            case Phase.awaiting_approval:
                // Avoid overlapping GATT writes while waiting for NFC approval.
                if (getTime() - _last_request_time > approval_interval)
                {
                    _last_request_time = getTime();
                    _approval_toggle = !_approval_toggle;
                    if (_approval_toggle)
                        send_add_key_request();
                    else
                        send_session_info_request(TeslaDomain.vehicle_security);
                }
                return CompletionStatus.continue_;

            case Phase.info_xchg:
                if (getTime() - _last_request_time > retry_interval)
                    send_session_info_request(TeslaDomain.infotainment);
                return CompletionStatus.continue_;

            case Phase.ready:
                subscribe_vehicle_controls();
                Duration interval = poll_interval_for_state();
                if (getTime() - _last_poll_time >= interval)
                {
                    _last_poll_time = getTime();
                    refresh_charge_state();
                }
                else if (getTime() - _last_climate_poll_time >= climate_poll_interval)
                {
                    _last_climate_poll_time = getTime();
                    refresh_climate_state();
                }
                else if (getTime() - _last_vehicle_poll_time >= vehicle_poll_interval)
                {
                    _last_vehicle_poll_time = getTime();
                    refresh_vehicle_state();
                }
                return CompletionStatus.complete;

            case Phase.failed:
                return CompletionStatus.error;
        }
    }

    enum Duration retry_interval = 5.seconds;
    enum Duration approval_interval = 2.seconds;
    enum Duration link_timeout = 45.seconds;
    enum Duration poll_charging = 2.seconds;
    enum Duration poll_idle = 30.seconds;
    enum Duration climate_poll_interval = 60.seconds;
    enum Duration vehicle_poll_interval = 60.seconds;

    TeslaVehicleScanner _scanner;
    MACAddress _peer;
    BLEClient _client;
    bool _subscribed;
    bool _controls_subscribed;
    bool _approval_toggle;
    ushort _tx_handle;
    ushort _rx_handle;
    Phase _phase = Phase.connecting;
    MonoTime _last_rx_time;
    MonoTime _last_seen;

    ubyte[16] _routing_address;
    ubyte[16] _request_uuid;
    MonoTime _last_request_time;
    MonoTime _last_poll_time;
    MonoTime _last_climate_poll_time;
    MonoTime _last_vehicle_poll_time;
    bool _routing_seeded;

    Element* _charging_enabled;
    Element* _charging_amps;
    Element* _hvac_power;
    Element* _hvac_target_temperature;

    Duration poll_interval_for_state() const pure
    {
        if (_has_charge_state && _charge_state.charging_state.present)
        {
            int state = charging_state_kind(_charge_state.charging_state.value);
            if (state == 4 || state == 5)
                return poll_charging;
        }
        return poll_idle;
    }

    void subscribe_vehicle_controls()
    {
        if (_controls_subscribed)
            return;

        Component vehicle = _scanner.component_for_vin(name[]);
        if (!vehicle)
            return;

        _charging_enabled = vehicle.find_element("charging.enabled");
        _charging_amps = vehicle.find_element("control.setpoint");
        _hvac_power = vehicle.find_element("hvac.power");
        _hvac_target_temperature = vehicle.find_element("hvac.target_temperature");

        subscribe_vehicle_control(_charging_enabled);
        subscribe_vehicle_control(_charging_amps);
        subscribe_vehicle_control(_hvac_power);
        subscribe_vehicle_control(_hvac_target_temperature);
        _controls_subscribed = true;
    }

    void unsubscribe_vehicle_controls()
    {
        if (!_controls_subscribed)
            return;

        unsubscribe_vehicle_control(_charging_enabled);
        unsubscribe_vehicle_control(_charging_amps);
        unsubscribe_vehicle_control(_hvac_power);
        unsubscribe_vehicle_control(_hvac_target_temperature);
        _charging_enabled = null;
        _charging_amps = null;
        _hvac_power = null;
        _hvac_target_temperature = null;
        _controls_subscribed = false;
    }

    void subscribe_vehicle_control(Element* element)
    {
        if (!element)
            return;
        element.access = Access.read_write;
        element.subscribe(&vehicle_control_change);
    }

    void unsubscribe_vehicle_control(Element* element)
    {
        if (element)
        {
            element.unsubscribe(&vehicle_control_change);
            element.access = Access.read;
        }
    }

    void vehicle_control_change(ref const SampleUpdate update)
    {
        if (!update.value_ready || _phase != Phase.ready)
            return;

        if (update.element is _charging_enabled)
        {
            if (update.value.asBool)
                charging_start();
            else
                charging_stop();
        }
        else if (update.element is _charging_amps)
            set_charging_amps(cast(int)update.value.asQuantity!double().value);
        else if (update.element is _hvac_power)
            climate_power(update.value.asBool);
        else if (update.element is _hvac_target_temperature)
            climate_temperature(cast(float)update.value.asQuantity!double().value);
    }

    ubyte[16] _aes_key;
    ubyte[65] _vehicle_pubkey;
    ubyte[16] _epoch;
    uint _counter;
    MonoTime _epoch_start;

    enum max_pending_commands = 8;
    enum Duration pending_command_timeout = 15.seconds;
    enum size_t max_frame_size = 16 * 1024;

    struct PendingCommand
    {
        bool active;
        VehicleCommandKind kind;
        ubyte[16] uuid;
        ubyte[16] request_tag;
        MonoTime sent_at;
        ResponseReplayWindow response_window;
    }
    PendingCommand[max_pending_commands] _pending_commands;

    TeslaChargeState _charge_state;
    TeslaClimateState _climate_state;
    bool _has_charge_state;
    bool _has_climate_state;

    struct CapacitySamplerState
    {
        bool anchored;
        int soc_anchor;
        float energy_anchor;  // kWh
    }
    CapacitySamplerState _cap;

    Array!ubyte _rx_buffer;
    Array!ubyte _rx_frame;

    void client_state_change(ActiveObject, StateSignal signal)
    {
        if (signal != StateSignal.offline)
            return;

        // the client is temporary; offline is its death
        _subscribed = false;
        _client = null;
        restart();
    }

    // NFC authorises the unsigned AddKey request.
    bool send_add_key_request()
    {
        Secret secret = _scanner.secret;
        if (!secret)
            return false;
        const(ubyte)[] pub = secret.public_key_raw;
        if (pub.length != 64)
        {
            log.error("secret public key not available (Secret kind != ec_p256 or not loaded)");
            return false;
        }

        Array!ubyte msg = build_add_key_request(pub);
        return write_tesla_frame(msg[]);
    }

    // Tesla BLE frames are length-prefixed and may exceed the ATT payload.
    bool write_tesla_frame(const(ubyte)[] payload)
    {
        if (payload.length > 0xFFFF)
        {
            log.error("Tesla message too large: ", payload.length, " bytes");
            return false;
        }

        Array!ubyte framed;
        framed.reserve(2 + payload.length);
        framed ~= cast(ubyte)(payload.length >> 8);
        framed ~= cast(ubyte)(payload.length & 0xFF);
        framed ~= payload;

        version (DebugTeslaSession)
            log.trace("TX ", payload.length, " bytes to handle ", _tx_handle);

        ushort mtu = _client.att_mtu;
        if (mtu <= 3)
        {
            log.error("invalid BLE ATT MTU ", mtu, " for VIN '", name[], "'");
            return false;
        }
        size_t max_write = mtu - 3;
        const(ubyte)[] rem = framed[];
        while (rem.length)
        {
            size_t n = rem.length > max_write ? max_write : rem.length;
            if (!_client.write(_tx_handle, rem[0 .. n], true))
            {
                log.error("BLE write failed at offset ", framed.length - rem.length);
                return false;
            }
            rem = rem[n .. $];
        }
        return true;
    }

    // The fresh request UUID is the SessionInfo HMAC challenge.
    bool send_session_info_request(TeslaDomain domain)
    {
        Secret secret = _scanner.secret;
        if (!secret)
            return false;
        const(ubyte)[] pub_xy = secret.public_key_raw;
        if (pub_xy.length != 64)
        {
            log.error("secret public key not available (Secret kind != ec_p256 or not loaded)");
            return false;
        }

        ubyte[65] sec1 = void;
        sec1[0] = 0x04;
        sec1[1 .. 65] = pub_xy[];

        if (!_routing_seeded)
        {
            crypto_random_bytes(_routing_address[]);
            _routing_seeded = true;
        }
        crypto_random_bytes(_request_uuid[]);

        Array!ubyte msg = build_session_info_request(domain, sec1[], _routing_address[], _request_uuid[]);
        _last_request_time = getTime();
        return write_tesla_frame(msg[]);
    }

    // Frames may span multiple ATT notifications.
    void on_notification(ushort, const(ubyte)[] value)
    {
        version (DebugTeslaSession)
            log.trace("RX notify ", value.length, " bytes (buffer ", _rx_buffer.length, ")");

        _last_rx_time = getTime();
        _rx_buffer ~= value[];

        while (_rx_buffer.length >= 2)
        {
            size_t msg_len = (size_t(_rx_buffer[0]) << 8) | _rx_buffer[1];
            if (msg_len == 0 || msg_len > max_frame_size)
            {
                log.warning("invalid Tesla frame length ", msg_len, " for VIN '", name[], "'");
                _rx_buffer.clear();
                restart();
                return;
            }
            if (_rx_buffer.length < 2 + msg_len)
                return;  // need more chunks

            // Dispatch may restart the session or append to _rx_buffer.
            _rx_frame.clear();
            _rx_frame ~= _rx_buffer[2 .. 2 + msg_len];
            _rx_buffer.remove(0, 2 + msg_len);
            dispatch_response(_rx_frame[]);
        }
    }

    void dispatch_response(const(ubyte)[] msg)
    {
        RoutableResponse r;
        if (!decode_routable_response(msg, r))
        {
            log.warning("failed to decode RoutableMessage from vehicle");
            return;
        }

        if (_phase == Phase.session_info_xchg || _phase == Phase.awaiting_approval || _phase == Phase.info_xchg)
        {
            handle_session_info_response(r);
            return;
        }

        if (_phase == Phase.ready)
        {
            if (!r.has_response_signature)
            {
                if (r.protobuf_message.length)
                    log.warning("discarding unauthenticated vehicle response for VIN '", name[], "'");
                return;
            }

            PendingCommand* pending = find_pending_command(r.request_uuid);
            if (pending is null)
            {
                log.warning("encrypted vehicle response has no matching request for VIN '", name[], "'");
                return;
            }

            Array!ubyte plaintext;
            if (!decrypt_routable_response(r, _aes_key[], name[], pending.request_tag[], plaintext))
            {
                log.error("vehicle response authentication failed for VIN '", name[], "'");
                return;
            }
            if (!pending.response_window.accept(r.response_counter))
            {
                log.warning("replayed vehicle response counter ", r.response_counter, " for VIN '", name[], "'");
                return;
            }

            handle_command_response(r, plaintext[], pending.kind);
            *pending = PendingCommand.init;
            return;
        }
    }

    void handle_session_info_response(ref const RoutableResponse r)
    {
        if (r.request_uuid.length == 16 && r.request_uuid[] != _request_uuid[])
            return;

        // Untrusted SessionInfo replies have no HMAC tag.
        if (!r.session_info.length)
        {
            if (r.has_status)
                log.warning("vehicle returned protocol error ", r.signed_message_fault);
            return;
        }

        SessionInfo info;
        if (!decode_session_info(r.session_info, info))
        {
            log.warning("failed to decode SessionInfo from vehicle");
            return;
        }

        if (info.status == 1)  // SESSION_INFO_STATUS_KEY_NOT_ON_WHITELIST
        {
            if (_phase != Phase.awaiting_approval)
            {
                log.info("key not enrolled for VIN '", name[], "'; tap an enrolled key card on the console reader to authorise (retrying continuously)");
                send_add_key_request();
                _phase = Phase.awaiting_approval;
            }
            return;
        }

        if (info.public_key.length != 65 || info.epoch.length != _epoch.length)
        {
            log.error("vehicle SessionInfo has malformed key/epoch lengths ", info.public_key.length, "/", info.epoch.length);
            return;
        }

        if (!verify_session_info_tag(info, r))
        {
            log.error("SessionInfo HMAC tag mismatch for VIN '", name[], "', discarding");
            return;
        }

        // Controls use INFOTAINMENT, not the VCSEC pairing session.
        _vehicle_pubkey[] = info.public_key[];
        _epoch[] = info.epoch[];
        _counter = info.counter;
        _epoch_start = getTime() - info.clock_time.seconds;

        if (_phase == Phase.info_xchg)
        {
            _phase = Phase.ready;
            log.info("session ready for VIN '", name[], "'");
        }
        else
        {
            log.info("trust verified for VIN '", name[], "', establishing infotainment session");
            send_session_info_request(TeslaDomain.infotainment);
            _phase = Phase.info_xchg;
        }
    }

    void handle_command_response(ref const RoutableResponse r, const(ubyte)[] payload, VehicleCommandKind kind)
    {
        if (r.has_status && r.signed_message_fault != 0)
        {
            log.warning("vehicle ", vehicle_command_names[cast(size_t)kind], " protocol error ", r.signed_message_fault, " for VIN '", name[], "'");
            return;
        }
        if (payload.length == 0)
            return;

        TeslaCommandResponse response;
        if (!decode_carserver_response(payload, response))
        {
            log.warning("failed to decode CarServer.Response for VIN '", name[], "'");
            return;
        }

        if (response.action_status.present)
        {
            ref status = response.action_status.value;
            if (status.result.present && status.result.value != 0)
            {
                if (status.result_reason.present && status.result_reason.value.plain_text.present)
                    log.warning("vehicle rejected ", vehicle_command_names[cast(size_t)kind], " for VIN '", name[], "': ", status.result_reason.value.plain_text.value[]);
                else
                    log.warning("vehicle rejected ", vehicle_command_names[cast(size_t)kind], " for VIN '", name[], "' with result ", status.result.value);
                return;
            }

            bool query = kind == VehicleCommandKind.get_charge_state
                      || kind == VehicleCommandKind.get_climate_state
                      || kind == VehicleCommandKind.get_vehicle_state;
            if (!query)
            {
                log.info("vehicle accepted ", vehicle_command_names[cast(size_t)kind], " for VIN '", name[], "'");
                return;
            }
        }

        if (!response.vehicle_data.present)
            return;

        ref data = response.vehicle_data.value;
        if (data.charge_state.present)
        {
            move(data.charge_state.value, _charge_state);
            _has_charge_state = true;
            publish_charge_state(_charge_state);
        }

        if (data.climate_state.present)
        {
            move(data.climate_state.value, _climate_state);
            _has_climate_state = true;
            publish_climate_state(_climate_state);
        }

        if (data.drive_state.present)
        {
            publish_drive_state(data.drive_state.value);
        }
        if (data.location_state.present)
        {
            publish_location_state(data.location_state.value);
        }
        if (data.closures_state.present)
        {
            publish_closures_state(data.closures_state.value);
        }
        if (data.tire_pressure_state.present)
        {
            publish_tire_pressure_state(data.tire_pressure_state.value);
        }
    }

    PendingCommand* reserve_pending_command(const(ubyte)[] uuid, const(ubyte)[] request_tag, VehicleCommandKind kind)
    {
        assert(uuid.length == 16);
        assert(request_tag.length == 16);

        MonoTime now = getTime();
        PendingCommand* free_slot;
        foreach (ref pending; _pending_commands)
        {
            if (pending.active && now - pending.sent_at > pending_command_timeout)
                pending = PendingCommand.init;
            if (!pending.active && free_slot is null)
                free_slot = &pending;
        }
        if (free_slot is null)
            return null;

        free_slot.active = true;
        free_slot.kind = kind;
        free_slot.uuid[] = uuid[];
        free_slot.request_tag[] = request_tag[];
        free_slot.sent_at = now;
        return free_slot;
    }

    PendingCommand* find_pending_command(const(ubyte)[] uuid)
    {
        if (uuid.length != 16)
            return null;
        foreach (ref pending; _pending_commands)
            if (pending.active && pending.uuid[] == uuid)
                return &pending;
        return null;
    }

    void publish_charge_state(ref const TeslaChargeState cs)
    {
        Component v = _scanner.component_for_vin(name[]);
        if (v is null)
            return;

        SysTime now = getSysTime();
        v.set_element("connected", true, now);
        v.set_element("last_seen", now, now);

        if (cs.battery_level.present)
            v.set_element("battery.soc", Quantity!(int, Percent)(cs.battery_level.value), now);
        if (cs.usable_battery_level.present)
            v.set_element("battery.usable_soc", Quantity!(int, Percent)(cs.usable_battery_level.value), now);

        if (cs.charging_state.present)
        {
            static immutable string[9] names = [
                "unknown", "unknown", "disconnected", "no_power", "starting",
                "charging", "complete", "stopped", "calibrating"
            ];
            int state = charging_state_kind(cs.charging_state.value);
            uint idx = state >= 0 && state < names.length ? state : 0;
            v.set_element("charging_state", names[idx], now);
            if (state == 4 || state == 5)
                v.set_element("charging.enabled", true, now, &vehicle_control_change);
            else if (state == 2 || state == 7)
                v.set_element("charging.enabled", false, now, &vehicle_control_change);
        }
        if (cs.minutes_to_full_charge.present)
            v.set_element("minutes_to_full", Quantity!(int, Minute)(cs.minutes_to_full_charge.value), now);
        if (cs.charge_limit_soc.present)
            v.set_element("charging.target_soc", Quantity!(int, Percent)(cs.charge_limit_soc.value), now);
        if (cs.scheduled_charging_pending.present)
            v.set_element("charging.scheduled", cs.scheduled_charging_pending.value, now);
        if (cs.scheduled_charging_start_time_minutes.present)
            v.set_element("charging.schedule_time", cast(int)cs.scheduled_charging_start_time_minutes.value, now);
        if (cs.charge_port_open.present)
        {
            v.set_element("charging.port_open", cs.charge_port_open.value, now);
            v.set_element("closures.charge_port", closure_name(cs.charge_port_open.value), now);
        }

        if (cs.charger_voltage.present)
            v.set_element("meter.voltage", Quantity!(int, ScaledUnits.volt)(cs.charger_voltage.value), now);
        if (cs.charger_actual_current.present)
            v.set_element("meter.current", Quantity!(int, ScaledUnits.ampere)(cs.charger_actual_current.value), now);
        if (cs.charger_power.present)
            v.set_element("meter.power", Quantity!(int, ScaledUnits.watt)(cs.charger_power.value * 1000), now);
        if (cs.charge_energy_added.present)
            v.set_element("meter.import", Quantity!(float, KilowattHour)(cs.charge_energy_added.value), now);

        if (cs.charge_current_request_max.present)
            v.set_element("control.max", Quantity!(int, ScaledUnits.ampere)(cs.charge_current_request_max.value), now);
        if (cs.charging_amps.present)
            v.set_element("control.setpoint", Quantity!(int, ScaledUnits.ampere)(cs.charging_amps.value), now, &vehicle_control_change);

        if (cs.battery_level.present && cs.charge_energy_added.present)
            capacity_sample(cs.battery_level.value, cs.charge_energy_added.value);
    }

    void publish_climate_state(ref const TeslaClimateState climate)
    {
        Component v = _scanner.component_for_vin(name[]);
        if (v is null)
            return;

        SysTime now = getSysTime();
        v.set_element("connected", true, now);
        v.set_element("last_seen", now, now);
        if (climate.inside_temperature.present)
            v.set_element("hvac.temperature", Quantity!(float, Celsius)(climate.inside_temperature.value), now);
        if (climate.outside_temperature.present)
            v.set_element("hvac.outside_temperature", Quantity!(float, Celsius)(climate.outside_temperature.value), now);
        if (climate.driver_temperature.present)
            v.set_element("hvac.target_temperature", Quantity!(float, Celsius)(climate.driver_temperature.value), now, &vehicle_control_change);
        if (climate.passenger_temperature.present)
            v.set_element("hvac.passenger_target_temperature", Quantity!(float, Celsius)(climate.passenger_temperature.value), now);
        if (climate.fan_speed.present)
            v.set_element("hvac.fan_speed", climate.fan_speed.value, now);
        if (climate.min_temperature.present)
            v.set_element("hvac.min_temperature", Quantity!(float, Celsius)(climate.min_temperature.value), now);
        if (climate.max_temperature.present)
            v.set_element("hvac.max_temperature", Quantity!(float, Celsius)(climate.max_temperature.value), now);
        if (climate.climate_on.present)
        {
            v.set_element("hvac.power", climate.climate_on.value, now, &vehicle_control_change);
            v.set_element("hvac.state", climate.climate_on.value
                ? StringLit!"on" : StringLit!"off", now);
            v.set_element("hvac.mode", climate.climate_on.value
                ? StringLit!"auto" : StringLit!"off", now);
        }
        if (climate.preconditioning.present)
            v.set_element("hvac.preconditioning", climate.preconditioning.value, now);
        if (climate.battery_heater.present)
            v.set_element("hvac.battery.heating", climate.battery_heater.value, now);
        if (climate.steering_wheel_heat_level.present)
            v.set_element("hvac.steering_wheel.heating_level", climate.steering_wheel_heat_level.value, now);
        else if (climate.steering_wheel_heater.present)
            v.set_element("hvac.steering_wheel.heater", climate.steering_wheel_heater.value, now);
        if (climate.seat_front_left_heating.present)
            v.set_element("hvac.seats.front_left.heating_level", climate.seat_front_left_heating.value, now);
        if (climate.seat_front_right_heating.present)
            v.set_element("hvac.seats.front_right.heating_level", climate.seat_front_right_heating.value, now);
        if (climate.seat_rear_left_heating.present)
            v.set_element("hvac.seats.rear_left.heating_level", climate.seat_rear_left_heating.value, now);
        if (climate.seat_rear_center_heating.present)
            v.set_element("hvac.seats.rear_center.heating_level", climate.seat_rear_center_heating.value, now);
        if (climate.seat_rear_right_heating.present)
            v.set_element("hvac.seats.rear_right.heating_level", climate.seat_rear_right_heating.value, now);
        if (climate.seat_rear_left_back_heating.present)
            v.set_element("hvac.seats.rear_left_back.heating_level", climate.seat_rear_left_back_heating.value, now);
        if (climate.seat_rear_right_back_heating.present)
            v.set_element("hvac.seats.rear_right_back.heating_level", climate.seat_rear_right_back_heating.value, now);
        if (climate.seat_third_row_left_heating.present)
            v.set_element("hvac.seats.third_row_left.heating_level", climate.seat_third_row_left_heating.value, now);
        if (climate.seat_third_row_right_heating.present)
            v.set_element("hvac.seats.third_row_right.heating_level", climate.seat_third_row_right_heating.value, now);
        if (climate.seat_front_left_cooling.present)
            v.set_element("hvac.seats.front_left.cooling_level", climate.seat_front_left_cooling.value, now);
        if (climate.seat_front_right_cooling.present)
            v.set_element("hvac.seats.front_right.cooling_level", climate.seat_front_right_cooling.value, now);
        if (climate.defrost_mode.present)
            v.set_element("hvac.defrost", defrost_name(defrost_mode_kind(climate.defrost_mode.value)), now);
        if (climate.climate_keeper_mode.present)
            v.set_element("hvac.climate_keeper_mode", climate_keeper_name(climate_keeper_mode_kind(climate.climate_keeper_mode.value)), now);
    }

    void publish_drive_state(ref const TeslaDriveState drive)
    {
        Component v = vehicle_for_update();
        if (!v)
            return;

        SysTime now = getSysTime();
        if (drive.gear.present)
            v.set_element("drive.gear", gear_name(shift_state_kind(drive.gear.value)), now);
        if (drive.speed_float.present || drive.speed.present)
        {
            float speed_mph = drive.speed_float.present
                ? drive.speed_float.value : drive.speed.value;
            v.set_element("drive.speed", Quantity!(float, ScaledUnits.kilometre_per_hour)(speed_mph * 1.609344f), now);
        }
        if (drive.power.present)
            v.set_element("drive.power", Quantity!(int, Kilowatt)(drive.power.value), now);
        if (drive.odometer_hundredths_mile.present)
            v.set_element("drive.odometer", Quantity!(float, Kilometre)(drive.odometer_hundredths_mile.value * 0.01609344f), now);
    }

    void publish_location_state(ref const TeslaLocationState location)
    {
        Component v = vehicle_for_update();
        if (!v)
            return;

        SysTime now = getSysTime();
        if (location.latitude.present)
            v.set_element("location.latitude", Quantity!(float, Degree)(location.latitude.value), now);
        if (location.longitude.present)
            v.set_element("location.longitude", Quantity!(float, Degree)(location.longitude.value), now);
        if (location.heading.present)
            v.set_element("location.heading", Quantity!(uint, Degree)(location.heading.value), now);
        if (location.accuracy.present)
            v.set_element("location.accuracy", Quantity!(float, ScaledUnits.metre)(location.accuracy.value), now);
    }

    void publish_closures_state(ref const TeslaClosuresState closures)
    {
        Component v = vehicle_for_update();
        if (!v)
            return;

        SysTime now = getSysTime();
        if (closures.locked.present)
            v.set_element("access.locked", closures.locked.value, now);
        if (closures.user_present.present)
            v.set_element("access.user_present", closures.user_present.value, now);
        if (closures.driver_front_open.present)
            v.set_element("closures.driver_front", closure_name(closures.driver_front_open.value), now);
        if (closures.passenger_front_open.present)
            v.set_element("closures.passenger_front", closure_name(closures.passenger_front_open.value), now);
        if (closures.driver_rear_open.present)
            v.set_element("closures.driver_rear", closure_name(closures.driver_rear_open.value), now);
        if (closures.passenger_rear_open.present)
            v.set_element("closures.passenger_rear", closure_name(closures.passenger_rear_open.value), now);
        if (closures.frunk_open.present)
            v.set_element("closures.frunk", closure_name(closures.frunk_open.value), now);
        if (closures.trunk_open.present)
            v.set_element("closures.trunk", closure_name(closures.trunk_open.value), now);
    }

    void publish_tire_pressure_state(ref const TeslaTirePressureState tyres)
    {
        Component v = vehicle_for_update();
        if (!v)
            return;

        SysTime now = getSysTime();
        if (tyres.front_left_pressure.present)
            v.set_element("tyres.front_left.pressure", Quantity!(float, Bar)(tyres.front_left_pressure.value), now);
        if (tyres.front_right_pressure.present)
            v.set_element("tyres.front_right.pressure", Quantity!(float, Bar)(tyres.front_right_pressure.value), now);
        if (tyres.rear_left_pressure.present)
            v.set_element("tyres.rear_left.pressure", Quantity!(float, Bar)(tyres.rear_left_pressure.value), now);
        if (tyres.rear_right_pressure.present)
            v.set_element("tyres.rear_right.pressure", Quantity!(float, Bar)(tyres.rear_right_pressure.value), now);
        if (tyres.front_left_hard_warning.present || tyres.front_left_soft_warning.present)
            v.set_element("tyres.front_left.warning", tyres.front_left_hard_warning.value || tyres.front_left_soft_warning.value, now);
        if (tyres.front_right_hard_warning.present || tyres.front_right_soft_warning.present)
            v.set_element("tyres.front_right.warning", tyres.front_right_hard_warning.value || tyres.front_right_soft_warning.value, now);
        if (tyres.rear_left_hard_warning.present || tyres.rear_left_soft_warning.present)
            v.set_element("tyres.rear_left.warning", tyres.rear_left_hard_warning.value || tyres.rear_left_soft_warning.value, now);
        if (tyres.rear_right_hard_warning.present || tyres.rear_right_soft_warning.present)
            v.set_element("tyres.rear_right.warning", tyres.rear_right_hard_warning.value || tyres.rear_right_soft_warning.value, now);
    }

    Component vehicle_for_update()
    {
        Component v = _scanner.component_for_vin(name[]);
        if (!v)
            return null;

        SysTime now = getSysTime();
        v.set_element("connected", true, now);
        v.set_element("last_seen", now, now);
        return v;
    }

    static const(char)[] closure_name(bool open) pure
        => open ? "open" : "closed";

    static const(char)[] gear_name(int gear) pure
    {
        static immutable string[7] names = ["unknown", "invalid", "park", "reverse", "neutral", "drive", "unavailable"];
        return gear > 0 && gear < names.length ? names[gear] : names[0];
    }

    static const(char)[] defrost_name(int mode) pure
    {
        static immutable string[5] names = ["unknown", "unknown", "off", "normal", "max"];
        return mode > 0 && mode < names.length ? names[mode] : names[0];
    }

    static const(char)[] climate_keeper_name(int mode) pure
    {
        static immutable string[6] names = ["unknown", "unknown", "off", "on", "dog", "party"];
        return mode > 0 && mode < names.length ? names[mode] : names[0];
    }

    // Estimate capacity from 5%-SOC windows in the BMS's linear region.
    void capacity_sample(int soc, float energy_added)
    {
        import apps.energy.vehicle : add_capacity_sample;

        // charge_energy_added resets for each charging session.
        if (_cap.anchored && energy_added < _cap.energy_anchor)
            _cap.anchored = false;

        if (!_cap.anchored)
        {
            // The top and bottom BMS buffers produce noisy estimates.
            if (soc >= 15 && soc <= 85)
            {
                _cap.soc_anchor = soc;
                _cap.energy_anchor = energy_added;
                _cap.anchored = true;
            }
            return;
        }

        if (soc > 85)
        {
            _cap.anchored = false;
            return;
        }

        int delta_soc = soc - _cap.soc_anchor;
        if (delta_soc < 5)
            return;  // wait for a meaningful window

        float delta_energy = energy_added - _cap.energy_anchor;
        if (delta_energy <= 0)
            return;  // wonky reading, ignore

        float estimate_kwh = delta_energy / (delta_soc / 100.0f);
        add_capacity_sample(name[], estimate_kwh, cast(float)delta_soc);

        _cap.soc_anchor = soc;
        _cap.energy_anchor = energy_added;
    }

    bool send_signed_action(TeslaDomain domain, const(ubyte)[] plaintext, VehicleCommandKind kind)
    {
        if (_phase != Phase.ready)
        {
            log.warning("session not ready, command refused");
            return false;
        }

        Secret secret = _scanner.secret;
        if (!secret)
            return false;
        const(ubyte)[] pub_xy = secret.public_key_raw;
        if (pub_xy.length != 64)
            return false;
        ubyte[65] signer_sec1 = void;
        signer_sec1[0] = 0x04;
        signer_sec1[1 .. 65] = pub_xy[];

        ++_counter;

        long elapsed = (getTime() - _epoch_start).as!"seconds";
        if (elapsed < 0) elapsed = 0;
        uint expires_at = cast(uint)elapsed + 5;  // 5-second TTL

        enum uint flags = encrypt_response_mask;

        Array!ubyte meta = build_signed_command_metadata(domain, name[], _epoch[], expires_at, _counter, flags);

        SHA256Context sha;
        sha_init(sha);
        sha_update(sha, meta[]);
        ubyte[32] aad = sha_finalise(sha);

        ubyte[12] nonce = void;
        crypto_random_bytes(nonce[]);

        Array!ubyte ciphertext;
        ciphertext.resize(plaintext.length);
        ubyte[16] tag = void;
        Result enc = aes_gcm_encrypt(_aes_key[], nonce[], aad[], plaintext, ciphertext[], tag[]);
        if (enc.failed)
        {
            log.error("AES-GCM encrypt failed: ", enc.system_code);
            return false;
        }

        if (!_routing_seeded)
        {
            crypto_random_bytes(_routing_address[]);
            _routing_seeded = true;
        }
        ubyte[16] uuid = void;
        crypto_random_bytes(uuid[]);

        Array!ubyte msg = build_signed_routable_message(domain, ciphertext[], signer_sec1[], _epoch[], nonce[], _counter, expires_at, tag[], _routing_address[], uuid[], flags);
        PendingCommand* pending = reserve_pending_command(uuid[], tag[], kind);
        if (pending is null)
        {
            log.warning("too many vehicle commands awaiting responses for VIN '", name[], "'");
            return false;
        }
        if (!write_tesla_frame(msg[]))
        {
            *pending = PendingCommand.init;
            return false;
        }
        return true;
    }

    // Derive the SessionInfo HMAC key from the ECDH shared X coordinate.
    bool verify_session_info_tag(ref const SessionInfo info, ref const RoutableResponse r)
    {
        if (info.public_key.length != 65 || info.public_key[0] != 0x04)
            return false;

        const(ubyte)[] vehicle_xy = info.public_key[1 .. 65];

        ubyte[32] shared_x = void;
        Secret secret = _scanner.secret;
        if (!secret || secret.ecdh_compute_shared(vehicle_xy, shared_x[]).failed)
            return false;

        SHA1Context sha;
        sha_init(sha);
        sha_update(sha, shared_x[]);
        Array!ubyte sha1_out = sha_finalise(sha);
        _aes_key[] = sha1_out[0 .. 16];

        HMACContext!SHA256Context kdf;
        hmac_init(kdf, _aes_key[]);
        hmac_update(kdf, cast(const(ubyte)[])"session info");
        ubyte[32] session_info_key = hmac_finalise(kdf);

        ubyte[1] sig_hmac = [cast(ubyte)SigType.hmac];

        Array!ubyte meta;
        append_tlv(meta, SigTag.signature_type, sig_hmac[]);
        append_tlv(meta, SigTag.personalization, cast(const(ubyte)[])name[]);
        append_tlv(meta, SigTag.challenge, _request_uuid[]);
        meta ~= cast(ubyte)SigTag.end;

        HMACContext!SHA256Context tag_ctx;
        hmac_init(tag_ctx, session_info_key[]);
        hmac_update(tag_ctx, meta[]);
        hmac_update(tag_ctx, r.session_info);
        ubyte[32] expected = hmac_finalise(tag_ctx);

        if (r.session_info_tag.length != expected.length)
            return false;
        ubyte diff = 0;
        foreach (i, b; expected[])
            diff |= b ^ r.session_info_tag[i];
        return diff == 0;
    }
}
