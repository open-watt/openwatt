module protocol.tesla.vehicle_scanner;

import urt.array;
import urt.log;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device;
import manager.secret;

import protocol.ble;
import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;
import protocol.tesla.vehicle_codec;
import protocol.tesla.vehicle_session;

import router.iface;
import router.iface.mac;
import router.iface.packet;

//version = DebugTeslaScanner;

nothrow @nogc:


// ---------------------------------------------------------------------------
// TeslaVehicleScanner - the "server-like" protocol object.
//
// One per install (typically). User-configured (Collection-managed). Owns the
// shared Secret and the BLE interface used to scan for vehicles.
// Discovers known-VIN cars via BLE adverts and dynamically spawns
// TeslaVehicleSession entries (registered with ObjectFlags.dynamic|temporary)
// for each active vehicle, the way TCPServer spawns TCPStream instances.
//
// Config shape:
//   /secret/add  name=tesla  kind=ec_p256  key_file=/etc/openwatt/tesla.pem
//   /protocol/tesla/vehicle-scanner/add  name=tesla  iface=ble1  secret=tesla
// ---------------------------------------------------------------------------
class TeslaVehicleScanner : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("iface", iface),
                                 Prop!("secret", secret),
                                 Prop!("vins", vins));
nothrow @nogc:

    enum type_name = "tesla-vehicle-scanner";
    enum path = "/protocol/tesla/vehicle-scanner";
    enum collection_id = CollectionType.tesla_vehicle_scanner;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaVehicleScanner, id, flags);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        restart();
    }

    inout(Secret) secret() inout pure
        => _secret.get;
    void secret(Secret value)
    {
        if (_secret.get is value)
            return;
        _secret = value;
        restart();
    }

    // Comma-separated list of known VINs. Each VIN materialises a root Device
    // and matching dynamic Appliance; adverts whose hashed local name matches
    // it trigger a session spawn.
    Array!String vins() const
    {
        auto r = Array!String(Reserve, _vins.length);
        foreach (ref v; _vins[])
            r ~= v.vin;
        return r;
    }
    void vins(const(char)[][] value...)
    {
        import apps.energy.vehicle : vehicle_appliance_for;

        Array!VinEntry updated;
        foreach (v; value)
        {
            MutableString!0 t = v;
            t[].to_upper();
            if (!valid_vin(t[]))
            {
                log.warning("ignoring malformed Tesla VIN '", t[], "'");
                continue;
            }

            bool duplicate;
            foreach (ref existing; updated[])
                if (existing.vin[] == t[])
                {
                    duplicate = true;
                    break;
                }
            if (duplicate)
                continue;

            ubyte[8] hash;
            tesla_vin_hash(t[], hash);

            if (!vehicle_appliance_for(t[]))
                continue;
            Device* vehicle = t[] in g_app.devices;
            if (!vehicle)
                continue;
            version (DebugTeslaScanner)
                log.trace("registered VIN '", t[], "' -> hash [ ", cast(void[])hash[], " ]");
            updated ~= VinEntry(String(t.move), hash, *vehicle);
        }

        _vins = updated.move;

        // VIN configuration owns live discovery sessions, not the persistent
        // Device, Appliance, or recorded series. Removing a VIN stops access to
        // that vehicle while leaving the collected dataset intact.
        foreach (session; Collection!TeslaVehicleSession().values)
            if (session.scanner is this && !component_for_vin(session.vin))
                session.destroy();
    }

    // Vehicle Component published for `vin`, or null if the VIN isn't registered.
    Component component_for_vin(const(char)[] vin)
    {
        foreach (ref e; _vins[])
        {
            if (e.vin[] == vin)
                return e.component;
        }
        return null;
    }

    override const(char)[] status_message() const
    {
        if (!_iface || !_iface.running)
            return "Waiting for BLE interface";
        if (_vins.empty)
            return "No VINs registered";
        return super.status_message();
    }

protected:
    override bool validate() const
    {
        const Secret s = _secret.get;
        return _iface !is null
            && (cast(const(BLEInterface))_iface.get) !is null
            && s !is null
            && s.kind == SecretKind.ec_p256;
    }

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            PacketFilter filter;
            filter.type = PacketType.ble;
            _iface.subscribe(&incoming_packet, filter);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;

            version (DebugTeslaScanner)
                log.trace("scanner subscribed to BLE adverts on '", _iface.get.name[], "', watching ", _vins.length, " VIN(s)");
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        // Sessions hold a back-reference to us, so they cannot outlive us.
        foreach (s; Collection!TeslaVehicleSession().values)
        {
            if (s.scanner is this)
                s.destroy();
        }

        return CompletionStatus.complete;
    }

    // Drop sessions for vehicles that have stopped advertising. Without this a
    // car that drives away leaves a session reconnecting on backoff forever.
    override void update()
    {
        if (!_secret)
        {
            restart();
            return;
        }

        MonoTime now = getTime();
        foreach (s; Collection!TeslaVehicleSession().values)
        {
            if (s.scanner !is this)
                continue;

            // A connected vehicle need not continue advertising.
            BLEClient client = s.client;
            if (client && client.running)
                continue;

            if (now - s.last_seen > out_of_range_timeout)
            {
                log.info("Tesla vehicle '", s.name[], "' out of range, ending session");
                s.destroy();
            }
        }
    }

package:
    // Create a new TeslaVehicleSession for the given vehicle. The session owns
    // its own BLEClient lifecycle (created in startup, destroyed in shutdown) so
    // restart() cleanly reconnects. Returns null on allocation failure.
    TeslaVehicleSession spawn_session(const(char)[] vin, MACAddress peer)
    {
        TeslaVehicleSession s = Collection!TeslaVehicleSession().alloc(vin, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
        if (!s)
        {
            log.error("could not spawn session for VIN '", vin, "' (name collision?)");
            return null;
        }
        s.attach(this, peer);
        Collection!TeslaVehicleSession().add(s);
        return s;
    }

private:
    // A parked car still advertises, so silence this long means it has left.
    enum Duration out_of_range_timeout = 120.seconds;

    struct VinEntry
    {
        String vin;
        ubyte[8] hash;
        Component component;  // Root Vehicle Device for this VIN
    }

    ObjectRef!BaseInterface _iface;
    ObjectRef!Secret _secret;
    Array!VinEntry _vins;
    bool _subscribed;

    void incoming_packet(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        if (p.type != PacketType.ble)
            return;
        ref f = p.hdr!BLEFrame;
        if (f.kind != BLEFrameKind.advert)
            return;
        switch (f.adv_type)
        {
            case BLEAdvPDU.adv_ind:
            case BLEAdvPDU.adv_nonconn_ind:
            case BLEAdvPDU.adv_scan_ind:
            case BLEAdvPDU.adv_direct_ind:
            case BLEAdvPDU.scan_rsp:
                break;
            default:
                return;
        }

        version (DebugTeslaScanner)
            log.trace("BLE adv pdu ", f.adv_type, " from ", f.src);

        if (_vins.empty)
        {
            version (DebugTeslaScanner)
                log.trace("adv from ", f.src, " ignored: no VINs registered");
            return;
        }

        const(char)[] local_name = advert_local_name(cast(const(ubyte)[])p.data);
        if (local_name.length != TESLA_LOCAL_NAME_LEN)
        {
            version (DebugTeslaScanner)
                log.trace("adv from ", f.src, " local name '", local_name, "' len ", local_name.length,
                          " != Tesla name len ", TESLA_LOCAL_NAME_LEN);
            return;
        }

        ubyte[8] hash;
        if (!parse_tesla_local_name(local_name, hash))
        {
            version (DebugTeslaScanner)
                log.trace("adv from ", f.src, " name '", local_name, "' is not a Tesla 'S<hex>C' name");
            return;
        }

        foreach (ref e; _vins[])
        {
            if (e.hash[] != hash[])
                continue;

            // Already have a session for this VIN; just note the car is still here.
            if (TeslaVehicleSession s = Collection!TeslaVehicleSession().get(e.vin[]))
            {
                s.mark_seen(f.src);
                return;
            }

            log.info("Tesla vehicle '", e.vin[], "' seen at ", f.src, ", spawning session");
            spawn_session(e.vin[], f.src);
            return;
        }

        version (DebugTeslaScanner)
            log.trace("adv from ", f.src, " is a Tesla, hash [ ", cast(void[])hash[], " ] matches no registered VIN");
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    const(char)[] advert_local_name(const(ubyte)[] payload) pure
    {
        size_t offset;
        while (offset + 1 < payload.length)
        {
            ubyte length = payload[offset++];
            if (length == 0 || offset + length > payload.length)
                break;

            ubyte type = payload[offset];
            if (type == ADType.complete_local_name || type == ADType.shortened_local_name)
                return cast(const(char)[])payload[offset + 1 .. offset + length];
            offset += length;
        }
        return null;
    }

    bool valid_vin(const(char)[] vin) pure
    {
        if (vin.length != 17)
            return false;
        foreach (c; vin)
        {
            bool digit = c >= '0' && c <= '9';
            bool letter = (c >= 'A' && c <= 'H')
                       || (c >= 'J' && c <= 'N')
                       || c == 'P'
                       || (c >= 'R' && c <= 'Z');
            if (!digit && !letter)
                return false;
        }
        return true;
    }
}
