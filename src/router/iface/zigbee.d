module router.iface.zigbee;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.temp;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection;
import manager.element;

import protocol.ezsp.client;
import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.client;
import protocol.zigbee.coordinator;

import router.iface;
import router.iface.mac;
import router.iface.packet;
import router.iface.priority_queue;

//version = DebugZigbeeMessageFlow;

nothrow @nogc:


// devices who rx while idle (exclude sleepy devices)
enum broadcast_active           = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD);
// routing-capable devices (routers, coordinators)
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


enum uint queue_timeout = 30_000; // milliseconds — safety net only; message_sent_handler is the real completion path
enum uint ezsp_grace_period = 4000; // milliseconds — how long to wait for EZSP client to recover before restarting


class ZigbeeInterface : BaseInterface
{
    __gshared Property[3] Properties = [ Property.create!("ezsp-client", ezsp_client)(),
                                         Property.create!("max-in-flight", max_in_flight)(),
                                         Property.create!("pan-id", pan_id)() ];
nothrow @nogc:

    enum type_name = "zigbee";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ZigbeeInterface, name.move, flags);
    }

    // Properties...

    inout(EZSPClient) ezsp_client() inout pure
        => _ezsp_client;
    StringResult ezsp_client(EZSPClient value)
    {
        if (!value)
            return StringResult("ezsp-client cannot be null");
        if (_ezsp_client is value)
            return StringResult.success;
        if (_subscribed)
        {
            _ezsp_client.unsubscribe(&ezsp_state_change);
            set_ezsp_callbacks(false);
            if (is_coordinator)
                _coordinator.subscribe_client(_ezsp_client, false);
            _subscribed = false;
        }

        _ezsp_client = value;
        _network_status = EmberStatus.NETWORK_DOWN;

        restart();
        return StringResult.success;
    }

    ubyte max_in_flight() const pure
        => _max_in_flight;
    StringResult max_in_flight(ubyte value)
    {
        if (value == 0)
            return StringResult("max-in-flight must be non-zero");
        _max_in_flight = value;
        return StringResult.success;
    }

    bool is_coordinator() const pure
        => _coordinator !is null;

    ushort pan_id() const pure
        => _coordinator ? _coordinator.pan_id : 0;

    // API...

    final override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        debug assert(msg_handle >= 0 && msg_handle <= 0xFF, "invalid msg_handle");

        ubyte t = cast(ubyte)msg_handle;
        if (auto pm = t in _pending)
        {
            if (pm.callback)
                pm.callback(msg_handle, reason);
            _pending.remove(t);
        }
        _queue.abort(t);
    }

    final override MessageState msg_state(int msg_handle) const
    {
        if (cast(ubyte)msg_handle in _pending)
            return MessageState.in_flight;
        if (_queue.is_queued(cast(ubyte)msg_handle))
            return MessageState.queued;
        return MessageState.complete;
    }

//package: // TODO: should this be hidden in some way?
    void attach_coordiantor(ZigbeeCoordinator coordinator)
    {
        _coordinator = coordinator;
        restart();
    }

protected:

    override bool validate() const
        => _ezsp_client !is null;

    override CompletionStatus validating()
    {
        _ezsp_client.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_ezsp_client.running)
            return CompletionStatus.continue_;

        // Register EZSP callback handlers early — the coordinator needs
        // status_handler to receive NETWORK_UP during its init sequence.
        // This is idempotent (set_callback_handler overwrites).
        if (!_subscribed)
            set_ezsp_callbacks(true);

        if (is_coordinator)
        {
            if (_coordinator.ready)
            {
                _ezsp_client.subscribe(&ezsp_state_change);
                _coordinator.subscribe_client(_ezsp_client, true);
                _subscribed = true;
                _queue.init(_max_in_flight, 1, PCP.ca, &_status);
                _queue.set_transport_timeout(queue_timeout.msecs);
                return CompletionStatus.complete;
            }
        }
        else
        {
            if (_ezsp_client.stack_type == EZSPStackType.coordinator)
            {
                writeError("EZSP device must run router firmware be used as an interface");
                return CompletionStatus.error;
            }

            _ezsp_client.subscribe(&ezsp_state_change);
            _subscribed = true;

            // startup in router mode...
            assert(false, "TODO");

            return CompletionStatus.complete;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        // if the network is still up, leave it before tearing down context
        if (_ezsp_client && _network_status == EmberStatus.NETWORK_UP)
        {
            if (_ezsp_client.running)
            {
                if (!_leave_sent)
                {
                    _ezsp_client.send_command!EZSP_LeaveNetwork(null);
                    _leave_sent = true;
                }
                // wait for status_handler to confirm NETWORK_DOWN
                return CompletionStatus.continue_;
            }

            _network_status = EmberStatus.NETWORK_DOWN;
        }
        _leave_sent = false;

        // Always clear EZSP callbacks — they may have been registered
        // early in startup before _subscribed was set.
        set_ezsp_callbacks(false);

        if (_subscribed)
        {
            _ezsp_client.unsubscribe(&ezsp_state_change);
            if (is_coordinator)
                _coordinator.subscribe_client(_ezsp_client, false);
            _subscribed = false;
        }

        get_module!ZigbeeProtocolModule.detach_all_nodes(this);

        // abort all pending messages
        foreach (kvp; _pending[])
        {
            if (kvp.value.callback)
                kvp.value.callback(kvp.key, MessageState.aborted);
        }
        _pending.clear();
        _queue.abort_all();

        _last_ping = MonoTime();
        _ezsp_offline_since = MonoTime();

        if (_ezsp_client)
            _network_status = EmberStatus.NETWORK_DOWN;

        return CompletionStatus.complete;
    }

    override void update()
    {
        MonoTime now = getTime();

        // delayed restart: give EZSP client a grace period to recover
        if (_ezsp_offline_since != MonoTime())
        {
            if (now - _ezsp_offline_since > ezsp_grace_period.msecs)
                restart();
            return; // don't send while client is offline
        }

        _queue.timeout_stale(now);

        send_queued_messages();

        // Counter polling — 200ms when idle, 2s hard maximum
        long ping_elapsed = (now - _last_ping).as!"msecs";
        if (ping_elapsed >= 2000 || (ping_elapsed >= 200 && !_queue.has_pending() && _queue.in_flight_count() == 0))
        {
            _last_ping = now;
            _ezsp_client.send_command!EZSP_ReadAndClearCounters(&counter_response_handler);
        }

        // TODO: should we poll EZSP_NetworkState? or expect the state change callback to inform us?
    }

    final override int transmit(ref const Packet packet, MessageCallback callback = null) nothrow @nogc
    {
        // can only handle zigbee packets
        switch (packet.type)
        {
            case PacketType.zigbee_aps:
                // the APS code follows this switch...
                break;

            case PacketType.zigbee_nwk:
                if (_ezsp_client)
                {
                    writeWarning("Zigbee: cannot send raw NWK frames via EZSP");
                    goto default;
                }

                // NWK frame; we need to implement the NWK protocol I guess?
                assert(false, "TODO: handle NWK frame... or de-frame APS message and goto ZigbeeAPS?");

            default:
                ++_status.send_dropped;
                return ZigbeeResult.unsupported;
        }

        Packet p = packet;
        int tag = _queue.enqueue(p, &on_frame_complete);
        if (tag < 0)
        {
            ++_status.send_dropped;
            return -1;
        }

        _pending[cast(ubyte)tag] = PendingMessage(callback, packet.hdr!APSFrame, cast(ushort)packet.data.length, getTime());

        send_queued_messages();
        return tag;
    }

    override ushort pcap_type() const
        => 283; // DLT_IEEE802_15_4_TAP

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packetData) nothrow @nogc sink) const
    {
        ref aps = packet.hdr!APSFrame;
        const(ubyte)[] data = cast(ubyte[])packet.data;

        ubyte[28] tmp = 0;

        // write the TAP header
        ubyte tlv_len = 20;
        tmp[6] = 1; // FCS_TYPE len
        tmp[12] = 3; tmp[14] = 3; // channel
        tmp[16] = _coordinator.channel;
        if (dir == PacketDirection.incoming)
        {
            tmp[20] = 1; tmp[22] = 4; // RSSI
            tmp[24..28] = float(aps.last_hop_rssi).nativeToLittleEndian;
            tlv_len += 8;
        }
        tmp[2] = tlv_len; // TLV header length
        sink(tmp[0 .. tlv_len]);

        // MAC header
        tmp[0] = 0x41; // data frame | pan comp
        tmp[1] = 0x98;
        tmp[2] = 1; // seq num (TODO: should we fake a sequence?)
        tmp[3..5] = aps.pan_id.nativeToLittleEndian; // PAN
        if (aps.delivery_mode == APSDeliveryMode.broadcast)
            tmp[5..7] = ushort(0xFFFF).nativeToLittleEndian; // FFFD/FFFC are not used in MAC
        else
            tmp[5..7] = aps.dst.nativeToLittleEndian; // dst addr
        tmp[7..9] = aps.src.nativeToLittleEndian; // src addr
        sink(tmp[0 .. 9]);

        // NWK header
        size_t len = 8;
        tmp[0] = 0x08; // fcf-low
        tmp[1] = 0; // fcf-high (0x08 = dst eui, 0x10 = src eui)
        tmp[2..4] = aps.dst.nativeToLittleEndian; // dst addr
        tmp[4..6] = aps.src.nativeToLittleEndian; // src addr
        tmp[6] = 30; // radius
        tmp[7] = 1; // seq num (TODO: should we fake a sequence?)
        if (NodeMap* n = get_module!ZigbeeProtocolModule.find_node(aps.pan_id, dir == PacketDirection.incoming ? aps.src : aps.dst))
        {
            tmp[1] |= dir == PacketDirection.incoming ? 0x10 : 0x08;
            tmp[8..16] = n.eui.b; // dst eui64
            len += 8;
        }
        sink(tmp[0 .. len]);

        // write the APS frame
        len = aps.format_aps_frame(tmp);
        sink(tmp[0 .. len]);

        // and finally, the payload...
        sink(data);
    }

private:

    struct PendingMessage
    {
        MessageCallback callback;
        APSFrame aps;
        ushort message_length;
        MonoTime send_time;
    }

    ObjectRef!EZSPClient _ezsp_client;

    // this is used to store the sender EUI64 for the next incoming message
    EUI64 _sender_eui;
    package(protocol.zigbee) EmberStatus _network_status;
    ZigbeeCoordinator _coordinator;

    bool _leave_sent;
    bool _subscribed;
    ubyte _max_in_flight = 3;

    MonoTime _last_ping;
    MonoTime _ezsp_offline_since;

    PriorityPacketQueue _queue;
    Map!(ubyte, PendingMessage) _pending;

    void send_queued_messages()
    {
        if (_ezsp_offline_since != MonoTime())
            return;

        for (QueuedFrame* frame = _queue.dequeue(); frame !is null; frame = _queue.dequeue())
        {
            const(ubyte)[] data = cast(const(ubyte)[])frame.packet.data();

            ZigbeeResult result = send_message(frame.tag, frame.packet.hdr!APSFrame, data);
            if (result != ZigbeeResult.success)
            {
                ++_status.send_dropped;
                _queue.complete(frame.tag, MessageState.failed);
            }
        }
    }

    ZigbeeResult send_message(ubyte tag, ref const APSFrame hdr, const(ubyte)[] data)
    {
        if (_ezsp_client)
        {
            if (hdr.type != APSFrameType.data)
            {
                writeWarning("Zigbee: cannot send non-data APS frames via EZSP");
                return ZigbeeResult.unsupported;
            }

            EmberApsFrame aps;
            aps.profileId = hdr.profile_id;
            aps.clusterId = hdr.cluster_id;
            aps.sourceEndpoint = hdr.src_endpoint;
            aps.destinationEndpoint = hdr.dst_endpoint;
            aps.options = hdr.security ? EmberApsOption.ENCRYPTION : EmberApsOption.NONE;
            aps.sequence = hdr.counter;

            void* user_data = cast(void*)size_t(tag);
            bool sent;
            if (hdr.delivery_mode == APSDeliveryMode.broadcast)
                sent = _ezsp_client.send_command!EZSP_SendBroadcast(&send_message_response, EmberNodeId(hdr.dst), aps, 0, tag, data, user_data);
            else if (hdr.delivery_mode == APSDeliveryMode.group)
            {
                aps.groupId = hdr.dst;
                sent = _ezsp_client.send_command!EZSP_SendMulticast(&send_message_response, aps, 0, 7, tag, data, user_data);
            }
            else
            {
                aps.options |= EmberApsOption.RETRY;

                NodeMap* n = get_module!ZigbeeProtocolModule.find_node(hdr.pan_id, hdr.dst);
                if (!n)
                    aps.options |= EmberApsOption.ENABLE_ROUTE_DISCOVERY;

                // TODO: handle fragmentation...
                if (hdr.fragmentation != APSFragmentation.none)
                {
                    aps.options |= EmberApsOption.FRAGMENT;
                    if (hdr.fragmentation == APSFragmentation.first)
                        aps.groupId = cast(ushort)(hdr.block_number << 8);
                    else
                        aps.groupId = hdr.block_number;
                }

                sent = _ezsp_client.send_command!EZSP_SendUnicast(&send_message_response, EmberOutgoingMessageType.DIRECT, EmberNodeId(hdr.dst), aps, tag, data, user_data);
            }
            if (!sent)
            {
                version (DebugZigbeeMessageFlow)
                    writeDebugf("Zigbee: APS dispatch FAILED ({0,03}) - {1, 04x}:{2, 02x}->{3, 04x}:{4, 02x} [{5}:{6, 04x}]", tag, hdr.src, hdr.src_endpoint, hdr.dst, hdr.dst_endpoint, profile_name(hdr.profile_id), hdr.cluster_id);
                return ZigbeeResult.failed;
            }

            version (DebugZigbeeMessageFlow)
                writeDebugf("Zigbee: APS dispatch ({0,03}) - {1, 04x}:{2, 02x}->{3, 04x}:{4, 02x} [{5}:{6, 04x}] - [{7}]", tag, hdr.src, hdr.src_endpoint, hdr.dst, hdr.dst_endpoint, profile_name(hdr.profile_id), hdr.cluster_id, cast(void[])data);
        }
        else
        {
            // TODO: based on an underlying interface... wpan? ethernet?
            assert(false);
        }

        return ZigbeeResult.success;
    }

    void send_message_response(void* user_data, EmberStatus status, ubyte aps_sequence)
    {
        ubyte tag = cast(ubyte)(cast(size_t)user_data);

        if (status != EmberStatus.SUCCESS)
        {
            ++_status.send_dropped;

            if (status == EmberStatus.NETWORK_DOWN)
                _network_status = EmberStatus.NETWORK_DOWN;

            version (DebugZigbeeMessageFlow)
                writeDebugf("Zigbee: APS send FAILED ({0,03}): EmberStatus {1, 02x}", tag, status);

            _queue.complete(tag, MessageState.failed);
            send_queued_messages();
            return;
        }

        if (auto pm = tag in _pending)
        {
            pm.aps.counter = aps_sequence;
            _status.send_bytes += pm.message_length;

            version (DebugZigbeeMessageFlow)
                writeDebugf("Zigbee: APS       sent ({0,03}) {1,4}ms - {2, 04x}:{3, 02x}->{4, 04x}:{5, 02x} [{6}:{7, 04x}]", tag, (getTime() - pm.send_time).as!"msecs", pm.aps.src, pm.aps.src_endpoint, pm.aps.dst, pm.aps.dst_endpoint, profile_name(pm.aps.profile_id), pm.aps.cluster_id);

            if (pm.callback)
                pm.callback(tag, MessageState.in_flight);
        }
    }

    void message_sent_handler(EmberOutgoingMessageType type, ushort index_or_destination, EmberApsFrame aps_frame, ubyte message_tag, EmberStatus status, const(ubyte)[] message) nothrow
    {
        if (auto pm = message_tag in _pending)
        {
            if (status != EmberStatus.SUCCESS)
                writeWarningf("Zigbee: APS delivery FAILED: {0} ({1,3}) {2,4}ms - {3, 04x}:{4, 02x}->{5, 04x}:{6, 02x} [{7}:{8, 04x}]", status, message_tag, (getTime() - pm.send_time).as!"msecs", pm.aps.src, pm.aps.src_endpoint, pm.aps.dst, pm.aps.dst_endpoint, profile_name(pm.aps.profile_id), pm.aps.cluster_id);
            else
            {
                version (DebugZigbeeMessageFlow)
                    writeDebugf("Zigbee: APS  delivered ({0,03}) {1,4}ms - {2, 04x}:{3, 02x}->{4, 04x}:{5, 02x} [{6}:{7, 04x}]", message_tag, (getTime() - pm.send_time).as!"msecs", pm.aps.src, pm.aps.src_endpoint, pm.aps.dst, pm.aps.dst_endpoint, profile_name(pm.aps.profile_id), pm.aps.cluster_id);
            }
        }
        else
        {
            version (DebugZigbeeMessageFlow)
                writeDebugf("Zigbee: APS unsolicited message sent ({0,03}) - {1, 04x}:{2, 02x}->{3, 04x}:{4, 02x} [{5}:{6, 04x}] - [{7}]", message_tag, _coordinator.node_id, aps_frame.sourceEndpoint, index_or_destination, aps_frame.destinationEndpoint, profile_name(aps_frame.profileId), aps_frame.clusterId, cast(void[])message);
        }

        _queue.complete(message_tag, status == EmberStatus.SUCCESS ? MessageState.complete : MessageState.failed);
        send_queued_messages();
    }

    void on_frame_complete(int tag, MessageState state)
    {
        ubyte t = cast(ubyte)tag;
        if (auto pm = t in _pending)
        {
            if (pm.callback)
                pm.callback(tag, state);
            _pending.remove(t);
        }
    }

    void set_ezsp_callbacks(bool enable) nothrow
    {
        _ezsp_client.set_message_handler(enable ? &unhandled_message : null);
        _ezsp_client.set_callback_handler!EZSP_StackStatusHandler(enable ? &status_handler : null);
        _ezsp_client.set_callback_handler!EZSP_IncomingSenderEui64Handler(enable ? &incoming_message_sender : null);
        _ezsp_client.set_callback_handler!EZSP_IncomingMessageHandler(enable ? &incoming_message_handler : null);
        _ezsp_client.set_callback_handler!EZSP_MessageSentHandler(enable ? &message_sent_handler : null);
        _ezsp_client.set_callback_handler!EZSP_MacPassthroughMessageHandler(enable ? &mac_passthrough_handler : null);
        _ezsp_client.set_callback_handler!EZSP_CustomFrameHandler(enable ? &custom_frame_handler : null);
        _ezsp_client.set_callback_handler!EZSP_CounterRolloverHandler(enable ? &counter_rollover_handler : null);
    }

    void ezsp_state_change(BaseObject, StateSignal signal) nothrow
    {
        if (signal == StateSignal.offline)
        {
            _ezsp_offline_since = getTime();
            _queue.abort_all_in_flight(MessageState.failed);
        }
        else if (signal == StateSignal.online)
            _ezsp_offline_since = MonoTime();
        else if (signal == StateSignal.destroyed)
            restart();
    }

    void status_handler(EmberStatus status)
    {
        writeInfo("Zigbee: EZSP NETWORK STATUS CHANGE: ", status);

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
        if (_coordinator.node_id == 0xFFFE)
            return; // not joined to a network...

        Packet p;
        ref hdr = p.init!APSFrame(message);
        switch (type)
        {
            case EmberIncomingMessageType.UNICAST:
            case EmberIncomingMessageType.UNICAST_REPLY:
                // EZSP only provides unicast messages if they were destined for "me"
                hdr.dst = _coordinator.node_id;
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
        hdr.pan_id = _coordinator.pan_id;
        hdr.src = sender;
        hdr.security = (aps_frame.options & EmberApsOption.ENCRYPTION) ? true : false;
        hdr.ack_request = false;

        hdr.dst_endpoint = aps_frame.destinationEndpoint;
        hdr.src_endpoint = aps_frame.sourceEndpoint;
        hdr.cluster_id = aps_frame.clusterId;
        hdr.profile_id = aps_frame.profileId;
        hdr.counter = aps_frame.sequence;

        hdr.flags |= aps_frame.options & EmberApsOption.ZDO_RESPONSE_REQUIRED;

        // TODO: do we need bookkeeping for messages that expect replies?
        //       older stack's required explicit SendReply for reply messages, and I can't determine if it's safe to ignore SendReply these days...
        //       What do we keep? How do we match the NCP bookkeeping expectations for SendReply translation?

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

        // record sender...
        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;
        auto n = mod_zb.find_node(_coordinator.pan_id, sender);
        if (!n)
        {
            if (_sender_eui != EUI64())
            {
                n = mod_zb.attach_node(_sender_eui, _coordinator.pan_id, sender);    
                n.via = this;
                _sender_eui = EUI64();
            }
            else
                _ezsp_client.send_command!EZSP_LookupEui64ByNodeId(&lookup_eui_response, sender, cast(void*)size_t(sender));
        }
        else
        {
            n.last_seen = getSysTime();
            n.lqi = last_hop_lqi;
            n.rssi = last_hop_rssi;

            if (n.device)
            {
                if (Element* e = n.device.find_element("status.network.zigbee.rssi"))
                    e.value = n.rssi;
                if (Element* e = n.device.find_element("status.network.zigbee.lqi"))
                    e.value = n.lqi;
            }

            if (n.desc.type == NodeType.sleepy_end_device)
            {
                // TODO: we can try and send some queued messages here?
            }
        }

        version (DebugZigbeeMessageFlow)
            writeDebugf("Zigbee: APS recv ({0, 03}) - {1, 04x}:{2, 02x}<-{3, 04x}:{4, 02x} [{5}:{6, 04x}] - [{7}]", hdr.counter, hdr.dst, hdr.dst_endpoint, hdr.src, hdr.src_endpoint, profile_name(hdr.profile_id), hdr.cluster_id, cast(void[])message);

        dispatch(p);
    }

    void lookup_eui_response(void* user_data, EmberStatus status, EmberEUI64 eui64)
    {
        ushort sender = cast(ushort)(cast(size_t)user_data);
        ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;

        if (status == EmberStatus.SUCCESS)
        {
            auto n = mod_zb.attach_node(EUI64(eui64[]), _coordinator.pan_id, sender);
            n.last_seen = getSysTime(); // NOTE: we're here because we received a message
            n.via = this;
        }
        else
            mod_zb.discover_node(this, _coordinator.pan_id, sender);
    }

    void mac_passthrough_handler(EmberMacPassthroughType message_type, ubyte last_hop_lqi, int8s last_hop_rssi, const(ubyte)[] message) nothrow
    {
        assert(false, "TODO");
    }

    void counter_response_handler(ushort[EmberCounterType.TYPE_COUNT] counters) nothrow
    {
        // TODO: consider; should we count MAC_TX/RX_XXX or APS_DATA_TX/RX_XXX?
        _status.recv_packets += counters[EmberCounterType.MAC_RX_BROADCAST];
        _status.send_packets += counters[EmberCounterType.MAC_TX_BROADCAST];
        _status.recv_packets += counters[EmberCounterType.MAC_RX_UNICAST];
        _status.send_packets += counters[EmberCounterType.MAC_TX_UNICAST_SUCCESS];
        _status.send_dropped += counters[EmberCounterType.MAC_TX_UNICAST_FAILED];

        // TODO: is there any other statistics we want to collect or log?
        //       useful debug information?
    }

    void counter_rollover_handler(EmberCounterType type) nothrow
    {
        switch (type)
        {
            case EmberCounterType.MAC_RX_BROADCAST:
                _status.recv_packets += 0x10000; break;
            case EmberCounterType.MAC_TX_BROADCAST:
                _status.send_packets += 0x10000; break;
            case EmberCounterType.MAC_RX_UNICAST:
                _status.recv_packets += 0x10000; break;
            case EmberCounterType.MAC_TX_UNICAST_SUCCESS:
                _status.send_packets += 0x10000; break;
            case EmberCounterType.MAC_TX_UNICAST_FAILED:
                _status.send_dropped += 0x10000; break;
            default:
                // should we log this? is it interesting?
                writeWarning("Zigbee: EZSP counter rollover - ", type);
                break;
        }
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
                writeErrorf("Zigbee: unhandled EZSP message: x{0,04x}", command);
        }
    }

}
