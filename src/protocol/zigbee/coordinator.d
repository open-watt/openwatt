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
import protocol.zigbee.client;

@nogc:


class ZigbeeCoordinator : BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("channel", channel)(),
                                         Property.create!("pan-eui", _pan_eui)(),
                                         Property.create!("pan-id", _pan_id)() ];
@nogc:

    enum TypeName = StringLit!"zigbee-coordinator";

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow
    {
        super(collection_type_info!ZigbeeCoordinator, name.move, flags);
    }

    // Properties...

    final inout(ZigbeeInterface) iface() inout pure nothrow
        => _interface;
    final StringResult iface(BaseInterface value) nothrow
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
            _interface.attach_coordiantor(null);
            if (_interface.ezsp_client)
                subscribe_client(_interface.ezsp_client, false);
        }
        if (zi.is_coordinator)
            return StringResult("interface is already a coordinator");
        _interface = zi;
        _interface.subscribe(&state_change);
        _interface.subscribe(&incoming_packet, PacketFilter());
        _interface.attach_coordiantor(this);
        if (_interface.ezsp_client)
            subscribe_client(_interface.ezsp_client, true);
        return StringResult.success;
    }

    final uint channel() inout pure nothrow
        => _channel;
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

    // API...

    void reboot()
    {
        // reboot the NCP
        if (auto ezsp = get_ezsp())
        {
            ezsp.reboot_ncp();
            _interface.restart(); // TODO: is rebooting another component good policy?
        }
        restart();
    }

    override bool validate() const
        => _interface !is null;

    override CompletionStatus startup()
    {
        if (auto ezsp = get_ezsp())
        {
            if (!ezsp.running)
            {
                if (_init_promise)
                {
                    // the client went down during initialisation...
                    return CompletionStatus.Error;
                }
                return CompletionStatus.Continue;
            }

            if (!_init_promise)
            {
                if (ezsp.stack_type != EZSPClient.StackType.Coordinator && !_already_complained)
                {
                    writeError("Zigbee: EZSP client device is not running cordinator firmware. To use this device, flash with the proper coordinator firmware.");
                    _already_complained = true;
                    // TODO: maybe we should have a sort of non-recoverable error, where it won't automatically try and restart?
                    return CompletionStatus.Error;
                }

                _init_promise = async(&init);
            }
            else if (_init_promise.state != PromiseState.Pending)
            {
                bool failed = _init_promise.state == PromiseState.Failed ? true : !_init_promise.result;
                freePromise(_init_promise);
                if (failed)
                    return CompletionStatus.Error;
                return CompletionStatus.Complete;
            }
        }

        return CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        if (_init_promise)
        {
            if (!_init_promise.finished)
                _init_promise.abort();
            freePromise(_init_promise);
        }

        if (_interface)
        {
            _interface.unsubscribe(&state_change);
            _interface.unsubscribe(&incoming_packet);
            _interface.attach_coordiantor(null);
            if (_interface.ezsp_client)
                subscribe_client(_interface.ezsp_client, false);
            _interface = null;
        }

        _already_complained = false;

        return CompletionStatus.Complete;
    }

    override void update() nothrow
    {
        // TODO: any administrative activities for the coordinator?
        if (_pan_eui != EUI64() && _pan_eui != _network_params.extended_pan_id)
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

    void subscribe_client(EZSPClient client, bool subscribe) nothrow
    {
        client.set_callback_handler!EZSP_TrustCenterJoinHandler(subscribe ? &join_handler : null);
        client.set_callback_handler!EZSP_ChildJoinHandler(subscribe ? &child_join : null);
        client.set_callback_handler!EZSP_ZigbeeKeyEstablishmentHandler(subscribe ? &key_establishment : null);
        client.set_callback_handler!EZSP_RemoteSetBindingHandler(subscribe ? &remote_set_binding : null);
        client.set_callback_handler!EZSP_RemoteDeleteBindingHandler(subscribe ? &remote_delete_binding : null);
    }

private:
    struct NetworkParams
    {
        EUI64 extended_pan_id;
        ushort pan_id;
        ubyte radio_tx_power;
        ubyte radio_channel;
//        EmberJoinMethod join_method; // The method used to initially join the network.
//        EmberNodeId nwk_manager_id;
//        ubyte nwk_update_id;
//        uint channels;
    }

    ZigbeeInterface _interface;
    EUI64 _pan_eui;
    ushort _pan_id = 0xFFFF;
    ubyte _channel = 0xFF;

    ubyte[16] _network_key = cast(ubyte[16])"ZigBeeAlliance09";

    NetworkParams _network_params;

    MonoTime _last_action;
    bool _already_complained; // suppress repeat complaining about the same errors

    Promise!bool* _init_promise;

    inout(EZSPClient) get_ezsp() inout pure nothrow
        => _interface ? _interface.ezsp_client : null;

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
                    writeInfo("Zigbee coordinator: NETWORK JOINED");
                    done = true;
                    break;

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

        ezsp.request!EZSP_SetManufacturerCode(0xFFFF); // "not specified"

        ezsp.set_configuration(EzspConfigId.SUPPORTED_NETWORKS, 1);
        ezsp.set_configuration(EzspConfigId.SECURITY_LEVEL, 5);

        // Configure stack for router/end device joins
        ezsp.set_configuration(EzspConfigId.STACK_PROFILE, 2);

        // Enable MAC passthrough for beacons and join requests
        ezsp.set_configuration(EzspConfigId.APPLICATION_ZDO_FLAGS, EmberZdoConfigurationFlags.APP_RECEIVES_SUPPORTED_ZDO_REQUESTS);

        // TODO: do we need/want any of these?
//        ezsp.set_configuration(EzspConfigId.INDIRECT_TRANSMISSION_TIMEOUT, 0x1000);
//        ezsp.set_configuration(EzspConfigId.MAX_END_DEVICE_CHILDREN, 0x20);
//        ezsp.set_configuration(EzspConfigId.SOURCE_ROUTE_TABLE_SIZE, 0x20);
//        ezsp.set_configuration(EzspConfigId.KEY_TABLE_SIZE, 0x04);
//        ezsp.set_configuration(EzspConfigId.APS_ACK_TIMEOUT, 0x2000);

//        ezsp.set_policy(EzspPolicyId.TRUST_CENTER, EzspDecisionId.ALLOW_TC_KEY_REQUESTS_AND_SEND_CURRENT_KEY);
        ezsp.set_policy(EzspPolicyId.TRUST_CENTER, cast(EzspDecisionId)EzspDecisionBitmask.ALLOW_JOINS);
        ezsp.set_policy(EzspPolicyId.MESSAGE_CONTENTS_IN_CALLBACK, EzspDecisionId.MESSAGE_TAG_AND_CONTENTS_IN_CALLBACK);
        ezsp.set_policy(EzspPolicyId.UNICAST_REPLIES, EzspDecisionId.HOST_WILL_SUPPLY_REPLY);
        ezsp.set_policy(EzspPolicyId.TC_KEY_REQUEST, EzspDecisionId.ALLOW_TC_KEY_REQUEST_AND_GENERATE_NEW_KEY);

        // Set MAC passthrough flags for beacon requests
        ubyte flags = 0xF;
        EzspStatus r = ezsp.request!EZSP_SetValue(EzspValueId.MAC_PASSTHROUGH_FLAGS, (&flags)[0..1]);//EzspValueId.MAC_PASSTHROUGH_FLAGS, EmberMacPassthroughType.EMBER_MAC_PASSTHROUGH_BEACON | EmberMacPassthroughType.EMBERMGMT | EmberMacPassthroughType.EMBER_MAC_PASSTHROUGH_MAC_COMMAND);
        if (r != EzspStatus.SUCCESS)
            writeInfo("Zigbee coordinator: MAC_PASSTHROUGH_FLAGS failed: ", r);

        // update the EUI for this interface; since it's determined by the NCP...
        _interface._eui.b = ezsp.request!EZSP_GetEui64();

        // create the node for this coordinator...
        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;
        NodeMap* mn = mod_zb.add_node(_interface.eui, _interface.mac, _interface);
        mn.name = _interface.name;

//        EmberInitialSecurityState security;
//        security.bitmask = cast(EmberInitialSecurityBitmask)(EmberInitialSecurityBitmask.HAVE_PRECONFIGURED_KEY | EmberInitialSecurityBitmask.TRUST_CENTER_GLOBAL_LINK_KEY);
//        security.preconfiguredKey.contents[] = _network_key;
//        _client.send_command!EZSP_SetInitialSecurityState(&securityResponse, security);

        // register local endpoints
        foreach (ref e; mn.endpoints.values)
        {
            if (e.endpoint == 0)
                continue;
            r = ezsp.request!EZSP_AddEndpoint(e.endpoint, e.profile, e.device, ubyte(0), e.in_clusters[], e.out_clusters[]);
            if (r != EzspStatus.SUCCESS)
                writeInfo("Zigbee coordinator: AddEndpoint failed: ", r);
        }

        // try and raise the network...
        EmberStatus status = ezsp.request!EZSP_NetworkInit(EmberNetworkInitStruct(bitmask: EmberNetworkInitBitmask.NO_OPTIONS));
        if (status == EmberStatus.NOT_JOINED)
        {
            writeInfo("Zigbee coordinator: network init status: ", status);

            // try and form a network...
            assert(false);
            // TODO: what was the state of `networkStateChange` in this path?

            EmberInitialSecurityState security;
            security.bitmask = cast(EmberInitialSecurityBitmask)(EmberInitialSecurityBitmask.HAVE_PRECONFIGURED_KEY | EmberInitialSecurityBitmask.TRUST_CENTER_GLOBAL_LINK_KEY);
            security.preconfiguredKey.contents[] = _network_key;

            status = ezsp.request!EZSP_SetInitialSecurityState(security);
            if (status != EmberStatus.SUCCESS)
                writeInfo("Zigbee coordinator: SetInitialSecurityState failed: ", status);

            // we should form a network here...
            EmberNetworkParameters params;
            if (_pan_eui != EUI64())
                params.extendedPanId = _pan_eui.b;
            else
                params.extendedPanId = _interface.eui.b;
            params.panId = _pan_id;
            params.radioTxPower = 0;
            params.radioChannel = _channel;
            params.joinMethod = EmberJoinMethod.USE_MAC_ASSOCIATION;
            params.nwkManagerId = 0x0000;
            params.nwkUpdateId = 0x00;
            params.channels = 0;

            status = ezsp.request!EZSP_FormNetwork(params);
            if (status != EmberStatus.SUCCESS)
            {
                writeInfo("Zigbee coordinator: FormNetwork failed: ", status);
                return false;
            }
        }

        while (_interface._network_status != EmberStatus.NETWORK_UP)
        {
            // TODO: implement timeout...
            yield();
        }

        auto nwk_params = ezsp.request!EZSP_GetNetworkParameters();
        writeInfo("Zigbee coordinator: NETWORK UP: node-type=", nwk_params.nodeType, "  pan-id=", nwk_params.parameters.extendedPanId, "  channel=", nwk_params.parameters.radioChannel);

        _network_params.extended_pan_id.b = nwk_params.parameters.extendedPanId;
        _network_params.pan_id = nwk_params.parameters.panId;
        _network_params.radio_channel = nwk_params.parameters.radioChannel;
        _network_params.radio_tx_power = nwk_params.parameters.radioTxPower;

        _interface._node_id = ezsp.request!EZSP_GetNodeId();
        assert(_interface.node_id == nwk_params.parameters.nwkManagerId && _interface.node_id == 0x0000, "We are the coordinator, so shouldn't we have id 0?");

        auto node = _interface.find_node(_interface.node_id);
        if (node)
        {
            writeErrorf("Zigbee coordinator: node id {0, 04x} already exists in node table - something went wrong?", _interface.node_id);
            return false;
        }
        node = _interface.add_node(_interface.node_id, _interface.eui);
        node.node_type = EmberNodeType.COORDINATOR;
        node.ncp_index = cast(ubyte)-1;
        node.available = true;

        // TODO: are we supposed to permit joining for a little while after network-up?
        //       is this for all the clients to re-sync, or will they all join anyway?
        //       if this is for new clients to join, then we don't need to do this here...
        status = ezsp.request!EZSP_PermitJoining(0xFF);
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
                    auto n = _interface.add_node(child.childData.id, EUI64(child.childData.eui64));
                    n.node_type = child.childData.type;
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
                _interface.add_node(nodeId, EUI64(eui));
            }
        }
        return true;
    }

    void join_handler(EmberNodeId new_node_id, EmberEUI64 new_node_eui64, EmberDeviceUpdate status, EmberJoinDecision policy_decision, EmberNodeId parent_of_new_node_id) nothrow
    {
        if (policy_decision == EmberJoinDecision.DENY_JOIN)
        {
            writeInfof("Zigbee coordinator: join denied for node {0, 04x} {1}", new_node_id, cast(void[])new_node_eui64);
            return;
        }

        if (status == EmberDeviceUpdate.DEVICE_LEFT)
        {
            writeDebugf("Zigbee coordinator: TC left - {0, 04x} {1}", new_node_id, cast(void[])new_node_eui64);
            _interface.remove_node(new_node_id);
            return;
        }

        // TODO: should we EXPECT to find it if it is a rejoin?
        auto n = _interface.add_node(new_node_id, EUI64(new_node_eui64));
        n.parent = parent_of_new_node_id; // TODO: should we be concerned if we don't know who the parent is?
        n.available = status != EmberDeviceUpdate.DEVICE_LEFT;

        if (status == EmberDeviceUpdate.STANDARD_SECURITY_UNSECURED_JOIN)// && policy_decision == EmberJoinDecision.NO_ACTION)
        {
            // TODO: maybe we have the policy set so that we have to manually respond to the join request?
//            assert(false);
            _interface.ezsp_client.send_command!EZSP_UnicastNwkKeyUpdate((EmberStatus status)
                {
                    if (status != EmberStatus.SUCCESS)
                        writeInfo("Zigbee coordinator: UnicastNwkKeyUpdate - ", status);
                }, new_node_id, new_node_eui64, EmberKeyData(_network_key));
        }

        writeDebugf("Zigbee coordinator: TC join - {0, 04x} [{1}] {2}", new_node_id, cast(void[])new_node_eui64, status);
    }

    void child_join(ubyte index, bool joining, EmberNodeId child_id, EmberEUI64 child_eui64, EmberNodeType child_type) nothrow
    {
        if (!joining)
        {
            writeDebugf("Zigbee coordinator: child left - {0, 04x} {1}", child_id, cast(void[])child_eui64);
            _interface.remove_node(child_id);
            return;
        }

        auto n = _interface.add_node(child_id, EUI64(child_eui64));
        n.ncp_index = index;
        n.available = joining;
        n.node_type = child_type;

        writeDebugf("Zigbee coordinator: child join - {0, 04x} [{1}] {2}", child_id, cast(void[])child_eui64, child_type);
    }

    void key_establishment(EmberEUI64 partner, EmberKeyStatus status) nothrow
    {
        assert(false, "TODO");
    }

    void remote_set_binding(EmberBindingTableEntry entry, ubyte index, EmberStatus policy_decision) nothrow
    {
        assert(false, "TODO");
    }

    void remote_delete_binding(ubyte index, EmberStatus policy_decision) nothrow
    {
        assert(false, "TODO");
    }

    void state_change(BaseObject object, StateSignal signal) nothrow
    {
        // if the interface goes offline, we should restart the coordinator...
        if (object is _interface && signal == StateSignal.Offline)
            restart();
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* userData) nothrow
    {
        // TODO: what messages do we even want to know about as the coordinator?
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
