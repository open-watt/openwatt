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
import protocol.ble.att : ATTError;
import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;
import protocol.tesla.vehicle_codec;
import protocol.tesla.vehicle_crypto;
import protocol.tesla.vehicle_scanner;
public import protocol.tesla.vehicle_retry;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import tools.protobuf;

nothrow @nogc:

enum Bar = ScaledUnit(Pascal, 5);

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
    {
        if (!select_vehicle_category(getTime()))
            return false;
        bool sent = send_signed_action(TeslaDomain.infotainment, build_action_get_vehicle_category(_vehicle_category)[], VehicleCommandKind.get_vehicle_state);
        if (sent)
            _vehicle_category = (_vehicle_category + 1) % 4;
        return sent;
    }

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
    void reset_retry_status()
    {
        _fault = null;
        _phase = Phase.failed;
        _pending_commands[] = PendingCommand.init;
        restart();
        write_status();
    }

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
    const(VehicleRetryState)* retry_state() const pure
        => _scanner ? _scanner.retry_state(name[]) : null;

    VehicleRetryState* retry_state()
        => _scanner ? _scanner.retry_state(name[]) : null;

    bool signer_unchanged()
    {
        const Secret key = _scanner ? _scanner.secret : null;
        if (key && key.public_key_raw == _signer_pubkey[])
            return true;
        fail_session("Vehicle key changed; establishing a new session");
        return false;
    }

    override bool validate() const
    {
        const(VehicleRetryState)* retry = retry_state();
        return _scanner !is null && cast(bool)_peer && (!retry || retry.failures[0].available(getTime()));
    }

    override const(char)[] status_message() const
    {
        if (const(VehicleRetryState)* retry = retry_state())
            if (retry.status.length)
                return retry.status[];
        if (_state != State.starting && _state != State.running)
            return super.status_message();

        if (_fault)
            return _fault;

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
        retry_state();
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
        if (_poll_scheduled)
        {
            g_app.cancel(&poll_event);
            _poll_scheduled = false;
        }
        _retry_poll = PollKind.none;
        _auth_failures = 0;
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
        _vehicle_category = 0;
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
    CompletionStatus advance(MonoTime now = getTime())
    {
        if (_phase == Phase.ready && now - _last_authenticated_rx_time > link_timeout)
        {
            _fault = "Vehicle session stopped responding";
            _phase = Phase.failed;
            return CompletionStatus.error;
        }
        // WinRT can report a dead GATT channel as connected.
        if (now - _last_rx_time > link_timeout)
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
                if (now >= _approval_deadline)
                {
                    record_failure(VehicleCommandKind.unknown, 0, "Key not enrolled; tap an enrolled key card during the next approval attempt, or reset back-off to try now", false);
                    return CompletionStatus.error;
                }
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
                return CompletionStatus.complete;

            case Phase.failed:
                return CompletionStatus.error;
        }
    }

    enum Duration retry_interval = 5.seconds;
    enum Duration approval_interval = 2.seconds;
    enum Duration approval_window = 60.seconds;
    enum Duration link_timeout = 45.seconds;
    enum Duration poll_charging = 2.seconds;
    enum Duration poll_idle = 30.seconds;
    enum Duration climate_poll_interval = 60.seconds;
    enum Duration vehicle_poll_interval = 15.seconds;

    Device _control_device;
    TeslaVehicleScanner _scanner;
    MACAddress _peer;
    BLEClient _client;
    bool _subscribed;
    bool _approval_toggle;
    MonoTime _approval_deadline;
    ushort _tx_handle;
    ushort _rx_handle;
    Phase _phase = Phase.connecting;
    MonoTime _last_rx_time;
    MonoTime _last_authenticated_rx_time;
    MonoTime _last_seen;

    ubyte[16] _routing_address;
    ubyte[16] _request_uuid;
    TeslaDomain _info_domain;
    MonoTime _last_request_time;
    MonoTime _last_poll_time;
    MonoTime _last_climate_poll_time;
    MonoTime _last_vehicle_poll_time;
    enum PollKind : ubyte { none, charge, climate, vehicle }
    PollKind _retry_poll;
    bool _poll_scheduled;

    bool _routing_seeded;

    Element* _charging_enabled;
    Element* _charging_amps;
    Element* _hvac_power;
    Element* _hvac_target_temperature;

    MonoTime next_poll_time() const
    {
        import urt.util : min, max;
        MonoTime charge = max(_last_poll_time + poll_interval_for_state(), retry_time(VehicleCommandKind.get_charge_state));
        MonoTime climate = max(_last_climate_poll_time + climate_poll_interval, retry_time(VehicleCommandKind.get_climate_state));
        MonoTime vehicle = MonoTime(ulong.max);
        foreach (ubyte category; 0 .. 4)
            vehicle = min(vehicle, max(_last_vehicle_poll_time + vehicle_poll_interval, retry_time(VehicleCommandKind.get_vehicle_state, category)));
        return min(charge, min(climate, vehicle));
    }

    MonoTime retry_time(VehicleCommandKind kind, ubyte category = 0) const
    {
        import urt.util : max;
        const(VehicleRetryState)* retry = retry_state();
        return retry ? max(retry.failures[0].next(), retry.failures[VehicleRetryState.index(kind, category)].next()) : MonoTime();
    }

    bool select_vehicle_category(MonoTime now)
    {
        foreach (ubyte offset; 0 .. 4)
        {
            ubyte category = (_vehicle_category + offset) % 4;
            if (retry_time(VehicleCommandKind.get_vehicle_state, category) <= now)
            {
                _vehicle_category = category;
                return true;
            }
        }
        return false;
    }

    bool poll_available(PollKind kind, MonoTime now)
    {
        final switch (kind)
        {
            case PollKind.none: return false;
            case PollKind.charge: return retry_time(VehicleCommandKind.get_charge_state) <= now;
            case PollKind.climate: return retry_time(VehicleCommandKind.get_climate_state) <= now;
            case PollKind.vehicle: return select_vehicle_category(now);
        }
    }

    MonoTime poll(MonoTime now)
    {
        PollKind kind = _retry_poll;
        if (!poll_available(kind, now))
            kind = _retry_poll = PollKind.none;
        if (kind == PollKind.none)
        {
            if (now - _last_poll_time >= poll_interval_for_state() && poll_available(PollKind.charge, now))
                kind = PollKind.charge;
            else if (now - _last_climate_poll_time >= climate_poll_interval && poll_available(PollKind.climate, now))
                kind = PollKind.climate;
            else if (now - _last_vehicle_poll_time >= vehicle_poll_interval && poll_available(PollKind.vehicle, now))
                kind = PollKind.vehicle;
        }

        bool sent;
        final switch (kind)
        {
            case PollKind.none: return next_poll_time();
            case PollKind.charge:
                sent = refresh_charge_state();
                if (sent)
                    _last_poll_time = now;
                break;
            case PollKind.climate:
                sent = refresh_climate_state();
                if (sent)
                    _last_climate_poll_time = now;
                break;
            case PollKind.vehicle:
                sent = refresh_vehicle_state();
                if (sent)
                    _last_vehicle_poll_time = now;
                break;
        }
        _retry_poll = sent ? PollKind.none : kind;
        if (sent)
            return next_poll_time();

        MonoTime expiry = MonoTime(ulong.max);
        foreach (ref pending; _pending_commands)
        {
            if (!pending.active)
                return now + 1.seconds;
            if (pending.sent_at + pending_command_timeout < expiry)
                expiry = pending.sent_at + pending_command_timeout;
        }
        return expiry > now ? expiry : now + 1.seconds;
    }

    void schedule_poll(MonoTime when)
    {
        if (_phase != Phase.ready || _client is null || (_state != State.running && _state != State.starting))
            return;
        if (_poll_scheduled)
            g_app.cancel(&poll_event);
        _poll_scheduled = false;
        if (when == MonoTime(ulong.max))
            return;
        g_app.schedule(when, &poll_event);
        _poll_scheduled = true;
    }

    void poll_event(MonoTime now)
    {
        _poll_scheduled = false;
        if (_phase == Phase.ready && (_state == State.running || _state == State.starting))
            schedule_poll(poll(now));
    }

    void write_complete(const(ubyte)[], ATTError error)
    {
        if (error == ATTError.none)
            schedule_poll(getTime());
    }

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
        if (_control_device)
            return;

        Device vehicle = _scanner.device_for_vin(name[]);
        if (!vehicle)
            return;

        _charging_enabled = vehicle.find_element("charging.enabled");
        _charging_amps = vehicle.find_element("control.setpoint");
        _hvac_power = vehicle.find_element("hvac.power");
        _hvac_target_temperature = vehicle.find_element("hvac.target_temperature");

        subscribe_vehicle_control(vehicle, _charging_enabled);
        subscribe_vehicle_control(vehicle, _charging_amps);
        subscribe_vehicle_control(vehicle, _hvac_power);
        subscribe_vehicle_control(vehicle, _hvac_target_temperature);
        _control_device = vehicle;
    }

    void unsubscribe_vehicle_controls()
    {
        if (!_control_device)
            return;

        _control_device.detach_binding(this);
        unsubscribe_vehicle_control(_charging_enabled);
        unsubscribe_vehicle_control(_charging_amps);
        unsubscribe_vehicle_control(_hvac_power);
        unsubscribe_vehicle_control(_hvac_target_temperature);
        _charging_enabled = null;
        _charging_amps = null;
        _hvac_power = null;
        _hvac_target_temperature = null;
        _control_device = null;
    }

    void subscribe_vehicle_control(Device vehicle, Element* element)
    {
        if (!element)
            return;
        vehicle.attach_binding(this, element, Access.read_write);
        element.subscribe(&vehicle_control_change);
    }

    void unsubscribe_vehicle_control(Element* element)
    {
        if (!element)
            return;
        element.unsubscribe(&vehicle_control_change);
        element.access = cast(Access)(element.access | Access.read);
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
    ubyte[64] _signer_pubkey;
    enum ubyte auth_failure_limit = 3;
    ubyte _auth_failures;
    const(char)[] _fault;

    ubyte[16] _epoch;
    uint _counter;
    MonoTime _epoch_start;

    enum max_pending_commands = 8;
    enum Duration pending_command_timeout = 15.seconds;
    enum size_t max_frame_size = 16 * 1024;

    struct PendingCommand
    {
        bool active;
        bool auth_failure_reported;
        VehicleCommandKind kind;
        ubyte category;
        ubyte[16] uuid;
        ubyte[16] request_tag;
        MonoTime sent_at;
    }
    PendingCommand[max_pending_commands] _pending_commands;

    TeslaChargeState _charge_state;
    TeslaClimateState _climate_state;
    bool _has_charge_state;
    bool _has_climate_state;
    ubyte _vehicle_category;

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
            if (!_client.write(_tx_handle, rem[0 .. n], true, n == rem.length ? &write_complete : null))
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
        _info_domain = domain;

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

        // the vehicle broadcasts unsolicited VCSEC status to domain 0; only replies carry our routing address
        if (!r.addressed_to(_routing_address[]))
            return;

        if (_phase == Phase.session_info_xchg || _phase == Phase.awaiting_approval || _phase == Phase.info_xchg)
        {
            handle_session_info_response(r);
            return;
        }

        if (_phase == Phase.ready)
        {
            if (!signer_unchanged())
                return;
            if (!r.has_from_domain || r.from_domain != TeslaDomain.infotainment)
                return;

            PendingCommand* pending = find_pending_command(r.request_uuid);
            if (pending is null)
                return;

            if (!r.has_response_signature)
            {
                if (r.signed_message_fault != 0)
                    handle_protocol_fault(r.signed_message_fault, *pending, false);
                else if (r.protobuf_message.length)
                {
                    log.warning("discarding unauthenticated vehicle response for VIN '", name[], "': ", cast(void[])r.protobuf_message);
                    note_auth_failure(*pending, "Vehicle replies unauthenticated");
                }
                return;
            }

            Array!ubyte plaintext;
            if (!decrypt_routable_response(r, _aes_key[], name[], pending.request_tag[], plaintext))
            {
                log.error("vehicle response authentication failed for VIN '", name[], "'");
                note_auth_failure(*pending, "Vehicle responses fail authentication");
                return;
            }
            _auth_failures = 0;
            _fault = null;
            _last_authenticated_rx_time = getTime();
            if (r.signed_message_fault != 0)
            {
                handle_protocol_fault(r.signed_message_fault, *pending, true);
                return;
            }
            VehicleCommandKind kind = pending.kind;
            ubyte category = pending.category;
            *pending = PendingCommand.init;
            handle_command_response(plaintext[], kind, category);
            schedule_poll(getTime());
            return;
        }
    }

    void note_auth_failure(ref PendingCommand pending, const(char)[] reason)
    {
        if (pending.auth_failure_reported)
            return;
        pending.auth_failure_reported = true;
        if (++_auth_failures < auth_failure_limit)
            return;
        fail_session(reason);
    }

    void fail_session(const(char)[] reason)
    {
        _fault = reason;
        _auth_failures = 0;
        _phase = Phase.failed;
        log.warning("session unusable for VIN '", name[], "': ", reason, "; re-establishing");
        restart();
    }

    void handle_protocol_fault(uint fault, ref PendingCommand pending, bool authenticated)
    {
        enum MessageFault : uint
        {
            invalid_signature = 5,
            invalid_token_or_counter = 6,
            incorrect_epoch = 15,
            time_expired = 17,
            time_to_live_too_long = 20,
        }

        log.warning("vehicle ", vehicle_command_names[cast(size_t)pending.kind], " protocol error ", fault, " for VIN '", name[], "'");
        VehicleCommandKind kind = pending.kind;
        ubyte category = pending.category;
        pending = PendingCommand.init;
        switch (fault)
        {
            case MessageFault.invalid_signature:
            case MessageFault.invalid_token_or_counter:
            case MessageFault.incorrect_epoch:
            case MessageFault.time_expired:
            case MessageFault.time_to_live_too_long:
                record_failure(kind, category, "Vehicle session needs resynchronization", false);
                fail_session("Vehicle session needs resynchronization");
                return;
            default:
                string reason;
                bool permanent = true;
                bool session;
                switch (fault)
                {
                    case 1: reason = "Vehicle busy"; permanent = false; break;
                    case 2: reason = "Vehicle subsystem timed out"; permanent = false; break;
                    case 3: reason = "Key not enrolled; pair the key then reset back-off"; session = true; break;
                    case 4: reason = "Key disabled; enable or replace the key then reset back-off"; session = true; break;
                    case 7: reason = "Permission denied; check key role and vehicle state then reset back-off"; break;
                    case 8: case 9: reason = "Command unsupported; update vehicle/client support then reset back-off"; break;
                    case 11: reason = "Vehicle internal error"; permanent = false; break;
                    case 21: reason = "Mobile access disabled; enable it then reset back-off"; session = true; break;
                    case 22: reason = "Service access disabled; enable it then reset back-off"; session = true; break;
                    case 23: reason = "Command requires account credentials unavailable over BLE"; break;
                    default: reason = "Vehicle rejected command; inspect protocol error in log then reset back-off"; break;
                }
                record_failure(session ? VehicleCommandKind.unknown : kind, category, reason, permanent && authenticated);
                if (session && authenticated)
                {
                    _phase = Phase.failed;
                    restart();
                }
                schedule_poll(getTime());
                return;
        }
    }

    void handle_session_info_response(ref const RoutableResponse r)
    {
        if (r.request_uuid.length == 16 && r.request_uuid[] != _request_uuid[])
            return;
        if (r.has_from_domain && r.from_domain != _info_domain)
            return;

        // Untrusted SessionInfo replies have no HMAC tag.
        if (!r.session_info.length)
        {
            if (r.has_status && r.signed_message_fault && r.request_uuid.length == 16 && r.has_from_domain)
            {
                PendingCommand pending;
                handle_protocol_fault(r.signed_message_fault, pending, false);
                restart();
            }
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
                log.info("key not enrolled for VIN '", name[], "'; tap an enrolled key card on the console reader within 60 seconds to authorise");
                send_add_key_request();
                _phase = Phase.awaiting_approval;
                _approval_deadline = getTime() + approval_window;
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

        _last_authenticated_rx_time = getTime();
        _signer_pubkey[] = _scanner.secret.public_key_raw;

        // Controls use INFOTAINMENT, not the VCSEC pairing session.
        _vehicle_pubkey[] = info.public_key[];
        _epoch[] = info.epoch[];
        _counter = info.counter;
        _epoch_start = getTime() - info.clock_time.seconds;

        if (_phase == Phase.info_xchg)
        {
            if (VehicleRetryState* retry = retry_state())
                retry.succeeded(0);
            _phase = Phase.ready;
            write_status();
            schedule_poll(getTime());
            log.info("session ready for VIN '", name[], "'");
        }
        else
        {
            log.info("trust verified for VIN '", name[], "', establishing infotainment session");
            send_session_info_request(TeslaDomain.infotainment);
            _phase = Phase.info_xchg;
        }
    }

    void record_failure(VehicleCommandKind kind, ubyte category, const(char)[] reason, bool latch)
    {
        if (VehicleRetryState* retry = retry_state())
            retry.failed(VehicleRetryState.index(kind, category), reason, getTime(), latch);
        _fault = "Vehicle command back-off";
        write_status();
    }

    void handle_command_response(const(ubyte)[] payload, VehicleCommandKind kind, ubyte category = 0)
    {
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
                const(char)[] reason = "Vehicle rejected action";
                if (status.result_reason.present && status.result_reason.value.plain_text.present)
                    reason = status.result_reason.value.plain_text.value[];
                log.warning("vehicle rejected ", vehicle_command_names[cast(size_t)kind], " for VIN '", name[], "': ", reason);
                record_failure(kind, category, reason, false);
                return;
            }

            if (VehicleRetryState* retry = retry_state())
            {
                retry.succeeded(VehicleRetryState.index(kind, category));
                retry.succeeded(0);
                write_status();
            }

            bool query = kind == VehicleCommandKind.get_charge_state || kind == VehicleCommandKind.get_climate_state || kind == VehicleCommandKind.get_vehicle_state;
            if (!query)
            {
                log.info("vehicle accepted ", vehicle_command_names[cast(size_t)kind], " for VIN '", name[], "'");
                return;
            }
        }

        if (!response.vehicle_data.present)
            return;

        if (VehicleRetryState* retry = retry_state())
        {
            retry.succeeded(VehicleRetryState.index(kind, category));
            retry.succeeded(0);
            write_status();
        }

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
            if (pending.active && now - pending.sent_at >= pending_command_timeout)
            {
                record_failure(pending.kind, pending.category, "Vehicle command response timed out", false);
                pending = PendingCommand.init;
            }
            if (!pending.active && free_slot is null)
                free_slot = &pending;
        }
        if (free_slot is null)
            return null;

        free_slot.active = true;
        free_slot.kind = kind;
        free_slot.category = kind == VehicleCommandKind.get_vehicle_state ? _vehicle_category : 0;
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
            {
                if (getTime() - pending.sent_at >= pending_command_timeout)
                {
                    record_failure(pending.kind, pending.category, "Vehicle command response timed out", false);
                    pending = PendingCommand.init;
                    return null;
                }
                return &pending;
            }
        return null;
    }

    void publish_charge_state(ref const TeslaChargeState cs)
    {
        Device v = _scanner.device_for_vin(name[]);
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
        Device v = _scanner.device_for_vin(name[]);
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
            v.set_element("hvac.state", climate.climate_on.value ? StringLit!"on" : StringLit!"off", now);
            v.set_element("hvac.mode", climate.climate_on.value ? StringLit!"auto" : StringLit!"off", now);
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
            float speed_mph = drive.speed_float.present ? drive.speed_float.value : drive.speed.value;
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

    Device vehicle_for_update()
    {
        Device v = _scanner.device_for_vin(name[]);
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
        retry_state();
        if (retry_time(kind, kind == VehicleCommandKind.get_vehicle_state ? _vehicle_category : 0) > getTime())
            return false;
        if (_phase != Phase.ready)
        {
            log.warning("session not ready, command refused");
            return false;
        }
        if (!signer_unchanged())
            return false;

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
        if (retry_time(kind, pending.category) > getTime())
        {
            *pending = PendingCommand.init;
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


unittest
{
    import urt.mem : alloc, free;

    TeslaVehicleSession unready = alloc!TeslaVehicleSession(CID(1));
    scope(exit) free(unready);
    assert(!unready.refresh_vehicle_state() && unready._vehicle_category == 0);
    assert(!unready.refresh_vehicle_state() && unready._vehicle_category == 0);

    static class Session : TeslaVehicleSession
    {
    nothrow @nogc:
        this() { super(CID(2)); }
        bool accept;
        uint charges, climates, vehicles;
        VehicleRetryState retry;
        override VehicleRetryState* retry_state() => &retry;
        override const(VehicleRetryState)* retry_state() const pure => &retry;
        override bool refresh_charge_state() { ++charges; return accept; }
        override bool refresh_climate_state() { ++climates; return accept; }
        override bool refresh_vehicle_state() { ++vehicles; return accept; }
    }
    Session s = alloc!Session();
    scope(exit) free(s);
    MonoTime now = MonoTime.init + 100.seconds;
    s._last_poll_time = now;
    s._last_climate_poll_time = now;
    s._last_vehicle_poll_time = now - s.vehicle_poll_interval;
    MonoTime previous = s._last_vehicle_poll_time;
    assert(s.poll(now) == now + 1.seconds);
    assert(s._last_vehicle_poll_time == previous && s.vehicles == 1);
    assert(s._retry_poll == s.PollKind.vehicle);

    foreach (ref pending; s._pending_commands)
    {
        pending.active = true;
        pending.sent_at = now;
    }
    assert(s.poll(now) == now + s.pending_command_timeout);
    assert(s._last_vehicle_poll_time == previous && s.vehicles == 2);
    s.accept = true;
    MonoTime admitted = now + 1.seconds;
    assert(s.poll(admitted) > admitted);
    assert(s._last_vehicle_poll_time == admitted && s._retry_poll == s.PollKind.none && s.vehicles == 3);
    s.poll(admitted);
    assert(s.vehicles == 3 && s.charges == 0 && s.climates == 0);

    s.accept = false;
    s._last_poll_time = now - s.poll_idle;
    previous = s._last_poll_time;
    s.poll(now);
    assert(s.charges == 1 && s._last_poll_time == previous);
    s.accept = true;
    s.poll(admitted);
    assert(s.charges == 2 && s._last_poll_time == admitted);

    s._last_climate_poll_time = now - s.climate_poll_interval;
    s.accept = false;
    previous = s._last_climate_poll_time;
    s.poll(now);
    assert(s.climates == 1 && s._last_climate_poll_time == previous);
    s.accept = true;
    s.poll(admitted);
    assert(s.climates == 2 && s._last_climate_poll_time == admitted);

    foreach (ref pending; s._pending_commands)
        pending.sent_at = getTime();
    ubyte[16] uuid, tag;
    assert(s.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_vehicle_state) is null);
    s._pending_commands[0].sent_at -= s.pending_command_timeout;
    assert(s.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_vehicle_state) !is null);

    static class Receiver : TeslaVehicleSession
    {
    nothrow @nogc:
        this() { super(CID(3)); }
        override bool signer_unchanged() => true;
    }
    Receiver receiver = alloc!Receiver();
    scope(exit) free(receiver);
    receiver._phase = receiver.Phase.ready;
    receiver._routing_address[] = 0x22;
    receiver._aes_key[] = 0x44;
    Device vehicle = alloc!Device(StringLit!"session-controls");
    scope(exit) free(vehicle);
    DeviceTable devices;
    devices.insert(vehicle);
    Element* control = alloc_element();
    scope(exit) free(control);
    control.parent = vehicle;
    vehicle.elements ~= control;
    foreach (iteration; 0 .. 8)
    {
        receiver._control_device = vehicle;
        receiver._charging_enabled = control;
        receiver.subscribe_vehicle_control(vehicle, control);
        assert(control.access == Access.read_write);
        assert(vehicle.bindings[0] is receiver);
        if (iteration == 0)
            vehicle.attach_binding(s, control, Access.read_write);
        receiver.unsubscribe_vehicle_controls();
        assert(!receiver._control_device && !receiver._charging_enabled);
        assert(!vehicle.bindings[0]);
        assert(control.access == Access.read_write);
        receiver.unsubscribe_vehicle_controls();
    }
    vehicle.detach_binding(s);
    receiver._control_device = vehicle;
    receiver._charging_enabled = control;
    receiver.subscribe_vehicle_control(vehicle, control);
    receiver.unsubscribe_vehicle_controls();
    assert(control.access == Access.read);
    receiver._control_device = vehicle;
    uuid[] = 0x11;
    tag[] = 0x33;

    TeslaRoutableMessage response;
    response.to_destination.ensure().routing_address.ensure().extend(16)[] = receiver._routing_address[];
    response.from_destination.ensure().domain.set(cast(uint)TeslaDomain.infotainment);
    response.request_uuid.ensure().extend(16)[] = uuid[];
    response.signed_message_status.ensure().signed_message_fault.set(15);

    void deliver()
    {
        Array!ubyte wire;
        wire.resize(buffer_len(response));
        assert(proto_serialise(wire[], response) == wire.length);
        receiver.dispatch_response(wire[]);
    }

    auto pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
    response.request_uuid.value[0] ^= 1;
    deliver();
    assert(pending.active && receiver._phase == receiver.Phase.ready && receiver._auth_failures == 0);
    response.request_uuid.value[0] ^= 1;
    response.from_destination.value.domain.set(cast(uint)TeslaDomain.vehicle_security);
    deliver();
    assert(pending.active && receiver._phase == receiver.Phase.ready);
    response.from_destination.value.domain.set(cast(uint)TeslaDomain.infotainment);
    response.to_destination.value.routing_address.value[0] ^= 1;
    deliver();
    assert(pending.active && receiver._phase == receiver.Phase.ready);
    response.to_destination.value.routing_address.value[0] ^= 1;
    pending.sent_at -= receiver.pending_command_timeout;
    deliver();
    assert(!pending.active && receiver._phase == receiver.Phase.ready);

    foreach (fault; [1u, 2u, 3u, 4u, 7u, 9u, 11u, 25u, 99u])
    {
        pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
        response.signed_message_status.value.signed_message_fault.set(fault);
        deliver();
        assert(!pending.active && receiver._phase == receiver.Phase.ready && receiver._auth_failures == 0);
        assert(receiver._last_authenticated_rx_time == MonoTime.init);
        deliver();
        assert(receiver._auth_failures == 0);
    }

    foreach (fault; [5u, 6u, 15u, 17u, 20u])
    {
        receiver._phase = receiver.Phase.ready;
        pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
        response.signed_message_status.value.signed_message_fault.set(fault);
        deliver();
        assert(!pending.active && receiver._phase == receiver.Phase.failed);
        assert(!receiver.refresh_vehicle_state());
    }

    receiver._phase = receiver.Phase.ready;
    response.signed_message_status.value.signed_message_fault.set(0);
    response.protobuf_message_as_bytes.ensure().extend(1)[0] = 0;
    pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
    response.request_uuid.value[0] ^= 1;
    foreach (i; 0 .. 4)
        deliver();
    assert(receiver._auth_failures == 0);
    response.request_uuid.value[0] ^= 1;
    foreach (i; 0 .. 4)
        deliver();
    assert(receiver._auth_failures == 1 && receiver._phase == receiver.Phase.ready && pending.active);

    response.protobuf_message_as_bytes.value.clear();
    ubyte[12] nonce = 0x55;
    ref signature = response.signature_data.ensure().aes_gcm_response.ensure();
    signature.nonce.ensure().extend(12)[] = nonce[];
    signature.counter.set(1);
    signature.tag.ensure().extend(16)[] = 0;
    Array!ubyte metadata = build_response_metadata(TeslaDomain.infotainment, receiver.name[], 1, 0, tag[], 0);
    SHA256Context digest;
    sha_init(digest);
    sha_update(digest, metadata[]);
    ubyte[32] aad = sha_finalise(digest);
    ubyte[16] response_tag;
    assert(aes_gcm_encrypt(receiver._aes_key[], nonce[], aad[], null, null, response_tag[]).succeeded);
    signature.tag.value[] = response_tag[];
    signature.tag.value[0] ^= 1;
    deliver();
    assert(receiver._auth_failures == 1 && pending.active);
    signature.tag.value[0] ^= 1;
    deliver();
    assert(!pending.active && receiver._auth_failures == 0 && receiver._fault is null);
    assert(receiver._last_authenticated_rx_time != MonoTime.init);
    MonoTime authenticated = receiver._last_authenticated_rx_time;
    deliver();
    assert(receiver._last_authenticated_rx_time == authenticated);

    pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
    response.signed_message_status.value.signed_message_fault.set(15);
    deliver();
    assert(pending.active && receiver._phase == receiver.Phase.ready && receiver._auth_failures == 1);
    metadata = build_response_metadata(TeslaDomain.infotainment, receiver.name[], 1, 0, tag[], 15);
    sha_init(digest);
    sha_update(digest, metadata[]);
    aad = sha_finalise(digest);
    assert(aes_gcm_encrypt(receiver._aes_key[], nonce[], aad[], null, null, response_tag[]).succeeded);
    signature.tag.value[] = response_tag[];
    deliver();
    assert(!pending.active && receiver._phase == receiver.Phase.failed && receiver._auth_failures == 0);

    receiver._phase = receiver.Phase.ready;
    response.signed_message_status.value.signed_message_fault.set(0);
    signature.tag.value[0] ^= 1;
    foreach (i; 0 .. receiver.auth_failure_limit)
    {
        uuid[0] = cast(ubyte)i;
        response.request_uuid.value[] = uuid[];
        pending = receiver.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_charge_state);
        deliver();
        assert(pending.auth_failure_reported);
    }
    assert(receiver._phase == receiver.Phase.failed);

    receiver._phase = receiver.Phase.ready;
    receiver._last_authenticated_rx_time = now;
    receiver._last_rx_time = now + 60.seconds;
    assert(receiver.advance(now + 46.seconds) == CompletionStatus.error);
    assert(receiver._phase == receiver.Phase.failed);
}

unittest
{
    import urt.mem : alloc, free;

    static class Session : TeslaVehicleSession
    {
    nothrow @nogc:
        this() { super(CID(4)); }
        VehicleRetryState retry;
        uint charges, climates;
        override VehicleRetryState* retry_state() => &retry;
        override const(VehicleRetryState)* retry_state() const pure => &retry;
        override bool refresh_charge_state() { ++charges; return true; }
        override bool refresh_climate_state() { ++climates; return true; }
    }
    Session s = alloc!Session();
    scope(exit) free(s);
    TeslaVehicleScanner scanner = alloc!TeslaVehicleScanner(CID(5));
    scope(exit) free(scanner);
    s.attach(scanner, MACAddress(2, 3, 4, 5, 6, 7));
    assert(s.validate());
    s._phase = s.Phase.ready;

    TeslaVehicleSession.PendingCommand pending;
    pending.kind = VehicleCommandKind.get_charge_state;
    s.handle_protocol_fault(7, pending, false);
    assert(!s.retry.failures[VehicleCommandKind.get_charge_state].latched);
    assert(s.retry.failures[VehicleCommandKind.get_charge_state].retry_at > getTime());
    pending.kind = VehicleCommandKind.get_charge_state;
    s.handle_protocol_fault(7, pending, true);
    assert(s.retry.failures[VehicleCommandKind.get_charge_state].latched);
    assert(s.validate() && s._phase == s.Phase.ready);
    assert(s.status_message() == s.retry.status[]);

    MonoTime now = getTime() + s.climate_poll_interval;
    s._last_poll_time = now - s.poll_idle;
    s._last_climate_poll_time = now - s.climate_poll_interval;
    s._last_vehicle_poll_time = now;
    s._retry_poll = s.PollKind.charge;
    assert(s.poll(now) > now);
    assert(s.charges == 0 && s.climates == 1 && s._retry_poll == s.PollKind.none);
    s.retry.failed(VehicleRetryState.index(VehicleCommandKind.get_vehicle_state, 0), "Unsupported drive state", now, true);
    assert(s.select_vehicle_category(now) && s._vehicle_category == 1);
    ubyte[16] uuid, tag;
    auto queued = s.reserve_pending_command(uuid[], tag[], VehicleCommandKind.get_vehicle_state);
    assert(queued && queued.category == 1);
    s._vehicle_category = 2;
    s.handle_protocol_fault(9, *queued, true);
    assert(s.retry.failures[VehicleRetryState.index(VehicleCommandKind.get_vehicle_state, 1)].latched);
    assert(s.select_vehicle_category(now) && s._vehicle_category == 2);

    foreach (fault; [5u, 6u, 15u, 17u, 20u])
    {
        s._phase = s.Phase.ready;
        pending.kind = VehicleCommandKind.get_climate_state;
        s.handle_protocol_fault(fault, pending, false);
        assert(s._phase == s.Phase.failed);
        assert(s.retry_time(VehicleCommandKind.get_climate_state) > getTime());
        s.retry.succeeded(0);
        assert(s.retry_time(VehicleCommandKind.get_climate_state) > getTime());
    }

    pending.kind = VehicleCommandKind.get_charge_state;
    s.handle_protocol_fault(4, pending, true);
    assert(!s.validate() && s._phase == s.Phase.failed);
    s.retry = VehicleRetryState.init;
    s.reset_retry_status();
    assert(s.validate() && !s.retry.status.length && s._fault is null);
    s._phase = s.Phase.awaiting_approval;
    s._approval_deadline = now;
    s._last_rx_time = now;
    assert(s.advance(now) == CompletionStatus.error);
    assert(!s.validate() && !s.retry.failures[0].latched);
}
