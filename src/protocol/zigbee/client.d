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
import router.iface.zigbee;

version = DebugZigbee;

nothrow @nogc:


alias ZigbeeMessageHandler = void delegate(ref const APSFrame header, const(void)[] message, SysTime timestamp) nothrow @nogc;
alias ZDOResponseHandler = void delegate(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void* user_data) nothrow @nogc;
alias ZCLResponseHandler = void delegate(ZigbeeResult result, const ZCLHeader* hdr, const(ubyte)[] message, void* user_data) nothrow @nogc;

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


class ZigbeeNode : BaseObject
{
    __gshared Property[5] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("is-router", is_router)(),
                                         Property.create!("is-coordinator", is_coordinator)(),
                                         Property.create!("eui", eui)(),
                                         Property.create!("node-id", node_id)() ];
@nogc:

    enum type_name = "zb-node";

    this(String name, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        this(collection_type_info!ZigbeeNode, name.move, flags);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure nothrow // TODO: should return zigbee interface?
        => _interface;
    StringResult iface(BaseInterface value) nothrow
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
        return StringResult.success;
    }

    EUI64 eui() const pure nothrow
        => _eui;

    ushort node_id() const pure nothrow
        => _node_id;

    bool is_router() const pure nothrow
        => false;

    bool is_coordinator() const pure nothrow
        => false;

    // API...

    final int send_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false) nothrow
        => send_message(dst, dst_endpoint, src_endpoint, profile_id, cluster_id, message, null, pcp, group);

    final int send_message(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be) nothrow
    {
        if (!running)
            return ZigbeeResult.no_network;
        if (eui.is_zigbee_broadcast)
            return send_message(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
        else if (eui.is_zigbee_multicast)
            return send_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, pcp, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? just drop it?");
        return send_message(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
    }

    final int send_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, MessageCallback progress_callback, PCP pcp = PCP.be, bool group = false) nothrow
    {
        if (!running)
            return ZigbeeResult.no_network;

        assert(message.length <= 256, "TODO: what actually is the maximum zigbee payload?");

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

        return _interface.forward(p, progress_callback);
    }

    final ZigbeeResult send_message_async(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

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

        scope (failure)
            _interface.abort(tag);

        yield(ev);

        if (!ev.finished)
        {
            _interface.abort(tag);
            return ZigbeeResult.timeout;
        }
        return data.r;
    }

    final ZigbeeResult send_message_async(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        if (!running)
            return ZigbeeResult.no_network;
        if (eui.is_zigbee_broadcast)
            return send_message_async(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
        else if (eui.is_zigbee_multicast)
            return send_message_async(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, pcp, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? should we ask the network if anyone has this EUI?");
        return send_message_async(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message, pcp);
    }

    final int send_zdo_message(ushort dst, ushort cluster, void[] message, PCP pcp = PCP.be, ZDOResponseHandler response_handler = null, void* user_data = null) nothrow
    {
        ubyte[] msg = cast(ubyte[])message;

        if (msg[0] == 0)
            msg[0] = _seq++;

        ZDORequest* req = null;
        MessageCallback progress = null;
        if (response_handler && (cluster & 0x8000) == 0)
        {
            req = _zdo_request_pool.alloc();
            *req = ZDORequest(msg[0], cluster, -1, getTime(), response_handler, user_data, null);
            _zdo_requests.pushBack(req);
            progress = &req.progress_callback;
        }

        int tag = send_message(dst, 0, 0, 0, cluster, message, progress, pcp);
        if (req)
        {
            if (tag < 0)
            {
                _zdo_requests.popBack();
                _zdo_request_pool.free(req);
            }
            else
            {
                req.tag = tag;
                req.iface = _interface;
            }
        }
        return tag;
    }

    final int send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message, PCP pcp = PCP.be) nothrow
    {
        ubyte[256] buffer = void;
        buffer[0] = tsn;
        buffer[1] = status;
        buffer[2 .. 2 + message.length] = cast(ubyte[])message[];
        return send_message(dst, 0, 0, 0, cluster, buffer[0 .. 2 + message.length], pcp);
    }

    final void abort_zdo_request(int tag, ZigbeeResult reason = ZigbeeResult.aborted) nothrow
    {
        for (size_t i = 0; i < _zdo_requests.length; ++i)
        {
            if (_zdo_requests[i].tag == tag)
            {
                ZDORequest* req = _zdo_requests[i];
                _aborted_zdo[_aborted_zdo_pos++ & 7] = AbortedZDOMsg(req.seq, req.cluster);
                _zdo_requests.remove(i);
                if (req.response_handler)
                    req.response_handler(reason, ZDOStatus.success, null, req.user_data);
                req.response_handler = null;
                if (req.iface)
                    req.iface.abort(tag);
                _zdo_request_pool.free(req);
                return;
            }
        }
    }

    final ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response, PCP pcp = PCP.be)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        struct ResponseData
        {
            YieldZB e;
            ZigbeeResult result;
            ZDOResponse* r;
            ushort dst, cluster;

            void response(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void*) nothrow @nogc
            {
                this.result = result;
                if (result == ZigbeeResult.success)
                {
                    r.status = status;
                    r.message = message;
                }
                if (result == ZigbeeResult.pending)
                {
                    version (DebugZigbee)
                        writeInfof("Zigbee: zdo TRANSMIT ->{0,04x} [zdo:{1,04x}] at {2}", dst, cluster, e.timeout.elapsed);
                    e.timeout.reset();
                }
                else
                    e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, ZigbeeResult.success, &response, dst, cluster);

        // TODO: we should adjust this process to start counting after we know the message was delivered
        ev.timeout = Timer(10.seconds);

        int tag = send_zdo_message(dst, cluster, message, pcp, &data.response, null);
        if (tag < 0)
            return ZigbeeResult.failed;

        scope (exit)
            abort_zdo_request(tag);

        yield(ev);

        if (!ev.finished)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zdo TIMEOUT ->{0,04x} [zdo:{1,04x}] at {2}", dst, cluster, ev.timeout.elapsed);
            return ZigbeeResult.timeout;
        }
        else if (data.result != ZigbeeResult.success)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zdo FAILED <-{0,04x} [zdo:{1,04x}] result {2}", dst, cluster, data.result);
        }
        else version (DebugZigbee)
            writeInfof("Zigbee: zdo response <-{0,04x} [zdo:{1,04x}] after {2}", dst, cluster, ev.timeout.elapsed);
        return data.result;
    }

    final int send_zcl_message(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null) nothrow
    {
        if (eui.is_zigbee_broadcast)
            return send_zcl_message(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);
        else if (eui.is_zigbee_multicast)
            return send_zcl_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? should we ask the network if anyone has this EUI?");
        return send_zcl_message(n.id, dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);
    }

    final int send_zcl_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null) nothrow
    {
        ZCLHeader hdr;
        hdr.control = flags;
        if (command >= 0x8000)
        {
            hdr.control |= ZCLControlFlags.manufacturer_specific;
            assert(false, "TODO: lookup manufacturer code from table");
//            hdr.manufacturer_code = table[command - 0x8000];
        }
        else
            hdr.command = command & 0xFF;
        hdr.cluster_local = (command & 0x4000) != 0;
        hdr.seq = _seq++;

        ZCLRequest* req = null;
        MessageCallback progress = null;
        if (response_handler && (hdr.control & ZCLControlFlags.response) == 0)
        {
            req = _zcl_request_pool.alloc();
            *req = ZCLRequest(hdr.seq, dst_endpoint, cluster, -1, getTime(), response_handler, user_data, null);
            _zcl_requests.pushBack(req);
            progress = &req.progress_callback;
        }

        void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return ZigbeeResult.insufficient_buffer;

        assert(offset + payload.length <= buffer.length, "ZCL message too large!");
        buffer[offset .. offset + payload.length] = payload[];

        int tag = send_message(dst, dst_endpoint, src_endpoint, profile, cluster, buffer[0 .. offset + payload.length], progress, pcp);
        if (req)
        {
            if (tag < 0)
            {
                _zcl_requests.popBack();
                _zcl_request_pool.free(req);
            }
            else
            {
                req.tag = tag;
                req.iface = _interface;
            }
        }
        return tag;
    }

    final int send_zcl_response(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ref const ZCLHeader req, const(void)[] payload, PCP pcp = PCP.be) nothrow
    {
        ZCLHeader hdr;
        hdr.control = (req.control & ZCLControlFlags.response) | ZCLControlFlags.disable_default_response;
        hdr.control ^= ZCLControlFlags.response;
        if (command >= 0x8000)
        {
            hdr.control |= ZCLControlFlags.manufacturer_specific;
            assert(false, "TODO: lookup manufacturer code from table");
//            hdr.manufacturer_code = table[command - 0x8000];
        }
        else
            hdr.command = cast(ubyte)command;
        hdr.cluster_local = req.cluster_local || (command & 0x4000) != 0;
        hdr.seq = req.seq;

        void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return ZigbeeResult.insufficient_buffer;

        assert(offset + payload.length <= buffer.length, "ZCL message too large!");
        buffer[offset .. offset + payload.length] = payload[];

        return send_message(dst, dst_endpoint, src_endpoint, profile, cluster, buffer[0 .. offset + payload.length], pcp);
    }

    final void abort_zcl_request(int tag, ZigbeeResult reason = ZigbeeResult.aborted) nothrow
    {
        for (size_t i = 0; i < _zcl_requests.length; ++i)
        {
            if (_zcl_requests[i].tag == tag)
            {
                ZCLRequest* req = _zcl_requests[i];
                _aborted_zcl[_aborted_zcl_pos++ & 7] = AbortedZCLMsg(req.seq, req.endpoint, req.cluster);
                _zcl_requests.remove(i);
                if (req.response_handler)
                    req.response_handler(reason, null, null, req.user_data);
                req.response_handler = null;
                if (req.iface)
                    req.iface.abort(tag);
                _zcl_request_pool.free(req);
                return;
            }
        }
    }

    final ZigbeeResult zcl_request(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response, PCP pcp = PCP.be)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        struct ResponseData
        {
            YieldZB e;
            ZigbeeResult result;
            ZCLResponse* r;
            ushort dst, cluster;
            ubyte dst_endpoint;

            void response(ZigbeeResult status, const ZCLHeader* hdr, const(ubyte)[] message, void*) nothrow @nogc
            {
                this.result = status;
                if (status == ZigbeeResult.success)
                {
                    r.hdr = *hdr;
                    r.message = message;
                }
                if (result == ZigbeeResult.pending)
                {
                    version (DebugZigbee)
                        writeInfof("Zigbee: zcl TRANSMIT ->{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, e.timeout.elapsed);
                    e.timeout.reset();
                }
                else
                    e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, ZigbeeResult.success, &response, dst, cluster, dst_endpoint);

        // TODO: we should adjust this process to start counting after we know the message was delivered
        ev.timeout = Timer(10.seconds);

        int tag = send_zcl_message(dst, dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, pcp, &data.response, null);
        if (tag < 0)
            return ZigbeeResult.failed;

        scope (exit)
            abort_zcl_request(tag);

        yield(ev);

        if (!ev.finished)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zcl TIMEOUT ->{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);
            return ZigbeeResult.timeout;
        }
        else if (data.result != ZigbeeResult.success)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zcl FAILED ->{0,04x}:{1} [:{2,04x}] result {3}", dst, dst_endpoint, cluster, data.result);
            return data.result;
        }

        version (DebugZigbee)
            writeInfof("Zigbee: zcl response <-{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);

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

    final bool is_network_up() const pure nothrow
        => zigbee_iface()._network_status == EmberStatus.NETWORK_UP;

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
    ubyte _seq = 8;

    this(const(CollectionTypeInfo)* type_info, String name, ObjectFlags flags) nothrow
    {
        super(type_info, name.move, flags);
    }

    final inout(ZigbeeInterface) zigbee_iface() inout pure nothrow
        => cast(inout(ZigbeeInterface))_interface;

    override bool validate() const pure nothrow
        => _interface !is null;

    override CompletionStatus startup() nothrow
        => _interface.running ? CompletionStatus.complete : CompletionStatus.continue_;

    override CompletionStatus shutdown() nothrow
    {
        // flush the message queues
        while (!_zdo_requests.empty)
            abort_zdo_request(_zdo_requests.back.tag);
        while (!_zcl_requests.empty)
            abort_zcl_request(_zcl_requests.back.tag);

        return CompletionStatus.complete;
    }

    override void update() nothrow
    {
        // TODO: the timeouts should probably work in 2 phases;
        //       1) timeout waiting for message to be sent
        //       2) timeout waiting for response after message sent

        for (size_t i = 0; i < _zdo_requests.length; )
        {
            ZDORequest* req = _zdo_requests[i];
            if (getTime() - req.request_time > 2.seconds)
            {
                version (DebugZigbee)
                    writeWarningf("Zigbee: ZDO request {0, 04x} with seq {1} timed out", req.cluster, req.seq);

                abort_zdo_request(req.tag, ZigbeeResult.timeout);
            }
            else
                ++i;
        }

        for (size_t i = 0; i < _zcl_requests.length; )
        {
            ZCLRequest* req = _zcl_requests[i];
            if (getTime() - req.request_time > 2.seconds)
            {
                version (DebugZigbee)
                    writeWarningf("Zigbee: ZCL request {0, 04x} with seq {1} timed out", req.cluster, req.seq);

                abort_zcl_request(req.tag, ZigbeeResult.timeout);
            }
            else
                ++i;
        }
    }

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void*) nothrow
    {
        // TODO: we should enhance the PACKET FILTER to do this work!
        ref aps = p.hdr!APSFrame;

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
                    if (_zdo_requests[i].seq == seq && _zdo_requests[i].cluster == (aps.cluster_id & 0x7FFF))
                    {
                        ZDORequest* req = _zdo_requests[i];
                        _zdo_requests.remove(i);
                        if (req.response_handler)
                            req.response_handler(ZigbeeResult.success, cast(ZDOStatus)data[1], data[2..$], req.user_data);
                        _zdo_request_pool.free(req);
                        return;
                    }
                }
                foreach (ref ak; _aborted_zdo)
                {
                    if (ak.seq == seq && ak.cluster == (aps.cluster_id & 0x7FFF))
                    {
                        writeInfof("Zigbee: late ZDO response {0, 04x} from {1, 04x} seq {2} (aborted in-flight)", aps.cluster_id, aps.src, seq);
                        return;
                    }
                }

                version (DebugZigbee)
                    writeWarningf("Zigbee: received unexpected ZDO response {0, 04x} from {1, 04x} with seq {2}", aps.cluster_id, aps.src, seq);
                return;
            }

            bool response_sent = handle_zdo_frame(aps, p);

            if ((aps.flags & APSFlags.zdo_response_required) && !response_sent)
                writeWarningf("Zigbee: ZDO request {0, 04x} from {1, 04x} requires a response but none was sent!", aps.cluster_id, aps.src);
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
                    if (_zcl_requests[i].seq == seq && _zcl_requests[i].endpoint == aps.src_endpoint && _zcl_requests[i].cluster == aps.cluster_id)
                    {
                        ZCLHeader zcl;
                        ptrdiff_t hdr_len = decode_zcl_header(data, zcl);
                        if (hdr_len < 0)
                            return; // malformed

                        ZCLRequest* req = _zcl_requests[i];
                        _zcl_requests.remove(i);
                        if (req.response_handler)
                            req.response_handler(ZigbeeResult.success, &zcl, data[hdr_len .. $], req.user_data);
                        _zcl_request_pool.free(req);
                        return;
                    }
                }

                foreach (ref ak; _aborted_zcl)
                {
                    if (ak.seq == seq && ak.endpoint == aps.src_endpoint && ak.cluster == aps.cluster_id)
                    {
                        writeInfof("Zigbee: late ZCL response from {0, 04x}:{1} [:{2, 04x}] seq {3} (aborted in-flight)", aps.src, aps.src_endpoint, aps.cluster_id, seq);
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

    bool handle_zdo_frame(ref const APSFrame aps, ref const Packet p) nothrow
    {
        bool response_required = (aps.flags & APSFlags.zdo_response_required) != 0;

        ubyte[] req_data = cast(ubyte[])p.data[];
        ubyte[256] buffer = void;

        switch (aps.cluster_id) with (ZDOCluster)
        {
            case nwk_addr_req:
                if (!response_required)
                    return false; // handled by the NCP
                if (req_data.length < 11)
                    return false; // malformed

                auto addr = EUI64(req_data[1..9]);
                if (addr != _eui)
                    return true; // asking about some other EUI... (not for me?)

                assert(req_data[9] == 0, "TODO: only supporting single address requests for now");

                buffer[0] = req_data[0]; // sequence
                buffer[1] = ZDOStatus.success;
                buffer[2..10] = _eui.b[]; // is this meant to be little-endian?
                buffer[10..12] = _node_id.nativeToLittleEndian!ushort;
                send_zdo_message(aps.src, aps.cluster_id | 0x8000, buffer[0..12]);
                return true;

            case ieee_addr_req:
                if (!response_required)
                    return false; // handled by the NCP
                if (req_data.length < 5)
                    return false; // malformed

                ushort addr = req_data[1..3].littleEndianToNative!ushort;
                if (_node_id != addr)
                    return true; // not for us!

                assert(req_data[3] == 0, "TODO: only supporting single address requests for now");

                buffer[0] = req_data[0]; // sequence
                buffer[1] = ZDOStatus.success;
                buffer[2..10] = _eui.b[]; // is this meant to be little-endian?
                buffer[10..12] = _node_id.nativeToLittleEndian!ushort;
                send_zdo_message(aps.src, aps.cluster_id | 0x8000, buffer[0..12]);
                return true;

            case node_desc_req:
                if (!response_required)
                    return false; // handled by the NCP
                assert(false, "TODO");
//                if (req_data.length < 5)
//                    return false; // malformed
                return false;

            case power_desc_req:
                if (!response_required)
                    return false; // handled by the NCP
                assert(false, "TODO");
//                if (req_data.length < 5)
//                    return false; // malformed
                return false;

            case simple_desc_req:
                if (!response_required)
                    return false; // handled by the NCP
                assert(false, "TODO");
//                if (req_data.length < 5)
//                    return false; // malformed
                return false;

            case active_ep_req:
                if (!response_required)
                    return false; // handled by the NCP
                assert(false, "TODO");
//                if (req_data.length < 5)
//                    return false; // malformed
                return false;

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
                if (!response_required)
                    return false; // handled by the NCP
                assert(false, "TODO");

            case device_annce:
                // these messages are only of interest to routers/coordinators (?)
                return false;

            default:
                // TODO: unknown (or deprecated) ZDO request
                return false;
        }
    }


private:

    struct ZDORequest
    {
        ubyte seq;
        ushort cluster;
        int tag;
        MonoTime request_time;
        ZDOResponseHandler response_handler;
        void* user_data;
        BaseInterface iface;

    private:
        void progress_callback(int, MessageState state) nothrow @nogc
        {
            if (state <= MessageState.in_flight)
                return;
            iface = null;
            if (state != MessageState.complete)
            {
                if (response_handler)
                {
                    ZigbeeResult r = state == MessageState.timeout ? ZigbeeResult.timeout :
                                     state == MessageState.aborted ? ZigbeeResult.aborted :
                                     ZigbeeResult.failed;
                    response_handler(r, ZDOStatus.success, null, user_data);
                }
                response_handler = null;
            }
        }
    }

    struct ZCLRequest
    {
        ubyte seq;
        ubyte endpoint;
        ushort cluster;
        int tag;
        MonoTime request_time;
        ZCLResponseHandler response_handler;
        void* user_data;
        BaseInterface iface;

    private:
        void progress_callback(int, MessageState state) nothrow @nogc
        {
            if (state <= MessageState.in_flight)
                return;
            iface = null;
            if (state != MessageState.complete)
            {
                if (response_handler)
                {
                    ZigbeeResult r = state == MessageState.timeout ? ZigbeeResult.timeout :
                                     state == MessageState.aborted ? ZigbeeResult.aborted :
                                     ZigbeeResult.failed;
                    response_handler(r, null, null, user_data);
                }
                response_handler = null;
            }
        }
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

    // ring-buffer of aborted requests to detect late responses
    struct AbortedZDOMsg { ubyte seq; ushort cluster; }
    struct AbortedZCLMsg { ubyte seq; ubyte endpoint; ushort cluster; }
    AbortedZDOMsg[8] _aborted_zdo;
    AbortedZCLMsg[8] _aborted_zcl;
    ubyte _aborted_zdo_pos;
    ubyte _aborted_zcl_pos;

    size_t find_endpoint(ZigbeeEndpoint endpoint) nothrow
    {
        foreach (i; 0 .. _endpoints.length)
            if (_endpoints[i].endpoint.get() is endpoint)
                return i;
        return _endpoints.length;
    }

    void add_endpoint(ZigbeeEndpoint endpoint) nothrow
    {
        if (find_endpoint(endpoint) < _endpoints.length)
            return; // TODO: error or assert or something?!
        ref Endpoint ep = _endpoints.pushBack();
        ep.id = endpoint.endpoint;
        ep.endpoint = endpoint;
    }

    void remove_endpoint(ZigbeeEndpoint endpoint) nothrow
    {
        size_t i = find_endpoint(endpoint);
        if (i < _endpoints.length)
            _endpoints.remove(i);
    }
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
@nogc:

    enum type_name = "zb-endpoint";

    this(String name, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!ZigbeeEndpoint, name.move, flags);
    }

    ~this() nothrow
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
    final void in_clusters(Array!ushort value) nothrow
    {
        _in_clusters = value.move;
    }

    final const(ushort)[] out_clusters() inout pure nothrow
        => _out_clusters[];
    final void out_clusters(const(ushort)[] value) nothrow
    {
        _out_clusters = value;
    }
    final void out_clusters(Array!ushort value) nothrow
    {
        _out_clusters = value.move;
    }


    // API...

    void set_message_handler(ZigbeeMessageHandler handler) nothrow
    {
        _message_handler = handler;
    }

    int send_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message, PCP pcp = PCP.be, bool group = false) nothrow
        => _node.send_message(dst, endpoint, _endpoint, profile, cluster, message, pcp, group);

    int send_message(EUI64 eui, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message, PCP pcp = PCP.be) nothrow
        => _node.send_message(eui, endpoint, _endpoint, profile, cluster, message, pcp);

    ZigbeeResult send_message_async(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, PCP pcp = PCP.be, bool group = false)
        => _node.send_message_async(dst, endpoint, _endpoint, profile_id, cluster_id, message, pcp, group);

    ZigbeeResult send_message_async(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster, const(void)[] message, PCP pcp = PCP.be)
        => _node.send_message_async(eui, endpoint, _endpoint, profile_id, cluster, message, pcp);

    int send_zdo_message(ushort dst, ushort cluster, void[] message, PCP pcp = PCP.be, ZDOResponseHandler response_handler = null, void* user_data = null) nothrow
        => _node.send_zdo_message(dst, cluster, message, pcp, response_handler, user_data);

    int send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message, PCP pcp = PCP.be) nothrow
        => _node.send_zdo_response(dst, cluster, tsn, status, message, pcp);

    void abort_zdo_request(int tag) nothrow
        => _node.abort_zdo_request(tag);

    ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response, PCP pcp = PCP.be)
        => _node.zdo_request(dst, cluster, message, response, pcp);

    int send_zcl_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null) nothrow
        => _node.send_zcl_message(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

    int send_zcl_message(EUI64 eui, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, PCP pcp = PCP.be, ZCLResponseHandler response_handler = null, void* user_data = null) nothrow
        => _node.send_zcl_message(eui, endpoint, _endpoint, profile, cluster, command, flags, payload, pcp, response_handler, user_data);

    int send_zcl_response(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ref const ZCLHeader req, const(void)[] payload, PCP pcp = PCP.be) nothrow
        => _node.send_zcl_response(dst, endpoint, _endpoint, profile, cluster, command, req, payload, pcp);

    void abort_zcl_request(int tag) nothrow
        => _node.abort_zcl_request(tag);

    ZigbeeResult zcl_request(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response, PCP pcp = PCP.be)
        => _node.zcl_request(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, response, pcp);

protected:

    override bool validate() const pure nothrow
    {
        if (!_node || _endpoint == 0)
            return false;
        else
            return _profile != 0;
    }

    override CompletionStatus startup() nothrow
        => _node.running ? CompletionStatus.complete : CompletionStatus.continue_;

    override void update() nothrow
    {
        // nothing to do here maybe? I think it's all event driven...
    }

private:

    ZigbeeNode _node;
    ubyte _endpoint;

    ushort _profile, _device;
    Array!ushort _in_clusters, _out_clusters;

    ZigbeeMessageHandler _message_handler;

    void incoming_packet(ref const Packet p, ZigbeeNode iface, PacketDirection dir) nothrow
    {
        // TODO: this seems inefficient!
        if (_message_handler)
            _message_handler(p.hdr!APSFrame, p.data[], p.creation_time);
    }
}
