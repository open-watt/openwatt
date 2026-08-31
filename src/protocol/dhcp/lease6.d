module protocol.dhcp.lease6;

version (NoIPv6) {} else:

import urt.inet;
import urt.lifetime;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.ip.pool;

nothrow @nogc:


// One DHCPv6 binding: a host address (prefix-length 128, IA_NA) or a delegated
// prefix (IA_PD). Client identity is the DUID, stored as lowercase hex.
class DHCP6Lease : BaseObject
{
    alias Properties = AliasSeq!(Prop!("address", address),
                                 Prop!("prefix-length", prefix_length),
                                 Prop!("duid", duid),
                                 Prop!("iaid", iaid),
                                 Prop!("hostname", hostname),
                                 Prop!("expires", expires),
                                 Prop!("pool", pool));
nothrow @nogc:

    enum type_name = "dhcp6-lease";
    enum path = "/protocol/dhcp/lease6";
    enum collection_id = CollectionType.dhcp6_lease;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCP6Lease, id, flags);
        _prefix_length = 128;
    }

    // Properties
    IPv6Addr address() const pure
        => _address;
    const(char)[] address(IPv6Addr value)
    {
        if (value == IPv6Addr.any)
            return "address cannot be ::";
        _address = value;
        mark_set!(typeof(this), "address")();
        return null;
    }

    ubyte prefix_length() const pure
        => _prefix_length;
    const(char)[] prefix_length(ubyte value)
    {
        if (value == 0 || value > 128)
            return "prefix-length must be 1-128";
        _prefix_length = value;
        mark_set!(typeof(this), "prefix-length")();
        return null;
    }

    ref const(String) duid() const pure
        => _duid;
    void duid(String value)
    {
        _duid = value.move;
        mark_set!(typeof(this), "duid")();
    }

    uint iaid() const pure
        => _iaid;
    void iaid(uint value)
    {
        _iaid = value;
        mark_set!(typeof(this), "iaid")();
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

    inout(IPv6Pool) pool() inout pure
        => _pool;
    void pool(IPv6Pool value)
    {
        _pool = value;
        mark_set!(typeof(this), "pool")();
    }

    bool is_prefix() const pure
        => _prefix_length < 128;

    bool is_static_lease() const pure
        => (_flags & ObjectFlags.dynamic) == 0;

    bool is_expired(SysTime now) const pure
        => !is_static_lease() && now >= _expires;

protected:

    override bool validate() const pure
        => _address != IPv6Addr.any && !_duid.empty;

private:
    IPv6Addr _address;
    ubyte _prefix_length;
    uint _iaid;
    String _duid;
    String _hostname;
    SysTime _expires;
    ObjectRef!IPv6Pool _pool;
}
