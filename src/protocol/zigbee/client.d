module protocol.zigbee.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tstring, tconcat;
import urt.result;
import urt.string;

import manager;
import manager.collection;

import protocol.ezsp.client;
import protocol.ezsp.commands;
import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.zdo;

import router.iface;
import router.iface.packet;
import router.iface.zigbee;

version = DebugZigbee;

nothrow @nogc:


alias ZigbeeMessageHandler = void delegate(ref const APSFrame header, const(void)[] message) nothrow @nogc;


class ZigbeeNode : BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("is-coordinator", is_coordinator)(),
                                         Property.create!("eui", eui)(),
                                         Property.create!("node-id", node_id)() ];
nothrow @nogc:

    enum TypeName = StringLit!"zb-node";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        this(collection_type_info!ZigbeeNode, name.move, flags);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure // TODO: should return zigbee interface?
        => _interface;
    StringResult iface(BaseInterface value)
    {
        if (!value)
            return StringResult("interface cannot be null");
        if (_interface)
        {
            if (_interface is value)
                return StringResult.success;
            _interface.unsubscribe(&incoming_packet);
        }
        _interface = value;
        _interface.subscribe(&incoming_packet, PacketFilter(type: PacketType.ZigbeeAPS));
        return StringResult.success;
    }

    EUI64 eui() const pure
        => _eui;

    ushort node_id() const pure
        => _node_id;

    bool is_coordinator() const pure
        => false;

    // API...

    override bool validate() const pure
        => _interface !is null;

    override CompletionStatus startup()
        => _interface.running ? CompletionStatus.Complete : CompletionStatus.Continue;

    override CompletionStatus shutdown()
        => CompletionStatus.Complete;

protected:
    struct Endpoint
    {
        ubyte id;
        ObjectRef!ZigbeeEndpoint endpoint;
    }

    BaseInterface _interface;
    Array!Endpoint _endpoints;

    EUI64 _eui = EUI64.broadcast;
    ushort _node_id = 0xFFFE;

    this(const(CollectionTypeInfo)* type_info, String name, ObjectFlags flags)
    {
        super(type_info, name.move, flags);
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data)
    {
        // TODO: we should enhance the PACKET FILTER to do this work!
        ref aps = p.hdr!APSFrame;

        if (aps.dst_endpoint == 0)
        {
            if (aps.src_endpoint != 0 || aps.profile_id != 0)
                return;

            handle_zdo_frame(aps, p);
            return;
        }
        else if (aps.src_endpoint == 0 || aps.profile_id == 0)
            return;

        // check if it's for an endpoint we own
        foreach (ref ep; _endpoints[])
        {
            if ((aps.dst_endpoint == 0xFF || aps.dst_endpoint == ep.id) && aps.profile_id == ep.endpoint._profile)
                ep.endpoint.incoming_packet(p, this, dir);
        }
    }

    void handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        assert(false, "TODO: already handled by the EZSP stack?");

        switch (aps.cluster_id)
        {
            case 0x0000, // NWK_addr_req
                 0x0001, // IEEE_addr_req
                 0x0002, // Node_Desc_req
                 0x0003, // Power_Desc_req
                 0x0004, // Simple_Desc_req
                 0x0005, // Active_EP_req
                 0x0006, // Match_Desc_req
                 0x0010, // Complex_Desc_req
                 0x0011, // User_Desc_req
                 0x0012, // Discovery_Cache_req
                 0x0013, // Device_annce
                 0x0014, // User_Desc_set
                 0x0015, // System_Server_Discovery_req
                 0x0016, // Discovery_store_req
                 0x0017, // Node_Desc_store_req
                 0x0018, // Power_Desc_store_req
                 0x0019, // Active_EP_store_req
                 0x001A, // Simple_Desc_store_req
                 0x001B, // Remove_node_cache_req
                 0x001C, // Find_node_cache_req
                 0x001D, // Extended_Simple_Desc_req
                 0x001E, // Extended_Active_EP_req
                 0x001F, // Parent_annce
                 0x0020, // End_Device_Bind_req
                 0x0021, // Bind_req
                 0x0022, // Unbind_req
                 0x0023, // Bind_Register_req
                 0x0024, // Replace_Device_req
                 0x0025, // Store_Bkup_Bind_Entry_req
                 0x0026, // Remove_Bkup_Bind_Entry_req
                 0x0027, // Backup_Bind_Table_req
                 0x0028, // Recover_Bind_Table_req
                 0x0029, // Backup_Source_Bind_req
                 0x002A, // Recover_Source_Bind_req
                 0x002B, // Clear_All_Bindings_req
                 0x0030, // Mgmt_NWK_Disc_req
                 0x0031, // Mgmt_Lqi_req
                 0x0032, // Mgmt_Rtg_req
                 0x0033, // Mgmt_Bind_req
                 0x0034, // Mgmt_Leave_req
                 0x0035, // Mgmt_Direct_Join_req
                 0x0036, // Mgmt_Permit_Joining_req
                 0x0037, // Mgmt_Cache_req
                 0x0038, // Mgmt_NWK_Update_req
                 0x0039, // Mgmt_NWK_Enhanced_Update_req
                 0x003A, // Mgmt_NWK_IEEE_Joining_List_req
                 0x003C: // Mgmt_NWK_Beacon_Survey_req
                goto default;
            default:
                // TODO: unknown ZDO request?
                return;
        }
    }

private:
    size_t find_endpoint(ZigbeeEndpoint endpoint)
    {
        foreach (i; 0 .. _endpoints.length)
            if (_endpoints[i].endpoint.get() is endpoint)
                return i;
        return _endpoints.length;
    }

    void add_endpoint(ZigbeeEndpoint endpoint)
    {
        if (find_endpoint(endpoint) < _endpoints.length)
            return; // TODO: error or assert or something?!
        ref Endpoint ep = _endpoints.pushBack();
        ep.id = endpoint.endpoint;
        ep.endpoint = endpoint;
    }

    void remove_endpoint(ZigbeeEndpoint endpoint)
    {
        size_t i = find_endpoint(endpoint);
        if (i < _endpoints.length)
            _endpoints.remove(i);
    }
}


class ZigbeeRouter : ZigbeeNode
{
    __gshared Property[2] Properties = [ Property.create!("pan-eui", _pan_eui)(),
                                         Property.create!("pan-id", _pan_id)() ];
nothrow @nogc:

    enum TypeName = StringLit!"zb-router";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        this(collection_type_info!ZigbeeRouter, name.move, flags);
    }

    ~this()
    {
        get_module!ZigbeeProtocolModule.nodes.remove(this);
    }

    // Properties...

    EUI64 pan_eui() const pure nothrow
        => _network_params.pan_id == 0xFFFF ? _pan_eui : _network_params.extended_pan_id;
    void pan_eui(EUI64 value) pure nothrow
    {
        _pan_eui = value;
    }

    ushort pan_id() const pure nothrow
        => _network_params.pan_id == 0xFFFF ? _pan_id : _network_params.pan_id;
    void pan_id(ushort value) pure nothrow
    {
        _pan_id = value;
    }

    // API...

    override bool validate() const pure
        => super.validate();

    override CompletionStatus startup()
    {
        CompletionStatus s = super.startup();
        if (s != CompletionStatus.Complete)
            return s;
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
        => super.shutdown();

    void subscribe_client(EZSPClient client, bool subscribe) nothrow
    {
        client.set_callback_handler!EZSP_IdConflictHandler(subscribe ? &id_conflict_handler : null);
    }

protected:
    this(const(CollectionTypeInfo)* type_info, String name, ObjectFlags flags)
    {
        super(type_info, name.move, flags);

        get_module!ZigbeeProtocolModule.nodes.add(this);
    }

    void id_conflict_handler(EmberNodeId id)
    {
        // TODO: this is called when the NCP detects multiple nodes using the same id
        //       the stack will remove references to this id, and we should also remove the ID from our records
        assert(false, "TODO");
    }

    override void handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        switch (aps.cluster_id)
        {
            case ZDOCluster.Device_annce:
                const ubyte[] data = cast(ubyte[])p.data[];
                ubyte seq = data[0];
                ushort id = data[1..3].littleEndianToNative!ushort;
                EUI64 eui = EUI64(data[3..11]);
                ubyte caps = data[11];

                assert(eui != EUI64.broadcast, "TODO: node EUI is not valid... we're meant to do something with this?");

                ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;
                auto n = mod_zb.find_node(eui);
                if (!n)
                    n = mod_zb.attach_node(eui, _network_params.pan_id, id);
                else if (n.id != id || n.pan_id != _network_params.pan_id)
                {
                    assert(n.pan_id == _network_params.pan_id, "TODO: how can the device change PAN?");

                    // rebind the address
                    mod_zb.detach_node(_network_params.pan_id, n.id);
                    mod_zb.attach_node(eui, _network_params.pan_id, id);
                }

                if (caps & 0x02) // fully-functional device
                    n.type = (caps & 0x01) ? NodeType.coordinator : NodeType.router;
                else // reduced-functionality device
                    n.type = (caps & 0x08) ? NodeType.end_device : NodeType.sleepy_end_device;

                // TODO: save the power source (0x04) and security caps (0x40) somewhere?

                // HACK: apparenty lots of Tuya devices only report this 'allocate address' flag, and that means they're a router?
                if (caps == 0x80)
                    n.type = NodeType.router;

                version (DebugZigbee)
                    writeInfof("Zigbee: device announce: {0, 04x} [{1}] - type={2}", id, eui, n.type);
                return;

            default:
                super.handle_zdo_frame(aps, p);
        }
    }

protected:
    struct NetworkParams
    {
        EUI64 extended_pan_id;
        ushort pan_id = 0xFFFF;
        ubyte radio_tx_power;
        ubyte radio_channel;
//        EmberJoinMethod join_method; // The method used to initially join the network.
//        EmberNodeId nwk_manager_id;
//        ubyte nwk_update_id;
//        uint channels;
    }

    NetworkParams _network_params;
    ZigbeeInterface _interface;
    EUI64 _pan_eui = EUI64.broadcast;
    ushort _pan_id = 0xFFFF;
}

class ZigbeeEndpoint : BaseObject
{
    __gshared Property[7] Properties = [ Property.create!("node", node)(),
                                         Property.create!("endpoint-id", endpoint)(),
                                         Property.create!("profile", profile)(),
                                         Property.create!("profile-id", profile_id)(),
                                         Property.create!("device", device)(),
                                         Property.create!("in-clusters", in_clusters)(),
                                         Property.create!("out-clusters", out_clusters)() ];
nothrow @nogc:

    enum TypeName = StringLit!"zb-endpoint";

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow
    {
        super(collection_type_info!ZigbeeEndpoint, name.move, flags);
    }

    ~this()
    {
        if (_node)
            _node.remove_endpoint(this);
    }

    // Properties...

    final inout(ZigbeeNode) node() inout pure nothrow // TODO: should return zigbee interface?
        => _node;
    final const(char)[] node(ZigbeeNode value) nothrow
    {
        if (!value)
            return "node cannot be null";
        if (_node)
        {
            if (_node is value)
                return null;
            _node.remove_endpoint(this);
        }
        _node = value;
        if (_endpoint != 0)
            _node.add_endpoint(this);
        return null;
    }

    final ubyte endpoint() inout pure nothrow
        => _endpoint;
    final const(char)[] endpoint(ubyte value) nothrow
    {
        if (value == 0 || value > 240)
            return "endpoint must be in range 1..240";
        if (_node && _endpoint != 0)
            _node.remove_endpoint(this);
        _endpoint = value;
        if (_node)
            _node.add_endpoint(this);
        return null;
    }

    final const(char)[] profile() inout nothrow
        => profile_name(_profile);
    final const(char)[] profile(const(char)[] value) nothrow
    {
        switch (value)
        {
            case "zdo":
            case "zdp":  _profile = 0x0000; break;
            case "ipm":  _profile = 0x0101; break; // industrial plant monitoring
            case "ha":
            case "zha":  _profile = 0x0104; break; // home assistant
            case "ba":
            case "cba":  _profile = 0x0105; break; // building automation
            case "ta":   _profile = 0x0107; break; // telco automation
            case "hc":
            case "hcp":
            case "phhc": _profile = 0x0108; break; // health care
            case "zse":
            case "se":   _profile = 0x0109; break; // smart energy
            case "gp":
            case "zgp":  _profile = 0xA1E0; break; // green power
            case "zll":  _profile = 0xC05E; break; // only for the commissioning cluster (0x1000); zll commands use `ha`
            default:
                import urt.conv : parse_uint_with_base;
                size_t taken;
                ulong ul = parse_uint_with_base(value, &taken);
                if (taken == 0 || taken != value.length || ul > ushort.max)
                    return tconcat("unknown zigbee profile: ", value);
                _profile = cast(ushort)ul;
        }
        return null;
    }

    final ushort profile_id() inout nothrow
        => _profile;

    final ushort device() inout pure nothrow
        => _device;
    final void device(ushort value) nothrow
    {
        _device = value;
    }

    final const(ushort)[] in_clusters() inout pure nothrow
        => _in_clusters[];
    final void in_clusters(const(ushort)[] value) nothrow
    {
        _in_clusters = value;
    }

    final const(ushort)[] out_clusters() inout pure nothrow
        => _out_clusters[];
    final void out_clusters(const(ushort)[] value) nothrow
    {
        _out_clusters = value;
    }


    // API...

    override bool validate() const
    {
        if (!_node || _endpoint == 0)
            return false;
        else
            return _profile != 0;
    }

    override CompletionStatus startup()
        => _node.running ? CompletionStatus.Complete : CompletionStatus.Continue;

    override void update()
    {
        // nothing to do here maybe? I think it's all event driven...
    }

    void set_message_handler(ZigbeeMessageHandler handler)
    {
        _message_handler = handler;
    }

    bool send_message(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running)
            return false;

        assert(message.length <= 256, "TODO: what actually is the maximum zigbee payload?");

        Packet p;
        ref aps = p.init!APSFrame(message);

        aps.type = APSFrameType.data;
        aps.dst = dst;
        if (dst >= 0xFFFB)
            aps.delivery_mode = APSDeliveryMode.broadcast;
        else
            aps.delivery_mode = APSDeliveryMode.unicast;
        aps.src = _node._node_id;
        aps.src_endpoint = _endpoint;
        aps.dst_endpoint = endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        // TODO: anything else?

        return _node._interface.forward(p);
    }

    bool send_message(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
    {
        if (!running)
            return false;

        assert(message.length <= 256, "TODO: what actually is the maximum zigbee payload?");

        Packet p;
        ref aps = p.init!APSFrame(message);

        aps.type = APSFrameType.data;
        aps.dst = dst;
        if (dst >= 0xFFFB)
            aps.delivery_mode = APSDeliveryMode.broadcast;
        else
            aps.delivery_mode = group ? APSDeliveryMode.group : APSDeliveryMode.unicast;
        aps.src = _node._node_id;
        aps.src_endpoint = _endpoint;
        aps.dst_endpoint = endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        // TODO: anything else?

        return _node._interface.forward(p);
    }

    bool send_message(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running)
            return false;
        if (eui.is_zigbee_broadcast)
            return send_message(0xFF00 | eui.b[7], endpoint, profile_id, cluster_id, message);
        else if (eui.is_zigbee_multicast)
            return send_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), endpoint, profile_id, cluster_id, message, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? just drop it?");
        return send_message(n.id, endpoint, profile_id, cluster_id, message);
    }

private:
    ZigbeeNode _node;
    ubyte _endpoint;

    ushort _profile, _device;
    Array!ushort _in_clusters, _out_clusters;

    ZigbeeMessageHandler _message_handler;

    void incoming_packet(ref const Packet p, ZigbeeNode iface, PacketDirection dir) nothrow @nogc
    {
        // TODO: this seems inefficient!
        if (_message_handler)
            _message_handler(p.hdr!APSFrame, p.data[]);
    }
}
