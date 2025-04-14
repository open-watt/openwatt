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
    nothrow @nogc:
        String name;
        MACAddress mac;
        ushort id;

        ubyte reqSeq;
        bool linkready;
        ubyte sigByte; // we don't know what this is for...

        ubyte heartbeatSent;
        ubyte heartbeatReceived;

        TWCState state;

        ubyte flags; // 1 = got state, 2 = got charge info, 4 = got sn, 10 = car connected, 20 = got vin1, 40 = got vin2, 80 = got vin3
        ubyte vinAttempts;

        ushort specifiedMaxCurrent; // the maximum current we're allowed to charge with
        ushort deviceMaxCurrent;    // the maximum current supported by the charger
        ushort targetCurrent;       // the current we're trying to charge with
        ushort chargeCurrentTarget; // the current the car is requesting

        ushort current;
        ushort voltage1;
        ushort voltage2;
        ushort voltage3;
        ushort totalPower;
        ushort power1;
        ushort power2;
        ushort power3;

        uint lifetimeEnergy;

        char[11] serialNumber;
        char[17] vin;

        ushort maxCurrent()
            => min(deviceMaxCurrent, specifiedMaxCurrent);

        ushort chargeCurrent()
            => min(maxCurrent, targetCurrent);

        ChargerState chargerState()
        {
            switch (state)
            {
                case TWCState.Ready:
                    // it seems that if the charger is reporting a current, a car is connected
                    if (chargeCurrentTarget > 0)
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

        void reset()
        {
            linkready = false;
            state = TWCState.Ready;
            flags = 0;
            vinAttempts = 0;
            reqSeq = 0;
        }
    }

    TeslaProtocolModule m;

    String name;
    BaseInterface iface;
    bool lastLinkStatus = false;

    MonoTime lastAction;

    ushort id;
    ubyte sig;

    byte roundRobinIndex;

    Array!Charger chargers;


    this(TeslaProtocolModule m, String name, BaseInterface iface)
    {
        this.name = name.move;
        this.iface = iface;

        static ubyte idCounter = 0;
        this.id = 0x7770 + idCounter++;
        this.sig = iface.mac.b[3];

        iface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.TeslaTWC));

        getModule!TeslaInterfaceModule.addServer(name[], iface, id);
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
            roundRobinIndex = -10;
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
        if (roundRobinIndex < 0)
        {
            ubyte[15] message = 0;
            message[0..2] = ushort(roundRobinIndex++ < -5 ? 0xFCE1 : 0xFBE2).nativeToBigEndian;
            message[2..4] = id.nativeToBigEndian;
            message[4] = sig;
            iface.send(MACAddress.broadcast, message[], EtherType.ENMS, ENMS_SubType.TeslaTWC);
            return;
        }

        // iterate through the ready chargers...
        Charger* c = &chargers[roundRobinIndex++];
        if (roundRobinIndex >= chargers.length)
            roundRobinIndex = 0;

        while (!c.linkready)
            return; // TODO: preferably, advance to the next charger...
        if (c.heartbeatReceived != c.heartbeatSent)
            c.reqSeq = 0; // send heartbeats until the device responds

        ubyte[15] message = 0;
        message[2..4] = id.nativeToBigEndian;
        message[4..6] = c.id.nativeToBigEndian;

        // command selection logic...
        if ((c.reqSeq & 1) == 0)
        {
            if (c.heartbeatSent - c.heartbeatReceived >= 20)
            {
                // the slave stopped responding... I guess we should assume it's offline?
                c.reset();
                return;
            }

            version (DebugTWCMaster)
                writeDebugf("Charger {0}({1,04x}) - SN: {2}\n   {3}/{4}/{5}V  {6}A({7}A)  {8}W - {9}\n   VIN {10}", c.name, c.id, c.serialNumber[], c.voltage1, c.voltage2, c.voltage3, cast(float)c.current/100, cast(float)c.maxCurrent / 100, c.totalPower, c.chargerState(), c.vin[]);

            message[0..2] = ushort(0xFBE0).nativeToBigEndian;

            switch (c.state)
            {
                case TWCState.Ready:
                    if (c.chargeCurrentTarget == 0)
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
                    else if (c.chargeCurrent != c.chargeCurrentTarget)
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

            ++c.heartbeatSent;
            ++c.reqSeq;
        }
        else
        {
            __gshared static ushort[5] reqs = [0xFBEB, 0xFBED, 0xFBEE, 0xFBEF, 0xFBF1];

            byte item = c.reqSeq >> 1;

            if (item == 1)
            {
                if (c.flags & 4)
                    ++item;
            }
            if (item >= 2 && ((c.flags & 0x10) == 0 || (c.flags & 0xF0) == 0xF0 || c.vinAttempts >= 10))
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

            c.reqSeq = cast(ubyte)(item << 1);
        }

        // send request
        iface.send(c.mac, message[], EtherType.ENMS, ENMS_SubType.TeslaTWC);
    }

    void incomingPacket(ref const Packet p, BaseInterface iface, PacketDirection dir, void* userData) nothrow @nogc
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
                        if (slave.linkready)
                            break;
                        slave.mac = p.src;
                        slave.linkready = true;
                        slave.sigByte = msg.linkready.signature;
                        slave.deviceMaxCurrent = msg.linkready.amps;
                        slave.heartbeatSent = 0;
                        slave.heartbeatReceived = 0;
                        break;
                    case TWCMessageType.ChargeInfo:
                        slave.lifetimeEnergy = msg.chargeinfo.lifetimeEnergy;
                        slave.voltage1 = msg.chargeinfo.voltage1;
                        slave.voltage2 = msg.chargeinfo.voltage2;
                        slave.voltage3 = msg.chargeinfo.voltage3;
                        // the current in this message is more closely temporally aligned, but it's only 500mA precision
//                        slave.power1 = cast(ushort)(msg.chargeinfo.voltage1 * msg.chargeinfo.current / 2);
//                        slave.power2 = cast(ushort)(msg.chargeinfo.voltage2 * msg.chargeinfo.current / 2);
//                        slave.power3 = cast(ushort)(msg.chargeinfo.voltage3 * msg.chargeinfo.current / 2);
                        // the current we recorded is half a second old, but it's 10mA precision
                        slave.power1 = cast(ushort)(msg.chargeinfo.voltage1 * slave.current / 100);
                        slave.power2 = cast(ushort)(msg.chargeinfo.voltage2 * slave.current / 100);
                        slave.power3 = cast(ushort)(msg.chargeinfo.voltage3 * slave.current / 100);
                        slave.totalPower = cast(ushort)(slave.power1 + slave.power2 + slave.power3);
                        slave.flags |= 0x2;
                        break;
                    case TWCMessageType._FDEC:
                        break;
                    case TWCMessageType.TWCSerialNumber:
                        slave.serialNumber[0..11] = msg.sn[0..11];
                        slave.flags |= 0x4;
                        break;
                    case TWCMessageType.VIN1:
                        slave.vin[0..7] = msg.vin[];
                        if (*cast(uint*)msg.vin.ptr == 0)
                        {
                            ++slave.vinAttempts;
                            slave.reqSeq = 0;
                        }
                        else
                            slave.flags |= 0x20;
                        break;
                    case TWCMessageType.VIN2:
                        slave.vin[7..14] = msg.vin[];
                        if (*cast(uint*)msg.vin.ptr == 0)
                        {
                            ++slave.vinAttempts;
                            slave.reqSeq = 0;
                        }
                        else
                            slave.flags |= 0x40;
                        break;
                    case TWCMessageType.VIN3:
                        slave.vin[14..17] = msg.vin[0..3];
                        if (*cast(uint*)msg.vin.ptr == 0)
                        {
                            ++slave.vinAttempts;
                            slave.reqSeq = 0;
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
            else if (p.dst == iface.mac && msg.type == TWCMessageType.SlaveHeartbeat)
            {
                // record heartbeat response state...
                slave.state = msg.heartbeat.state;
                slave.chargeCurrentTarget = msg.heartbeat.current;
                slave.current = msg.heartbeat.currentInUse;

                slave.flags |= 0x1;

                // if a car appears to be connected...
                if (msg.heartbeat.state == TWCState.Ready && msg.heartbeat.current == 0)
                {
                    debug if (slave.flags & 0x10)
                        writeDebug("Car disconnected from ", slave.name);

                    slave.flags &= 0xF;
                    slave.vinAttempts = 0;
                }
                else
                {
                    debug if ((slave.flags & 0x10) == 0)
                        writeDebug("Car connected to ", slave.name);

                    slave.flags |= 0x10;
                }

                slave.heartbeatReceived = slave.heartbeatSent;
                if (slave.heartbeatReceived >= 128)
                {
                    // handle graceful overflow...
                    slave.heartbeatSent -= slave.heartbeatReceived;
                    slave.heartbeatReceived = 0;
                }
            }
        }
    }
}
