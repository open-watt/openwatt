module protocol.ip.address;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import router.iface;

nothrow @nogc:

class IPAddress : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("address", address)(),
                                         Property.create!("interface", iface)() ];
nothrow @nogc:

    enum type_name = "ip-address";
    enum collection_id = CollectionType.ip_address;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPAddress, id, flags);
    }

    // Properties
    IPNetworkAddress address() const pure
    {
        return _address;
    }
    const(char)[] address(IPNetworkAddress value)
    {
        _address = value;
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
        return null;
    }

    override bool validate() const pure nothrow @nogc
        => _iface !is null;

private:
    IPNetworkAddress _address;
    ObjectRef!BaseInterface _iface;
}
