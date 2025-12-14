module protocol.zigbee.controller;

import urt.array;
import urt.async;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.mem.temp;
import urt.result;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.profile;

import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.client;
import protocol.zigbee.zcl;
import protocol.zigbee.zdo;

import router.iface.mac;

version = DebugZigbeeController;

@nogc:

enum MaxFibers = 5;


class ZigbeeController : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("endpoint", endpoint)(),
                                         Property.create!("auto-create", auto_create)() ];
@nogc:

    ZigbeeResult send_message_async(ushort dst, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
    {
        if (!running || !_endpoint)
            return ZigbeeResult.no_network;
        return _endpoint.send_message_async(dst, endpoint, profile_id, cluster_id, message, group);
    }

    ZigbeeResult send_message_async(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster, const(void)[] message)
    {
        if (!running || !_endpoint)
            return ZigbeeResult.no_network;
        return _endpoint.send_message_async(eui, endpoint, profile_id, cluster, message);
    }

    ZigbeeResult zdo_request(ushort dst, ushort cluster, void[] message, out ZDOResponse response)
    {
        if (!running || !_endpoint)
            return ZigbeeResult.no_network;
        return _endpoint.zdo_request(dst, cluster, message, response);
    }

    ZigbeeResult zcl_request(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, out ZCLResponse response)
    {
        if (!running || !_endpoint)
            return ZigbeeResult.no_network;
        return _endpoint.zcl_request(dst, endpoint, profile, cluster, command, flags, payload, response);
    }

    ZigbeeResult ieee_request(ushort dst, out EUI64 eui)
    {
        ubyte[5] addr_req_msg = void;
        addr_req_msg[0] = 0;
        addr_req_msg[1..3] = dst.nativeToLittleEndian;
        addr_req_msg[3] = 0; // request type: single device response
        addr_req_msg[4] = 0; // start index

        ZDOResponse response;
        ZigbeeResult r = zdo_request(dst, ZDOCluster.ieee_addr_req, addr_req_msg[], response);
        if (r == ZigbeeResult.success && response.status == ZDOStatus.success && response.message.length >= 8)
            eui.b[] = response.message[0..8];
        return r;
    }

nothrow:

    enum TypeName = StringLit!"zigbee-controller";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!ZigbeeController, name.move, flags);

        _promises.reserve(MaxFibers);
    }

    ~this()
    {
        if (_endpoint)
        {
            _endpoint.set_message_handler(null);
            _endpoint = null;
        }
    }

    // Properties...

    final inout(ZigbeeEndpoint) endpoint() inout pure
        => _endpoint;
    final StringResult endpoint(ZigbeeEndpoint value)
    {
        if (!value)
            return StringResult("endpoint cannot be null");
        if (_endpoint)
        {
            if (_endpoint is value)
                return StringResult.success;
            _endpoint.set_message_handler(null);
        }
        _endpoint = value;
        if (_endpoint)
            _endpoint.set_message_handler(&message_handler);
        return StringResult.success;
    }

    final bool auto_create() const pure
        => _auto_create_devices;
    final void auto_create(bool value) nothrow
    {
        _auto_create_devices = value;
    }

    // API...

    bool send_message(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_message(eui, endpoint, profile_id, cluster_id, message);
    }

    bool send_message(ushort id, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_message(id, endpoint, profile_id, cluster_id, message, false);
    }

    bool send_group_message(ushort id, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_message(id, endpoint, profile_id, cluster_id, message, true);
    }

    override bool validate() const
        => _endpoint !is null;

    override CompletionStatus validating()
    {
        _endpoint.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_zigbee_profile)
            _zigbee_profile = load_profile("conf/zigbee_profiles/zigbee.conf", defaultAllocator());

        return _endpoint.running ? CompletionStatus.Complete : CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        // abort any outstanding interviews
        // TODO: there is a CRITICAL problem where in-flight requests have callbacks into fibre-local yield objects!
        //       maybe we need an API to abort requests...?
        while (!_promises.empty)
        {
            Promise!bool* p = _promises.popBack();
            if (!p.finished)
                p.abort();
            freePromise(p);
        }

        if (_zigbee_profile)
        {
            defaultAllocator().freeT(_zigbee_profile);
            _zigbee_profile = null;
        }

        return CompletionStatus.Complete;
    }

    override void update() nothrow
    {
        // we need to populate our database of devices with detail...

        ZigbeeProtocolModule zb = get_module!ZigbeeProtocolModule();

        for (size_t i = 0; i < _promises.length; )
        {
            if (_promises[i].finished)
            {
                if (!_promises[i].result)
                {
                    // TODO: anything on failure? retry? reason why?
                }
                freePromise(_promises[i]);
                _promises.remove(i);
            }
            else
                ++i;
        }

        // update all the nodes...
        foreach (ref NodeMap nm; zb.nodes_by_eui.values)
        {
            if (nm.initialised == 0 && _promises.length < MaxFibers)
            {
                nm.initialised = 1;
                _promises.pushBack(async(&do_node_interview, this, &nm));
            }
        }

        // TODO: we should periodically read the software/build id's, and if they change (firmware update) we should re-interview the device to rebuild it's detail map...
    }

private:

    bool _auto_create_devices;

    ObjectRef!ZigbeeEndpoint _endpoint;
    Array!(Promise!bool*) _promises;

    Profile* _zigbee_profile;

    bool send_zdo_message(ushort dst, ushort cluster_id, void[] message, ZDOResponseHandler response_handler = null, void* user_data = null)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_zdo_message(dst, cluster_id, message, response_handler, user_data);
    }

    bool send_zcl_message(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ZCLCommand command, ubyte flags, const(void)[] payload, ZCLResponseHandler response_handler = null, void* user_data = null)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_zcl_message(dst, endpoint, profile, cluster, command, flags, payload, response_handler, user_data);
    }

    bool send_default_response(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ubyte tsn, ubyte cmd, ubyte status)
    {
        const ubyte[2] msg = [ cmd, status ];
        return _endpoint.send_zcl_response(dst, endpoint, profile, cluster, ZCLCommand.default_response, tsn, msg[]);
    }

    bool send_ieee_request(ushort dst, ZDOResponseHandler response_hander = null, void* user_data = null)
    {
        ubyte[5] addr_req_msg = void;
        addr_req_msg[0] = 0;
        addr_req_msg[1..3] = dst.nativeToLittleEndian;
        addr_req_msg[3] = 0; // request type: single device response
        addr_req_msg[4] = 0; // start index
        return send_zdo_message(dst, ZDOCluster.ieee_addr_req, addr_req_msg[], response_hander, user_data);
    }

    void message_handler(ref const APSFrame aps, const(void)[] message)
    {
        if (message.length < ZCLHeader.sizeof)
            return;

        ZCLHeader zcl;
        ptrdiff_t bytes = message.decode_zcl_header(zcl);
        if (bytes < 0)
            return; // TODO: should we send malformed_command default response?
        const(ubyte)[] payload = cast(ubyte[])message[bytes..$]; // get the payload...

        NodeMap* nm = get_module!ZigbeeProtocolModule.find_node(aps.pan_id, aps.src);
        if (!nm)
        {
            version (DebugZigbeeController)
                writeWarningf("ZigbeeController: Received ZCL message from unknown device {0,04x}", aps.src);
        }

        ZCLStatus status = ZCLStatus.success;

        switch (zcl.command) with (ZCLCommand)
        {
            case read_attributes, write_attributes, configure_reporting, read_reporting_configuration:
                // DOES CONTROLLER HAVE ANY RECORDS?
                status = ZCLStatus.unsup_cluster_command;
                break;

            case write_attributes_no_response:
                // DOES CONTROLLER HAVE ANY RECORDS TO WRITE?
                return; // no response expected...

            case discover_attributes:
                if (payload.length < 3)
                {
                    status = ZCLStatus.malformed_command;
                    break;
                }

                ushort start_attr = payload[0..2].littleEndianToNative!ushort;
                ubyte max_attrs = payload[2];

                // DOES CONTROLLER HAVE ANY RECORDS TO REPORT?

                ubyte[1] response = [ 1 ]; // complete message, nothing to report...

                _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, ZCLCommand.discover_attributes_response, zcl.seq, response[]);
                return;

            case discover_attributes_extended:
                if (payload.length < 3)
                {
                    status = ZCLStatus.malformed_command;
                    break;
                }

                ushort start_attr = payload[0..2].littleEndianToNative!ushort;
                ubyte max_attrs = payload[2];

                // DOES CONTROLLER HAVE ANY RECORDS TO REPORT?

                ubyte[1] response = [ 1 ]; // complete message, nothing to report...

                _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, ZCLCommand.discover_attributes_extended_response, zcl.seq, response[]);
                return;

            case read_attributes_response:
                // my request for attributes returned...
                assert(false, "TODO");
                return;

            case write_attributes_response:
                // my request to write attributes returned...
                assert(false, "TODO");
                return;

            case discover_attributes_response:
                // my request to discover attributes returned...
                assert(false, "TODO");
                return;

            case discover_attributes_extended_response:
                // my request to discover attributes returned...
                assert(false, "TODO");
                return;

            case configure_reporting_response:
                // my request to configure reporting returned...
                assert(false, "TODO");
                return;

            case read_reporting_configuration_response:
                // my request to read reporting configuration returned...
                assert(false, "TODO");
                return;

            case report_attributes:
                if (!nm)
                    break;

                ref NodeMap.Endpoint ep = nm.get_endpoint(aps.src_endpoint);
                if (ep.profile_id == 0)
                    ep.profile_id = aps.profile_id;
                ref NodeMap.Cluster cluster = ep.get_cluster(aps.cluster_id);
                SysTime now = getSysTime();

                while (payload.length > 0)
                {
                    ushort attr_id = payload[0..2].littleEndianToNative!ushort;
                    ref NodeMap.Attribute attr = cluster.get_attribute(attr_id);

                    attr.data_type = cast(ZCLDataType)payload[2];
                    ptrdiff_t taken = get_zcl_value(attr.data_type, payload[3 .. $], attr.value);
                    if (taken < 0)
                    {
                        attr.data_type = ZCLDataType.no_data;
                        attr.value = Variant();
                        status = ZCLStatus.malformed_command;
                        break;
                    }
                    attr.last_updated = now; // TODO: this timestamp should come from the packet! but we lost that here...

                    payload = payload[3 + taken .. $];

                    version (DebugZigbeeController)
                        writeInfof("ZigbeeController: {0,04x}:{1,02x} report {2}:{3,04x}:{4,04x} = {5}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id, attr_id, attr.value);
                }

                // we don't respond to report
                return;

            case default_response:
                // response to my previous command...
                // check failure status and log?
                return;

            default:
                assert(false, tformat("Unsupported ZCL command: {0, 02x}", zcl.command));
                return;
        }

        // send default response
        if (zcl.control & ZCLControlFlags.disable_default_response)
            return; // request no default response
        send_default_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, zcl.seq, zcl.command, status);
    }

    void create_device(ref NodeMap node)
    {
        if (_zigbee_profile)
        {
            // check the profile for this thing
            const DeviceTemplate* device_template = _zigbee_profile.get_model_template(node.get_fingerprint[]);
            if (device_template)
            {
                // we have a device template, so create the device from that

                return;
            }
        }

        // otherwise, interrogate and create something

    }
}

private:

__gshared immutable ubyte[4] g_power_levels = [ 0, 33, 66, 100 ];


bool do_node_interview(ZigbeeController controller, NodeMap* node) @nogc
{
    version (DebugZigbeeController)
        writeInfof("ZigbeeController: beginning interview for device {0,04x}...", node.id);

    ZigbeeResult r;
    ZDOResponse zdo_res;
    ZCLResponse zcl_res;
    ubyte[128] req_buffer = void;

    bool fail(const(char)[] reason = "failed")
    {
        node.initialised = 0;
        version (DebugZigbeeController)
            writeWarningf("ZigbeeController: interview FAILED for device {0,04x}! result = {1} - {2}", node.id, r, reason);
        return false;
    }

    // if we don't know the device EUI, then fetch that
    if (node.eui == EUI64())
    {
        EUI64 eui;
        r = controller.ieee_request(node.id, eui);
        if (r != ZigbeeResult.success)
            return fail("ieee request fail");
    }

    // request node descriptor
    req_buffer[0] = 0;
    req_buffer[1..3] = node.id.nativeToLittleEndian;
    r = controller.zdo_request(node.id, ZDOCluster.node_desc_req, req_buffer[0..3], zdo_res);
    if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
        return fail("node_desc_req fail");

    const(ubyte)[] msg = zdo_res.message[];
    if (msg.length < 15)
        return fail("response too short");
    if (msg[0..2].littleEndianToNative!ushort != node.id)
        return fail("id mismatch");

    ubyte type = msg[2] & 0x07;
    node.desc.type = type == 0 ? NodeType.coordinator :
    type == 1 ? NodeType.router :
    NodeType.end_device;
    node.desc.freq_bands = msg[3] >> 3;
    node.desc.mac_capabilities = msg[4];
    node.desc.manufacturer_code = msg[5..7].littleEndianToNative!ushort;
    ushort server_mask = msg[10..12].littleEndianToNative!ushort;
    node.desc.server_capabilities = server_mask & ZDOServerCapability.mask;
    node.desc.stack_compliance_revision = server_mask >> 9;
    node.desc.max_nsdu = msg[7];
    node.desc.max_asdu_in = msg[8..10].littleEndianToNative!ushort;
    node.desc.max_asdu_out = msg[12..14].littleEndianToNative!ushort;
    node.desc.complex_desc = (msg[2] & 0x08) != 0;
    node.desc.user_desc = (msg[2] & 0x10) != 0;
    node.desc.extended_active_ep_list = (msg[14] & 0x01) != 0;
    node.desc.extended_simple_desc_list = (msg[14] & 0x02) != 0;

    if (node.desc.complex_desc)
    {
        // TODO: request complex descriptor??
        assert(false);
    }
    if (node.desc.user_desc)
    {
        // TODO: request user descriptor??
        assert(false);
    }

    // request power descriptor
    r = controller.zdo_request(node.id, ZDOCluster.power_desc_req, req_buffer[0..3], zdo_res);
    if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
        return fail("power_desc_req fail");

    msg = zdo_res.message[];
    if (msg.length < 4)
        return fail("response too short");
    if (msg[0..2].littleEndianToNative!ushort != node.id)
        return fail("id mismatch");

    node.power.current_mode = cast(CurrentPowerMode)(msg[2] & 0x0F);
    node.power.available_sources = msg[2] >> 4;
    node.power.current_source = msg[3] & 0x0F;
    node.power.batt_level = g_power_levels[msg[3] >> 6];

    // request active endpoints
    r = controller.zdo_request(node.id, ZDOCluster.active_ep_req, req_buffer[0..3], zdo_res);
    if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
        return fail("active_ep_req fail");

    msg = zdo_res.message[];
    if (msg.length < 3)
        return fail("response too short");
    if (msg[0..2].littleEndianToNative!ushort != node.id)
        return fail("id mismatch");

    ubyte num_eps = msg[2];
    foreach (i; 0 .. num_eps)
    {
        ubyte endpoint = msg[3 + i];
        ref ep = node.get_endpoint(endpoint);
        ep.dynamic = false;
    }

    // for each endpoint...
    bool support_extended_attributes = true;
    foreach (ref ep; node.endpoints.values)
    {
        // request simple descriptor
        req_buffer[1..3] = node.id.nativeToLittleEndian;
        req_buffer[3] = ep.endpoint;
        r = controller.zdo_request(node.id, ZDOCluster.simple_desc_req, req_buffer[0..4], zdo_res);
        if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
            return fail("simple_desc_req fail");

        msg = zdo_res.message[];
        if (msg.length < 3)
            return fail("response too short");
        ubyte length = zdo_res.message[2];
        if (length > zdo_res.message.length - 3)
            return fail("response too short");
        if (zdo_res.message[3] != ep.endpoint)
            return fail("endpoint mismatch");

        ep.profile_id = msg[4..6].littleEndianToNative!ushort;
        ep.device_id = msg[6..8].littleEndianToNative!ushort;
        ep.device_version = msg[8] & 0x0F;

        ubyte num_in_clusters = msg[9];
        size_t offset = 10;
        if (offset + num_in_clusters*2 > msg.length)
            return fail("response too short");
        foreach (i; 0 .. num_in_clusters)
        {
            ushort cluster_id = msg[offset..offset + 2][0..2].littleEndianToNative!ushort;
            offset += 2;
            ref cluster = ep.get_cluster(cluster_id);
            cluster.dynamic = false;
        }
        ubyte num_out_clusters = msg[offset++];
        if (offset + num_out_clusters*2 > msg.length)
            return fail("response too short");
        ep.out_clusters.reserve(num_out_clusters);
        foreach (i; 0 .. num_out_clusters)
        {
            ep.out_clusters ~= msg[offset..offset + 2][0..2].littleEndianToNative!ushort;
            offset += 2;
        }

        // scan attributes for clusters
        foreach (ref NodeMap.Cluster c; ep.clusters.values)
        {
            req_buffer[2] = 0xFF;

            ushort attr_id = 0;
            while (true)
            {
                req_buffer[0] = attr_id & 0xFF;
                req_buffer[1] = attr_id >> 8;

                // try request extended attributes first, then normal if that fails
                if (support_extended_attributes)
                {
                    r = controller.zcl_request(node.id, ep.endpoint, ep.profile_id, c.cluster_id, ZCLCommand.discover_attributes_extended, 0, req_buffer[0..3], zcl_res);
                    if (r != ZigbeeResult.success)
                        support_extended_attributes = false;
                }
                if (!support_extended_attributes)
                {
                    r = controller.zcl_request(node.id, ep.endpoint, ep.profile_id, c.cluster_id, ZCLCommand.discover_attributes, 0, req_buffer[0..3], zcl_res);
                    if (r != ZigbeeResult.success)
                        return fail("discover_attributes fail");
                }

                ref ZCLHeader hdr = zcl_res.hdr;
                msg = zcl_res.message[];
                if (msg.length < 1)
                    return fail("response too short");
                bool complete = msg[0] != 0;

                if (hdr.command == ZCLCommand.discover_attributes_extended_response)
                {
                    for (offset = 1; offset + 4 < msg.length; offset += 4)
                    {
                        attr_id = msg[offset..offset + 2][0..2].littleEndianToNative!ushort;
                        ref NodeMap.Attribute attr = c.get_attribute(attr_id);
                        attr.data_type = cast(ZCLDataType)msg[offset + 2];
                        attr.access = cast(ZCLAccess)msg[offset + 3];
                    }
                }
                else if (hdr.command == ZCLCommand.discover_attributes_response)
                {
                    for (offset = 1; offset + 3 < msg.length; offset += 3)
                    {
                        attr_id = msg[offset..offset + 2][0..2].littleEndianToNative!ushort;
                        ref NodeMap.Attribute attr = c.get_attribute(attr_id);
                        attr.data_type = cast(ZCLDataType)msg[offset + 2];
                        attr.access = ZCLAccess.unknown;
                    }
                }
                else
                    return fail("got unexpected response");

                if (complete)
                    break;
                ++attr_id;
            }
        }
    }

    // read from the basic cluster
    enum ushort[10] basic_attributes = [ 0, 1, 2, 3, 4, 5, 7, 10, 11, 0x4000 ];
    for (size_t i = 0; i < basic_attributes.length; ++i)
        req_buffer[i*2..i*2 + 2][0..2] = basic_attributes[i].nativeToLittleEndian;

    // apparently we're meant to read basic info from the earliest endpoint that has it
    foreach (ref ep; node.endpoints.values)
    {
        if ((0 in ep.clusters) is null)
            continue;

        // read basic attributes
        r = controller.zcl_request(node.id, ep.endpoint, ep.profile_id, 0, ZCLCommand.read_attributes, 0, req_buffer[0 .. basic_attributes.length*2], zcl_res);
        if (r != ZigbeeResult.success)
            return fail("read_attributes fail");
        if (zcl_res.hdr.command == ZCLCommand.default_response)
        {
            if (zcl_res.message.length != 2)
                return fail("default response wrong length");
            if (zcl_res.message[0] != ZCLCommand.read_attributes)
                return fail("default response to wrong command");
            if (zcl_res.message[1] != cast(ubyte)ZCLStatus.unsup_cluster_command)
                return fail("default response failure");
            continue;
        }
        if (zcl_res.hdr.command != ZCLCommand.read_attributes_response)
            return fail("unexpected response");

        msg = zcl_res.message[];
        if (msg.length < basic_attributes.length*3)
            return fail("response too short");

        SysTime now = getSysTime();

        // parse the results
        for (size_t i = 0; i + 3 <= msg.length; )
        {
            ushort attr_id = msg[i .. i + 2][0..2].littleEndianToNative!ushort;
            ubyte status = msg[i + 2];
            i += 3;
            if (status != 0)
            {
                if (status == ZCLStatus.unsupported_attribute)
                    continue; // TODO: should we zero-out the attribute value?
                //                        return fail("read attribute fail");
                continue; // also just skip on other errors? or maybe we should bail (maybe we fell off the parsing rails?)
            }

            ref NodeMap.Attribute attr = ep.get_cluster(0).get_attribute(attr_id);
            attr.last_updated = now;

            ZCLDataType data_type = cast(ZCLDataType)msg[i++];
            version (DebugZigbeeController)
            {
                if (attr.data_type != data_type)
                    writeWarningf("ZigbeeController: basic attribute {0,04x} data type mismatch (expected {1}, got {2})", attr_id, attr.data_type, data_type);
            }
            attr.data_type = data_type;

            ptrdiff_t taken = get_zcl_value(attr.data_type, msg[i .. $], attr.value);
            if (taken > 0)
            {
                i += taken;

                switch (attr_id)
                {
                    case 0:      node.basic_info.zcl_ver = attr.value.as!ubyte;      break;
                    case 1:      node.basic_info.app_ver = attr.value.as!ubyte;      break;
                    case 2:      node.basic_info.stack_ver = attr.value.as!ubyte;    break;
                    case 3:      node.basic_info.hw_ver = attr.value.as!ubyte;       break;
                    case 7:      node.basic_info.power_source = cast(ZCLPowerSource)attr.value.as!ubyte;          break;
                    case 4:      node.basic_info.mfg_name = attr.value.asString.makeString(defaultAllocator);     break;
                    case 5:      node.basic_info.model_name = attr.value.asString.makeString(defaultAllocator);   break;
                    case 10:     node.basic_info.product_code = attr.value.asString.makeString(defaultAllocator); break;
                    case 11:     node.basic_info.product_url = attr.value.asString.makeString(defaultAllocator);  break;
                    case 0x4000: node.basic_info.sw_build_id = attr.value.asString.makeString(defaultAllocator);  break;
                    default:
                        break;
                }
            }
        }
        break;
    }

    version (DebugZigbeeController)
    {
        MutableString!0 info;
        foreach (ref ep; node.endpoints.values)
        {
            info.append("    ep ", ep.endpoint, ":\n");
            foreach (ref NodeMap.Cluster c; ep.clusters.values)
            {
                info.appendFormat("        cluster {0,x}:", c.cluster_id);
                foreach (ref NodeMap.Attribute a; c.attributes.values)
                    info.appendFormat(" {0,x}", a.attribute_id);
                info ~= "\n";
            }
        }
        writeInfof("ZigbeeController: completed interview for device {0,04x} ({1}) {2} {3}\n{4}", node.id, node.get_fingerprint()[], node.basic_info.product_code[], node.basic_info.product_url[], info[]);
    }

    if (controller._auto_create_devices && node.desc.type != NodeType.coordinator)
        controller.create_device(*node);

    return true;
}
