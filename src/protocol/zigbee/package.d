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
import manager.console.function_command : FunctionCommandState, NamedArgument;
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
    MonoTime retry_after;
    ubyte interview_failures;

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
        g_app.console.register_command!zcl_read("/protocol/zigbee", this, "read");
        g_app.console.register_command!zcl_write("/protocol/zigbee", this, "write");
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

    void detach_all_nodes(BaseInterface iface)
    {
        foreach (ref kvp; nodes_by_eui)
        {
            if (kvp.value.via is iface)
            {
                if (kvp.value.pan_id != 0xFFFF && kvp.value.id != 0xFFFE)
                    detach_node(kvp.value.pan_id, kvp.value.id);
                kvp.value.scan_in_progress = false;
            }
        }
    }

    void remove_all_nodes(BaseInterface iface)
    {
        foreach (kvp; nodes_by_eui)
        {
            if (kvp.value.via is iface)
            {
                if (kvp.value.pan_id != 0xFFFF && kvp.value.id != 0xFFFE)
                    detach_node(kvp.value.pan_id, kvp.value.id);
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

    // /protocol/zigbee/read command
    FunctionCommandState zcl_read(Session session, ZigbeeEndpoint source, ref const(Variant) node, ubyte endpoint, ushort cluster, ref const(Variant) attributes)
    {
        Array!ushort attrs;
        if (!parse_attr_list(attributes, attrs))
        {
            session.write_line("Invalid attribute value");
            return null;
        }

        NodeMap* nm = resolve_node(session, node);
        if (!nm)
            return null;

        if (cluster == 0xEF00)
            return tuya_read(session, source, nm, endpoint, attrs);

        auto state = g_app.allocator.allocT!ZCLReadState(session, source, nm.id, endpoint, cluster, attrs);
        state.send_requests();
        return state;
    }

    static FunctionCommandState tuya_read(Session session, ZigbeeEndpoint source, NodeMap* nm, ubyte endpoint, ref Array!ushort attrs)
    {
        foreach (dp_id; attrs[])
        {
            if (dp_id >= 256)
            {
                session.write_line("Invalid Tuya DP id (must be 0-255)");
                return null;
            }
        }

        // Clear requested DPs from cache so we can detect fresh values
        foreach (dp_id; attrs[])
            nm.tuya_datapoints.remove(cast(ubyte)dp_id);

        // Send tuya_data_query to request device to report all DPs
        ubyte[2] buffer = void;
        buffer[0..2] = tuya_seq.nativeToBigEndian;
        ++tuya_seq;
        tuya_seq += tuya_seq == 0;

        source.send_zcl_message(nm.id, endpoint, source.profile_id, 0xEF00,
            ZCLCommand.tuya_data_query, 0, buffer[], PCP.be);

        return g_app.allocator.allocT!TuyaReadState(session, nm, attrs);
    }

    // /protocol/zigbee/write command
    ZCLWriteState zcl_write(Session session, ZigbeeEndpoint source, ref const(Variant) node, ubyte endpoint, ushort cluster, ushort attribute, ref const(Variant) value, Nullable!ZCLDataType type)
    {
        NodeMap* nm = resolve_node(session, node);
        if (!nm)
            return null;

        if (cluster == 0xEF00)
            return tuya_write(session, source, nm, endpoint, attribute, value);

        ZCLDataType data_type = ZCLDataType.no_data;
        if (type)
            data_type = type.value;
        else
        {
            NodeMap.Endpoint* ep = endpoint in nm.endpoints;
            if (ep)
            {
                NodeMap.Cluster* cl = cluster in ep.clusters;
                if (cl)
                {
                    NodeMap.Attribute* attr = attribute in cl.attributes;
                    if (attr && attr.data_type != ZCLDataType.no_data)
                        data_type = attr.data_type;
                }
            }
        }

        auto state = g_app.allocator.allocT!ZCLWriteState(session, source, nm, endpoint, cluster, attribute, value, data_type);
        if (data_type != ZCLDataType.no_data)
            state.send_write();
        else
            state.send_type_discovery();
        return state;
    }

    static ZCLWriteState tuya_write(Session session, ZigbeeEndpoint source, NodeMap* nm, ubyte endpoint, ushort attribute, ref const(Variant) value)
    {
        if (attribute >= 256)
        {
            session.write_line("Invalid Tuya DP id (must be 0-255)");
            return null;
        }

        // Encode Tuya DP frame: [seq_hi, seq_lo, dp_id, dp_type, len_hi, len_lo, data...]
        ubyte[256] buffer = void;
        buffer[0..2] = tuya_seq.nativeToBigEndian;
        ++tuya_seq;
        tuya_seq += tuya_seq == 0;

        buffer[2] = cast(ubyte)attribute;

        ubyte dp_type;
        ptrdiff_t data_len;

        if (value.isBool)
        {
            dp_type = 1; // bool
            buffer[6] = value.as!bool ? 1 : 0;
            data_len = 1;
        }
        else if (value.isNumber)
        {
            dp_type = 2; // value (uint32 big-endian)
            buffer[6..10] = (value.as!uint).nativeToBigEndian;
            data_len = 4;
        }
        else if (value.isString)
        {
            dp_type = 3; // string
            const(char)[] str = value.asString[];
            if (str.length > 245) // 256 - 11 bytes overhead
            {
                session.write_line("String value too long for Tuya DP");
                return null;
            }
            buffer[6 .. 6 + str.length] = cast(const(ubyte)[])str[];
            data_len = str.length;
        }
        else
        {
            session.write_line("Unsupported value type for Tuya DP");
            return null;
        }

        buffer[3] = dp_type;
        buffer[4..6] = (cast(ushort)data_len).nativeToBigEndian;

        source.send_zcl_message(nm.id, endpoint, source.profile_id, 0xEF00,
            ZCLCommand.tuya_data_request, 0, buffer[0 .. 6 + data_len], PCP.be);
        session.writef("Sent Tuya DP {0} = {1}\n", attribute, value);
        return null;
    }

    NodeMap* resolve_node(Session session, ref const Variant node_arg)
    {
        EUI64 eui;
        ulong addr;
        size_t taken;
        const(char)[] node_str;

        if (node_arg.isNumber)
        {
            addr = node_arg.as!ulong;
            goto from_nwk;
        }
        if (node_arg.isUser!EUI64)
        {
            eui = node_arg.as!EUI64;
            goto from_eui;
        }
        if (!node_arg.isString || node_arg.empty)
        {
            session.write_line("Invalid node argument");
            return null;
        }

        node_str = node_arg.asString;
        foreach (ref kvp; nodes_by_eui)
        {
            if (kvp.value.name[] == node_str[])
            {
                if (!kvp.value.available)
                {
                    session.write_line("Node '", node_str, "' is not available (not joined)");
                    return null;
                }
                return &kvp.value();
            }
        }

        if (eui.fromString(node_str) == EUI64.StringLen)
        {
        from_eui:
            NodeMap* n = find_node(eui);
            if (!n)
            {
                session.write_line("EUI64 ", eui, " not found in node registry");
                return null;
            }
            if (!n.available)
            {
                session.write_line("Node ", eui, " is not available (not joined)");
                return null;
            }
            return n;
        }

        addr = parse_uint_with_base(node_str, &taken);
        if (taken == node_str.length)
        {
        from_nwk:
            if (addr >= 0xFFF8)
            {
                session.writef("Invalid nwk address: {0,04x}\n", addr);
                return null;
            }
            ushort nwk = cast(ushort)addr;

            // TODO: a better lookup is possible!
            foreach (ref kvp; nodes_by_eui)
            {
                if (kvp.value.id == nwk)
                    return &kvp.value();
            }
            session.writef("No registered node with nwk address {0,04x}\n", nwk);
            return null;
        }

        session.write_line("Cannot resolve node: '", node_str, "'");
        return null;
    }
}


private:

__gshared ushort tuya_seq = 0x8000; // shared between tuya_read and tuya_write, offset from controller's counter

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

class ZCLReadState : FunctionCommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;
    MonoTime start_time;
    ubyte pending;
    ubyte retries = 3;
    bool had_error;

    ZigbeeEndpoint source;
    ushort dst;
    ubyte endpoint_id;
    ushort cluster_id;
    Array!ushort requested;
    Array!ushort remaining;
    Array!int tags;
    Array!Variant results;

    this(Session session, ZigbeeEndpoint source, ushort dst, ubyte endpoint_id, ushort cluster_id, Array!ushort attrs)
    {
        super(session);
        this.source = source;
        this.dst = dst;
        this.endpoint_id = endpoint_id;
        this.cluster_id = cluster_id;
        this.requested = attrs;
        this.remaining = attrs;
        this.results.resize(attrs.length);
        this.start_time = getTime();
    }

    void send_requests()
    {
        tags.clear();
        enum max_attrs_per_request = 20;
        ubyte[max_attrs_per_request * 2] req_buffer = void;

        size_t i = 0;
        while (i < remaining.length)
        {
            size_t chunk = remaining.length - i;
            if (chunk > max_attrs_per_request)
                chunk = max_attrs_per_request;

            for (size_t j = 0; j < chunk; ++j)
                req_buffer[j*2 .. j*2+2][0..2] = remaining[i+j].nativeToLittleEndian;

            int tag = source.send_zcl_message(dst, endpoint_id, source.profile_id, cluster_id,
                ZCLCommand.read_attributes, 0, req_buffer[0 .. chunk*2],
                PCP.be, &response_handler, null);
            if (tag >= 0)
                tags.pushBack(tag);
            ++pending;
            i += chunk;
        }
    }

    override CommandCompletionState update()
    {
        if (state == CommandCompletionState.cancel_requested)
        {
            state = CommandCompletionState.cancelled;
            abort_pending();
        }
        else if (getTime() - start_time > 10.seconds)
        {
            state = CommandCompletionState.timeout;
            abort_pending();
            session.write_line("ZCL read timed out");
        }
        return state;
    }

    override void request_cancel()
    {
        if (state == CommandCompletionState.in_progress)
            state = CommandCompletionState.cancel_requested;
    }

    void abort_pending()
    {
        foreach (tag; tags[])
            source.abort_zcl_request(tag);
        tags.clear();
    }

    void response_handler(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void*) nothrow @nogc
    {
        if (state >= CommandCompletionState.cancel_requested)
            return;

        if (result != ZigbeeResult.success)
        {
            session.write_line("ZCL read failed: ", result);
            had_error = true;
            return finish();
        }

        if (hdr.command == ZCLCommand.default_response)
        {
            if (message.length >= 2)
                session.writef("ZCL default response: command=0x{0,02x} status={1}\n", message[0], cast(ZCLStatus)message[1]);
            else
                session.write_line("ZCL default response (malformed)");
            had_error = true;
            return finish();
        }

        // Parse read_attributes_response:
        // for each attribute: [u16 attr_id, u8 status, (u8 data_type, value...)]
        const(ubyte)[] msg = message;
        while (msg.length >= 3)
        {
            ushort attr_id = msg[0..2].littleEndianToNative!ushort;
            ubyte status = msg[2];
            msg = msg[3..$];

            // Mark this attribute as received
            foreach (idx, ref r; remaining[])
            {
                if (r == attr_id)
                {
                    remaining.remove(idx);
                    break;
                }
            }

            if (status != ZCLStatus.success)
            {
                session.writef("  attr {0,04x}: error {1}\n", attr_id, cast(ZCLStatus)status);
                continue;
            }

            if (msg.length < 1)
                break;
            ZCLDataType dtype = cast(ZCLDataType)msg[0];
            msg = msg[1..$];

            Variant val;
            ptrdiff_t taken = get_zcl_value(dtype, msg, val);
            if (taken < 0)
            {
                session.writef("  attr {0,04x}: [{1}] (decode error)\n", attr_id, dtype);
                break;
            }
            msg = msg[taken..$];
            session.writef("  attr {0,04x}: [{1}] = {2}\n", attr_id, dtype, val);

            foreach (ri, id; requested[])
            {
                if (id == attr_id)
                {
                    results.ptr[ri] = val;
                    break;
                }
            }
        }

        finish();
    }

    void finish()
    {
        if (--pending > 0)
            return;

        tags.clear();

        if (state >= CommandCompletionState.cancel_requested)
            return;

        if (remaining.length > 0 && retries > 0)
        {
            --retries;
            send_requests();
            return;
        }

        if (remaining.length > 0)
        {
            session.writef("{0} attribute(s) not returned by device\n", remaining.length);
            had_error = true;
        }

        if (requested.length == 1)
            result = results[0];
        else
            result = Variant(results.move);

        state = had_error ? CommandCompletionState.error : CommandCompletionState.finished;
    }
}


class TuyaReadState : FunctionCommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;
    MonoTime start_time;

    NodeMap* nm;
    Array!ushort requested;
    Array!Variant results;

    this(Session session, NodeMap* nm, Array!ushort attrs)
    {
        super(session);
        this.nm = nm;
        this.requested = attrs;
        this.results.resize(attrs.length);
        this.start_time = getTime();
    }

    override CommandCompletionState update()
    {
        if (state == CommandCompletionState.cancel_requested)
        {
            state = CommandCompletionState.cancelled;
            return state;
        }

        // Check if all requested DPs have arrived in the cache
        bool all_received = true;
        foreach (i, dp_id; requested[])
        {
            Variant* val = cast(ubyte)dp_id in nm.tuya_datapoints;
            if (val)
                results.ptr[i] = *val;
            else
                all_received = false;
        }

        if (all_received)
            return finish(false);

        if (getTime() - start_time > 10.seconds)
        {
            session.write_line("Tuya read timed out");
            return finish(true);
        }

        return state;
    }

    override void request_cancel()
    {
        if (state == CommandCompletionState.in_progress)
            state = CommandCompletionState.cancel_requested;
    }

private:
    CommandCompletionState finish(bool had_timeout)
    {
        foreach (i, dp_id; requested[])
        {
            if (!results[i].isNull)
                session.writef("  dp {0}: {1}\n", dp_id, results[i]);
            else
                session.writef("  dp {0}: (no response)\n", dp_id);
        }

        if (requested.length == 1)
            result = results[0];
        else
            result = Variant(results.move);

        state = had_timeout ? CommandCompletionState.timeout : CommandCompletionState.finished;
        return state;
    }
}


class ZCLWriteState : FunctionCommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;
    MonoTime start_time;

    ZigbeeEndpoint source;
    NodeMap* node;
    ubyte endpoint_id;
    ushort cluster_id;
    ushort attribute_id;
    Variant write_value;
    ZCLDataType data_type;
    int pending_tag = -1;

    this(Session session, ZigbeeEndpoint source, NodeMap* node, ubyte endpoint_id, ushort cluster_id, ushort attribute_id, ref const Variant write_value, ZCLDataType data_type)
    {
        super(session);
        this.source = source;
        this.node = node;
        this.endpoint_id = endpoint_id;
        this.cluster_id = cluster_id;
        this.attribute_id = attribute_id;
        this.write_value = write_value;
        this.data_type = data_type;
        this.start_time = getTime();
    }

    override CommandCompletionState update()
    {
        if (state == CommandCompletionState.cancel_requested)
        {
            state = CommandCompletionState.cancelled;
            abort_pending();
        }
        else if (getTime() - start_time > 10.seconds)
        {
            state = CommandCompletionState.timeout;
            abort_pending();
            session.write_line("ZCL write timed out");
        }
        return state;
    }

    override void request_cancel()
    {
        if (state == CommandCompletionState.in_progress)
            state = CommandCompletionState.cancel_requested;
    }

    void abort_pending()
    {
        if (pending_tag >= 0)
        {
            source.abort_zcl_request(pending_tag);
            pending_tag = -1;
        }
    }

    void send_type_discovery()
    {
        ubyte[2] read_buf = void;
        read_buf[0..2] = attribute_id.nativeToLittleEndian;
        pending_tag = source.send_zcl_message(node.id, endpoint_id, source.profile_id, cluster_id,
            ZCLCommand.read_attributes, 0, read_buf[], PCP.be, &read_response_handler, null);
    }

    void send_write()
    {
        // Build write_attributes payload: [u16 attr_id, u8 data_type, value...]
        ubyte[128] write_buffer = void;
        write_buffer[0..2] = attribute_id.nativeToLittleEndian;
        write_buffer[2] = cast(ubyte)data_type;

        ptrdiff_t val_len = set_zcl_value(data_type, write_value, write_buffer[3 .. $]);
        if (val_len < 0)
        {
            session.write_line("Failed to encode value for type ", data_type);
            state = CommandCompletionState.error;
            return;
        }

        pending_tag = source.send_zcl_message(node.id, endpoint_id, source.profile_id, cluster_id,
            ZCLCommand.write_attributes, 0, write_buffer[0 .. 3 + val_len],
            PCP.be, &write_response_handler, null);
    }

    void read_response_handler(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void*)
    {
        pending_tag = -1;

        if (state >= CommandCompletionState.cancel_requested)
            return;

        if (result != ZigbeeResult.success)
        {
            session.write_line("ZCL read (type discovery) failed: ", result);
            state = CommandCompletionState.error;
            return;
        }

        if (hdr.command == ZCLCommand.default_response)
        {
            if (message.length >= 2)
                session.writef("ZCL read (type discovery) default response: status={0}\n", cast(ZCLStatus)message[1]);
            else
                session.write_line("ZCL read (type discovery) default response (malformed)");
            state = CommandCompletionState.error;
            return;
        }

        // Parse read_attributes_response: [u16 attr_id, u8 status, u8 data_type, value...]
        if (message.length < 4)
        {
            session.write_line("ZCL read response too short for type discovery");
            state = CommandCompletionState.error;
            return;
        }

        ushort resp_attr_id = message[0..2].littleEndianToNative!ushort;
        ubyte status = message[2];

        if (status != ZCLStatus.success)
        {
            session.writef("Cannot read attribute {0,04x} to discover type: {1}\n",
                resp_attr_id, cast(ZCLStatus)status);
            state = CommandCompletionState.error;
            return;
        }

        data_type = cast(ZCLDataType)message[3];

        // Cache the discovered type and value in the NodeMap
        ref NodeMap.Attribute attr = node.get_attribute(endpoint_id, cluster_id, attribute_id);
        attr.data_type = data_type;
        Variant val;
        ptrdiff_t taken = get_zcl_value(data_type, message[4 .. $], val);
        if (taken >= 0)
        {
            attr.value = val;
            attr.last_updated = getSysTime();
        }

        session.writef("Discovered type for {0,04x}: {1}\n", attribute_id, data_type);
        send_write();
    }

    void write_response_handler(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void*)
    {
        pending_tag = -1;

        if (state >= CommandCompletionState.cancel_requested)
            return;

        if (result != ZigbeeResult.success)
        {
            session.write_line("ZCL write failed: ", result);
            state = CommandCompletionState.error;
            return;
        }

        if (hdr.command == ZCLCommand.default_response)
        {
            if (message.length >= 2)
                session.writef("ZCL default response: command=0x{0,02x} status={1}\n",
                    message[0], cast(ZCLStatus)message[1]);
            else
                session.write_line("ZCL default response (malformed)");
            state = CommandCompletionState.error;
            return;
        }

        // write_attributes_response: [0x00] on full success, or [status, u16 attr_id]... per failure
        if (message.length >= 1 && message[0] == ZCLStatus.success)
        {
            session.writef("Attribute {0,04x} written successfully\n", attribute_id);
            state = CommandCompletionState.finished;
            return;
        }

        const(ubyte)[] msg = message;
        while (msg.length >= 3)
        {
            ubyte err_status = msg[0];
            ushort err_attr_id = msg[1..3].littleEndianToNative!ushort;
            msg = msg[3 .. $];
            session.writef("Attribute {0,04x}: write error {1}\n", err_attr_id, cast(ZCLStatus)err_status);
        }
        state = CommandCompletionState.error;
    }
}


Nullable!T parse_arg(T)(ref const Variant v) nothrow @nogc
{
    if (v.isNumber)
        return Nullable!T(cast(T)v.as!uint);
    if (v.isString)
    {
        size_t taken;
        ulong val = parse_uint_with_base(v.asString, &taken);
        if (taken == v.asString.length)
            return Nullable!T(cast(T)val);
    }
    return Nullable!T();
}

bool parse_attr_list(ref const Variant v, ref Array!ushort attrs) nothrow @nogc
{
    if (v.isNumber && v.as!ulong < 0xFFFF)
    {
        attrs.pushBack(cast(ushort)v.as!uint);
        return true;
    }
    if (v.isArray)
    {
        foreach (ref elem; v.asArray[])
        {
            Nullable!ushort val = parse_arg!ushort(elem);
            if (!val)
                return false;
            attrs.pushBack(val.value);
        }
        return attrs.length > 0;
    }
    if (v.isString)
    {
        // TODO: parse comma separated list?
        Nullable!ushort val = parse_arg!ushort(v);
        if (!val)
            return false;
        attrs.pushBack(val.value);
        return true;
    }
    return false;
}
