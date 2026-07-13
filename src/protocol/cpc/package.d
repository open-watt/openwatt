module protocol.cpc;

// Silicon Labs CPC (Co-Processor Communication) transport for multiprotocol / "multi-PAN" RCPs.
//
// CPC is the serial transport a Silabs multiprotocol radio co-processor speaks: one UART carrying many
// logical protocols at once (Zigbee, OpenThread/802.15.4, Bluetooth HCI, ...). It does the same
// reliable-framing job as ASH (protocol/ezsp/ashv2.d) but MULTIPLEXES: numbered endpoints, each with its
// own seq/ack window, plus a control endpoint (0, SYSTEM) used to reset the secondary, read its
// version/capabilities, and connect/terminate the protocol endpoints. Mental model is "USB for a UART":
// endpoint 0 is the control endpoint, the rest are addressed data channels.
//
// Wire format implemented from cpc-daemon v4.4.5 source (nearest tag to the deployed secondary's 4.4.4;
// server_core/core/hdlc.h, crc.c, system_endpoint/system.h, core.c). Protocol version 5 only.
// Frames are NOT byte-stuffed: 7-byte header (flag 0x14, endpoint, LE length, control, LE HCS) delimits
// exactly, resync scans for a flag byte with a valid HCS. Both CRCs are CRC-16/XMODEM, little-endian.
// The length field counts payload + 2-byte FCS, or 0 for no payload (then no FCS either).
//
//   Serial (Stream)
//     +-- CPCInterface : BaseInterface        the trunk: owns the stream, framing, ep0 reset/interrogation
//           +-- CPCEndpoint : BaseInterface   one child per connected endpoint, bound to the trunk the way
//                                             VLANInterface binds to its trunk; delivers raw packets
//
// Upper clients bind to the ENDPOINT interface's raw frames, never to CPC directly, exactly as the EZSP
// client consumes ASH. The multiprotocol image is an RCP (thin radio), NOT a Zigbee NCP: the Zigbee PRO
// stack lives on the host in Silabs' model (zigbeed), so there is no EZSP NCP behind the zigbee endpoint.
// First consumer here is Thread / 802.15.4 via Spinel riding the openthread endpoint.
//
// TODO:
//   [ ] SpinelClient (commit 1b105431, currently dropped from the tree): split into transport-agnostic
//       codec + framing consumer so it rides either HDLC-over-serial (bare ot-rcp) or a CPCEndpoint
//       (CPC frames need no HDLC). Bind /protocol/spinel/client to the "openthread" endpoint.
//   [ ] Bluetooth HCI endpoint feeding protocol/ble
//   [ ] CPC security sessions (AES-GCM over endpoint 1): detected and refused today
//   [ ] protocol v4 secondaries (different endpoint-state values); v5 only today
//   [ ] tx window > 1 and adaptive RTO: window is fixed at 1 (all Silabs host libs do the same today)
//   [ ] PROP_PRIMARY_VERSION_VALUE set + bus-bitrate verification (informational; cpcd sends them)
//
// TODO: revisit the trunk/ep0 data-plane modelling to mirror VLAN exactly. The trunk carries ALL the
//   traffic in framed form (every CPC frame on the wire, like a VLAN trunk carrying tagged frames);
//   each CPCEndpoint carries the decapsulated payload for its own ep (like a VLAN sub-interface for its
//   vid). So the trunk should route frames through its OWN packet path (a real transmit() + a CPC packet
//   type carrying endpoint+control), demuxing to the child on rx the way BaseInterface.dispatch demuxes
//   vlans, instead of the private emit_frame/on_bytes bypass it uses today. Counters then fall out: the
//   trunk counts every framed unit, each endpoint counts its decapped frames. transmit() is a dead -1
//   stub today and ep0 is handled entirely out-of-band.

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
import router.stream;

//version = DebugCPCMessageFlow;

nothrow @nogc:


alias cpc_crc = calculate_crc!(Algorithm.crc16_xmodem);

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
                                 Prop!("protocol-version", protocol_version, "status"),
                                 Prop!("secondary-version", secondary_version, "status"),
                                 Prop!("app-version", app_version, "status"),
                                 Prop!("rx-payload-max", max_tx_payload, "status"));
nothrow @nogc:

    enum type_name = "cpc";
    enum path = "/interface/cpc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CPCInterface, id, flags);
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
        restart();
    }

    final ubyte retransmits() const pure
        => _max_retransmits;
    final StringResult retransmits(ubyte value)
    {
        if (value < 1 || value > 15)
            return StringResult("retransmits must be between 1 and 15");
        _max_retransmits = value;
        return StringResult.success;
    }

    final ushort ack_timeout() const pure
        => _ack_timeout_ms;
    final StringResult ack_timeout(ushort value)
    {
        if (value < 50 || value > 5000)
            return StringResult("ack-timeout must be between 50ms and 5000ms");
        _ack_timeout_ms = value;
        return StringResult.success;
    }

    final ubyte protocol_version() const pure
        => _protocol_version;

    final const(char)[] secondary_version() const pure
        => _secondary_version[0 .. _secondary_version_len];

    final const(char)[] app_version() const pure
        => _app_version[0 .. _app_version_len];

    // largest payload the secondary can receive in one frame (learned during the reset sequence)
    final ushort max_tx_payload() const pure
        => _rx_capability < cpc_max_payload ? _rx_capability : cpc_max_payload;


    // API...

    override int transmit(ref Packet packet, MessageCallback)
    {
        // data rides on the endpoint interfaces; the trunk carries no packets of its own
        return -1;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _stream !is null;

    override const(char)[] status_message() const
    {
        if (running)
            return super.status_message();
        if (!_stream || !_stream.running)
            return "Waiting for stream";
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
                    // the secondary isn't answering the handshake; kick the serial path so a stopped
                    // or saturated tty output queue can't starve every retry behind the same bytes
                    log.warning("no response from CPC secondary (handshake step ", cast(int)_phase,
                                "); restarting stream '", _stream.name, "'");
                    _stream.restart();
                    return CompletionStatus.continue_;
                }
                emit_frame(0, uframe_control(UFrameType.poll_final), _ucmd_buffer[0 .. _ucmd_len]);
                _ucmd_sent = now;
            }
            return CompletionStatus.continue_;
        }

        if (_phase == Phase.wait_reset_reason)
        {
            // the reset reason is announced unsolicited once the secondary reboots
            if (now - _phase_start >= reset_reason_timeout)
            {
                if (++_reset_attempts >= 3)
                {
                    log.error("secondary never announced its reset; restarting stream '", _stream.name, "'");
                    _reset_attempts = 0;
                    _stream.restart();
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

        channel_clear(_ep0);
        _pending_cmds.clear();

        // children hold their messages until their own shutdown; this only frees the idle pool
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
            log.error("system endpoint unresponsive: no ack after ", _max_retransmits, " retransmits");
            restart();
            return;
        }

        for (size_t i = _pending_cmds.length; i > 0; )
        {
            --i;
            if (now - _pending_cmds[i].sent < icmd_timeout)
                continue;
            CPCEndpoint requester = _pending_cmds[i].requester;
            _pending_cmds.remove(i);
            if (requester)
                requester.on_connect_timeout();
        }
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

    ushort _ack_timeout_ms = 500;
    ubyte _max_retransmits = 10;

    Channel _ep0;
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
        ubyte seq = _command_seq++;
        uint prop = SystemProperty.endpoint_state_0 | endpoint;
        ubyte[1] value = [ state ];
        ubyte[16] cmd = void;
        size_t len = build_property_cmd(cmd, SystemCommand.prop_value_set, seq, prop, value);
        if (!channel_submit(_ep0, 0, cmd[0 .. len], true))
            return false;
        _pending_cmds ~= PendingCommand(seq, prop, requester, getTime());
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
                if (value.length >= 2)
                    _rx_capability = value[0 .. 2][0 .. 2].littleEndianToNative!ushort;
                _phase = Phase.protocol_version;
                break;
            case Phase.protocol_version:
                _protocol_version = value.length ? value[0] : 0;
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
                _phase = Phase.done;
                log.info("secondary CPC ", secondary_version, " (", app_version, "), protocol v", _protocol_version,
                         ", max payload ", max_tx_payload);
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
                // only possible if resync never finds a frame in a full buffer of garbage
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
                // a valid HCS with an impossible length (payload zone can't hold its own FCS)
                ++start;
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
                    process_frame(endpoint, control, payload, rx_time);
            }
            else
                process_frame(endpoint, control, null, rx_time);

            // a packet subscriber under process_frame may run arbitrary code; if anything tore
            // this interface down, the rx buffer was cleared beneath the cursor
            if (!_subscribed)
                return;

            start += frame_len;
        }

        _rx_offset -= start;
        if (start > 0 && _rx_offset > 0)
        {
            import urt.mem : memmove;
            memmove(_rx_buffer.ptr, _rx_buffer.ptr + start, _rx_offset);
        }
    }

    ubyte channel_ack_for(ubyte endpoint) pure
    {
        if (endpoint == 0)
            return _ep0.rx_ack;
        if (CPCEndpoint child = find_endpoint(endpoint))
            return child._channel.rx_ack;
        return 0;
    }

    void process_frame(ubyte endpoint, ubyte control, const(ubyte)[] payload, MonoTime rx_time)
    {
        version (DebugCPCMessageFlow)
            log.tracef("<-- ep {0} ctrl [{1,02x}] {2} bytes", endpoint, control, payload.length);

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
                    child.endpoint_incoming(payload, rx_time);
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
            if (!ch)
                return;
            if (func == SupervisoryFunction.ack)
                channel_ack(*ch, endpoint, ack);
            else if (func == SupervisoryFunction.reject)
            {
                RejectReason reason = payload.length ? cast(RejectReason)payload[0] : RejectReason.error;
                channel_ack(*ch, endpoint, ack);
                final switch (reason)
                {
                    case RejectReason.checksum_mismatch:
                        if (ch.in_flight)
                            channel_emit(*ch, endpoint, ch.in_flight);
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
                        if (child)
                            child.restart();
                        else
                            _restart_pending = true; // never restart the trunk from its own rx path
                        break;
                }
            }
        }
        else // unnumbered: system endpoint control traffic only, outside any seq/ack window
        {
            if (endpoint != 0)
                return;
            ubyte utype = control & 0x3F;
            if (utype == UFrameType.information || utype == UFrameType.poll_final)
                process_system_message(payload);
            // acknowledge (0x0E) answers a RESET_SEQ we never send; anything else is ignorable
        }
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
                            // the boot announcement is the synchronisation point the reset sequence
                            // exists to reach; it may arrive before our commands get a look-in when
                            // opening the serial port hardware-resets the dongle (RTS/DTR wire to
                            // the EFR32 reset on some boards), or mid-interrogation on a crash
                            log.debug_("secondary booted, reset reason ", status);
                            _ucmd_active = false; // any in-flight command died with the reboot
                            channel_clear(_ep0);
                            _pending_cmds.clear();
                            _reset_attempts = 0;
                            _phase = Phase.rx_capability;
                        }
                        else
                        {
                            // an unprompted reboot invalidates every endpoint and window on the
                            // link; restarting here would clear the rx buffer parse_buffer is
                            // iterating, so leave it for the state machine
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
                        if (child._connected && state != EndpointState.connected && state != EndpointState.open)
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

    // per-endpoint ARQ (window fixed at 1; seq/ack are 3 bits, arithmetic mod 8)

    Message* alloc_message()
    {
        Message* msg = _free_messages;
        if (msg)
            _free_messages = msg.next;
        else
            msg = defaultAllocator.allocT!Message();
        msg.next = null;
        msg.send_time = MonoTime();
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

    bool channel_submit(ref Channel ch, ubyte endpoint, const(ubyte)[] payload, bool poll)
    {
        if (ch.queue_len >= max_channel_queue)
        {
            log.warning("endpoint ", endpoint, " tx queue full (", max_channel_queue, "); rejecting frame");
            return false;
        }
        Message* msg = alloc_message();
        msg.poll = poll;
        msg.length = cast(ushort)payload.length;
        msg.buffer[0 .. payload.length] = payload[];
        if (!ch.queue)
            ch.queue = msg;
        else
        {
            Message* m = ch.queue;
            while (m.next)
                m = m.next;
            m.next = msg;
        }
        ++ch.queue_len;
        if (!ch.in_flight)
            channel_send_next(ch, endpoint);
        return true;
    }

    void channel_send_next(ref Channel ch, ubyte endpoint)
    {
        Message* msg = ch.queue;
        if (!msg)
            return;
        ch.queue = msg.next;
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
            channel_send_next(ch, endpoint);
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

    enum type_name = "cpc-endpoint";
    enum path = "/interface/cpc/endpoint";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CPCEndpoint, id, flags);
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
        restart();
    }


    // API...

    override int transmit(ref Packet packet, MessageCallback)
    {
        if (packet.type != PacketType.raw)
            return -1;
        CPCInterface trunk = _cpc.get;
        const(ubyte)[] message = cast(const(ubyte)[])packet.data;
        if (!trunk || !_connected || message.length == 0 || message.length > trunk.max_tx_payload)
        {
            add_tx_drop();
            return -1;
        }
        if (!trunk.channel_submit(_channel, ubyte(_endpoint), message, false))
        {
            add_tx_drop();
            return -1;
        }
        add_tx_frame(message.length);
        return 0;
    }

protected:
    mixin RekeyHandler;

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
            _connect_pending = trunk.submit_connect(this);
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

        CPCInterface trunk = _cpc.get;
        if (!trunk || !_connected)
            return;
        if (!trunk.channel_service(_channel, ubyte(_endpoint), getTime()))
        {
            log.error("endpoint ", _endpoint, " unresponsive: no ack after retransmits; reconnecting");
            restart();
        }
    }

private:
    ObjectRef!CPCInterface _cpc;
    CPCEndpointId _endpoint = CPCEndpointId.system; // sentinel: must be configured
    bool _subscribed;
    bool _bound;
    bool _connected;
    bool _connect_pending;
    bool _refused;
    MonoTime _last_attempt;
    Channel _channel;

    enum connect_retry_interval = 1.seconds;

    void detach()
    {
        CPCInterface trunk = _cpc.get;
        _connected = false;
        _connect_pending = false;
        _refused = false;
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

    // trunk callbacks

    void endpoint_incoming(const(ubyte)[] payload, MonoTime rx_time)
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
            _connected = true;
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
    MonoTime send_time;
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
