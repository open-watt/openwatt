module router.iface.vlan;

import urt.lifetime;
import urt.mem.temp;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.element : SampleUpdate;

import router.iface;
import router.iface.ethernet;

nothrow @nogc:


enum VlanTag : ushort
{
    _8100 = 0x8100, // standard 802.1Q customer tag
    _88a8 = 0x88a8, // 802.1ad provider/service tag
    _9100 = 0x9100, // legacy Cisco-style Q-in-Q
    _9200 = 0x9200, // alternate legacy Q-in-Q
    _9300 = 0x9300, // another legacy Q-in-Q variant
}


class VLANInterface : EthernetStation
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("vlan", vlan),
                                 Prop!("tag", tag));
nothrow @nogc:

    enum type_name = "vlan";
    enum path = "/interface/vlan";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!VLANInterface, id, flags);

        adopt_mac(MACAddress());
    }

    // Properties...

    ushort vlan() const
        => _vlan;
    const(char)[] vlan(ushort value)
    {
        if (value < 2 || value > 4094)
            return "invalid vlan id";
        if (value == _vlan)
            return null;
        if (_interface !is null && _vlan != 0)
            _interface.bind_vlan(this, true);
        _vlan = value;
        if (_interface !is null)
            _interface.bind_vlan(this, false);
        mark_set!(typeof(this), "vlan")();
        return null;
    }

    VlanTag tag() const
        => _tag;
    void tag(VlanTag value)
    {
        _tag = value;
        mark_set!(typeof(this), "tag")();
    }

    inout(BaseInterface) iface() inout pure
        => _interface;
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_interface is value)
            return null;
        if (_interface !is null && _vlan != 0)
            _interface.bind_vlan(this, true);
        if (_vlan != 0)
        {
            if (!value.bind_vlan(this, false))
            {
                if (_interface !is null)
                    _interface.bind_vlan(this, false);
                return tconcat("interface ", value.name, " of type ", value.type, " does not support vlans");
            }
        }
        unsubscribe_parent_mac();
        _interface = value;
        if (auto station = cast(EthernetStation)value)
            adopt_parent_mac(station);
        else
            adopt_mac(MACAddress());
        mark_set!(typeof(this), "interface")();
        restart();
        return null;
    }


    // API...

    override void abort(int msg_handle, MessageState reason = MessageState.aborted)
    {
        _interface.abort(msg_handle, reason);
    }

    override MessageState msg_state(int msg_handle) const
    {
        return _interface.msg_state(msg_handle);
    }

    override bool can_forward_ethernet_sources() const pure
    {
        const(BaseInterface) parent = _interface.get;
        return parent && parent.can_forward_ethernet_sources();
    }

    override bool can_assist_ethernet_sources() const
    {
        const(BaseInterface) parent = _interface.get;
        return parent && parent.can_assist_ethernet_sources();
    }

protected:

    override bool validate() const
        => _interface !is null && _vlan != 0;

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;
        if (!_mac_subscribed)
        {
            if (auto station = cast(EthernetStation)_interface.get)
            {
                adopt_parent_mac(station);
                station.prop_element(prop_index!(EthernetStation, "mac")).subscribe(&parent_mac_changed);
                _mac_subscribed = true;
            }
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_parent_mac();
        return super.shutdown();
    }

    override void online()
    {
        super.online();

        // later changes arrive by push from the parent's set_link_speed
        if (BaseInterface i = _interface)
            set_link_speed(i.tx_link_speed, i.rx_link_speed);
    }

    override const(char)[] apply_mac(ref MACAddress value)
        => "vlan address is inherited from its parent";

    final override void medium_tx(ref Packet packet)
    {
        debug assert((packet.vlan & 0xFFF) == 0, "packet already has a vlan tag");
        packet.vlan = (packet.vlan & 0xF000) | (_vlan & 0xFFF);

        if (_interface.forward(packet) < 0)
            add_tx_drop();
        else
            add_tx_frame(packet.data.length);
    }

    // override forward() instead of transmit() for the ethernet path, to pass the
    // callback through to the parent without double firing; exotic packets route
    // through the inherited station egress.
    final override int forward(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
    {
        if (packet.type != PacketType.ethernet)
            return super.forward(packet, callback, queue_policy);

        if (!running)
        {
            if (callback)
                callback(-1, MessageState.failed);
            return -1;
        }

        debug assert((packet.vlan & 0xFFF) == 0, "packet already has a vlan tag");
        packet.vlan = (packet.vlan & 0xF000) | (_vlan & 0xFFF);

        foreach (ref sub; _subscribers[0 .. _num_subscribers])
        {
            if ((sub.filter.direction & PacketDirection.outgoing) && sub.filter.match(packet))
                sub.recv_packet(packet, this, PacketDirection.outgoing, sub.user_data);
        }

        int result = _interface.forward(packet, callback, queue_policy);
        if (result >= 0)
            add_tx_frame(packet.data.length);
        return result;
    }

package:
    final void vlan_incoming(ref Packet packet)
    {
        assert((packet.vlan & 0xFFF) == _vlan, "received packet for wrong vlan!");
        packet.vlan &= 0xF000; // should we clear the p-bits too?
        incoming_packet(packet);
    }

private:
    ObjectRef!BaseInterface _interface;
    ushort _vlan;
    VlanTag _tag = VlanTag._8100;
    bool _mac_subscribed;

    void adopt_parent_mac(EthernetStation station)
    {
        if (mac == station.mac)
            return;
        bool rebound = _interface !is null && _vlan != 0;
        if (rebound)
            _interface.bind_vlan(this, true);
        adopt_mac(station.mac);
        if (rebound)
            _interface.bind_vlan(this, false);
    }

    void parent_mac_changed(ref const SampleUpdate)
    {
        if (auto station = cast(EthernetStation)_interface.get)
            adopt_parent_mac(station);
    }

    void unsubscribe_parent_mac()
    {
        if (!_mac_subscribed)
            return;
        if (auto station = cast(EthernetStation)_interface.get)
            station.prop_element(prop_index!(EthernetStation, "mac")).unsubscribe(&parent_mac_changed);
        _mac_subscribed = false;
    }
}
