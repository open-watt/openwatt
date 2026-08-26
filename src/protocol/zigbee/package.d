module protocol.zigbee;

import urt.array;
import urt.conv : parse_uint_with_base;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat, tformat;
import urt.meta.enuminfo : enum_key_from_value;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection;
import manager.config : ConfItem;
import manager.console.command;
import manager.console.session;
import manager.console.table;
import manager.device;
import manager.plugin;
import manager.profile;
import manager.sample.spec : stream_be_context, stream_le_context;

import protocol.ezsp;
import protocol.ezsp.client;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;
import protocol.zigbee.controller;
import protocol.zigbee.router;
import protocol.zigbee.zcl;

import router.iface;
import protocol.zigbee.iface;

nothrow @nogc:


package __gshared uint zb_section_kind;

enum TuyaDataType : ubyte
{
    raw = 0,
    bool_ = 1,
    value = 2,
    string = 3,
    enum_ = 4,
    bitmap = 5
}

struct ElementDesc_Zigbee
{
    ushort cluster_id;
    ushort attribute_id;
    ushort manufacturer_code;
    ushort desc = ushort.max;
    ubyte length;
    TuyaDataType tuya_type;
}

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
    ubyte initialised;
    ubyte interview_failures;
    ubyte lqi;
    byte rssi;
    bool discovered;
    bool scan_in_progress;
    bool woke_during_scan;
    bool device_created;
    MonoTime retry_after;

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

class ZigbeeProtocolModule : Module, ProfileSections
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

    override void init()
    {
        import protocol.zigbee.aps : APSFrame;

//        register_packet_codec!NWKFrame();
        register_packet_codec!APSFrame();

        zb_section_kind = register_profile_section("zb", this);

        g_app.console.register_collection!ZigbeeInterface();
        g_app.console.register_collection!ZigbeeNode();
        g_app.console.register_collection!ZigbeeRouter();
        g_app.console.register_collection!ZigbeeCoordinator();
        g_app.console.register_collection!ZigbeeEndpoint();
        g_app.console.register_collection!ZigbeeController();

        g_app.console.register_command!scan("/protocol/zigbee", this);
        g_app.console.register_command!(nodes_print, "nodes")("/protocol/zigbee", this);
        g_app.console.register_command!(zcl_read, "read")("/protocol/zigbee", this);
        g_app.console.register_command!(zcl_write, "write")("/protocol/zigbee", this);
    }

    uint element_size(uint)
        => cast(uint)ElementDesc_Zigbee.sizeof;

    void count_element(uint, ref const ConfItem, ref ProfileSize) {}

    bool parse_element(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        const(char)[] tail = item.value;
        ElementDesc_Zigbee* zb = cast(ElementDesc_Zigbee*)slot.ptr;
        *zb = ElementDesc_Zigbee.init;

        const(char)[] cluster = tail.split!',';
        const(char)[] attr_field = tail.split!',';
        const(char)[] attribute = attr_field.split!'(';
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] following = tail.split!','.unQuote;

        size_t taken;
        ulong value = cluster.parse_uint_with_base(&taken);
        if (taken != cluster.length || value > ushort.max)
        {
            writeWarning("Invalid Zigbee cluster ID: ", cluster);
            return false;
        }
        zb.cluster_id = cast(ushort)value;

        value = attribute.parse_uint_with_base(&taken);
        if (taken != attribute.length || value > ushort.max)
        {
            writeWarning("Invalid Zigbee attribute ID: ", attribute);
            return false;
        }
        zb.attribute_id = cast(ushort)value;

        if (attr_field.length)
        {
            if (attr_field[$-1] != ')')
            {
                writeWarning("Invalid Zigbee manufacturer code: ", attr_field);
                return false;
            }
            attr_field = attr_field[0 .. $-1].trimBack;
            value = attr_field.parse_uint_with_base(&taken);
            if (taken != attr_field.length || value > ushort.max)
            {
                writeWarning("Invalid Zigbee manufacturer code: ", attr_field);
                return false;
            }
            zb.manufacturer_code = cast(ushort)value;
        }

        if (type.empty)
            return true;

        const(char)[] value_type = type;
        const(char)[] family = value_type.split!('/', false);
        if (family.startsWith("str"))
            zb.tuya_type = TuyaDataType.string;
        else if (family.startsWith("bf"))
            zb.tuya_type = TuyaDataType.bitmap;
        else if (family.startsWith("enum"))
            zb.tuya_type = TuyaDataType.enum_;
        else if (family.startsWith("bool"))
            zb.tuya_type = TuyaDataType.bool_;
        else
            zb.tuya_type = TuyaDataType.value;

        if (zb.cluster_id == 0xEF00)
        {
            if (!b.compile_value(type, following, stream_be_context, zb.desc, zb.length))
                return false;
        }
        else if (!b.compile_value(type, following, stream_le_context, zb.desc, zb.length))
            return false;

        if (zb.cluster_id == 0xEF00)
        {
            if (zb.tuya_type == TuyaDataType.bitmap)
            {
                if (!(zb.length == 1 || zb.length == 2 || zb.length == 4))
                    writeWarning("Tuya bitmap datapoint '", b.element_id, "' must be 1, 2, 4 bytes");
            }
            else if (zb.tuya_type == TuyaDataType.enum_)
            {
                if (zb.length != 1)
                    writeWarning("Tuya enum datapoint '", b.element_id, "' must be 1 byte");
            }
            else if (zb.tuya_type == TuyaDataType.bool_)
            {
                if (zb.length != 1)
                    writeWarning("Tuya bool datapoint '", b.element_id, "' must be 1 byte");
            }
            else if (zb.tuya_type == TuyaDataType.value && zb.length != 4)
                writeWarning("Tuya value datapoint '", b.element_id, "' must be 4 bytes");
        }
        return true;
    }

    override void update()
    {
        // TODO: check; should coordinators or interfaces come first?
        //       does one produce changes which will be consumed by the other?
        Collection!ZigbeeNode().update_all();
        // TODO: routers? nodes? should they be updated together? shoud routers populate the node pool?
        Collection!ZigbeeEndpoint().update_all();
        Collection!ZigbeeController().update_all();
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
        note_awake(n);
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

        for (size_t i = 0; i < unknown_nodes.length; )
        {
            if (unknown_nodes[i].via is iface)
                unknown_nodes.remove(i);
            else
                ++i;
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

    void note_awake(NodeMap* node)
    {
        if (!node || node.initialised == 0xFF)
            return;
        foreach (ZigbeeController c; Collection!ZigbeeController().values)
            c.node_awake(node);
    }

    void discover_node(BaseInterface via, ushort pan_id, ushort id)
    {
        if (find_node(pan_id, id))
            return;
        foreach (ref n; unknown_nodes)
        {
            if (n.pan_id == pan_id && n.id == id)
            {
                note_work(); // it just spoke, so probe again while it is awake
                return;
            }
        }
        unknown_nodes.pushBack(UnknownNode(via, pan_id, id));
        note_work();
    }

    void note_work()
    {
        foreach (ZigbeeController c; Collection!ZigbeeController().values)
            c.work_pending();
    }

    // some useful tools zigbee...
    import protocol.ezsp.commands;

    // /protocol/zigbee/scan command
    EnergyScanState scan(Session session, const(char)[] ezsp_client, Nullable!bool energy_scan)
    {
        EZSPClient c = Collection!EZSPClient().get(ezsp_client);
        if (!c)
        {
            session.write_line("EZSP client does not exist: ", ezsp_client);
            return null;
        }

        EnergyScanState state = alloc!EnergyScanState(session, c);
        c.set_message_handler(&state.message_handler);
        c.send_command!EZSP_StartScan(&state.start_scan, energy_scan ? EzspNetworkScanType.ENERGY_SCAN : EzspNetworkScanType.ACTIVE_SCAN, 0x07FFF800, energy_scan ? 1 : 3);
        return state;
    }

    void nodes_print(Session session)
    {
        if (nodes_by_eui.length == 0 && unknown_nodes.length == 0)
        {
            session.write_line("No zigbee nodes");
            return;
        }

        if (nodes_by_eui.length != 0)
        {
            MonoTime now = getTime();
            SysTime now_sys = getSysTime();
            Table t;
            t.add_column("eui");
            t.add_column("interface");
            t.add_column("pan");
            t.add_column("id");
            t.add_column("type");
            t.add_column("state");
            t.add_column("interview");
            t.add_column("fails", Table.TextAlign.right);
            t.add_column("device");
            t.add_column("lqi", Table.TextAlign.right);
            t.add_column("rssi", Table.TextAlign.right);
            t.add_column("seen", Table.TextAlign.right);

            foreach (ref NodeMap n; nodes_by_eui.values)
            {
                char[7] interview_buffer = void;
                size_t interview_length;
                foreach (i, stage; "npeca")
                    if (n.initialised & (1 << i))
                        interview_buffer[interview_length++] = stage;
                if (n.initialised & 0x40)
                    interview_buffer[interview_length++] = 'b';
                if (n.initialised & 0x80)
                    interview_buffer[interview_length++] = 'B';
                const(char)[] interview = n.initialised == 0xFF ? "complete" : interview_buffer[0 .. interview_length];
                bool seen = n.last_seen != SysTime();

                t.add_row();
                t.cell(tconcat(n.eui));
                t.cell(n.available && n.via ? n.via.name[] : "-");
                t.cell(n.pan_id == 0xFFFF ? "-" : tformat("{0,04x}", n.pan_id));
                t.cell(n.available ? tformat("{0,04x}", n.id) : "-");
                t.cell(enum_key_from_value!NodeType(n.desc.type));

                const(char)[] state;
                if (!n.available)
                    state = "offline";
                else if (n.initialised == 0xFF)
                    state = "ready";
                else if (n.scan_in_progress)
                    state = n.woke_during_scan ? "scanning*" : "scanning";
                else if (n.retry_after != MonoTime() && now < n.retry_after)
                    state = n.retry_after == wake_only ? "wake" : tconcat("retry ", (n.retry_after - now).as!"seconds", "s");
                else
                    state = "pending";
                t.cell(state);

                t.cell(interview.length ? interview : "-");
                t.cell(n.interview_failures ? tconcat(n.interview_failures) : "-");
                t.cell(n.device ? n.device.id[] : "-");
                t.cell(seen ? tconcat(n.lqi) : "-");
                t.cell(seen ? tconcat(n.rssi) : "-");
                t.cell(seen ? tconcat((now_sys - n.last_seen).as!"seconds", "s") : "-");
            }

            t.render(session);
        }

        if (unknown_nodes.length == 0)
            return;

        if (nodes_by_eui.length != 0)
            session.write_line();
        Table u;
        u.add_column("interface");
        u.add_column("pan");
        u.add_column("unresolved id");
        u.add_column("state");
        foreach (ref unk; unknown_nodes)
        {
            u.add_row();
            u.cell(unk.via ? unk.via.name[] : "-");
            u.cell(tformat("{0,04x}", unk.pan_id));
            u.cell(tformat("{0,04x}", unk.id));
            u.cell(unk.scanning ? "probing" : "pending");
        }
        u.render(session);
    }

    // /protocol/zigbee/read command
    CommandState zcl_read(Session session, ZigbeeEndpoint source, ref const(Variant) node, ubyte endpoint, ushort cluster, const(ushort)[] attributes)
    {
        NodeMap* nm = resolve_node(session, node);
        if (!nm)
            return null;

        if (cluster == 0xEF00)
            return tuya_read(session, source, nm, endpoint, attributes);

        auto state = alloc!ZCLReadState(session, source, nm.id, endpoint, cluster, attributes);
        state.send_requests();
        return state;
    }

    static CommandState tuya_read(Session session, ZigbeeEndpoint source, NodeMap* nm, ubyte endpoint, const(ushort)[] attributes)
    {
        foreach (dp_id; attributes[])
        {
            if (dp_id >= 256)
            {
                session.write_line("Invalid Tuya DP id (must be 0-255)");
                return null;
            }
        }

        // tuya_data_query requests a device to report *ALL DPs*
        ubyte[2] buffer = void;
        buffer[0..2] = tuya_seq.nativeToBigEndian;
        ++tuya_seq;
        tuya_seq += tuya_seq == 0;

        source.send_zcl_message(nm.id, endpoint, source.profile_id, 0xEF00, ZCLCommand.tuya_data_query, 0, buffer[], PCP.be);

        return alloc!TuyaReadState(session, nm, attributes);
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

        auto state = alloc!ZCLWriteState(session, source, nm, endpoint, cluster, attribute, value, data_type);
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

        // encode Tuya DP frame: [seq_hi, seq_lo, dp_id, dp_type, len_hi, len_lo, data...]
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

        source.send_zcl_message(nm.id, endpoint, source.profile_id, 0xEF00, ZCLCommand.tuya_data_request, 0, buffer[0 .. 6 + data_len], PCP.vo);
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

class EnergyScanState : CommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;

    EZSPClient client;
    bool finished = false;

    MonoTime start_time;

    this(Session session, EZSPClient client)
    {
        super(session, null);
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

class ZCLReadState : CommandState
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
    Array!int handles;
    Array!Variant results;

    this(Session session, ZigbeeEndpoint source, ushort dst, ubyte endpoint_id, ushort cluster_id, const(ushort)[] attrs)
    {
        super(session, null);
        this.source = source;
        this.dst = dst;
        this.endpoint_id = endpoint_id;
        this.cluster_id = cluster_id;
        this.requested = attrs[];
        this.remaining = attrs[];
        this.results.resize(attrs.length);
        this.start_time = getTime();
    }

    void send_requests()
    {
        handles.clear();
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

            int handle = source.send_zcl_message(dst, endpoint_id, source.profile_id, cluster_id, ZCLCommand.read_attributes, 0, req_buffer[0 .. chunk*2], PCP.be, &response_handler, null);
            if (handle > 0)
            {
                handles.pushBack(handle);
                ++pending;
            }
            i += chunk;
        }

        if (pending == 0)
        {
            session.write_line("ZCL read could not be submitted");
            state = CommandCompletionState.error;
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
        foreach (handle; handles[])
            source.abort_zcl_request(handle);
        handles.clear();
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

        handles.clear();

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


class TuyaReadState : CommandState
{
nothrow @nogc:

    CommandCompletionState state = CommandCompletionState.in_progress;
    MonoTime start_time;

    NodeMap* nm;
    Array!ushort requested;
    Array!Variant results;

    this(Session session, NodeMap* nm, const(ushort)[] attrs)
    {
        super(session, null);
        this.nm = nm;
        this.requested = attrs[];
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


class ZCLWriteState : CommandState
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
    int pending_handle = -1;

    this(Session session, ZigbeeEndpoint source, NodeMap* node, ubyte endpoint_id, ushort cluster_id, ushort attribute_id, ref const Variant write_value, ZCLDataType data_type)
    {
        super(session, null);
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
        if (pending_handle > 0)
        {
            source.abort_zcl_request(pending_handle);
            pending_handle = -1;
        }
    }

    void send_type_discovery()
    {
        ubyte[2] read_buf = void;
        read_buf[0..2] = attribute_id.nativeToLittleEndian;
        int handle = source.send_zcl_message(node.id, endpoint_id, source.profile_id, cluster_id, ZCLCommand.read_attributes, 0, read_buf[], PCP.be, &read_response_handler, null);
        if (handle < 0)
        {
            session.write_line("ZCL read (type discovery) could not be submitted");
            state = CommandCompletionState.error;
            return;
        }
        pending_handle = handle;
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

        int handle = source.send_zcl_message(node.id, endpoint_id, source.profile_id, cluster_id, ZCLCommand.write_attributes, 0, write_buffer[0 .. 3 + val_len], PCP.vo, &write_response_handler, null);
        if (handle < 0)
        {
            session.write_line("ZCL write could not be submitted");
            state = CommandCompletionState.error;
            return;
        }
        pending_handle = handle;
    }

    void read_response_handler(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void*)
    {
        pending_handle = -1;

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
        pending_handle = -1;

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
