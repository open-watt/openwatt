module router.iface.vlan;

import urt.lifetime;
import urt.mem.temp;
import urt.string;

import manager;
import manager.base;

import router.iface;

nothrow @nogc:


class VLANInterface : BaseInterface
{
    __gshared Property[2] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("vlan", vlan)() ];
nothrow @nogc:

    enum type_name = "vlan";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!VLANInterface, name.move, flags);

        // the super made a mac address, but we don't actually want one...
        remove_address(mac);
        mac = MACAddress();
    }

    // Properties...

    ushort vlan() const
        => _vlan;
    const(char)[] vlan(ushort value)
    {
        if (value < 2 || value > 4094)
            return "invalid vlan id";
        _vlan = value;
        return null;
    }

    inout(BaseInterface) iface() inout pure
        => _interface;
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_interface is value)
            return null;
        if (_interface !is null)
            _interface.bind_vlan(this, true);
        if (!_interface.bind_vlan(this, false))
            return tconcat("interface ", value.name, " of type ", value.type, " does not support vlans");
        _interface = value;
        mac = _interface.mac;
        return null;
    }


    // API...

    override bool validate() const
        => _interface !is null;

    override CompletionStatus validating()
    {
        if (_interface.detached)
        {
            if (BaseInterface s = get_module!InterfaceModule.interfaces.get(_interface.name[]))
            {
                _interface = s;
                mac = _interface.mac;
            }
        }
        return super.validating();
    }

    protected override int transmit(ref Packet packet, MessageCallback)
    {
        assert((packet.vlan & 0xFFF) == 0, "packet already has a vlan tag");
        packet.vlan = _vlan;
        int result = _interface.forward(packet);
        if (result >= 0)
        {
            ++_status.send_packets;
            _status.send_bytes += packet.data.length;
        }
        return result;
    }

package:
    final void vlan_incoming(ref Packet packet)
    {
        assert((packet.vlan & 0xFFF) == _vlan, "received packet for wrong vlan!");
        packet.vlan &= 0xF000; // should we clear the p-bits too?
        dispatch(packet);
    }

private:
    ObjectRef!BaseInterface _interface;
    ushort _vlan;
}
