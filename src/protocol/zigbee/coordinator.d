module protocol.zigbee.coordinator;

import urt.async;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.result : StringResult;
import urt.string;
import urt.time;

import manager;
import manager.collection;

import router.iface;
import router.iface.packet;
import router.iface.zigbee;

import protocol.ezsp;
import protocol.ezsp.client;
import protocol.ezsp.commands;
import protocol.zigbee;
import protocol.zigbee.aps;
//import protocol.zigbee.client;
import protocol.zigbee.router;
import protocol.zigbee.zdo;

@nogc:


class ZigbeeCoordinator : ZigbeeRouter
{
    __gshared Property[2] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("channel", channel)() ];
@nogc:

    enum type_name = "zb-coordinator";

    this(String name, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!ZigbeeCoordinator, name.move, flags);

        get_module!ZigbeeProtocolModule.routers.add(this);
    }

    ~this()
    {
        get_module!ZigbeeProtocolModule.routers.remove(this);
    }

    // Properties...

    alias iface = typeof(super).iface; // merge the overload set
    final override StringResult iface(BaseInterface value) nothrow
    {
        if (!value)
            return StringResult("interface cannot be null");
        ZigbeeInterface zi = cast(ZigbeeInterface)value;
        if (!zi)
            return StringResult("must be a zigbee interface");
        if (_interface)
        {
            if (_interface is value)
                return StringResult.success;
            _interface.unsubscribe(&state_change);
            _interface.unsubscribe(&incoming_packet);
            zigbee_iface.attach_coordiantor(null);
            if (auto ezsp = get_ezsp())
                subscribe_client(ezsp, false);
        }
        if (zi.is_coordinator)
            return StringResult("interface is already a coordinator");
        _interface = zi;
        _interface.subscribe(&state_change);
        _interface.subscribe(&incoming_packet, PacketFilter(type: PacketType.zigbee_aps));
        zigbee_iface.attach_coordiantor(this);
        if (auto ezsp = get_ezsp())
            subscribe_client(ezsp, true);
        return StringResult.success;
    }

    final ubyte channel() inout pure nothrow
        => _network_params.radio_channel ? _network_params.radio_channel : _channel;
    final StringResult channel(uint value) nothrow
    {
        if (value == 0)
            return StringResult("868 MHz not supported");
        if (value <= 10)
            return StringResult("915 MHz channels not supported");
        if (value > 26)
            return StringResult("invalid channel");
        _channel = cast(ubyte)value;
        return StringResult.success;
    }
    final StringResult channel(const(char)[] value) nothrow
    {
        if (value[] == "auto")
            _channel = 0xFF;
        else
            return StringResult("invalid channel specification");
        return StringResult.success;
    }

    final override bool is_coordinator() const pure nothrow
        => true;

    final bool ready() const pure nothrow
        => _ready;

    // API...

    void reboot() nothrow
    {
        // reboot the NCP
        if (auto ezsp = get_ezsp())
        {
            ezsp.reboot_ncp();
            _interface.restart(); // TODO: is rebooting another component good policy?
        }
        restart();
    }

    void destroy_network() nothrow
    {
        if (_destroying)
            return;

        if (_init_promise)
        {
            _init_promise.abort();
            freePromise(_init_promise);
        }
        _destroying = true;
        _init_promise = async(&do_destroy_network);
    }

    override bool validate() const nothrow
        => super.validate();

    override CompletionStatus startup() nothrow
    {
        auto zb = zigbee_iface();
        if (!zb || !zb.is_coordinator)
        {
            CompletionStatus s = super.startup();
            if (s != CompletionStatus.complete)
                return s;
        }
        else
        {
            auto ezsp = get_ezsp();
            assert(ezsp, "What happened here? I'm not sure what flow could lead to this case...");

            if (!ezsp.running)
            {
                if (_init_promise)
                {
                    // the client went down during initialisation...
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }
            else if (ezsp.protocol_version < 13)
            {
                // TODO: should we even attempt to support old firmware?
                //       major difference: only single pending message slot; must use `SendReply` when replying to a ZCL message.
                return CompletionStatus.error;
            }

            if (_destroying)
            {
                if (_init_promise.state != PromiseState.Pending)
                {
                    freePromise(_init_promise);
                    return CompletionStatus.error;
                }
                return CompletionStatus.continue_;
            }

            if (!_ready)
            {
                if (!_init_promise)
                {
                    if (ezsp.stack_type != EZSPStackType.coordinator && !_already_complained)
                    {
                        writeError("Zigbee: EZSP client device is not running cordinator firmware. To use this device, flash with the proper coordinator firmware.");
                        _already_complained = true;
                        // TODO: maybe we should have a sort of non-recoverable error, where it won't automatically try and restart?
                        return CompletionStatus.error;
                    }

                    _init_promise = async(&init);
                }
                else if (_init_promise.state != PromiseState.Pending)
                {
                    bool failed = _init_promise.state == PromiseState.Failed ? true : !_init_promise.result;
                    freePromise(_init_promise);
                    if (failed)
                        return CompletionStatus.error;
                    _ready = true;
                }
            }

            if (_ready)
            {
                CompletionStatus s = super.startup();
                if (s != CompletionStatus.complete)
                    return s;
                return CompletionStatus.complete;
            }
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown() nothrow
    {
        if (_init_promise)
        {
            if (!_init_promise.finished)
            {
                if (_destroying)
                    return CompletionStatus.continue_;
                _init_promise.abort();
            }
            freePromise(_init_promise);
            _init_promise = null;
        }

        _previous_extended_pan_id = _network_params.extended_pan_id;
        _network_params = NetworkParams();
        _already_complained = false;
        _ready = false;

        return super.shutdown();
    }

    override void update() nothrow
    {
        if (_destroying)
        {
            if (_init_promise.state != PromiseState.Pending)
            {
                freePromise(_init_promise);
                restart();
            }
            return;
        }

        // TODO: any administrative activities for the coordinator?
        if (_pan_eui != EUI64.broadcast && _pan_eui != _network_params.extended_pan_id)
        {
            writeInfo("Zigbee coordinator: PAN EUI changed - re-forming network");
            assert(false, "TODO");
            // TODO: we must re-form the network to change the EUI...
            //       we should also clear all records about device presence...
            restart();
        }
        if (_pan_id != 0xFFFF && _pan_id != _network_params.pan_id)
        {
            writeInfo("Zigbee coordinator: PAN ID changed - updating network...");
            assert(false, "TODO");
            // TODO: we can change pan_id without re-forming the network...
            //       ZDO Mgmt_NWK_Update_req (cluster 0x0036) with ScanDuration=0xFE and a one-bit channel mask (new channel).
        }
        if (_channel != 0xFF && _channel != _network_params.radio_channel)
        {
            writeInfo("Zigbee coordinator: CHANNEL changed - updating network...");
            assert(false, "TODO");
            // TODO: we can change channel without re-forming the network...
            //       ZDO Mgmt_NWK_Update_req with ScanDuration=0xFF (PAN ID update).
        }
    }

    override final void subscribe_client(EZSPClient client, bool subscribe) nothrow
    {
        super.subscribe_client(client, subscribe);

        client.set_callback_handler!EZSP_TrustCenterJoinHandler(subscribe ? &join_handler : null);
        client.set_callback_handler!EZSP_ChildJoinHandler(subscribe ? &child_join : null);
        client.set_callback_handler!EZSP_ZigbeeKeyEstablishmentHandler(subscribe ? &key_establishment : null);
        client.set_callback_handler!EZSP_RemoteSetBindingHandler(subscribe ? &remote_set_binding : null);
        client.set_callback_handler!EZSP_RemoteDeleteBindingHandler(subscribe ? &remote_delete_binding : null);
    }

private:
    enum ubyte[16] _tc_link_key = cast(ubyte[16])"ZigBeeAlliance09";

    ubyte[16] _network_key;
    ubyte _channel = 0xFF;

    EUI64 _previous_extended_pan_id;
    MonoTime _last_action;
    bool _already_complained; // suppress repeat complaining about the same errors
    bool _ready;
    bool _destroying;

    Promise!bool* _init_promise;

    bool init()
    {
        auto ezsp = get_ezsp();

        bool done = false;
        while (!done)
        {
            EmberNetworkStatus network_status = ezsp.request!EZSP_NetworkState();
            switch (network_status) with(EmberNetworkStatus)
            {
                case JOINED_NETWORK:
                    // ASH RST resets the NCP, so this shouldn't happen.
                    // if it does, the stack is already running — just sync bookkeeping!
                    writeWarning("Zigbee coordinator: unexpected JOINED_NETWORK at init — syncing state");
                    return sync_network_state(ezsp);

                case NO_NETWORK:
                    return init_network(ezsp);

                case JOINED_NETWORK_NO_PARENT:
                    assert(false, "TODO: what is this case?");
//                    ezsp.send_command!EZSP_PermitJoining(0xFF, (EmberStatus status) {
//                        writeInfo("Zigbee coordinator: permit joining status: ", status);
//                    });
                break;

                case JOINING_NETWORK:
                case LEAVING_NETWORK:
                    writeInfo("Zigbee coordinator: JOINING/LEAVING NETWORK");
                    sleep(1.seconds);
                    break;

                default:
                    writeError("Zigbee coordinator: invalid network state: ", cast(ubyte)network_status);
                    ezsp.restart();
                    return false;
            }
        }

        return true;
    }

    bool init_network(EZSPClient ezsp)
    {
        // TODO: do we want to know how many physical interfaces there are?
        //       we should probably have one interface for each one... and are they all coordinators, or some routers? what's the deal?
        //       what hardware even is this? we should get one to test...
//        EZSP_GetPhyInterfaceCount

//        ezsp.request!EZSP_SetManufacturerCode(0xFFFF); // "not specified"

        ezsp.set_configuration(EzspConfigId.SUPPORTED_NETWORKS, 1);
        ezsp.set_configuration(EzspConfigId.STACK_PROFILE, 2);
        ezsp.set_configuration(EzspConfigId.SECURITY_LEVEL, 5);
        ezsp.set_configuration(EzspConfigId.TRUST_CENTER_ADDRESS_CACHE_SIZE, 2);

        // Enable MAC passthrough for beacons and join requests
        // TODO: do we want to handle APP_HANDLES_ZDO_ENDPOINT_REQUESTS and APP_HANDLES_ZDO_BINDING_REQUESTS ourself? add them here...
        ezsp.set_configuration(EzspConfigId.APPLICATION_ZDO_FLAGS, cast(EmberZdoConfigurationFlags)(EmberZdoConfigurationFlags.APP_HANDLES_UNSUPPORTED_ZDO_REQUESTS | EmberZdoConfigurationFlags.APP_RECEIVES_SUPPORTED_ZDO_REQUESTS));

        // TODO: do we need/want any of these?
        ezsp.set_configuration(EzspConfigId.INDIRECT_TRANSMISSION_TIMEOUT, 300); // >= 300
        ezsp.set_configuration(EzspConfigId.MAX_END_DEVICE_CHILDREN, 32); // >= 16
        ezsp.set_configuration(EzspConfigId.KEY_TABLE_SIZE, 8);
        ezsp.set_configuration(EzspConfigId.ADDRESS_TABLE_SIZE, 16);
        ezsp.set_configuration(EzspConfigId.SOURCE_ROUTE_TABLE_SIZE, 32);
//        ezsp.set_configuration(EzspConfigId.APS_ACK_TIMEOUT, 0x2000);

        ezsp.set_policy(EzspPolicyId.TRUST_CENTER, cast(EzspDecisionId)(EzspDecisionBitmask.ALLOW_JOINS | EzspDecisionBitmask.ALLOW_UNSECURED_REJOINS));
//        ezsp.set_policy(EzspPolicyId.TC_KEY_REQUEST, EzspDecisionId.DENY_TC_KEY_REQUESTS);
        ezsp.set_policy(EzspPolicyId.TC_KEY_REQUEST, EzspDecisionId.ALLOW_TC_KEY_REQUESTS_AND_SEND_CURRENT_KEY);
        ezsp.set_policy(EzspPolicyId.APP_KEY_REQUEST, EzspDecisionId.DENY_APP_KEY_REQUESTS);
//        ezsp.set_policy(EzspPolicyId.APP_KEY_REQUEST, EzspDecisionId.ALLOW_APP_KEY_REQUESTS);
        ezsp.set_policy(EzspPolicyId.BINDING_MODIFICATION, EzspDecisionId.ALLOW_BINDING_MODIFICATION);
        ezsp.set_policy(EzspPolicyId.MESSAGE_CONTENTS_IN_CALLBACK, EzspDecisionId.MESSAGE_TAG_AND_CONTENTS_IN_CALLBACK);
//        ezsp.set_policy(EzspPolicyId.UNICAST_REPLIES, EzspDecisionId.HOST_WILL_SUPPLY_REPLY);
        ezsp.set_policy(EzspPolicyId.UNICAST_REPLIES, EzspDecisionId.HOST_WILL_NOT_SUPPLY_REPLY);

        // Set MAC passthrough flags for beacon requests
        ubyte flags = 0xF;
        EzspStatus r = ezsp.request!EZSP_SetValue(EzspValueId.MAC_PASSTHROUGH_FLAGS, (&flags)[0..1]);//EzspValueId.MAC_PASSTHROUGH_FLAGS, EmberMacPassthroughType.EMBER_MAC_PASSTHROUGH_BEACON | EmberMacPassthroughType.EMBERMGMT | EmberMacPassthroughType.EMBER_MAC_PASSTHROUGH_MAC_COMMAND);
        if (r != EzspStatus.SUCCESS)
            writeInfo("Zigbee coordinator: MAC_PASSTHROUGH_FLAGS failed: ", r);

        // update the EUI for this interface; since it's determined by the NCP...
        _eui.b = ezsp.request!EZSP_GetEui64();

        auto security_state = ezsp.request!EZSP_GetCurrentSecurityState();
        if (security_state.status != EmberStatus.SUCCESS)
            writeWarning("Zigbee coordinator: GetCurrentSecurityState failed: ", security_state.status);
        else
            writeDebugf("Zigbee coordinator: GetCurrentSecurityState bitmask = {0,04x}", security_state.state.bitmask);

        // register local endpoints
        foreach (ref e; _endpoints)
        {
            r = ezsp.request!EZSP_AddEndpoint(e.id, e.endpoint.profile_id, e.endpoint.device, ubyte(0), e.endpoint.in_clusters[], e.endpoint.out_clusters[]);
            if (r != EzspStatus.SUCCESS)
                writeInfo("Zigbee coordinator: AddEndpoint failed: ", r);
        }

        // try and raise the network...
        EmberStatus status = ezsp.request!EZSP_NetworkInit(EmberNetworkInitStruct(bitmask: EmberNetworkInitBitmask.NO_OPTIONS));
        if (status == EmberStatus.NOT_JOINED)
        {
            writeInfo("Zigbee coordinator: network init failed: ", status);

            // TODO: better keygen?
            // TODO: also, allow user to supply one
            import urt.rand;
            debug
            {
                _network_key = [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 ];
            }
            else
            {
                (cast(uint[])_network_key)[0] = rand();
                (cast(uint[])_network_key)[1] = rand();
                (cast(uint[])_network_key)[2] = rand();
                (cast(uint[])_network_key)[3] = rand();
            }

            // configure the security state...
            EmberInitialSecurityState sec;
            sec.bitmask = cast(EmberInitialSecurityBitmask)(EmberInitialSecurityBitmask.HAVE_PRECONFIGURED_KEY |
                                                            EmberInitialSecurityBitmask.HAVE_NETWORK_KEY |
                                                            EmberInitialSecurityBitmask.TRUST_CENTER_GLOBAL_LINK_KEY
//                                                            EmberInitialSecurityBitmask.TRUST_CENTER_USES_HASHED_LINK_KEY
                                                            // Depending on your stack/version you may also need flags such as:
                                                            // - REQUIRE_ENCRYPTED_KEY
                                                            // Add only if your headers define them and you know you need them.
                                                            );
            sec.preconfiguredKey.contents = _tc_link_key; // == "ZigBeeAlliance09"
            sec.networkKey.contents = _network_key;
            sec.networkKeySequenceNumber = 0;

            // If your SDK expects you to explicitly set the NWK key here, do it like this
            // (ONLY if you have the correct bitmask flag, e.g. HAVE_NETWORK_KEY):
            //
            // sec.networkKey.contents[] = _network_key[];
            // sec.bitmask |= EmberInitialSecurityBitmask.HAVE_NETWORK_KEY;

            EmberStatus sec_status = ezsp.request!EZSP_SetInitialSecurityState(sec);
            if (sec_status != EmberStatus.SUCCESS)
                writeInfo("Zigbee coordinator: SetInitialSecurityState failed: ", sec_status);

            // we should form a network here...
            uint[2] id = [ rand(), rand() ];
            while (id[1] == 0xFFFFFFFF)
                id[1] = rand();
            ref ubyte[8] id_b = *cast(ubyte[8]*)&id;

            EmberNetworkParameters params;
            params.extendedPanId = id_b;
            params.panId = id_b[6..8].bigEndianToNative!ushort;
            params.radioTxPower = 20;
            params.radioChannel = 15; //_channel; TODO: if _channel == 0xFF, do an energy scan...
            params.joinMethod = EmberJoinMethod.USE_MAC_ASSOCIATION;
            params.nwkManagerId = 0x0000;
            params.nwkUpdateId = 0x00;
            params.channels = 1 << params.radioChannel;

            writeInfof("Zigbee coordinator: form network - pan-id={0} ({1, 04x}) channel={2}...", EUI64(params.extendedPanId), params.panId, params.radioChannel);
            status = ezsp.request!EZSP_FormNetwork(params);
            if (status != EmberStatus.SUCCESS)
            {
                writeInfo("Zigbee coordinator: form network FAILED: ", status);
                return false;
            }
        }

        while (zigbee_iface._network_status != EmberStatus.NETWORK_UP)
            sleep(100.msecs);

        return sync_network_state(ezsp);
    }

    bool sync_network_state(EZSPClient ezsp)
    {
        auto nwk_params = ezsp.request!EZSP_GetNetworkParameters();
        _network_params.extended_pan_id.b = nwk_params.parameters.extendedPanId;
        _network_params.pan_id = nwk_params.parameters.panId;
        _network_params.radio_channel = nwk_params.parameters.radioChannel;
        _network_params.radio_tx_power = nwk_params.parameters.radioTxPower;

        _node_id = ezsp.request!EZSP_GetNodeId();
        assert(_node_id == nwk_params.parameters.nwkManagerId && _node_id == 0x0000, "We are the coordinator, so shouldn't we have id 0?");

        writeInfof("Zigbee coordinator: NETWORK UP: node-id={0} type={1} pan-id={2} ({3, 04x}) channel={4}", _node_id, nwk_params.nodeType, _network_params.extended_pan_id, _network_params.pan_id, _network_params.radio_channel);

        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;

        // if the network identity changed, purge old node data
        if (_previous_extended_pan_id != EUI64() && _previous_extended_pan_id != _network_params.extended_pan_id)
        {
            writeInfo("Zigbee coordinator: network identity changed, clearing old node data");
            mod_zb.remove_all_nodes(_interface);
        }

        // create or reuse the node for this coordinator...
        NodeMap* nm = mod_zb.find_node(pan_id, _node_id);
        if (nm && nm.eui != _eui)
        {
            writeErrorf("Zigbee coordinator: node id {0, 04x} already exists with different EUI - something went wrong?", _node_id);
            return false;
        }
        if (!nm)
            nm = mod_zb.attach_node(_eui, pan_id, _node_id);
        nm.name = name;
        nm.desc.type = NodeType.coordinator;
        nm.node = this;
//        nm.via = _interface; // TODO: should we set `via` for a local node?

        // populate the node
        foreach (ref e; _endpoints)
        {
            ref ep = nm.get_endpoint(e.id);
            ep.dynamic = false;
            ep.profile_id = e.endpoint.profile_id;
            ep.device_id = e.endpoint.device;
            ep.device_version = 0; // TODO: add version property to endpoint?
            foreach (c; e.endpoint.in_clusters)
            {
                ref cluster = ep.get_cluster(c);
                cluster.dynamic = false;
                // ...attributes?
            }
        }

        // mark all non-coordinator nodes as offline; short addresses may be stale after NCP restart
        // pre-population below will re-attach nodes the NCP confirms; remaining nodes recover when they next communicate
        foreach (ref n; mod_zb.nodes_by_eui)
        {
            if (n.value.pan_id == pan_id && n.value.id != _node_id)
            {
                mod_zb.detach_node(n.value.pan_id, n.value.id);
                n.value.scan_in_progress = false;
            }
        }

        // TODO: are we supposed to permit joining for a little while after network-up?
        //       is this for all the clients to re-sync, or will they all join anyway?
        //       if this is for new clients to join, then we don't need to do this here...
        EmberStatus status = ezsp.request!EZSP_PermitJoining(0xFF);
        if (status != EmberStatus.SUCCESS)
            writeInfo("Zigbee coordinator: PermitJoining failed - ", status);

        // pre-populate the node table as best we can...
        auto conf = ezsp.request!EZSP_GetConfigurationValue(EzspConfigId.MAX_END_DEVICE_CHILDREN);
        if (conf.status != EzspStatus.SUCCESS)
            writeInfo("Zigbee coordinator: GetConfigurationValue failed - ", conf.status);
        else
        {
            foreach (ubyte i; 0 .. cast(ubyte)conf.value)
            {
                auto child = ezsp.request!EZSP_GetChildData(i);
                if (child.status == EmberStatus.SUCCESS)
                {
                    if (child.childData.id == 0xFFFF)
                        continue;
                    nm = mod_zb.attach_node(EUI64(child.childData.eui64), pan_id, child.childData.id);
//                    nm.parent_id = _node_id; // TODO: is the coordinator the parent, or it's preferred router?
                    nm.desc.type = cast(NodeType)child.childData.type;
                    nm.via = _interface;
                }
            }
        }

        conf = ezsp.request!EZSP_GetConfigurationValue(EzspConfigId.ADDRESS_TABLE_SIZE);
        if (conf.status != EzspStatus.SUCCESS)
            writeInfo("Zigbee coordinator: GetConfigurationValue failed - ", conf.status);
        else
        {
            foreach (ubyte i; 0 .. cast(ubyte)conf.value)
            {
                EmberNodeId nodeId = ezsp.request!EZSP_GetAddressTableRemoteNodeId(i);
                if (nodeId == 0xFFFF)
                    continue;
                EmberEUI64 eui = ezsp.request!EZSP_GetAddressTableRemoteEui64(i);
                nm = mod_zb.attach_node(EUI64(eui), pan_id, nodeId);
//                nm.parent_id = _node_id; // TODO: is the coordinator the parent, or it's preferred router?
            }
        }
        return true;
    }

    bool do_destroy_network()
    {
        auto ezsp = get_ezsp();

        EmberStatus status = ezsp.request!EZSP_LeaveNetwork();
        writeDebug("Zigbee coordinator: leave network - status: ", status);

        status = ezsp.request!EZSP_ClearKeyTable();
        writeDebug("Zigbee coordinator: clear key table - status: ", status);

        ezsp.request!EZSP_ClearTransientLinkKeys();
        ezsp.request!EZSP_TokenFactoryReset(false, true);
        ezsp.request!EZSP_ResetNode();

        return true;
    }

nothrow:
    void join_handler(EmberNodeId new_node_id, EmberEUI64 new_node_eui64, EmberDeviceUpdate status, EmberJoinDecision policy_decision, EmberNodeId parent_of_new_node_id)
    {
        if (!running)
            return; // we are not handling events yet

        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;
        auto eui = EUI64(new_node_eui64);

        if (policy_decision == EmberJoinDecision.DENY_JOIN)
        {
            writeInfof("Zigbee coordinator: join denied - {0, 04x} {1}", new_node_id, eui);
            return;
        }
        if (status == EmberDeviceUpdate.DEVICE_LEFT)
        {
            writeDebugf("Zigbee coordinator: TC left - {0, 04x} {1}", new_node_id, eui);
            mod_zb.detach_node(pan_id, new_node_id);
            return;
        }

        auto n = mod_zb.attach_node(eui, pan_id, new_node_id);
        n.parent_id = parent_of_new_node_id; // TODO: should we be concerned if we don't know who the parent is?
        n.last_seen = getSysTime();
//        n.via = _interface; // TODO: should we set `via` for a local node?

        writeDebugf("Zigbee coordinator: TC join - {0,04x} [{1}] (parent: {2,04x}) {3}", new_node_id, eui, parent_of_new_node_id, status);

        if (status == EmberDeviceUpdate.STANDARD_SECURITY_UNSECURED_JOIN)
        {
            get_ezsp.send_command!EZSP_UnicastCurrentNetworkKey(&unicast_network_key_result, new_node_id, new_node_eui64, parent_of_new_node_id);
        }

        if (n.desc.type == NodeType.unknown)
        {
            // TODO: should probably only do this if `parent_of_new_node_id == _node_id`, because if we're not the parent; not our child?
            get_ezsp.send_command!EZSP_Id(&get_child_index, new_node_id);
        }

        // TODO: consider; maybe we shouldn't fetch this eagerly?
        //       maybe only if the type can't be fetched from EZSP?
        if (!(n.initialised & 0x01))
        {
            ubyte[3] req_buffer = void;
            req_buffer[0] = 0;
            req_buffer[1..3] = new_node_id.nativeToLittleEndian;
            send_zdo_message(new_node_id, ZDOCluster.node_desc_req, req_buffer[], PCP.vo, &get_node_desc, cast(void*)size_t(new_node_id));
        }
    }

    void unicast_network_key_result(EmberStatus status)
    {
        if (status != EmberStatus.SUCCESS)
            writeDebugf("Zigbee coordinator: UnicastCurrentNetworkKey FAILED");
    }

    void get_child_index(ubyte childIndex)
    {
        if (childIndex == 0xFF)
        {
            writeDebugf("Zigbee coordinator: not my child...");
            return;
        }
        get_ezsp.send_command!EZSP_GetChildData(&get_child_date, childIndex);
    }

    void get_child_date(EmberStatus status, EmberChildData childData)
    {
        if (status == EmberStatus.SUCCESS)
            writeDebugf("Zigbee coordinator: child {0, 04x} [{1}] {2}", childData.id, EUI64(childData.eui64), childData.type);

        auto n = get_module!ZigbeeProtocolModule.attach_node(EUI64(childData.eui64), pan_id, childData.id);
        n.parent_id = _node_id;
        n.desc.type = cast(NodeType)childData.type;
//        n.via = _interface; // TODO: should we set `via` for a local node?

        // TODO: do we want to record phy/power/timeout/remaining?
    }

    void get_node_desc(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void* user_data)
    {
        if (result != ZigbeeResult.success)
            return;

        ushort node_id = cast(ushort)cast(size_t)user_data;
        auto n = get_module!ZigbeeProtocolModule.find_node(pan_id, node_id);
        if (n)
            message.parse_node_desc(n);
    }

    void child_join(ubyte index, bool joining, EmberNodeId child_id, EmberEUI64 child_eui64, EmberNodeType child_type)
    {
        if (!running)
            return; // we are not handling events yet

        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;
        auto eui = EUI64(child_eui64);

        auto n = mod_zb.attach_node(eui, pan_id, child_id);
        n.desc.type = cast(NodeType)child_type;
        n.last_seen = getSysTime();
//        n.via = _interface; // TODO: should we set `via` for a local node?

        if (joining)
        {
            n.parent_id = _node_id;
            writeDebugf("Zigbee coordinator: child join - {0, 04x} [{1}] {2}", child_id, eui, child_type);
        }
        else
        {
            n.parent_id = 0xFFFE; // TODO: who is its parent now?
            writeDebugf("Zigbee coordinator: child left - {0, 04x} [{1}]", child_id, eui);

            // TODO: is there a way to know if the child left the network completely?
        }
    }

    void key_establishment(EmberEUI64 partner, EmberKeyStatus status)
    {
        const eui = EUI64(partner[]);
        writeDebugf("Zigbee coordinator: key establishment - partner: {0}, status: {1}", eui, status);
    }

    void remote_set_binding(EmberBindingTableEntry entry, ubyte index, EmberStatus policy_decision)
    {
        assert(false, "TODO");
    }

    void remote_delete_binding(ubyte index, EmberStatus policy_decision)
    {
        assert(false, "TODO");
    }

    void state_change(BaseObject object, StateSignal signal)
    {
        // if the interface goes offline, we should restart the coordinator...
        if (object is _interface && signal == StateSignal.offline)
            restart();
    }

protected:
    final override bool handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        bool response_required = (aps.flags & APSFlags.zdo_response_required) != 0;

        //...

        return super.handle_zdo_frame(aps, p);
    }
}


void set_configuration(EZSPClient ezsp, EzspConfigId id, ushort value)
{
    EzspStatus r = ezsp.request!EZSP_SetConfigurationValue(id, value);
    if (r != EzspStatus.SUCCESS)
        writeInfo("Zigbee coordinator: SetConfigurationValue(", id, ", ", value, ") failed: ", r);
}

void set_policy(EZSPClient ezsp, EzspPolicyId id, EzspDecisionId decision)
{
    EzspStatus r = ezsp.request!EZSP_SetPolicy(id, decision);
    if (r != EzspStatus.SUCCESS)
        writeInfo("Zigbee coordinator: SetPolicy(", id, ", ", decision, ") failed: ", r);
}
