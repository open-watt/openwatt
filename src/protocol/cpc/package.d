module protocol.cpc;

// Silicon Labs CPC (Co-Processor Communication) transport for multiprotocol / "multi-PAN" RCPs.
//
// CPC is the serial transport a Silabs multiprotocol radio co-processor speaks: one UART carrying many
// logical protocols at once (Zigbee, OpenThread/802.15.4, Bluetooth HCI, ...). It does the same
// reliable-framing job as ASH (protocol/ezsp/ashv2.d) but MULTIPLEXES: numbered endpoints, each with its
// own seq/ack window, plus a control endpoint (0, SYSTEM) used to reset the secondary, read its
// version/capabilities, and connect/terminate the protocol endpoints.
//
// Data plane, VLAN-style: the trunk (CPCInterface) carries ALL traffic as framed CPCFrame packets and
// each CPCEndpoint carries the decapsulated payload for its own endpoint (like a VLAN sub-interface for
// its vid). TX: CPCEndpoint.transmit() wraps a raw packet into a CPCFrame (borrowing the payload) and
// forward()s it to the trunk; CPCInterface.transmit() enqueues it on that endpoint's per-endpoint FIFO
// and the scheduler emits it. RX: on_bytes parses a frame, builds a CPCFrame packet (payload borrowed
// from the rx buffer), and incoming_packet()s it; ingress() runs the ARQ, then either handles ep0 system
// traffic or hands the decapsulated payload to the child endpoint. Sequence numbers are stamped by the
// trunk at emit time, never pre-baked by the endpoint.
//
// Scheduling: per-endpoint order is strict FIFO (the endpoint sub-protocols -- EZSP, Spinel, HCI -- carry
// their own transaction state and require in-order delivery), so PCP only reorders ACROSS endpoints: at
// each tx opportunity the trunk serves the eligible endpoint (queued head + window open) with the highest
// head-of-line PCP. Window is 1 per endpoint, so an endpoint blocks on its own ack after sending and
// can't monopolise the wire -- strict priority is starvation-free without extra machinery.
//
// Wire format from cpc-daemon v4.4.5 (protocol v5). Frames are NOT byte-stuffed: a 7-byte header
// (flag 0x14, endpoint, LE length, control, LE HCS) delimits exactly; both CRCs are CRC-16/XMODEM, LE.
// The length field counts payload + 2-byte FCS, or 0 for no payload. CPC assumes an 8-bit-clean link, so
// the serial stream must be flow-control=none or hardware, never software (XON/XOFF would strip 0x11/0x13).
//
// The multiprotocol image is an RCP (thin radio), NOT a Zigbee NCP: there is no EZSP NCP behind the zigbee
// endpoint. First consumer is Thread / 802.15.4.
//
// TODO:
//   [x] SpinelClient: split into transport-agnostic codec + a consumer that binds a CPCEndpoint (protocol/spinel).
//       Native HDLC-over-serial transport is still future work; spinel currently rides a CPCEndpoint only.
//   [ ] Bluetooth HCI endpoint feeding protocol/ble
//   [ ] CPC security sessions (AES-GCM over endpoint 1): detected and refused today
//   [ ] protocol v4 secondaries (different endpoint-state values); v5 only today
//   [ ] tx window > 1 and adaptive RTO: window is fixed at 1 (all Silabs host libs do the same today)
//   [ ] migrate the retransmit/connect-retry timers off update() onto g_app.schedule() (event-driven)
//   [ ] QueuePolicy: honour deadline/urgent-pcp escalation (accepted but ignored today)

import urt.array;
import urt.crc;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.mem.temp;
import urt.result;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

import router.iface;
import router.iface.packet;
import router.stream;

//version = DebugCPCMessageFlow;

nothrow @nogc:


alias cpc_crc = calculate_crc!(Algorithm.crc16_xmodem);

// The trunk's packet type: the endpoint id and control byte ride in the embed header; the payload is the
// endpoint's frame (borrowed from the rx buffer on ingress, or the consumer's buffer on egress).
struct CPCFrame
{
    enum Type = PacketType.cpc;
    ubyte endpoint;
    ubyte control;      // full control byte on rx; the emit-intent (poll bit) on tx, seq/ack stamped by the trunk
}

enum CPCEndpointId : ubyte
{
    system = 0,
    security = 1,
    bluetooth = 2,
    rail_downstream = 3,
    rail_upstream = 4,
    zigbee = 5,
    zwave = 6,
    connect = 7,
    gpio = 8,
    openthread = 9,
    wisun = 10,
    wifi = 11,
    ieee802_15_4 = 12,
    cli = 13,
    bluetooth_rcp = 14,
    acp = 15,
    se = 16,
    nvm3 = 17,
    user_0 = 90,
    user_1 = 91,
    user_2 = 92,
    user_3 = 93,
    user_4 = 94,
    user_5 = 95,
    user_6 = 96,
    user_7 = 97,
    user_8 = 98,
    user_9 = 99,
}


class CPCInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("retransmits", retransmits),
                                 Prop!("ack-timeout", ack_timeout),
                                 Prop!("trace-frames", trace_frames),
                                 Prop!("protocol-version", protocol_version, "status"),
                                 Prop!("secondary-version", secondary_version, "status"),
                                 Prop!("app-version", app_version, "status"));
nothrow @nogc:

    enum type_name = "cpc";
    enum path = "/interface/cpc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CPCInterface, id, flags);

        // max-l2mtu is the driver's payload cap; the 9-byte CPC framing is transport overhead, not counted
        // in the MTU (same as CAN/BLE). l2mtu defaults to the cap and is user-reducible; mtu derives from
        // l2mtu. The cap is narrowed to the secondary's rx_capability once the handshake learns it.
        _max_l2mtu = cpc_max_payload;
        l2mtu = _max_l2mtu;
        mark_set!(typeof(this), "max-l2mtu")();
        retransmits(10);
        ack_timeout(500);
    }

    // Properties...

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream stream)
    {
        if (_stream.get is stream)
            return;
        if (_subscribed)
        {
            _stream.release_rx_handler(&on_bytes);
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        _stream = stream;
        mark_set!(typeof(this), "stream")();
        restart();
    }

    final ubyte retransmits() const pure
        => _max_retransmits;
    final StringResult retransmits(ubyte value)
    {
        if (value < 1 || value > 15)
            return StringResult("retransmits must be between 1 and 15");
        _max_retransmits = value;
        mark_set!(typeof(this), "retransmits")();
        return StringResult.success;
    }

    final ushort ack_timeout() const pure
        => _ack_timeout_ms;
    final StringResult ack_timeout(ushort value)
    {
        if (value < 50 || value > 5000)
            return StringResult("ack-timeout must be between 50ms and 5000ms");
        _ack_timeout_ms = value;
        mark_set!(typeof(this), "ack-timeout")();
        return StringResult.success;
    }

    final ubyte protocol_version() const pure
        => _protocol_version;

    final const(char)[] secondary_version() const pure
        => _secondary_version[0 .. _secondary_version_len];

    final const(char)[] app_version() const pure
        => _app_version[0 .. _app_version_len];

    // runtime wire trace: hexdump every emitted/received frame at trace level. off by default; toggled live
    // on the running instance so an incident can be captured without a rebuild.
    final bool trace_frames() const pure
        => _trace_frames;
    final void trace_frames(bool value)
    {
        _trace_frames = value;
        mark_set!(typeof(this), "trace-frames")();
    }


protected:
    mixin RekeyHandler;

    // Egress entry for endpoint traffic: a CPCEndpoint forwards a CPCFrame here (framework calls this via
    // forward()). We enqueue it on the target endpoint's channel and let the scheduler emit it.
    override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)* queue_policy)
    {
        if (packet.type != PacketType.cpc)
            return -1;
        CPCFrame f = packet.hdr!CPCFrame;
        const(ubyte)[] payload = cast(const(ubyte)[])packet.data;
        if (payload.length == 0 || payload.length > actual_mtu)
            return -1;

        Channel* ch = channel_for(f.endpoint);
        if (!ch)
            return -1; // endpoint not connected

        if (!channel_submit(*ch, f.endpoint, payload, packet.pcp, false))
            return -1; // queue full

        schedule();
        return 0;
    }

    override bool validate() const pure
        => _stream !is null;

    override const(char)[] status_message() const
    {
        if (running)
            return super.status_message();
        if (!_stream || !_stream.running)
            return "Waiting for stream";
        if (_unresponsive)
            return "Secondary unresponsive (may need power cycle)";
        final switch (_phase)
        {
            case Phase.reboot_mode:
            case Phase.reset:
                return "Resetting secondary";
            case Phase.wait_reset_reason:
                return "Waiting for secondary boot";
            case Phase.rx_capability:
            case Phase.protocol_version:
            case Phase.capabilities:
            case Phase.cpc_version:
            case Phase.app_version:
                return "Interrogating secondary";
            case Phase.failed:
                return "Unsupported secondary configuration";
            case Phase.done:
                return super.status_message();
        }
    }

    override CompletionStatus startup()
    {
        if (!_stream || !_stream.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _stream.rx_handler = &on_bytes;
            _stream.subscribe(&stream_state_change);
            _subscribed = true;
        }

        if (_restart_pending)
        {
            _restart_pending = false;
            restart();
            return CompletionStatus.continue_;
        }

        if (_phase == Phase.failed)
            return CompletionStatus.error;
        if (_phase == Phase.done)
            return CompletionStatus.complete;

        MonoTime now = getTime();

        if (_ucmd_active)
        {
            if (now - _ucmd_sent >= ucmd_timeout)
            {
                if (++_ucmd_retries > max_ucmd_retries)
                {
                    // secondary silent on this step. don't thrash the (healthy) transport; give up this
                    // handshake cycle and let the state machine back off (100ms..60s) before the next attempt.
                    if (++_handshake_attempts >= unresponsive_threshold)
                        _unresponsive = true;
                    log.warning("no response from CPC secondary (handshake step ", cast(int)_phase,
                                "); backing off (give-up ", _handshake_attempts, ")");
                    return CompletionStatus.error;
                }
                emit_frame(0, uframe_control(UFrameType.poll_final), _ucmd_buffer[0 .. _ucmd_len]);
                _ucmd_sent = now;
            }
            return CompletionStatus.continue_;
        }

        if (_phase == Phase.wait_reset_reason)
        {
            if (now - _phase_start >= reset_reason_timeout)
            {
                if (++_reset_attempts >= 3)
                {
                    _reset_attempts = 0;
                    if (++_handshake_attempts >= unresponsive_threshold)
                        _unresponsive = true;
                    log.warning("secondary never announced its reset; backing off (give-up ", _handshake_attempts, ")");
                    return CompletionStatus.error;
                }
                else
                    _phase = Phase.reset;
            }
            return CompletionStatus.continue_;
        }

        send_handshake_command();
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _phase = Phase.reboot_mode;
        _restart_pending = false;
        _reset_attempts = 0;
        _command_seq = 0;
        _ucmd_active = false;
        _ucmd_retries = 0;
        _ucmd_len = 0;
        _ucmd_prop = SystemProperty.last_status;
        _phase_start = MonoTime();
        _ucmd_sent = MonoTime();
        _rx_offset = 0;
        _rx_capability = 0;
        _protocol_version = 0;
        _capabilities = 0;
        _secondary_version_len = 0;
        _app_version_len = 0;
        mark_set!(typeof(this), [ "protocol-version", "secondary-version", "app-version" ])();

        channel_clear(_ep0);
        _pending_cmds.clear();

        while (_free_messages)
        {
            Message* next = _free_messages.next;
            defaultAllocator.freeT(_free_messages);
            _free_messages = next;
        }

        if (_subscribed)
        {
            _stream.release_rx_handler(&on_bytes);
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        if (_restart_pending)
        {
            _restart_pending = false;
            restart();
            return;
        }

        MonoTime now = getTime();

        if (!channel_service(_ep0, 0, now))
        {
            log_channel_death("system endpoint", _ep0, now);
            restart();
            return;
        }

        foreach (ep; _endpoints[])
        {
            // only a running, connected endpoint has a live channel; a destroying-but-not-yet-detached
            // endpoint is still in _endpoints, and restart() on it would trip the destroyed assert
            if (ep.running && ep._connected && !channel_service(ep._channel, ubyte(ep._endpoint), now))
            {
                log_channel_death(tconcat("endpoint ", ep._endpoint), ep._channel, now);
                ep.restart();
            }
        }

        for (size_t i = _pending_cmds.length; i > 0; )
        {
            --i;
            if (now - _pending_cmds[i].sent < icmd_timeout)
                continue;
            CPCEndpoint requester = _pending_cmds[i].requester;
            ubyte seq = _pending_cmds[i].seq;
            _pending_cmds.remove(i);
            // the reply never came: drop the command's still-queued ep0 frame so it can't flush as a stale
            // backlog on recovery. an already in-flight frame may have reached the secondary, so leave it.
            cancel_queued_command(_ep0, seq);
            if (requester)
                requester.on_connect_timeout();
        }
    }

    void log_channel_death(const(char)[] who, ref Channel ch, MonoTime now)
    {
        Message* m = ch.in_flight;
        if (m)
            log.errorf("{0} unresponsive: no ack after {1} retransmits; in-flight seq {2} len {3} age {4}ms first: {5}",
                       who, _max_retransmits, m.seq, m.length, cast(uint)(now - m.enqueue_time).as!"msecs",
                       cast(void[])m.buffer[0 .. m.length < 8 ? m.length : 8]);
        else
            log.error(who, " unresponsive: no ack after ", _max_retransmits, " retransmits");
    }

    // ingress: trunk accounting + observability, then ARQ and demux. A CPCFrame terminates here (ep0
    // system traffic) or is decapsulated to the child endpoint; it is never dispatched as a vlan/eth frame.
    override void ingress(ref Packet packet)
    {
        // count the full wire frame (header + payload + FCS), matching what emit_frame counts on tx, so
        // the trunk's rx/tx byte stats stay comparable; the packet carries only the borrowed payload
        add_rx_frame(cpc_header_size + (packet.length ? packet.length + 2 : 0));
        fire_subscribers(packet);

        ubyte endpoint = packet.hdr!CPCFrame.endpoint;
        ubyte control = packet.hdr!CPCFrame.control;
        const(ubyte)[] payload = cast(const(ubyte)[])packet.data;
        MonoTime rx_time = packet.creation_time;

        version (DebugCPCMessageFlow)
            log.tracef("<-- ep {0} ctrl [{1,02x}] {2} bytes", endpoint, control, payload.length);
        if (_trace_frames)
            log.debugf("<-- ep {0} ctrl [{1,02x}] {2}B: {3}", endpoint, control, payload.length, cast(void[])payload);

        ubyte ftype = control >> 6;
        if (ftype <= 1) // information frame: only bit 7 identifies it; seq occupies bits 6..4
        {
            if (endpoint == 0)
            {
                if (channel_rx_iframe(_ep0, 0, control))
                    process_system_message(payload);
            }
            else if (CPCEndpoint child = find_endpoint(endpoint))
            {
                if (channel_rx_iframe(child._channel, endpoint, control))
                    child.deliver_payload(payload, rx_time);
            }
            else
            {
                add_rx_drop();
                ubyte[1] reason = [ RejectReason.unreachable_endpoint ];
                emit_frame(endpoint, sframe_control(SupervisoryFunction.reject, 0), reason);
            }
        }
        else if (ftype == FrameType.supervisory)
        {
            ubyte func = (control >> 4) & 3;
            ubyte ack = control & 7;
            CPCEndpoint child = endpoint == 0 ? null : find_endpoint(endpoint);
            Channel* ch = endpoint == 0 ? &_ep0 : (child ? &child._channel : null);
            if (ch)
            {
                if (func == SupervisoryFunction.ack)
                    channel_ack(*ch, endpoint, ack);
                else if (func == SupervisoryFunction.reject)
                {
                    RejectReason reason = payload.length ? cast(RejectReason)payload[0] : RejectReason.error;
                    channel_ack(*ch, endpoint, ack);
                    final switch (reason)
                    {
                        case RejectReason.checksum_mismatch:
                            // retransmit, but consume the retry budget so a link that keeps corrupting
                            // frames trips the dead-link cutoff instead of resetting send_time forever
                            if (ch.in_flight)
                            {
                                if (ch.in_flight.retries >= _max_retransmits)
                                {
                                    log.error("endpoint ", endpoint, " unrecoverable: checksum rejects exhausted retransmits");
                                    restart_or_defer(child);
                                }
                                else
                                {
                                    ++ch.in_flight.retries;
                                    channel_emit(*ch, endpoint, ch.in_flight);
                                }
                            }
                            break;
                        case RejectReason.no_error:
                        case RejectReason.sequence_mismatch:
                        case RejectReason.out_of_memory:
                            log.debug_("reject on endpoint ", endpoint, ": reason ", cast(int)reason);
                            break;
                        case RejectReason.security_issue:
                        case RejectReason.unreachable_endpoint:
                        case RejectReason.error:
                            log.warning("endpoint ", endpoint, " rejected: reason ", cast(int)reason);
                            restart_or_defer(child);
                            break;
                    }
                }
            }
        }
        else // unnumbered: system endpoint control traffic only, outside any seq/ack window
        {
            if (endpoint == 0)
            {
                ubyte utype = control & 0x3F;
                if (utype == UFrameType.information || utype == UFrameType.poll_final)
                    process_system_message(payload);
                // acknowledge (0x0E) answers a RESET_SEQ we never send; anything else is ignorable
            }
        }

        schedule(); // an ack may have opened a window
    }

private:
    enum Phase : ubyte
    {
        reboot_mode,        // SET PROP_BOOTLOADER_REBOOT_MODE = application
        reset,              // CMD_SYSTEM_RESET
        wait_reset_reason,  // unsolicited PROP_LAST_STATUS after the secondary reboots
        rx_capability,
        protocol_version,
        capabilities,
        cpc_version,
        app_version,
        done,
        failed,             // incompatible secondary (wrong protocol version, or requires encryption)
    }

    enum ucmd_timeout = 500.msecs;
    enum max_ucmd_retries = 5;
    enum reset_reason_timeout = 5.seconds;
    enum icmd_timeout = 2.seconds;
    enum unresponsive_threshold = 2; // handshake give-ups before we surface "may need power cycle" in status

    ObjectRef!Stream _stream;
    bool _subscribed;
    bool _restart_pending;
    Phase _phase;
    ubyte _reset_attempts;
    ubyte _command_seq;

    // the handshake is strictly sequential, so a single u-frame command slot suffices
    bool _ucmd_active;
    ubyte _ucmd_seq;
    ubyte _ucmd_retries;
    ubyte _ucmd_len;
    SystemProperty _ucmd_prop;
    MonoTime _ucmd_sent;
    MonoTime _phase_start;
    ubyte[16] _ucmd_buffer;

    ushort _rx_capability;
    ubyte _protocol_version;
    uint _capabilities;
    ubyte _secondary_version_len;
    ubyte _app_version_len;
    char[16] _secondary_version;
    char[32] _app_version;

    ushort _ack_timeout_ms;
    ubyte _max_retransmits;
    ubyte _handshake_attempts;          // consecutive handshake give-ups; persists across backoff, cleared on sign of life
    bool _unresponsive;                 // secondary went silent long enough to warrant a power cycle (status only)
    bool _trace_frames;

    Channel _ep0;                       // the SYSTEM channel is the trunk's own (no endpoint object)
    Array!CPCEndpoint _endpoints;
    Array!PendingCommand _pending_cmds;
    Message* _free_messages;

    size_t _rx_offset;
    ubyte[4096] _rx_buffer;

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    // Recover a wedged channel: bounce the child (guarded, since a destroying-but-still-registered
    // endpoint would trip restart()'s destroyed assert), or defer a trunk restart for ep0 -- never
    // restart the trunk synchronously from its own rx path (it would clear the rx buffer mid-parse).
    void restart_or_defer(CPCEndpoint child)
    {
        if (child)
        {
            if (child.running)
                child.restart();
        }
        else
            _restart_pending = true;
    }

    // endpoint registry (the CPC analogue of BaseInterface's vlan table)

    bool bind_endpoint(CPCEndpoint ep, bool remove)
    {
        if (remove)
        {
            foreach (i, e; _endpoints[])
            {
                if (e is ep)
                {
                    _endpoints.remove(i);
                    break;
                }
            }
            for (size_t i = _pending_cmds.length; i > 0; )
            {
                --i;
                if (_pending_cmds[i].requester is ep)
                    _pending_cmds.remove(i);
            }
            return true;
        }
        foreach (e; _endpoints[])
        {
            if (e._endpoint == ep._endpoint)
                return false;
        }
        _endpoints ~= ep;
        return true;
    }

    CPCEndpoint find_endpoint(ubyte id) pure
    {
        foreach (e; _endpoints[])
        {
            if (ubyte(e._endpoint) == id)
                return e;
        }
        return null;
    }

    // channel lookup for egress: ep0 is the trunk's; every other endpoint owns its channel (connected only)
    Channel* channel_for(ubyte id)
    {
        if (id == 0)
            return &_ep0;
        if (CPCEndpoint ep = find_endpoint(id))
        {
            if (ep._connected)
                return &ep._channel;
        }
        return null;
    }

    // system endpoint services for the children

    bool submit_connect(CPCEndpoint ep)
        => submit_endpoint_state(ubyte(ep._endpoint), EndpointState.connected, ep);

    void submit_terminate(ubyte endpoint)
    {
        submit_endpoint_state(endpoint, EndpointState.closed, null);
    }

    bool submit_endpoint_state(ubyte endpoint, EndpointState state, CPCEndpoint requester)
    {
        if (_pending_cmds.length >= 8)
            return false;
        // don't stack endpoint control onto a struggling system channel: a retransmitting ep0 means the
        // secondary isn't acking, and piling connect/terminate frames just fills the queue (the amplification
        // that turned one endpoint's failure into a trunk-wide outage). the endpoint retries under its backoff.
        if (_ep0.in_flight && _ep0.in_flight.retries >= 1)
            return false;
        ubyte seq = _command_seq++;
        uint prop = SystemProperty.endpoint_state_0 | endpoint;
        ubyte[1] value = [ state ];
        ubyte[16] cmd = void;
        size_t len = build_property_cmd(cmd, SystemCommand.prop_value_set, seq, prop, value);
        // endpoint-state commands ride ep0 as reliable i-frames at network-control priority; the poll
        // bit is mandatory on system-endpoint commands -- it's what makes the secondary send the
        // PROP_VALUE_IS reply rather than just link-acking the frame
        if (!channel_submit(_ep0, 0, cmd[0 .. len], PCP.nc, true))
            return false;
        _pending_cmds ~= PendingCommand(seq, prop, requester, getTime());
        schedule();
        return true;
    }

    // reset sequence / interrogation (all u-frames: no seq/ack state exists before the reset)

    void send_handshake_command()
    {
        ubyte seq = _command_seq++;
        final switch (_phase)
        {
            case Phase.reboot_mode:
                ubyte[4] mode = 0; // reboot into the application, not the bootloader
                _ucmd_prop = SystemProperty.bootloader_reboot_mode;
                _ucmd_len = cast(ubyte)build_property_cmd(_ucmd_buffer, SystemCommand.prop_value_set, seq, _ucmd_prop, mode);
                break;
            case Phase.reset:
                _ucmd_buffer[0] = SystemCommand.reset;
                _ucmd_buffer[1] = seq;
                _ucmd_buffer[2] = 0;
                _ucmd_buffer[3] = 0;
                _ucmd_len = 4;
                _ucmd_prop = SystemProperty.last_status;
                break;
            case Phase.rx_capability:
                _ucmd_prop = SystemProperty.rx_capability;
                goto build_get;
            case Phase.protocol_version:
                _ucmd_prop = SystemProperty.protocol_version;
                goto build_get;
            case Phase.capabilities:
                _ucmd_prop = SystemProperty.capabilities;
                goto build_get;
            case Phase.cpc_version:
                _ucmd_prop = SystemProperty.secondary_cpc_version;
                goto build_get;
            case Phase.app_version:
                _ucmd_prop = SystemProperty.secondary_app_version;
            build_get:
                _ucmd_len = cast(ubyte)build_property_cmd(_ucmd_buffer, SystemCommand.prop_value_get, seq, _ucmd_prop, null);
                break;
            case Phase.wait_reset_reason:
            case Phase.done:
            case Phase.failed:
                assert(false);
        }
        _ucmd_seq = seq;
        _ucmd_retries = 0;
        _ucmd_active = true;
        _ucmd_sent = getTime();
        emit_frame(0, uframe_control(UFrameType.poll_final), _ucmd_buffer[0 .. _ucmd_len]);
    }

    void handshake_reply(const(ubyte)[] value)
    {
        final switch (_phase)
        {
            case Phase.reboot_mode:
                _phase = Phase.reset;
                break;
            case Phase.rx_capability:
            {
                if (value.length >= 2)
                    _rx_capability = value[0 .. 2][0 .. 2].littleEndianToNative!ushort;
                // clamp the driver max to the secondary's advertised payload capacity; l2mtu follows down
                // if it was still pinned at the old max (a smaller user-set l2mtu is left alone)
                ushort new_max = _rx_capability != 0 && _rx_capability < cpc_max_payload ? _rx_capability : cpc_max_payload;
                if (_l2mtu == _max_l2mtu || _l2mtu > new_max)
                    l2mtu = new_max;
                _max_l2mtu = new_max;
                mark_set!(typeof(this), "max-l2mtu")();
                _phase = Phase.protocol_version;
                break;
            }
            case Phase.protocol_version:
                _protocol_version = value.length ? value[0] : 0;
                mark_set!(typeof(this), "protocol-version")();
                if (_protocol_version != 5)
                {
                    log.error("secondary speaks CPC protocol v", _protocol_version, "; only v5 is supported");
                    _phase = Phase.failed;
                    return;
                }
                _phase = Phase.capabilities;
                break;
            case Phase.capabilities:
                _capabilities = value.length >= 4 ? value[0 .. 4][0 .. 4].littleEndianToNative!uint : 0;
                if (_capabilities & capability_security)
                {
                    log.error("secondary requires CPC encryption, which is not supported; use firmware built without the security endpoint");
                    _phase = Phase.failed;
                    return;
                }
                _phase = Phase.cpc_version;
                break;
            case Phase.cpc_version:
                if (value.length >= 12)
                {
                    const(char)[] v = tconcat(value[0 .. 4][0 .. 4].littleEndianToNative!uint, ".",
                                              value[4 .. 8][0 .. 4].littleEndianToNative!uint, ".",
                                              value[8 .. 12][0 .. 4].littleEndianToNative!uint);
                    _secondary_version_len = cast(ubyte)(v.length < _secondary_version.length ? v.length : _secondary_version.length);
                    _secondary_version[0 .. _secondary_version_len] = v[0 .. _secondary_version_len];
                    mark_set!(typeof(this), "secondary-version")();
                }
                _phase = Phase.app_version;
                break;
            case Phase.app_version:
                size_t len = value.length;
                while (len && value[len - 1] == 0)
                    --len;
                if (len > _app_version.length)
                    len = _app_version.length;
                _app_version[0 .. len] = cast(const(char)[])value[0 .. len];
                _app_version_len = cast(ubyte)len;
                mark_set!(typeof(this), "app-version")();
                _phase = Phase.done;
                log.info("secondary CPC ", secondary_version, " (", app_version, "), protocol v", _protocol_version,
                         ", max payload ", actual_mtu);
                break;
            case Phase.reset:
            case Phase.wait_reset_reason:
            case Phase.done:
            case Phase.failed:
                break;
        }
    }

    // frame codec

    bool emit_frame(ubyte endpoint, ubyte control, const(ubyte)[] payload)
    {
        version (DebugCPCMessageFlow)
            log.tracef("--> ep {0} ctrl [{1,02x}] {2} bytes", endpoint, control, payload.length);
        if (_trace_frames)
            log.debugf("--> ep {0} ctrl [{1,02x}] {2}B: {3}", endpoint, control, payload.length, cast(void[])payload);

        ubyte[cpc_header_size] header = void;
        build_frame_header(header, endpoint, payload.length ? cast(ushort)(payload.length + 2) : 0, control);

        ptrdiff_t written;
        size_t expect;
        if (payload.length)
        {
            ubyte[2] fcs = payload.cpc_crc().nativeToLittleEndian;
            expect = header.length + payload.length + fcs.length;
            written = _stream.write(header[], payload, fcs[]);
        }
        else
        {
            expect = header.length;
            written = _stream.write(header[]);
        }
        if (written != expect)
        {
            // no cancel byte exists in CPC; a torn partial is resolved by the receiver's HCS resync,
            // and I-frame loss by the retransmit timer
            add_tx_drop();
            return false;
        }
        add_tx_frame(expect);
        return true;
    }

    void on_bytes(Stream, const(void)[] data, MonoTime rx_time)
    {
        const(ubyte)[] input = cast(const(ubyte)[])data;
        while (input.length)
        {
            size_t space = _rx_buffer.length - _rx_offset;
            if (space == 0)
            {
                add_rx_drop();
                _rx_offset = 0;
                space = _rx_buffer.length;
            }
            size_t take = input.length < space ? input.length : space;
            _rx_buffer[_rx_offset .. _rx_offset + take] = input[0 .. take];
            _rx_offset += take;
            input = input[take .. $];
            parse_buffer(rx_time);
            if (!_subscribed)
                return; // torn down beneath the callback; the buffer is no longer ours
        }
    }

    void parse_buffer(MonoTime rx_time)
    {
        size_t start = 0;
        while (_rx_offset - start >= cpc_header_size)
        {
            const(ubyte)[] buf = _rx_buffer[start .. _rx_offset];
            if (buf[0] != cpc_flag ||
                buf[0 .. 5].cpc_crc() != buf[5 .. 7][0 .. 2].littleEndianToNative!ushort)
            {
                ++start; // resync: slide to the next byte that could start a valid header
                continue;
            }
            ushort length = buf[2 .. 4][0 .. 2].littleEndianToNative!ushort;
            if (length == 1 || length == 2)
            {
                ++start; // valid HCS with an impossible length (payload zone can't hold its own FCS)
                continue;
            }
            size_t frame_len = cpc_header_size + length;
            if (frame_len > _rx_buffer.length)
            {
                add_rx_drop();
                start += cpc_header_size;
                continue;
            }
            if (buf.length < frame_len)
                break; // incomplete; wait for more bytes

            ubyte endpoint = buf[1];
            ubyte control = buf[4];
            if (length)
            {
                const(ubyte)[] payload = buf[cpc_header_size .. frame_len - 2];
                if (payload.cpc_crc() != buf[frame_len - 2 .. frame_len][0 .. 2].littleEndianToNative!ushort)
                {
                    add_rx_drop();
                    ubyte[1] reason = [ RejectReason.checksum_mismatch ];
                    emit_frame(endpoint, sframe_control(SupervisoryFunction.reject, channel_ack_for(endpoint)), reason);
                }
                else
                    deliver_frame(endpoint, control, payload, rx_time);
            }
            else
                deliver_frame(endpoint, control, null, rx_time);

            if (!_subscribed)
                return; // a subscriber under deliver_frame tore us down; the buffer was cleared

            start += frame_len;
        }

        _rx_offset -= start;
        if (start > 0 && _rx_offset > 0)
        {
            import urt.mem : memmove;
            memmove(_rx_buffer.ptr, _rx_buffer.ptr + start, _rx_offset);
        }
    }

    // build a CPCFrame packet (payload borrowed from the rx buffer) and push it through the packet path
    void deliver_frame(ubyte endpoint, ubyte control, const(ubyte)[] payload, MonoTime rx_time)
    {
        Packet p;
        CPCFrame* f = &p.init!CPCFrame(payload, rx_time);
        f.endpoint = endpoint;
        f.control = control;
        incoming_packet(p);
    }

    ubyte channel_ack_for(ubyte endpoint) pure
    {
        if (endpoint == 0)
            return _ep0.rx_ack;
        if (CPCEndpoint child = find_endpoint(endpoint))
            return child._channel.rx_ack;
        return 0;
    }

    void process_system_message(const(ubyte)[] payload)
    {
        if (payload.length < 4)
        {
            add_rx_drop();
            return;
        }
        ubyte cmd = payload[0];
        ubyte cseq = payload[1];
        ushort plen = payload[2 .. 4][0 .. 2].littleEndianToNative!ushort;
        if (4 + plen > payload.length)
        {
            add_rx_drop();
            return;
        }
        const(ubyte)[] body_ = payload[4 .. 4 + plen];

        switch (cmd)
        {
            case SystemCommand.reset:
                if (_ucmd_active && cseq == _ucmd_seq && _phase == Phase.reset)
                {
                    _ucmd_active = false;
                    uint status = body_.length >= 4 ? body_[0 .. 4][0 .. 4].littleEndianToNative!uint : uint.max;
                    if (status == status_ok)
                    {
                        // the secondary reboots now; all its endpoint and seq/ack state evaporates
                        channel_clear(_ep0);
                        _pending_cmds.clear();
                        _phase = Phase.wait_reset_reason;
                        _phase_start = getTime();
                    }
                    else
                        log.warning("secondary refused reset: status ", status);
                }
                break;

            case SystemCommand.prop_value_is:
                if (body_.length < 4)
                {
                    add_rx_drop();
                    return;
                }
                uint prop = body_[0 .. 4][0 .. 4].littleEndianToNative!uint;
                const(ubyte)[] value = body_[4 .. $];

                if (_ucmd_active && cseq == _ucmd_seq && prop == _ucmd_prop)
                {
                    _ucmd_active = false;
                    handshake_reply(value);
                    return;
                }

                foreach (i, ref pc; _pending_cmds[])
                {
                    if (pc.seq != cseq)
                        continue;
                    CPCEndpoint requester = pc.requester;
                    uint expected = pc.property;
                    _pending_cmds.remove(i);
                    if (requester && expected == prop && value.length >= 1)
                        requester.on_connect_reply(cast(EndpointState)value[0]);
                    return;
                }

                if (prop == SystemProperty.last_status)
                {
                    uint status = value.length >= 4 ? value[0 .. 4][0 .. 4].littleEndianToNative!uint : 0;
                    if (status >= status_reset_first && status <= status_reset_last)
                    {
                        if (_phase != Phase.done && _phase != Phase.failed)
                        {
                            log.debug_("secondary booted, reset reason ", status);
                            _ucmd_active = false;
                            channel_clear(_ep0);
                            _pending_cmds.clear();
                            _reset_attempts = 0;
                            _handshake_attempts = 0; // sign of life: clear the give-up tally and unresponsive flag
                            _unresponsive = false;
                            _phase = Phase.rx_capability;
                        }
                        else
                        {
                            log.error("secondary rebooted unexpectedly (reason ", status, ")");
                            _restart_pending = true;
                        }
                    }
                }
                else if ((prop & 0xFFFFFF00) == SystemProperty.endpoint_state_0)
                {
                    ubyte ep_id = prop & 0xFF;
                    EndpointState state = value.length ? cast(EndpointState)value[0] : EndpointState.error_fault;
                    if (CPCEndpoint child = find_endpoint(ep_id))
                    {
                        if (child.running && child._connected && state != EndpointState.connected && state != EndpointState.open)
                            child.remote_closed();
                    }
                }
                break;

            case SystemCommand.noop:
                break;

            default:
                log.debug_("unhandled system command ", cmd);
                break;
        }
    }

    // per-endpoint ARQ (window fixed at 1; seq/ack are 3 bits, arithmetic mod 8). Storage lives with the
    // owner (ep0 here, data endpoints in the child); the trunk stamps seq and drives emit/ack/retransmit.

    Message* alloc_message()
    {
        Message* msg = _free_messages;
        if (msg)
            _free_messages = msg.next;
        else
            msg = defaultAllocator.allocT!Message();
        msg.next = null;
        msg.enqueue_time = MonoTime();
        msg.send_time = MonoTime();
        msg.pcp = PCP.be;
        msg.seq = 0;
        msg.retries = 0;
        msg.poll = false;
        msg.length = 0;
        return msg;
    }

    void release_message(Message* msg)
    {
        msg.next = _free_messages;
        _free_messages = msg;
    }

    bool channel_submit(ref Channel ch, ubyte endpoint, const(ubyte)[] payload, PCP pcp, bool poll)
    {
        if (ch.queue_len >= max_channel_queue)
        {
            log.warning("endpoint ", endpoint, " tx queue full (", max_channel_queue, "); rejecting frame");
            return false;
        }
        Message* msg = alloc_message();
        msg.poll = poll;
        msg.pcp = pcp;
        msg.enqueue_time = getTime();
        msg.length = cast(ushort)payload.length;
        msg.buffer[0 .. payload.length] = payload[];
        if (!ch.queue)
            ch.queue = msg;
        else
            ch.queue_tail.next = msg;
        ch.queue_tail = msg;
        ++ch.queue_len;
        return true;
    }

    // cross-endpoint scheduler: emit the head frame of the eligible channel with the highest head-of-line
    // PCP (tiebreak: oldest enqueue). window-1 makes each channel ineligible until its ack, so one pass
    // fills the wire with at most one frame per channel and strict priority can't starve anyone.
    void schedule()
    {
        for (;;)
        {
            Channel* best;
            ubyte best_ep;
            ubyte best_rank;
            MonoTime best_time;

            void consider(ref Channel ch, ubyte ep)
            {
                if (!ch.queue || ch.in_flight)
                    return;
                ubyte rank = pcp_priority_map[ch.queue.pcp];
                if (!best || rank > best_rank || (rank == best_rank && ch.queue.enqueue_time < best_time))
                {
                    best = &ch;
                    best_ep = ep;
                    best_rank = rank;
                    best_time = ch.queue.enqueue_time;
                }
            }

            consider(_ep0, 0);
            foreach (ep; _endpoints[])
            {
                if (ep._connected)
                    consider(ep._channel, ubyte(ep._endpoint));
            }

            if (!best)
                break;
            channel_send_next(*best, best_ep);
        }
    }

    void channel_send_next(ref Channel ch, ubyte endpoint)
    {
        Message* msg = ch.queue;
        if (!msg || ch.in_flight)
            return;
        ch.queue = msg.next;
        if (!ch.queue)
            ch.queue_tail = null;
        --ch.queue_len;
        msg.next = null;
        msg.seq = ch.tx_seq;
        ch.tx_seq = (ch.tx_seq + 1) & 7;
        msg.retries = 0;
        ch.in_flight = msg;
        channel_emit(ch, endpoint, msg);
    }

    void channel_emit(ref Channel ch, ubyte endpoint, Message* msg)
    {
        msg.send_time = getTime();
        emit_frame(endpoint, iframe_control(msg.seq, ch.rx_ack, msg.poll), msg.buffer[0 .. msg.length]);
    }

    void channel_ack(ref Channel ch, ubyte endpoint, ubyte ack)
    {
        if (ch.in_flight && ack == ((ch.in_flight.seq + 1) & 7))
        {
            release_message(ch.in_flight);
            ch.in_flight = null;
            // next frame is emitted by schedule() (called at the end of ingress)
        }
    }

    // returns true when the payload is new in-sequence data the caller should deliver
    bool channel_rx_iframe(ref Channel ch, ubyte endpoint, ubyte control)
    {
        channel_ack(ch, endpoint, control & 7); // piggybacked ack

        ubyte seq = (control >> 4) & 7;
        if (seq == ch.rx_ack)
        {
            ch.rx_ack = (ch.rx_ack + 1) & 7;
            emit_frame(endpoint, sframe_control(SupervisoryFunction.ack, ch.rx_ack), null);
            return true;
        }
        if (seq == ((ch.rx_ack + 7) & 7))
        {
            // duplicate of the frame we already delivered; our ack was lost, re-ack
            emit_frame(endpoint, sframe_control(SupervisoryFunction.ack, ch.rx_ack), null);
            return false;
        }
        ubyte[1] reason = [ RejectReason.sequence_mismatch ];
        emit_frame(endpoint, sframe_control(SupervisoryFunction.reject, ch.rx_ack), reason);
        return false;
    }

    // returns false when the link is considered dead (retransmits exhausted)
    bool channel_service(ref Channel ch, ubyte endpoint, MonoTime now)
    {
        if (!ch.in_flight)
            return true;
        if (now - ch.in_flight.send_time < retransmit_timeout(ch.in_flight.retries))
            return true;
        if (ch.in_flight.retries >= _max_retransmits)
            return false;
        ++ch.in_flight.retries;
        channel_emit(ch, endpoint, ch.in_flight);
        return true;
    }

    // drop a not-yet-emitted command frame from a channel's queue by its system-command seq (buffer[1]).
    // only walks the queue, never in_flight -- an emitted frame may already have reached the secondary.
    void cancel_queued_command(ref Channel ch, ubyte seq)
    {
        Message* prev = null;
        for (Message* m = ch.queue; m; prev = m, m = m.next)
        {
            if (m.length >= 2 && m.buffer[1] == seq)
            {
                if (prev)
                    prev.next = m.next;
                else
                    ch.queue = m.next;
                if (ch.queue_tail is m)
                    ch.queue_tail = prev;
                --ch.queue_len;
                release_message(m);
                return;
            }
        }
    }

    void channel_clear(ref Channel ch)
    {
        Message* next;
        while (ch.in_flight)
        {
            next = ch.in_flight.next;
            release_message(ch.in_flight);
            ch.in_flight = next;
        }
        while (ch.queue)
        {
            next = ch.queue.next;
            release_message(ch.queue);
            ch.queue = next;
        }
        ch = Channel();
    }

    Duration retransmit_timeout(ubyte retries) const
    {
        uint timeout = cast(uint)_ack_timeout_ms << retries;
        if (timeout > 5000)
            timeout = 5000;
        return msecs(timeout);
    }
}


class CPCEndpoint : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("cpc", cpc),
                                 Prop!("endpoint", endpoint));
nothrow @nogc:

    enum type_name = "cpc-ep";
    enum path = "/interface/cpc/endpoint";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CPCEndpoint, id, flags);

        // same payload cap as the trunk (both carry the CPC payload; framing is the trunk's transport
        // overhead). max-l2mtu starts at the cap and is narrowed to the trunk's learned limit on connect.
        _max_l2mtu = cpc_max_payload;
        l2mtu = cpc_max_payload;
        mark_set!(typeof(this), "max-l2mtu")();
    }

    // Properties...

    final inout(CPCInterface) cpc() inout pure
        => _cpc;
    final void cpc(CPCInterface value)
    {
        if (_cpc.get is value)
            return;
        detach();
        _cpc = value;
        mark_set!(typeof(this), "cpc")();
        restart();
    }

    final CPCEndpointId endpoint() const pure
        => _endpoint;
    final void endpoint(CPCEndpointId value)
    {
        if (value == _endpoint)
            return;
        detach();
        _endpoint = value;
        mark_set!(typeof(this), "endpoint")();
        restart();
    }


protected:
    mixin RekeyHandler;

    // wrap the raw frame into a CPCFrame (borrowing the payload) and forward it to the trunk; the trunk
    // copies it into this endpoint's channel on transmit(), so the borrow only needs to last that call.
    override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)* queue_policy)
    {
        if (packet.type != PacketType.raw)
            return -1;
        CPCInterface trunk = _cpc.get;
        if (!trunk || !_connected)
        {
            add_tx_drop();
            return -1;
        }

        Packet cpc_packet;
        CPCFrame* f = &cpc_packet.init!CPCFrame(packet.data, packet.creation_time);
        f.endpoint = ubyte(_endpoint);
        f.control = 0; // the trunk stamps the control byte at emit
        cpc_packet.pcp = packet.pcp;
        cpc_packet.dei = packet.dei;

        if (trunk.forward(cpc_packet, callback, queue_policy) < 0)
        {
            add_tx_drop();
            return -1;
        }
        add_tx_frame(packet.data.length);
        return 0;
    }

    override bool validate() const pure
        => _cpc !is null && _endpoint != CPCEndpointId.system;

    override const(char)[] status_message() const
    {
        if (running)
            return super.status_message();
        if (!_cpc || !_cpc.running)
            return "Waiting for CPC interface";
        if (_refused)
            return "Endpoint closed on secondary";
        return "Connecting endpoint";
    }

    override CompletionStatus startup()
    {
        CPCInterface trunk = _cpc.get;
        if (!trunk || !trunk.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            trunk.subscribe(&cpc_state_change);
            _subscribed = true;
        }
        if (!_bound)
        {
            if (!trunk.bind_endpoint(this, false))
            {
                log.error("endpoint ", _endpoint, " is already bound on '", trunk.name, "'");
                return CompletionStatus.error;
            }
            _bound = true;
        }

        if (_connected)
            return CompletionStatus.complete;

        MonoTime now = getTime();
        if (!_connect_pending && (_last_attempt == MonoTime() || now - _last_attempt >= connect_retry_interval))
        {
            // only count an attempt that actually reached the wire; a submit refused because the trunk is
            // congested (ep0 struggling) isn't the endpoint's failure, so it shouldn't burn its budget.
            if (trunk.submit_connect(this))
            {
                _connect_pending = true;
                if (++_connect_attempts >= max_connect_attempts)
                {
                    log.warning("endpoint ", _endpoint, " not connecting after ", _connect_attempts,
                                " attempts; backing off");
                    return CompletionStatus.error;
                }
            }
            _last_attempt = now;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        CPCInterface trunk = _cpc.get;

        // best effort: tell the secondary we are gone so it can release the endpoint; the
        // PROP_VALUE_IS reply is deliberately unrequested (requester null) and simply dropped
        if (_connected && trunk && trunk.running)
            trunk.submit_terminate(ubyte(_endpoint));

        detach();
        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();
        // the trunk services this endpoint's retransmit timer (it owns the wire); connect retries run in
        // startup() while we are not yet Running, so nothing is needed here.
    }

package:
    // package: the trunk drives this endpoint's channel and delivery; kept package-scoped so only the
    // co-located CPCInterface reaches in.

    CPCEndpointId _endpoint = CPCEndpointId.system; // sentinel: must be configured
    bool _connected;
    Channel _channel;

    // decapsulate: the trunk hands us the endpoint payload (borrowed from its rx buffer); re-enter the
    // packet path as a RawFrame so our subscribers see it and our rx counters advance.
    void deliver_payload(const(ubyte)[] payload, MonoTime rx_time)
    {
        Packet p;
        p.init!RawFrame(payload, rx_time);
        incoming_packet(p);
    }

    void on_connect_reply(EndpointState state)
    {
        _connect_pending = false;
        if (state == EndpointState.connected)
        {
            // the secondary zeroes the endpoint's seq/ack window when it accepts the connection
            _channel = Channel();
            _refused = false;
            _connect_attempts = 0;
            _connected = true;
            // adopt the trunk's learned payload limit as our L2 cap (the trunk finished its handshake before
            // we could connect); l2mtu follows down only if it was still pinned at the old max
            if (CPCInterface trunk = _cpc.get)
            {
                ushort cap = trunk.actual_mtu;
                if (_l2mtu == _max_l2mtu || _l2mtu > cap)
                    l2mtu = cap;
                _max_l2mtu = cap;
                mark_set!(typeof(this), "max-l2mtu")();
            }
            log.info("endpoint ", _endpoint, " connected");
        }
        else
        {
            _refused = true;
            log.warning("endpoint ", _endpoint, " refused: secondary reports state ", cast(int)state);
        }
    }

    void on_connect_timeout()
    {
        _connect_pending = false;
    }

    void remote_closed()
    {
        log.warning("endpoint ", _endpoint, " closed by secondary");
        restart();
    }

private:
    ObjectRef!CPCInterface _cpc;
    bool _subscribed;
    bool _bound;
    bool _connect_pending;
    bool _refused;
    ubyte _connect_attempts;
    MonoTime _last_attempt;

    enum connect_retry_interval = 1.seconds;
    enum max_connect_attempts = 5; // connects issued per startup episode before erroring into the backoff

    void detach()
    {
        CPCInterface trunk = _cpc.get;
        _connected = false;
        _connect_pending = false;
        _refused = false;
        _connect_attempts = 0;
        _last_attempt = MonoTime();
        clear_channel(trunk);
        if (_bound)
        {
            if (trunk)
                trunk.bind_endpoint(this, true);
            _bound = false;
        }
        if (_subscribed)
        {
            if (trunk)
                trunk.unsubscribe(&cpc_state_change);
            _subscribed = false;
        }
    }

    void clear_channel(CPCInterface trunk)
    {
        Message* next;
        while (_channel.in_flight)
        {
            next = _channel.in_flight.next;
            if (trunk)
                trunk.release_message(_channel.in_flight);
            else
                defaultAllocator.freeT(_channel.in_flight);
            _channel.in_flight = next;
        }
        while (_channel.queue)
        {
            next = _channel.queue.next;
            if (trunk)
                trunk.release_message(_channel.queue);
            else
                defaultAllocator.freeT(_channel.queue);
            _channel.queue = next;
        }
        _channel = Channel();
    }

    void cpc_state_change(ActiveObject object, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
        else if (signal == StateSignal.destroyed)
        {
            // the trunk's registry and freelist die with it; drop our claims and free directly
            if (auto trunk = cast(CPCInterface)object)
                trunk.unsubscribe(&cpc_state_change);
            _subscribed = false;
            _bound = false;
            _connected = false;
            _connect_pending = false;
            clear_channel(null);
            restart();
        }
    }
}


class CPCProtocolModule : Module
{
    mixin DeclareModule!"protocol.cpc";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!CPCEndpointId();

        g_app.console.register_collection!CPCInterface();
        g_app.console.register_collection!CPCEndpoint();
    }
}


unittest
{
    // control-byte and header vectors cross-checked against cpc-daemon v4.4.5 (hdlc.h/hdlc.c/crc.c)
    assert(cpc_crc(cast(const(ubyte)[])"123456789") == 0x31C3);

    assert(iframe_control(3, 6, true) == 0x3E);
    assert(iframe_control(0, 0, false) == 0x00);
    assert(sframe_control(SupervisoryFunction.ack, 2) == 0x82);
    assert(sframe_control(SupervisoryFunction.reject, 5) == 0x95);
    assert(uframe_control(UFrameType.information) == 0xC0);
    assert(uframe_control(UFrameType.poll_final) == 0xC4);
    assert(uframe_control(UFrameType.acknowledge) == 0xCE);
    assert(uframe_control(UFrameType.reset_seq) == 0xF1);

    ubyte[cpc_header_size] header = void;
    build_frame_header(header, 5, 12, iframe_control(3, 6, true));
    assert(header[0] == cpc_flag && header[1] == 5);
    assert(header[2 .. 4][0 .. 2].littleEndianToNative!ushort == 12);
    assert(header[4] == 0x3E);
    assert(header[0 .. 5].cpc_crc() == header[5 .. 7][0 .. 2].littleEndianToNative!ushort);

    ubyte[16] cmd = void;
    size_t len = build_property_cmd(cmd, SystemCommand.prop_value_get, 7, SystemProperty.rx_capability, null);
    assert(len == 8);
    assert(cmd[0] == SystemCommand.prop_value_get && cmd[1] == 7);
    assert(cmd[2 .. 4][0 .. 2].littleEndianToNative!ushort == 4);
    assert(cmd[4 .. 8][0 .. 4].littleEndianToNative!uint == SystemProperty.rx_capability);
}


private:

enum ubyte cpc_flag = 0x14;
enum cpc_header_size = 7;
enum cpc_max_payload = 256;
enum max_channel_queue = 16;

enum FrameType : ubyte
{
    information = 0,
    supervisory = 2,
    unnumbered = 3,
}

enum UFrameType : ubyte
{
    information = 0x00,
    poll_final = 0x04,
    acknowledge = 0x0E,
    reset_seq = 0x31,
}

enum SupervisoryFunction : ubyte
{
    ack = 0,
    reject = 1,
}

enum RejectReason : ubyte
{
    no_error = 0,
    checksum_mismatch = 1,
    sequence_mismatch = 2,
    out_of_memory = 3,
    security_issue = 4,
    unreachable_endpoint = 5,
    error = 6,
}

enum SystemCommand : ubyte
{
    noop = 0x00,
    reset = 0x01,
    prop_value_get = 0x02,
    prop_value_set = 0x03,
    prop_value_is = 0x06,
}

enum SystemProperty : uint
{
    last_status = 0x00,
    protocol_version = 0x01,
    capabilities = 0x02,
    secondary_cpc_version = 0x03,
    secondary_app_version = 0x04,
    rx_capability = 0x20,
    bootloader_reboot_mode = 0x202,
    endpoint_state_0 = 0x1000,
}

// protocol v5 endpoint states (v4 numbers them differently)
enum EndpointState : ubyte
{
    freed = 0,
    open = 1,
    closed = 2,
    closing = 3,
    connecting = 4,
    connected = 5,
    shutting_down = 6,
    shut_down = 7,
    remote_shutdown = 8,
    disconnected = 9,
    error_destination_unreachable = 10,
    error_security_incident = 11,
    error_fault = 12,
}

enum status_ok = 0;
enum status_reset_first = 112; // power-on
enum status_reset_last = 120;  // watchdog

enum capability_security = 1 << 0;
enum capability_uart_flow_control = 1 << 3;

struct Message
{
    Message* next;
    MonoTime enqueue_time;  // head-of-line age, for the scheduler's PCP tiebreak
    MonoTime send_time;
    PCP pcp;
    ubyte seq;
    ubyte retries;
    bool poll;
    ushort length;
    ubyte[cpc_max_payload] buffer;
}

struct Channel
{
    ubyte tx_seq;       // next sequence number to assign
    ubyte rx_ack;       // next sequence number we expect (== the ack we advertise)
    Message* in_flight; // window is fixed at 1
    Message* queue;
    Message* queue_tail;
    uint queue_len;
}

struct PendingCommand
{
    ubyte seq;
    uint property;
    CPCEndpoint requester; // null for fire-and-forget (terminate)
    MonoTime sent;
}

ubyte iframe_control(ubyte seq, ubyte ack, bool poll) pure
    => cast(ubyte)((seq << 4) | (poll ? 0x08 : 0) | ack);

ubyte sframe_control(SupervisoryFunction func, ubyte ack) pure
    => cast(ubyte)(0x80 | (func << 4) | ack);

ubyte uframe_control(UFrameType type) pure
    => cast(ubyte)(0xC0 | type);

void build_frame_header(ref ubyte[cpc_header_size] header, ubyte endpoint, ushort length_field, ubyte control) pure
{
    header[0] = cpc_flag;
    header[1] = endpoint;
    header[2 .. 4][0 .. 2] = length_field.nativeToLittleEndian;
    header[4] = control;
    header[5 .. 7][0 .. 2] = header[0 .. 5].cpc_crc().nativeToLittleEndian;
}

size_t build_property_cmd(ref ubyte[16] buffer, SystemCommand cmd, ubyte seq, uint property, const(ubyte)[] value)
{
    buffer[0] = cmd;
    buffer[1] = seq;
    buffer[2 .. 4][0 .. 2] = nativeToLittleEndian(cast(ushort)(4 + value.length));
    buffer[4 .. 8][0 .. 4] = nativeToLittleEndian(property);
    buffer[8 .. 8 + value.length] = value[];
    return 8 + value.length;
}
