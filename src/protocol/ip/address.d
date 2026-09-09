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


BaseInterface interface_for_address(IPAddr address)
{
    if (!address)
        return null;
    foreach (configured; Collection!IPAddress().values)
        if (configured.address.addr == address)
            return configured.iface;
    return null;
}

bool interface_has_address(BaseInterface iface, IPAddr address)
{
    if (!iface || !address)
        return false;
    foreach (configured; Collection!IPAddress().values)
        if (configured.iface is iface && configured.address.addr == address)
            return true;
    return false;
}

bool is_broadcast_for_interface(BaseInterface iface, IPAddr address)
{
    if (!iface)
        return false;
    if (address == IPAddr.broadcast)
        return true;
    foreach (configured; Collection!IPAddress().values)
    {
        if (configured.iface !is iface)
            continue;
        if (is_broadcast_for_subnet(configured.address, address))
            return true;
    }
    return false;
}

static if (has_ipv6)
BaseInterface interface_for_address6(IPv6Addr address)
{
    if (!address)
        return null;
    foreach (configured; Collection!IPv6Address().values)
        if (configured.address.addr == address)
            return configured.iface;
    return null;
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

bool is_broadcast_for_subnet(IPNetworkAddress subnet, IPAddr address) pure
    => subnet.prefix_len < 31 && (subnet.get_network() | ~subnet.net_mask()) == address;

void bump_route_generation()
{
    version (UseInternalIPStack)
    {
        import protocol.ip.stack : bump = bump_route_generation;
        bump();
    }
}


unittest
{
    assert(is_broadcast_for_subnet(IPNetworkAddress(IPAddr(192, 168, 1, 20), 24), IPAddr(192, 168, 1, 255)));
    assert(!is_broadcast_for_subnet(IPNetworkAddress(IPAddr(192, 168, 1, 20), 24), IPAddr(192, 168, 1, 20)));
    assert(!is_broadcast_for_subnet(IPNetworkAddress(IPAddr(192, 168, 1, 20), 31), IPAddr(192, 168, 1, 21)));
}
