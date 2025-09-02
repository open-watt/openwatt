module router.iface.zigbee;

import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection;

import protocol.ezsp.client;
import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;

import router.iface;
import router.iface.mac;
import router.iface.packet;

version = DebugZigbeeMessageFlow;

nothrow @nogc:


// devices who rx while idle (exclude sleepy devices)
enum broadcast_active           = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD);
// routing-capable devices (routers, _coordinators)
enum broadcast_routers          = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFC);
// low-power routers
enum broadcast_lowpower_routers = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB);
// zigbee multicast (group) address
enum zigbee_multicast(ushort group) = zigbee_multicast_addr(group);

bool is_zigbee_broadcast(EUI64 addr)
    => addr.b[0] == 0xFF && addr.b[1] == 0xFF && addr.b[2] == 0xFF && addr.b[3] == 0xFF && addr.b[4] == 0xFF && addr.b[5] == 0xFF && addr.b[6] == 0xFF && addr.b[7] >= 0xFB;
bool is_zigbee_multicast(EUI64 addr)
    => addr.b[0] == 0x3 && addr.b[1] == 0 && addr.b[2] == 0 && addr.b[3] == 0 && addr.b[4] == 0 && addr.b[5] == 0;

EUI64 zigbee_multicast_addr(ushort group)
    => EUI64(0x3, 0, 0, 0, 0, 0, group >> 8, cast(ubyte)group);


class ZigbeeInterface : BaseInterface
{
    __gshared Property[4] Properties = [ Property.create!("ezsp-client", ezsp_client)(),
                                         Property.create!("is-coordinator", is_coordinator)(),
                                         Property.create!("eui", eui)(),
                                         Property.create!("node-id", node_id)() ];
                                         // TODO: it should be possible to layer a sigbee interface on a base interface...
nothrow @nogc:

    alias TypeName = StringLit!"zigbee";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!ZigbeeInterface, name.move, flags);
    }

    // Properties...

    inout(EZSPClient) ezsp_client() inout pure
        => _ezsp_client;
    const(char)[] ezsp_client(EZSPClient value)
    {
        if (!value)
            return "ezsp-client cannot be null";
        if (_ezsp_client is value)
            return null;
        if (_ezsp_client && is_coordinator)
            _coordinator.subscribe_client(_ezsp_client, false);

        _ezsp_client = value;
        subscribe_ezsp_client(true);
        if (is_coordinator)
            _coordinator.subscribe_client(_ezsp_client, true);

        _network_status = EmberStatus.NETWORK_DOWN;

        restart();
        return null;
    }

    bool is_coordinator() const pure
        => _coordinator !is null;

    EUI64 eui() const pure
        => _eui;

    ushort node_id() const pure
        => _node_id;

    // API...

    void bindEndpoint(ZigbeeEndpoint endpoint) pure
    {
        if (endpoint.endpoint == 0)
            _zdo = endpoint;
        else
            assert(_state != State.Running, "Endpoints must be added prior to network startup");

        // TODO: we shouldn't need to be the coordinator to bind an endpoint to this node
//        if (is_coordinator)
//            _coordinator.bindEndpoint(endpoint);
    }


    alias send = typeof(super).send;

    bool send(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        assert(message.length <= 256, "TODO: what actually is the maximum zigbee payload?");

        Packet p;
        ref aps = p.init!APSFrame(message);

        aps.type = APSFrameType.data;
        if (eui.is_zigbee_broadcast)
        {
            aps.delivery_mode = APSDeliveryMode.broadcast;
            aps.dst = 0xFF00 | eui.b[7];
        }
        else if (eui.is_zigbee_multicast)
        {
            aps.delivery_mode = APSDeliveryMode.group;
            aps.dst = cast(ushort)((eui.b[6] << 8) | eui.b[7]);
        }
        else
        {
            aps.delivery_mode = APSDeliveryMode.unicast;
            NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
            assert(n, "TODO: what to do if we don't know where it's going? just drop it?");
            aps.dst = n.id;
        }
        aps.src = _node_id;
        aps.dst_endpoint = dst_endpoint;
        aps.src_endpoint = src_endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        // TODO: anything else?

        return forward(p);
    }

    override bool validate() const
        => _ezsp_client !is null; // TODO: || _interface

    override CompletionStatus startup()
    {
        // create zdo endpoint...
        if (!_zdo)
        {
            ZigbeeEndpoint zdo = get_module!ZigbeeProtocolModule.endpoints.create(name, ObjectFlags.Dynamic, NamedArgument("interface", Variant(name)));
            zdo.set_message_handler(&zdo_message_handler);
            bindEndpoint(zdo);
        }

        if (_ezsp_client)
        {
            // boot up the ezsp client...

            if (!_ezsp_client.running)
                return CompletionStatus.Continue;
        }

        if (is_coordinator)
        {
            if (_coordinator.running)
            {
                // TODO: do we need to do any local init after the coordinator started?
                //...

                return CompletionStatus.Complete;
            }
        }
        else
        {
            if (_ezsp_client.stack_type == EZSPClient.StackType.Coordinator)
            {
                writeError("EZSP device must run router firmware be used as an interface");
                return CompletionStatus.Error;
            }

            // startup in router mode...
            assert(false, "TODO");

            return CompletionStatus.Complete;
        }
        return CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        if (_zdo)
        {
            _zdo.destroy();
            _zdo = null;
        }

        // HACK: this was moved from coordinator; rethink this...!
        get_module!ZigbeeProtocolModule.remove_all_nodes(this);
        _nodes.clear();

        if (is_coordinator)
        {
            _coordinator.subscribe_client(_ezsp_client, false);
            _coordinator = null;
        }

        // if we're based an an EZSP instance; clear the eui
        if (_ezsp_client)
        {
            if (_network_status == EmberStatus.NETWORK_UP)
            {
                // drop the network...
                assert(false, "TODO");
            }

            _eui = EUI64();
            _node_id = 0xFFFE;
            _network_status = EmberStatus.NETWORK_DOWN;
        }

        return CompletionStatus.Complete;
    }

    override void update()
    {
        MonoTime now = getTime();
        if ((now - _last_ping).as!"msecs" >= 10)
        {
            _last_ping = now;
            _ezsp_client.send_command!EZSP_ReadAndClearCounters(&counter_response_handler);
        }

        // TODO: should we poll EZSP_NetworkState? or expect the state change callback to inform us?
    }

    //package: // TODO: should this be hidden in some way?
    void attach_coordiantor(ZigbeeCoordinator coordinator)
    {
        _coordinator = coordinator;
        if (!coordinator)
        {
            get_module!ZigbeeProtocolModule.remove_node(_eui);
            _eui = EUI64();
        }
        restart();
    }

protected:
    override bool transmit(ref const Packet packet) nothrow @nogc
    {
        // can only handle zigbee packets
        switch (packet.type)
        {
            case PacketType.ZigbeeAPS:
                // the APS code follows this switch...
                break;

            case PacketType.ZigbeeNWK:
                if (_ezsp_client)
                {
                    writeWarning("Zigbee: cannot send raw NWK frames via EZSP");
                    goto default;
                }

                // NWK frame; we need to implement the NWK protocol I guess?
                assert(false, "TODO: handle NWK frame... or de-frame APS message and goto ZigbeeAPS?");

            default:
                ++_status.sendDropped;
                return false;
        }

        ref hdr = packet.hdr!APSFrame;

        if (_ezsp_client)
        {
            if (hdr.type != APSFrameType.data)
            {
                writeWarning("Zigbee: cannot send non-data APS frames via EZSP");
                ++_status.sendDropped;
                return false;
            }

            EmberApsFrame aps;
            aps.profileId = hdr.profile_id;
            aps.clusterId = hdr.cluster_id;
            aps.sourceEndpoint = hdr.src_endpoint;
            aps.destinationEndpoint = hdr.dst_endpoint;
            aps.options = cast(EmberApsOption)(EmberApsOption.ENABLE_ROUTE_DISCOVERY | (hdr.security ? EmberApsOption.ENCRYPTION : EmberApsOption.NONE));
            aps.sequence = hdr.counter;

            ubyte message_tag = 0;

            bool sent;
            if (hdr.delivery_mode == APSDeliveryMode.broadcast)
                sent = _ezsp_client.send_command!EZSP_SendBroadcast(&send_message_response, EmberNodeId(hdr.dst), aps, 0, message_tag, cast(const(ubyte)[])packet.data[]);
            else if (hdr.delivery_mode == APSDeliveryMode.group)
            {
                aps.groupId = hdr.dst;
                sent = _ezsp_client.send_command!EZSP_SendMulticast(&send_message_response, aps, 0, 7, message_tag, cast(const(ubyte)[])packet.data[]);
            }
            else
            {
                // TODO: handle fragmentation...
                if (hdr.fragmentation != APSFragmentation.none)
                {
                    aps.options |= EmberApsOption.FRAGMENT;
                    if (hdr.fragmentation == APSFragmentation.first)
                        aps.groupId = cast(ushort)(hdr.block_number << 8); // block count in high byte
                    else
                        aps.groupId = hdr.block_number; // block number in low byte
                }

                sent = _ezsp_client.send_command!EZSP_SendUnicast(&send_message_response, EmberOutgoingMessageType.DIRECT, EmberNodeId(hdr.dst), aps, message_tag, cast(const(ubyte)[])packet.data[]);
            }
            if (!sent)
                return false;

            // TODO: probably shouldn't increment these counters until we receive the sent confirmation from the NCP?
            ++_status.sendPackets;
            _status.sendBytes += packet.data.length;
            return true;
        }

        // TODO: based on an underlying interface... wpan? ethernet?
        assert(false);
    }

private:
    struct Node
    {
        ushort id;
        ushort parent;
        ubyte ncp_index;
        EmberNodeType node_type;
        bool available;
//        ubyte last_lqi;
//        byte last_rssi;
        NodeMap* node_map;
    }

    union {
//        struct
//        {
//            BaseInterface _interface; // TODO
//        }
        struct
        {
            EZSPClient _ezsp_client;

            // this is used to store the sender EUI64 for the next incoming message
            EUI64 _sender_eui;
            package(protocol.zigbee) EmberStatus _network_status;
        }
    }
    ZigbeeCoordinator _coordinator;
    ZigbeeEndpoint _zdo;

    MonoTime _last_ping;

package(protocol.zigbee): // TODO: this package declaration should go!
    EUI64 _eui;
    ushort _node_id = 0xFFFE;

    Map!(ushort, Node) _nodes;

    Node* add_node(ushort id, EUI64 eui) nothrow
    {
        Node* n = id in _nodes;
        if (!n)
            n = _nodes.insert(id, Node(id: id));

        bool validEui = eui != EUI64.init;
        if (validEui && !n.node_map)
        {
            NodeMap* mn = get_module!ZigbeeProtocolModule.find_node(eui);
            if (mn)
            {
                n.node_map = mn;
                if (mn.id == 0xFFFE)
                    mn.id = id;
                else
                    assert(mn.id == id, "Node already exists with different id!");
            }
            else
            {
                MACAddress mac = void;
                mac.b[] = eui.b[0..6];
                mac.b[0] = (mac.b[0] & 0xFC) | 2;
                n.node_map = get_module!ZigbeeProtocolModule.add_node(eui, mac, this);
                addAddress(mac, this);
            }
        }
        else
            assert(!validEui || n.node_map.eui == eui, "Node already exists with different eui!");

        return n;
    }

    void remove_node(ushort id) nothrow
    {
        Node* n = id in _nodes;
        if (!n)
            return;

        if (n.node_map)
        {
            // TODO: if node was 'discovered' then remove it

            get_module!ZigbeeProtocolModule.remove_node(n.node_map.eui);
            n.node_map = null;
        }
        _nodes.remove(id);
    }

    inout(Node)* find_node(ushort id) inout nothrow
        => id in _nodes;

private:
    void zdo_message_handler(ref const APSFrame header, const(void)[] message) nothrow
    {
        // TODO: what ZDO messages do we need to handle?
        int x = 0;
    }

    // EZSP related:

    void send_message_response(EmberStatus status, ubyte aps_sequence)
    {
        assert(false);
    }

    void subscribe_ezsp_client(bool subscribe) nothrow
    {
        if (subscribe)
            _ezsp_client.subscribe(&ezsp_state_change);
        else
            _ezsp_client.unsubscribe(&ezsp_state_change);

        _ezsp_client.set_message_handler(subscribe ? &unhandled_message : null);
        _ezsp_client.set_callback_handler!EZSP_StackStatusHandler(subscribe ? &status_handler : null);
        _ezsp_client.set_callback_handler!EZSP_IncomingSenderEui64Handler(subscribe ? &incoming_message_sender : null);
        _ezsp_client.set_callback_handler!EZSP_IncomingMessageHandler(subscribe ? &incoming_message_handler : null);
        _ezsp_client.set_callback_handler!EZSP_MessageSentHandler(subscribe ? &message_sent_handler : null);
        _ezsp_client.set_callback_handler!EZSP_MacPassthroughMessageHandler(subscribe ? &mac_passthrough_handler : null);
        _ezsp_client.set_callback_handler!EZSP_CustomFrameHandler(subscribe ? &custom_frame_handler : null);
        _ezsp_client.set_callback_handler!EZSP_CounterRolloverHandler(subscribe ? &counter_rollover_handler : null);
        _ezsp_client.set_callback_handler!EZSP_IdConflictHandler(subscribe ? &id_conflict_handler : null);
    }

    void send_message_via_ezsp(EUI64 dst, ref EmberApsFrame aps_frame, const(void)[] message, ubyte tag) nothrow
    {
        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(dst);

        assert(n, "TODO: what if we don't know this guy? Should we find him, or just drop the message?");

        // TODO: I THINK THERE'S A WAY TO FLAG? DISCOVER_ROUTE...?

        assert(n.id != 0xFFFE, "TODO: the node isn't known... we should find it");
        // and should we store this until we do, or discard it for now?

        send_message_via_ezsp(n.id, aps_frame, message, tag);
    }

    void send_message_via_ezsp(ushort dst, ref EmberApsFrame aps_frame, const(void)[] message, ubyte tag) nothrow
    {
        if ((dst & 0xFFFC) == 0xFFFC)
        {
            ubyte radius = 0; // infinite radius

            _ezsp_client.send_command!EZSP_SendBroadcast((EmberStatus status, ubyte sequence)
                {
                    if (status != EmberStatus.SUCCESS)
                        writeWarning("Zigbee: SendBroadcast FAILED - ", status);
                    else version (DebugZigbeeMessageFlow)
                        writeDebug("Zigbee: SendBroadcast - seq: ", sequence);
                }, dst, aps_frame, radius, tag, cast(const ubyte[])message);
            return;
        }

        _ezsp_client.send_command!EZSP_SendUnicast((EmberStatus status, ubyte sequence)
            {
                if (status != EmberStatus.SUCCESS)
                    writeWarning("Zigbee: SendUnicast FAILED - ", status);
                else version (DebugZigbeeMessageFlow)
                    writeDebug("Zigbee: SendUnicast - seq: ", sequence);
            }, EmberOutgoingMessageType.DIRECT, dst, aps_frame, tag, cast(const ubyte[])message);
    }

    void ezsp_state_change(BaseObject object, StateSignal signal) nothrow
    {
        // if the ezsp interface goes offline, we should restart this interface...
        if (object is _ezsp_client && signal == StateSignal.Offline)
            restart();
    }

    void status_handler(EmberStatus status)
    {
        writeInfo("Zigbee: NETWORK STATUS CHANGE: ", status);

        if (status == EmberStatus.NETWORK_UP || status == EmberStatus.NETWORK_DOWN)
            _network_status = status;
        else if (status == EmberStatus.NETWORK_OPENED)
        {
            // accept joins
        }
        else if (status == EmberStatus.NETWORK_CLOSED)
        {
            // no longer accept joins
        }
    }

    void incoming_message_sender(ubyte[8] sender) nothrow
    {
        _sender_eui = EUI64(sender);
    }
    void incoming_message_handler(EmberIncomingMessageType type, EmberApsFrame aps_frame, ubyte last_hop_lqi, int8s last_hop_rssi, EmberNodeId sender, ubyte bindingIndex, ubyte addressIndex, const(ubyte)[] message) nothrow
    {
        version (DebugZigbeeMessageFlow)
            writeDebugf("Zigbee: incoming message - from {0, 04x} frame {1} - [{2}]", sender, aps_frame, cast(void[])message);

        Packet p;
        ref hdr = p.init!APSFrame(message);
        switch (type)
        {
            case EmberIncomingMessageType.UNICAST:
            case EmberIncomingMessageType.UNICAST_REPLY:
                // EZSP only provides unicast messages if they were destined for "me"
                hdr.dst = _node_id;
                hdr.delivery_mode = APSDeliveryMode.unicast;
                break;
            case EmberIncomingMessageType.MULTICAST_LOOPBACK:
                assert(sender == 0, "we are the coordinator, how did we get a loopback message that wasn't us?");
                // TODO: this loopback message may be useful to bridge to other zigbee interfaces...?
                //       we'll ignore it for now!
                return;
            case EmberIncomingMessageType.MULTICAST:
                hdr.dst = aps_frame.groupId;
                hdr.delivery_mode = APSDeliveryMode.group;
                break;
            case EmberIncomingMessageType.BROADCAST_LOOPBACK:
                assert(sender == 0, "we are the coordinator, how did we get a loopback message that wasn't us?");
                // TODO: this loopback message may be useful to bridge to other zigbee interfaces...?
                //       we'll ignore it for now!
                return;
            case EmberIncomingMessageType.BROADCAST:
                hdr.dst = 0xFFFF;
                hdr.delivery_mode = APSDeliveryMode.broadcast;
                break;
            case EmberIncomingMessageType.MANY_TO_ONE_ROUTE_REQUEST:
                assert(false, "Unhandled incoming message type!");
            default:
                writeWarning("Zigbee: unhandled incoming message type: ", cast(int)type);
                return;
        }

        hdr.type = APSFrameType.data;
        hdr.src = sender;
        hdr.security = (aps_frame.options & EmberApsOption.ENCRYPTION) ? true : false;
        hdr.ack_request = false;

        hdr.dst_endpoint = aps_frame.destinationEndpoint;
        hdr.src_endpoint = aps_frame.sourceEndpoint;
        hdr.cluster_id = aps_frame.clusterId;
        hdr.profile_id = aps_frame.profileId;
        hdr.counter = aps_frame.sequence;

        if (aps_frame.options & EmberApsOption.ZDO_RESPONSE_REQUIRED)
        {
            // TODO: this incoming message is a ZDO request not handled by the EmberZNet stack,
            //       the application is responsible for sending a ZDO response.
            //       this flag is used only when the ZDO is configured to have requests handled by the application.
            //       see the EZSP_CONFIG_APPLICATION_ZDO_FLAGS configuration parameter for more information.
            assert(false, "TODO");
        }

        if (aps_frame.options & EmberApsOption.FRAGMENT)
        {
            hdr.block_number = cast(ubyte)aps_frame.groupId;
            if (hdr.block_number == 0)
            {
                hdr.fragmentation = APSFragmentation.first;
                hdr.block_number = aps_frame.groupId >> 8;
            }
            else
                hdr.fragmentation = APSFragmentation.fragment;
            hdr.ack_bitfield = 0; // TODO: ???
        }
        else
        {
            hdr.fragmentation = APSFragmentation.none;
            hdr.block_number = 0;
            hdr.ack_bitfield = 0;
        }

        hdr.last_hop_lqi = last_hop_lqi;
        hdr.last_hop_rssi = last_hop_rssi;

        // translate sender...
        auto n = add_node(sender, _sender_eui);
        _sender_eui = EUI64();

        // TODO: if we don't know the sender's EUI, let's find out what it is...
/+
        if (!n.node_map)
        {
            enum ubyte Seq = 0x3f;

            // is this a response to an EUI request?
            if (aps_frame.profileId == 0 && aps_frame.clusterId == 0x8001)
            {
                if (message.length < 12 || message[0] != Seq || message[1] != 0x00)
                    return;
                ubyte[8] eui = message[2 .. 10];
                ushort id = message[10 .. 12].littleEndianToNative!ushort;
                add_node(id, EUI64(eui));
                return; // no point dispatching this message, since we requested it internally...
            }

            // request the EUI from the device...
            EmberApsFrame aps;
            aps.clusterId = 1;
            aps.options = EmberApsOption.ENABLE_ROUTE_DISCOVERY;
            ubyte[5] msg = [ Seq, 0x00, 0x00, 0x00, 0x00 ]; // seq, nodeId, type, index
            msg[1..3] = sender.nativeToLittleEndian;

            ezsp_client.send_command!EZSP_SendUnicast(null, EmberOutgoingMessageType.DIRECT, sender, aps, 0x01, msg[]);

            // we can't dispatch this message, because we can't determine a dst MAC address.
            // we COULD dispatch it if we weren't doing MAC framing of everything... :/
            return;
        }
+/

        dispatch(p);
    }

    void message_sent_handler(EmberOutgoingMessageType type, ushort index_or_destination, EmberApsFrame aps_frame, ubyte message_tag, EmberStatus status, const(ubyte)[] message) nothrow
    {
        version (DebugZigbeeMessageFlow)
            writeDebug("Zigbee: sent message - to ", index_or_destination, " frame ", aps_frame, " - ", cast(void[])message);
    }

    void mac_passthrough_handler(EmberMacPassthroughType message_type, ubyte last_hop_lqi, int8s last_hop_rssi, const(ubyte)[] message) nothrow
    {
        assert(false, "TODO");
    }

    void counter_response_handler(ushort[EmberCounterType.TYPE_COUNT] counters) nothrow
    {
        // TODO: consider; should we count MAC_TX/RX_XXX or APS_DATA_TX/RX_XXX?
        _status.recvPackets += counters[EmberCounterType.MAC_RX_BROADCAST];
        _status.sendPackets += counters[EmberCounterType.MAC_TX_BROADCAST];
        _status.recvPackets += counters[EmberCounterType.MAC_RX_UNICAST];
        _status.sendPackets += counters[EmberCounterType.MAC_TX_UNICAST_SUCCESS];
        _status.sendDropped += counters[EmberCounterType.MAC_TX_UNICAST_FAILED];

        // TODO: is there any other statistics we want to collect or log?
        //       useful debug information?
    }

    void counter_rollover_handler(EmberCounterType type) nothrow
    {
        switch (type)
        {
            case EmberCounterType.MAC_RX_BROADCAST:
                _status.recvPackets += 0x10000; break;
            case EmberCounterType.MAC_TX_BROADCAST:
                _status.sendPackets += 0x10000; break;
            case EmberCounterType.MAC_RX_UNICAST:
                _status.recvPackets += 0x10000; break;
            case EmberCounterType.MAC_TX_UNICAST_SUCCESS:
                _status.sendPackets += 0x10000; break;
            case EmberCounterType.MAC_TX_UNICAST_FAILED:
                _status.sendDropped += 0x10000; break;
            default:
                // should we log this? is it interesting?
                writeWarning("Zigbee: EZSP counter rollover - ", type);
                break;
        }
    }

    void id_conflict_handler(EmberNodeId id)
    {
        // TODO: this is called when the NCP detects multiple nodes using the same id
        //       the stack will remove references to this id, and we should also remove the ID from our records
        assert(false, "TODO");
    }

    void custom_frame_handler(const(ubyte)[] payload) nothrow
    {
        assert(false, "TODO");
    }

    void unhandled_message(ubyte sequence, ushort command, const(ubyte)[] message) nothrow
    {
        switch (command)
        {
            default:
                writeErrorf("Zigbee: unhandled EZSP message: x{0,02x}", command);
        }
    }
}
