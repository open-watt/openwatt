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


class TeslaTWCMaster
{
nothrow @nogc:

    enum ChargerState
    {
        Unknown,
        Idle,
        Stopped,
        Scheduled,
        Charging,
        Error
    }

    struct Charger
    {
        struct State
        {
            ushort deviceMaxCurrent;

            bool linkready;
            ubyte sigByte; // we don't know what this is for...

            ushort currentReq;
            ushort current;

            ushort voltage1;
            ushort voltage2;
            ushort voltage3;
            ushort totalPower;
            ushort power1;
            ushort power2;
            ushort power3;

            uint lifetimeEnergy;

            TWCState state;

            char[11] serialNumber;
            char[17] vin;
            char[14] nextVin;

            ubyte heartbeatSent;
            ubyte heartbeatReceived;
            ubyte dataRequestIndex;
        }

        String name;
        ushort id;

        MACAddress mac;

        ushort specifiedMaxCurrent;
        ushort targetCurrent;

        State state;

        ushort maxCurrent() nothrow @nogc
            => min(state.deviceMaxCurrent, specifiedMaxCurrent);

        ushort chargeCurrent() nothrow @nogc
            => min(maxCurrent, targetCurrent);

        ChargerState chargerState()
        {
            switch (state.state)
            {
                case TWCState.Ready:
                    // it seems that if the charger is reporting a current, a car is connected
                    if (state.currentReq > 0)
                        return ChargerState.Stopped;
                    return ChargerState.Idle; // not sure if it's possible that the car is plugged in?
                case TWCState.Charging:
                case TWCState.RaisingCurrent:
                case TWCState.LoweringCurrent:
                case TWCState.LimitCurrent:
                case TWCState._A:
                    return ChargerState.Charging;
                case TWCState.PluggedIn_DoNotCharge:
                case TWCState.StartingToCharge:
                case TWCState.Busy: // ???? what is this?
                    return ChargerState.Stopped;
                case TWCState.PluggedIn_ChargeScheduled:
                    return ChargerState.Scheduled;
                case TWCState.Error:
                    return ChargerState.Error;
                default:
                    return ChargerState.Unknown;
            }
        }

        void reset() nothrow @nogc
        {
            state = State.init;
        }
    }

    TeslaProtocolModule.Instance m;

    String name;
    BaseInterface iface;
    bool lastLinkStatus = false;

    MonoTime lastAction;

    ushort id;
    ubyte sig;

    byte pollState = -8;

    Array!Charger chargers;


    this(TeslaProtocolModule.Instance m, String name, BaseInterface iface)
    {
        this.name = name.move;
        this.iface = iface;

        static ubyte idCounter = 0;
        this.id = 0x7770 + idCounter++;
        this.sig = iface.mac.b[3];

        iface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.TeslaTWC));

        m.app.moduleInstance!TeslaInterfaceModule.addServer(name[], iface, id);
    }

    ~this()
    {
    }

    void addCharger(String name, ushort twcId, ushort maxCurrent)
    {
        Charger* charger = &chargers.pushBack();

        charger.name = name.move;
        charger.id = twcId;

        charger.specifiedMaxCurrent = maxCurrent;
        charger.targetCurrent = maxCurrent;

    }

    Charger* findCharger(const(char)[] name)
    {
        foreach (ref c; chargers)
        {
            if (c.name[] == name[])
                return &c;
        }
        return null;
    }

    int setTargetCurrent(const(char)[] name, ushort current)
    {
        Charger* c = findCharger(name);
        if (c)
        {
            c.targetCurrent = min(current, c.maxCurrent);
            return c.targetCurrent;
        }
        return -1;
    }

    void update()
    {
        bool linkStatus = iface.getStatus.linkStatus;
        if (linkStatus != lastLinkStatus && linkStatus)
        {
            // if the link returned after being offline for a bit, we'll issue a full restart
            pollState = -8;
            foreach (ref c; chargers)
                c.reset();
            lastAction = MonoTime();
        }
        lastLinkStatus = linkStatus;
        if (!linkStatus)
            return;

        MonoTime now = getTime();
        if (now < lastAction + 400.msecs)
            return;
        lastAction = now;

        // we will immitate the bootup sequence... but I don't really know why?
        // I can't really see evidence the slaves care about this!
        if (pollState < 0)
        {
            ubyte[15] message = 0;
            message[0..2] = (pollState++ < -4 ? 0xFCE1 : 0xFBE2).nativeToBigEndian;
            message[2..4] = id.nativeToBigEndian;
            message[4] = sig;
            iface.send(MACAddress.broadcast, message[], EtherType.ENMS, ENMS_SubType.TeslaTWC);
            return;
        }

        // iterate through the ready chargers...
        Charger* c = &chargers[pollState / 2];
        bool dataCycle = pollState & 1;

        while (!c.state.linkready)
            goto next;

        if (!dataCycle)
        {
            if (c.state.heartbeatSent - c.state.heartbeatReceived >= 10)
            {
                // the slave stopped responding... I guess we should assume it's offline?
                c.reset();
                goto next;
            }

            ubyte[15] message = 0;
            message[0..2] = 0xFBE0.nativeToBigEndian;
            message[2..4] = id.nativeToBigEndian;
            message[4..6] = c.id.nativeToBigEndian;

            switch (c.state.state)
            {
                case TWCState.Ready:
                    if (c.state.currentReq == 0)
                    {
                        // the charger is idle...
                        break;
                    }
                    goto case;
                case TWCState.PluggedIn_DoNotCharge:
                case TWCState.PluggedIn_ChargeScheduled:
                    // we'll advertise the available charge current...
                    message[6] = TWCState.Busy;
                    message[7..9] = c.maxCurrent.nativeToBigEndian;
                    break;
                case TWCState.StartingToCharge:
                    // car is requesting to charge...
                    if (c.chargeCurrent != 0)
                    {
                        // accept the request
                        message[6] = TWCState.StartingToCharge;
                        message[7..9] = c.maxCurrent.nativeToBigEndian;
                    }
                    break;
                case TWCState.Charging:
                    if (c.chargeCurrent == 0)
                    {
                        // the car is requesting to stop charging...
                        // TODO: we don't know how to do this!
                    }
                    else if (c.chargeCurrent != c.state.currentReq)
                    {
                        // the car is requesting to change the current...
                        message[6] = TWCState.LimitCurrent;
                        message[7..9] = c.chargeCurrent.nativeToBigEndian;
                    }
                    break;
                default:
                    // what goes on?
                    break;
            }

            iface.send(c.mac, message[], EtherType.ENMS, ENMS_SubType.TeslaTWC);

            ++c.state.heartbeatSent;
        }
        else if (c.state.heartbeatReceived == c.state.heartbeatSent)
        {
            if (c.state.dataRequestIndex >= 6)
            {
                c.state.dataRequestIndex = 0;
                debug writeDebug("Charger ", c.name, "(", c.id, "):\n   I ", cast(float)c.state.current/100, "A(", cast(float)c.maxCurrent / 100, "A)  V ", c.state.voltage1, '/', c.state.voltage2, '/', c.state.voltage3, "V  P ", c.state.totalPower, "W (", cast(float)c.state.current*c.state.voltage1/100, "W)\n   SN ", c.state.serialNumber[], "  VIN ", c.state.vin[]);
            }
            ushort[6] req = [ 0xFBEB, 0xFBEC, 0xFBEE, 0xFBEF, 0xFBF1, 0xFBED ];
            ubyte[15] message = 0;
            message[0..2] = req[c.state.dataRequestIndex].nativeToBigEndian;
            message[2..4] = id.nativeToBigEndian;
            message[4..6] = c.id.nativeToBigEndian;

            iface.send(c.mac, message[], EtherType.ENMS, ENMS_SubType.TeslaTWC);
        }

    next:
        if (++pollState >= chargers.length * 2)
            pollState -= chargers.length * 2;
    }

    void incomingPacket(ref const Packet p, BaseInterface iface, void* userData) nothrow @nogc
    {
        TWCMessage msg;
        if (parseTWCMessage(cast(ubyte[])p.data, msg))
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

            if (p.dst.isBroadcast)
            {
                switch (msg.type)
                {
                    case TWCMessageType.SlaveLinkReady:
                        if (slave.state.linkready)
                            break;
                        slave.mac = p.src;
                        slave.state.linkready = true;
                        slave.state.sigByte = msg.linkready.signature;
                        slave.state.deviceMaxCurrent = msg.linkready.amps;
                        slave.state.heartbeatSent = 0;
                        slave.state.heartbeatReceived = 0;
                        break;
                    case TWCMessageType.ChargeInfo:
                        slave.state.voltage1 = msg.chargeinfo.voltage1;
                        slave.state.voltage2 = msg.chargeinfo.voltage2;
                        slave.state.voltage3 = msg.chargeinfo.voltage3;
                        slave.state.power1 = cast(ushort)(msg.chargeinfo.voltage1 * msg.chargeinfo.current / 2);
                        slave.state.power2 = cast(ushort)(msg.chargeinfo.voltage2 * msg.chargeinfo.current / 2);
                        slave.state.power3 = cast(ushort)(msg.chargeinfo.voltage3 * msg.chargeinfo.current / 2);
                        slave.state.totalPower = cast(ushort)(slave.state.power1 + slave.state.power2 + slave.state.power3);
                        slave.state.lifetimeEnergy = msg.chargeinfo.lifetimeEnergy;
                        ++slave.state.dataRequestIndex;
                        break;
                    case TWCMessageType._FDEC:
                        ++slave.state.dataRequestIndex;
                        break;
                    case TWCMessageType.TWCSerialNumber:
                        slave.state.serialNumber[0..11] = msg.sn[0..11];
                        ++slave.state.dataRequestIndex;
                        break;
                    case TWCMessageType.VIN1:
                        slave.state.nextVin[0..7] = msg.vin1[0..7];
                        ++slave.state.dataRequestIndex;
                        break;
                    case TWCMessageType.VIN2:
                        slave.state.nextVin[7..14] = msg.vin2[0..7];
                        ++slave.state.dataRequestIndex;
                        break;
                    case TWCMessageType.VIN3:
                        slave.state.vin[0..14] = slave.state.nextVin[];
                        slave.state.vin[14..17] = msg.vin3[0..3];
                        ++slave.state.dataRequestIndex;
                        break;
                    default:
                        // unexpected message?
//                        debug writeWarning("Unexpected message!");
                        break;
                }
            }
            else if (p.dst == iface.mac && msg.type == TWCMessageType.SlaveHeartbeat)
            {
                // record heartbeat response state...
                slave.state.state = msg.heartbeat.state;
                slave.state.currentReq = msg.heartbeat.current;
                slave.state.current = msg.heartbeat.currentInUse;

                slave.state.heartbeatReceived = slave.state.heartbeatSent;
                if (slave.state.heartbeatReceived >= 128)
                {
                    // handle graceful overflow...
                    slave.state.heartbeatSent -= slave.state.heartbeatReceived;
                    slave.state.heartbeatReceived = 0;
                }
            }
        }
    }
}
