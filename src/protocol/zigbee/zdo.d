module protocol.zigbee.zdo;

import urt.endian;

import protocol.zigbee;

nothrow @nogc:

//
// ZDO spec here: https://zigbeealliance.org/wp-content/uploads/2019/11/docs-05-3474-21-0csg-zigbee-specification.pdf
//

enum ZDOCluster : ushort
{
    // Device and Service Discovery Client Services
    nwk_addr_req = 0x0000,
    ieee_addr_req = 0x0001,
    node_desc_req = 0x0002,
    power_desc_req = 0x0003,
    simple_desc_req = 0x0004,
    active_ep_req = 0x0005,
    match_desc_req = 0x0006,
    device_annce = 0x0013,
    parent_annce = 0x001F,
    system_server_discovery_req = 0x0015,

    // Bind, Unbind, and Bind Management Client Services Primitives
    bind_req = 0x0021,
    unbind_req = 0x0022,
    clear_all_bindings_req = 0x002B,

    // Network Management Client Services
    mgmt_lqi_req = 0x0031,
    mgmt_rtg_req = 0x0032,
    mgmt_bind_req = 0x0033,
    mgmt_leave_req = 0x0034,
    mgmt_permit_joining_req = 0x0036,
    mgmt_nwk_update_req = 0x0038,
    mgmt_nwk_enhanced_update_req = 0x0039,
    mgmt_nwk_ieee_joining_list_req = 0x003A,
    mgmt_nwk_beacon_survey_req = 0x003C,

    // Deprecated clusters:
    complex_desc_req = 0x0010,
    user_desc_req = 0x0011,
    discovery_cache_req = 0x0012,
    user_desc_set_req = 0x0014,
    discovery_store_req = 0x0016,
    node_desc_store_req = 0x0017,
    power_desc_store_req = 0x0018,
    active_ep_store_req = 0x0019,
    simple_desc_store_req = 0x001A,
    remove_node_cache_req = 0x001B,
    find_node_cache_req = 0x001C,
    extended_simple_desc_req = 0x001D,
    extended_active_ep_req = 0x001E,

    end_device_bind_req = 0x0020,
    bind_register_req = 0x0023,
    replace_device_req = 0x0024,
    store_bkup_bind_entry_req = 0x0025,
    remove_bkup_bind_entry_req = 0x0026,
    backup_bind_table_req = 0x0027,
    recover_bind_table_req = 0x0028,
    backup_source_bind_req = 0x0029,
    recover_source_bind_req = 0x002A,

    mgmt_nwk_disc_req = 0x0030,
    mgmt_direct_join_req = 0x0035,
    mgmt_cache_req = 0x0037,
}

enum ZDOStatus : ubyte
{
    success = 0x00,             // The operation was successful.
    inv_requesttype = 0x80,     // The supplied request type was invalid.
    device_not_found = 0x81,    // The requested device did not exist on a device following a child descriptor request to a parent.
    invalid_ep = 0x82,          // The supplied endpoint was equal to 0x00 or between 0xF1 and 0xFF.
    not_active = 0x83,          // The requested endpoint is not described by a Simple descriptor.
    not_supported = 0x84,       // The requested optional feature is not supported on the target device.
    timeout = 0x85,             // A timeout has occurred with the requested operation.
    no_match = 0x86,            // The End Device bind request was unsuccessful due to a failure to match any suitable clusters.
    no_entry = 0x88,            // The unbind request was unsuccessful due to the Co- ordinator or source device not having an entry in its binding table to unbind.
    no_descriptor = 0x89,       // A child descriptor was not available following a discovery request to a parent.
    insufficient_space = 0x8A,  // The device does not have storage space to support the requested operation.
    not_permitted = 0x8B,       // The device is not in the proper state to support the requested operation.
    table_full = 0x8C,          // The device does not have table space to support the operation.
    not_authorized = 0x8D       // The permissions configuration table on the target indicates that the request is not authorized from this device.
}

enum ZDOServerCapability : ubyte
{
    primary_trust = 0x01,
    secondary_trust = 0x02,
    primary_binding = 0x04,
    secondary_binding = 0x08,
    primary_discovery_cache = 0x10,
    secondary_discovery_cache = 0x20,
    network_manager = 0x40,

    mask = 0x7F
}

enum ZDOFrequencyBand : ubyte
{
    band_868MHz = 0x01,
    band_902MHz = 0x04,
    band_2400MHz = 0x08
}

enum ZDOMACCaps : ubyte
{
    alternate_pan_coordinator = 0x01,
    device_type = 0x02,
    power_source = 0x04,
    receiver_on_when_idle = 0x08,
    security_capable = 0x40,
    allocate_address = 0x80
}


bool parse_node_desc(const(ubyte)[] message, NodeMap* node)
{
    if (message.length < 15)
        return false;
    if (message[0..2].littleEndianToNative!ushort != node.id)
        return false;

    ubyte type = message[2] & 0x07;
    node.desc.freq_bands = message[3] >> 3;
    node.desc.mac_capabilities = message[4];
    NodeType new_type;
    if (type == 0)
        new_type = NodeType.coordinator;
    else if (type == 1)
        new_type = NodeType.router;
    else
    {
//        if (node.desc.mac_capabilities == 0x80) // HACK: lots of Tuya devices only report this 'allocate address' flag
//            new_type = NodeType.router;         //       ...and apparently that means they're a router?
//        else
        assert((node.desc.mac_capabilities & 0x2) == 0, "FFD flag, but not a router? the information is in conflict... who do we trust?");

        if (node.desc.mac_capabilities & 0x08) // receiver-on-while-idle
            new_type = NodeType.end_device;
        else
            new_type = NodeType.sleepy_end_device;
    }
    if (node.desc.type != NodeType.unknown && node.desc.type != new_type)
    {
        import urt.log;
        log_debugf("zigbee", "node {0, 04x} type mismatch: old = {1}, new = {2}", node.id, node.desc.type, new_type);
    }
    node.desc.type = new_type;
    node.desc.manufacturer_code = message[5..7].littleEndianToNative!ushort;
    ushort server_mask = message[10..12].littleEndianToNative!ushort;
    node.desc.server_capabilities = server_mask & ZDOServerCapability.mask;
    node.desc.stack_compliance_revision = server_mask >> 9;
    node.desc.max_nsdu = message[7];
    node.desc.max_asdu_in = message[8..10].littleEndianToNative!ushort;
    node.desc.max_asdu_out = message[12..14].littleEndianToNative!ushort;
    node.desc.complex_desc = (message[2] & 0x08) != 0;
    node.desc.user_desc = (message[2] & 0x10) != 0;
    node.desc.extended_active_ep_list = (message[14] & 0x01) != 0;
    node.desc.extended_simple_desc_list = (message[14] & 0x02) != 0;

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

    node.initialised |= 0x01;

    return true;
}
