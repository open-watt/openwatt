module protocol.zigbee.client;

import urt.array;
import urt.async;
import urt.endian;
import urt.fibre;
import urt.lifetime;
import urt.log;
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

//version = DebugZigbee;

nothrow @nogc:


alias ZigbeeMessageHandler = void delegate(ref const APSFrame header, const(void)[] message) nothrow @nogc;
alias ZDOResponseHandler = void delegate(ZDOStatus status, const(ubyte)[] message, void* user_data) nothrow @nogc;
alias ZCLResponseHandler = void delegate(ref ZCLHeader hdr, const(ubyte)[] message, void* user_data) nothrow @nogc;

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

    enum TypeName = StringLit!"zb-node";

    ZigbeeResult send_message_async(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

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
        aps.src = _node_id;
        aps.src_endpoint = src_endpoint;
        aps.dst_endpoint = dst_endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        // TODO: anything else?

        // yield until sent...
        struct AsyncData
        {
            YieldZB e;
            ZigbeeResult r;

            void progress(ZigbeeResult status, ref const APSFrame frame) pure nothrow @nogc
            {
                r = status;
                if (status == ZigbeeResult.pending)
                    return; // this is the intermediate update when the message is received by EZSP
                e.finished = true;
            }
        }

        AsyncData data;
        auto ev = InPlace!YieldZB(Default);
        data.e = ev;
        ev.timeout = Timer(2.seconds);

        ZigbeeResult r = zigbee_iface.forward_async(p, &data.progress);
        if (r != ZigbeeResult.success)
            return r;

        yield(ev);
        return ev.finished ? data.r : ZigbeeResult.timeout;
    }

    ZigbeeResult send_message_async(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        if (!running)
            return ZigbeeResult.no_network;
        if (eui.is_zigbee_broadcast)
            return send_message_async(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message);
        else if (eui.is_zigbee_multicast)
            return send_message_async(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? should we ask the network if anyone has this EUI?");
        return send_message_async(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message);
    }

    ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        if (!running)
            return ZigbeeResult.no_network;

        struct ResponseData
        {
            YieldZB e;
            ZDOResponse* r;

            void response(ZDOStatus status, const(ubyte)[] message, void*) nothrow @nogc
            {
                r.status = status;
                r.message = message;
                e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, &response);

        // TODO: we should adjust this process to start counting after we know the message was delivered
        ev.timeout = Timer(4.seconds);

        if (!send_zdo_message(dst, cluster, message, &data.response, null))
            return ZigbeeResult.failed;

        yield(ev);

        if (!ev.finished)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zdo TIMEOUT ->{0,04x} [zdo:{1,04x}] at {2}", dst, cluster, ev.timeout.elapsed);
            return ZigbeeResult.timeout;
        }
        version (DebugZigbee)
            writeInfof("Zigbee: zdo response <-{0,04x} [zdo:{1,04x}] after {2}", dst, cluster, ev.timeout.elapsed);
        return ZigbeeResult.success;
    }

    ZigbeeResult zcl_request(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response)
    {
        debug assert(isInFibre(), "send_message_async() must be called from a fibre context");

        if (!running)
            return ZigbeeResult.no_network;

        struct ResponseData
        {
            YieldZB e;
            ZCLResponse* r;

            void response(ref ZCLHeader hdr, const(ubyte)[] message, void*) nothrow @nogc
            {
                r.hdr = hdr;
                if (hdr.command == ZCLCommand.default_response)
                {
                    int x = 0;
                }
                r.message = message;
                e.finished = true;
            }
        }
        auto ev = InPlace!YieldZB(Default);
        auto data = ResponseData(ev, &response);

        // TODO: we should adjust this process to start counting after we know the message was delivered
        ev.timeout = Timer(4.seconds);

        if (!send_zcl_message(dst, dst_endpoint, src_endpoint, profile, cluster, command, flags, payload, &data.response, null))
            return ZigbeeResult.failed;

        yield(ev);

        if (!ev.finished)
        {
            version (DebugZigbee)
                writeInfof("Zigbee: zcl TIMEOUT ->{0,04x}:{1} [:{2,04x}] at {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);
            return ZigbeeResult.timeout;
        }
        version (DebugZigbee)
            writeInfof("Zigbee: zcl response <-{0,04x}:{1} [:{2,04x}] after {3}", dst, dst_endpoint, cluster, ev.timeout.elapsed);
        return ZigbeeResult.success;
    }

nothrow:
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

    bool is_router() const pure
        => false;

    bool is_coordinator() const pure
        => false;

    // API...

    override bool validate() const pure
        => _interface !is null;

    override CompletionStatus startup()
        => _interface.running ? CompletionStatus.Complete : CompletionStatus.Continue;

    override CompletionStatus shutdown()
        => CompletionStatus.Complete;

    override void update()
    {
        for (size_t i = 0; i < _zdo_requests.length; )
        {
            if (getTime() - _zdo_requests[i].request_time > 2.seconds)
            {
                version (DebugZigbee)
                    writeWarningf("Zigbee: ZDO request {0, 04x} with seq {1} timed out", _zdo_requests[i].cluster, _zdo_requests[i].seq);
                _zdo_requests.remove(i);
            }
            else
                ++i;
        }

        for (size_t i = 0; i < _zcl_requests.length; )
        {
            if (getTime() - _zcl_requests[i].request_time > 2.seconds)
            {
                version (DebugZigbee)
                    writeWarningf("Zigbee: ZCL request {0, 04x} with seq {1} timed out", _zdo_requests[i].cluster, _zdo_requests[i].seq);
                _zcl_requests.remove(i);
            }
            else
                ++i;
        }
    }

    bool send_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
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
        aps.src = _node_id;
        aps.src_endpoint = src_endpoint;
        aps.dst_endpoint = dst_endpoint;
        aps.profile_id = profile_id;
        aps.cluster_id = cluster_id;

        // TODO: anything else?

        return _interface.forward(p);
    }

    bool send_message(EUI64 eui, ubyte dst_endpoint, ubyte src_endpoint, ushort profile_id, ushort cluster, const(void)[] message)
    {
        if (!running)
            return false;
        if (eui.is_zigbee_broadcast)
            return send_message(0xFF00 | eui.b[7], dst_endpoint, src_endpoint, profile_id, cluster, message);
        else if (eui.is_zigbee_multicast)
            return send_message(cast(ushort)((eui.b[6] << 8) | eui.b[7]), dst_endpoint, src_endpoint, profile_id, cluster, message, true);

        NodeMap* n = get_module!ZigbeeProtocolModule.find_node(eui);
        assert(n, "TODO: what to do if we don't know where it's going? just drop it?");
        return send_message(n.id, dst_endpoint, src_endpoint, profile_id, cluster, message);
    }

    bool send_zdo_message(ushort dst, ushort cluster, void[] message, ZDOResponseHandler response_handler = null, void* user_data = null)
    {
        ubyte[] msg = cast(ubyte[])message;

        if (msg[0] == 0)
            msg[0] = _seq++;

        if (response_handler && (cluster & 0x8000) == 0)
            _zdo_requests.pushBack(ZDORequest(msg[0], cluster, response_handler, user_data, getTime()));

        return send_message(dst, 0, 0, 0, cluster, message);
    }

    bool send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message)
    {
        ubyte[256] buffer = void;
        buffer[0] = tsn;
        buffer[1] = status;
        buffer[2 .. 2 + message.length] = cast(ubyte[])message[];
        return send_message(dst, 0, 0, 0, cluster, buffer[0 .. 2 + message.length]);
    }

    bool send_zcl_message(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, ZCLResponseHandler response_handler = null, void* user_data = null)
    {
        ZCLHeader hdr;
        hdr.control = ZCLControlFlags.frame_type_global | (flags & (ZCLControlFlags.response | ZCLControlFlags.disable_default_response));
        if (command >= 0x100)
        {
            hdr.control |= ZCLControlFlags.manufacturer_specific;
            assert(false, "TODO: lookup manufacturer code from table");
//            hdr.manufacturer_code = table[command - 0x80];
        }
        else
            hdr.command = cast(ubyte)command;
        hdr.seq = _seq++;
        if (response_handler && (hdr.control & ZCLControlFlags.response) == 0)
            _zcl_requests.pushBack(ZCLRequest(hdr.seq, dst_endpoint, cluster, response_handler, user_data, getTime()));

        void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return false;

        assert(offset + payload.length <= buffer.length, "ZCL message too large!");
        buffer[offset .. offset + payload.length] = payload[];

        return send_message(dst, dst_endpoint, src_endpoint, profile, cluster, buffer[0 .. offset + payload.length]);
    }

    bool send_zcl_response(ushort dst, ubyte dst_endpoint, ubyte src_endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte tsn, const(void)[] payload)
    {
        ZCLHeader hdr;
        hdr.control = ZCLControlFlags.frame_type_global | ZCLControlFlags.response | ZCLControlFlags.disable_default_response;
        if (command >= 0x100)
        {
            hdr.control |= ZCLControlFlags.manufacturer_specific;
            assert(false, "TODO: lookup manufacturer code from table");
//            hdr.manufacturer_code = table[command - 0x80];
        }
        else
            hdr.command = cast(ubyte)command;
        hdr.seq = tsn;

        void[256] buffer = void;
        ptrdiff_t offset = hdr.format_zcl_header(buffer);
        if (offset < 0)
            return false;

        assert(offset + payload.length <= buffer.length, "ZCL message too large!");
        buffer[offset .. offset + payload.length] = payload[];

        return send_message(dst, dst_endpoint, src_endpoint, profile, cluster, buffer[0 .. offset + payload.length]);
    }


    bool send_zcl_message(ushort dst, ubyte endpoint, ushort profile, ZCLClusterCommand command, ubyte flags, const(void)[] payload, ZCLResponseHandler response_handler = null, void* user_data = null)
    {
        assert(false, "TODO");
    }

protected:
    struct Endpoint
    {
        ubyte id;
        ObjectRef!ZigbeeEndpoint endpoint;
    }

    struct ZDORequest
    {
        ubyte seq;
        ushort cluster;
        ZDOResponseHandler response_handler;
        void* user_data;
        MonoTime request_time;
    }

    struct ZCLRequest
    {
        ubyte seq;
        ubyte endpoint;
        ushort cluster;
        ZCLResponseHandler response_handler;
        void* user_data;
        MonoTime request_time;
    }

    static class YieldZB : AwakenEvent
    {
    nothrow @nogc:
        Timer timeout;
        bool finished;
        override bool ready() { return finished || timeout.expired(); }
    }

    BaseInterface _interface;
    Array!Endpoint _endpoints;
    Array!ZDORequest _zdo_requests;
    Array!ZCLRequest _zcl_requests;

    EUI64 _eui = EUI64.broadcast;
    ushort _node_id = 0xFFFE;
    ubyte _seq = 8;

    this(const(CollectionTypeInfo)* type_info, String name, ObjectFlags flags)
    {
        super(type_info, name.move, flags);
    }

    final inout(ZigbeeInterface) zigbee_iface() inout pure
        => cast(inout(ZigbeeInterface))_interface;

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void*)
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
                        auto handler = _zdo_requests[i].response_handler;
                        void* user_data = _zdo_requests[i].user_data;
                        _zdo_requests.remove(i);
                        handler(cast(ZDOStatus)data[1], data[2..$], user_data);
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

                        auto handler = _zcl_requests[i].response_handler;
                        void* user_data = _zcl_requests[i].user_data;
                        _zcl_requests.remove(i);
                        handler(zcl, data[hdr_len .. $], user_data);
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

    bool handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        bool response_required = (aps.flags & APSFlags.zdo_response_required) != 0;

        ubyte[] req_data = cast(ubyte[])p.data[];
        ubyte[256] buffer = void;

        switch (aps.cluster_id) with (ZDOCluster)
        {
            case ieee_addr_req:
                if (!response_required)
                    return false; // handled by the NCP
                if (req_data.length < 5)
                    return false; // malformed

                ushort addr = req_data[1..3].littleEndianToNative!ushort;
                if (_node_id != addr)
                    return false; // not for us!

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

            case nwk_addr_req,
                 match_desc_req,
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

    EUI64 pan_eui() const pure
        => _network_params.pan_id == 0xFFFF ? _pan_eui : _network_params.extended_pan_id;
    void pan_eui(EUI64 value) pure
    {
        _pan_eui = value;
    }

    ushort pan_id() const pure
        => _network_params.pan_id == 0xFFFF ? _pan_id : _network_params.pan_id;
    void pan_id(ushort value) pure
    {
        _pan_id = value;
    }

    final override bool is_router() const pure
        => true;

    // API...

    override bool validate() const pure
        => super.validate() && zigbee_iface() !is null;

    override CompletionStatus startup()
    {
        CompletionStatus s = super.startup();
        if (s != CompletionStatus.Complete)
            return s;

        // router startup?

        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
        => super.shutdown();

    void subscribe_client(EZSPClient client, bool subscribe)
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

    override bool handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
    {
        bool response_required = (aps.flags & APSFlags.zdo_response_required) != 0;

        switch (aps.cluster_id) with (ZDOCluster)
        {
            case device_annce:
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

                n.desc.mac_capabilities = caps;
                if (caps & 0x02) // fully-functional device
                    n.desc.type = (caps & 0x01) ? NodeType.coordinator : NodeType.router;
                else // reduced-functionality device
                    n.desc.type = (caps & 0x08) ? NodeType.end_device : NodeType.sleepy_end_device;

                // TODO: save the power source (0x04) and security caps (0x40) somewhere?

                // HACK: apparenty lots of Tuya devices only report this 'allocate address' flag, and that means they're a router?
                if (caps == 0x80)
                    n.desc.type = NodeType.router;

                version (DebugZigbee)
                    writeInfof("Zigbee: device announce: {0, 04x} [{1}] - type={2}", id, eui, n.desc.type);
                break;

            default:
                return super.handle_zdo_frame(aps, p);
        }
        return false;
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
    EUI64 _pan_eui = EUI64.broadcast;
    ushort _pan_id = 0xFFFF;

    final inout(EZSPClient) get_ezsp() inout pure
    {
        if (auto i = zigbee_iface())
            return i.ezsp_client;
        return null;
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

    enum TypeName = StringLit!"zb-endpoint";

    ZigbeeResult send_message_async(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
        => _node.send_message_async(dst, endpoint, _endpoint, profile_id, cluster_id, message, group);

    ZigbeeResult send_message_async(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster, const(void)[] message)
        => _node.send_message_async(eui, endpoint, _endpoint, profile_id, cluster, message);

    ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response)
        => _node.zdo_request(dst, cluster, message, response);

    ZigbeeResult zcl_request(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response)
        => _node.zcl_request(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, response);

nothrow:

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!ZigbeeEndpoint, name.move, flags);
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
        return null;
    }

    final ushort profile_id() inout
        => _profile;

    final ushort device() inout pure
        => _device;
    final void device(ushort value)
    {
        _device = value;
    }

    final const(ushort)[] in_clusters() inout pure
        => _in_clusters[];
    final void in_clusters(const(ushort)[] value)
    {
        _in_clusters = value;
    }

    final const(ushort)[] out_clusters() inout pure
        => _out_clusters[];
    final void out_clusters(const(ushort)[] value)
    {
        _out_clusters = value;
    }


    // API...

    override bool validate() const pure
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

    bool send_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message, bool group = false)
        => _node.send_message(dst, endpoint, _endpoint, profile, cluster, message, group);

    bool send_message(EUI64 eui, ubyte endpoint, ushort profile, ushort cluster, const(void)[] message)
        => _node.send_message(eui, endpoint, _endpoint, profile, cluster, message);

    bool send_zdo_message(ushort dst, ushort cluster, void[] message, ZDOResponseHandler response_handler = null, void* user_data = null)
        => _node.send_zdo_message(dst, cluster, message, response_handler, user_data);

    bool send_zdo_response(ushort dst, ushort cluster, ubyte tsn, ZDOStatus status, void[] message)
        => _node.send_zdo_response(dst, cluster, tsn, status, message);

    bool send_zcl_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, ZCLResponseHandler response_handler = null, void* user_data = null)
        => _node.send_zcl_message(dst, endpoint, _endpoint, profile, cluster, command, flags, payload, response_handler, user_data);

    bool send_zcl_response(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte tsn, const(void)[] payload)
        => _node.send_zcl_response(dst, endpoint, _endpoint, profile, cluster, command, tsn, payload);

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
            _message_handler(p.hdr!APSFrame, p.data[]);
    }
}
