module protocol.ip.route;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_ipv6;

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

    ~this()
    {
        bump_route_generation();
    }

    // Properties
    IPNetworkAddress destination() const pure
        => _destination;
    void destination(IPNetworkAddress value)
    {
        _destination = IPNetworkAddress(value.get_network, value.prefix_len);
        mark_set!(typeof(this), "destination")();
        bump_route_generation();
    }

    IPAddr gateway() const pure
        => _gateway;
    const(char)[] gateway(IPAddr value)
    {
        if (value == IPAddr.any)
            return "gateway cannot be 0.0.0.0";
        _gateway = value;
        _blackhole = false;
        mark_set!(typeof(this), "gateway")();
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
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
        _iface = value;
        _blackhole = false;
        mark_set!(typeof(this), "out-interface")();
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
        return null;
    }

    bool blackhole() const pure
        => _blackhole;
    void blackhole(bool value)
    {
        if (value)
        {
            _gateway = IPAddr();
            _iface = null;
        }
        _blackhole = value;
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
    }

    ubyte distance() const pure
    {
        return _distance;
    }
    void distance(ubyte value)
    {
        _distance = value;
        mark_set!(typeof(this), "distance")();
        bump_route_generation();
    }

protected:

    override bool validate() const pure nothrow @nogc
        => _blackhole || _iface !is null || _gateway != IPAddr.any;

private:
    IPNetworkAddress _destination;
    IPAddr _gateway;
    ObjectRef!BaseInterface _iface;
    bool _blackhole;
    ubyte _distance;
}


static if (has_ipv6)
class IPv6Route : BaseObject
{
    alias Properties = AliasSeq!(Prop!("destination", destination),
                                 Prop!("gateway", gateway),
                                 Prop!("out-interface", out_interface),
                                 Prop!("blackhole", blackhole),
                                 Prop!("distance", distance));
nothrow @nogc:

    enum type_name = "ipv6-route";
    enum path = "/protocol/ip/route6";
    enum collection_id = CollectionType.ip_route6;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPv6Route, id, flags);
    }

    ~this()
    {
        bump_route_generation();
    }

    // Properties
    IPv6NetworkAddress destination() const pure
        => _destination;
    void destination(IPv6NetworkAddress value)
    {
        _destination = IPv6NetworkAddress(value.get_network, value.prefix_len);
        mark_set!(typeof(this), "destination")();
        bump_route_generation();
    }

    IPv6Addr gateway() const pure
        => _gateway;
    const(char)[] gateway(IPv6Addr value)
    {
        if (value == IPv6Addr.any)
            return "gateway cannot be ::";
        _gateway = value;
        _blackhole = false;
        mark_set!(typeof(this), "gateway")();
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
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
        _iface = value;
        _blackhole = false;
        mark_set!(typeof(this), "out-interface")();
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
        return null;
    }

    bool blackhole() const pure
        => _blackhole;
    void blackhole(bool value)
    {
        if (value)
        {
            _gateway = IPv6Addr();
            _iface = null;
        }
        _blackhole = value;
        mark_set!(typeof(this), "blackhole")();
        bump_route_generation();
    }

    ubyte distance() const pure
    {
        return _distance;
    }
    void distance(ubyte value)
    {
        _distance = value;
        mark_set!(typeof(this), "distance")();
        bump_route_generation();
    }

protected:

    override bool validate() const pure nothrow @nogc
        => _blackhole || _iface !is null || _gateway != IPv6Addr.any;

private:
    IPv6NetworkAddress _destination;
    IPv6Addr _gateway;
    ObjectRef!BaseInterface _iface;
    bool _blackhole;
    ubyte _distance;
}


private:

void bump_route_generation()
{
    version (UseInternalIPStack)
    {
        import protocol.ip.stack : bump = bump_route_generation;
        bump();
    }
}
