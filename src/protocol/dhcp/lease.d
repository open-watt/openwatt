module protocol.dhcp.lease;

version (NoGateway) {} else:

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


final class DHCPLease : BaseObject
{
    alias Properties = AliasSeq!(Prop!("address", address),
                                 Prop!("mac", mac),
                                 Prop!("hostname", hostname),
                                 Prop!("expires", expires),
                                 Prop!("pool", pool),
                                 Prop!("declined", declined, "status", "d"));
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

    // wall time for display; the deadline itself is armed on the monotonic clock when set
    SysTime expires() const pure
        => _expires;
    void expires(SysTime value)
    {
        Duration left = value - getSysTime();
        set_expiry(value, getTime() + (left > Duration.zero ? left : Duration.zero));
    }

    inout(IPPool) pool() inout pure
        => _pool;
    void pool(IPPool value)
    {
        _pool = value;
        mark_set!(typeof(this), "pool")();
    }

    // the client reported the address in use elsewhere; the reservation is held in quarantine until expiry
    bool declined() const pure
        => _declined;
    void declined(bool value)
    {
        _declined = value;
        mark_set!(typeof(this), "declined")();
    }

    // the operational deadline, on the monotonic clock
    MonoTime deadline() const pure
        => _deadline;

    void expire_in(Duration d)
        => set_expiry(getSysTime() + d, getTime() + d);

    bool is_static_lease() const pure
        => (_flags & ObjectFlags.dynamic) == 0;

    // the reservation goes back to the pool that made it, whoever destroys the lease
    override void destroy()
    {
        if (_armed)
        {
            g_app.cancel(&expire);
            _armed = false;
        }
        if (IPPool p = _pool.get)
            p.release(_address);
        super.destroy();
    }

protected:

    override bool validate() const pure
        => _address != IPAddr.any && cast(bool)_mac;

private:
    IPAddr _address;
    MACAddress _mac;
    bool _armed;
    bool _declined;
    String _hostname;
    SysTime _expires;
    MonoTime _deadline;
    ObjectRef!IPPool _pool;

    void set_expiry(SysTime wall, MonoTime deadline)
    {
        _expires = wall;
        _deadline = deadline;
        mark_set!(typeof(this), "expires")();
        if (_armed)
        {
            g_app.cancel(&expire);
            _armed = false;
        }
        if (is_static_lease() || !g_app)
            return;
        g_app.schedule(deadline, &expire);
        _armed = true;
    }

    void expire(MonoTime)
    {
        _armed = false;
        destroy();
    }
}
