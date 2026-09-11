module protocol.tesla.master;

import urt.array;
import urt.endian;
import urt.log;
import urt.si;
import urt.string;
import urt.string.format;
import urt.time;
import urt.util;

import manager;
import manager.base;
import manager.collection;

import protocol.tesla.binding;
import protocol.tesla.iface;
import protocol.tesla.twc;

import router.iface;
import router.iface.packet;
import router.stream;

//version = DebugTWCMaster;

nothrow @nogc:


alias CentiAmps = Quantity!(ushort, ScaledUnit(Ampere, -2));


class TeslaTWCMaster : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("stream", stream),
                                 Prop!("max-current", max_current));
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
        ObjectRef!TeslaTWCBinding binding;
        uint lifetime_energy;

        ushort id;
        ushort allocation;
        ushort offered_current;
        ushort reserved_current;
        ushort specified_max_current; // 0 = no runtime cap
        ushort device_max_current;
        ushort target_current;
        ushort charge_current_target;
        ushort current;
        ushort voltage1;
        ushort voltage2;
        ushort voltage3;
        ushort total_power;
        ushort power1;
        ushort power2;
        ushort power3;

        ubyte req_seq;
        ubyte heartbeat_sent;
        ubyte heartbeat_received;
        TWCState state;
        ubyte flags; // 1 = state, 2 = charge info, 4 = sn, 10 = connected, 20/40/80 = vin parts
        ubyte vin_attempts;
        ubyte verify_zero_count;
        bool verify_presence;

        char[11] serial_number;
        char[17] vin;

        enum ushort min_current = 500;

        ushort demand() const pure
        {
            ushort ceiling = specified_max_current ? min(specified_max_current, device_max_current) : device_max_current;
            return ceiling >= min_current ? min(ceiling, max(min_current, target_current)) : 0;
        }

        void acknowledge(ushort accepted, ushort measured) pure
        {
            charge_current_target = accepted;
            current = measured;
            if (accepted == offered_current)
                reserved_current = max(offered_current, measured);
            else
                reserved_current = max(reserved_current, max(accepted, measured));
        }

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

        import manager.system : node_id;
        _id_on_bus = cast(ushort)node_id();
        if (_id_on_bus == 0 || _id_on_bus == TWCFrame.broadcast)
            _id_on_bus = 0x7777;
    }


    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (!_stream && _iface.get is value)
            return;
        release_iface();
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    inout(Stream) stream() inout pure
        => _stream;
    void stream(Stream value)
    {
        if (_stream.get is value)
            return;
        release_iface();
        _stream = value;
        mark_set!(typeof(this), "stream")();
        restart();
    }

    final Amps max_current() const pure
        => Amps(_max_current / 100.0f);
    final const(char)[] max_current(Amps value)
    {
        if (!(value.value >= 5 && value.value <= ushort.max / 100.0f))
            return "max-current must be between 5A and 655.35A";
        _max_current = (cast(CentiAmps)value).value;
        mark_set!(typeof(this), "max-current")();
        rebalance();
        return null;
    }

    override const(char)[] status_message() const
    {
        if (_state == State.init_failed || _state == State.failure)
            return super.status_message();
        if (!_iface || !_iface.running)
            return "Waiting for interface";
        if (_role == BusRole.listening)
            return "Listening for other masters";
        if (_role == BusRole.standby)
            return _standby_status ? _standby_status : "Standing by: another master on bus";
        return super.status_message();
    }

protected:
    override bool validate() const pure
        => _iface !is null || _stream !is null;

    override CompletionStatus startup()
    {
        if (_stream && !_iface)
        {
            const(char)[] n = Collection!BaseInterface().generate_name(name[]);
            TeslaInterface ti = Collection!TeslaInterface().alloc(n, ObjectFlags.dynamic);
            if (!ti)
            {
                log.error("could not create TWC interface '", n, "'");
                return CompletionStatus.error;
            }
            ti.stream = _stream.get;
            Collection!TeslaInterface().add(ti);
            _iface = ti;
        }

        BaseInterface i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        MonoTime now = getTime();

        if (!_subscribed)
        {
            import urt.crc;
            _sig = cast(ubyte)calculate_crc!(Algorithm.crc32_iso_hdlc)(i.name[]);

            i.subscribe(&incoming_packet, PacketFilter(type: PacketType.tesla_twc));
            i.subscribe(&iface_state_change);
            _subscribed = true;

            set_role(BusRole.listening);
            _listen_deadline = now + listen_window;
            foreach (ref c; _chargers)
                c.flags &= ~1;
        }

        if (_collision)
        {
            _collision = false;
            _listen_deadline = now + listen_window;
            log.error("config error: another master on the bus uses our id ", tformat("{0,04x}", _id_on_bus));
            _fail_reason = "config error: id collision on bus";
            return CompletionStatus.error;
        }

        // The listen window only counts link-up time.
        if (i.status.link_status != LinkStatus.up)
        {
            _listen_deadline = now + listen_window;
            return CompletionStatus.continue_;
        }
        if (now < _listen_deadline)
            return CompletionStatus.continue_;

        if (_other_master_heard != MonoTime() && now - _other_master_heard < takeover_timeout)
            set_role(BusRole.standby);
        else
        {
            set_role(BusRole.active);
            _round_robin_index = -10;
        }

        g_app.schedule(now + tick_interval, &tick);
        return CompletionStatus.complete;
    }

    override void online()
    {
        super.online();
        refresh_binding_access();
    }

    override void offline()
    {
        refresh_binding_access();
        super.offline();
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
        if (_stream)
        {
            if (BaseInterface i = _iface.get)
                i.destroy();
            _iface = null;
        }
        return CompletionStatus.complete;
    }

package:
    bool has_agency() const pure
        => running && _role == BusRole.active;

    Charger* find_charger(ushort slave_id)
    {
        foreach (ref c; _chargers)
        {
            if (c.id == slave_id)
                return &c;
        }
        return null;
    }

    Charger* adopt(ushort slave_id, TeslaTWCBinding binding)
    {
        Charger* c = find_charger(slave_id);
        if (c && c.binding && c.binding.get !is binding)
            return null;
        if (!c)
            c = add_charger(slave_id);
        c.binding = binding;
        rebalance();
        return c;
    }

    void detach(ushort slave_id, TeslaTWCBinding binding)
    {
        Charger* c = find_charger(slave_id);
        if (c && c.binding.get is binding)
            c.binding = null;
    }

    void set_target_current(ushort slave_id, ushort current)
    {
        if (Charger* c = find_charger(slave_id))
            c.target_current = current;
        rebalance();
    }

    void set_cap(ushort slave_id, ushort current)
    {
        if (Charger* c = find_charger(slave_id))
            c.specified_max_current = current;
        rebalance();
    }

private:
    enum Duration tick_interval = 400.msecs;
    enum Duration takeover_silence = 15.seconds;
    enum Duration echo_grace = 2.seconds;

    enum BusRole : ubyte
    {
        listening,
        active,
        standby
    }

    ObjectRef!BaseInterface _iface;
    ObjectRef!Stream _stream;
    bool _subscribed;

    ushort _max_current = 3200;
    ushort _id_on_bus;
    ubyte _sig;
    BusRole _role;
    bool _collision;

    ushort _other_master;
    MonoTime _other_master_heard;
    MonoTime _listen_deadline;
    MonoTime _last_tx;
    char[44] _status_buf;
    const(char)[] _standby_status;

    int _round_robin_index;

    Array!Charger _chargers;

    // two of ours standing off would otherwise take over in lockstep and collide forever
    Duration takeover_timeout() const pure
        => takeover_silence + msecs((_id_on_bus & 0xF) * 400);

    Duration listen_window() const pure
        => 5.seconds + takeover_timeout - takeover_silence;

    // only the stream-mode interface is ours to destroy; a user's is merely released
    void release_iface()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        if (_stream)
        {
            if (BaseInterface i = _iface.get)
                i.destroy();
        }
        _iface = null;
        _stream = null;
        _other_master = 0;
        _other_master_heard = MonoTime();
        _standby_status = null;
        _collision = false;
    }

    Charger* add_charger(ushort slave_id)
    {
        Charger* c = &_chargers.pushBack();
        c.id = slave_id;
        c.name = tformat("twc_{0,04x}", slave_id).make_string();
        c.target_current = ushort.max;
        return c;
    }

    Charger* discover(ushort slave_id)
    {
        Charger* c = add_charger(slave_id);
        log.info("discovered charger '", c.name[], "' on bus");

        foreach (binding; Collection!TeslaTWCBinding().values)
        {
            if (binding.master is this && binding.slave_id == slave_id)
                return c;
        }

        c.name = Collection!TeslaTWCBinding().generate_name(c.name[]).make_string();
        TeslaTWCBinding b = Collection!TeslaTWCBinding().alloc(c.name[], ObjectFlags.dynamic);
        if (b)
        {
            b.master = this;
            b.slave_id = slave_id;
            b.device = c.name;
            Collection!TeslaTWCBinding().add(b);
        }
        else
            log.error("could not spawn binding for charger '", c.name[], "'");
        return c;
    }

    void set_role(BusRole role)
    {
        _role = role;
        refresh_binding_access();
    }

    void refresh_binding_access()
    {
        foreach (ref c; _chargers)
            if (TeslaTWCBinding binding = c.binding.get)
                binding.refresh_access(has_agency);
    }

    void rebalance()
    {
        uint remaining = _max_current;
        foreach (ref c; _chargers)
            c.allocation = 0;
        uint eligible;
        foreach (ref c; _chargers)
            if ((c.flags & 1) && c.demand >= Charger.min_current)
                ++eligible;
        // TODO: admission and stop policy when the fleet cannot fit its minimum grants.
        if (eligible * Charger.min_current > remaining)
            return;
        foreach (ref c; _chargers)
            if ((c.flags & 1) && c.demand >= Charger.min_current)
            {
                c.allocation = Charger.min_current;
                remaining -= Charger.min_current;
            }
        while (remaining)
        {
            uint hungry;
            foreach (ref c; _chargers)
                if (c.allocation && c.allocation < c.demand)
                    ++hungry;
            if (!hungry)
                break;
            uint share = max(1u, remaining / hungry);
            foreach (ref c; _chargers)
                if (c.allocation && c.allocation < c.demand)
                {
                    ushort extra = cast(ushort)min(remaining, min(share, uint(c.demand - c.allocation)));
                    c.allocation += extra;
                    remaining -= extra;
                }
        }
    }

    ushort next_offer(ref const Charger charger) const pure
    {
        if (!charger.allocation)
            return 0;
        if (charger.allocation <= charger.reserved_current)
            return charger.allocation;
        uint reserved;
        foreach (ref c; _chargers)
        {
            if (!(c.flags & 1))
                return min(charger.offered_current, charger.allocation);
            if (&c !is &charger)
                reserved += c.reserved_current;
        }
        uint available = reserved < _max_current ? _max_current - reserved : 0;
        ushort offer = cast(ushort)min(charger.allocation, available);
        return offer >= Charger.min_current ? offer : 0;
    }

    void tick(MonoTime scheduled)
    {
        if (!running)
            return;
        g_app.schedule(scheduled + tick_interval, &tick);

        BaseInterface i = _iface.get;
        if (!i || i.status.link_status != LinkStatus.up)
            return;

        if (_role == BusRole.standby)
        {
            if (scheduled - _other_master_heard < takeover_timeout)
                return;
            log.info("master ", tformat("{0,04x}", _other_master), " silent; taking over the bus");
            set_role(BusRole.active);
            _round_robin_index = -10;
            write_status();
        }

        if (_round_robin_index < 0)
        {
            ubyte[15] message = 0;
            message[0..2] = ushort(++_round_robin_index <= -5 ? 0xFCE1 : 0xFBE2).nativeToBigEndian;
            message[2..4] = _id_on_bus.nativeToBigEndian;
            message[4] = _sig;
            send_twc_message(TWCFrame.broadcast, message[]);

            return;
        }

        if (_chargers.empty)
            return;

        Charger* c = &_chargers[_round_robin_index++];
        if (_round_robin_index >= _chargers.length)
            _round_robin_index = 0;

        if (c.heartbeat_received != c.heartbeat_sent)
            c.req_seq = 0; // send heartbeats until the device responds

        ubyte[15] message = 0;
        message[2..4] = _id_on_bus.nativeToBigEndian;
        message[4..6] = c.id.nativeToBigEndian;

        if ((c.req_seq & 1) == 0)
        {
            if (c.heartbeat_sent - c.heartbeat_received >= 20)
            {
                debug writeDebug("Charger ", c.name, " not responding");
                c.heartbeat_sent = 0;
                c.heartbeat_received = 0;
                c.req_seq = 0;
            }

            version (DebugTWCMaster)
                writeDebugf("Charger {0}({1,04x}) - SN: {2}\n   {3}/{4}/{5}V  {6}A({7}A)  {8}W - {9}\n   VIN {10}", c.name, c.id, c.serial_number[], c.voltage1, c.voltage2, c.voltage3, cast(float)c.current/100, cast(float)c.offered_current / 100, c.total_power, c.charger_state(), c.vin[]);

            message[0..2] = ushort(0xFBE0).nativeToBigEndian;

            ushort offer = next_offer(*c);
            if (offer >= Charger.min_current && (offer != c.offered_current || offer != c.charge_current_target || c.state == TWCState.StartingToCharge))
            {
                message[6] = c.state == TWCState.StartingToCharge ? TWCState.StartingToCharge :
                    c.charger_state == ChargerState.charging ? TWCState.LimitCurrent : TWCState.Busy;
                message[7..9] = offer.nativeToBigEndian;
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


            message[0..2] = reqs[item].nativeToBigEndian;
            if (++item >= 5)
                item = 0;

            c.req_seq = cast(ubyte)(item << 1);
        }

        ushort previous_offer = c.offered_current;
        ushort previous_reservation = c.reserved_current;
        if (message[6] && (c.req_seq & 1))
        {
            c.offered_current = message[7..9].bigEndianToNative!ushort;
            c.reserved_current = max(c.reserved_current, c.offered_current);
        }
        if (send_twc_message(c.id, message[]) < 0)
        {
            c.offered_current = previous_offer;
            c.reserved_current = previous_reservation;
        }
        if (TeslaTWCBinding binding = c.binding.get)
            binding.push_samples(*c, TeslaTWCBinding.Push.heartbeat);
    }

    int send_twc_message(ushort dst, const(void)[] message)
    {
        _last_tx = getTime();
        Packet p;
        ref TWCFrame twc = p.init!TWCFrame(message[]);
        twc.src = _id_on_bus;
        twc.dst = dst;
        return _iface.forward(p);
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

        if (is_master_message(msg.type))
        {
            if (msg.sender == _id_on_bus)
            {
                // our own id heard while we are silent, and past any late echo of our last frames, is
                // another node configured with it
                if (_role != BusRole.active && getTime() - _last_tx > echo_grace)
                {
                    _collision = true;
                    if (running)
                        restart();
                }
                return;
            }
            if (msg.sender != _other_master)
            {
                _other_master = msg.sender;
                _standby_status = format(_status_buf, "Standing by: master {0,04x} on bus", _other_master);
            }
            _other_master_heard = getTime();
            if (_role == BusRole.active)
            {
                log.warning("another master ", tformat("{0,04x}", msg.sender), " on the bus; standing down");
                set_role(BusRole.standby);
                write_status();
            }
            if (_role != BusRole.active && msg.type == TWCMessageType.MasterHeartbeat && msg.heartbeat.current >= Charger.min_current)
                if (Charger* c = find_charger(msg.receiver))
                {
                    c.offered_current = msg.heartbeat.current;
                    c.reserved_current = max(c.reserved_current, c.offered_current);
                    if (TeslaTWCBinding binding = c.binding.get)
                        binding.push_samples(*c, TeslaTWCBinding.Push.heartbeat);
                }
            return;
        }

        Charger* slave = find_charger(msg.sender);
        if (!slave)
        {
            bool announced = twc.dst == TWCFrame.broadcast && msg.type == TWCMessageType.SlaveLinkReady;
            bool snooped = _role != BusRole.active && _other_master && twc.dst == _other_master && msg.type == TWCMessageType.SlaveHeartbeat;
            if ((!announced && !snooped) || msg.sender == 0 || msg.sender == TWCFrame.broadcast)
                return;
            slave = discover(msg.sender);
        }
        if (TeslaTWCBinding binding = slave.binding.get)
            binding.heard();
        ubyte flags_before = slave.flags;
        ushort offered_before = slave.offered_current;
        TeslaTWCBinding.Push changed;

        if (twc.dst == TWCFrame.broadcast)
        {
            switch (msg.type)
            {
                case TWCMessageType.SlaveLinkReady:
                    // always refresh: with optimistic adoption this may arrive while we're
                    // already heartbeating (slave rebooted, or first contact after our boot)
                    slave.device_max_current = msg.link_ready.amps;
                    if (slave.target_current == ushort.max)
                        slave.target_current = slave.device_max_current;
                    changed |= TeslaTWCBinding.Push.link_ready | TeslaTWCBinding.Push.heartbeat;
                    break;
                case TWCMessageType.ChargeInfo:
                    slave.lifetime_energy = msg.charge_info.lifetime_energy;
                    slave.voltage1 = msg.charge_info.voltage1;
                    slave.voltage2 = msg.charge_info.voltage2;
                    slave.voltage3 = msg.charge_info.voltage3;
                    // the current in this message is more closely temporally aligned, but it's only 500mA precision
                    // the current we recorded is half a second old, but it's 10mA precision
                    slave.power1 = cast(ushort)(msg.charge_info.voltage1 * slave.current / 100);
                    slave.power2 = cast(ushort)(msg.charge_info.voltage2 * slave.current / 100);
                    slave.power3 = cast(ushort)(msg.charge_info.voltage3 * slave.current / 100);
                    slave.total_power = cast(ushort)(slave.power1 + slave.power2 + slave.power3);
                    slave.flags |= 0x2;
                    changed |= TeslaTWCBinding.Push.charge_info;
                    break;
                case TWCMessageType._FDEC:
                    break;
                case TWCMessageType.TWCSerialNumber:
                    slave.serial_number[0..11] = msg.sn[0..11];
                    slave.flags |= 0x4;
                    changed |= TeslaTWCBinding.Push.serial;
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
                    break;
            }
        }
        // in standby, snooping the slaves' replies to the active master keeps the model fresh
        else if (msg.type == TWCMessageType.SlaveHeartbeat && (twc.dst == _id_on_bus || (_role != BusRole.active && twc.dst == _other_master)))
        {
            slave.state = msg.heartbeat.state;
            if (_role != BusRole.active && !slave.offered_current)
                slave.offered_current = msg.heartbeat.current;
            slave.acknowledge(msg.heartbeat.current, msg.heartbeat.current_in_use);

            slave.flags |= 0x1;

            // Ready+0A also describes a sleeping car; confirm unplugging with VIN re-polls.
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
                slave.heartbeat_sent -= slave.heartbeat_received;
                slave.heartbeat_received = 0;
            }
            changed |= TeslaTWCBinding.Push.heartbeat;
        }

        rebalance();
        if (slave.offered_current != offered_before)
            changed |= TeslaTWCBinding.Push.heartbeat;
        // the VIN and circuit follow the collected and connected bits, the charger state the rest
        if ((flags_before ^ slave.flags) & 0xF0)
            changed |= TeslaTWCBinding.Push.vehicle | TeslaTWCBinding.Push.heartbeat;
        if (changed)
            if (TeslaTWCBinding binding = slave.binding.get)
                binding.push_samples(*slave, changed);
    }
}

unittest
{
    import urt.mem : alloc, free;

    static class TestInterface : BaseInterface
    {
        enum type_name = "twc-test-interface";
    nothrow @nogc:
        bool subscribed;

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestInterface, id, flags);
        }

        override CompletionStatus startup() => CompletionStatus.complete;
        override int transmit(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null) => 0;
        override void on_subscribers_changed(bool any) { subscribed = any; }
        void start() { set_state(State.running); }
    }

    static class TestMaster : TeslaTWCMaster
    {
    nothrow @nogc:
        this(CID id) { super(id); }
        void start() { set_state(State.running); }
        void stop() { set_state_deferred(State.stopping); }
    }

    TestInterface iface = Collection!TestInterface().alloc("twc-review-interface");
    Collection!TestInterface().add(iface);
    scope(exit)
    {
        Collection!TestInterface().remove(iface);
        free(iface);
    }
    iface.start();
    assert(iface.running);

    TestMaster master = alloc!TestMaster(Collection!TeslaTWCMaster().allocate_id("twc-review-master"));
    Collection!TeslaTWCMaster().add(master);
    scope(exit)
    {
        Collection!TeslaTWCMaster().remove(master);
        free(master);
    }
    master.iface = iface;
    assert(master.startup() == CompletionStatus.continue_);
    assert(iface.subscribed && master._subscribed);
    master._other_master = 42;
    master._other_master_heard = getTime();
    master.iface = null;
    assert(!iface.subscribed && !master._subscribed);
    assert(master._other_master == 0 && master._other_master_heard == MonoTime());
    master.tick(getTime());

    master._id_on_bus = 1;
    Duration first = master.listen_window;
    master._id_on_bus = 2;
    assert(master.listen_window - first == 400.msecs);

    TeslaTWCBinding binding = Collection!TeslaTWCBinding().alloc("twc-review-binding");
    Collection!TeslaTWCBinding().add(binding);
    scope(exit)
    {
        Collection!TeslaTWCBinding().remove(binding);
        free(binding);
    }
    binding.master = master;
    binding.slave_id = 123;
    TeslaTWCMaster.Charger* discovered = master.discover(123);
    assert(!discovered.binding);
    assert(master.adopt(123, binding) is discovered);
    TeslaTWCBinding duplicate = alloc!TeslaTWCBinding(CID(2));
    scope(exit) free(duplicate);
    assert(master.adopt(123, duplicate) is null);
    assert(discovered.binding.get is binding);
    master.detach(123, binding);

    binding.slave_id = 124;
    master._other_master = 42;
    master._role = TeslaTWCMaster.BusRole.listening;
    ubyte[15] message;
    message[0..2] = ushort(0xFDE0).nativeToBigEndian;
    message[2..4] = ushort(124).nativeToBigEndian;
    message[4..6] = ushort(42).nativeToBigEndian;
    message[6] = TWCState.Charging;
    message[7..9] = ushort(2000).nativeToBigEndian;
    message[9..11] = ushort(1500).nativeToBigEndian;
    Packet packet;
    ref TWCFrame frame = packet.init!TWCFrame(message[]);
    frame.src = 124;
    frame.dst = 42;
    master.incoming_packet(packet, iface, PacketDirection.incoming, null);
    discovered = master.find_charger(124);
    assert(discovered && discovered.current == 1500 && discovered.charge_current_target == 2000);
    assert(discovered.reserved_current == 2000);

    master.start();
    master.set_role(TeslaTWCMaster.BusRole.active);
    assert(master.has_agency);
    master.set_role(TeslaTWCMaster.BusRole.standby);
    assert(!master.has_agency);
    master.set_role(TeslaTWCMaster.BusRole.active);
    assert(master.has_agency);
    master.stop();
    assert(!master.has_agency);

    assert(master.max_current(Amps(3)).length);
    assert(master.max_current(Amps(-1)).length);
    assert(master.max_current(Amps(float.nan)).length);
    assert(master.max_current(Amps(1000)).length);
    assert(master.max_current(Amps(32)) is null);

    master._chargers.clear();
    foreach (id; [ushort(1), ushort(2)])
    {
        auto c = master.add_charger(id);
        c.device_max_current = 3200;
        c.flags = 1;
    }
    master.rebalance();
    assert(master._chargers[0].allocation == 1600 && master._chargers[1].allocation == 1600);
    master.set_cap(1, 1000);
    assert(master._chargers[0].allocation == 1000 && master._chargers[1].allocation == 2200);
    master.set_target_current(2, 1200);
    assert(master._chargers[0].allocation == 1000 && master._chargers[1].allocation == 1200);
    master.set_cap(1, 0);
    assert(master._chargers[0].allocation == 2000 && master._chargers[1].allocation == 1200);

    master._chargers[0].offered_current = 3200;
    master._chargers[0].reserved_current = 3200;
    master._chargers[0].charge_current_target = 3200;
    assert(master.next_offer(master._chargers[1]) == 0);
    assert(master.next_offer(master._chargers[0]) == 2000);
    master._chargers[0].offered_current = 2000;
    master._chargers[0].acknowledge(3200, 2000);
    assert(master.next_offer(master._chargers[1]) == 0);
    master._chargers[0].acknowledge(2000, 3000);
    assert(master.next_offer(master._chargers[1]) == 0);
    master._chargers[0].acknowledge(2000, 2000);
    assert(master.next_offer(master._chargers[1]) == 1200);

    master._chargers[1].offered_current = 1200;
    master._chargers[1].reserved_current = 1200;
    assert(master.max_current(Amps(10)) is null);
    assert(master._chargers[0].allocation == 500 && master._chargers[1].allocation == 500);

    master._chargers.clear();
    foreach (id; 1 .. 5)
    {
        auto c = master.add_charger(cast(ushort)id);
        c.device_max_current = 3200;
        c.flags = 1;
    }
    foreach (budget; [ushort(500), ushort(999), ushort(1000), ushort(1600), ushort(3200), ushort(65535)])
    {
        master._max_current = budget;
        master.rebalance();
        uint total;
        foreach (ref c; master._chargers)
        {
            assert(!c.allocation || c.allocation >= TeslaTWCMaster.Charger.min_current);
            assert(c.allocation <= c.demand);
            total += c.allocation;
        }
        assert(total <= budget);
    }
}
