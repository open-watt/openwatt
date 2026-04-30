module protocol.ip.tcp;

import urt.array;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.time;

import router.iface;
import router.iface.packet;

import protocol.ip.icmp;
import protocol.ip.stack;

//version = DebugTCP;       // buffering / transmission characteristics
//version = DebugTCPProto;  // every segment in/out, state transitions, options

private alias log = Log!"tcp";

nothrow @nogc:


// TODO: Path MTU Discovery is not implemented.
//
// We currently seed pcb.send_mss from the local egress interface's MTU at
// connection setup (refresh_route()), and lower it further if the peer
// advertises a smaller MSS in its SYN. That covers two of the three bounds
// on effective MSS:
//
//   1. local link MTU             - covered (egress.actual_mtu - 40)
//   2. peer's receive MSS         - covered (parse_options)
//   3. path MTU (smallest hop)    - NOT COVERED
//
// If any router along the path has a smaller MTU than our local link, every
// full-sized segment we send will be dropped at that hop. Routers signal
// this via ICMP "Fragmentation Needed" (type 3, code 4) carrying the
// next-hop MTU in the ICMP code_data field. Real TCP stacks set the DF
// (Don't Fragment) bit on outgoing segments, catch the resulting ICMP, and
// lower send_mss for that destination, then retransmit.
//
// What we do instead today: nothing. icmp_input() ignores
// dest_unreachable/frag_needed. A connection over a path with a sub-link
// bottleneck will retransmit the same oversized segments until the retry
// counter exhausts and the connection fails.
//
// Resolution requires:
//   - Set IP DF flag on outgoing TCP segments (currently flags_frag = 0).
//   - In icmp_input(), recognize type=3 code=4, locate the PCB by parsing
//     the quoted IP+TCP header in the ICMP body, lower pcb.send_mss to the
//     advertised next-hop MTU - 40 (clamped to TcpDefaultMss = 536 floor).
//   - Mark snd_una..snd_nxt for immediate retransmission so the lowered
//     MSS takes effect without waiting for the RTO.
//
// Until this lands, OpenWatt's TCP works correctly only when the path MTU
// equals the local link MTU - which is the LAN-only case we currently
// deploy in. Tunneled / WAN paths with smaller intermediate MTUs will
// stall connections.


// -------------------------------------------------------------------------
// Constants

enum TcpState : ubyte
{
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,
}

enum TcpFlag : ubyte
{
    fin = 1 << 0,
    syn = 1 << 1,
    rst = 1 << 2,
    psh = 1 << 3,
    ack = 1 << 4,
    urg = 1 << 5,
    ece = 1 << 6,
    cwr = 1 << 7,
}

enum TcpOptionKind : ubyte
{
    end_of_options = 0,
    nop            = 1,
    mss            = 2,
    window_scale   = 3,
    sack_permitted = 4,
    sack           = 5,
    timestamp      = 8,
}

enum size_t TcpDefaultMss     = 536;        // RFC 1122 minimum
enum size_t TcpEthernetMss    = 1460;       // 1500 - 20 IP - 20 TCP
enum size_t TcpSendBufSize    = 8192;
enum size_t TcpRecvBufSize    = 8192;
enum size_t TcpAcceptQueueMax = 16;

enum uint  TcpInitialRtoMs = 1000;
enum uint  TcpMaxRtoMs     = 60_000;
enum ubyte TcpMaxRetries   = 5;
enum uint  TcpTimeWaitMs   = 60_000;        // 2 * MSL with MSL=30s


// -------------------------------------------------------------------------
// Wire format

struct TcpHeader
{
nothrow @nogc:
align(1):
    ubyte[2] src_port;
    ubyte[2] dst_port;
    ubyte[4] seq;
    ubyte[4] ack;
    ubyte    data_offset_reserved;      // upper 4 bits = data offset (32-bit words)
    ubyte    flags;
    ubyte[2] window;
    ubyte[2] checksum;
    ubyte[2] urgent;

    ubyte data_offset() const pure
        => data_offset_reserved >> 4;
    void  data_offset(ubyte n) pure
    {
        data_offset_reserved = cast(ubyte)((n & 0x0F) << 4);
    }
}
static assert(TcpHeader.sizeof == 20);


// -------------------------------------------------------------------------
// PCB

struct TcpPcb
{
    // Monotonic per-PCB id; lets log lines correlate across a single
    // connection's lifetime amid mixed traffic. Assigned in tcp_register.
    uint id;

    // 4-tuple
    IPAddr  local_addr;
    ushort  local_port;
    IPAddr  remote_addr;
    ushort  remote_port;

    TcpState state;

    // Send sequence space
    uint snd_iss;       // initial send seq
    uint snd_una;       // oldest unacked seq
    uint snd_nxt;       // next seq to send
    uint snd_wnd;       // peer's advertised window

    // Receive sequence space
    uint rcv_irs;       // peer's initial seq
    uint rcv_nxt;       // next expected seq
    uint rcv_wnd;       // our advertised window

    ushort send_mss;    // MSS we'll use when sending (peer's MSS or default)

    // Cached route. Refreshed when route_generation() ticks; lets transmit
    // skip per-segment route lookup and lets MSS track the egress MTU.
    BaseInterface route_egress;
    IPAddr   route_next_hop;
    uint     route_gen;

    // Send/recv buffers (linear; recv_buf[0] is at sequence rcv_irs+1 + read_offset
    // — we slide both via Array.remove on consume)
    Array!ubyte send_buf;
    Array!ubyte recv_buf;

    // Flags
    bool fin_sent;          // we've sent FIN (snd_nxt includes its sequence)
    bool fin_seen;          // peer sent FIN
    bool fin_pending;       // app closed; FIN to be sent once send_buf drains

    // Retransmit timing
    MonoTime last_send;
    uint     rto_ms;
    ubyte    retries;

    // Time-wait
    MonoTime time_wait_start;

    // Listen-state state:
    Array!(TcpPcb*) accept_queue;       // completed conns awaiting accept
    Array!(TcpPcb*) child_list;         // all children (synrcvd + accept queue) for cleanup

    // Set on child PCBs to reference the listener that spawned them.
    TcpPcb* parent;

    // Owner socket handle (set by socket layer).
    int handle;

    bool is_listener;

    // Pending notifications consumed by the socket layer.
    bool readable_event;
    bool writable_event;
    bool accept_event;
    bool error_event;
}


// -------------------------------------------------------------------------
// PCB registry

__gshared Array!(TcpPcb*) _pcbs;
__gshared uint _pcb_next_id = 1;


void tcp_register(TcpPcb* pcb)
{
    if (pcb.id == 0)
        pcb.id = _pcb_next_id++;
    _pcbs ~= pcb;
}

void tcp_unregister(TcpPcb* pcb)
{
    foreach (i, p; _pcbs[])
    {
        if (p is pcb)
        {
            _pcbs.remove(i);
            return;
        }
    }
}


// -------------------------------------------------------------------------
// Public API

void tcp_listen(TcpPcb* pcb)
{
    pcb.state        = TcpState.listen;
    pcb.is_listener  = true;
    pcb.rcv_wnd      = TcpRecvBufSize;
    version (DebugTCP)
        log.trace("c", pcb.id, " listen :", pcb.local_port);
}

bool tcp_connect(ref IPStack stack, TcpPcb* pcb)
{
    if (pcb.local_port == 0 || pcb.remote_port == 0)
        return false;
    refresh_route(stack, pcb);
    if (!pcb.route_egress)
        return false;
    if (pcb.local_addr == IPAddr.any)
        pcb.local_addr = stack.select_source_v4(pcb.remote_addr);
    if (pcb.local_addr == IPAddr.any)
        return false;

    pcb.snd_iss   = generate_iss();
    pcb.snd_una   = pcb.snd_iss;
    pcb.snd_nxt   = pcb.snd_iss + 1;        // SYN consumes one sequence
    pcb.rcv_wnd   = TcpRecvBufSize;
    pcb.rto_ms    = TcpInitialRtoMs;
    pcb.state     = TcpState.syn_sent;

    version (DebugTCP)
        log.trace("c", pcb.id, " connect ", pcb.local_addr, ':', pcb.local_port, " -> ", pcb.remote_addr, ':', pcb.remote_port);

    send_segment_at(stack, pcb, TcpFlag.syn, pcb.snd_iss, null);
    pcb.last_send = getTime();
    return true;
}

void tcp_close(ref IPStack stack, TcpPcb* pcb)
{
    version (DebugTCP)
        log.trace("c", pcb.id, " close :", pcb.local_port, "->:", pcb.remote_port, " state=", pcb.state);

    final switch (pcb.state) with (TcpState)
    {
        case closed:
            return;
        case listen:
            // RST any unaccepted children. Accepted children have already been
            // removed from child_list by tcp_accept and are independent.
            foreach (c; pcb.child_list[])
            {
                c.parent = null;        // detach so free_pcb doesn't try to remove
                if (c.state != closed)
                    send_segment_at(stack, c, TcpFlag.rst, c.snd_nxt, null);
                c.state = closed;
                tcp_unregister(c);
                free_pcb(c);
            }
            pcb.child_list.clear();
            pcb.accept_queue.clear();
            pcb.state = closed;
            tcp_unregister(pcb);
            return;
        case syn_sent:
            pcb.state = closed;
            tcp_unregister(pcb);
            return;
        case syn_received:
        case established:
        case close_wait:
            // Defer FIN until queued data has drained from send_buf;
            // transmit_pending will emit it and transition state.
            pcb.fin_pending = true;
            transmit_pending(stack, pcb);
            return;
        case fin_wait_1:
        case fin_wait_2:
        case closing:
        case last_ack:
        case time_wait:
            return;     // already winding down
    }
}

size_t tcp_send_data(ref IPStack stack, TcpPcb* pcb, const(ubyte)[] data)
{
    if (pcb.state != TcpState.established && pcb.state != TcpState.close_wait)
        return 0;

    size_t free = TcpSendBufSize - pcb.send_buf.length;
    size_t n = data.length < free ? data.length : free;

    version (DebugTCP)
    {
        if (n < data.length)
            log.trace("c", pcb.id, " send req=", data.length, " accepted=", n, " buf=", pcb.send_buf.length + n, '/', TcpSendBufSize, " (full)");
        else if (data.length > 0)
            log.trace("c", pcb.id, " send req=", data.length, " accepted=", n, " buf=", pcb.send_buf.length + n, '/', TcpSendBufSize);
    }

    if (n == 0)
        return 0;

    pcb.send_buf ~= data[0 .. n];
    transmit_pending(stack, pcb);
    return n;
}

size_t tcp_recv_data(TcpPcb* pcb, ubyte[] buf)
{
    size_t avail = pcb.recv_buf.length;
    size_t n = buf.length < avail ? buf.length : avail;
    if (n == 0)
        return 0;

    buf[0 .. n] = pcb.recv_buf[0 .. n];
    pcb.recv_buf.remove(0, n);
    pcb.rcv_wnd = cast(uint)(TcpRecvBufSize - pcb.recv_buf.length);
    return n;
}

bool tcp_accept(TcpPcb* listener, out TcpPcb* accepted)
{
    if (!listener.is_listener || listener.accept_queue.length == 0)
        return false;
    accepted = listener.accept_queue[0];
    listener.accept_queue.remove(0);
    // Accepted child is now independent: remove from parent's child_list,
    // null parent ref so its later cleanup doesn't try to remove from us.
    foreach (i, c; listener.child_list[])
    {
        if (c is accepted)
        {
            listener.child_list.remove(i);
            break;
        }
    }
    accepted.parent = null;
    return true;
}

void tcp_shutdown_write(ref IPStack stack, TcpPcb* pcb)
{
    if (pcb.state == TcpState.established || pcb.state == TcpState.close_wait)
    {
        pcb.fin_pending = true;
        transmit_pending(stack, pcb);
    }
}


// -------------------------------------------------------------------------
// Ingress

void tcp_input(ref IPStack stack, ref Packet pkt)
{
    if (pkt.data.length < IPv4Header.sizeof + TcpHeader.sizeof)
        return;
    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    if (pkt.data.length < ip_hdr_len + TcpHeader.sizeof)
        return;

    // Trim to IP total_length: Ethernet pads small frames to 46-byte minimum
    // payload, and pkt.data may include those padding bytes.
    size_t ip_total = (size_t(ip.total_length[0]) << 8) | ip.total_length[1];
    if (ip_total < ip_hdr_len + TcpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] tcp_seg = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. ip_total];
    const t = cast(const TcpHeader*)tcp_seg.ptr;

    size_t tcp_hdr_len = t.data_offset * 4;
    if (tcp_hdr_len < TcpHeader.sizeof || tcp_hdr_len > tcp_seg.length)
        return;

    // Verify TCP checksum (pseudo-header + segment).
    ushort pseudo = pseudo_header_checksum_v4(ip.src, ip.dst, IpProtocol.tcp, cast(ushort)tcp_seg.length);
    ushort calc = internet_checksum(tcp_seg, pseudo);
    if (calc != 0)
        return;

    ushort src_port = be_u16(t.src_port);
    ushort dst_port = be_u16(t.dst_port);
    uint   seq      = be_u32(t.seq);
    uint   ack      = be_u32(t.ack);
    uint   wnd      = be_u16(t.window);
    ubyte  flags    = t.flags;
    const(ubyte)[] payload = tcp_seg[tcp_hdr_len .. $];

    TcpPcb* pcb = find_pcb_4tuple(ip.dst, dst_port, ip.src, src_port);
    if (!pcb)
        pcb = find_listener(ip.dst, dst_port);

    if (!pcb)
    {
        if (!(flags & TcpFlag.rst))
            send_rst_for_unknown(stack, ip.src, src_port, ip.dst, dst_port, seq, ack, flags, payload.length);
        return;
    }

    process_segment(stack, pcb, ip, t, seq, ack, wnd, flags, payload);
}


// -------------------------------------------------------------------------
// Tick (retransmit + time-wait expiry)

void tcp_tick(ref IPStack stack, MonoTime now)
{
    Array!(TcpPcb*) doomed;

    foreach (pcb; _pcbs[])
    {
        // Time-wait expiry
        if (pcb.state == TcpState.time_wait)
        {
            if (now - pcb.time_wait_start >= TcpTimeWaitMs.msecs)
            {
                pcb.state = TcpState.closed;
                doomed ~= pcb;
            }
            continue;
        }

        // Retransmit unacked data / control
        bool has_unacked = false;
        switch (pcb.state) with (TcpState)
        {
            case syn_sent:
            case syn_received:
                has_unacked = true;
                break;
            case established:
            case fin_wait_1:
            case fin_wait_2:
            case close_wait:
            case closing:
            case last_ack:
                has_unacked = (pcb.snd_una != pcb.snd_nxt);
                break;
            default:
                break;
        }
        if (!has_unacked)
            continue;

        if (now - pcb.last_send < pcb.rto_ms.msecs)
            continue;

        if (pcb.retries >= TcpMaxRetries)
        {
            version (DebugTCP)
                log.warning("c", pcb.id, " abort: max retries exhausted in state=", pcb.state, " (peer unreachable?)");
            pcb.error_event = true;
            pcb.state = TcpState.closed;
            doomed ~= pcb;
            continue;
        }
        ++pcb.retries;
        pcb.rto_ms = pcb.rto_ms * 2;
        if (pcb.rto_ms > TcpMaxRtoMs)
            pcb.rto_ms = TcpMaxRtoMs;

        retransmit(stack, pcb);
        pcb.last_send = now;
    }

    foreach (pcb; doomed[])
    {
        tcp_unregister(pcb);
        // The socket layer owns the PCB allocation; it'll free it after observing
        // the error/closed state. If there's no socket attached (handle == 0),
        // free here.
        if (pcb.handle == 0)
            free_pcb(pcb);
    }
}


// -------------------------------------------------------------------------
// State machine

private:

void process_segment(ref IPStack stack, TcpPcb* pcb, const IPv4Header* ip, const TcpHeader* t,
                     uint seq, uint ack, uint wnd, ubyte flags, const(ubyte)[] payload)
{
    version (DebugTCPProto)
        log.trace("c", pcb.id, " << ", flags_str(flags), " seq=", seq, " ack=", ack, " len=", payload.length, " wnd=", wnd, " state=", pcb.state);

    // RFC 793 §3.9 ordered processing.

    // ---------- LISTEN ----------
    if (pcb.state == TcpState.listen)
    {
        if (flags & TcpFlag.rst)
            return;
        if (flags & TcpFlag.ack)
        {
            send_rst_for_unknown(stack, ip.src, be_u16(t.src_port),
                                 ip.dst, be_u16(t.dst_port), seq, ack, flags, payload.length);
            return;
        }
        if (flags & TcpFlag.syn)
            spawn_child_from_listen(stack, pcb, ip, t, seq, wnd);
        return;
    }

    // ---------- SYN_SENT ----------
    if (pcb.state == TcpState.syn_sent)
    {
        bool acceptable_ack = false;
        if (flags & TcpFlag.ack)
        {
            if (seq_le(ack, pcb.snd_iss) || seq_gt(ack, pcb.snd_nxt))
            {
                if (!(flags & TcpFlag.rst))
                    send_segment_raw(stack, pcb.local_addr, pcb.local_port,
                                     pcb.remote_addr, pcb.remote_port,
                                     ack, 0, TcpFlag.rst, 0, null);
                return;
            }
            acceptable_ack = true;
        }
        if (flags & TcpFlag.rst)
        {
            if (acceptable_ack)
            {
                version (DebugTCP)
                    log.warning("c", pcb.id, " RST during connect (refused) ", pcb.remote_addr, ':', pcb.remote_port);
                pcb.state = TcpState.closed;
                pcb.error_event = true;
                tcp_unregister(pcb);
            }
            return;
        }
        if (flags & TcpFlag.syn)
        {
            pcb.rcv_irs = seq;
            pcb.rcv_nxt = seq + 1;
            if (acceptable_ack)
                pcb.snd_una = ack;
            pcb.snd_wnd = wnd;
            parse_options(t, pcb);

            if (seq_gt(pcb.snd_una, pcb.snd_iss))
            {
                pcb.state = TcpState.established;
                version (DebugTCP)
                    log.trace("c", pcb.id, " established (active) mss=", pcb.send_mss, " peer_wnd=", pcb.snd_wnd);
                send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
                pcb.writable_event = true;
                pcb.retries = 0;
                pcb.rto_ms  = TcpInitialRtoMs;
            }
            else
            {
                // Simultaneous open
                pcb.state = TcpState.syn_received;
                send_segment_at(stack, pcb, TcpFlag.syn | TcpFlag.ack, pcb.snd_iss, null);
            }
        }
        return;
    }

    // ---------- Synchronized states ----------

    // 1. Sequence number check
    if (!check_in_window(pcb, seq, payload.length, flags))
    {
        if (!(flags & TcpFlag.rst))
            send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
        return;
    }

    // 2. RST
    if (flags & TcpFlag.rst)
    {
        if (pcb.state == TcpState.syn_received && pcb.parent)
        {
            // Refused passive open
            version (DebugTCP)
                log.warning("c", pcb.id, " RST during passive open from ", pcb.remote_addr, ':', pcb.remote_port);
            remove_child(pcb.parent, pcb);
            pcb.state = TcpState.closed;
            tcp_unregister(pcb);
            free_pcb(pcb);
        }
        else
        {
            version (DebugTCP)
                log.warning("c", pcb.id, " RST in state=", pcb.state, " from ", pcb.remote_addr, ':', pcb.remote_port);
            pcb.state = TcpState.closed;
            pcb.error_event = true;
            tcp_unregister(pcb);
        }
        return;
    }

    // 3. SYN in synchronized state -> connection has been broken
    if (flags & TcpFlag.syn)
    {
        version (DebugTCP)
            log.warning("c", pcb.id, " SYN in synchronized state=", pcb.state, " (peer crashed?); aborting");
        send_segment_at(stack, pcb, TcpFlag.rst, pcb.snd_nxt, null);
        pcb.state = TcpState.closed;
        pcb.error_event = true;
        tcp_unregister(pcb);
        return;
    }

    // 4. ACK
    if (!(flags & TcpFlag.ack))
        return;

    if (pcb.state == TcpState.syn_received)
    {
        if (seq_le(pcb.snd_una, ack) && seq_le(ack, pcb.snd_nxt))
        {
            pcb.snd_una = ack;
            pcb.snd_wnd = wnd;
            pcb.state = TcpState.established;
            version (DebugTCP)
                log.trace("c", pcb.id, " established (passive) mss=", pcb.send_mss, " peer_wnd=", pcb.snd_wnd);
            pcb.retries = 0;
            pcb.rto_ms = TcpInitialRtoMs;

            if (pcb.parent)
            {
                if (pcb.parent.accept_queue.length < TcpAcceptQueueMax)
                {
                    pcb.parent.accept_queue ~= pcb;
                    pcb.parent.accept_event = true;
                }
                else
                {
                    send_segment_at(stack, pcb, TcpFlag.rst, pcb.snd_nxt, null);
                    remove_child(pcb.parent, pcb);
                    pcb.state = TcpState.closed;
                    tcp_unregister(pcb);
                    free_pcb(pcb);
                    return;
                }
            }
        }
        else
        {
            send_segment_at(stack, pcb, TcpFlag.rst, ack, null);
            return;
        }
    }

    if (pcb.state == TcpState.established ||
        pcb.state == TcpState.fin_wait_1 ||
        pcb.state == TcpState.fin_wait_2 ||
        pcb.state == TcpState.close_wait ||
        pcb.state == TcpState.closing  ||
        pcb.state == TcpState.last_ack)
    {
        if (seq_lt(ack, pcb.snd_una))
        {
            // Stale duplicate ACK - ignore
        }
        else if (seq_gt(ack, pcb.snd_nxt))
        {
            send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
            return;
        }
        else if (seq_lt(pcb.snd_una, ack) || ack == pcb.snd_una)
        {
            uint acked_total = ack - pcb.snd_una;
            pcb.snd_una = ack;
            pcb.snd_wnd = wnd;
            pcb.retries = 0;
            pcb.rto_ms  = TcpInitialRtoMs;

            // FIN-was-sent and FIN-is-acked accounting:
            // If fin_sent, the last sequence (snd_nxt - 1) is the FIN's sequence (no byte in send_buf).
            // The number of *data* bytes acked = acked_total - (1 if FIN now acked else 0).
            uint data_acked = acked_total;
            if (pcb.fin_sent && ack == pcb.snd_nxt && data_acked > 0)
                data_acked -= 1;

            if (data_acked > pcb.send_buf.length)
                data_acked = cast(uint)pcb.send_buf.length;
            if (data_acked > 0)
            {
                pcb.send_buf.remove(0, data_acked);
                version (DebugTCP)
                    log.trace("c", pcb.id, " ack +", data_acked, "B buf=", pcb.send_buf.length, '/', TcpSendBufSize, " peer_wnd=", wnd);
            }

            pcb.writable_event = true;

            // FIN-acked state transitions
            if (pcb.fin_sent && ack == pcb.snd_nxt)
            {
                if (pcb.state == TcpState.fin_wait_1)
                    pcb.state = TcpState.fin_wait_2;
                else if (pcb.state == TcpState.closing)
                {
                    pcb.state = TcpState.time_wait;
                    pcb.time_wait_start = getTime();
                }
                else if (pcb.state == TcpState.last_ack)
                {
                    pcb.state = TcpState.closed;
                    version (DebugTCP)
                        log.trace("c", pcb.id, " closed (graceful)");
                    tcp_unregister(pcb);
                    if (pcb.handle == 0)
                        free_pcb(pcb);
                    return;
                }
            }
        }
    }

    if (pcb.state == TcpState.time_wait)
    {
        // ACK any retransmissions, restart 2MSL.
        send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
        pcb.time_wait_start = getTime();
        return;
    }

    // 6. Process payload data (only in states that accept data)
    if (payload.length > 0 &&
        (pcb.state == TcpState.established ||
         pcb.state == TcpState.fin_wait_1 ||
         pcb.state == TcpState.fin_wait_2))
    {
        if (seq == pcb.rcv_nxt)
        {
            size_t free = TcpRecvBufSize - pcb.recv_buf.length;
            size_t n = payload.length < free ? payload.length : free;
            if (n > 0)
            {
                pcb.recv_buf ~= payload[0 .. n];
                pcb.rcv_nxt += n;
                pcb.rcv_wnd  = cast(uint)(TcpRecvBufSize - pcb.recv_buf.length);
                pcb.readable_event = true;
            }
            send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
        }
        else
        {
            // Out-of-order: not buffered (no SACK). ACK current state.
            send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);
        }
    }

    // 7. FIN processing
    if (flags & TcpFlag.fin)
    {
        // FIN occupies one sequence past the payload.
        uint fin_seq = seq + cast(uint)payload.length;
        if (fin_seq == pcb.rcv_nxt)
        {
            pcb.rcv_nxt += 1;
            pcb.fin_seen = true;
            pcb.readable_event = true;      // app sees EOF
            send_segment_at(stack, pcb, TcpFlag.ack, pcb.snd_nxt, null);

            switch (pcb.state) with (TcpState)
            {
                case established:
                    pcb.state = close_wait;
                    version (DebugTCP)
                        log.trace("c", pcb.id, " peer FIN -> close_wait");
                    break;
                case fin_wait_1:
                    if (pcb.fin_sent && pcb.snd_una == pcb.snd_nxt)
                    {
                        pcb.state = time_wait;
                        pcb.time_wait_start = getTime();
                    }
                    else
                    {
                        pcb.state = closing;
                    }
                    break;
                case fin_wait_2:
                    pcb.state = time_wait;
                    pcb.time_wait_start = getTime();
                    break;
                case time_wait:
                    pcb.time_wait_start = getTime();
                    break;
                default:
                    break;
            }
        }
    }

    // After processing, push out anything pending.
    transmit_pending(stack, pcb);
}


void spawn_child_from_listen(ref IPStack stack, TcpPcb* listener, const IPv4Header* ip, const TcpHeader* t, uint seq, uint wnd)
{
    if (listener.child_list.length >= TcpAcceptQueueMax * 2)
        return;     // refuse, drop SYN

    TcpPcb* child = defaultAllocator().allocT!TcpPcb();
    listener.child_list ~= child;
    tcp_register(child);                    // assigns id before any logging

    child.local_addr  = ip.dst;
    child.local_port  = listener.local_port;
    child.remote_addr = ip.src;
    child.remote_port = be_u16(t.src_port);
    child.parent      = listener;
    child.snd_iss     = generate_iss();
    child.snd_una     = child.snd_iss;
    child.snd_nxt     = child.snd_iss + 1;          // SYN consumes one
    child.rcv_irs     = seq;
    child.rcv_nxt     = seq + 1;
    child.rcv_wnd     = TcpRecvBufSize;
    child.snd_wnd     = wnd;
    child.state       = TcpState.syn_received;
    child.rto_ms      = TcpInitialRtoMs;
    refresh_route(stack, child);  // sets send_mss from egress MTU
    parse_options(t, child);                // peer's MSS may lower send_mss further

    version (DebugTCP)
        log.trace("c", child.id, " accept (SYN) :", child.local_port, "<-", child.remote_addr, ':', child.remote_port);

    send_segment_at(stack, child, TcpFlag.syn | TcpFlag.ack, child.snd_iss, null);
    child.last_send = getTime();
}


void remove_child(TcpPcb* parent, TcpPcb* child)
{
    foreach (i, c; parent.child_list[])
    {
        if (c is child)
        {
            parent.child_list.remove(i);
            break;
        }
    }
    foreach (i, c; parent.accept_queue[])
    {
        if (c is child)
        {
            parent.accept_queue.remove(i);
            break;
        }
    }
}


// Acceptable segment? RFC 793 §3.3 sequence-number check.
bool check_in_window(const TcpPcb* pcb, uint seq, size_t seg_len, ubyte flags) pure
{
    bool fin_set = (flags & TcpFlag.fin) != 0;
    size_t total_len = seg_len + (fin_set ? 1 : 0);
    if (total_len == 0)
    {
        if (pcb.rcv_wnd == 0)
            return seq == pcb.rcv_nxt;
        return seq_le(pcb.rcv_nxt, seq) && seq_lt(seq, pcb.rcv_nxt + pcb.rcv_wnd);
    }
    if (pcb.rcv_wnd == 0)
        return false;
    uint last = seq + cast(uint)total_len - 1;
    bool start_ok = seq_le(pcb.rcv_nxt, seq) && seq_lt(seq, pcb.rcv_nxt + pcb.rcv_wnd);
    bool last_ok  = seq_le(pcb.rcv_nxt, last) && seq_lt(last, pcb.rcv_nxt + pcb.rcv_wnd);
    return start_ok || last_ok;
}


// -------------------------------------------------------------------------
// Output

// Send IP+TCP segment with given seq, ack=pcb.rcv_nxt (if ACK flag), flags, data.
// `seq` is for the first byte of payload (or for SYN/FIN, that flag's sequence).
void send_segment_at(ref IPStack stack, TcpPcb* pcb, ubyte flags, uint seq, const(ubyte)[] data)
{
    ushort window = cast(ushort)(pcb.rcv_wnd > 0xFFFF ? 0xFFFF : pcb.rcv_wnd);
    uint ack_val = pcb.rcv_nxt;
    if (!(flags & TcpFlag.rst) && pcb.state != TcpState.syn_sent && pcb.state != TcpState.listen)
        flags |= TcpFlag.ack;

    // Advertise our chosen MSS in any SYN we send.
    ushort advertise_mss = (flags & TcpFlag.syn) ? pcb.send_mss : 0;

    version (DebugTCPProto)
        log.trace("c", pcb.id, " >> ", flags_str(flags), " seq=", seq, " ack=", ack_val, " len=", data.length, " wnd=", window);

    send_segment_raw(stack, pcb.local_addr, pcb.local_port, pcb.remote_addr, pcb.remote_port,
                     seq, ack_val, flags, window, data, advertise_mss,
                     pcb.route_egress, pcb.route_next_hop);
}


// Build and emit a fully-specified TCP segment. Used both via PCB and for
// stateless RSTs to unknown 4-tuples. SYN segments include an MSS option;
// `advertise_mss` is the value to put in the option (caller's responsibility).
// `egress`/`next_hop` are optional pre-resolved route hints; when non-null we
// take the fast path through output_v4_routed and skip route lookup.
void send_segment_raw(ref IPStack stack, IPAddr src_addr, ushort src_port, IPAddr dst_addr, ushort dst_port,
                      uint seq, uint ack_val, ubyte flags, ushort window, const(ubyte)[] data,
                      ushort advertise_mss = 0, BaseInterface egress = null, IPAddr next_hop = IPAddr.any)
{
    enum size_t max_packet = 1500;      // scratch buffer; segment must already be sized to MSS

    bool include_mss = (flags & TcpFlag.syn) != 0;
    size_t opt_len = include_mss ? 4 : 0;
    size_t total = IPv4Header.sizeof + TcpHeader.sizeof + opt_len + data.length;
    assert(total <= max_packet, "TCP segment exceeds output buffer; MSS must be set correctly");
    if (total > max_packet)
        return;

    ubyte[max_packet] buf = void;

    auto ip = cast(IPv4Header*)buf.ptr;
    ip.ver_ihl  = 0x45;
    ip.tos      = 0;
    ip.total_length[0] = cast(ubyte)(total >> 8);
    ip.total_length[1] = cast(ubyte)total;
    ip.ident[0] = 0;
    ip.ident[1] = 0;
    ip.flags_frag[0] = 0;
    ip.flags_frag[1] = 0;
    ip.ttl      = 64;
    ip.protocol = IpProtocol.tcp;
    ip.checksum[] = 0;
    ip.src      = src_addr;
    ip.dst      = dst_addr;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    ip.checksum[0] = cast(ubyte)(ihc >> 8);
    ip.checksum[1] = cast(ubyte)ihc;

    auto t = cast(TcpHeader*)(buf.ptr + IPv4Header.sizeof);
    set_be_u16(t.src_port, src_port);
    set_be_u16(t.dst_port, dst_port);
    set_be_u32(t.seq, seq);
    set_be_u32(t.ack, ack_val);
    ushort header_len = cast(ushort)(TcpHeader.sizeof + opt_len);
    t.data_offset = cast(ubyte)(header_len / 4);
    t.flags = flags;
    set_be_u16(t.window, window);
    t.checksum[] = 0;
    t.urgent[] = 0;

    if (include_mss)
    {
        ushort mss = advertise_mss != 0 ? advertise_mss : cast(ushort)TcpEthernetMss;
        ubyte* opt = buf.ptr + IPv4Header.sizeof + TcpHeader.sizeof;
        opt[0] = TcpOptionKind.mss;
        opt[1] = 4;
        opt[2] = cast(ubyte)(mss >> 8);
        opt[3] = cast(ubyte)mss;
    }

    if (data.length > 0)
        buf[IPv4Header.sizeof + TcpHeader.sizeof + opt_len .. total] = data[];

    ushort tcp_total = cast(ushort)(TcpHeader.sizeof + opt_len + data.length);
    ushort pseudo = pseudo_header_checksum_v4(src_addr, dst_addr, IpProtocol.tcp, tcp_total);
    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total], pseudo);
    t.checksum[0] = cast(ubyte)(cc >> 8);
    t.checksum[1] = cast(ubyte)cc;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    if (egress)
        stack.output_v4_routed(pkt, egress, next_hop);
    else
        stack.output_v4(pkt);
}


// RFC 793 §3.4: respond to a packet for a non-existent connection.
void send_rst_for_unknown(ref IPStack stack, IPAddr src_addr, ushort src_port, IPAddr dst_addr, ushort dst_port,
                          uint seq, uint ack, ubyte flags, size_t payload_len)
{
    ubyte rst_flags = TcpFlag.rst;
    uint  rst_seq;
    uint  rst_ack;

    if (flags & TcpFlag.ack)
    {
        // The original segment carried an ACK. Use its ACK value as our seq,
        // no ACK in our reply.
        rst_seq = ack;
        rst_ack = 0;
    }
    else
    {
        rst_seq = 0;
        rst_ack = seq + cast(uint)payload_len + ((flags & TcpFlag.syn) ? 1 : 0)
                                              + ((flags & TcpFlag.fin) ? 1 : 0);
        rst_flags |= TcpFlag.ack;
    }

    // Note: src/dst and addresses swap because we're replying.
    send_segment_raw(stack, dst_addr, dst_port, src_addr, src_port, rst_seq, rst_ack, rst_flags, 0, null);
}


// Push as much of send_buf as the window and MSS allow.
void transmit_pending(ref IPStack stack, TcpPcb* pcb)
{
    if (pcb.state != TcpState.established && pcb.state != TcpState.close_wait)
        return;

    // Keep the cached egress + MSS in sync with the route table; if the route
    // disappeared, fall through and let send_segment_at hit the slow path.
    refresh_route(stack, pcb);

    uint in_flight = pcb.snd_nxt - pcb.snd_una;
    uint send_window = pcb.snd_wnd > in_flight ? pcb.snd_wnd - in_flight : 0;

    // Bytes available to send: those after snd_nxt in send_buf.
    uint sent_offset = pcb.snd_nxt - pcb.snd_una;
    if (sent_offset > pcb.send_buf.length)
        sent_offset = cast(uint)pcb.send_buf.length;
    uint queued = cast(uint)pcb.send_buf.length - sent_offset;

    if (send_window == 0)
    {
        version (DebugTCP)
        {
            if (queued > 0)
                log.trace("c", pcb.id, " xmit stall queued=", queued, " in_flight=", in_flight, " peer_wnd=", pcb.snd_wnd);
        }
        return;
    }

    uint segs = 0;
    uint sent_bytes = 0;
    while (queued > 0 && send_window > 0)
    {
        uint chunk = queued;
        if (chunk > pcb.send_mss)
            chunk = pcb.send_mss;
        if (chunk > send_window)
            chunk = send_window;

        const(ubyte)[] slice = pcb.send_buf[sent_offset .. sent_offset + chunk];
        send_segment_at(stack, pcb, TcpFlag.psh, pcb.snd_nxt, slice);

        pcb.snd_nxt += chunk;
        sent_offset += chunk;
        queued      -= chunk;
        send_window -= chunk;
        ++segs;
        sent_bytes  += chunk;
        pcb.last_send = getTime();
    }

    version (DebugTCP)
    {
        if (segs > 0)
            log.trace("c", pcb.id, " xmit ", segs, " segs / ", sent_bytes, "B, queued=", queued, " in_flight=", pcb.snd_nxt - pcb.snd_una, " peer_wnd=", pcb.snd_wnd);
    }

    // All queued data sent, FIN requested -> emit FIN and transition.
    if (pcb.fin_pending && !pcb.fin_sent && queued == 0)
    {
        send_segment_at(stack, pcb, TcpFlag.fin | TcpFlag.ack, pcb.snd_nxt, null);
        pcb.snd_nxt   += 1;
        pcb.fin_sent   = true;
        pcb.state      = (pcb.state == TcpState.close_wait) ? TcpState.last_ack : TcpState.fin_wait_1;
        pcb.last_send  = getTime();
    }
}


// Retransmit the oldest unacked content (one MSS worth, or SYN/SYN-ACK).
void retransmit(ref IPStack stack, TcpPcb* pcb)
{
    refresh_route(stack, pcb);

    version (DebugTCP)
        log.trace("c", pcb.id, " retransmit state=", pcb.state, " retries=", pcb.retries, " rto=", pcb.rto_ms, "ms snd_una=", pcb.snd_una, " snd_nxt=", pcb.snd_nxt);

    final switch (pcb.state) with (TcpState)
    {
        case syn_sent:
            send_segment_at(stack, pcb, TcpFlag.syn, pcb.snd_iss, null);
            return;
        case syn_received:
            send_segment_at(stack, pcb, TcpFlag.syn | TcpFlag.ack, pcb.snd_iss, null);
            return;
        case established:
        case fin_wait_1:
        case fin_wait_2:
        case close_wait:
        case closing:
        case last_ack:
            // Resend up to MSS bytes from snd_una.
            if (pcb.send_buf.length > 0)
            {
                size_t n = pcb.send_buf.length < pcb.send_mss ? pcb.send_buf.length : pcb.send_mss;
                send_segment_at(stack, pcb, TcpFlag.psh, pcb.snd_una, pcb.send_buf[0 .. n]);
                return;
            }
            // Otherwise it's our FIN that's unacked.
            if (pcb.fin_sent && pcb.snd_una < pcb.snd_nxt)
            {
                send_segment_at(stack, pcb, TcpFlag.fin | TcpFlag.ack, pcb.snd_nxt - 1, null);
                return;
            }
            return;
        case closed:
        case listen:
        case time_wait:
            return;     // nothing to retransmit
    }
}


// -------------------------------------------------------------------------
// Helpers

// Refresh the PCB's cached egress + next-hop + MSS if the route table has
// changed. Cheap to call before every send. Callers needing to know whether
// a route exists should check `pcb.route_egress !is null` afterwards.
void refresh_route(ref IPStack stack, TcpPcb* pcb)
{
    uint cur_gen = route_generation();
    if (pcb.route_gen == cur_gen && pcb.route_egress)
        return;

    RouteResult r = stack.route_lookup_v4_dst(pcb.remote_addr);
    if (r.kind != RouteResult.Kind.forward || !r.out_iface)
    {
        pcb.route_egress = null;
        pcb.route_gen = cur_gen;
        return;
    }

    pcb.route_egress   = r.out_iface;
    pcb.route_next_hop = r.next_hop;
    pcb.route_gen      = cur_gen;

    // Derive local-side MSS from egress MTU. The smaller of this, peer's
    // advertised MSS, and the prior value wins (peer MSS is applied via
    // parse_options separately).
    ushort link_mss = TcpEthernetMss;
    uint mtu = pcb.route_egress.actual_mtu;
    if (mtu > 40)
    {
        uint cap = mtu - 40;            // 20 IP + 20 TCP
        if (cap < link_mss)
            link_mss = cast(ushort)cap;
    }
    if (pcb.send_mss == 0 || link_mss < pcb.send_mss)
        pcb.send_mss = link_mss;
}


void parse_options(const TcpHeader* t, TcpPcb* pcb)
{
    size_t hdr_len = t.data_offset * 4;
    if (hdr_len <= TcpHeader.sizeof)
        return;
    const(ubyte)[] opts = (cast(const(ubyte)*)t)[TcpHeader.sizeof .. hdr_len];

    size_t i = 0;
    while (i < opts.length)
    {
        ubyte kind = opts[i];
        if (kind == TcpOptionKind.end_of_options)
            break;
        if (kind == TcpOptionKind.nop)
        {
            ++i;
            continue;
        }
        if (i + 1 >= opts.length)
            break;
        ubyte olen = opts[i + 1];
        if (olen < 2 || i + olen > opts.length)
            break;

        if (kind == TcpOptionKind.mss && olen == 4)
        {
            ushort mss = (ushort(opts[i + 2]) << 8) | opts[i + 3];
            version (DebugTCPProto)
                log.trace("c", pcb.id, " opt peer mss=", mss);
            if (mss > 0 && mss < pcb.send_mss)
                pcb.send_mss = mss;
        }
        // Other options ignored (we don't negotiate window scale, SACK, timestamp).
        i += olen;
    }
}


// Compact one-line flag string for logging. e.g. "SA" for SYN|ACK.
const(char)[] flags_str(ubyte f) @nogc nothrow
{
    static char[8] buf;
    size_t n = 0;
    if (f & TcpFlag.fin) buf[n++] = 'F';
    if (f & TcpFlag.syn) buf[n++] = 'S';
    if (f & TcpFlag.rst) buf[n++] = 'R';
    if (f & TcpFlag.psh) buf[n++] = 'P';
    if (f & TcpFlag.ack) buf[n++] = 'A';
    if (f & TcpFlag.urg) buf[n++] = 'U';
    if (f & TcpFlag.ece) buf[n++] = 'E';
    if (f & TcpFlag.cwr) buf[n++] = 'C';
    if (n == 0) buf[n++] = '-';
    return buf[0 .. n];
}


TcpPcb* find_pcb_4tuple(IPAddr l_addr, ushort l_port, IPAddr r_addr, ushort r_port)
{
    foreach (p; _pcbs[])
    {
        if (p.is_listener) continue;
        if (p.local_port  != l_port) continue;
        if (p.remote_port != r_port) continue;
        if (p.remote_addr != r_addr) continue;
        if (p.local_addr != IPAddr.any && p.local_addr != l_addr) continue;
        return p;
    }
    return null;
}

TcpPcb* find_listener(IPAddr addr, ushort port)
{
    foreach (p; _pcbs[])
    {
        if (!p.is_listener) continue;
        if (p.local_port != port) continue;
        if (p.local_addr != IPAddr.any && p.local_addr != addr) continue;
        return p;
    }
    return null;
}


void free_pcb(TcpPcb* pcb)
{
    if (pcb.parent !is null)
        remove_child(pcb.parent, pcb);
    pcb.send_buf.clear();
    pcb.recv_buf.clear();
    pcb.accept_queue.clear();
    pcb.child_list.clear();
    defaultAllocator().freeT(pcb);
}


// Sequence number arithmetic (modular 32-bit).
bool seq_lt(uint a, uint b) pure => cast(int)(a - b) < 0;
bool seq_le(uint a, uint b) pure => cast(int)(a - b) <= 0;
bool seq_gt(uint a, uint b) pure => cast(int)(a - b) > 0;
bool seq_ge(uint a, uint b) pure => cast(int)(a - b) >= 0;


// Produce an initial sequence number. Not cryptographic; sufficient as a
// monotonic-with-jitter start point.
uint generate_iss()
{
    MonoTime now = getTime();
    return cast(uint)(now.ticks >> 8) ^ 0xA3B75D17;
}


ushort be_u16(const ref ubyte[2] x) pure
    => cast(ushort)((x[0] << 8) | x[1]);

uint be_u32(const ref ubyte[4] x) pure
    => (uint(x[0]) << 24) | (uint(x[1]) << 16) | (uint(x[2]) << 8) | x[3];

void set_be_u16(ref ubyte[2] x, ushort v) pure
{
    x[0] = cast(ubyte)(v >> 8);
    x[1] = cast(ubyte)v;
}

void set_be_u32(ref ubyte[4] x, uint v) pure
{
    x[0] = cast(ubyte)(v >> 24);
    x[1] = cast(ubyte)(v >> 16);
    x[2] = cast(ubyte)(v >> 8);
    x[3] = cast(ubyte)v;
}


// IPv4 pseudo-header checksum: sum of src_addr, dst_addr, zero+protocol, transport_length.
ushort pseudo_header_checksum_v4(IPAddr src, IPAddr dst, ubyte protocol, ushort transport_length) pure
{
    ubyte[12] ph = void;
    ph[0..4]  = src.b[];
    ph[4..8]  = dst.b[];
    ph[8]     = 0;
    ph[9]     = protocol;
    ph[10]    = cast(ubyte)(transport_length >> 8);
    ph[11]    = cast(ubyte)transport_length;
    return internet_checksum(ph[]);
}
