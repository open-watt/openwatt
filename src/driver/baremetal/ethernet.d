module driver.baremetal.ethernet;

import urt.driver.ethernet;

static if (num_ethernet > 0)
{

import urt.atomic;
import urt.log;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;
import router.status;

nothrow @nogc:


final class BuiltinEthernet : EthernetInterface
{
nothrow @nogc:

    enum type_name = "ether";
    enum path = "/interface/ethernet";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BuiltinEthernet, id, flags);
        _max_l2mtu = 1500;
        _l2mtu = _max_l2mtu;
        _port.owner = this;
        _port.on_rx = &on_rx;
        _port.on_link = &on_link;
        _port.on_rx_drops = &add_rx_drops;
    }

    final String device() const pure
        => _port.device;
    final void device(String value) { set_wiring!"device"(_port.device, value); }

    final ubyte port() const pure
        => _port.port;
    final void port(ubyte value) { set_wiring!"port"(_port.port, value); }

    final EthPhy phy() const pure
        => _port.config.phy;
    final void phy(EthPhy value) { set_wiring!"phy"(_port.config.phy, value); }

    final byte phy_address() const pure
        => _port.config.phy_address;
    final void phy_address(byte value) { set_wiring!"phy-address"(_port.config.phy_address, value); }

    final byte mdc_gpio() const pure
        => _port.config.mdc_gpio;
    final void mdc_gpio(byte value) { set_wiring!"mdc-gpio"(_port.config.mdc_gpio, value); }

    final byte mdio_gpio() const pure
        => _port.config.mdio_gpio;
    final void mdio_gpio(byte value) { set_wiring!"mdio-gpio"(_port.config.mdio_gpio, value); }

    final byte phy_reset_gpio() const pure
        => _port.config.phy_reset_gpio;
    final void phy_reset_gpio(byte value) { set_wiring!"phy-reset-gpio"(_port.config.phy_reset_gpio, value); }

    final EthClockMode clock_mode() const pure
        => _port.config.clock_mode;
    final void clock_mode(EthClockMode value) { set_wiring!"clock-mode"(_port.config.clock_mode, value); }

    final byte clock_gpio() const pure
        => _port.config.clock_gpio;
    final void clock_gpio(byte value) { set_wiring!"clock-gpio"(_port.config.clock_gpio, value); }

    static if (has_eth_pin_select)
    {
        final byte tx_en_gpio() const pure
            => _port.config.data_gpio[0];
        final void tx_en_gpio(byte value) { set_wiring!"tx-en-gpio"(_port.config.data_gpio[0], value); }

        final byte txd0_gpio() const pure
            => _port.config.data_gpio[1];
        final void txd0_gpio(byte value) { set_wiring!"txd0-gpio"(_port.config.data_gpio[1], value); }

        final byte txd1_gpio() const pure
            => _port.config.data_gpio[2];
        final void txd1_gpio(byte value) { set_wiring!"txd1-gpio"(_port.config.data_gpio[2], value); }

        final byte crs_dv_gpio() const pure
            => _port.config.data_gpio[3];
        final void crs_dv_gpio(byte value) { set_wiring!"crs-dv-gpio"(_port.config.data_gpio[3], value); }

        final byte rxd0_gpio() const pure
            => _port.config.data_gpio[4];
        final void rxd0_gpio(byte value) { set_wiring!"rxd0-gpio"(_port.config.data_gpio[4], value); }

        final byte rxd1_gpio() const pure
            => _port.config.data_gpio[5];
        final void rxd1_gpio(byte value) { set_wiring!"rxd1-gpio"(_port.config.data_gpio[5], value); }

        final byte clock_loopback_gpio() const pure
            => _port.config.clock_loopback_gpio;
        final void clock_loopback_gpio(byte value) { set_wiring!"clock-loopback-gpio"(_port.config.clock_loopback_gpio, value); }

        final bool hw_timestamp() const pure
            => _port.config.timestamp;
        final void hw_timestamp(bool value) { set_wiring!"hw-timestamp"(_port.config.timestamp, value); }
    }

    final bool promiscuous() const pure
        => _port.config.promiscuous;
    final void promiscuous(bool value)
    {
        _port.config.promiscuous = value;
        mark_set!(typeof(this), "promiscuous")();
        if (_port.eth.is_open && eth_set_promiscuous(_port.eth, value).failed)
            log.warning("set promiscuous failed");
    }

    final bool flow_control() const pure
        => _port.config.flow_control;
    final void flow_control(bool value) { set_wiring!"flow-control"(_port.config.flow_control, value); }

    static if (has_eth_tx_checksum)
    {
        final bool tx_checksum() const pure
            => _port.config.tx_checksum;
        final void tx_checksum(bool value) { set_wiring!"tx-checksum"(_port.config.tx_checksum, value); }
    }

    final bool auto_negotiate() const pure
        => _port.auto_negotiate;
    final void auto_negotiate(bool value)
    {
        _port.auto_negotiate = value;
        mark_set!(typeof(this), "auto-negotiate")();
        apply_link_mode();
    }

    final EthSpeed speed() const pure
        => _port.speed;
    final void speed(EthSpeed value)
    {
        _port.speed = value;
        _port.auto_negotiate = false;
        mark_set!(typeof(this), [ "speed", "auto-negotiate" ])();
        apply_link_mode();
    }

    final bool full_duplex() const pure
        => _port.full_duplex;
    final void full_duplex(bool value)
    {
        _port.full_duplex = value;
        _port.auto_negotiate = false;
        mark_set!(typeof(this), [ "full-duplex", "auto-negotiate" ])();
        apply_link_mode();
    }

    alias CommonProperties = AliasSeq!(Prop!("device", device),
                                       Prop!("port", port),
                                       Prop!("phy", phy),
                                       Prop!("phy-address", phy_address),
                                       Prop!("mdc-gpio", mdc_gpio),
                                       Prop!("mdio-gpio", mdio_gpio),
                                       Prop!("phy-reset-gpio", phy_reset_gpio),
                                       Prop!("clock-mode", clock_mode),
                                       Prop!("clock-gpio", clock_gpio),
                                       Prop!("promiscuous", promiscuous),
                                       Prop!("flow-control", flow_control),
                                       Prop!("speed", speed),
                                       Prop!("full-duplex", full_duplex),
                                       Prop!("auto-negotiate", auto_negotiate),
                                       Prop!("duplex", duplex, "status"));
    static if (has_eth_pin_select)
        alias PinSelectProperties = AliasSeq!(Prop!("tx-en-gpio", tx_en_gpio),
                                              Prop!("txd0-gpio", txd0_gpio),
                                              Prop!("txd1-gpio", txd1_gpio),
                                              Prop!("crs-dv-gpio", crs_dv_gpio),
                                              Prop!("rxd0-gpio", rxd0_gpio),
                                              Prop!("rxd1-gpio", rxd1_gpio),
                                              Prop!("clock-loopback-gpio", clock_loopback_gpio),
                                              Prop!("hw-timestamp", hw_timestamp));
    else
        alias PinSelectProperties = AliasSeq!();
    static if (has_eth_tx_checksum)
        alias TxChecksumProperties = AliasSeq!(Prop!("tx-checksum", tx_checksum));
    else
        alias TxChecksumProperties = AliasSeq!();
    alias Properties = AliasSeq!(CommonProperties, PinSelectProperties, TxChecksumProperties);

    final Duplex duplex() const pure
        => _duplex;

    override const(char)[] status_message() const
    {
        if (_port.eth.is_open && !_port.link_up)
            return "Cable unplugged";
        return super.status_message();
    }

    // TODO: say why; an unknown device or a port the MAC does not have fails silently.
    override bool validate() const
        => port_valid(_port);

    override void heartbeat(MonoTime now)
    {
        super.heartbeat(now);
        port_service(_port);
    }

protected:

    override CompletionStatus startup()
    {
        if (!_port.eth.is_open)
        {
            if (const(char)[] error = port_attach(_port))
            {
                log.error(error);
                return CompletionStatus.error;
            }
            set_connected(false);
            _caps &= ~(InterfaceCaps.hw_timestamp | InterfaceCaps.tx_checksum);
            if (_port.config.timestamp)
                _caps |= InterfaceCaps.hw_timestamp;
            if (_port.config.tx_checksum)
                _caps |= InterfaceCaps.tx_checksum;
            mark_set!(typeof(this), "caps")();

            ubyte[6] hw = void;
            if (_port.assigned_mac != MACAddress.init)
            {
                if (eth_set_address(_port.eth, _port.assigned_mac.b).failed)
                    log.warning("driver rejected hardware address");
            }
            else if (port_hardware_address(_port, hw))
                adopt_mac(MACAddress(hw));

            if (!_port.auto_negotiate)
                apply_link_mode();
        }
        port_service(_port);
        return _port.link_up ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        bool first_attempt;
        if (!port_detach(_port, first_attempt))
        {
            if (first_attempt)
                log.warning("driver refused to uninstall; retrying");
            return CompletionStatus.continue_;
        }
        return super.shutdown();
    }

    override const(char)[] apply_mac(ref MACAddress value)
    {
        if (value == MACAddress.init || value.is_multicast)
            return "not a valid unicast hardware address";
        if (_port.eth.is_open && eth_set_address(_port.eth, value.b).failed)
            return "hardware address rejected by driver";
        _port.assigned_mac = value;
        return null;
    }

    override int wire_send(const(ubyte)[] frame)
        => port_send(_port, frame);

    static if (has_eth_tx_checksum)
    {
        override bool mac_completes_checksum(const(ubyte)[] frame)
            => _port.eth.is_open && eth_checksum_insertable(_port.eth, frame);

        override int wire_send_checksum(const(ubyte)[] frame)
            => _port.eth.is_open && eth_tx(_port.eth, frame, true) ? 0 : -1;
    }

private:
    MacPort _port;
    Duplex _duplex = Duplex.unknown;

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

    void apply_link_mode()
    {
        if (!port_apply_link_mode(_port))
            log.warning("set link mode failed");
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
        if (_port.link_up)
        {
            EthLinkInfo info;
            if (port_link_info(_port, info))
            {
                set_duplex(info.full_duplex ? Duplex.full : Duplex.half);
                set_link_speed(link_bps(info.speed));
                log.info("link up: ", info.speed == EthSpeed.s10m ? "10M" : info.speed == EthSpeed.s100m ? "100M" : "1000M", info.full_duplex ? " full duplex" : " half duplex");
            }
        }
        else
        {
            set_duplex(Duplex.unknown);
            if (running)
                restart();
        }
    }

    void set_duplex(Duplex value)
    {
        _duplex = value;
        mark_set!(typeof(this), "duplex")();
    }
}


// One front port of a built-in MAC, for any interface class that owns one.
struct MacPort
{
nothrow @nogc:
    EthernetInterface owner;
    void delegate(const(ubyte)[] frame, MonoTime ts, const(HwTimestamp)* hw, bool checksum_verified) nothrow @nogc on_rx;
    void delegate(EthLinkEvent) nothrow @nogc on_link;
    void delegate(uint dropped) nothrow @nogc on_rx_drops;
    EthPort eth;
    EthernetConfig config;
    String device;
    MACAddress assigned_mac;
    ubyte port;
    EthSpeed speed = EthSpeed.s100m;
    bool auto_negotiate = true;
    bool full_duplex = true;
    bool link_up;
    bool close_refused;

    static if (has_eth_timestamp)
    {
        MonoTime mono_sample;
        EthTime mac_sample;
    }
}

// Unnamed means the first MAC, so single-MAC boards need no device property.
ubyte port_resolve(ref const MacPort p)
{
    if (!p.device)
        return 0;
    foreach (mac; 0 .. num_ethernet)
    {
        if (eth_name(cast(ubyte)mac) == p.device[])
            return cast(ubyte)mac;
    }
    return ubyte.max;
}

bool port_valid(ref const MacPort p)
{
    immutable mac = port_resolve(p);
    return mac < num_ethernet && p.port < eth_ports(mac);
}

const(char)[] port_attach(ref MacPort p)
{
    if (eth_open(p.eth, port_resolve(p), p.port, p.config, &rx_thunk, &link_thunk, &p).failed)
        return "ethernet MAC or PHY init failed";
    eth_set_ready_callback(&request_service);
    return null;
}

bool port_detach(ref MacPort p, out bool first_attempt)
{
    if (p.eth.is_open)
    {
        first_attempt = !p.close_refused;
        if (eth_close(p.eth).failed)
        {
            p.close_refused = true;
            return false;
        }
    }
    p.close_refused = false;
    p.link_up = false;
    return true;
}

bool port_hardware_address(ref const MacPort p, ref ubyte[6] hw)
    => eth_get_hardware_address(p.eth.mac, p.eth.port, hw).succeeded;

int port_send(ref MacPort p, const(ubyte)[] frame)
    => p.eth.is_open && eth_tx(p.eth, frame) ? 0 : -1;

bool port_apply_link_mode(ref MacPort p)
    => !p.eth.is_open || eth_set_link_mode(p.eth, p.auto_negotiate, p.speed, p.full_duplex).succeeded;

bool port_link_info(ref MacPort p, ref EthLinkInfo info)
    => eth_get_link(p.eth, info).succeeded;

ulong link_bps(EthSpeed speed)
    => speed == EthSpeed.s10m ? 10_000_000 : speed == EthSpeed.s100m ? 100_000_000 : 1_000_000_000;

void port_service(ref MacPort p)
{
    if (!p.eth.is_open)
        return;
    if (eth_service(p.eth.mac))
        request_service();
    uint dropped = eth_take_rx_drops(p.eth);
    if (dropped != 0)
        p.on_rx_drops(dropped);
}


final class BuiltinEthernetModule : Module
{
    mixin DeclareModule!"interface.ethernet.builtin";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!BuiltinEthernet();
    }
}


private:

__gshared shared(uint) _service_pending;

// may run on the esp_eth receive task
void request_service()
{
    if (g_app is null || !cas(&_service_pending, 0u, 1u))
        return;
    bool queued;
    g_app.post_event_from_isr(&_service_sweep.event, EventPriority.bulk, queued);
    if (!queued)
        atomicStore!(MemoryOrder.release)(_service_pending, 0u);
}

// a posted event cannot be recalled, so it must not retain an interface that may be destroyed before it runs
struct ServiceSweep
{
    void event(MonoTime) nothrow @nogc
    {
        atomicStore!(MemoryOrder.release)(_service_pending, 0u);
        foreach (mac; 0 .. num_ethernet)
        {
            if (eth_service(cast(ubyte)mac))
                request_service();
        }
    }
}
__gshared ServiceSweep _service_sweep;

void rx_thunk(void* context, const(ubyte)[] frame, ref const EthRxInfo info)
{
    auto p = cast(MacPort*)context;
    if (!p.owner.running)
        return;
    HwTimestamp hw = HwTimestamp(info.timestamp.seconds, info.timestamp.nanoseconds);
    p.on_rx(frame, receive_time(*p, info), info.has_timestamp ? &hw : null, info.checksum_verified);
}

void link_thunk(void* context, EthLinkEvent event)
{
    (cast(MacPort*)context).on_link(event);
}

// The MAC clock and MonoTime run off the same crystal, so one paired sample, taken at the first
// stamp newer than the last one, places every stamp in the batch on the MonoTime line without
// drift between them.
MonoTime receive_time(ref MacPort p, ref const EthRxInfo info)
{
    static if (has_eth_timestamp)
    {
        if (info.has_timestamp)
        {
            long age = stamp_age(p, info.timestamp);
            if (age < 0 && eth_get_time(p.eth.mac, p.mac_sample))
            {
                p.mono_sample = getTime();
                age = stamp_age(p, info.timestamp);
            }
            if (p.mono_sample != MonoTime.init && age >= 0)
                return p.mono_sample - nsecs(age);
        }
    }
    return getTime();
}

static if (has_eth_timestamp)
{
    long stamp_age(ref const MacPort p, ref const EthTime stamp)
        => (long(p.mac_sample.seconds) - stamp.seconds) * 1_000_000_000 + (long(p.mac_sample.nanoseconds) - stamp.nanoseconds);
}

}
