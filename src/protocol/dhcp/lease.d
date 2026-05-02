module protocol.dhcp.lease;

import urt.inet;
import urt.lifetime;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.ip.pool;

import router.iface.mac;

nothrow @nogc:


class DHCPLease : BaseObject
{
    alias Properties = AliasSeq!(Prop!("address", address),
                                 Prop!("mac", mac),
                                 Prop!("hostname", hostname),
                                 Prop!("expires", expires),
                                 Prop!("pool", pool));
nothrow @nogc:

    enum type_name = "dhcp-lease";
    enum path = "/protocol/dhcp/lease";
    enum collection_id = CollectionType.dhcp_lease;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCPLease, id, flags);
    }

    // Properties
    IPAddr address() const pure
        => _address;
    const(char)[] address(IPAddr value)
    {
        if (value == IPAddr.any)
            return "address cannot be 0.0.0.0";
        _address = value;
        mark_set!(typeof(this), "address")();
        return null;
    }

    MACAddress mac() const pure
        => _mac;
    void mac(MACAddress value)
    {
        _mac = value;
        mark_set!(typeof(this), "mac")();
    }

    ref const(String) hostname() const pure
        => _hostname;
    void hostname(String value)
    {
        _hostname = value.move;
        mark_set!(typeof(this), "hostname")();
    }

    SysTime expires() const pure
        => _expires;
    void expires(SysTime value)
    {
        _expires = value;
        mark_set!(typeof(this), "expires")();
    }

    inout(IPPool) pool() inout pure
        => _pool;
    void pool(IPPool value)
    {
        _pool = value;
        mark_set!(typeof(this), "pool")();
    }

    bool is_static_lease() const pure
        => (_flags & ObjectFlags.dynamic) == 0;

    bool is_expired(SysTime now) const pure
        => !is_static_lease() && now >= _expires;

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _address != IPAddr.any && cast(bool)_mac;

private:
    IPAddr _address;
    MACAddress _mac;
    String _hostname;
    SysTime _expires;
    ObjectRef!IPPool _pool;
}
