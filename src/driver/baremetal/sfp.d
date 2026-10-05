module driver.baremetal.sfp;

import urt.driver.ethernet;

static if (num_ethernet > 0)
{

import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager.base;
import manager.collection;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.sfp;
import router.status;

import driver.baremetal.ethernet;

nothrow @nogc:


final class BuiltinSFP : SFPInterface
{
    alias Properties = AliasSeq!(Prop!("device", device),
                                 Prop!("phy", phy),
                                 Prop!("phy-address", phy_address));
nothrow @nogc:

    ~this() {}

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinSFP, id, flags);
        _port.owner = this;
        _port.on_rx = &on_rx;
        _port.on_link = &on_link;
        _port.on_rx_drops = &add_rx_drops;
    }

    String device() const pure => _port.device;
    void device(String value) { set_wiring!"device"(_port.device, value); }

    EthPhy phy() const pure => _port.config.phy;
    void phy(EthPhy value) { set_wiring!"phy"(_port.config.phy, value); }

    byte phy_address() const pure => _port.config.phy_address;
    void phy_address(byte value) { set_wiring!"phy-address"(_port.config.phy_address, value); }

    override void heartbeat(MonoTime now)
    {
        super.heartbeat(now);
        port_service(_port);
    }

protected:

    override bool data_path_valid() const
        => _port.device.length != 0 && port_valid(_port);

    // The module's data is live without a link, so the port runs from attach and signals its link apart.
    override CompletionStatus data_path_up()
    {
        if (const(char)[] error = port_attach(_port))
        {
            log.error(error);
            return CompletionStatus.error;
        }
        set_connected(false);
        MACAddress hardware;
        if (port_address(_port, hardware))
            adopt_mac(hardware);
        set_laser(true);
        return CompletionStatus.complete;
    }

    override bool data_path_down()
    {
        set_laser(false);
        bool first_attempt;
        if (port_detach(_port, first_attempt))
            return true;
        if (first_attempt)
            log.warning("driver refused to uninstall; retrying");
        return false;
    }

    override int wire_send(const(ubyte)[] frame)
        => port_send(_port, frame);

    override const(char)[] apply_mac(ref MACAddress value)
        => port_apply_mac(_port, value);

    override bool carrier() const
        => _port.link_up;

private:
    MacPort _port;

    void set_wiring(string prop, T)(ref T field, T value)
    {
        if (field == value)
        {
            mark_assigned!(typeof(this), prop)();
            return;
        }
        field = value;
        mark_set!(typeof(this), prop)();
        restart();
    }

    void on_rx(const(ubyte)[] frame, MonoTime ts, const(HwTimestamp)* hw, bool checksum_verified)
    {
        incoming_ethernet_frame(frame, ts, 0, 0, hw, checksum_verified);
    }

    void add_rx_drops(uint dropped)
    {
        _status.rx_dropped += dropped;
        mark_set!(typeof(this), "rx-dropped")();
    }

    void set_connected(bool value)
    {
        _status.connected = value ? ConnectionStatus.connected : ConnectionStatus.disconnected;
        mark_set!(typeof(this), "connected")();
        write_status();
    }

    void on_link(EthLinkEvent event)
    {
        _port.link_up = event == EthLinkEvent.up;
        set_connected(_port.link_up);
        EthLinkInfo info;
        if (_port.link_up && port_link_info(_port, info))
            set_link_speed(link_bps(info.speed));
        if (running)
            set_link(_port.link_up);
    }
}

}
