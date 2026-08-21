module protocol.ip.address;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_ipv6;

import router.iface;

nothrow @nogc:


class IPAddress : BaseObject
{
    alias Properties = AliasSeq!(Prop!("address", address),
                                 Prop!("interface", iface));
nothrow @nogc:

    enum type_name = "ip-address";
    enum path = "/protocol/ip/address";
    enum collection_id = CollectionType.ip_address;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPAddress, id, flags);
    }

    ~this()
    {
        bump_route_generation();
    }

    // Properties
    IPNetworkAddress address() const pure
    {
        return _address;
    }
    const(char)[] address(IPNetworkAddress value)
    {
        _address = value;
        mark_set!(typeof(this), "address")();
        bump_route_generation();
        return null;
    }

    inout(BaseInterface) iface() inout pure
    {
        return _iface;
    }
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_iface is value)
            return null;
        _iface = value;
        mark_set!(typeof(this), "interface")();
        mark_set!(typeof(this), [ "flags" ])();
        bump_route_generation();
        return null;
    }

protected:

    override bool validate() const pure nothrow @nogc
        => _iface !is null;

private:
    IPNetworkAddress _address;
    ObjectRef!BaseInterface _iface;
}


static if (has_ipv6)
class IPv6Address : BaseObject
{
    alias Properties = AliasSeq!(Prop!("address", address),
                                 Prop!("interface", iface));
nothrow @nogc:

    enum type_name = "ipv6-address";
    enum path = "/protocol/ip/address6";
    enum collection_id = CollectionType.ip_address6;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPv6Address, id, flags);
    }

    ~this()
    {
        bump_route_generation();
    }

    // Properties
    IPv6NetworkAddress address() const pure
    {
        return _address;
    }
    const(char)[] address(IPv6NetworkAddress value)
    {
        _address = value;
        mark_set!(typeof(this), "address")();
        bump_route_generation();
        return null;
    }

    inout(BaseInterface) iface() inout pure
    {
        return _iface;
    }
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_iface is value)
            return null;
        _iface = value;
        mark_set!(typeof(this), "interface")();
        mark_set!(typeof(this), [ "flags" ])();
        bump_route_generation();
        return null;
    }

protected:

    override bool validate() const pure nothrow @nogc
        => _iface !is null && _address.addr;

private:
    IPv6NetworkAddress _address;
    ObjectRef!BaseInterface _iface;
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
