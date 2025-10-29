module protocol.zigbee.controller;

 import urt.lifetime;
import urt.result;
import urt.string;

import manager.base;
import manager.collection;

import protocol.zigbee;
import protocol.zigbee.aps;
import protocol.zigbee.client;
import protocol.zigbee.zcl;
import protocol.zigbee.zdo;

import router.iface.mac;

nothrow @nogc:


class ZigbeeController : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("endpoint", endpoint)() ];
nothrow @nogc:

    enum TypeName = StringLit!"zigbee-controller";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!ZigbeeController, name.move, flags);
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

    // API...

    bool send_message(ushort id, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message, bool group = false)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_message(id, endpoint, profile_id, cluster_id, message, group);
    }

    bool send_message(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        if (!running || !_endpoint)
            return false;
        return _endpoint.send_message(eui, endpoint, profile_id, cluster_id, message);
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
        return _endpoint.running ? CompletionStatus.Complete : CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update() nothrow
    {
        // we need to populate our database of devices with detail...
    }

private:

    struct Device
    {
        ushort id;
        // identifier details
        // device type, capabilities, etc...
    }

    ObjectRef!ZigbeeEndpoint _endpoint;

    void message_handler(ref const APSFrame aps, const(void)[] message)
    {
        if (message.length < ZCLHeader.sizeof)
            return;

        ZCLHeader zcl;
        ptrdiff_t bytes = message.decode_zcl_header(zcl);
        if (bytes < 0)
            return;
        message = message[bytes..$]; // get the payload...

        // TODO: parse ZCL
        switch (zcl.command)
        {
            case ZCLCommand.read_attributes:
                break;
            case ZCLCommand.write_attributes:
                break;
            case ZCLCommand.configure_reporting:
                break;
            case ZCLCommand.read_reporting_configuration:
                break;
            case ZCLCommand.report_attributes:
                break;
            case ZCLCommand.default_response:
                break;
            case ZCLCommand.discover_attributes:
                break;
            default:
                break;
        }

        // send default response
        if (zcl.control & ZCLControlFlags.disable_default_response)
            return; // no default response requested

        ubyte[5] response;
        response[3] = zcl.command;    // command
        response[4] = 0;              // status

        zcl.command = ZCLCommand.default_response;
        zcl.control = ZCLControlFlags.response | ZCLControlFlags.disable_default_response;
        ptrdiff_t offset = zcl.format_zcl_header(response);
        assert(offset == 3, "ZCL default response header should be 3 bytes!");

        send_message(aps.src, aps.src_endpoint, aps.profile_id, aps.cluster_id, response[]);
    }
}
