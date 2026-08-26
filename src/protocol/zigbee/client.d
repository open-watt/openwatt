module protocol.zigbee.client;

import urt.array;
import urt.async;
import urt.endian;
import urt.fibre;
import urt.lifetime;
import urt.log;
import urt.mem.freelist;
import urt.mem.temp : tstring, tconcat;
import urt.result;
import urt.time;
import urt.string;
import urt.util : InPlace, Default;

import manager;
import manager.collection;

import protocol.ezsp.client;
import protocol.ezsp.commands;
import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.zcl;
import protocol.zigbee.zdo;

import router.iface;
import router.iface.packet;
import protocol.zigbee.iface;

version = DebugZigbee;

nothrow @nogc:

enum Duration zigbee_response_timeout = 2.seconds;
// A parent's indirect queue may deliver after the NCP reports delivery failure.
enum Duration zigbee_indirect_grace = 4.seconds;
// Activity bounds an existing request to one final round trip.
enum Duration zigbee_awake_grace = 300.msecs;
enum Duration zigbee_delivery_deadline = 200.msecs;


alias ZigbeeMessageHandler = void delegate(ref const APSFrame header, const(void)[] message, MonoTime timestamp) nothrow @nogc;
alias ZDOResponseHandler = void delegate(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void* user_data) nothrow @nogc;
alias ZCLResponseHandler = void delegate(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void* user_data) nothrow @nogc;

enum ZDOReply : ubyte
{
    ncp,
    sent,
    intentionally_none,
    impossible,
}

struct ZDOResponse
{
    ZDOStatus status;
    Array!ubyte message;
}

struct ZCLResponse
{
    ZCLHeader hdr;
    Array!ubyte message;
}


class ZigbeeNode : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("is-router", is_router),
                                 Prop!("is-coordinator", is_coordinator),
                                 Prop!("eui", eui),
                                 Prop!("node-id", node_id));
nothrow @nogc:

    enum type_name = "zb-node";
    enum path = "/protocol/zigbee/node";
    enum collection_id = CollectionType.zigbee;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        this(collection_type_info!ZigbeeNode, id, flags);
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
        _interface.subscribe(&incoming_packet, PacketFilter(type: PacketType.zigbee_aps));
        mark_set!(typeof(this), "interface")();
        return StringResult.success;
    }

    EUI64 eui() const pure
        => _eui;

    ushort node_id() const pure
        => _node_id;

    bool is_router() const pure
        => false;

    bool is_coordinator() const pure
        => false;

    // API...

    final int send_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false)
        => send_message(dst, dst_endpoint, src_endpoint, profile_id, cluster_id, message, null, pcp, group);

    final int send_message(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
    {
        if (!running)
            return -1;
        if (eui.is_zigbee_broadcast)
            return send_message(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
        else if (eui.is_zigbee_multicast)
            return send_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, pcp, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        if (!n)
        {
            log.warningf("Zigbee: cannot send to unknown EUI {0}", eui);
            return -1;
        }
        return send_message(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
    }

    final int send_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id,
        ushort cluster_id, const(void)[] message, MessageCallback progress_callback,
        PCP pcp = PCP.be, bool group = false, Duration deadline = Duration.zero,
        PCP urgent_pcp = PCP.ic)
    {
        if (!running)
            return -1;

        if (message.length > 256)
            return -1;

        Packet p;
        ref aps = p.init!APSFrame(message);

        aps.type = APSFrameType.data;
        aps.dst = dst;
        if (dst >= 0xFFFB)
            aps.delivery_mode = APSDeliveryMode.broadcast;
        else
            aps.delivery_mode = group ? APSDeliveryMode.group : APSDeliveryMode.unicast;
        aps.pan_id = zigbee_iface.pan_id;
        aps.src = _node_id;
        aps.src_endpoint = src_endpoint;
        aps.dst_endpoint = dst_endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        p.pcp = pcp;
        p.dei = pcp == PCP.bk;
        QueuePolicy queue_policy;
        const(QueuePolicy)* queue_policy_ptr;
        if (deadline != Duration.zero)
        {
            queue_policy.set_deadline(deadline, urgent_pcp);
            queue_policy_ptr = &queue_policy;
        }

        return _interface.forward(p, progress_callback, queue_policy_ptr);
    }

    final ZigbeeResult send_message_async(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false)
    {
        debug assert(is_in_fibre(), "send_message_async() must be called from a fibre context");

        if (aborting())
            return ZigbeeResult.aborted;

        // yield until sent...
        struct AsyncData
        {
            YieldZB e;
            ZigbeeResult r;

            void progress(int, MessageState state) nothrow @nogc
            {
                if (state <= MessageState.in_flight)
                    return; // intermediate; keep waiting
                r = state == MessageState.complete ? ZigbeeResult.success :
                    state == MessageState.timeout ? ZigbeeResult.timeout :
                    ZigbeeResult.failed;
                e.finished = true;
            }
        }

        AsyncData data;
        auto ev = InPlace!YieldZB(Default);
        data.e = ev;
        ev.timeout = Timer(4.seconds);

        int tag = send_message(dst, dst_endpoint, src_endpoint, profile_id, cluster_id, message, &data.progress, pcp, group);
        if (tag < 0)
            return ZigbeeResult.failed;

        if (yield(ev) == YieldResult.aborted)
        {
            _interface.abort(tag);
            return ZigbeeResult.aborted;
        }

        if (!ev.finished)
        {
            _interface.abort(tag);
            return ZigbeeResult.timeout;
        }
        return data.r;
    }

    final ZigbeeResult send_message_async(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
    {
        debug assert(is_in_fibre(), "send_message_async() must be called from a fibre context");

        if (!running)
            return ZigbeeResult.no_network;
        if (eui.is_zigbee_broadcast)
            return send_message_async(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
        else if (eui.is_zigbee_multicast)
            return send_message_async(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, pcp, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        if (!n)
        {
            log.warningf("Zigbee: cannot send to unknown EUI {0}", eui);
            return ZigbeeResult.failed;
        }
        return send_message_async(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
    }

    final int send_zdo_message(ushort dst, ushort cluster, void[] message, PCP pcp = PCP.be, ZDOResponseHandler response_handler = null, void* user_data = null)
    {
        ubyte[] msg = cast(ubyte[])message;
        bool request = (cluster & 0x8000) == 0;

        if (msg.length == 0)
            return -1;
        if (request && msg[0] == 0)
        {
            msg[0] = allocate_sequence();
            if (msg[0] == 0)
                return -1;
        }
        else if (request && sequence_active(msg[0]))
            return -1;

        ZDORequest* req = null;
        MessageCallback progress = null;
        if (response_handler && request)
        {
            req = _zdo_request_pool.alloc();
            *req = ZDORequest(RequestState(MonoTime(), _interface, -1, dst, cluster, msg[0], 0, ZigbeeResult.pending), response_handler, user_data);
            _zdo_requests.pushBack(req);
            progress = &req.state.progress_callback;
        }

        Duration deadline = request ? Duration.zero : zigbee_delivery_deadline;
        int handle = msg[0];
        int message_handle = send_message(dst, 0, 0, 0, cluster, message, progress, pcp, false, deadline, PCP.ic);
        if (!req)
            return message_handle;
        if (message_handle < 0)
        {
            discard_request(req);
            return -1;
        }
        req.message_handle = message_handle;
        return handle;
    }

    final int send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message, PCP pcp = PCP.ca)
    {
        if (message.length > 254)
            return -1;

        align(size_t.sizeof) ubyte[256] buffer = void;
        buffer[0] = tsn;
        buffer[1] = status;
        buffer[2 .. 2 + message.length] = cast(ubyte[])message[];
        return send_message(dst, 0, 0, 0, cluster, buffer[0 .. 2 + message.length], null,
            pcp, false, zigbee_delivery_deadline, PCP.ic);
    }

    final void abort_zdo_request(int handle, ZigbeeResult reason = ZigbeeResult.aborted)
    {
        for (size_t i = 0; i < _zdo_requests.length; ++i)
        {
            if (_zdo_requests[i].seq == handle)
            {
                abort_zdo_request_at(i, reason);
                return;
            }
        }
    }

    final ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response, PCP pcp = PCP.be)
    {
        debug assert(is_in_fibre(), "send_message_async() must be called from a fibre context");

        if (aborting())
            return ZigbeeResult.aborted;

        struct ResponseData
        {
            YieldZB e;
            ZigbeeResult result;
            ZDOResponse* r;

            void response(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void*) nothrow @nogc
            {
                this.result = result;
                if (result == ZigbeeResult.success)
                {
                    r.status = status;
                    r.message = message;
                }
                e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, ZigbeeResult.success, &response);

        ev.timeout = Timer(10.seconds);

        int handle = send_zdo_message(dst, cluster, message, pcp, &data.response, null);
        if (handle < 0)
            return ZigbeeResult.failed;

        if (yield(ev) == YieldResult.aborted)
        {
            abort_zdo_request(handle);
            return ZigbeeResult.aborted;
        }

        if (!ev.finished)
        {
            version (DebugZigbee)
                log.tracef("zdo TIMEOUT ->{0,04x} [zdo:{1,04x}] at {2}", dst, cluster, ev.timeout.elapsed);
            abort_zdo_request(handle, ZigbeeResult.timeout);
            return ZigbeeResult.timeout;
        }
        else if (data.result != ZigbeeResult.success)
        {
            version (DebugZigbee)
                log.tracef("zdo FAILED <-{0,04x} [zdo:{1,04x}] result {2}", dst, cluster, data.result);
        }
        else version (DebugZigbee)
            log.tracef("zdo response <-{0,04x} [zdo:{1,04x}] after {2}", dst, cluster, ev.timeout.elapsed);
        return data.result;
    }

    final int send_zcl_message(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null)
    {
        if (eui.is_zigbee_broadcast)
            return send_zcl_message(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);
        else if (eui.is_zigbee_multicast)
            return send_zcl_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        if (!n)
        {
            log.warningf("Zigbee: cannot send ZCL command to unknown EUI {0}", eui);
            return -1;
        }
        return send_zcl_message(n.id, dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);
    }

    final int send_zcl_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null)
    {
        ZCLHeader hdr;
        hdr.control = flags;
        if (command >= 0x8000)
            return -1;
        else
            hdr.command = command & 0xFF;
        hdr.cluster_local = (command & 0x4000) != 0;
        hdr.seq = allocate_sequence();
        if (hdr.seq == 0)
            return -1;

        align(size_t.sizeof) void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return -1;

        if (offset + payload.length > buffer.length)
            return -1;
        buffer[offset .. offset + payload.length] = payload[];

        ZCLRequest* req = null;
        MessageCallback progress = null;
        if (response_handler && (hdr.control & ZCLControlFlags.response) == 0)
        {
            req = _zcl_request_pool.alloc();
            *req = ZCLRequest(RequestState(MonoTime(), _interface, -1, dst, cluster, hdr.seq, dst_endpoint, ZigbeeResult.pending), response_handler, user_data);
            _zcl_requests.pushBack(req);
            progress = &req.state.progress_callback;
        }

        int handle = hdr.seq;
        int message_handle = send_message(dst, dst_endpoint, src_endpoint, profile, cluster, buffer[0 .. offset + payload.length], progress, pcp);
        if (!req)
            return message_handle;
        if (message_handle < 0)
        {
            discard_request(req);
            return -1;
        }
        req.message_handle = message_handle;
        return handle;
    }

    final int send_zcl_response(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ref const ZCLHeader req, const(void)[] payload, PCP pcp = PCP.ca)
    {
        ZCLHeader hdr = make_zcl_response_header(command, req);

        align(size_t.sizeof) void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return -1;

        if (offset + payload.length > buffer.length)
            return -1;
        buffer[offset .. offset + payload.length] = payload[];

        return send_message(dst, dst_endpoint, src_endpoint, profile, cluster,
            buffer[0 .. offset + payload.length], null, pcp, false,
            zigbee_delivery_deadline, PCP.ic);
    }

    final void abort_zcl_request(int handle, ZigbeeResult reason = ZigbeeResult.aborted)
    {
        for (size_t i = 0; i < _zcl_requests.length; ++i)
        {
            if (_zcl_requests[i].seq == handle)
            {
                abort_zcl_request_at(i, reason);
                return;
            }
        }
    }

    final ZigbeeResult zcl_request(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response, PCP pcp = PCP.be)
    {
        debug assert(is_in_fibre(), "send_message_async() must be called from a fibre context");

        if (aborting())
            return ZigbeeResult.aborted;

        struct ResponseData
        {
            YieldZB e;
            ZigbeeResult result;
            ZCLResponse* r;

            void response(ZigbeeResult status, const ZCLHeader* hdr, const(ubyte)[] message, void*) nothrow @nogc
            {
                this.result = status;
                if (status == ZigbeeResult.success)
                {
                    r.hdr = *hdr;
                    r.message = message;
                }
                e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, ZigbeeResult.success, &response);

        ev.timeout = Timer(10.seconds);

        int handle = send_zcl_message(dst, dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, &data.response, null);
        if (handle < 0)
            return ZigbeeResult.failed;

        if (yield(ev) == YieldResult.aborted)
        {
            abort_zcl_request(handle);
            return ZigbeeResult.aborted;
        }

        if (!ev.finished)
        {
            version (DebugZigbee)
                log.tracef("zcl TIMEOUT ->{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);
            abort_zcl_request(handle, ZigbeeResult.timeout);
            return ZigbeeResult.timeout;
        }
        else if (data.result != ZigbeeResult.success)
        {
            version (DebugZigbee)
                log.tracef("zcl FAILED ->{0,04x}:{1} [:{2,04x}] result {3}", dst, dst_endpoint, cluster, data.result);
            return data.result;
        }

        version (DebugZigbee)
            log.tracef("zcl response <-{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);

        // let's centralise some basic response validation
        if (response.hdr.command == ZCLCommand.default_response)
        {
            if (response.message.length < 2)
                return ZigbeeResult.truncated;
            if (response.message[0] != command)
                return ZigbeeResult.unexpected;
        }
        else
        {
            // validate expected response for common commands
            switch (command) with (ZCLCommand)
            {
                case read_attributes,
                     configure_reporting,
                     read_reporting_configuration,
                     discover_attributes,
                     write_attributes_structured,
                     discover_commands_received,
                     discover_commands_generated,
                     discover_attributes_extended:
                    if (response.hdr.command != command + 1) // these commands responses are just the next command id
                        return ZigbeeResult.unexpected;
                    break;
//                case write_attributes: // TODO: is this right? what is `write_attributes_undivided`?
//                    if (response.hdr.command != ZCLCommand.write_attributes_response)
//                        return ZigbeeResult.unexpected;
//                    break;
                default:
                    break;
            }
        }

        // TODO: should we centralise validation of any other common messages?

        return ZigbeeResult.success;
    }

    final bool is_network_up() const pure
        => zigbee_iface()._network_status == EmberStatus.NETWORK_UP;

    final void arm_extended_timeout(ref NodeMap node)
    {
        if (node.desc.type != NodeType.sleepy_end_device)
            return;
        ZigbeeInterface i = zigbee_iface();
        if (!i || !i.ezsp_client)
            return;
        i.ezsp_client.send_command!EZSP_SetExtendedTimeout(null, node.eui.b, true);
    }

protected:

    final void set_eui(EUI64 value)
    {
        _eui = value;
        mark_set!(typeof(this), "eui")();
    }

    final void set_node_id(ushort value)
    {
        _node_id = value;
        mark_set!(typeof(this), "node-id")();
    }

    struct Endpoint
    {
        ubyte id;
        ObjectRef!ZigbeeEndpoint endpoint;
    }

    BaseInterface _interface;
    Array!Endpoint _endpoints;

    EUI64 _eui = EUI64.broadcast;
    ushort _node_id = 0xFFFE;
    ubyte _seq = 8;

    this(const(CollectionTypeInfo)* type_info, CID id, ObjectFlags flags)
    {
        super(type_info, id, flags);
    }

    final inout(ZigbeeInterface) zigbee_iface() inout pure
        => dyn_cast!ZigbeeInterface(_interface);

    override bool validate() const pure
        => _interface !is null;

    override CompletionStatus startup()
        => _interface.running ? CompletionStatus.complete : CompletionStatus.continue_;

    override CompletionStatus shutdown()
    {
        while (!_zdo_requests.empty)
            abort_zdo_request_at(_zdo_requests.length - 1, ZigbeeResult.aborted);
        while (!_zcl_requests.empty)
            abort_zcl_request_at(_zcl_requests.length - 1, ZigbeeResult.aborted);

        return CompletionStatus.complete;
    }

    override void update()
    {
        MonoTime now = getTime();

        for (size_t i = 0; i < _zdo_requests.length; )
        {
            ZDORequest* req = _zdo_requests[i];
            if (req.expiry_result != ZigbeeResult.pending && now >= req.deadline)
            {
                version (DebugZigbee)
                    log.warningf("ZDO request {0, 04x} with seq {1} expired: {2}", req.cluster, req.seq, req.expiry_result);

                abort_zdo_request_at(i, req.expiry_result);
            }
            else
                ++i;
        }

        for (size_t i = 0; i < _zcl_requests.length; )
        {
            ZCLRequest* req = _zcl_requests[i];
            if (req.expiry_result != ZigbeeResult.pending && now >= req.deadline)
            {
                version (DebugZigbee)
                    log.warningf("ZCL request {0, 04x} with seq {1} expired: {2}", req.cluster, req.seq, req.expiry_result);

                abort_zcl_request_at(i, req.expiry_result);
            }
            else
                ++i;
        }
    }

    void note_node_activity(ushort src)
    {
        MonoTime cut = getTime() + zigbee_awake_grace;
        foreach (req; _zdo_requests[])
        {
            if (req.dst == src && req.expiry_result != ZigbeeResult.pending)
                constrain_deadline(req.deadline, cut);
        }
        foreach (req; _zcl_requests[])
        {
            if (req.dst == src && req.expiry_result != ZigbeeResult.pending)
                constrain_deadline(req.deadline, cut);
        }
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void*)
    {
        // TODO: we should enhance the PACKET FILTER to do this work!
        ref aps = p.hdr!APSFrame;

        note_node_activity(aps.src);

        const(ubyte)[] data = cast(ubyte[])p.data;

        if (aps.dst_endpoint == 0)
        {
            if (aps.src_endpoint != 0 || aps.profile_id != 0)
                return;

            if (aps.cluster_id & 0x8000) // ZDO response
            {
                if (data.length < 2)
                    return; // malformed
                ubyte seq = data[0];

                for (size_t i = 0; i < _zdo_requests.length; ++i)
                {
                    if (response_source_matches(_zdo_requests[i].dst, aps.src) && _zdo_requests[i].seq == seq && _zdo_requests[i].cluster == (aps.cluster_id & 0x7FFF))
                    {
                        ZDORequest* req = _zdo_requests[i];
                        _zdo_requests.remove(i);
                        record_recent(req.dst, req.cluster, req.seq);
                        ZDOResponseHandler handler = req.response_handler;
                        void* user_data = req.user_data;
                        req.response_handler = null;
                        if (req.iface && req.message_handle > 0)
                            req.iface.abort(req.message_handle);
                        _zdo_request_pool.free(req);
                        if (handler)
                            handler(ZigbeeResult.success, cast(ZDOStatus)data[1], data[2..$], user_data);
                        return;
                    }
                }
                foreach (ref recent; _recent_requests)
                {
                    if (recent.endpoint == 0 && response_source_matches(recent.dst, aps.src) && recent.seq == seq && recent.cluster == (aps.cluster_id & 0x7FFF))
                    {
                        log.debugf("late ZDO response {0, 04x} from {1, 04x} seq {2}", aps.cluster_id, aps.src, seq);
                        return;
                    }
                }

                version (DebugZigbee)
                    log.warningf("received unexpected ZDO response {0, 04x} from {1, 04x} with seq {2}", aps.cluster_id, aps.src, seq);
                return;
            }

            ZDOReply reply = handle_zdo_frame(aps, p);

            if (aps.flags & APSFlags.zdo_response_required)
            {
                if (reply == ZDOReply.impossible)
                    log.warningf("ZDO request {0, 04x} from {1, 04x} requires a response but none was sent!", aps.cluster_id, aps.src);
                else if (reply == ZDOReply.ncp)
                    log.errorf("ZDO request {0, 04x} from {1, 04x} was incorrectly left to the NCP", aps.cluster_id, aps.src);
            }
            return;
        }
        else if (aps.src_endpoint == 0 || aps.profile_id == 0)
            return;

        // check if it's a response to a pending request
        if (data.length > 0 && (data[0] & ZCLControlFlags.response))
        {
            auto seq_offset = (data[0] & ZCLControlFlags.manufacturer_specific) ? 3 : 1;
            if (data.length > seq_offset)
            {
                ubyte seq = data[seq_offset];

                for (size_t i = 0; i < _zcl_requests.length; ++i)
                {
                    if (response_source_matches(_zcl_requests[i].dst, aps.src) && _zcl_requests[i].seq == seq && _zcl_requests[i].endpoint == aps.src_endpoint && _zcl_requests[i].cluster == aps.cluster_id)
                    {
                        ZCLHeader zcl;
                        ptrdiff_t hdr_len = decode_zcl_header(data, zcl);
                        if (hdr_len < 0)
                            return; // malformed

                        ZCLRequest* req = _zcl_requests[i];
                        _zcl_requests.remove(i);
                        record_recent(req.dst, req.cluster, req.seq, req.endpoint);
                        ZCLResponseHandler handler = req.response_handler;
                        void* user_data = req.user_data;
                        req.response_handler = null;
                        if (req.iface && req.message_handle > 0)
                            req.iface.abort(req.message_handle);
                        _zcl_request_pool.free(req);
                        if (handler)
                            handler(ZigbeeResult.success, &zcl, data[hdr_len .. $], user_data);
                        return;
                    }
                }

                foreach (ref recent; _recent_requests)
                {
                    if (recent.endpoint != 0 && response_source_matches(recent.dst, aps.src) && recent.seq == seq && recent.endpoint == aps.src_endpoint && recent.cluster == aps.cluster_id)
                    {
                        log.debugf("late ZCL response from {0, 04x}:{1} [:{2, 04x}] seq {3}", aps.src, aps.src_endpoint, aps.cluster_id, seq);
                        return;
                    }
                }
            }
        }

        // check if it's for an endpoint we own
        foreach (ref ep; _endpoints[])
        {
            if ((aps.dst_endpoint == 0xFF || aps.dst_endpoint == ep.id) && aps.profile_id == ep.endpoint._profile)
                ep.endpoint.incoming_packet(p, this, dir);
        }
    }

    ZDOReply handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        bool response_required = (aps.flags & APSFlags.zdo_response_required) != 0;

        const(ubyte)[] req_data = cast(const(ubyte)[])p.data[];
        align(size_t.sizeof) ubyte[256] buffer = void;

        if (!response_required)
            return ZDOReply.ncp;
        if (req_data.length == 0)
            return ZDOReply.impossible;

        switch (aps.cluster_id) with (ZDOCluster)
        {
            case nwk_addr_req:
                if (req_data.length < 11)
                    return send_zdo_status(aps, req_data[0], ZDOStatus.inv_requesttype);

                auto addr = EUI64(req_data[1..9]);
                if (addr != _eui)
                    return ZDOReply.intentionally_none;

                if (req_data[9] != 0)
                    return send_zdo_status(aps, req_data[0], ZDOStatus.not_supported);

                buffer[0] = req_data[0]; // sequence
                buffer[1] = ZDOStatus.success;
                buffer[2..10] = _eui.b[]; // is this meant to be little-endian?
                buffer[10..12] = _node_id.nativeToLittleEndian!ushort;
                return send_zdo_payload(aps, buffer[0..12]);

            case ieee_addr_req:
                if (req_data.length < 5)
                    return send_zdo_status(aps, req_data[0], ZDOStatus.inv_requesttype);

                ushort addr = req_data[1..3].littleEndianToNative!ushort;
                if (_node_id != addr)
                    return ZDOReply.intentionally_none;

                if (req_data[3] != 0)
                    return send_zdo_status(aps, req_data[0], ZDOStatus.not_supported);

                buffer[0] = req_data[0]; // sequence
                buffer[1] = ZDOStatus.success;
                buffer[2..10] = _eui.b[]; // is this meant to be little-endian?
                buffer[10..12] = _node_id.nativeToLittleEndian!ushort;
                return send_zdo_payload(aps, buffer[0..12]);

            case node_desc_req:
            case power_desc_req:
            case simple_desc_req:
            case active_ep_req:
            case match_desc_req,
                 parent_annce,
                 system_server_discovery_req,
                 bind_req,
                 unbind_req,
                 clear_all_bindings_req,
                 mgmt_lqi_req,
                 mgmt_rtg_req,
                 mgmt_bind_req,
                 mgmt_leave_req,
                 mgmt_permit_joining_req,
                 mgmt_nwk_update_req,
                 mgmt_nwk_enhanced_update_req,
                 mgmt_nwk_ieee_joining_list_req,
                 mgmt_nwk_beacon_survey_req:
                return send_zdo_status(aps, req_data[0], ZDOStatus.not_supported);

            case device_annce:
                return ZDOReply.intentionally_none;

            default:
                return send_zdo_status(aps, req_data[0], ZDOStatus.not_supported);
        }
    }

    ZDOReply send_zdo_status(ref const APSFrame aps, ubyte seq, ZDOStatus status)
    {
        int tag = send_zdo_response(aps.src, aps.cluster_id | 0x8000, seq, status, null);
        return tag > 0 ? ZDOReply.sent : ZDOReply.impossible;
    }

    ZDOReply send_zdo_payload(ref const APSFrame aps, void[] payload)
    {
        int tag = send_zdo_message(aps.src, aps.cluster_id | 0x8000, payload, PCP.ca);
        return tag > 0 ? ZDOReply.sent : ZDOReply.impossible;
    }


private:

    ubyte allocate_sequence()
    {
        foreach (_; 0 .. ubyte.max)
        {
            ubyte sequence = _seq;
            _seq = sequence == ubyte.max ? ubyte(1) : cast(ubyte)(sequence + 1);
            if (sequence != 0 && !sequence_in_use(sequence))
                return sequence;
        }
        return 0;
    }

    bool sequence_active(ubyte sequence) const
    {
        foreach (req; _zdo_requests[])
            if (req.seq == sequence)
                return true;
        foreach (req; _zcl_requests[])
            if (req.seq == sequence)
                return true;
        return false;
    }

    bool sequence_in_use(ubyte sequence) const
    {
        if (sequence_active(sequence))
            return true;
        foreach (ref recent; _recent_requests)
            if (recent.seq == sequence)
                return true;
        return false;
    }

    static void constrain_deadline(ref MonoTime deadline, MonoTime limit)
    {
        if (!deadline || deadline > limit)
            deadline = limit;
    }

    static ZigbeeResult message_result(MessageState state)
    {
        if (state == MessageState.timeout || state == MessageState.expired)
            return ZigbeeResult.timeout;
        if (state == MessageState.aborted)
            return ZigbeeResult.aborted;
        return ZigbeeResult.failed;
    }

    static bool response_source_matches(ushort destination, ushort source)
        => destination == source || destination >= 0xFFFB;

    void record_recent(ushort dst, ushort cluster, ubyte sequence)
    {
        record_recent(dst, cluster, sequence, 0);
    }

    void record_recent(ushort dst, ushort cluster, ubyte sequence, ubyte endpoint)
    {
        _recent_requests[_recent_request_pos++ & 7] = RecentRequest(dst, cluster, sequence, endpoint);
    }

    void discard_request(ZDORequest* req)
    {
        foreach (i, active; _zdo_requests[])
        {
            if (active is req)
            {
                _zdo_requests.remove(i);
                _zdo_request_pool.free(req);
                return;
            }
        }
    }

    void discard_request(ZCLRequest* req)
    {
        foreach (i, active; _zcl_requests[])
        {
            if (active is req)
            {
                _zcl_requests.remove(i);
                _zcl_request_pool.free(req);
                return;
            }
        }
    }

    void abort_zdo_request_at(size_t index, ZigbeeResult reason)
    {
        ZDORequest* req = _zdo_requests[index];
        record_recent(req.dst, req.cluster, req.seq);
        _zdo_requests.remove(index);
        ZDOResponseHandler handler = req.response_handler;
        req.response_handler = null;
        if (req.iface && req.message_handle > 0)
            req.iface.abort(req.message_handle);
        void* user_data = req.user_data;
        _zdo_request_pool.free(req);
        if (handler)
            handler(reason, ZDOStatus.success, null, user_data);
    }

    void abort_zcl_request_at(size_t index, ZigbeeResult reason)
    {
        ZCLRequest* req = _zcl_requests[index];
        record_recent(req.dst, req.cluster, req.seq, req.endpoint);
        _zcl_requests.remove(index);
        ZCLResponseHandler handler = req.response_handler;
        req.response_handler = null;
        if (req.iface && req.message_handle > 0)
            req.iface.abort(req.message_handle);
        void* user_data = req.user_data;
        _zcl_request_pool.free(req);
        if (handler)
            handler(reason, null, null, user_data);
    }

    struct RequestState
    {
        MonoTime deadline;
        BaseInterface iface;
        int message_handle;
        ushort dst;
        ushort cluster;
        ubyte seq;
        ubyte endpoint;
        ZigbeeResult expiry_result;

        void progress_callback(int handle, MessageState state) nothrow @nogc
        {
            message_handle = handle;
            if (state <= MessageState.in_flight)
                return;

            iface = null;
            if (state == MessageState.complete)
            {
                expiry_result = ZigbeeResult.timeout;
                deadline = getTime() + zigbee_response_timeout;
            }
            else if (state == MessageState.delivery_failed)
            {
                expiry_result = ZigbeeResult.failed;
                deadline = getTime() + zigbee_indirect_grace;
            }
            else
            {
                expiry_result = message_result(state);
                deadline = getTime();
            }
        }
    }

    struct ZDORequest
    {
        RequestState state;
        alias state this;

        ZDOResponseHandler response_handler;
        void* user_data;
    }

    struct ZCLRequest
    {
        RequestState state;
        alias state this;

        ZCLResponseHandler response_handler;
        void* user_data;
    }

    struct RecentRequest
    {
        ushort dst;
        ushort cluster;
        ubyte seq;
        ubyte endpoint;
    }

    static class YieldZB : AwakenEvent
    {
    nothrow @nogc:
        Timer timeout;
        bool finished;
        override bool ready() { return finished || timeout.expired(); }
    }

    FreeList!ZDORequest _zdo_request_pool;
    Array!(ZDORequest*) _zdo_requests;

    FreeList!ZCLRequest _zcl_request_pool;
    Array!(ZCLRequest*) _zcl_requests;

    RecentRequest[8] _recent_requests;
    ubyte _recent_request_pos;

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


class ZigbeeEndpoint : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("node", node),
                                 Prop!("endpoint-id", endpoint),
                                 Prop!("profile", profile),
                                 Prop!("profile-id", profile_id),
                                 Prop!("device", device),
                                 Prop!("in-clusters", in_clusters),
                                 Prop!("out-clusters", out_clusters));
nothrow @nogc:

    enum collection_id = CollectionType.zb_endpoint;
    enum type_name = "zb-endpoint";
    enum path = "/protocol/zigbee/endpoint";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ZigbeeEndpoint, id, flags);
    }

    ~this()
    {
        if (_node)
            _node.remove_endpoint(this);
    }

    // Properties...

    final inout(ZigbeeNode) node() inout pure // TODO: should return zigbee interface?
        => _node;
    final const(char)[] node(ZigbeeNode value)
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
        mark_set!(typeof(this), "node")();
        return null;
    }

    final ubyte endpoint() inout pure
        => _endpoint;
    final const(char)[] endpoint(ubyte value)
    {
        if (value == 0 || value > 240)
            return "endpoint must be in range 1..240";
        if (_node && _endpoint != 0)
            _node.remove_endpoint(this);
        _endpoint = value;
        if (_node)
            _node.add_endpoint(this);
        mark_set!(typeof(this), "endpoint-id")();
        return null;
    }

    final const(char)[] profile() inout
        => profile_name(_profile);
    final const(char)[] profile(const(char)[] value)
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
        mark_set!(typeof(this), [ "profile", "profile-id" ])();
        return null;
    }

    final ushort profile_id() inout
        => _profile;

    final ushort device() inout pure
        => _device;
    final void device(ushort value)
    {
        _device = value;
        mark_set!(typeof(this), "device")();
    }

    final const(ushort)[] in_clusters() inout pure
        => _in_clusters[];
    final void in_clusters(const(ushort)[] value)
    {
        _in_clusters = value;
        mark_set!(typeof(this), "in-clusters")();
    }
    final void in_clusters(Array!ushort value)
    {
        _in_clusters = value.move;
        mark_set!(typeof(this), "in-clusters")();
    }

    final const(ushort)[] out_clusters() inout pure
        => _out_clusters[];
    final void out_clusters(const(ushort)[] value)
    {
        _out_clusters = value;
        mark_set!(typeof(this), "out-clusters")();
    }
    final void out_clusters(Array!ushort value)
    {
        _out_clusters = value.move;
        mark_set!(typeof(this), "out-clusters")();
    }


    // API...

    void set_message_handler(ZigbeeMessageHandler handler)
    {
        _message_handler = handler;
    }

    int send_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message, PCP pcp = PCP.be, bool group = false)
        => _node.send_message(dst, endpoint, _endpoint, profile, cluster, message, pcp, group);

    int send_message(EUI64 eui, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
        => _node.send_message(eui, endpoint, _endpoint, profile, cluster, message, pcp);

    ZigbeeResult send_message_async(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false)
        => _node.send_message_async(dst, endpoint, _endpoint, profile_id, cluster_id, message, pcp, group);

    ZigbeeResult send_message_async(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
        => _node.send_message_async(eui, endpoint, _endpoint, profile_id, cluster, message, pcp);

    int send_zdo_message(ushort dst, ushort cluster, void[] message, PCP pcp = PCP.be, ZDOResponseHandler response_handler = null, void* user_data = null)
        => _node.send_zdo_message(dst, cluster, message, pcp, response_handler, user_data);

    int send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message, PCP pcp = PCP.ca)
        => _node.send_zdo_response(dst, cluster, tsn, status, message, pcp);

    void abort_zdo_request(int handle)
        => _node.abort_zdo_request(handle);

    ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response, PCP pcp = PCP.be)
        => _node.zdo_request(dst, cluster, message, response, pcp);

    int send_zcl_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null)
        => _node.send_zcl_message(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

    int send_zcl_message(EUI64 eui, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null)
        => _node.send_zcl_message(eui, endpoint, _endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

    int send_zcl_response(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ref const ZCLHeader req, const(void)[] payload, PCP pcp = PCP.ca)
        => _node.send_zcl_response(dst, endpoint, _endpoint, profile, cluster, command, req, payload, pcp);

    void abort_zcl_request(int handle)
        => _node.abort_zcl_request(handle);

    ZigbeeResult zcl_request(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response, PCP pcp = PCP.be)
        => _node.zcl_request(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, response, pcp);

protected:

    override bool validate() const pure
    {
        if (!_node || _endpoint == 0)
            return false;
        else
            return _profile != 0;
    }

    override CompletionStatus startup()
        => _node.running ? CompletionStatus.complete : CompletionStatus.continue_;

    override void update()
    {
        // nothing to do here maybe? I think it's all event driven...
    }

private:

    ZigbeeNode _node;
    ubyte _endpoint;

    ushort _profile, _device;
    Array!ushort _in_clusters, _out_clusters;

    ZigbeeMessageHandler _message_handler;

    void incoming_packet(ref const Packet p, ZigbeeNode iface, PacketDirection dir)
    {
        // TODO: this seems inefficient!
        if (_message_handler)
            _message_handler(p.hdr!APSFrame, p.data[], p.creation_time);
    }
}


unittest
{
    auto state = ZigbeeNode.RequestState(MonoTime(), null, -1, 0x1234, 0x5678, 1, 2, ZigbeeResult.pending);

    state.progress_callback(7, MessageState.in_flight);
    assert(state.message_handle == 7);
    assert(state.expiry_result == ZigbeeResult.pending);
    assert(!state.deadline);

    MonoTime before = getTime();
    state.deadline = before - 1.seconds;
    state.progress_callback(7, MessageState.complete);
    assert(state.expiry_result == ZigbeeResult.timeout);
    assert(state.deadline >= before + zigbee_response_timeout);

    before = getTime();
    state.progress_callback(7, MessageState.failed);
    assert(state.expiry_result == ZigbeeResult.failed);
    assert(state.deadline >= before);
}
