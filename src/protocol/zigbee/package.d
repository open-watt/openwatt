module protocol.zigbee;

import urt.endian;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.ezsp;
import protocol.ezsp.client;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;

import router.iface;

nothrow @nogc:


class ZigbeeProtocolModule : Module
{
    mixin DeclareModule!"protocol.zigbee";
nothrow @nogc:

    Map!(const(char)[], ZigbeeClient) clients;
    Map!(const(char)[], ZigbeeCoordinator) coordinators;

    override void init()
    {
        g_app.console.registerCommand!client_add("/protocol/zigbee/client", this, "add");
        g_app.console.registerCommand!coordinator_add("/protocol/zigbee/coordinator", this, "add");

        g_app.console.registerCommand!scan("/protocol/zigbee", this);
    }

    override void update()
    {
        foreach(coordinator; coordinators.values)
            coordinator.update();

        foreach(client; clients.values)
            client.update();
    }

    void client_add(Session session, const(char)[] name, const(char)[] _interface)
    {
        BaseInterface i = getModule!InterfaceModule.findInterface(_interface);
        if(i is null)
        {
            session.writeLine("Interface '", _interface, "' not found");
            return;
        }

        NoGCAllocator a = g_app.allocator;

        // TODO: generate name if not supplied
        String n = name.makeString(a);

        ZigbeeClient client = a.allocT!ZigbeeClient(n.move, i);
        clients.insert(client.name[], client);

//        writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
    }

    void coordinator_add(Session session, const(char)[] name, const(char)[] _interface)
    {
        BaseInterface i = getModule!InterfaceModule.findInterface(_interface);
        if(i is null)
        {
            session.writeLine("Interface '", _interface, "' not found");
            return;
        }

        NoGCAllocator a = g_app.allocator;

        // TODO: generate name if not supplied
        String n = name.makeString(a);

        ZigbeeCoordinator coordinator = a.allocT!ZigbeeCoordinator(n.move, i);
        coordinators.insert(coordinator.name[], coordinator);

//        writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
    }


    // some useful tools zigbee...
    import protocol.ezsp.commands;

    RequestState scan(Session session, const(char)[] ezsp_client, Nullable!bool energy_scan)
    {
        EZSPClient c = getModule!EZSPProtocolModule.getClient(ezsp_client);
        if (!c)
        {
            session.writeLine("EZSP client does not exist: ", ezsp_client);
            return null;
        }

        RequestState state = g_app.allocator.allocT!RequestState(session, c);
        c.setMessageHandler(&state.messageHandler);
        c.sendCommand!EZSP_StartScan(&state.startScan, energy_scan ? EzspNetworkScanType.ENERGY_SCAN : EzspNetworkScanType.ACTIVE_SCAN, 0x07FFF800, 3);
        return state;
    }
}


class RequestState : FunctionCommandState
{
nothrow @nogc:

    EZSPClient client;
    bool finished = false;

    MonoTime startTime;

    this(Session session, EZSPClient client)
    {
        super(session);
        this.client = client;
        startTime = getTime();
    }

    override CommandCompletionState update()
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

        if (getTime() - startTime > 5.seconds)
        {
            session.writeLine("Zigbee scan timed out");
            finished = true;
        }

        if (finished)
            return CommandCompletionState.Finished;
        return CommandCompletionState.InProgress;
    }

    void startScan(sl_status state)
    {
        if (state != sl_status.OK)
        {
            session.writeLine("Zigbee scan failed: ", state);
            finished = true;
        }
        else
            session.writeLine("Zigbee scan started");
    }

    void messageHandler(ubyte sequence, ushort command, const(ubyte)[] message) nothrow @nogc
    {
        switch (command)
        {
            case EZSP_EnergyScanResultHandler.Command:
                EZSP_EnergyScanResultHandler.Response r;
                if (message.ezspDeserialise(r) == 0)
                    return;
                session.writef("Energy scan: channel {0} = {1}dBm\n", r.channel, r.maxRssiValue);
                break;
            case EZSP_NetworkFoundHandler.Command:
                EZSP_NetworkFoundHandler.Response r;
                if (message.ezspDeserialise(r) == 0)
                    return;
                session.writef("Network found: channel={0} PAN-ID={1,04x} ({2, 0}) {'ALLOW-JOIN', ?3} - lqi: {4}({5}dBm)\n", r.networkFound.channel, r.networkFound.panId, cast(void[])r.networkFound.extendedPanId[], r.networkFound.allowingJoin, r.lastHopLqi, r.lastHopRssi);
                break;
            case EZSP_ScanCompleteHandler.Command:
                EZSP_ScanCompleteHandler.Response r;
                if (message.ezspDeserialise(r) == 0)
                    return;
                if (r.status == EmberStatus.SUCCESS)
                    session.writeLine("Zigbee scan complete");
                else
                    session.writeLine("Zigbee scan failed at channel: ", r.channel);
                finished = true;
                break;
            default:
                session.writef("Zigbee message: {0} 0x{1,04x} - {2}", sequence, command, cast(void[])message);
                break;
        }
    }
}
