module driver.linux.ble;

version (linux):

// BLEInterface backed by the linux kernel bluetooth stack, with no BlueZ
// userspace dependency. The kernel MGMT API (HCI control channel) provides
// adapter enumeration/hotplug, power, LE discovery and advertising; the ATT
// data plane rides per-connection L2CAP sockets (CID 4).
//
// The module owns one global MGMT socket (the same interface bluetoothd
// uses). All sockets are serviced event-driven via driver.linux.fdwatch.
// A running bluetoothd would fight us for the adapter, so interface startup
// refuses while one is detected -- the state machine's backoff retry means
// stopping bluetoothd brings the interface up automatically.

import urt.array;
import urt.endian;
import urt.log;
import urt.map;
import urt.mem.temp;
import urt.string;

import manager;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;

import driver.linux.fdwatch;

import router.iface;
import router.iface.priority_queue;

import protocol.ble.iface;

import urt.internal.sys.posix;

nothrow @nogc:

static if (has_all):


class LinuxBLEInterface : BLEInterface
{
    alias Properties = AliasSeq!(Prop!("hci-index", hci_index));
nothrow @nogc:

    enum type_name = "ble";
    enum path = "/interface/ble";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LinuxBLEInterface, id, flags);
    }

    // Properties...

    final ushort hci_index() const pure
        => _index;
    final void hci_index(ushort value)
    {
        if (_index == value)
            return;
        _index = value;
        restart();
    }

    override const(char)[] status_message() const
    {
        if (_conflict)
            return "BLE adapter is managed by another host (bluetoothd)";
        return super.status_message();
    }

protected:

    override bool validate() const
        => _index != mgmt_index_none;

    override CompletionStatus startup()
    {
        LinuxBLEModule m = get_module!LinuxBLEModule;
        if (!m.mgmt_available)
        {
            log.error("BLE management socket unavailable");
            return CompletionStatus.error;
        }

        _conflict = bluetoothd_running();
        if (_conflict)
        {
            log.warning("bluetoothd is running; refusing to claim hci", _index);
            return CompletionStatus.error;
        }

        CompletionStatus s = super.startup();
        if (s != CompletionStatus.complete)
            return s;

        if (!_info_valid)
        {
            if (!_info_requested)
            {
                _info_requested = true;
                m.cmd_read_info(_index);
            }
            return CompletionStatus.continue_;
        }

        if (!_powered)
        {
            if (!_power_requested)
            {
                _power_requested = true;
                m.cmd_set_powered(_index, true);
            }
            return CompletionStatus.continue_;
        }

        if (!_discovering)
        {
            _discovering = true;
            m.cmd_start_discovery(_index);
        }

        log.info("BLE started on interface '", name, "' (hci", _index, ")");
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_connect_fd >= 0)
        {
            close(_connect_fd);
            _connect_fd = -1;
            _connect_tag = -1;
        }

        LinuxBLEModule m = get_module!LinuxBLEModule;
        if (m.mgmt_available)
        {
            if (_discovering)
                m.cmd_stop_discovery(_index);
            if (_adv_instances.length > 0)
                m.cmd_remove_advertising(_index, 0); // 0 = all instances
        }

        _info_requested = false;
        _power_requested = false;
        _discovering = false;
        _scan_paused = false;
        _addr_types.clear();
        _adv_instances.clear();
        _next_adv_instance = 1;

        CompletionStatus s = super.shutdown();
        fd_watch_changed();
        return s;
    }

    override bool submit_frame(QueuedFrame* frame)
    {
        ref f = frame.packet.hdr!BLEFrame;

        final switch (f.kind)
        {
            case BLEFrameKind.advert:
                switch (f.code)
                {
                    case BLEAdvPDU.adv_ind:
                    case BLEAdvPDU.adv_nonconn_ind:
                    case BLEAdvPDU.adv_scan_ind:
                    case BLEAdvPDU.adv_direct_ind:
                        return submit_advert(frame, f);
                    case BLEAdvPDU.connect_ind:
                        return submit_connect(frame, f);
                    default:
                        return false;
                }

            case BLEFrameKind.control:
                if (f.code == BLEControl.disconnect)
                {
                    auto session = find_session_by_client(f.src);
                    if (session !is null)
                    {
                        log.info("disconnecting from ", session.peer);
                        destroy_session(session);
                    }
                    _queue.complete(frame.tag, MessageState.complete);
                    return true;
                }
                return false;

            case BLEFrameKind.att:
            {
                auto session = find_session_by_client(f.src);
                if (session is null)
                {
                    log.warning("ATT send: no session for ", f.src);
                    return false;
                }

                const(ubyte)[] pdu = cast(const(ubyte)[])frame.packet.data;
                ptrdiff_t n = .send(session_fd(session), pdu.ptr, pdu.length, 0);
                if (n != pdu.length)
                {
                    log.warning("ATT send failed: errno=", last_errno());
                    return false;
                }
                _queue.complete(frame.tag, MessageState.complete);
                return true;
            }
        }
    }

    override void transport_close(BLESession* session)
    {
        if (session.transport != uint.max)
        {
            close(session_fd(session));
            session.transport = uint.max;
            fd_watch_changed();
        }
    }

package:

    ushort _index = mgmt_index_none;
    MACAddress _bdaddr;
    bool _conflict;
    bool _info_valid;
    bool _info_requested;
    bool _powered;
    bool _power_requested;
    bool _discovering;
    bool _scan_paused;

    // pending outbound connection (one at a time, like the builtin backend)
    int _connect_fd = -1;
    int _connect_tag = -1;
    sockaddr_l2 _connect_addr;
    MACAddress _connect_client;
    MACAddress _connect_peer;

    Map!(MACAddress, ubyte) _addr_types; // LE address type by device, learnt from adverts

    enum max_adv_instances = 4; // conservative; kernel exposes the real limit via Read Adv Features
    Map!(MACAddress, ubyte) _adv_instances;
    ubyte _next_adv_instance = 1;

    // socket servicing entry, driven by the fdwatch waiter via the module
    void service_sockets()
    {
        pump_pending_connect();
        pump_sessions();
        cleanup_dead_sessions();
    }

    void append_watch(ref Array!pollfd fds)
    {
        if (_connect_fd >= 0)
            fds ~= pollfd(_connect_fd, POLLOUT);
        foreach (session; _sessions[])
        {
            if (session.active && session.transport != uint.max)
                fds ~= pollfd(session_fd(session), POLLIN);
        }
    }

    void on_controller_info(ref const MgmtControllerInfo info)
    {
        _info_valid = true;
        _powered = (info.current_settings & mgmt_setting_powered) != 0;

        // bdaddr is wire (little-endian) byte order; MAC display order is reversed.
        // NOTE: the interface keeps its generated fabric mac (same policy as
        // ethernet/wifi); the radio address is kept for when we need it.
        _bdaddr = MACAddress(info.bdaddr[5], info.bdaddr[4], info.bdaddr[3],
                             info.bdaddr[2], info.bdaddr[1], info.bdaddr[0]);
    }

    void on_new_settings(uint settings)
    {
        bool powered = (settings & mgmt_setting_powered) != 0;
        if (_powered && !powered && running)
        {
            log.warning("adapter powered off");
            restart();
        }
        _powered = powered;
    }

    void on_discovering(bool discovering)
    {
        // kernel discovery sessions time out; re-arm to scan continuously
        // (unless paused while a connection attempt is in flight)
        if (!discovering && running && _discovering && !_scan_paused)
            get_module!LinuxBLEModule.cmd_start_discovery(_index);
    }

    void on_device_found(ref const MgmtDeviceFound ev, const(ubyte)[] eir)
    {
        if (!running)
            return;
        if (ev.addr_type == 0) // BR/EDR
            return;

        Packet p;
        ref f = p.init!BLEFrame(eir);
        f.src = MACAddress(ev.addr[5], ev.addr[4], ev.addr[3],
                           ev.addr[2], ev.addr[1], ev.addr[0]);
        f.dst = MACAddress.broadcast;

        // remember the LE address type for connectable devices; connecting needs it
        if (!(ev.flags & mgmt_dev_found_not_connectable))
        {
            if (_addr_types.length >= 256)
                _addr_types.clear(); // crude bound; re-learnt from live adverts
            _addr_types[f.src] = ev.addr_type;
        }
        f.kind = BLEFrameKind.advert;
        if (ev.flags & mgmt_dev_found_scan_rsp)
            f.code = BLEAdvPDU.scan_rsp;
        else if (ev.flags & mgmt_dev_found_not_connectable)
            f.code = BLEAdvPDU.adv_nonconn_ind;
        else
            f.code = BLEAdvPDU.adv_ind;
        f.rssi = ev.rssi;

        on_incoming(p);
    }

private:

    int session_fd(const BLESession* session) const pure
        => cast(int)session.transport;

    static ubyte[6] mac_to_bdaddr(MACAddress m) pure
    {
        // bdaddr_t is wire (little-endian) byte order; MAC display order reversed
        ubyte[6] b = [m.b[5], m.b[4], m.b[3], m.b[2], m.b[1], m.b[0]];
        return b;
    }

    bool submit_advert(QueuedFrame* frame, ref BLEFrame f)
    {
        const(ubyte)[] adv_data = cast(const(ubyte)[])frame.packet.data;
        if (adv_data.length > 31)
            return false;

        ubyte instance;
        if (ubyte* pi = f.src in _adv_instances)
            instance = *pi; // re-adding the same instance updates it
        else
        {
            if (_next_adv_instance > max_adv_instances)
            {
                log.warning("out of advertising instances");
                return false;
            }
            instance = _next_adv_instance++;
            _adv_instances[f.src] = instance;
        }

        bool connectable = f.code == BLEAdvPDU.adv_ind || f.code == BLEAdvPDU.adv_direct_ind;
        get_module!LinuxBLEModule.cmd_add_advertising(_index, instance, connectable, adv_data);

        register_adv_source(f.src, f.src);
        _queue.complete(frame.tag, MessageState.complete);
        return true;
    }

    // Active discovery fights LE Create Connection in the kernel; pause the
    // scan while a connection attempt is in flight.
    void pause_scanning()
    {
        if (_scan_paused)
            return;
        _scan_paused = true;
        if (_discovering)
            get_module!LinuxBLEModule.cmd_stop_discovery(_index);
    }

    void resume_scanning()
    {
        if (!_scan_paused)
            return;
        _scan_paused = false;
        if (running && _discovering)
            get_module!LinuxBLEModule.cmd_start_discovery(_index);
    }

    bool submit_connect(QueuedFrame* frame, ref BLEFrame f)
    {
        if (_connect_fd >= 0)
        {
            log.warning("connection already in progress");
            return false;
        }

        int fd = socket(af_bluetooth, sock_seqpacket | sock_nonblock, btproto_l2cap);
        if (fd < 0)
        {
            log.error("L2CAP socket failed: errno=", last_errno());
            return false;
        }

        // bind to this adapter so multi-adapter hosts route correctly
        sockaddr_l2 src;
        src.l2_family = af_bluetooth;
        src.l2_cid = att_cid;
        src.l2_bdaddr = mac_to_bdaddr(_bdaddr);
        src.l2_bdaddr_type = bdaddr_le_public;
        if (bind(fd, &src, sockaddr_l2.sizeof) < 0)
        {
            log.error("L2CAP bind failed: errno=", last_errno());
            close(fd);
            return false;
        }

        // raise the L2CAP rx MTU before connect or the kernel clamps inbound
        // PDUs to the 23-byte default
        ushort rx_mtu = 517;
        setsockopt(fd, sol_bluetooth, bt_rcvmtu, &rx_mtu, rx_mtu.sizeof);

        ubyte* peer_type = f.dst in _addr_types;

        sockaddr_l2 dst;
        dst.l2_family = af_bluetooth;
        dst.l2_cid = att_cid;
        dst.l2_bdaddr = mac_to_bdaddr(f.dst);
        dst.l2_bdaddr_type = peer_type ? *peer_type : bdaddr_le_public;

        int r = connect(fd, &dst, sockaddr_l2.sizeof);
        if (r < 0 && last_errno() != EINPROGRESS_)
        {
            log.error("L2CAP connect failed: errno=", last_errno());
            close(fd);
            return false;
        }

        pause_scanning();

        _connect_fd = fd;
        _connect_tag = frame.tag;
        _connect_addr = dst;
        _connect_client = f.src;
        _connect_peer = f.dst;

        fd_watch_changed();
        return true;
    }

    void pump_pending_connect()
    {
        if (_connect_fd < 0)
            return;

        // re-issuing connect() reports async completion without poll():
        // EISCONN/0 = established, EALREADY/EINPROGRESS = still going
        int r = connect(_connect_fd, &_connect_addr, sockaddr_l2.sizeof);
        int e = r < 0 ? last_errno() : 0;

        if (r == 0 || e == EISCONN_)
        {
            auto session = add_session(_connect_client, _connect_peer, cast(uint)_connect_fd);
            log.info("connected to ", session.peer);
            _queue.complete(cast(ubyte)_connect_tag, MessageState.complete);
            clear_pending_connect();
            resume_scanning();
            fd_watch_changed();
            send_queued_messages();
            return;
        }

        if (e == EALREADY_ || e == EINPROGRESS_ || e == EAGAIN_ || e == EINTR_)
            return;

        log.error("connection to ", _connect_peer, " failed: errno=", e);
        close(_connect_fd);
        _queue.complete(cast(ubyte)_connect_tag, MessageState.failed);
        clear_pending_connect();
        resume_scanning();
        fd_watch_changed();
    }

    void clear_pending_connect()
    {
        _connect_fd = -1;
        _connect_tag = -1;
        _connect_client = MACAddress.init;
        _connect_peer = MACAddress.init;
    }

    void pump_sessions()
    {
        foreach (session; _sessions[])
        {
            if (!session.active || session.transport == uint.max)
                continue;

            while (true)
            {
                ubyte[517] buf = void;
                ptrdiff_t n = recv(session_fd(session), buf.ptr, buf.length, 0);
                if (n > 0)
                {
                    Packet p;
                    ref f = p.init!BLEFrame(buf[0 .. cast(size_t)n]);
                    f.src = session.peer;
                    f.dst = session.client;
                    f.kind = BLEFrameKind.att;
                    f.code = buf[0];
                    on_incoming(p);
                    continue;
                }

                if (n < 0)
                {
                    int e = last_errno();
                    if (e == EAGAIN_ || e == EWOULDBLOCK_ || e == EINTR_)
                        break;
                }

                // orderly close or socket error: connection is gone
                log.info("disconnected from ", session.peer);

                Packet p;
                ref f = p.init!BLEFrame(null);
                f.src = _bd_addr;
                f.dst = session.client;
                f.kind = BLEFrameKind.control;
                f.code = BLEControl.disconnected;
                on_incoming(p);

                session.active = false;
                break;
            }
        }
    }
}


// ---------------------------------------------------------------------------
// Driver module: owns the MGMT socket. Enumerates controllers at startup
// (Read Index List), tracks hotplug (Index Added/Removed events) and keeps
// the LinuxBLEInterface collection in sync, mirroring driver.linux.ethernet.
// ---------------------------------------------------------------------------

class LinuxBLEModule : Module
{
    mixin DeclareModule!"interface.ble";
nothrow @nogc:

    override void pre_init()
    {
        _fd = socket(af_bluetooth, sock_raw, btproto_hci);
        if (_fd < 0)
        {
            log_warning(ModuleName, "no kernel bluetooth support: errno=", last_errno());
            return;
        }

        sockaddr_hci addr;
        addr.hci_family = af_bluetooth;
        addr.hci_dev = hci_dev_none;
        addr.hci_channel = hci_channel_control;
        if (bind(_fd, &addr, sockaddr_hci.sizeof) < 0)
        {
            log_error(ModuleName, "MGMT bind() failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }

        int flags = fcntl(_fd, F_GETFL, 0);
        if (flags < 0 || fcntl(_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            log_error(ModuleName, "fcntl(O_NONBLOCK) failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }

        mgmt_send(MgmtCommand.read_index_list, mgmt_index_none);

        // the fdwatch waiter is the only pump -- there is no tick
        if (!add_fd_watcher(&service_sockets, &collect_fds))
        {
            log_error(ModuleName, "no fd waiter; BLE disabled");
            close(_fd);
            _fd = -1;
        }
    }

    override void init()
    {
        g_app.console.register_collection!LinuxBLEInterface();
    }

    override void deinit()
    {
        remove_fd_watcher(&service_sockets);
        if (_fd >= 0)
        {
            close(_fd);
            _fd = -1;
        }
    }

package:

    bool mgmt_available() const pure
        => _fd >= 0;

    void cmd_read_info(ushort index)
    {
        mgmt_send(MgmtCommand.read_info, index);
    }

    void cmd_set_powered(ushort index, bool on)
    {
        ubyte[1] param = [ on ? 1 : 0 ];
        mgmt_send(MgmtCommand.set_powered, index, param[]);
    }

    void cmd_start_discovery(ushort index)
    {
        ubyte[1] param = [ addr_type_le ];
        mgmt_send(MgmtCommand.start_discovery, index, param[]);
    }

    void cmd_stop_discovery(ushort index)
    {
        ubyte[1] param = [ addr_type_le ];
        mgmt_send(MgmtCommand.stop_discovery, index, param[]);
    }

    void cmd_add_advertising(ushort index, ubyte instance, bool connectable, const(ubyte)[] adv_data)
    {
        debug assert(adv_data.length <= 31);

        ubyte[11 + 31] param = void;
        param[0] = instance;
        uint flags = connectable ? mgmt_adv_flag_connectable : 0;
        param[1 .. 5] = flags.nativeToLittleEndian;
        param[5 .. 9] = 0; // duration + timeout: advertise until removed
        param[9] = cast(ubyte)adv_data.length;
        param[10] = 0;     // no scan response data
        param[11 .. 11 + adv_data.length] = adv_data[];

        mgmt_send(MgmtCommand.add_advertising, index, param[0 .. 11 + adv_data.length]);
    }

    void cmd_remove_advertising(ushort index, ubyte instance)
    {
        ubyte[1] param = [ instance ];
        mgmt_send(MgmtCommand.remove_advertising, index, param[]);
    }

private:

    int _fd = -1;

    // fdwatch hooks: drain everything (main loop), and contribute our fds
    void service_sockets()
    {
        pump_mgmt();
        foreach (iface; Collection!LinuxBLEInterface().values)
            iface.service_sockets();
    }

    void collect_fds(ref Array!pollfd fds)
    {
        if (_fd >= 0)
            fds ~= pollfd(_fd, POLLIN);
        foreach (iface; Collection!LinuxBLEInterface().values)
            iface.append_watch(fds);
    }

    void pump_mgmt()
    {
        if (_fd < 0)
            return;

        ubyte[2048] buf = void;
        while (true)
        {
            ptrdiff_t n = recv(_fd, buf.ptr, buf.length, 0);
            if (n < 0)
            {
                int e = last_errno();
                if (e == EAGAIN_ || e == EWOULDBLOCK_ || e == EINTR_)
                    return;
                log_error(ModuleName, "MGMT recv failed: errno=", e);
                return;
            }
            if (n == 0)
                return;

            dispatch(buf[0 .. cast(size_t)n]);
        }
    }

    bool mgmt_send(ushort opcode, ushort index, const(ubyte)[] params = null)
    {
        debug assert(params.length <= 64);
        ubyte[mgmt_hdr.sizeof + 64] buf = void;
        mgmt_hdr* h = cast(mgmt_hdr*)buf.ptr;
        h.code = opcode;
        h.index = index;
        h.plen = cast(ushort)params.length;
        buf[mgmt_hdr.sizeof .. mgmt_hdr.sizeof + params.length] = params[];

        return send(_fd, buf.ptr, mgmt_hdr.sizeof + params.length, 0) >= 0;
    }

    LinuxBLEInterface find_by_index(ushort index)
    {
        foreach (e; Collection!LinuxBLEInterface().values)
        {
            if (e._index == index)
                return e;
        }
        return null;
    }

    void add_adapter(ushort index)
    {
        if (find_by_index(index) !is null)
            return;

        const(char)[] iface_name = next_iface_name();
        log_info(ModuleName, "Found BLE adapter: hci", index, " (", iface_name, ")");
        // dynamic: we own its lifecycle and rediscover it each boot, so it
        // isn't persisted to config -- only dynamic entries are reaped when
        // their controller disappears.
        auto iface = Collection!LinuxBLEInterface().create(iface_name, ObjectFlags.dynamic);
        iface.hci_index = index;
    }

    void remove_adapter(ushort index)
    {
        LinuxBLEInterface iface = find_by_index(index);
        if (iface is null || !(iface.flags & ObjectFlags.dynamic))
            return;
        log_info(ModuleName, "BLE adapter gone: hci", index);
        Collection!LinuxBLEInterface().remove(iface);
    }

    const(char)[] next_iface_name()
    {
        for (int n = 1; n < 256; ++n)
        {
            auto candidate = tconcat("ble", n);
            bool taken = false;
            foreach (e; Collection!LinuxBLEInterface().values)
            {
                if (e.name == candidate)
                {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                return candidate;
        }
        return tconcat("ble", 999);
    }

    void dispatch(const(ubyte)[] data)
    {
        if (data.length < mgmt_hdr.sizeof)
            return;
        const mgmt_hdr* hdr = cast(const mgmt_hdr*)data.ptr;
        const(ubyte)[] params = data[mgmt_hdr.sizeof .. $];
        if (params.length < hdr.plen)
            return;
        params = params[0 .. hdr.plen];

        switch (hdr.code)
        {
            case MgmtEvent.command_complete:
            {
                if (params.length < 3)
                    return;
                ushort opcode = params.ptr[0 .. 2].littleEndianToNative!ushort;
                handle_command_complete(hdr.index, opcode, params[2], params[3 .. $]);
                break;
            }

            case MgmtEvent.command_status:
            {
                if (params.length < 3)
                    return;
                ushort opcode = params.ptr[0 .. 2].littleEndianToNative!ushort;
                if (params[2] != 0)
                    log_warning(ModuleName, "MGMT command ", opcode, " failed: status=", params[2]);
                break;
            }

            case MgmtEvent.index_added:
                add_adapter(hdr.index);
                break;

            case MgmtEvent.index_removed:
                remove_adapter(hdr.index);
                break;

            case MgmtEvent.new_settings:
                if (params.length < 4)
                    return;
                if (auto iface = find_by_index(hdr.index))
                    iface.on_new_settings(params.ptr[0 .. 4].littleEndianToNative!uint);
                break;

            case MgmtEvent.discovering:
                if (params.length < 2)
                    return;
                if (auto iface = find_by_index(hdr.index))
                    iface.on_discovering(params[1] != 0);
                break;

            case MgmtEvent.device_found:
            {
                if (params.length < MgmtDeviceFound.sizeof)
                    return;
                const MgmtDeviceFound* ev = cast(const MgmtDeviceFound*)params.ptr;
                const(ubyte)[] eir = params[MgmtDeviceFound.sizeof .. $];
                if (eir.length > ev.eir_len)
                    eir = eir[0 .. ev.eir_len];
                if (auto iface = find_by_index(hdr.index))
                    iface.on_device_found(*ev, eir);
                break;
            }

            default:
                break;
        }
    }

    void handle_command_complete(ushort index, ushort opcode, ubyte status, const(ubyte)[] rp)
    {
        switch (opcode)
        {
            case MgmtCommand.read_index_list:
            {
                if (status != 0 || rp.length < 2)
                    return;
                ushort num = rp.ptr[0 .. 2].littleEndianToNative!ushort;
                const(ubyte)[] list = rp[2 .. $];
                foreach (i; 0 .. num)
                {
                    if (list.length < 2)
                        break;
                    add_adapter(list.ptr[0 .. 2].littleEndianToNative!ushort);
                    list = list[2 .. $];
                }
                break;
            }

            case MgmtCommand.read_info:
                if (status != 0 || rp.length < MgmtControllerInfo.sizeof)
                    return;
                if (auto iface = find_by_index(index))
                    iface.on_controller_info(*cast(const MgmtControllerInfo*)rp.ptr);
                break;

            case MgmtCommand.set_powered:
                if (status != 0)
                {
                    log_warning(ModuleName, "Set Powered failed on hci", index, ": status=", status);
                    return;
                }
                if (rp.length >= 4)
                    if (auto iface = find_by_index(index))
                        iface.on_new_settings(rp.ptr[0 .. 4].littleEndianToNative!uint);
                break;

            case MgmtCommand.start_discovery:
                if (status != 0)
                    log_warning(ModuleName, "Start Discovery failed on hci", index, ": status=", status);
                break;

            case MgmtCommand.add_advertising:
                if (status != 0)
                    log_warning(ModuleName, "Add Advertising failed on hci", index, ": status=", status);
                break;

            default:
                break;
        }
    }
}


// Detect a running bluetoothd by scanning /proc/[pid]/comm. Dependency-free
// and cheap; only consulted from interface startup (backoff-retried).
package bool bluetoothd_running()
{
    void* dir = opendir("/proc");
    if (dir is null)
        return false;
    scope (exit) closedir(dir);

    while (true)
    {
        dirent* e = readdir(dir);
        if (e is null)
            return false;
        if (e.d_name[0] < '0' || e.d_name[0] > '9')
            continue;

        char[280] path = void;
        size_t len = 0;
        path[0 .. 6] = "/proc/";
        len = 6;
        for (size_t i = 0; len < path.length - 6 && e.d_name[i] != 0; ++i)
            path[len++] = e.d_name[i];
        path[len .. len + 5] = "/comm";
        len += 5;
        path[len] = 0;

        int fd = open(path.ptr, 0);
        if (fd < 0)
            continue;
        char[16] comm = void;
        ptrdiff_t n = read(fd, comm.ptr, comm.length);
        close(fd);

        if (n >= 10 && comm[0 .. 10] == "bluetoothd")
            return true;
    }
}


// === MGMT protocol ===

private:

enum af_bluetooth        = 31;
enum sock_raw            = 3;
enum sock_seqpacket      = 5;
enum sock_nonblock       = 0x800;
enum btproto_hci         = 1;
enum btproto_l2cap       = 0;
enum hci_dev_none        = 0xFFFF;
enum hci_channel_control = 3;
enum mgmt_index_none     = 0xFFFF;

enum att_cid          = 4; // ATT fixed channel
enum bdaddr_le_public = 1;
enum bdaddr_le_random = 2;

enum sol_bluetooth = 274;
enum bt_rcvmtu     = 13;

enum addr_type_le = 0x06; // LE public | LE random

enum mgmt_setting_powered = 0x00000001;

enum mgmt_dev_found_not_connectable = 0x04;
enum mgmt_dev_found_scan_rsp        = 0x20;

enum MgmtCommand : ushort
{
    read_index_list    = 0x0003,
    read_info          = 0x0004,
    set_powered        = 0x0005,
    start_discovery    = 0x0023,
    stop_discovery     = 0x0024,
    add_advertising    = 0x003E,
    remove_advertising = 0x003F,
}

enum mgmt_adv_flag_connectable = 0x00000001;

enum MgmtEvent : ushort
{
    command_complete = 0x0001,
    command_status   = 0x0002,
    index_added      = 0x0004,
    index_removed    = 0x0005,
    new_settings     = 0x0006,
    device_found     = 0x0012,
    discovering      = 0x0013,
}

struct mgmt_hdr
{
    ushort code; // command opcode / event code
    ushort index;
    ushort plen;
}

package align(1) struct MgmtControllerInfo
{
align(1):
    ubyte[6] bdaddr;
    ubyte hci_version;
    ushort manufacturer;
    uint supported_settings;
    uint current_settings;
    ubyte[3] dev_class;
    ubyte[249] name;
    ubyte[11] short_name;
}

package align(1) struct MgmtDeviceFound
{
align(1):
    ubyte[6] addr;
    ubyte addr_type; // 0 = BR/EDR, 1 = LE public, 2 = LE random
    byte rssi;
    uint flags;
    ushort eir_len;
}

struct sockaddr_hci
{
    ushort hci_family;
    ushort hci_dev;
    ushort hci_channel;
}

struct sockaddr_l2
{
    ushort l2_family;
    ushort l2_psm;
    ubyte[6] l2_bdaddr;
    ushort l2_cid;
    ubyte l2_bdaddr_type;
}

struct dirent
{
    ulong d_ino;
    long d_off;
    ushort d_reclen;
    ubyte d_type;
    char[256] d_name;
}

enum int EAGAIN_      = 11;
enum int EWOULDBLOCK_ = 11;
enum int EINTR_       = 4;
enum int EISCONN_     = 106;
enum int EALREADY_    = 114;
enum int EINPROGRESS_ = 115;

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    int connect(int fd, const(void)* addr, uint addrlen);
    int setsockopt(int fd, int level, int optname, const(void)* optval, uint optlen);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    ptrdiff_t send(int fd, const(void)* buf, size_t len, int flags);
    void* opendir(const(char)* name);
    dirent* readdir(void* dirp);
    int closedir(void* dirp);
    int* __errno_location();
}

int last_errno() => *__errno_location();
