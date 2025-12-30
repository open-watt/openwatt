module router.iface.zigbee;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.freelist;
import urt.mem.temp;
import urt.meta.nullable;
import urt.result;
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

//version = DebugZigbeeMessageFlow;

nothrow @nogc:


enum MessagePriority : byte
{
    immediate = -1,
    priority = 0,
    normal,
    background
}

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


alias MessageProgressCallback = void delegate(ZigbeeResult status, ref const APSFrame frame) nothrow;


class ZigbeeInterface : BaseInterface
{
    __gshared Property[2] Properties = [ Property.create!("ezsp-client", ezsp_client)(),
                                         Property.create!("max-in-flight", max_in_flight)() ];
nothrow @nogc:

    alias TypeName = StringLit!"zigbee";

    this(String name, ObjectFlags flags = ObjectFlags.None)
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
        if (_ezsp_client && is_coordinator)
            _coordinator.subscribe_client(_ezsp_client, false);

        _ezsp_client = value;
        subscribe_ezsp_client(true);
        if (is_coordinator)
            _coordinator.subscribe_client(_ezsp_client, true);

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
        if (_max_in_flight == value)
            return StringResult.success;
        _max_in_flight = value;
        return StringResult.success;
    }

    bool is_coordinator() const pure
        => _coordinator !is null;

    // API...

    final int forward_async(ref Packet packet, MessageProgressCallback callback, MessagePriority priority)
    {
        if (!running)
            return -1;

        foreach (ref subscriber; subscribers[0..numSubscribers])
        {
            if ((subscriber.filter.direction & PacketDirection.Outgoing) && subscriber.filter.match(packet))
                subscriber.recvPacket(packet, this, PacketDirection.Outgoing, subscriber.userData);
        }

        return transmit_async(packet, callback, priority);
    }

    final void abort_async(int tag, ZigbeeResult reason = ZigbeeResult.aborted)
    {
        debug assert(tag >= 0 && tag <= 0xFF, "invalid tag");

        foreach (msg; _in_flight)
        {
            if (msg.tag == cast(ubyte)tag)
            {
                if (msg.progress_callback)
                    msg.progress_callback(reason, msg.aps);
                msg.progress_callback = null;

                // NOTE: the stack will destroy it...
                return;
            }
        }

        foreach (i; 0 .. NumQueues)
        {
            foreach (j; 0 .. _send_queues[i].length)
            {
                QueuedMessage* msg = _send_queues[i][j];
                if (msg.tag == cast(ubyte)tag)
                {
                    if (msg.progress_callback)
                        msg.progress_callback(reason, msg.aps);
                    msg.progress_callback = null;

                    _send_queues[i].remove(j);
                    _message_pool.free(msg);
                    return;
                }
            }
        }
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

    override CompletionStatus startup()
    {
        if (_ezsp_client)
        {
            // boot up the ezsp client...

            if (!_ezsp_client.running)
                return CompletionStatus.Continue;
        }

        if (is_coordinator)
        {
            if (_coordinator.ready)
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
        // TODO: assure that this code places the coordinator in a state where it will not receive any further messages...

        // HACK: this was moved from coordinator; rethink this...!
        get_module!ZigbeeProtocolModule.remove_all_nodes(this);

        if (is_coordinator)
        {
            _coordinator.subscribe_client(_ezsp_client, false);
            _coordinator = null;
        }

        // abort all pending messages
        foreach (i; 0 .. NumQueues)
        {
            foreach (msg; _send_queues[i])
            {
                if (msg.progress_callback)
                    msg.progress_callback(ZigbeeResult.aborted, msg.aps);
                _message_pool.free(msg);
            }
            _send_queues[i].clear();
        }
        foreach (msg; _in_flight)
        {
            if (msg.progress_callback)
                msg.progress_callback(ZigbeeResult.aborted, msg.aps);
            _message_pool.free(msg);
        }
        _in_flight.clear();
        _last_ping = MonoTime();
        _sequence_number = 0;

        // if we're based on an EZSP instance; clear the eui
        if (_ezsp_client)
        {
            if (_network_status == EmberStatus.NETWORK_UP)
            {
                // drop the network...
                assert(false, "TODO");
            }

            _network_status = EmberStatus.NETWORK_DOWN;
        }

        return CompletionStatus.Complete;
    }

    override void update()
    {
        if (_ezsp_client && !_ezsp_client.running)
            restart();

        MonoTime now = getTime();

        // TODO: timeout stale messages
//        size_t i = 0;
//        for (i = 0; i < _send_queue.length;)
//        {
//            if (_send_queue.state >= 2 || now - _send_queue.send_time > 1200.msecs)
//            {
//                _send_queue.remove(i);
//                --_in_flight;
//            }
//            else
//                ++i;
//        }

        send_queued_messages();

        // NOTE: 10ms interval feels a bit spammy on a serial bus... but I also like counters being responsive!
        //       TODO: should we back-off from this polling when there are actual commands in flight?
        if ((now - _last_ping).as!"msecs" >= 10)
        {
            _last_ping = now;
            _ezsp_client.send_command!EZSP_ReadAndClearCounters(&counter_response_handler);
        }

        // TODO: should we poll EZSP_NetworkState? or expect the state change callback to inform us?
    }

    override bool transmit(ref const Packet packet) nothrow @nogc
        => transmit_async(packet, null, MessagePriority.normal) < 0 ? false : true;

private:

    struct QueuedMessage
    {
        MessageProgressCallback progress_callback;
        MonoTime send_time;
        APSFrame aps;
        Array!ubyte message; // TODO: probably move this to a ring buffer at some point...
        ubyte tag;
        ubyte state; // 0: waiting, 1: submit, 2: received, 3: delivered 4: failed
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

    ubyte _max_in_flight = 3;
    ubyte _sequence_number;

    MonoTime _last_ping;

    FreeList!QueuedMessage _message_pool;

    enum NumQueues = MessagePriority.max + 1;
    Array!(QueuedMessage*)[NumQueues] _send_queues;
    Array!(QueuedMessage*) _in_flight;

    ubyte next_seq() pure
    {
        if (_sequence_number == 0)
            _sequence_number = 1;
        return _sequence_number++;
    }

    void send_queued_messages()
    {
        outer: while (_in_flight.length < _max_in_flight)
        {
            for (size_t i = 0; i < NumQueues; ++i)
            {
                for (size_t j = 0; j < _send_queues[i].length; ++j)
                {
                    QueuedMessage* msg = _send_queues[i][j];
                    assert(msg.state == 0);
                    _send_queues[i].remove(j);

                    ZigbeeResult r = send_message(msg);
                    if (r != ZigbeeResult.success)
                    {
                        ++_status.sendDropped;
                        if (msg.progress_callback)
                            msg.progress_callback(r, msg.aps);
                        _message_pool.free(msg);
                    }
                    continue outer;
                }
            }
            break; // none left to send
        }
    }

    final int transmit_async(ref const Packet packet, MessageProgressCallback callback, MessagePriority priority) nothrow @nogc
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
                return ZigbeeResult.unsupported;
        }

        ref hdr = packet.hdr!APSFrame;

        QueuedMessage* msg = _message_pool.alloc();
        msg.progress_callback = callback;
        msg.aps = hdr;
        msg.message = cast(ubyte[])packet.data[];
        msg.send_time = getTime();
        msg.tag = next_seq();

        if (priority != MessagePriority.immediate && _in_flight.length >= _max_in_flight)
        {
            _send_queues[priority] ~= msg;
            version (DebugZigbeeMessageFlow)
                print_transaction_state(*msg, tconcat("queued (depth: ", _send_queues[priority].length, ")"));
            return msg.tag;
        }

        ZigbeeResult r = send_message(msg);
        if (r != ZigbeeResult.success)
        {
            _message_pool.free(msg);
            ++_status.sendDropped;
            return -1;
        }
        return msg.tag;
    }

    ZigbeeResult send_message(QueuedMessage* msg)
    {
        if (_ezsp_client)
        {
            if (msg.aps.type != APSFrameType.data)
            {
                writeWarning("Zigbee: cannot send non-data APS frames via EZSP");
                return ZigbeeResult.unsupported;
            }

            EmberApsFrame aps;
            aps.profileId = msg.aps.profile_id;
            aps.clusterId = msg.aps.cluster_id;
            aps.sourceEndpoint = msg.aps.src_endpoint;
            aps.destinationEndpoint = msg.aps.dst_endpoint;
            aps.options = msg.aps.security ? EmberApsOption.ENCRYPTION : EmberApsOption.NONE;
            aps.sequence = msg.aps.counter;

            bool sent;
            if (msg.aps.delivery_mode == APSDeliveryMode.broadcast)
                sent = _ezsp_client.send_command!EZSP_SendBroadcast(&send_message_response, EmberNodeId(msg.aps.dst), aps, 0, msg.tag, msg.message[], msg);
            else if (msg.aps.delivery_mode == APSDeliveryMode.group)
            {
                aps.groupId = msg.aps.dst;
                sent = _ezsp_client.send_command!EZSP_SendMulticast(&send_message_response, aps, 0, 7, msg.tag, msg.message[], msg);
            }
            else
            {
                aps.options |= EmberApsOption.RETRY;

                NodeMap* n = get_module!ZigbeeProtocolModule.find_node(msg.aps.pan_id, msg.aps.dst);
                if (!n)
                    aps.options |= EmberApsOption.ENABLE_ROUTE_DISCOVERY;

                // TODO: handle fragmentation...
                if (msg.aps.fragmentation != APSFragmentation.none)
                {
                    aps.options |= EmberApsOption.FRAGMENT;
                    if (msg.aps.fragmentation == APSFragmentation.first)
                        aps.groupId = cast(ushort)(msg.aps.block_number << 8); // block count in high byte
                    else
                        aps.groupId = msg.aps.block_number; // block number in low byte
                }

                sent = _ezsp_client.send_command!EZSP_SendUnicast(&send_message_response, EmberOutgoingMessageType.DIRECT, EmberNodeId(msg.aps.dst), aps, msg.tag, msg.message[], msg);
            }
            if (!sent)
            {
                version (DebugZigbeeMessageFlow)
                    print_transaction_state(*msg, "dispatch FAILED");
                return ZigbeeResult.failed;
            }

            version (DebugZigbeeMessageFlow)
                print_transaction_state(*msg, "dispatch");
        }
        else
        {
            // TODO: based on an underlying interface... wpan? ethernet?
            assert(false);
        }

        msg.state = 1; // in_flight
        _in_flight ~= msg;

        return ZigbeeResult.success;
    }

    void send_message_response(void* user_data, EmberStatus status, ubyte aps_sequence)
    {
        QueuedMessage* msg = cast(QueuedMessage*)user_data;

        // TODO: if we timed the message out, then we might get a callback with a message we destroyed...?

        if (status != EmberStatus.SUCCESS)
        {
            // complain that the message didn't send? should we try and resend?

            msg.state = 3; // failed
            ++_status.sendDropped;

            version (DebugZigbeeMessageFlow)
                writeDebugf("Zigbee: APS send FAILED ({0, 03}): EmberStatus {1, 02x}", msg.tag, status);

            _in_flight.removeFirstSwapLast(msg);

            if (msg.progress_callback)
                msg.progress_callback(ZigbeeResult.failed, msg.aps);

            _message_pool.free(msg);

            send_queued_messages();
            return;
        }

        msg.send_time = getTime(); // reset time for the in-flight state
        msg.aps.counter = aps_sequence;
        _status.sendBytes += msg.message.length; // doesn't include NWK or APS header bytes...

        version (DebugZigbeeMessageFlow)
            print_transaction_state(*msg, "sent");

        // does the user actually want to know this?
        if (msg.progress_callback)
            msg.progress_callback(ZigbeeResult.pending, msg.aps);
    }

    void message_sent_handler(EmberOutgoingMessageType type, ushort index_or_destination, EmberApsFrame aps_frame, ubyte message_tag, EmberStatus status, const(ubyte)[] message) nothrow
    {
        foreach (i, msg; _in_flight)
        {
            if (msg.tag != message_tag)
                continue;

            if (status != EmberStatus.SUCCESS)
            {
                // complain that the message didn't send? should we try and resend?
                // are we supposed to expect a default response to clear the queue?
//                version (DebugZigbeeMessageFlow)
//                    print_transaction_state(*msg, tconcat("delivery FAILED (", status, ")"));
                writeWarningf("Zigbee: APS delivery FAILED: {0} ({1,3}) {2,4}ms - {3, 04x}:{4, 02x}->{5, 04x}:{6, 02x} [{7}:{8, 04x}] - [{9}]", status, msg.tag, (getTime() - msg.send_time).as!"msecs", msg.aps.src, msg.aps.src_endpoint, msg.aps.dst, msg.aps.dst_endpoint, profile_name(msg.aps.profile_id), msg.aps.cluster_id, cast(void[])msg.message[]);
            }
            else
            {
                version (DebugZigbeeMessageFlow)
                    print_transaction_state(*msg, "delivered");
            }

            _in_flight.removeSwapLast(i);

            if (msg.progress_callback)
                msg.progress_callback(status == EmberStatus.SUCCESS ? ZigbeeResult.success : ZigbeeResult.failed, msg.aps);

            _message_pool.free(msg);

            send_queued_messages();
            return;
        }

        // the message isn't in the queue; maybe we timed-out or something?
        // should we make a noise about this?
        version (DebugZigbeeMessageFlow)
            writeDebugf("Zigbee: APS unsolicited message sent ({0, 03}) - {1, 04x}:{2, 02x}->{3, 04x}:{4, 02x} [{5}:{6, 04x}] - [{7}]", message_tag, _coordinator.node_id, aps_frame.sourceEndpoint, index_or_destination, aps_frame.destinationEndpoint, profile_name(aps_frame.profileId), aps_frame.clusterId, cast(void[])message);
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
    }

    void ezsp_state_change(BaseObject object, StateSignal signal) nothrow
    {
        // if the ezsp interface goes offline, we should restart this interface...
        if (object is _ezsp_client && signal == StateSignal.Offline)
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

            if (n.type == NodeType.sleepy_end_device)
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

    version (DebugZigbeeMessageFlow)
    {
        void print_transaction_state(ref QueuedMessage msg, const(char)[] state)
        {
            writeDebugf("Zigbee: APS {0,10} ({1,3}) {2,4}ms - {3, 04x}:{4, 02x}->{5, 04x}:{6, 02x} [{7}:{8, 04x}] - [{9}]", state, msg.tag, (getTime() - msg.send_time).as!"msecs", msg.aps.src, msg.aps.src_endpoint, msg.aps.dst, msg.aps.dst_endpoint, profile_name(msg.aps.profile_id), msg.aps.cluster_id, cast(void[])msg.message[]);
        }
    }
}
