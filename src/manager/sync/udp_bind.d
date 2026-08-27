module manager.sync.udp_bind;

import urt.array;
import urt.inet;
import urt.mem.temp : tconcat;

import manager.base;
import manager.collection;
import manager.features;

import router.iface;
import router.iface.endpoint : foreach_ether_station;
import router.iface.ethernet;
import router.iface.udp;

static if (has_ip)
    import protocol.ip.address : IPAddress;

nothrow @nogc:


enum ushort default_sync_port = 4826;


struct UDPBindEndpoint
{
    ObjectRef!BaseInterface iface;
    InetAddress local;

    bool opEquals(ref const UDPBindEndpoint rhs) const pure nothrow @nogc
        => local == rhs.local && (local.family != AddressFamily.ether || iface == rhs.iface);
}

struct UDPEndpoint
{
    UDPBindEndpoint binding;
    UDPInterface transport;
}

alias UDPBindingConfigure = bool delegate(UDPInterface transport, ref UDPBindEndpoint binding) nothrow @nogc;
alias UDPTransportRemove = void delegate(UDPInterface transport) nothrow @nogc;

struct UDPEndpointHooks
{
    UDPBindingConfigure configure;
    UDPTransportRemove remove;
    InterfaceSubscriber.PacketHandler packet;
}

struct UDPEndpointSet
{
nothrow @nogc:

    Array!UDPEndpoint endpoints;

    bool refresh(BaseObject owner, const(InetAddress)[] bind, const(ObjectRef!BaseInterface)[] interfaces, ushort port, ref UDPEndpointHooks hooks)
    {
        collect_udp_bindings(bind, interfaces, port, _desired);
        size_t i;
        while (i < endpoints.length)
        {
            bool wanted;
            foreach (ref binding; _desired[])
            {
                if (endpoints[i].binding == binding)
                {
                    wanted = true;
                    break;
                }
            }
            if (wanted)
                ++i;
            else
                remove(i, hooks);
        }

        bool created = true;
        foreach (ref binding; _desired[])
            created = ensure(owner, binding, hooks) && created;
        return created;
    }

    void close(ref UDPEndpointHooks hooks)
    {
        while (endpoints.length)
            remove(endpoints.length - 1, hooks);
    }

    bool any_running() const
    {
        foreach (ref endpoint; endpoints[])
            if (endpoint.transport.running)
                return true;
        return false;
    }

private:

    Array!UDPBindEndpoint _desired;
    uint _next_id;

    bool ensure(BaseObject owner, ref UDPBindEndpoint binding, ref UDPEndpointHooks hooks)
    {
        foreach (ref endpoint; endpoints[])
            if (endpoint.binding == binding)
                return true;
        UDPInterface transport = Collection!UDPInterface().create(tconcat(owner.name[], "-endpoint-", ++_next_id), ObjectFlags.dynamic);
        if (!transport)
            return false;
        if (hooks.configure && !hooks.configure(transport, binding))
        {
            transport.destroy();
            return false;
        }
        transport.subscribe(hooks.packet, PacketFilter(PacketType.udp, PacketDirection.incoming));
        endpoints.emplaceBack(binding, transport);
        return true;
    }

    void remove(size_t index, ref UDPEndpointHooks hooks)
    {
        UDPEndpoint endpoint = endpoints[index];
        endpoint.transport.unsubscribe(hooks.packet);
        if (hooks.remove)
            hooks.remove(endpoint.transport);
        endpoint.transport.destroy();
        endpoints.removeSwapLast(index);
    }
}

void replace_udp_bind(ref Array!InetAddress target, const(InetAddress)[] value)
{
    Array!InetAddress updated;
    foreach (address; value)
    {
        bool duplicate;
        foreach (ref existing; updated[])
        {
            if (existing == address)
            {
                duplicate = true;
                break;
            }
        }
        if (!duplicate)
            updated ~= address;
    }
    target = updated.move;
}

void replace_udp_interfaces(ref Array!(ObjectRef!BaseInterface) target, BaseInterface[] value)
{
    Array!(ObjectRef!BaseInterface) updated;
    foreach (interface_; value)
    {
        if (!interface_)
            continue;
        ObjectRef!BaseInterface candidate = interface_;
        bool duplicate;
        foreach (ref existing; updated[])
        {
            if (existing == candidate)
            {
                duplicate = true;
                break;
            }
        }
        if (!duplicate)
            updated.emplaceBack(interface_);
    }
    target = updated.move;
}

void collect_udp_bindings(const(InetAddress)[] bind, const(ObjectRef!BaseInterface)[] interfaces, ushort default_port, ref Array!UDPBindEndpoint result)
{
    result.clear();

    foreach (address; bind)
    {
        InetAddress local = address;
        local.port = bind_port(address, default_port);
        add_binding(result, null, local);
    }

    foreach_ether_station((EthernetStation station)
    {
        if (!station.running)
            return;
        if (interface_selected(station, interfaces))
            add_binding(result, station, InetAddress(station.mac.b, default_port));
    });

    static if (has_ip)
    {
        foreach (configured; Collection!IPAddress().values)
        {
            BaseInterface iface = configured.iface;
            if (!iface || !iface.running || !interface_selected(iface, interfaces))
                continue;
            add_binding(result, iface, InetAddress(configured.address.addr, default_port));
        }
    }
}

ushort bind_port(ref const InetAddress address, ushort default_port) pure
    => address.port ? address.port : default_port;

private:

bool interface_selected(BaseInterface iface, const(ObjectRef!BaseInterface)[] interfaces) pure
{
    ObjectRef!BaseInterface candidate = iface;
    foreach (ref interface_; interfaces)
        if (interface_ == candidate)
            return true;
    return false;
}

void add_binding(ref Array!UDPBindEndpoint result, BaseInterface iface, InetAddress local)
{
    UDPBindEndpoint candidate = UDPBindEndpoint(ObjectRef!BaseInterface(iface), local);
    foreach (ref existing; result[])
        if (existing == candidate)
            return;
    result ~= candidate;
}


version (unittest)
private class TestUDPInterface : UDPInterface
{
nothrow @nogc:

    this(CID id)
    {
        super(id);
    }

    override bool running() const pure
        => online;

    bool online;
}


unittest
{
    import urt.mem;
    import router.iface.bridge : BridgeInterface;

    BridgeInterface first = alloc!BridgeInterface(CID(100));
    BridgeInterface second = alloc!BridgeInterface(CID(101));
    scope(exit)
    {
        free(second);
        free(first);
    }

    InetAddress[3] configured = [InetAddress(IPAddr.any, 0),
                                 InetAddress(IPv6Addr.any, 0),
                                 InetAddress(IPAddr(192, 168, 0, 10), 1234)];
    Array!UDPBindEndpoint bindings;
    const(ObjectRef!BaseInterface)[] no_interfaces;
    collect_udp_bindings(configured[], no_interfaces, 6667, bindings);
    assert(bindings.length == 3);
    assert(bindings[0].local == InetAddress(IPAddr.any, 6667));
    assert(bindings[1].local == InetAddress(IPv6Addr.any, 6667));
    assert(bindings[2].local == InetAddress(IPAddr(192, 168, 0, 10), 1234));

    TestUDPInterface transport_a = alloc!TestUDPInterface(CID(102));
    scope(exit) free(transport_a);
    TestUDPInterface transport_b = alloc!TestUDPInterface(CID(103));
    scope(exit) free(transport_b);
    UDPEndpointSet endpoint_set;
    endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(), transport_a);
    endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(), transport_b);
    assert(!endpoint_set.any_running());
    transport_a.online = true;
    assert(endpoint_set.any_running());
    transport_a.online = false;
    assert(!endpoint_set.any_running());
    transport_b.online = true;
    assert(endpoint_set.any_running());
}
