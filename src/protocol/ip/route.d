module protocol.ip.route;

import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;

import router.iface;

nothrow @nogc:


class IPRoute : BaseObject
{
    __gshared Property[5] Properties = [ Property.create!("destination", destination)(),
                                         Property.create!("gateway", gateway)(),
                                         Property.create!("out-interface", out_interface)(),
                                         Property.create!("blackhole", blackhole)(),
                                         Property.create!("distance", distance)()];
nothrow @nogc:

    enum type_name = "ip-route";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPRoute, name.move, flags);
    }

    // Properties
    IPNetworkAddress destination() const pure
        => _destination;
    void destination(IPNetworkAddress value)
    {
        _destination = IPNetworkAddress(value.get_network, value.prefix_len);
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
        return null;
    }

    bool blackhole() const pure
        => _blackhole;
    void blackhole(bool value)
    {
        _blackhole = value;
    }

    ubyte distance() const pure
    {
        return _distance;
    }
    void distance(bool value)
    {
        _distance = value;
    }

    override bool validate() const pure nothrow @nogc
        => _blackhole || _iface !is null || _gateway != IPAddr.any;

    protected override CompletionStatus validating() nothrow @nogc
    {
        if (_iface.detached)
        {
            if (BaseInterface s = get_module!InterfaceModule.interfaces.get(_iface.name[]))
                _iface = s;
        }
        return super.validating();
    }

private:
    IPNetworkAddress _destination;
    IPAddr _gateway;
    ObjectRef!BaseInterface _iface;
    bool _blackhole;
    ubyte _distance;
}
