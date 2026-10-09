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


final class VLANInterface : EthernetStation
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("vlan", vlan),
                                 Prop!("tag", tag));
nothrow @nogc:

    ~this() {}

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
    const(char)[] tag(VlanTag value)
    {
        if (value == VlanTag.none)
            return "invalid vlan tag";
        if (value == _tag)
            return null;
        _tag = value;
        mark_set!(typeof(this), "tag")();
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
        unsubscribe_parent();
        _interface = value;
        if (auto station = dyn_cast!EthernetStation(value))
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

protected:

    override ushort l2_header() const pure
        => on_ethernet ? 14 : 0;

    override bool validate() const
        => _interface !is null && _vlan != 0 && _tag != VlanTag.none;

    override CompletionStatus startup()
    {
        auto result = super.startup();
        if (result != CompletionStatus.complete)
            return result;
        take_parent_limits();
        if (!_subscribed)
        {
            if (auto station = dyn_cast!EthernetStation(_interface.get))
            {
                adopt_parent_mac(station);
                station.prop_element(prop_index!(EthernetStation, "mac")).subscribe(&parent_mac_changed);
            }
            _interface.subscribe(&parent_state_change);
            _subscribed = true;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_parent();
        return super.shutdown();
    }

    override bool carrier() const
    {
        const(BaseInterface) i = _interface.get;
        return i && i.link_up;
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
        debug assert(packet.vid == 0 && packet.vlan_tag == VlanTag.none, "packet already has a vlan tag");
        packet.vlan = (packet.vlan & 0xF000) | (_vlan & 0xFFF);
        packet.vlan_tag = _tag;

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
        if (!admit(packet, callback))
            return -1;

        debug assert(packet.vid == 0 && packet.vlan_tag == VlanTag.none, "packet already has a vlan tag");
        packet.vlan = (packet.vlan & 0xF000) | (_vlan & 0xFFF);
        packet.vlan_tag = _tag;

        fire_subscribers(packet, PacketDirection.outgoing);

        int result = _interface.forward(packet, callback, queue_policy);
        if (result >= 0)
            add_tx_frame(packet.data.length);
        return result;
    }

package:
    final void vlan_incoming(ref Packet packet)
    {
        assert(packet.vid == _vlan, "received packet for wrong vlan!");
        assert(packet.vlan_tag == VlanTag.none || packet.vlan_tag == _tag, "received packet with wrong vlan tag!");
        packet.consume_vlan_tag();
        incoming_packet(packet);
    }

private:
    ObjectRef!BaseInterface _interface;
    ushort _vlan;
    VlanTag _tag = VlanTag._8100;
    bool _subscribed;

    // a tag rides only in an ethernet header (a port or a bridge); on any other parent the vlan is a decap of its pvid
    bool on_ethernet() const pure
        => dyn_cast!EthernetStation(_interface.get) !is null;

    // an unlimited parent stays unlimited
    ushort inside_tag(ushort size) const pure
        => on_ethernet && size != ushort.max ? cast(ushort)(size - 4) : size;

    // a parent settles its capacity as it comes up (a CPC handshake, a renegotiation), so it is taken again then
    void take_parent_limits()
        => set_l2mtu(inside_tag(_interface.l2mtu), inside_tag(_interface.max_l2mtu));

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
        if (auto station = dyn_cast!EthernetStation(_interface.get))
            adopt_parent_mac(station);
    }

    void parent_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.destroyed)
            restart();
        else if (signal == StateSignal.online)
            take_parent_limits();
        else if (running && (signal == StateSignal.link_up || signal == StateSignal.link_down))
            set_link(signal == StateSignal.link_up);
    }

    void unsubscribe_parent()
    {
        if (!_subscribed)
            return;
        if (auto station = dyn_cast!EthernetStation(_interface.get))
            station.prop_element(prop_index!(EthernetStation, "mac")).unsubscribe(&parent_mac_changed);
        _interface.unsubscribe(&parent_state_change);
        _subscribed = false;
    }
}
