module protocol.ip.address;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import protocol.ip.stack : bump_route_generation;

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
    mixin RekeyHandler;

    override bool validate() const pure nothrow @nogc
        => _iface !is null;

private:
    IPNetworkAddress _address;
    ObjectRef!BaseInterface _iface;
}
