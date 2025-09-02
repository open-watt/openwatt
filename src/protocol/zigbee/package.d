module protocol.zigbee;

import urt.array;
import urt.conv : parse_uint_with_base;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.ezsp;
import protocol.ezsp.client;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;

import router.iface;
import router.iface.zigbee;

nothrow @nogc:


struct NodeMap
{
    struct Endpoint
    {
        // TODO: name...?
        ubyte endpoint;
        ushort profile;
        ushort device;
        Array!ushort in_clusters;
        Array!ushort out_clusters;
    }

    String name;
    EUI64 eui;
    ushort id = 0xFFFE; // not online
    MACAddress mac;
    bool discovered;
    ZigbeeInterface iface;
    Map!(ubyte, Endpoint) endpoints;
}

class ZigbeeProtocolModule : Module
{
    mixin DeclareModule!"protocol.zigbee";
nothrow @nogc:

    Map!(EUI64, NodeMap) nodes;
    Map!(MACAddress, NodeMap*) nodes_by_mac;

    Collection!ZigbeeInterface zigbee_interfaces;
    Collection!ZigbeeCoordinator coordinators;
    Collection!ZigbeeEndpoint endpoints;

    Map!(ubyte, ZigbeeEndpoint) endpoint_by_id;

    override void init()
    {
        g_app.console.registerCollection("/interface/zigbee", zigbee_interfaces);
        g_app.console.registerCollection("/protocol/zigbee/coordinator", coordinators);
        g_app.console.registerCollection("/protocol/zigbee/endpoint", endpoints);

        g_app.console.registerCommand!scan("/protocol/zigbee", this);
    }

    override void update()
    {
        // TODO: check; should coordinators or inrterfaces come first?
        //       does one produce changes which will be consumed by the other?
        zigbee_interfaces.update_all();
        coordinators.update_all();
        endpoints.update_all();
    }

    NodeMap* add_node(EUI64 eui, MACAddress mac, ZigbeeInterface iface)
    {
        assert(eui !in nodes, "Already exists");

        NodeMap* n = nodes.insert(eui, NodeMap(eui: eui, mac: mac, iface: iface));
        nodes_by_mac.insert(mac, n);
        return n;
    }

    void remove_node(EUI64 eui)
    {
        NodeMap* n = eui in nodes;
        if (!n)
            return;
        nodes_by_mac.remove(n.mac);
        nodes.remove(eui);
    }

    void remove_all_nodes(BaseInterface iface)
    {
        foreach (kvp; nodes)
        {
            if (kvp.value.iface is iface)
            {
                nodes_by_mac.remove(kvp.value.mac);
                nodes.remove(kvp.key);
            }
        }
    }

    NodeMap* find_node(EUI64 eui)
        => eui in nodes;

    NodeMap* find_node(BaseInterface iface)
        => find_node(iface.mac);

    NodeMap* find_node(MACAddress mac)
    {
        auto n = mac in nodes_by_mac;
        if (!n)
            return null;
        return *n;
    }
/+
    UNCOMMENT THIS!!@!
    ZigbeeEndpoint addEndpoint(String name, BaseInterface iface, int endpointId = -1, ushort profile, ushort device, ushort[] in_clusters, ushort[] out_clusters)
    {
        NodeMap* n = find_node(iface);
        if (!n)
        {
            ZigbeeInterface zi = cast(ZigbeeInterface)iface;

            ubyte[8] eui = void;
            if (zi && zi.eui != ubyte[8].init)
                eui = zi.eui;
            else
            {
                import urt.crc;
                import urt.endian;
                eui[0..6] = iface.mac.b[0..6];
                eui[6..8] = nativeToLittleEndian(calculate_crc!(Algorithm.crc16_ezsp)(iface.name[]));

                if (zi)
                    zi.eui = eui;
            }

            n = add_node(eui, iface.mac, iface);
        }

        if (endpointId == -1)
        {
            endpointId = 1;
            while (endpointId in n.endpoints)
                ++endpointId;
            assert(endpointId < 241, "No free endpoint id available");
        }
        ubyte endpoint = cast(ubyte)endpointId;

        NodeMap.Endpoint* ne = n.endpoints.insert(endpoint, NodeMap.Endpoint(endpoint, profile, device));
        ne.in_clusters = in_clusters;
        ne.out_clusters = out_clusters;

        ZigbeeEndpoint ep = g_app.allocator.allocT!ZigbeeEndpoint(name.move, iface, endpoint, profile, device, in_clusters, out_clusters);
        endpoints.insert(ep.name[], ep);
        endpoint_by_id.insert(ep.endpoint, ep);

        return ep;
    }
+/

/+
    // /protocol/zigbee/endpoint/add command
    void endpoint_add(Session session, const(char)[] name, const(char)[] _interface, Nullable!ubyte id, Nullable!(const(char)[]) profile, Nullable!(const(char)[]) device, Nullable!(ushort[]) in_clusters, Nullable!(ushort[]) out_clusters)
    {
        BaseInterface i = getModule!InterfaceModule.interfaces.get(_interface);
        if(i is null)
        {
            session.writeLine("Interface '", _interface, "' not found");
            return;
        }

        ushort p = 0x0104; // default to ha
        if (profile)
        {
            switch (profile.value)
            {
                case "zdo":
                case "zdp":     p = 0x0000; break;
                case "ipm":     p = 0x0101; break; // industrial plant monitoring
                case "ha":
                case "zha":     p = 0x0104; break; // home assistant
                case "ba":
                case "cba":     p = 0x0105; break; // building automation
                case "ta":      p = 0x0107; break; // telco automation
                case "hc":
                case "hcp":
                case "phhc":    p = 0x0108; break; // health care
                case "zse":
                case "se":      p = 0x0109; break; // smart energy
                case "gp":
                case "zgp":     p = 0xA1E0; break; // green power
                case "zll":     p = 0xC05E; break; // only for the commissioning cluster (0x1000); zll commands use `ha`
                default:
                    size_t taken;
                    ulong ul = parse_uint_with_base(profile.value, &taken);
                    if (taken == 0 || taken != profile.value.length || ul > ushort.max)
                    {
                        session.writeLine("Invalid profile: ", profile.value);
                        return;
                    }
                    p = cast(ushort)ul;
                    break;
            }
        }
        ushort d = 0x0007; // combined interface
        if (device)
        {
            switch (device.value)
            {
                // TODO: are there standard device names?
//                case "onoff": d = 0x0000; break;

                default:
                    size_t taken;
                    ulong ul = parse_uint_with_base(device.value, &taken);
                    if (taken == 0 || taken != device.value.length || ul > ushort.max)
                    {
                        session.writeLine("Invalid device: ", device.value);
                        return;
                    }
                    d = cast(ushort)ul;
                    break;
            }
        }

        NoGCAllocator a = g_app.allocator;

        // TODO: generate name if not supplied
        String n = name.makeString(a);

        ZigbeeEndpoint endpoint = addEndpoint(n.move, i, id ? id.value : -1, p, d, in_clusters ? in_clusters.value : null, out_clusters ? out_clusters.value : null);

        writeInfof("Create Zigbee endpoint '{0}' - interface: {1}", name, i.name);
    }
+/
    // some useful tools zigbee...
    import protocol.ezsp.commands;

    // /protocol/zigbee/scan command
    RequestState scan(Session session, const(char)[] ezsp_client, Nullable!bool energy_scan)
    {
        EZSPClient c = get_module!EZSPProtocolModule.clients.get(ezsp_client);
        if (!c)
        {
            session.writeLine("EZSP client does not exist: ", ezsp_client);
            return null;
        }

        RequestState state = g_app.allocator.allocT!RequestState(session, c);
        c.set_message_handler(&state.message_handler);
        c.send_command!EZSP_StartScan(&state.start_scan, energy_scan ? EzspNetworkScanType.ENERGY_SCAN : EzspNetworkScanType.ACTIVE_SCAN, 0x07FFF800, energy_scan ? 1 : 3);
        return state;
    }
}


class RequestState : FunctionCommandState
{
nothrow @nogc:

    EZSPClient client;
    bool finished = false;

    MonoTime start_time;

    this(Session session, EZSPClient client)
    {
        super(session);
        this.client = client;
        start_time = getTime();
    }

    override CommandCompletionState update()
    {
        if (state == CommandCompletionState.CancelRequested)
        {
            client.send_command!EZSP_StopScan(&stop_scan);
            state = CommandCompletionState.CancelPending;
        }
        else if (getTime() - start_time > 5.seconds)
        {
            session.writeLine("Zigbee scan timed out");
            state = CommandCompletionState.Timeout;
        }

        return state;
    }

    void start_scan(sl_status state)
    {
        if (state != sl_status.OK)
        {
            session.writeLine("Zigbee scan failed: ", state);
            this.state = CommandCompletionState.Error;
        }
        else
            session.writeLine("Zigbee scan started");
    }

    void stop_scan(EmberStatus status)
    {
        // the scan is stopped...
        assert(false, "TODO: test this!");

        // flag as finished, but maybe we should flag an error state to emit a message or something?
        state = CommandCompletionState.Cancelled;
    }

    void message_handler(ubyte sequence, ushort command, const(ubyte)[] message) nothrow @nogc
    {
        switch (command)
        {
            case EZSP_EnergyScanResultHandler.Command:
                EZSP_EnergyScanResultHandler.Response r;
                if (message.ezsp_deserialise(r) == 0)
                    return;
                session.writef("Energy scan: channel {0} = {1}dBm\n", r.channel, r.maxRssiValue);
                break;
            case EZSP_NetworkFoundHandler.Command:
                EZSP_NetworkFoundHandler.Response r;
                if (message.ezsp_deserialise(r) == 0)
                    return;
                session.writef("Network found: channel={0} PAN-ID={1,04x} ({2, 0}) {'ALLOW-JOIN', ?3} - lqi: {4}({5}dBm)\n", r.networkFound.channel, r.networkFound.panId, cast(void[])r.networkFound.extendedPanId[], r.networkFound.allowingJoin, r.lastHopLqi, r.lastHopRssi);
                break;
            case EZSP_ScanCompleteHandler.Command:
                EZSP_ScanCompleteHandler.Response r;
                if (message.ezsp_deserialise(r) == 0)
                    return;
                if (r.status == EmberStatus.SUCCESS)
                {
                    session.writeLine("Zigbee scan complete");
                    state = CommandCompletionState.Finished;
                }
                else
                {
                    session.writeLine("Zigbee scan failed at channel: ", r.channel);
                    state = CommandCompletionState.Error;
                }
                break;
            default:
                session.writef("Zigbee message: {0} 0x{1,04x} - {2}", sequence, command, cast(void[])message);
                break;
        }
    }
}
