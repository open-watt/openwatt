module protocol.ip.address;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;

import router.iface;

nothrow @nogc:

class IPAddress : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("address", address)(),
                                         Property.create!("interface", iface)() ];
nothrow @nogc:

    enum type_name = "ip-address";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPAddress, name.move, flags);
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

    protected override CompletionStatus validating() nothrow @nogc
    {
        if (_iface.detached)
        {
            if (BaseInterface s = get_module!InterfaceModule.interfaces.get(_iface.name))
                _iface = s;
        }
        return super.validating();
    }

private:
    IPNetworkAddress _address;
    ObjectRef!BaseInterface _iface;
}
