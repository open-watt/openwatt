module protocol.ip.route;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import router.iface;

nothrow @nogc:


class IPRoute : BaseObject
{
    alias Properties = AliasSeq!(Prop!("destination", destination),
                                 Prop!("gateway", gateway),
                                 Prop!("out-interface", out_interface),
                                 Prop!("blackhole", blackhole),
                                 Prop!("distance", distance));
nothrow @nogc:

    enum type_name = "ip-route";
    enum path = "/protocol/ip/route";
    enum collection_id = CollectionType.ip_route;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPRoute, id, flags);
    }

    // Properties
    IPNetworkAddress destination() const pure
        => _destination;
    void destination(IPNetworkAddress value)
    {
        _destination = IPNetworkAddress(value.get_network, value.prefix_len);
        mark_set!(typeof(this), "destination")();
    }

    IPAddr gateway() const pure
        => _gateway;
    const(char)[] gateway(IPAddr value)
    {
        if (value != IPAddr.any)
            return "gateway cannot be 0.0.0.0";
        _iface = null;
        _gateway = value;
        _blackhole = false;
        mark_set!(typeof(this), "gateway")();
        mark_set!(typeof(this), "out-interface")();
        mark_set!(typeof(this), "blackhole")();
        return null;
    }

    inout(BaseInterface) out_interface() inout pure
        => _iface;
    const(char)[] out_interface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_iface is value)
            return null;
        _gateway = IPAddr();
        _iface = value;
        _blackhole = false;
        mark_set!(typeof(this), "gateway")();
        mark_set!(typeof(this), "out-interface")();
        mark_set!(typeof(this), "blackhole")();
        return null;
    }

    bool blackhole() const pure
        => _blackhole;
    void blackhole(bool value)
    {
        _blackhole = value;
        mark_set!(typeof(this), "blackhole")();
    }

    ubyte distance() const pure
    {
        return _distance;
    }
    void distance(bool value)
    {
        _distance = value;
        mark_set!(typeof(this), "distance")();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure nothrow @nogc
        => _blackhole || _iface !is null || _gateway != IPAddr.any;

private:
    IPNetworkAddress _destination;
    IPAddr _gateway;
    ObjectRef!BaseInterface _iface;
    bool _blackhole;
    ubyte _distance;
}
