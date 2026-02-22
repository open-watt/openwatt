module protocol.tesla.master;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;
import urt.util;

import protocol.tesla;
import protocol.tesla.twc;

import router.iface;
import router.iface.packet;
import router.iface.tesla;

import manager;

//version = DebugTWCMaster;

nothrow @nogc:


import urt.si;
alias CentiAmps = Quantity!(ushort, ScaledUnit(Ampere, -2));


class TeslaTWCMaster
{
nothrow @nogc:

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
        MACAddress mac;
        ushort id;

        ubyte req_seq;
        bool link_ready;
        ubyte sig_byte; // we don't know what this is for...

        ubyte heartbeat_sent;
        ubyte heartbeat_received;

        TWCState state;

        ubyte flags; // 1 = got state, 2 = got charge info, 4 = got sn, 10 = car connected, 20 = got vin1, 40 = got vin2, 80 = got vin3
        ubyte vin_attempts;

        ushort specified_max_current; // the maximum current we're allowed to charge with
        ushort device_max_current;    // the maximum current supported by the charger
        ushort target_current;       // the current we're trying to charge with
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

        ushort max_current()
            => min(device_max_current, specified_max_current);

        ushort charge_current()
            => min(max_current, target_current);

        ChargerState charger_state()
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

        void reset()
        {
            link_ready = false;
            state = TWCState.Ready;
            flags = 0;
            vin_attempts = 0;
            req_seq = 0;
        }
    }

    TeslaProtocolModule m;

    String name;
    BaseInterface iface;
    LinkStatus last_link_status = LinkStatus.down;

    MonoTime last_action;

    ushort id;
    ubyte sig;

    byte round_robin_index;

    Array!Charger chargers;


    this(TeslaProtocolModule m, String name, BaseInterface iface)
    {
        this.name = name.move;
        this.iface = iface;

        static ubyte id_counter = 0;
        this.id = 0x7770 + id_counter++;
        this.sig = iface.mac.b[3];

        iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ow, ow_subtype: OW_SubType.tesla_twc));

        get_module!TeslaInterfaceModule.add_server(name[], iface, id);
    }

    ~this()
    {
    }

    void add_charger(String name, ushort twc_id, ushort max_current)
    {
        Charger* charger = &chargers.pushBack();

        charger.name = name.move;
        charger.id = twc_id;

        charger.specified_max_current = max_current;
        charger.target_current = max_current;

    }

    Charger* find_charger(const(char)[] name)
    {
        foreach (ref c; chargers)
        {
            if (c.name[] == name[])
                return &c;
        }
        return null;
    }

    int set_target_current(const(char)[] name, ushort current)
    {
        Charger* c = find_charger(name);
        if (c)
        {
            c.target_current = min(current, c.max_current);
            return c.target_current;
        }
        return -1;
    }

    void update()
    {
        LinkStatus link_status = iface.status.link_status;
        if (link_status != last_link_status && link_status == LinkStatus.up)
        {
            // if the link returned after being offline for a bit, we'll issue a full restart
            round_robin_index = -10;
            foreach (ref c; chargers)
                c.reset();
            last_action = MonoTime();
        }
        last_link_status = link_status;
        if (link_status != LinkStatus.up)
            return;

        MonoTime now = getTime();
        if (now < last_action + 400.msecs)
            return;
        last_action = now;

        // we will immitate the bootup sequence... but I don't really know why?
        // I can't really see evidence the slaves care about this!
        if (round_robin_index < 0)
        {
            ubyte[15] message = 0;
            message[0..2] = ushort(round_robin_index++ < -5 ? 0xFCE1 : 0xFBE2).nativeToBigEndian;
            message[2..4] = id.nativeToBigEndian;
            message[4] = sig;
            iface.send(MACAddress.broadcast, message[], EtherType.ow, OW_SubType.tesla_twc);
            return;
        }

        // iterate through the ready chargers...
        Charger* c = &chargers[round_robin_index++];
        if (round_robin_index >= chargers.length)
            round_robin_index = 0;

        while (!c.link_ready)
            return; // TODO: preferably, advance to the next charger...
        if (c.heartbeat_received != c.heartbeat_sent)
            c.req_seq = 0; // send heartbeats until the device responds

        ubyte[15] message = 0;
        message[2..4] = id.nativeToBigEndian;
        message[4..6] = c.id.nativeToBigEndian;

        // command selection logic...
        if ((c.req_seq & 1) == 0)
        {
            if (c.heartbeat_sent - c.heartbeat_received >= 20)
            {
                // the slave stopped responding... I guess we should assume it's offline?
                c.reset();
                return;
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
                    // car is requesting to charge...
                    if (c.charge_current != 0)
                    {
                        // accept the request
                        message[6] = TWCState.StartingToCharge;
                        message[7..9] = c.max_current.nativeToBigEndian;
                    }
                    break;
                case TWCState.Charging:
                    if (c.charge_current == 0)
                    {
                        // the car is requesting to stop charging...
                        // TODO: we don't know how to do this!
                    }
                    else if (c.charge_current != c.charge_current_target)
                    {
                        // the car is requesting to change the current...
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
            if (item >= 2 && ((c.flags & 0x10) == 0 || (c.flags & 0xF0) == 0xF0 || c.vin_attempts >= 10))
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
        iface.send(c.mac, message[], EtherType.ow, OW_SubType.tesla_twc);
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        TWCMessage msg;
        if (parse_twc_message(cast(ubyte[])p.data, msg))
        {
            Charger* slave;
            foreach (ref c; chargers)
            {
                if (c.id == msg.sender)
                {
                    slave = &c;
                    break;
                }
            }
            if (!slave)
            {
                // there's a slave on the bus that was never registered...
                //... ???
            }

            if (p.eth.dst.isBroadcast)
            {
                switch (msg.type)
                {
                    case TWCMessageType.SlaveLinkReady:
                        if (slave.link_ready)
                            break;
                        slave.mac = p.eth.src;
                        slave.link_ready = true;
                        slave.sig_byte = msg.link_ready.signature;
                        slave.device_max_current = msg.link_ready.amps;
                        slave.heartbeat_sent = 0;
                        slave.heartbeat_received = 0;
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
            else if (p.eth.dst == iface.mac && msg.type == TWCMessageType.SlaveHeartbeat)
            {
                // record heartbeat response state...
                slave.state = msg.heartbeat.state;
                slave.charge_current_target = msg.heartbeat.current;
                slave.current = msg.heartbeat.current_in_use;

                slave.flags |= 0x1;

                // if a car appears to be connected...
                if (msg.heartbeat.state == TWCState.Ready && msg.heartbeat.current == 0)
                {
                    debug if (slave.flags & 0x10)
                        writeDebug("Car disconnected from ", slave.name);

                    slave.flags &= 0xF;
                    slave.vin_attempts = 0;
                }
                else
                {
                    debug if ((slave.flags & 0x10) == 0)
                        writeDebug("Car connected to ", slave.name);

                    slave.flags |= 0x10;
                }

                slave.heartbeat_received = slave.heartbeat_sent;
                if (slave.heartbeat_received >= 128)
                {
                    // handle graceful overflow...
                    slave.heartbeat_sent -= slave.heartbeat_received;
                    slave.heartbeat_received = 0;
                }
            }
        }
    }
}
