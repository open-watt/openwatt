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
import urt.variant;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.device;
import manager.plugin;

import protocol.ezsp;
import protocol.ezsp.client;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;
import protocol.zigbee.controller;
import protocol.zigbee.router;
import protocol.zigbee.zcl;

import router.iface;
import router.iface.zigbee;

nothrow @nogc:


enum NodeType : ubyte
{
    unknown = 0,
    coordinator = 1,
    router = 2,
    end_device = 3,
    sleepy_end_device = 4
}

enum CurrentPowerMode : ubyte
{
    receiver_on_when_idle = 0,
    receiver_off_when_idle = 1,
    rx_on_during_periodic_intervals = 2,
}

enum PowerSource : ubyte
{
    mains = 1,
    battery = 2,
    disposable_battery = 4,
}

enum ZigbeeResult : ubyte
{
    success = 0,
    failed,
    buffered,
    insufficient_buffer,
    truncated,
    unexpected,
    pending,
    aborted,
    no_network,
    timeout,
    invalid_parameter,
    not_permitted,
    unsupported_cluster,
    unsupported
}

struct NodeMap
{
    struct BasicInfo
    {
        // basic info: (from basic cluster)
        ubyte zcl_ver;
        ubyte app_ver;
        ubyte stack_ver;
        ubyte hw_ver;
        ZCLPowerSource power_source;
        String mfg_name;
        String model_name;
        String sw_build_id;
        String product_code;
        String product_url;
    }

    struct NodeDescriptor
    {
        NodeType type;
        ubyte freq_bands;
        ubyte mac_capabilities;

        ushort manufacturer_code;

        ubyte server_capabilities;
        ubyte stack_compliance_revision;

        ubyte max_nsdu; // max message payload size
        ushort max_asdu_in; // max message size with fragmentation
        ushort max_asdu_out;

        bool complex_desc;
        bool user_desc;
        bool extended_active_ep_list;
        bool extended_simple_desc_list;
    }

    struct PowerDescriptor
    {
        CurrentPowerMode current_mode;
        ubyte available_sources;
        ubyte current_source;
        ubyte batt_level; // percent
    }

    struct Endpoint
    {
        ubyte endpoint;
        bool dynamic;
        ushort profile_id;
        ushort device_id;
        ubyte device_version;
        ubyte initialised;
        Map!(ushort, Cluster) clusters;
        Array!ushort out_clusters; // the clusters that this endpoint can send requests to

    nothrow @nogc:
        bool has_cluster(ushort cluster_id) const pure
            => (cluster_id in clusters) !is null;

        ref Cluster get_cluster(ushort cluster_id)
        {
            Cluster* cluster = cluster_id in clusters;
            if (!cluster)
                cluster = clusters.insert(cluster_id, Cluster(cluster_id: cluster_id, dynamic: true));
            return *cluster;
        }

        ref Attribute get_attribute(ushort cluster_id, ushort attribute_id)
            => get_cluster(cluster_id).get_attribute(attribute_id);
    }

    struct Cluster
    {
        ushort cluster_id;
        bool dynamic; // true when the cluster was reported but not listed in the zdo...
        ubyte initialised;
        bool scan_in_progress;
        Map!(ushort, Attribute) attributes;

    nothrow @nogc:
        ref Attribute get_attribute(ushort attribute_id)
        {
            Attribute* attr = attribute_id in attributes;
            if (!attr)
                attr = attributes.insert(attribute_id, Attribute(attribute_id: attribute_id, data_type: ZCLDataType.no_data));
            return *attr;
        }
    }

    struct Attribute
    {
        ushort attribute_id;
        ZCLDataType data_type;
        ZCLAccess access;
        Variant value;
        SysTime last_updated;

    nothrow @nogc:
        this(this) @disable;
        this(ref Attribute rh)
        {
            this.attribute_id = rh.attribute_id;
            this.data_type = rh.data_type;
            this.value = rh.value;
            this.last_updated = rh.last_updated;
        }
        version (EnableMoveSemantics) {
        this(Attribute rh)
        {
            this.attribute_id = rh.attribute_id;
            this.data_type = rh.data_type;
            this.value = rh.value.move;
            this.last_updated = rh.last_updated;
        }
        }
    }

    String name;
    EUI64 eui;

    ZigbeeNode node;
    BaseInterface via; // TODO: do we need this? DELETE ME?

    Device device; // if a device has been created for this node

    ushort pan_id = 0xFFFF; // not joined
    ushort id = 0xFFFE; // not online
    ushort parent_id = 0xFFFE;
    bool discovered;

    ubyte initialised;
    bool scan_in_progress;
    bool device_created;

    ubyte lqi;
    byte rssi;

    NodeDescriptor desc;
    PowerDescriptor power;
    BasicInfo basic_info;

    Map!(ubyte, Endpoint) endpoints;
    Map!(ubyte, Variant) tuya_datapoints;

    SysTime last_seen;

nothrow @nogc:
    bool available() const pure
        => pan_id != 0xFFFF && id != 0xFFFE;

    ref Endpoint get_endpoint(ubyte endpoint_id)
    {
        Endpoint* ep = endpoint_id in endpoints;
        if (ep is null)
        {
            ep = endpoints.insert(endpoint_id, Endpoint(endpoint: endpoint_id, dynamic: true));
            initialised &= 0xF;
        }
        return *ep;
    }

    ref Cluster get_cluster(ubyte endpoint_id, ushort cluster_id)
    {
        ref Endpoint ep = get_endpoint(endpoint_id);
        return ep.get_cluster(cluster_id);
    }

    ref Attribute get_attribute(ubyte endpoint_id, ushort cluster_id, ushort attribute_id)
    {
        ref Endpoint ep = get_endpoint(endpoint_id);
        return ep.get_attribute(cluster_id, attribute_id);
    }

    MutableString!0 get_fingerprint()
    {
        // build a fingerprint string...
        if (basic_info.sw_build_id)
            return MutableString!0(Concat, basic_info.mfg_name, ':', basic_info.model_name, ':', basic_info.sw_build_id);
        else
            return MutableString!0(Concat, basic_info.mfg_name, ':', basic_info.model_name, ':', basic_info.hw_ver, '.', basic_info.app_ver);
    }
}

class ZigbeeProtocolModule : Module
{
    mixin DeclareModule!"protocol.zigbee";
nothrow @nogc:

    struct UnknownNode
    {
        BaseInterface via;
        ushort pan_id;
        ushort id;
        bool scanning;
    }


    Map!(EUI64, NodeMap) nodes_by_eui;
    Map!(uint, NodeMap*) nodes_by_pan;
    Array!UnknownNode unknown_nodes;

    Collection!ZigbeeInterface zigbee_interfaces;
    Collection!ZigbeeNode nodes;
    Collection!ZigbeeRouter routers;
    Collection!ZigbeeCoordinator coordinators;
    Collection!ZigbeeEndpoint endpoints;
    Collection!ZigbeeController controllers;

    override void init()
    {
        g_app.console.register_collection("/interface/zigbee", zigbee_interfaces);
        g_app.console.register_collection("/protocol/zigbee/node", nodes);
        g_app.console.register_collection("/protocol/zigbee/router", routers);
        g_app.console.register_collection("/protocol/zigbee/coordinator", coordinators);
        g_app.console.register_collection("/protocol/zigbee/endpoint", endpoints);
        g_app.console.register_collection("/protocol/zigbee/controller", controllers);

        g_app.console.register_command!scan("/protocol/zigbee", this);
    }

    override void update()
    {
        // TODO: check; should coordinators or interfaces come first?
        //       does one produce changes which will be consumed by the other?
        zigbee_interfaces.update_all();
        coordinators.update_all();
        // TODO: routers? nodes? should they be updated together? shoud routers populate the node pool?
        endpoints.update_all();
        controllers.update_all();
    }

    NodeMap* add_node(EUI64 eui, BaseInterface via = null)
    {
        assert(!eui.is_zigbee_broadcast, "Invalid EUI64");
        assert(eui !in nodes_by_eui, "Already exists");
        return nodes_by_eui.insert(eui, NodeMap(eui: eui, discovered: via !is null, via: via));
    }

    NodeMap* attach_node(EUI64 eui, ushort pan_id, ushort id)
    {
        assert(!eui.is_zigbee_broadcast, "Invalid EUI64");
        assert(pan_id != 0xFFFF && id != 0xFFFE, "Invalid pan_id/id");

        NodeMap* n = eui in nodes_by_eui;
        if (!n)
            n = nodes_by_eui.insert(eui, NodeMap(eui: eui));
        if ((n.id != 0xFFFE && id != n.id) || (n.pan_id != 0xFFFF && pan_id != n.pan_id))
            detach_node(n.pan_id, n.id);
        n.id = id;
        n.pan_id = pan_id;
        nodes_by_pan.insert((cast(uint)pan_id << 16) | id, n);
        return n;
    }

    void remove_node(EUI64 eui)
    {
        NodeMap* n = eui in nodes_by_eui;
        if (!n)
            return;
        if (n.pan_id != 0xFFFF && n.id != 0xFFFE)
            detach_node(n.pan_id, n.id);
        nodes_by_eui.remove(eui);
    }

    void detach_node(ushort pan_id, ushort id)
    {
        foreach (i, ref unk; unknown_nodes)
        {
            if (pan_id == unk.pan_id && id == unk.id)
            {
                unknown_nodes.remove(i);
                break;
            }
        }

        uint local_id = ((cast(uint)pan_id << 16) | id);
        NodeMap** n = local_id in nodes_by_pan;
        if (!n)
            return;
        (*n).pan_id = 0xFFFF;
        (*n).id = 0xFFFE;
        nodes_by_pan.remove(local_id);
    }

    void remove_all_nodes(BaseInterface iface)
    {
        foreach (kvp; nodes_by_eui)
        {
            if (kvp.value.discovered && kvp.value.via is iface)
            {
                nodes_by_eui.remove(kvp.key);
            }
        }
    }

    NodeMap* find_node(EUI64 eui)
        => eui in nodes_by_eui;

    NodeMap* find_node(ushort pan_id, ushort id)
    {
        NodeMap** n = ((cast(uint)pan_id << 16) | id) in nodes_by_pan;
        if (n)
            return *n;
        return null;
    }

    void discover_node(BaseInterface via, ushort pan_id, ushort id)
    {
        if (find_node(pan_id, id))
            return;
        foreach (ref n; unknown_nodes)
        {
            if (n.pan_id == pan_id && n.id == id)
                return;
        }
        unknown_nodes.pushBack(UnknownNode(via, pan_id, id));
    }

    // some useful tools zigbee...
    import protocol.ezsp.commands;

    // /protocol/zigbee/scan command
    EnergyScanState scan(Session session, const(char)[] ezsp_client, Nullable!bool energy_scan)
    {
        EZSPClient c = get_module!EZSPProtocolModule.clients.get(ezsp_client);
        if (!c)
        {
            session.write_line("EZSP client does not exist: ", ezsp_client);
            return null;
        }

        EnergyScanState state = g_app.allocator.allocT!EnergyScanState(session, c);
        c.set_message_handler(&state.message_handler);
        c.send_command!EZSP_StartScan(&state.start_scan, energy_scan ? EzspNetworkScanType.ENERGY_SCAN : EzspNetworkScanType.ACTIVE_SCAN, 0x07FFF800, energy_scan ? 1 : 3);
        return state;
    }
}


class EnergyScanState : FunctionCommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;

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
        if (state == CommandCompletionState.cancel_requested)
        {
            client.send_command!EZSP_StopScan(&stop_scan);
            state = CommandCompletionState.cancel_pending;
        }
        else if (getTime() - start_time > 5.seconds)
        {
            session.write_line("Zigbee scan timed out");
            state = CommandCompletionState.timeout;
        }

        return state;
    }

    override void request_cancel()
    {
        if (state == CommandCompletionState.in_progress)
            state = CommandCompletionState.cancel_requested;
    }

    void start_scan(sl_status state)
    {
        if (state != sl_status.OK)
        {
            session.write_line("Zigbee scan failed: ", state);
            this.state = CommandCompletionState.error;
        }
        else
            session.write_line("Zigbee scan started");
    }

    void stop_scan(EmberStatus status)
    {
        // the scan is stopped...
        assert(false, "TODO: test this!");

        // flag as finished, but maybe we should flag an error state to emit a message or something?
        state = CommandCompletionState.cancelled;
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
                    session.write_line("Zigbee scan complete");
                    state = CommandCompletionState.finished;
                }
                else
                {
                    session.write_line("Zigbee scan failed at channel: ", r.channel);
                    state = CommandCompletionState.error;
                }
                break;
            default:
                session.writef("Zigbee message: {0} 0x{1,04x} - {2}", sequence, command, cast(void[])message);
                break;
        }
    }
}
