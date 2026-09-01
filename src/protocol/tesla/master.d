module protocol.tesla.master;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.si;
import urt.string;
import urt.string.format;
import urt.time;
import urt.util;

import manager;
import manager.base;
import manager.collection;

import protocol.tesla;
import protocol.tesla.binding;
import protocol.tesla.iface;
import protocol.tesla.twc;

import router.iface;
import router.iface.packet;

//version = DebugTWCMaster;

nothrow @nogc:


alias CentiAmps = Quantity!(ushort, ScaledUnit(Ampere, -2));


// Runs the TWC master role on a bus. Slaves that answer the link-ready
// announcement are adopted as chargers, and each discovered charger spawns a
// TeslaTWCBinding (and Device) named for its 16-bit bus id, e.g. `twc_14fd`.
class TeslaTWCMaster : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface));
nothrow @nogc:

    enum type_name = "tesla-twc-master";
    enum path = "/protocol/tesla/twc";
    enum collection_id = CollectionType.tesla_twc;

    enum ChargerState : ubyte
    {
        unknown,
        idle,
        stopped,
        scheduled,
        charging,
        error
    }

    struct Charger
    {
    nothrow @nogc:
        String name;
        ushort id;

        TeslaTWCBinding binding;

        ubyte req_seq;
        bool link_ready;
        ubyte sig_byte; // we don't know what this is for...

        ubyte heartbeat_sent;
        ubyte heartbeat_received;

        TWCState state;

        ubyte flags; // 1 = got state, 2 = got charge info, 4 = got sn, 10 = car connected, 20 = got vin1, 40 = got vin2, 80 = got vin3
        ubyte vin_attempts;

        // A plugged-but-sleeping car also idles at Ready+0A, so presence is latched on VIN
        // evidence and only released after repeated zero-byte VIN re-polls confirm real unplug.
        bool verify_presence;
        ubyte verify_zero_count;

        ushort hard_max_current;      // the binding's configured ceiling; control.max can only lower it
        ushort specified_max_current; // a runtime charge limit from control.max; 0 = none
        ushort device_max_current;    // the maximum current supported by the charger
        ushort target_current;        // the current we're trying to charge with
        ushort charge_current_target; // the current the car is requesting

        ushort current;
        ushort voltage1;
        ushort voltage2;
        ushort voltage3;
        ushort total_power;
        ushort power1;
        ushort power2;
        ushort power3;

        uint lifetime_energy;

        char[11] serial_number;
        char[17] vin;

        // the TWC protocol cannot express less than 5A; "stop" must come from the car side
        // (or by disabling the appliance), so delivered current is always max(setpoint, floor)
        enum ushort min_current = 500;

        // device_max_current arrives in SlaveLinkReady; until then the configured
        // limits stand alone so optimistically-adopted chargers have a valid clamp
        ushort max_current() const pure
        {
            ushort m = hard_max_current;
            if (device_max_current && (!m || device_max_current < m))
                m = device_max_current;
            if (specified_max_current && (!m || specified_max_current < m))
                m = specified_max_current;
            return m;
        }

        ushort charge_current() const pure
            => max(min_current, min(max_current, target_current));

        ChargerState charger_state() const pure
        {
            switch (state)
            {
                case TWCState.Ready:
                    // it seems that if the charger is reporting a current, a car is connected
                    if (charge_current_target > 0)
                        return ChargerState.stopped;
                    return ChargerState.idle; // not sure if it's possible that the car is plugged in?
                case TWCState.Charging:
                case TWCState.RaisingCurrent:
                case TWCState.LoweringCurrent:
                case TWCState.LimitCurrent:
                case TWCState._A:
                    return ChargerState.charging;
                case TWCState.PluggedIn_DoNotCharge:
                case TWCState.StartingToCharge:
                case TWCState.Busy: // ???? what is this?
                    return ChargerState.stopped;
                case TWCState.PluggedIn_ChargeScheduled:
                    return ChargerState.scheduled;
                case TWCState.Error:
                    return ChargerState.error;
                default:
                    return ChargerState.unknown;
            }
        }
    }

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaTWCMaster, id, flags);

        static ubyte id_counter = 0;
        _id_on_bus = cast(ushort)(0x7770 + id_counter++);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface.get is value)
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

    override const(char)[] status_message() const
    {
        if (!_iface || !_iface.running)
            return "Waiting for interface";
        return super.status_message();
    }

protected:
    override bool validate() const pure
        => _iface !is null;

    override CompletionStatus startup()
    {
        BaseInterface i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        import urt.crc;
        _sig = cast(ubyte)calculate_crc!(Algorithm.crc32_iso_hdlc)(i.name[]);

        i.subscribe(&incoming_packet, PacketFilter(type: PacketType.tesla_twc));
        i.subscribe(&iface_state_change);
        _subscribed = true;

        _announced = false;
        _last_link_status = LinkStatus.down;
        g_app.schedule(getTime() + tick_interval, &tick);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        g_app.cancel(&tick);
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        // chargers survive a restart; adopted slaves resume heartbeating immediately
        return CompletionStatus.complete;
    }

package:
    Charger* find_charger(ushort slave_id)
    {
        foreach (ref c; _chargers)
        {
            if (c.id == slave_id)
                return &c;
        }
        return null;
    }

    Charger* adopt(ushort slave_id, TeslaTWCBinding binding, ushort hard_max)
    {
        Charger* c = find_charger(slave_id);
        if (!c)
        {
            c = add_charger(slave_id);
            // optimistic adoption: heartbeat immediately rather than wait for
            // SlaveLinkReady; a present slave answers heartbeats, and LinkReady
            // merely refines device_max_current/sig whenever it arrives
            if (_announced)
                c.link_ready = true;
        }
        c.binding = binding;
        c.hard_max_current = hard_max;
        return c;
    }

    void detach(ushort slave_id, TeslaTWCBinding binding)
    {
        Charger* c = find_charger(slave_id);
        if (c && c.binding is binding)
            c.binding = null;
    }

    void set_target_current(ushort slave_id, ushort current)
    {
        if (Charger* c = find_charger(slave_id))
            c.target_current = current;
    }

    void set_max_current(ushort slave_id, ushort current)
    {
        if (Charger* c = find_charger(slave_id))
            c.specified_max_current = current;
    }

private:
    enum Duration tick_interval = 400.msecs;

    ObjectRef!BaseInterface _iface;
    bool _subscribed;

    ushort _id_on_bus;
    ubyte _sig;
    bool _announced;
    LinkStatus _last_link_status = LinkStatus.down;

    byte _round_robin_index;

    Array!Charger _chargers;

    Charger* add_charger(ushort slave_id)
    {
        Charger* c = &_chargers.pushBack();
        c.id = slave_id;
        c.name = tformat("twc_{0,04x}", slave_id).make_string();
        c.target_current = ushort.max;
        c.hard_max_current = 3200; // until a binding adopts and states its ceiling
        return c;
    }

    Charger* discover(ushort slave_id)
    {
        Charger* c = add_charger(slave_id);
        log.info("discovered charger '", c.name[], "' on bus");

        if (!Collection!TeslaTWCBinding().get(c.name[]))
        {
            TeslaTWCBinding b = Collection!TeslaTWCBinding().alloc(c.name[], ObjectFlags.dynamic);
            if (b)
            {
                b.master = this;
                b.slave_id = slave_id;
                b.device = c.name;
                Collection!TeslaTWCBinding().add(b);
            }
            else
                log.error("could not spawn binding for charger '", c.name[], "' (name collision?)");
        }
        return c;
    }

    void tick(MonoTime scheduled)
    {
        g_app.schedule(scheduled + tick_interval, &tick);

        BaseInterface i = _iface.get;
        if (!i)
            return;
        LinkStatus link_status = i.status.link_status;
        if (link_status != _last_link_status && link_status == LinkStatus.up && !_announced)
        {
            // announce master presence on first bring-up only; on a link flap we just resume
            // heartbeating - a slave that actually rebooted re-announces itself, and waiting
            // for SlaveLinkReady costs the slave's own master-loss timeout (minutes)
            _announced = true;
            _round_robin_index = -10;
        }
        _last_link_status = link_status;
        if (link_status != LinkStatus.up)
            return;

        // we will immitate the bootup sequence... but I don't really know why?
        // I can't really see evidence the slaves care about this!
        if (_round_robin_index < 0)
        {
            ubyte[15] message = 0;
            message[0..2] = ushort(_round_robin_index++ < -5 ? 0xFCE1 : 0xFBE2).nativeToBigEndian;
            message[2..4] = _id_on_bus.nativeToBigEndian;
            message[4] = _sig;
            send_twc_message(TWCFrame.broadcast, message[]);

            // adopted chargers heartbeat immediately rather than wait for SlaveLinkReady
            if (_round_robin_index == 0)
            {
                foreach (ref c; _chargers)
                    c.link_ready = true;
            }
            return;
        }

        if (_chargers.empty)
            return;

        // iterate through the ready chargers...
        Charger* c = &_chargers[_round_robin_index++];
        if (_round_robin_index >= _chargers.length)
            _round_robin_index = 0;

        if (!c.link_ready)
            return; // TODO: preferably, advance to the next charger...
        if (c.heartbeat_received != c.heartbeat_sent)
            c.req_seq = 0; // send heartbeats until the device responds

        ubyte[15] message = 0;
        message[2..4] = _id_on_bus.nativeToBigEndian;
        message[4..6] = c.id.nativeToBigEndian;

        // command selection logic...
        if ((c.req_seq & 1) == 0)
        {
            if (c.heartbeat_sent - c.heartbeat_received >= 20)
            {
                // slave stopped responding; keep heartbeating (it answers again the moment it
                // returns, and a rebooted slave re-announces) but re-arm the counters so this
                // stall check can re-fire instead of saturating
                debug writeDebug("Charger ", c.name, " not responding");
                c.heartbeat_sent = 0;
                c.heartbeat_received = 0;
                c.req_seq = 0;
            }

            version (DebugTWCMaster)
                writeDebugf("Charger {0}({1,04x}) - SN: {2}\n   {3}/{4}/{5}V  {6}A({7}A)  {8}W - {9}\n   VIN {10}", c.name, c.id, c.serial_number[], c.voltage1, c.voltage2, c.voltage3, cast(float)c.current/100, cast(float)c.max_current / 100, c.total_power, c.charger_state(), c.vin[]);

            message[0..2] = ushort(0xFBE0).nativeToBigEndian;

            switch (c.state)
            {
                case TWCState.Ready:
                    if (c.charge_current_target == 0)
                    {
                        // the charger is idle...
                        break;
                    }
                    goto case;
                case TWCState.PluggedIn_DoNotCharge:
                case TWCState.PluggedIn_ChargeScheduled:
                    // we'll advertise the available charge current...
                    message[6] = TWCState.Busy;
                    message[7..9] = c.max_current.nativeToBigEndian;
                    break;
                case TWCState.StartingToCharge:
                    // car is requesting to charge; accept the request
                    message[6] = TWCState.StartingToCharge;
                    message[7..9] = c.max_current.nativeToBigEndian;
                    break;
                case TWCState.Charging:
                    if (c.charge_current != c.charge_current_target)
                    {
                        message[6] = TWCState.LimitCurrent;
                        message[7..9] = c.charge_current.nativeToBigEndian;
                    }
                    break;
                default:
                    // what goes on?
                    break;
            }

            ++c.heartbeat_sent;
            ++c.req_seq;
        }
        else
        {
            __gshared static ushort[5] reqs = [0xFBEB, 0xFBED, 0xFBEE, 0xFBEF, 0xFBF1];

            byte item = c.req_seq >> 1;

            if (item == 1)
            {
                if (c.flags & 4)
                    ++item;
            }
            if (item >= 2 && c.verify_presence)
                item = 2; // re-poll VIN1 to confirm the car is still plugged in
            else if (item >= 2 && ((c.flags & 0x10) == 0 || (c.flags & 0xF0) == 0xF0 || c.vin_attempts >= 10))
                item = 0;
            else
            {
                if (item == 2 && (c.flags & 0xF0) > 0x10)
                    ++item;
                if (item == 3 && (c.flags & 0xF0) > 0x30)
                    ++item;
            }

            // DO we ever need FDEC??? we don't know that it is!
            // will other chargers on the same bus find it interesting?

            message[0..2] = reqs[item].nativeToBigEndian;
            if (++item >= 5)
                item = 0;

            c.req_seq = cast(ubyte)(item << 1);
        }

        // send request
        send_twc_message(c.id, message[]);
    }

    void send_twc_message(ushort dst, const(void)[] message)
    {
        Packet p;
        ref TWCFrame twc = p.init!TWCFrame(message[]);
        twc.src = _id_on_bus;
        twc.dst = dst;
        _iface.forward(p);
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data)
    {
        ref const twc = p.hdr!TWCFrame;

        TWCMessage msg;
        if (!parse_twc_message(cast(ubyte[])p.data, msg))
            return;

        Charger* slave = find_charger(msg.sender);
        if (!slave)
        {
            // only a slave's link-ready announcement introduces a new charger;
            // anything else is another master, or chatter we can't attribute
            if (twc.dst != TWCFrame.broadcast || msg.type != TWCMessageType.SlaveLinkReady)
                return;
            slave = discover(msg.sender);
        }

        if (twc.dst == TWCFrame.broadcast)
        {
            switch (msg.type)
            {
                case TWCMessageType.SlaveLinkReady:
                    // always refresh: with optimistic adoption this may arrive while we're
                    // already heartbeating (slave rebooted, or first contact after our boot)
                    slave.sig_byte = msg.link_ready.signature;
                    slave.device_max_current = msg.link_ready.amps;
                    if (!slave.link_ready)
                    {
                        slave.link_ready = true;
                        slave.heartbeat_sent = 0;
                        slave.heartbeat_received = 0;
                    }
                    break;
                case TWCMessageType.ChargeInfo:
                    slave.lifetime_energy = msg.charge_info.lifetime_energy;
                    slave.voltage1 = msg.charge_info.voltage1;
                    slave.voltage2 = msg.charge_info.voltage2;
                    slave.voltage3 = msg.charge_info.voltage3;
                    // the current in this message is more closely temporally aligned, but it's only 500mA precision
//                        slave.power1 = cast(ushort)(msg.charge_info.voltage1 * msg.charge_info.current / 2);
//                        slave.power2 = cast(ushort)(msg.charge_info.voltage2 * msg.charge_info.current / 2);
//                        slave.power3 = cast(ushort)(msg.charge_info.voltage3 * msg.charge_info.current / 2);
                    // the current we recorded is half a second old, but it's 10mA precision
                    slave.power1 = cast(ushort)(msg.charge_info.voltage1 * slave.current / 100);
                    slave.power2 = cast(ushort)(msg.charge_info.voltage2 * slave.current / 100);
                    slave.power3 = cast(ushort)(msg.charge_info.voltage3 * slave.current / 100);
                    slave.total_power = cast(ushort)(slave.power1 + slave.power2 + slave.power3);
                    slave.flags |= 0x2;
                    break;
                case TWCMessageType._FDEC:
                    break;
                case TWCMessageType.TWCSerialNumber:
                    slave.serial_number[0..11] = msg.sn[0..11];
                    slave.flags |= 0x4;
                    break;
                case TWCMessageType.VIN1:
                    if (slave.verify_presence)
                    {
                        if (*cast(uint*)msg.vin.ptr == 0)
                        {
                            if (++slave.verify_zero_count >= 3)
                            {
                                debug writeDebug("Car disconnected from ", slave.name);
                                slave.flags &= 0xF;
                                slave.vin[] = 0;
                                slave.vin_attempts = 0;
                                slave.verify_presence = false;
                                slave.verify_zero_count = 0;
                            }
                        }
                        else
                        {
                            if (slave.vin[0..7] != msg.vin[])
                            {
                                // a different car since we last looked; recollect the rest
                                slave.vin[0..7] = msg.vin[];
                                slave.flags = cast(ubyte)((slave.flags | 0x20) & ~0xC0);
                                slave.vin_attempts = 0;
                            }
                            slave.verify_presence = false;
                            slave.verify_zero_count = 0;
                        }
                        break;
                    }
                    slave.vin[0..7] = msg.vin[];
                    if (*cast(uint*)msg.vin.ptr == 0)
                    {
                        ++slave.vin_attempts;
                        slave.req_seq = 0;
                    }
                    else
                        slave.flags |= 0x20;
                    break;
                case TWCMessageType.VIN2:
                    slave.vin[7..14] = msg.vin[];
                    if (*cast(uint*)msg.vin.ptr == 0)
                    {
                        ++slave.vin_attempts;
                        slave.req_seq = 0;
                    }
                    else
                        slave.flags |= 0x40;
                    break;
                case TWCMessageType.VIN3:
                    slave.vin[14..17] = msg.vin[0..3];
                    if (*cast(uint*)msg.vin.ptr == 0)
                    {
                        ++slave.vin_attempts;
                        slave.req_seq = 0;
                    }
                    else
                        slave.flags |= 0x80;
                    break;
                default:
                    // unexpected message?
//                        debug writeWarning("Unexpected message!");
                    break;
            }
        }
        else if (twc.dst == _id_on_bus && msg.type == TWCMessageType.SlaveHeartbeat)
        {
            // record heartbeat response state...
            slave.state = msg.heartbeat.state;
            slave.charge_current_target = msg.heartbeat.current;
            slave.current = msg.heartbeat.current_in_use;

            slave.flags |= 0x1;

            // Ready+0A is ambiguous: unplugged, or a plugged car that went to sleep.
            // With VIN evidence on record we hold presence and verify by re-polling VIN1;
            // without any VIN we have nothing to verify against, so treat it as unplugged.
            if (msg.heartbeat.state == TWCState.Ready && msg.heartbeat.current == 0)
            {
                if (slave.flags & 0xE0)
                {
                    if (!slave.verify_presence)
                    {
                        slave.verify_presence = true;
                        slave.verify_zero_count = 0;
                    }
                }
                else if (slave.flags & 0x10)
                {
                    debug writeDebug("Car disconnected from ", slave.name);
                    slave.flags &= 0xF;
                    slave.vin_attempts = 0;
                }
            }
            else
            {
                debug if ((slave.flags & 0x10) == 0)
                    writeDebug("Car connected to ", slave.name);

                slave.flags |= 0x10;
                if (slave.verify_presence)
                {
                    slave.verify_presence = false;
                    slave.verify_zero_count = 0;
                }
            }

            slave.heartbeat_received = slave.heartbeat_sent;
            if (slave.heartbeat_received >= 128)
            {
                // handle graceful overflow...
                slave.heartbeat_sent -= slave.heartbeat_received;
                slave.heartbeat_received = 0;
            }
        }

        if (slave.binding)
            slave.binding.push_samples(*slave);
    }
}
