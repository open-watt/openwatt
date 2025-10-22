module protocol.zigbee.client;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.mem.temp : tstring, tconcat;
import urt.string;

import manager;
import manager.collection;

// TODO: we should move the stuff from here to local protocol definitions...
import protocol.ezsp.commands;

import protocol.zigbee;
import protocol.zigbee.aps;

import router.iface;
import router.iface.packet;
import router.iface.zigbee;

nothrow @nogc:


alias ZigbeeMessageHandler = void delegate(ref const APSFrame header, const(void)[] message) nothrow @nogc;


class ZigbeeEndpoint : BaseObject
{
    __gshared Property[6] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("endpoint", endpoint)(),
                                         Property.create!("profile", profile)(),
                                         Property.create!("device", device)(),
                                         Property.create!("in_clusters", in_clusters)(),
                                         Property.create!("out_clusters", out_clusters)() ];
nothrow @nogc:

    enum TypeName = StringLit!"zigbee-endpoint";

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow
    {
        super(collection_type_info!ZigbeeEndpoint, name.move, flags);
    }

    ~this()
    {
        if (_interface)
        {
            _interface.unsubscribe(&incoming_packet);
            _interface = null;
        }
    }

    // Properties...

    final inout(ZigbeeInterface) iface() inout pure nothrow // TODO: should return zigbee interface?
        => _interface;
    final const(char)[] iface(ZigbeeInterface value) nothrow
    {
        if (!value)
            return "interface cannot be null";
        if (_interface)
        {
            if (_interface is value)
                return null;
            _interface.unsubscribe(&incoming_packet);
        }
        _interface = value;
        _interface.subscribe(&incoming_packet, PacketFilter(type: PacketType.ZigbeeAPS));
        return null;
    }

    final ubyte endpoint() inout pure nothrow
        => _endpoint;
    final const(char)[] endpoint(ubyte value) nothrow
    {
        if (value > 240)
            return "endpoint must be in range 0..240";
        _endpoint = value;
        return null;
    }

    final const(char)[] profile() inout nothrow
    {
        switch (_profile)
        {
            case 0x0000: return "zdo";
            case 0x0101: return "ipm";  // industrial plant monitoring
            case 0x0104: return "ha";   // home assistant
            case 0x0105: return "ba";   // building automation
            case 0x0107: return "ta";   // telco automation
            case 0x0108: return "hc";   // health care
            case 0x0109: return "se";   // smart energy
            case 0xA1E0: return "gp";   // green power
            default:
                return tstring(_profile);
        }
    }
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

    final const(ushort)[] out_clusters() inout pure nothrow
        => _out_clusters[];
    final void out_clusters(const(ushort)[] value) nothrow
    {
        _out_clusters = value;
    }


    // API...

    void set_message_handler(ZigbeeMessageHandler handler)
    {
        _message_handler = handler;
    }

    bool send_message(EUI64 eui, ubyte endpoint, ushort profile_id, ushort cluster_id, const(void)[] message)
    {
        return _interface.send(eui, endpoint, _endpoint, profile_id, cluster_id, message);
    }

    override bool validate() const
    {
        if (!_interface)
            return false;
        if (_endpoint == 0)
            return _device == 0 && _profile == 0;
        else
            return _profile != 0;
    }

    override void update()
    {
        // nothing to do here maybe? I think it's all event driven...
    }

private:
    ZigbeeInterface _interface;
    ubyte _endpoint;

    ushort _profile, _device;
    Array!ushort _in_clusters, _out_clusters;

    ZigbeeMessageHandler _message_handler;

    void incoming_packet(ref const Packet p, BaseInterface iface, PacketDirection dir, void* user_data) nothrow @nogc
    {
        // TODO: we should enhance the PACKET FILTER to do this work!
        ref aps = p.hdr!APSFrame;
        if (aps.dst_endpoint != _endpoint && aps.dst_endpoint != 0xFF)
            return;
        if (aps.profile_id != _profile)
            return;

        if (_message_handler)
            _message_handler(p.hdr!APSFrame, p.data[]);
    }
}
