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
import manager.component;
import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;
import manager.subscriber;

import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.client;
import protocol.zigbee.zcl;
import protocol.zigbee.zdo;

import router.iface.mac;
import router.iface.packet : PCP;

version = DebugZigbeeController;

nothrow @nogc:

enum MaxFibers = 2;


class ZigbeeController : BaseObject, Subscriber
{
    __gshared Property[2] Properties = [ Property.create!("endpoint", endpoint)(),
                                         Property.create!("auto-create", auto_create)() ];
@nogc:

    enum type_name = "zigbee-controller";

    this(String name, ObjectFlags flags = ObjectFlags.none) nothrow
    {
        super(collection_type_info!ZigbeeController, name.move, flags);

        _promises.reserve(MaxFibers);
    }

    ~this() nothrow
    {
        if (_endpoint)
        {
            _endpoint.set_message_handler(null);
            _endpoint = null;
        }
    }

    // Properties...

    final inout(ZigbeeEndpoint) endpoint() inout pure nothrow
        => _endpoint;
    final StringResult endpoint(ZigbeeEndpoint value) nothrow
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

    final bool auto_create() const pure nothrow
        => _auto_create_devices;
    final void auto_create(bool value) nothrow
    {
        _auto_create_devices = value;
    }

    // API...

protected:

    override bool validate() const nothrow
        => _endpoint !is null;

    override CompletionStatus validating() nothrow
    {
        _endpoint.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup() nothrow
    {
        if (!_zigbee_profile)
            _zigbee_profile = load_profile("conf/zigbee_profiles/zigbee.conf", defaultAllocator());

        return _endpoint.running ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown() nothrow
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

        tuya_dedup.clear();

        return CompletionStatus.complete;
    }

    override void update() nothrow
    {
        // we need to populate our database of devices with detail...

        ZigbeeProtocolModule zb = get_module!ZigbeeProtocolModule();

        MonoTime now = getTime();

        size_t i;
        for (i = 0; i < tuya_dedup.length; )
        {
            if (now - tuya_dedup[i].last > 2.seconds || now - tuya_dedup[i].first > 10.seconds)
                tuya_dedup.remove(i);
            else
                ++i;
        }

        for (i = 0; i < _promises.length; )
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
            if (!nm.available)
                continue;

            if (nm.initialised < 0xFF && !nm.scan_in_progress && _promises.length < MaxFibers)
            {
                nm.scan_in_progress = true;
                _promises.pushBack(async(&do_node_interview, &nm));
            }

            if (_auto_create_devices && !nm.device_created && (nm.initialised & 0x80))
            {
                nm.device_created = true;
                if (nm.desc.type != NodeType.coordinator)
                    create_device(nm);
            }
        }

        foreach (j, ref unk; get_module!ZigbeeProtocolModule.unknown_nodes)
        {
            if (!unk.scanning)
            {
                unk.scanning = true;
                send_ieee_request(unk.id, PCP.ca, &probe_response, cast(void*)cast(size_t)unk.id);
            }
        }

        // TODO: periodically read the software/build id's
        //       if they change (firmware update) we should re-interview the device to rebuild it's detail map
    }

    void probe_response(ZigbeeResult result, ZDOStatus status, const(ubyte)[] message, void* user_data) nothrow
    {
        if (result == ZigbeeResult.pending)
            return;

        auto zb_mod = get_module!ZigbeeProtocolModule;
        ushort node_id = cast(ushort)cast(size_t)user_data;

        foreach (i, ref unk; zb_mod.unknown_nodes)
        {
            if (node_id == unk.id)
            {
                unk.scanning = false;

                if (result == ZigbeeResult.success && status == ZDOStatus.success && message.length >= 10)
                {
                    if (message[8..10].littleEndianToNative!ushort != unk.id)
                    {
                        version (DebugZigbeeController)
                            writeWarningf("ZigbeeController: probe_response id mismatch for unknown node {0,04x}", unk.id);
                        return;
                    }

                    const eui = EUI64(message[0..8]);
                    NodeMap* n = zb_mod.attach_node(eui, unk.pan_id, unk.id);
                    n.via = unk.via;
                    version (DebugZigbeeController)
                        writeInfof("ZigbeeController: discovered unknown node {0,04x} with EUI {1}", unk.id, eui);

                    zb_mod.unknown_nodes.remove(i);
                }
                return;
            }
        }
    }

    final void add_sample_element(Element* element, EUI64 eui, ref const ElementDesc desc, ref const ElementDesc_Zigbee zb, ubyte endpoint) nothrow
    {
        ulong[2] key = make_sample_key(eui, endpoint, zb.cluster_id, zb.attribute_id, zb.manufacturer_code);
        assert(key !in _sample_elements, "TODO: support element duplicates?");
        SampleElement* se = _sample_elements.insert(key, SampleElement(element, zb.value_desc));
        se.eui = eui;
        se.endpoint = endpoint;
        se.cluster = zb.cluster_id;
        se.attribute = zb.attribute_id;
        se.manufacturer = zb.manufacturer_code;
        _sample_elements_by_element.insert(element, se);

        if (element.access & manager.element.Access.write)
            element.add_subscriber(this);
    }

    final SampleElement* find_sample_element(EUI64 eui, ubyte endpoint, ushort cluster, ushort attribute, ushort manufacturer = 0) nothrow
    {
        ulong[2] key = make_sample_key(eui, endpoint, cluster, attribute, manufacturer);
        return key in _sample_elements;
    }

    final SampleElement* find_sample_element_tuya(EUI64 eui, ubyte endpoint, ushort dp) nothrow
        => find_sample_element(eui, endpoint, 0xEF00, dp);

    final override void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber)
    {
        SampleElement** pse = e in _sample_elements_by_element;
        assert(pse, "Bookeeeping error!");
        set_value(**pse, val, timestamp);
    }

private:

    struct SampleElement
    {
        Element* element;
        ValueDesc desc;
        EUI64 eui;
        ubyte endpoint;
        ushort cluster;
        ushort attribute;
        ushort manufacturer;
    }

    struct TuyaDedup
    {
        MonoTime first;
        MonoTime last;
        ushort node;
        ushort tag;
    }

    // TODO: I'd prefer if we used a sorted array...
    Map!(ulong[2], SampleElement) _sample_elements;
    Map!(Element*, SampleElement*) _sample_elements_by_element;

    bool _auto_create_devices;
    ushort tuya_txn_id = 1;

    ObjectRef!ZigbeeEndpoint _endpoint;
    Array!(Promise!bool*) _promises;

    Array!NodeMap discover_nodes;
    Array!TuyaDedup tuya_dedup;

    Profile* _zigbee_profile;

    ulong[2] make_sample_key(EUI64 eui, ubyte endpoint, ushort cluster, ushort attribute, ushort manufacturer = 0) nothrow
    {
        ulong[2] r;
        r[0] = eui.ul;
        r[1] = (ulong(endpoint) << 48) | (ulong(manufacturer) << 32) | (cluster << 16) | attribute;
        return r;
    }

    ulong[2] make_sample_key_tuya(EUI64 eui, ubyte endpoint, ubyte dp) nothrow
        => make_sample_key(eui, endpoint, 0xEF00, dp);

    ZigbeeResult ieee_request(ushort dst, out EUI64 eui, PCP pcp = PCP.be)
    {
        ubyte[5] addr_req_msg = void;
        addr_req_msg[0] = 0;
        addr_req_msg[1..3] = dst.nativeToLittleEndian;
        addr_req_msg[3] = 0; // request type: single device response
        addr_req_msg[4] = 0; // start index

        ZDOResponse response;
        ZigbeeResult r = _endpoint.zdo_request(dst, ZDOCluster.ieee_addr_req, addr_req_msg[], response, pcp);
        if (r == ZigbeeResult.success && response.status == ZDOStatus.success && response.message.length >= 8)
            eui.b[] = response.message[0..8];
        return r;
    }

    int send_default_response(ushort dst, ubyte endpoint, ushort profile, ushort cluster, ref const ZCLHeader req, ubyte cmd, ubyte status, PCP pcp = PCP.be) nothrow
    {
        const ubyte[2] msg = [ cmd, status ];
        return _endpoint.send_zcl_response(dst, endpoint, profile, cluster, ZCLCommand.default_response, req, msg[], pcp);
    }

    int send_ieee_request(ushort dst, PCP pcp = PCP.be, ZDOResponseHandler response_hander = null, void* user_data = null) nothrow
    {
        ubyte[5] addr_req_msg = void;
        addr_req_msg[0] = 0;
        addr_req_msg[1..3] = dst.nativeToLittleEndian;
        addr_req_msg[3] = 0; // request type: single device response
        addr_req_msg[4] = 0; // start index
        return _endpoint.send_zdo_message(dst, ZDOCluster.ieee_addr_req, addr_req_msg[], pcp, response_hander, user_data);
    }

    void message_handler(ref const APSFrame aps, const(void)[] message, SysTime timestamp) nothrow
    {
        if (message.length < ZCLHeader.min_length)
            return;

        ZCLHeader zcl;
        ptrdiff_t bytes = message.decode_zcl_header(zcl);
        if (bytes < 0)
            return; // TODO: should we send malformed_command default response?
        const(ubyte)[] payload = cast(ubyte[])message[bytes..$]; // get the payload...
        ubyte[138] response = void; // complete message, nothing to report...

        NodeMap* nm = get_module!ZigbeeProtocolModule.find_node(aps.pan_id, aps.src);
        if (!nm)
        {
            version (DebugZigbeeController)
                writeWarningf("ZigbeeController: Received ZCL message from unknown device {0,04x}", aps.src);
        }

        ZCLStatus status = ZCLStatus.success;

        if (!zcl.cluster_local)
        {
            outer: switch (zcl.command) with (ZCLCommand)
            {
                case read_attributes:
                    size_t num_attrs = payload.length / 2;
                    size_t offset = 0;
                    foreach (i; 0 .. num_attrs)
                    {
                        ushort attr_id = payload[i*2 .. i*2 + 2][0..2].littleEndianToNative!ushort;
                        response[offset..offset + 2] = attr_id.nativeToLittleEndian;
                        offset += 2;

                        ptrdiff_t len;
                        switch (aps.cluster_id)
                        {
                            case 0x0000: // basic cluster
                                switch (attr_id)
                                {
                                    case 0x0000: // zcl version
                                        len = write_attribute(response[offset .. $], ubyte(3)); // ZCL version 3
                                        goto check_write;
                                    case 0x0001: // application version
                                        // TODO: patch an actual app version through to this...
                                        len = write_attribute(response[offset .. $], ubyte(0)); // app version 0
                                        goto check_write;
                                    case 0x0002: // stack version
                                        len = write_attribute(response[offset .. $], ubyte(0)); // stack version 0
                                        goto check_write;
                                    case 0x0003: // hw version
                                        len = write_attribute(response[offset .. $], ubyte(0)); // hw version 0
                                        goto check_write;
                                    case 0x0004: // manufacturer name
                                        len = write_attribute(response[offset .. $], "OpenWatt");
                                        goto check_write;
                                    case 0x0005: // model identifier
                                        len = write_attribute(response[offset .. $], "OpenWatt"); // TODO: better name?
                                        goto check_write;
                                    case 0x0007: // power source
                                        len = write_attribute(response[offset .. $], ZCLPowerSource.mains_single_phase); // mains powered
                                        goto check_write;
                                    case 0x0012: // device enabled
                                        len = write_attribute(response[offset .. $], true);
                                        goto check_write;
                                    case 0x4000: // sw-build-id
                                        len = write_attribute(response[offset .. $], "ow-zb-1.0.0"); // TODO: better version string?
                                        goto check_write;
                                    case 0xFFFD: // cluster revision
                                        len = write_attribute(response[offset .. $], ushort(1));
                                        goto check_write;
                                    default:
                                        goto unknown_attribute;
                                }
                                break;

                            case 0x0001: // power configuration cluster
                                switch (attr_id)
                                {
                                    default:
                                        goto unknown_attribute;
                                }
                                break;

                            case 0x000A: // time cluster
                                switch (attr_id)
                                {
                                    case 0x0000: // time
                                        len = write_attribute(response[offset .. $], get_zigbee_time(), ZCLDataType.utc_time);
                                        goto check_write;
                                    case 0x0001: // time status
                                        len = write_attribute(response[offset .. $], ubyte(7), ZCLDataType.bitmap8); // synchronized, master, master zone dst
                                        goto check_write;
                                    case 0x0002: // time zone
                                        len = write_attribute(response[offset .. $], int(0));
                                        goto check_write;
                                    default:
                                        goto unknown_attribute;
                                }
                                break;

                            check_write:
                                if (len < 0)
                                {
                                    status = ZCLStatus.insufficient_space;
                                    break outer;
                                }
                                offset += len;
                                break;

                            default: unknown_attribute:
                                response[offset] = ZCLStatus.unsupported_attribute;
                                offset += 1;
                                version (DebugZigbeeController)
                                    writeDebugf("ZigbeeController: {0,04x}:{1,02x} read unknown attribute {2}:{3,04x}:{4,04x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id, attr_id);
                                break;
                        }
                    }

                    _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, ZCLCommand.read_attributes_response, zcl, response[0..offset]);
                    return;

                case write_attributes, configure_reporting, read_reporting_configuration:
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

                    response[0] = 1; // complete message, nothing to report...

                    _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, ZCLCommand.discover_attributes_response, zcl, response[0..1]);
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

                    response[0] = 1; /// complete message, nothing to report...

                    _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, ZCLCommand.discover_attributes_extended_response, zcl, response[0..1]);
                    return;

                case read_attributes_response:
                    // my request for attributes returned...
                    version (DebugZigbeeController)
                        writeDebugf("ZigbeeController: {0,04x}:{1,02x} UNEXPECTED read_attributes_response {2}:{3,04x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id);
                    return;

                case write_attributes_response:
                    // my request to write attributes returned...
                    assert(false, "TODO");
                    return;

                case discover_attributes_response:
                    // my request to discover attributes returned...
                    version (DebugZigbeeController)
                        writeDebugf("ZigbeeController: {0,04x}:{1,02x} UNEXPECTED discover_attributes_response {2}:{3,04x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id);
                    return;

                case discover_attributes_extended_response:
                    // my request to discover attributes returned...
                    version (DebugZigbeeController)
                        writeDebugf("ZigbeeController: {0,04x}:{1,02x} UNEXPECTED discover_attributes_extended_response {2}:{3,04x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id);
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
                            status = ZCLStatus.malformed_command;
                            break;
                        }
                        attr.last_updated = now; // TODO: this timestamp should come from the packet! but we lost that here...

                        // update runtime element
                        if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, attr_id, zcl.manufacturer_code))
                        {
                            Variant v = attr.value;
                            adjust_value(v, e.desc);
                            e.element.value(v.move, timestamp, this);
                        }

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
                    version (DebugZigbeeController)
                        writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent unsupported command {2}:{3,04x} cmd: {4,02x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id, zcl.command);
                    break;
            }
        }
        else
        {
            // handle the `manuSpecificTuya` cluster to the best of our knowledge... :/
            switch (aps.cluster_id)
            {
                case 0:
                    if (zcl.command == 0)
                    {
                        // factory reset!
                        writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent UNSUPPORTED factory reset command...", aps.src, aps.src_endpoint);
                    }
                    break;

                case 0x500: // IAS Zone
                    if (zcl.command == 0)
                    {
                        // state change
                        ushort zone_status = payload[0..2].littleEndianToNative!ushort;
                        ubyte extended_status = payload[2];
                        ubyte zone_id = payload[3];
                        ushort delay = payload[4..6].littleEndianToNative!ushort;

                        if (nm)
                        {
                            SysTime now = getSysTime();

                            ref NodeMap.Endpoint ep = nm.get_endpoint(aps.src_endpoint);
                            if (ep.profile_id == 0)
                                ep.profile_id = aps.profile_id;
                            ref NodeMap.Cluster cluster = ep.get_cluster(aps.cluster_id);

                            ref attr_status = cluster.get_attribute(2);
                            attr_status.value = zone_status;
                            attr_status.last_updated = now;

                            // update some synthetic attributes under the 500 cluster...
                            ref attr_zone = cluster.get_attribute(0xFC10);
                            attr_zone.value = zone_id;
                            attr_zone.last_updated = now;
                            ref attr_delay = cluster.get_attribute(0xFC20);
                            attr_delay.value = delay;
                            attr_delay.last_updated = now;

                            // update runtime elements
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC00))
                                e.element.value = (zone_status & 1) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC01))
                                e.element.value = (zone_status & 2) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC02))
                                e.element.value = (zone_status & 4) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC03))
                                e.element.value = (zone_status & 8) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC06))
                                e.element.value = (zone_status & 0x40) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC07))
                                e.element.value = (zone_status & 0x80) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC09))
                                e.element.value = (zone_status & 0x200) != 0;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC10))
                                e.element.value = zone_id;
                            if (SampleElement* e = find_sample_element(nm.eui, aps.src_endpoint, aps.cluster_id, 0xFC20))
                                e.element.value = delay;
                        }

                        version (DebugZigbeeController)
                            writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent IAS zone: status={2,04x} ext={3,02x} zone={4} delay={5}", aps.src, aps.src_endpoint, zone_status, extended_status, zone_id, delay);
                        return;
                    }
                    else
                        assert(false, "TODO");
                    break;

                case 0xEF00: // Tuya
                    if (payload.length < 2)
                    {
                        status = ZCLStatus.malformed_command;

                        version (DebugZigbeeController)
                            writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent malformed Tuya command {2,02x}", aps.src, aps.src_endpoint, cast(ubyte)zcl.command);
                        break;
                    }
                    ushort tuya_seq = payload[0..2].bigEndianToNative!ushort;

                    // Tuya messages are spammy!
                    MonoTime now = getTime();
                    foreach (ref dedup; tuya_dedup)
                    {
                        if (dedup.node == aps.src && dedup.tag == tuya_seq)
                        {
                            dedup.last = now;
                            return; // ignore duplicate message
                        }
                    }
                    tuya_dedup.pushBack(TuyaDedup(now, now, aps.src, tuya_seq));

                    switch (zcl.command | 0x4000) with (ZCLCommand)
                    {
                        case tuya_data_request:
                            TuyaDP dp = parse_dp(payload[2 .. $]);
                            assert(false, "TODO");
                            return;

                        case tuya_data_response:
                            TuyaDP dp = parse_dp(payload[2 .. $]);
                            assert(false, "TODO");
                            return;

                        case tuya_data_report:
                            TuyaDP dp = parse_dp(payload[2 .. $]);
                            Variant v = decode_dp(dp);
                            version (DebugZigbeeController)
                                writeDebugf("ZigbeeController: {0,04x}:{1,02x} Tuya report dp{2} = {3} ({4})", aps.src, aps.src_endpoint, dp.dp_id, v, dp.dp_type);
                            if (nm)
                            {
                                nm.tuya_datapoints[dp.dp_id] = v;
                                if (SampleElement* e = find_sample_element_tuya(nm.eui, aps.src_endpoint, dp.dp_id))
                                {
                                    adjust_value(v, e.desc);
                                    e.element.value(v.move, timestamp, this);
                                }
                            }
                            return;

                        case tuya_mcu_version_req:
                            // TODO: this seems odd? why is someone asking us for this? just ignore it?
                            return;

                        case tuya_mcu_version_rsp:
                            writeInfof("ZigbeeController: {0,04x}:{1,02x} Tuya MCU version {2}.{3}.{4}", aps.src, aps.src_endpoint, payload[0], payload[1], payload[2]);
                            writeWarning("TODO: record the version into a synthetic attribute!!"); // ie, EF00:FC00?
                            return;

                        case tuya_mcu_sync_time:
                            uint time_secs = get_zigbee_time();
                            response[0..2] = tuya_seq.nativeToBigEndian;
                            response[2..6] = time_secs.nativeToBigEndian; // TODO: CONFIRM is big or little endian??
                            response[6..10] = time_secs.nativeToBigEndian;
                            _endpoint.send_zcl_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, cast(ZCLCommand)zcl.command, zcl, response[0..10]);
                            return;

                        default:
                            version (DebugZigbeeController)
                                writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent unsupported Tuya command {2,02x}", aps.src, aps.src_endpoint, cast(ubyte)zcl.command);
                            return;
                    }
                    break;

                default:
                    break;
            }

            version (DebugZigbeeController)
                writeDebugf("ZigbeeController: {0,04x}:{1,02x} sent unsupported cluster command {2}:{3,04x} cmd: {4,02x}", aps.src, aps.src_endpoint, aps.profile_id.profile_name, aps.cluster_id, zcl.command);
        }

        // send default response
        if (zcl.control & ZCLControlFlags.disable_default_response)
            return; // request no default response
        send_default_response(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, zcl, zcl.command, status);
    }

    void set_value(ref SampleElement e, ref const Variant val, SysTime timestamp) nothrow
    {
        if (!(e.element.access & manager.element.Access.write))
            return; // attribute is read-only!

        switch (e.cluster)
        {
            case 0x0006: // on/off
                if (e.attribute == 0)
                {
                    // on/off attribute must be translated to on/off command
                    bool on = val.as!bool;
                    ZCLCommand cmd = on ? ZCLCommand.onoff_on : ZCLCommand.onoff_off;

                    // TODO: we should request an ACK!!!

                    _endpoint.send_zcl_message(e.eui, e.endpoint, 0x0104, 0x0006, cmd, APSFlags.none, null, MessagePriority.immediate);
                    break;
                }
                goto default;

            case 0xEF00: // Tuya
                // attribute id is Tuya datapoint
                ubyte[256] buffer = void;
                buffer[0..2] = tuya_txn_id.nativeToBigEndian;
                tuya_txn_id++;
                tuya_txn_id += tuya_txn_id == 0;

                assert(e.attribute < 256, "Invalid Tuya DP id!");
                ptrdiff_t len = encode_dp(cast(ubyte)e.attribute, val, e.desc, buffer[2 .. $]);
                if (len <= 0)
                    break; // failed?!

                // TODO: we should request an ACK!!!

                _endpoint.send_zcl_message(e.eui, e.endpoint, 0x0104, 0xEF00, ZCLCommand.tuya_data_request, APSFlags.none, buffer[0..2+len], MessagePriority.immediate);
                break;

            default:
                // should we use a generic write_attributes?
                break;
        }
    }

    void create_device(ref NodeMap node) nothrow
    {
        if (_zigbee_profile)
        {
            MutableString!0 fingerprint = node.get_fingerprint;
            if (fingerprint[] != "::0.0") // don't attempt the default fingerprint
            {
                import urt.encoding : hex_encode;
                char[] eui_string = cast(char[])talloc(16);
                node.eui.b[].hex_encode(eui_string);
                const char[] id = tconcat("zb_", eui_string.to_lower);

                // see if we can create one for this fingerprint
                Device device = create_device_from_profile(*_zigbee_profile, fingerprint[], id, null, (Device device, Element* e, ref const ElementDesc desc, ubyte endpoint) {
                    assert(desc.type == ElementType.zigbee);
                    ref const ElementDesc_Zigbee zb = _zigbee_profile.get_zb(desc.element);
                    add_sample_element(e, node.eui, desc, zb, endpoint);

                    if (zb.cluster_id == 0x0000) // basic cluster
                    {
                        switch (zb.attribute_id)
                        {
                            case 0: // zcl version
                                e.value = node.basic_info.zcl_ver;
                                break;
                            case 1: // application version
                                e.value = node.basic_info.app_ver;
                                break;
                            case 2: // stack version
                                e.value = node.basic_info.stack_ver;
                                break;
                            case 3: // hw version
                                e.value = node.basic_info.hw_ver;
                                break;
                            case 4: // manufacturer name
                                e.value = node.basic_info.mfg_name[];
                                break;
                            case 5: // model identifier
                                e.value = node.basic_info.model_name[];
                                break;
                            case 7: // power source
                                e.value = node.basic_info.power_source;
                                break;
                            case 10: // product code
                                e.value = node.basic_info.product_code[];
                                break;
                            case 11: // product url
                                e.value = node.basic_info.product_url[];
                                break;
                            case 0x4000: // sw-build-id
                                e.value = node.basic_info.sw_build_id[];
                                break;
                            default:
                                break;
                        }
                    }
                });

                if (!device)
                {
                    writeWarning("Failed to create device for zigbee node ", node.eui, " with fingerprint: ", fingerprint[]);
                    return;
                }
                node.device = device;

                // set a bunch of status data
                Element* e = device.find_or_create_element("status.network.mode");
                e.value = StringLit!"zigbee";
                e = device.find_or_create_element("status.network.zigbee.eui");
                e.value = node.eui;
                e = device.find_or_create_element("status.network.zigbee.address");
                e.value = node.id;
                e = device.find_or_create_element("status.network.zigbee.rssi");
                e.value = node.rssi;
                e = device.find_or_create_element("status.network.zigbee.lqi");
                e.value = node.lqi;

                // set component templates for components we ma have created
                Component c = device.find_component("status");
                c.template_ = StringLit!"DeviceStatus";
                c = device.find_component("status.network");
                c.template_ = StringLit!"Network";
                c = device.find_component("status.network.zigbee");
                c.template_ = StringLit!"Zigbee";

                return;
            }
        }

        // otherwise, interrogate and create something
        // TODO: ...?

        writeWarning("Couldn't create device for zigbee node ", node.eui, ", no fingerprint match");
    }

    // a little helper to try a request up to 3 times with a delay
    ZigbeeResult try_thrice(scope ZigbeeResult delegate() @nogc fn)
    {
        ZigbeeResult res;
        for (size_t attempt = 0; attempt < 3; ++attempt)
        {
            res = fn();
            if (res != ZigbeeResult.timeout)
                break;
//            sleep(100.msecs); // timeout already implemented a fairly long wait?
        }
        return res;
    }

    bool do_node_interview(NodeMap* node)
    {
        version (DebugZigbeeController)
            writeInfof("ZigbeeController: beginning interview for device {0,04x}...", node.id);

        ZigbeeResult r;
        ZDOResponse zdo_res;
        ZCLResponse zcl_res;
        const(ubyte)[] msg = void;
        ubyte[128] req_buffer = void;

        bool fail(const(char)[] reason = "failed")
        {
            node.scan_in_progress = false;
            version (DebugZigbeeController)
                writeWarningf("ZigbeeController: interview FAILED for device {0,04x}! result = {1} - {2}", node.id, r, reason);
            return false;
        }

        debug assert(node.eui != EUI64());

        // request node descriptor
        if (!(node.initialised & 0x01))
        {
            req_buffer[0] = 0;
            req_buffer[1..3] = node.id.nativeToLittleEndian;
            r = try_thrice(() => _endpoint.zdo_request(node.id, ZDOCluster.node_desc_req, req_buffer[0..3], zdo_res, PCP.vo));
            if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
                return fail("node_desc_req failed");

            if (!zdo_res.message[].parse_node_desc(node))
                return fail("invalid response");
        }
/+
        // how do we know if we should do the IAS thing?
        if (node.desc.type == NodeType.sleepy_end_device)
        {
            // maybe IAS stuff?
            req_buffer[0..2] = ushort(0x0010).nativeToLittleEndian;
            req_buffer[2] = 0xF0;
            req_buffer[3..11] = _endpoint.node.eui.b[];
            int tag = _endpoint.send_zcl_message(node.id, 1, 0x0104, 0x0500, ZCLCommand.write_attributes_no_response, ZCLControlFlags.disable_default_response, req_buffer[0..11], PCP.ca);
            if (tag < 0)
                return fail("IAS subscribe failed");
        }
+/
        // try request basic cluster
        if (!(node.initialised & 0xC0))
        {
            node.initialised |= 0x40; // this is an eager attempt; either way this goes, we won't try again

            ref ep = node.get_endpoint(1);
            if (ep.profile_id == 0 || ep.profile_id == 0x0104)
            {
                bool create_ep = ep.profile_id == 0 && ep.dynamic;
                if (create_ep)
                    ep.profile_id = 0x0104;
                bool create_cluster = 0 !in ep.clusters;
                ref cluster = ep.get_cluster(0);

                StringResult result;
                foreach (i; 0..3)
                {
                    result = read_basic_info(node.id, ep, node.basic_info);
                    if (result.succeeded)
                    {
                        writeInfof("ZigbeeController: interviewing device {0,04x}: {1} \"{2}\" {3} {4}", node.id, node.desc.type, node.get_fingerprint()[], node.basic_info.product_code[], node.basic_info.product_url[]);

                        ep.dynamic = false;
                        cluster.dynamic = false;
                        node.initialised |= 0x80;
                        break;
                    }
                }

                if (result.failed)
                {
                    // this was created for the prospective attempt; we'll clean it up
                    if (create_cluster)
                        ep.clusters.remove(0);
                    if (create_ep)
                        node.endpoints.remove(1);
                }
            }
        }

        // request power descriptor
        if (!(node.initialised & 0x02))
        {
            r = try_thrice(() => _endpoint.zdo_request(node.id, ZDOCluster.power_desc_req, req_buffer[0..3], zdo_res, PCP.bk));
            if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
                return fail("power_desc_req failed");

            msg = zdo_res.message[];
            if (msg.length < 4)
                return fail("response too short");
            if (msg[0..2].littleEndianToNative!ushort != node.id)
                return fail("id mismatch");

            node.power.current_mode = cast(CurrentPowerMode)(msg[2] & 0x0F);
            node.power.available_sources = msg[2] >> 4;
            node.power.current_source = msg[3] & 0x0F;
            node.power.batt_level = g_power_levels[msg[3] >> 6];

            node.initialised |= 0x02;
        }

        // request active endpoints
        if (!(node.initialised & 0x04))
        {
            r = try_thrice(() => _endpoint.zdo_request(node.id, ZDOCluster.active_ep_req, req_buffer[0..3], zdo_res, PCP.bk));
            if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
                return fail("active_ep_req failed");

            msg = zdo_res.message[];
            if (msg.length < 3)
                return fail("response too short");
            if (msg[0..2].littleEndianToNative!ushort != node.id)
                return fail("id mismatch");

            ubyte num_eps = msg[2];
            if (msg.length < 3 + num_eps)
                return fail("response too short");

            foreach (i; 0 .. num_eps)
            {
                ubyte endpoint = msg[3 + i];
                ref ep = node.get_endpoint(endpoint);
                ep.dynamic = false;
            }

            node.initialised |= 0x04;
        }

        // discover clusters for each endpoint
        if (!(node.initialised & 0x08))
        {
            foreach (ref ep; node.endpoints.values)
            {
                if (ep.initialised & 0x01)
                    continue;

                // request simple descriptor
                req_buffer[1..3] = node.id.nativeToLittleEndian;
                req_buffer[3] = ep.endpoint;
            try_again:
                r = try_thrice(() => _endpoint.zdo_request(node.id, ZDOCluster.simple_desc_req, req_buffer[0..4], zdo_res, PCP.bk));
                if (r != ZigbeeResult.success || zdo_res.status != ZDOStatus.success)
                    return fail("simple_desc_req failed");

                msg = zdo_res.message[];
                if (msg.length < 3)
                    return fail("response too short");
                ubyte length = msg[2];
                if (length > msg.length - 3)
                    return fail("response too short");
                if (length < 10)
                    return fail("response too short");
                if (msg[3] != ep.endpoint)
                {
                    // this seems like a stale response; why did we receive response to an earlier request?
                    goto try_again;
                }

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

                ep.initialised |= 0x01;
            }

            node.initialised |= 0x08;
        }

        // for each endpoint...
        if (!(node.initialised & 0x10))
        {
            bool support_extended_attributes = true;
            bool got_basic = false;

            foreach (ref ep; node.endpoints.values)
            {
                if (ep.initialised & 0x02)
                    continue;

                // scan clusters for attributes
                foreach (ref NodeMap.Cluster c; ep.clusters.values)
                {
                    if (c.initialised & 0x01)
                        continue;

                    req_buffer[2] = 0xFF;

                    ushort attr_id = 0;
                    while (true)
                    {
                        req_buffer[0] = attr_id & 0xFF;
                        req_buffer[1] = attr_id >> 8;

                        // try request extended attributes first, then normal if that fails
                        if (support_extended_attributes)
                        {
                            r = try_thrice(() => _endpoint.zcl_request(node.id, ep.endpoint, ep.profile_id, c.cluster_id, ZCLCommand.discover_attributes_extended, 0, req_buffer[0..3], zcl_res, PCP.bk));
                            if (r != ZigbeeResult.success)
                                return fail("discover_attributes_extended failed");
                            if (zcl_res.hdr.command == ZCLCommand.default_response)
                            {
                                if (zcl_res.message[1] != ZCLStatus.unsup_cluster_command)
                                    return fail("unexpected default reaponse");
                                support_extended_attributes = false;
                            }
                        }
                        if (!support_extended_attributes)
                        {
                            r = try_thrice(() => _endpoint.zcl_request(node.id, ep.endpoint, ep.profile_id, c.cluster_id, ZCLCommand.discover_attributes, 0, req_buffer[0..3], zcl_res, PCP.bk));
                            if (r != ZigbeeResult.success)
                                return fail("discover_attributes failed");
                        }

                        ref ZCLHeader hdr = zcl_res.hdr;
                        msg = zcl_res.message[];
                        if (msg.length < 1)
                            return fail("response too short");
                        bool complete = msg[0] != 0;

                        size_t offset = 1;
                        if (hdr.command == ZCLCommand.discover_attributes_extended_response)
                        {
                            for (; offset + 4 < msg.length; offset += 4)
                            {
                                attr_id = msg[offset..offset + 2][0..2].littleEndianToNative!ushort;
                                ref NodeMap.Attribute attr = c.get_attribute(attr_id);
                                attr.data_type = cast(ZCLDataType)msg[offset + 2];
                                attr.access = cast(ZCLAccess)msg[offset + 3];
                            }
                        }
                        else if (hdr.command == ZCLCommand.discover_attributes_response)
                        {
                            for (; offset + 3 < msg.length; offset += 3)
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

                    // if we have a basic cluster, read basic info here so we have it as early as possible
                    if (!(node.initialised & 0x80) && ep.profile_id == 0x0104 && c.cluster_id == 0)
                    {
                        StringResult result = read_basic_info(node.id, ep, node.basic_info);
                        if (!result)
                            return fail(result.message);
                        node.initialised |= 0x80;
                    }

                    c.initialised |= 0x01;
                }

                ep.initialised |= 0x02;
            }

            node.initialised |= 0x10;
        }

        version (DebugZigbeeController)
        {
            MutableString!0 info;
            foreach (ref ep; node.endpoints.values)
            {
                info.append("    ep ", ep.endpoint, ":\n");
                foreach (ref NodeMap.Cluster c; ep.clusters.values)
                {
                    info.append_format("        cluster {0,x}:", c.cluster_id);
                    foreach (ref NodeMap.Attribute a; c.attributes.values)
                        info.append_format(" {0,x}", a.attribute_id);
                    info ~= "\n";
                }
            }
            writeInfof("ZigbeeController: completed interview for device {0,04x} ({1}) {2} {3}\n{4}", node.id, node.get_fingerprint()[], node.basic_info.product_code[], node.basic_info.product_url[], info[]);
        }

        node.initialised = 0xFF; // fully initialised
        node.scan_in_progress = false;

        return true;
    }

    StringResult read_basic_info(ushort node_id, ref NodeMap.Endpoint ep, out NodeMap.BasicInfo result)
    {
        ZCLResponse zcl_res;
        ubyte[128] req_buffer = void;

        assert(ep.profile_id == 0x0104, "wrong profile");

        if (0 !in ep.clusters)
            return StringResult("endpoint does not have basic cluster");
        ref NodeMap.Cluster basic = ep.clusters[0];

        // read from the basic cluster
        enum ushort[10] basic_attributes = [ 0, 1, 2, 3, 4, 5, 7, 10, 11, 0x4000 ];
        for (size_t i = 0; i < basic_attributes.length; ++i)
            req_buffer[i*2..i*2 + 2][0..2] = basic_attributes[i].nativeToLittleEndian;

        // read basic attributes
        ZigbeeResult r = try_thrice(() => _endpoint.zcl_request(node_id, ep.endpoint, 0x0104, 0, ZCLCommand.read_attributes, 0, req_buffer[0 .. basic_attributes.length*2], zcl_res, PCP.bk));
        if (r != ZigbeeResult.success)
            return StringResult("request failed");
        if (zcl_res.hdr.command == ZCLCommand.default_response)
        {
            if (zcl_res.message[1] != ZCLStatus.unsup_cluster_command)
                return StringResult("default response failure");
            return StringResult.success; // apparently the basic cluster doesn't want to provide any info...? (TODO: should we try another endpoint?)
        }

        const(ubyte)[] msg = zcl_res.message[];
        if (msg.length < basic_attributes.length*3)
            return StringResult("response too short");

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
//                return fail("read attribute fail");
                continue; // also just skip on other errors? or maybe we should bail (maybe we fell off the parsing rails?)
            }

            ref NodeMap.Attribute attr = basic.get_attribute(attr_id);
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
                    case 0:      result.zcl_ver = attr.value.as!ubyte;      break;
                    case 1:      result.app_ver = attr.value.as!ubyte;      break;
                    case 2:      result.stack_ver = attr.value.as!ubyte;    break;
                    case 3:      result.hw_ver = attr.value.as!ubyte;       break;
                    case 7:      result.power_source = cast(ZCLPowerSource)attr.value.as!ubyte;          break;
                    case 4:      result.mfg_name = attr.value.asString.makeString(defaultAllocator);     break;
                    case 5:      result.model_name = attr.value.asString.makeString(defaultAllocator);   break;
                    case 10:     result.product_code = attr.value.asString.makeString(defaultAllocator); break;
                    case 11:     result.product_url = attr.value.asString.makeString(defaultAllocator);  break;
                    case 0x4000: result.sw_build_id = attr.value.asString.makeString(defaultAllocator);  break;
                    default:
                        break;
                }
            }
        }

        return StringResult.success;
    }
}

private:

__gshared immutable ubyte[4] g_power_levels = [ 0, 33, 66, 100 ];

enum TuyaDataType : ubyte
{
    raw = 0,
    bool_ = 1,
    value = 2,
    string = 3,
    enum_ = 4,
    bitmap = 5
}

struct TuyaDP
{
    ubyte dp_id;
    TuyaDataType dp_type;
    const(ubyte)[] dp_data;
}

TuyaDP parse_dp(const(ubyte)[] data)
{
    if (data.length < 5)
        return TuyaDP(0, cast(TuyaDataType)0, null);
    ubyte id = data[0];
    TuyaDataType type = cast(TuyaDataType)data[1];
    ushort len = data[2..4].bigEndianToNative!ushort;
    if (data.length < 4 + len)
        return TuyaDP(0, cast(TuyaDataType)0, null);
    return TuyaDP(id, type, data[4 .. 4 + len]);
}

Variant decode_dp(ref TuyaDP dp)
{
    switch (dp.dp_type)
    {
        case TuyaDataType.raw:
            return Variant(cast(const(void)[])dp.dp_data);
        case TuyaDataType.string:
            return Variant(cast(const(char)[])dp.dp_data);
        case TuyaDataType.bool_:
            return Variant(dp.dp_data[0] != 0);
        case TuyaDataType.value:
            return Variant(dp.dp_data[0..4].bigEndianToNative!uint);
        case TuyaDataType.enum_:
            return Variant(dp.dp_data[0]); // TODO: confirm this one?
        case TuyaDataType.bitmap:
            if (dp.dp_data.length == 1)
                return Variant(dp.dp_data[0]); // TODO: confirm this one?
            else if (dp.dp_data.length == 2)
                return Variant(dp.dp_data[0..2].bigEndianToNative!ushort); // TODO: confirm this one?
            else if (dp.dp_data.length == 4)
                return Variant(dp.dp_data[0..4].bigEndianToNative!uint); // TODO: confirm this one?
            assert(false, "Unexpected Tuya BITMAP length");
        default:
            assert(false, "Unknown Tuya DP type");
    }
}

TuyaDataType type_from_desc(ref const ValueDesc desc)
{
    // TODO: how do we determine a RAW?

    if (desc.is_string)
        return TuyaDataType.string;
    if (desc.is_bitfield)
        return TuyaDataType.bitmap;
    else if (desc.is_enum)
        return TuyaDataType.enum_;
    else if (desc.is_bool)
        return TuyaDataType.bool_;
    else
        return TuyaDataType.value;
}

ptrdiff_t encode_dp(ubyte datapoint, ref const Variant value, ValueDesc desc, ubyte[] buffer)
{
    TuyaDataType type = desc.type_from_desc();

    buffer[0] = datapoint;
    buffer[1] = type;

    if (type == TuyaDataType.string)
    {
        if (!value.isString)
            return -1;
        const(char)[] str = value.asString[];
        if (str.length > 0xFFFF)
            return -1;
        buffer[2..4] = (cast(ushort)str.length).nativeToBigEndian;
        buffer[4..4 + str.length] = cast(ubyte[])str[];
        return 4 + str.length;
    }
    if (!value.isNumber && !value.isBool)
        return -1;

    ptrdiff_t len = buffer[4..$].write_value(value, desc);
    if (len <= 0)
        return -1;
    buffer[2..4] = (cast(ushort)len).nativeToBigEndian;
    return 4 + len;
}

uint get_zigbee_time()
{
    return cast(uint)(getSysTime().unixTimeNs() / 1_000_000_000);
}

ptrdiff_t write_attribute(T)(ubyte[] buffer, const T attribute, ZCLDataType type_override = ZCLDataType.no_data)
{
    static if (is(T E == enum) && T.sizeof <= 2)
        return write_attribute!E(buffer, attribute, E.sizeof == 1 ? ZCLDataType.enum8 : ZCLDataType.enum16);
    else static if (is(T == bool))
        return write_attribute(buffer, ubyte(attribute), type_override == ZCLDataType.no_data ? ZCLDataType.boolean : type_override);
    else static if (is(T == byte))
        return write_attribute(buffer, ubyte(attribute), type_override == ZCLDataType.no_data ? ZCLDataType.int8 : type_override);
    else static if (is(T == short))
        return write_attribute(buffer, ushort(attribute), type_override == ZCLDataType.no_data ? ZCLDataType.int16 : type_override);
    else static if (is(T == int))
        return write_attribute(buffer, uint(attribute), type_override == ZCLDataType.no_data ? ZCLDataType.int32 : type_override);
    else static if (is(T == long))
        return write_attribute(buffer, ulong(attribute), type_override == ZCLDataType.no_data ? ZCLDataType.int64 : type_override);
    else static if (is(T == float))
        return write_attribute(buffer, *cast(uint*)&attribute, ZCLDataType.single_prec_float);
    else static if (is(T == double))
        return write_attribute(buffer, *cast(ulong*)&attribute, ZCLDataType.double_prec_float);
    else static if (is(T == ubyte))
    {
        if (buffer.length < 3)
            return -1;
        buffer[0] = ZCLStatus.success;
        buffer[1] = type_override == ZCLDataType.no_data ? ZCLDataType.uint8 : type_override;
        buffer[2] = attribute;
        return 3;
    }
    else static if (is(T == ushort))
    {
        if (buffer.length < 4)
            return -1;
        buffer[0] = ZCLStatus.success;
        buffer[1] = type_override == ZCLDataType.no_data ? ZCLDataType.uint16 : type_override;
        buffer[2..4] = attribute.nativeToLittleEndian;
        return 4;
    }
    else static if (is(T == uint))
    {
        if (buffer.length < 6)
            return -1;
        buffer[0] = ZCLStatus.success;
        buffer[1] = type_override == ZCLDataType.no_data ? ZCLDataType.uint32 : type_override;
        buffer[2..6] = attribute.nativeToLittleEndian;
        return 6;
    }
    else static if (is(T == ulong))
    {
        if (buffer.length < 10)
            return -1;
        buffer[0] = ZCLStatus.success;
        buffer[1] = type_override == ZCLDataType.no_data ? ZCLDataType.uint64 : type_override;
        buffer[2..10] = attribute.nativeToLittleEndian;
        return 10;
    }
    else static if (is(T == const(ubyte)[]) || is(T == const(void)[]) || is(T : const(char)[]))
    {
        if (buffer.length < 3 + attribute.length + (attribute.length > 0xFF))
            return -1;
        buffer[0] = ZCLStatus.success;
        static if (is(T : const(char)[]))
            buffer[1] = attribute.length <= 0xFF ? ZCLDataType.char_string : ZCLDataType.long_char_string;
        else
            buffer[1] = attribute.length <= 0xFF ? ZCLDataType.octet_string : ZCLDataType.long_octet_string;
        if (attribute.length <= 0xFF)
        {
            buffer[2] = cast(ubyte)attribute.length;
            buffer[3 .. 3 + attribute.length] = cast(const(ubyte)[])attribute;
            return 3 + attribute.length;
        }
        else
        {
            buffer[2..4] = (cast(ushort)attribute.length).nativeToLittleEndian;
            buffer[4 .. 4 + attribute.length] = cast(const(ubyte)[])attribute;
            return 4 + attribute.length;
        }
    }
    else
        static assert(false, "unsupported attribute type");
}
