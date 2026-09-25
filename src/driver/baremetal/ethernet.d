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
    }

    final EthPhy phy() const pure => _config.phy;
    final void phy(EthPhy value) { set_wiring!"phy"(_config.phy, value); }

    final byte phy_address() const pure => _config.phy_address;
    final void phy_address(byte value) { set_wiring!"phy-address"(_config.phy_address, value); }

    final byte mdc_gpio() const pure => _config.mdc_gpio;
    final void mdc_gpio(byte value) { set_wiring!"mdc-gpio"(_config.mdc_gpio, value); }

    final byte mdio_gpio() const pure => _config.mdio_gpio;
    final void mdio_gpio(byte value) { set_wiring!"mdio-gpio"(_config.mdio_gpio, value); }

    final byte phy_reset_gpio() const pure => _config.phy_reset_gpio;
    final void phy_reset_gpio(byte value) { set_wiring!"phy-reset-gpio"(_config.phy_reset_gpio, value); }

    final EthClockMode clock_mode() const pure => _config.clock_mode;
    final void clock_mode(EthClockMode value) { set_wiring!"clock-mode"(_config.clock_mode, value); }

    final byte clock_gpio() const pure => _config.clock_gpio;
    final void clock_gpio(byte value) { set_wiring!"clock-gpio"(_config.clock_gpio, value); }

    static if (has_eth_pin_select)
    {
        final byte tx_en_gpio() const pure => _config.data_gpio[0];
        final void tx_en_gpio(byte value) { set_wiring!"tx-en-gpio"(_config.data_gpio[0], value); }

        final byte txd0_gpio() const pure => _config.data_gpio[1];
        final void txd0_gpio(byte value) { set_wiring!"txd0-gpio"(_config.data_gpio[1], value); }

        final byte txd1_gpio() const pure => _config.data_gpio[2];
        final void txd1_gpio(byte value) { set_wiring!"txd1-gpio"(_config.data_gpio[2], value); }

        final byte crs_dv_gpio() const pure => _config.data_gpio[3];
        final void crs_dv_gpio(byte value) { set_wiring!"crs-dv-gpio"(_config.data_gpio[3], value); }

        final byte rxd0_gpio() const pure => _config.data_gpio[4];
        final void rxd0_gpio(byte value) { set_wiring!"rxd0-gpio"(_config.data_gpio[4], value); }

        final byte rxd1_gpio() const pure => _config.data_gpio[5];
        final void rxd1_gpio(byte value) { set_wiring!"rxd1-gpio"(_config.data_gpio[5], value); }

        final byte clock_loopback_gpio() const pure => _config.clock_loopback_gpio;
        final void clock_loopback_gpio(byte value) { set_wiring!"clock-loopback-gpio"(_config.clock_loopback_gpio, value); }

        final bool hw_timestamp() const pure => _config.timestamp;
        final void hw_timestamp(bool value) { set_wiring!"hw-timestamp"(_config.timestamp, value); }
    }

    final bool promiscuous() const pure => _config.promiscuous;
    final void promiscuous(bool value)
    {
        _config.promiscuous = value;
        mark_set!(typeof(this), "promiscuous")();
        if (_eth.is_open && eth_set_promiscuous(_eth, value).failed)
            log.warning("set promiscuous failed");
    }

    final bool flow_control() const pure => _config.flow_control;
    final void flow_control(bool value) { set_wiring!"flow-control"(_config.flow_control, value); }

    static if (has_eth_tx_checksum)
    {
        final bool tx_checksum() const pure => _config.tx_checksum;
        final void tx_checksum(bool value) { set_wiring!"tx-checksum"(_config.tx_checksum, value); }
    }

    final bool auto_negotiate() const pure => _auto_negotiate;
    final void auto_negotiate(bool value)
    {
        _auto_negotiate = value;
        mark_set!(typeof(this), "auto-negotiate")();
        apply_link_mode();
    }

    final EthSpeed speed() const pure => _speed;
    final void speed(EthSpeed value)
    {
        _speed = value;
        _auto_negotiate = false;
        mark_set!(typeof(this), [ "speed", "auto-negotiate" ])();
        apply_link_mode();
    }

    final bool full_duplex() const pure => _full_duplex;
    final void full_duplex(bool value)
    {
        _full_duplex = value;
        _auto_negotiate = false;
        mark_set!(typeof(this), [ "full-duplex", "auto-negotiate" ])();
        apply_link_mode();
    }

    final String device() const pure => _device;
    final void device(String value) { set_wiring!"device"(_device, value); }

    final byte switch_port() const pure => _switch_port;
    final void switch_port(byte value) { set_wiring!"switch-port"(_switch_port, value); }

    alias CommonProperties = AliasSeq!(Prop!("device", device),
                                       Prop!("switch-port", switch_port),
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

    final Duplex duplex() const pure => _duplex;

    override const(char)[] status_message() const
    {
        if (_eth.is_open && !_link_up)
            return "Cable unplugged";
        return super.status_message();
    }

    // A MAC that fronts a switch is not an interface itself; each front port is.
    // TODO: say why; an unknown device or a missing switch-port fails silently.
    override bool validate() const
    {
        immutable port = resolve_port();
        if (port >= num_ethernet)
            return false;
        immutable ports = eth_switch_ports(port);
        return ports ? _switch_port >= 0 && _switch_port < ports : _switch_port < 0;
    }

    override void heartbeat(MonoTime now)
    {
        super.heartbeat(now);
        if (_eth.is_open)
            service_port(_eth.port);
    }

protected:

    override CompletionStatus startup()
    {
        if (!_eth.is_open)
        {
            immutable port = resolve_port();
            if (slot(port) !is null)
            {
                log.error("another interface already drives this port");
                return CompletionStatus.error;
            }
            if (_users[port] == 0)
            {
                if (eth_open(_shared[port], port, _config).failed)
                {
                    log.error("ethernet MAC or PHY init failed");
                    return CompletionStatus.error;
                }
                eth_set_rx_callback(_shared[port], &rx_dispatch);
                eth_set_link_callback(_shared[port], &link_dispatch);
                if (eth_switch_ports(port))
                    eth_set_switch_link_callback(_shared[port], &switch_link_dispatch);
                eth_set_ready_callback(&request_service);
            }
            ++_users[port];
            _eth = _shared[port];
            slot(port) = this;
            if (is_switch_port && eth_switch_port_enable(_eth, cast(ubyte)_switch_port, true).failed)
                log.warning("switch rejected the port");
            set_connected(false);
            _caps &= ~(InterfaceCaps.hw_timestamp | InterfaceCaps.tx_checksum);
            if (_config.timestamp)
                _caps |= InterfaceCaps.hw_timestamp;
            if (_config.tx_checksum)
                _caps |= InterfaceCaps.tx_checksum;
            mark_set!(typeof(this), "caps")();

            ubyte[6] hw = void;
            if (_assigned_mac != MACAddress.init)
            {
                if (eth_set_address(_eth, _assigned_mac.b).failed)
                    log.warning("driver rejected hardware address");
            }
            else if (eth_get_hardware_address(port, hw))
            {
                if (is_switch_port)
                    offset_mac(hw, _switch_port);
                adopt_mac(MACAddress(hw));
            }

            if (!_auto_negotiate)
                apply_link_mode();
        }
        service_port(_eth.port);
        return _link_up ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_eth.is_open)
        {
            immutable port = _eth.port;
            bool first_attempt = slot(port) is this;
            if (first_attempt)
            {
                slot(port) = null;
                if (is_switch_port)
                    eth_switch_port_enable(_eth, cast(ubyte)_switch_port, false);
            }
            if (_users[port] == 1)
            {
                eth_set_ready_callback(null);
                if (eth_close(_shared[port]).failed)
                {
                    if (first_attempt)
                        log.warning("driver refused to uninstall; retrying");
                    return CompletionStatus.continue_;
                }
            }
            --_users[port];
            _eth = EthMac.init;
        }
        _link_up = false;
        return super.shutdown();
    }

    override const(char)[] apply_mac(ref MACAddress value)
    {
        if (value == MACAddress.init || value.is_multicast)
            return "not a valid unicast hardware address";
        if (_eth.is_open && eth_set_address(_eth, value.b).failed)
            return "hardware address rejected by driver";
        _assigned_mac = value;
        return null;
    }

    override int wire_send(const(ubyte)[] frame)
    {
        if (!_eth.is_open)
            return -1;
        if (is_switch_port)
            return eth_tx_switch(_eth, frame, cast(ubyte)_switch_port) ? 0 : -1;
        return eth_tx(_eth, frame) ? 0 : -1;
    }

    static if (has_eth_tx_checksum)
    {
        override bool mac_completes_checksum(const(ubyte)[] frame)
            => _eth.is_open && eth_checksum_insertable(_eth, frame);

        override int wire_send_checksum(const(ubyte)[] frame)
            => _eth.is_open && eth_tx(_eth, frame, true) ? 0 : -1;
    }

private:
    enum uint max_switch_ports = 8;

    EthMac _eth;
    EthernetConfig _config;
    String _device;
    byte _switch_port = -1;
    MACAddress _assigned_mac;
    EthSpeed _speed = EthSpeed.s100m;
    bool _auto_negotiate = true;
    bool _full_duplex = true;
    bool _link_up;
    Duplex _duplex = Duplex.unknown;

    __gshared EthMac[num_ethernet] _shared;
    __gshared uint[num_ethernet] _users;
    __gshared BuiltinEthernet[num_ethernet] _active;
    __gshared BuiltinEthernet[max_switch_ports][num_ethernet] _switch_active;
    __gshared shared(uint) _service_pending;

    bool is_switch_port() const pure => _switch_port >= 0;

    // Unnamed means the first MAC, so single-MAC boards need no device property.
    ubyte resolve_port() const
    {
        if (!_device)
            return 0;
        foreach (p; 0 .. num_ethernet)
        {
            if (eth_name(cast(ubyte)p) == _device[])
                return cast(ubyte)p;
        }
        return ubyte.max;
    }

    ref BuiltinEthernet slot(ubyte port)
        => is_switch_port ? _switch_active[port][_switch_port] : _active[port];

    static void offset_mac(ref ubyte[6] mac, uint by)
    {
        uint low = (mac[3] << 16 | mac[4] << 8 | mac[5]) + by;
        mac[3] = cast(ubyte)(low >> 16);
        mac[4] = cast(ubyte)(low >> 8);
        mac[5] = cast(ubyte)low;
    }

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
        if (_eth.is_open && eth_set_link_mode(_eth, _auto_negotiate, _speed, _full_duplex).failed)
            log.warning("set link mode failed");
    }

    // One service pass drains the MAC for every interface on it.
    static void service_port(ubyte port)
    {
        if (_users[port] == 0)
            return;
        BuiltinEthernet plain = _active[port];
        static if (has_eth_timestamp)
        {
            if (plain !is null)
                plain.sample_clocks();
        }
        if (eth_service(_shared[port]))
            request_service();
        uint dropped = eth_take_rx_drops(_shared[port]);
        // TODO: a switch-fronting MAC has no plain interface, so its drops are counted nowhere.
        if (dropped != 0 && plain !is null)
            plain.add_rx_drops(dropped);
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
        _link_up = event == EthLinkEvent.up;
        set_connected(_link_up);
        if (_link_up)
        {
            EthLinkInfo info;
            if (is_switch_port ? eth_get_switch_link(_eth, cast(ubyte)_switch_port, info).succeeded : eth_get_link(_eth, info).succeeded)
            {
                set_duplex(info.full_duplex ? Duplex.full : Duplex.half);
                set_link_speed(info.speed == EthSpeed.s10m ? 10_000_000 : info.speed == EthSpeed.s100m ? 100_000_000 : 1_000_000_000);
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

    // may run on the esp_eth receive task
    static void request_service()
    {
        if (g_app is null || !cas(&_service_pending, 0u, 1u))
            return;
        bool queued;
        g_app.post_event_from_isr(&_service_sweep.event, EventPriority.bulk, queued);
        if (!queued)
            atomicStore!(MemoryOrder.release)(_service_pending, 0u);
    }

    // a posted event cannot be recalled, so it must not retain an interface that may be destroyed before it runs
    static struct ServiceSweep
    {
        void event(MonoTime) nothrow @nogc
        {
            atomicStore!(MemoryOrder.release)(_service_pending, 0u);
            foreach (p; 0 .. num_ethernet)
                service_port(cast(ubyte)p);
        }
    }
    __gshared ServiceSweep _service_sweep;

    static void rx_dispatch(EthMac eth, const(ubyte)[] frame, ref const EthRxInfo info)
    {
        if (eth.port >= num_ethernet)
            return;
        BuiltinEthernet iface;
        if (info.switch_port == ubyte.max)
            iface = _active[eth.port];
        else if (info.switch_port < max_switch_ports)
            iface = _switch_active[eth.port][info.switch_port];
        if (iface is null || !iface.running)
            return;
        HwTimestamp hw = HwTimestamp(info.timestamp.seconds, info.timestamp.nanoseconds);
        iface.incoming_ethernet_frame(frame, iface.receive_time(info), 0, 0, info.has_timestamp ? &hw : null, info.checksum_verified);
    }

    // The MAC clock and MonoTime run off the same crystal, so one paired sample per service
    // pass places every stamp in the batch on the MonoTime line without drift between them.
    static if (has_eth_timestamp)
    {
        MonoTime _mono_sample;
        EthTime _mac_sample;

        void sample_clocks()
        {
            if (_config.timestamp && eth_get_time(_eth, _mac_sample))
                _mono_sample = getTime();
        }
    }

    MonoTime receive_time(ref const EthRxInfo info)
    {
        static if (has_eth_timestamp)
        {
            if (info.has_timestamp && _mono_sample != MonoTime.init)
            {
                long age = (long(_mac_sample.seconds) - info.timestamp.seconds) * 1_000_000_000 + (long(_mac_sample.nanoseconds) - info.timestamp.nanoseconds);
                if (age >= 0)
                    return _mono_sample - nsecs(age);
            }
        }
        return getTime();
    }

    static void link_dispatch(EthMac eth, EthLinkEvent event)
    {
        if (eth.port >= num_ethernet)
            return;
        auto iface = _active[eth.port];
        if (iface !is null)
            iface.on_link(event);
    }

    static void switch_link_dispatch(EthMac eth, ubyte switch_port, EthLinkEvent event)
    {
        if (eth.port >= num_ethernet || switch_port >= max_switch_ports)
            return;
        auto iface = _switch_active[eth.port][switch_port];
        if (iface !is null)
            iface.on_link(event);
    }
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

}
