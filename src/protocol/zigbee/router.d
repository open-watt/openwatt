module protocol.zigbee.router;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;

import manager;
import manager.collection;

import protocol.ezsp.client;
import protocol.zigbee;
import protocol.zigbee.client;
import protocol.zigbee.aps;
import protocol.zigbee.zdo;

import router.iface.packet;

version = DebugZigbee;

nothrow @nogc:


class ZigbeeRouter : ZigbeeNode
{
    __gshared Property[2] Properties = [ Property.create!("pan-eui", _pan_eui)(),
                                         Property.create!("pan-id", _pan_id)() ];
nothrow @nogc:

    alias TypeName = StringLit!"zb-router";

    this(String name, ObjectFlags flags = ObjectFlags.none)
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

    this(const(CollectionTypeInfo)* type_info, String name, ObjectFlags flags)
    {
        super(type_info, name.move, flags);

        get_module!ZigbeeProtocolModule.nodes.add(this);
    }

    override bool validate() const pure
        => super.validate() && zigbee_iface() !is null;

    override CompletionStatus startup()
    {
        CompletionStatus s = super.startup();
        if (s != CompletionStatus.complete)
            return s;

        // router startup?

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
        => super.shutdown();

    final inout(EZSPClient) get_ezsp() inout pure
    {
        if (auto i = zigbee_iface())
            return i.ezsp_client;
        return null;
    }

    void subscribe_client(EZSPClient client, bool subscribe)
    {
        client.set_callback_handler!EZSP_IdConflictHandler(subscribe ? &id_conflict_handler : null);
        client.set_callback_handler!EZSP_IncomingRouteErrorHandler(subscribe ? &incoming_route_error_handler : null);
        client.set_callback_handler!EZSP_PollHandler(subscribe ? &poll_handler : null);
    }

    final void id_conflict_handler(EmberNodeId id)
    {
        // TODO: this is called when the NCP detects multiple nodes using the same id
        //       the stack will remove references to this id, and we should also remove the ID from our records
        assert(false, "TODO");
    }

    final void incoming_route_error_handler(EmberStatus status, EmberNodeId target)
    {
        // TODO: this is called when a route error message is received.
        //       the error indicates that a problem routing to or from the target node was encountered.
        version (DebugZigbee)
            writeInfof("Zigbee Router: incoming route error from target {0,04x} - status: {1}", target, status);
    }

    final void poll_handler(EmberNodeId childId, bool transmitExpected)
    {
        version (DebugZigbee)
            writeInfof("Zigbee Router: receive poll request from {0,04x} - transmit_expected: {1}", childId, transmitExpected);
    }


    override bool handle_zdo_frame(ref const APSFrame aps, ref const Packet p)
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
                NodeMap* n = get_module!ZigbeeProtocolModule.find_node(addr);
                if (!n)
                    return true; // we don't know the guy we're being asked about

                assert(req_data[9] == 0, "TODO: only supporting single address requests for now");

                buffer[0] = req_data[0]; // sequence
                buffer[1] = ZDOStatus.success;
                buffer[2..10] = n.eui.b[]; // is this meant to be little-endian?
                buffer[10..12] = n.id.nativeToLittleEndian!ushort;
                send_zdo_message(aps.src, aps.cluster_id | 0x8000, buffer[0..12]);
                return true;

            case device_annce:
                const ubyte[] data = cast(ubyte[])p.data[];
                ubyte seq = data[0];
                ushort id = data[1..3].littleEndianToNative!ushort;
                EUI64 eui = EUI64(data[3..11]);
                ubyte caps = data[11];

                assert(eui != EUI64.broadcast, "TODO: node EUI is not valid... we're meant to do something with this?");

                ZigbeeProtocolModule mod_zb = get_module!ZigbeeProtocolModule;

                auto n = mod_zb.attach_node(eui, _network_params.pan_id, id);

                n.desc.mac_capabilities = caps;
                NodeType type;
                if (caps & 0x02) // fully-functional device
                    type = (caps & 0x01) ? NodeType.coordinator : NodeType.router;
                else // reduced-functionality device
                    type = (caps & 0x08) ? NodeType.end_device : NodeType.sleepy_end_device;

                // TODO: save the power source (0x04) and security caps (0x40) somewhere?

                if (n.desc.type != NodeType.unknown && n.desc.type != type)
                {
                    version (DebugZigbee)
                        writeInfof("Zigbee: device announce: {0, 04x} [{1}] - type changed: old={2}, new={3} ({4,02x})", id, eui, n.desc.type, type, caps);
                }
                else version (DebugZigbee)
                    writeInfof("Zigbee: device announce: {0, 04x} [{1}] - type={2}", id, eui, type);
                n.desc.type = type;
                break;

            default:
                return super.handle_zdo_frame(aps, p);
        }
        return false;
    }
}
