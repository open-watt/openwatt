/**
 * @file
 * TCP API (to be used from TCPIP thread)<br>
 * See also @ref tcp_raw
 */

/*
 * Copyright (c) 2001-2004 Swedish Institute of Computer Science.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
 * SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * This file is part of the lwIP TCP/IP stack.
 *
 * Author: Adam Dunkels <adam@sics.se>
 *
 */
module protocol.ip.tcp;

version (UseInternalIPStack):

public import protocol.ip.tcp.opt;

nothrow @nogc:

/* lwIP's err.h. Negative-or-zero error codes. Kept above the LWIP_TCP gate so
   modules can use err_t without enabling the TCP feature. */
alias err_t = byte;

enum : err_t {
    ERR_OK         =  0,    /* No error, everything OK. */
    ERR_MEM        = -1,    /* Out of memory error. */
    ERR_BUF        = -2,    /* Buffer error. */
    ERR_TIMEOUT    = -3,    /* Timeout. */
    ERR_RTE        = -4,    /* Routing problem. */
    ERR_INPROGRESS = -5,    /* Operation in progress. */
    ERR_VAL        = -6,    /* Illegal value. */
    ERR_WOULDBLOCK = -7,    /* Operation would block. */
    ERR_USE        = -8,    /* Address in use. */
    ERR_ALREADY    = -9,    /* Already connecting. */
    ERR_ISCONN     = -10,   /* Conn already established. */
    ERR_CONN       = -11,   /* Not connected. */
    ERR_IF         = -12,   /* Low-level netif error. */

    ERR_ABRT       = -13,   /* Connection aborted. */
    ERR_RST        = -14,   /* Connection reset. */
    ERR_CLSD       = -15,   /* Connection closed. */
    ERR_ARG        = -16,   /* Illegal argument. */
}


version (LWIP_TCP) { /* don't build if not configured for use in lwipopts.h */

public import protocol.ip.tcp.tcpbase;
public import protocol.ip.tcp.pbuf;
public import protocol.ip.tcp.ip;
import protocol.ip.tcp.prot_tcp;

/* Composite version derivations. D's `version =` is FILE-LOCAL — every
   composite has to be re-derived in every file that tests it. See tcp.d.
   LWIP_CALLBACK_API is hard-wired on — the raw callback API is the only
   event-delivery model we use; the LWIP_EVENT_API alternative is gone. */
version = TCP_PCB_HAS_LISTENER;
version (TCP_OVERSIZE) version (LWIP_DEBUG)               version = TCP_OVERSIZE_DBGCHECK;
version (LWIP_CHECKSUM_ON_COPY) version (CHECKSUM_GEN_TCP) version = TCP_CHECKSUM_ON_COPY;
version (TCP_OVERSIZE) version (LWIP_DEBUG)               version = TCP_OVERSIZE_DBGCHECK;
version (LWIP_CHECKSUM_ON_COPY) version (CHECKSUM_GEN_TCP) version = TCP_CHECKSUM_ON_COPY;

nothrow @nogc:


/* -- Checksum helpers ------------------------------------------------------- */
/* pseudo-header lives in protocol.ip (UDP shares it); these walk pbuf chains
   so they're TCP-only. pbuf chains can have odd-length intermediate segments;
   the chained internet_checksum property only holds for even-length chunks,
   so for odd boundaries we byteswap the running accumulator (lwIP's standard
   trick) and unswap once at the end. */

ushort ip_chksum_copy(void* dst, const(void)* src, size_t len)
{
    import urt.hash : internet_checksum;
    import urt.mem : memcpy;
    memcpy(dst, src, len);
    return internet_checksum((cast(const(ubyte)*)src)[0 .. len]);
}

/* TCP checksum over a pbuf chain plus IPv4 pseudo-header. Returns the final
   inverted 16-bit checksum ready to drop into the wire header. */
ushort ip_chksum_pseudo(pbuf* p, ubyte proto, ushort proto_len,
                        const(ip_addr_t)* src, const(ip_addr_t)* dst)
{
    import protocol.ip : pseudo_header_checksum;
    if (src is null || dst is null)
        return 0;
    /* TODO: v6 pseudo-header. */
    if (src.type != IPADDR_TYPE_V4 || dst.type != IPADDR_TYPE_V4)
        return 0;

    ushort acc = pseudo_header_checksum(src.u_addr.ip4, dst.u_addr.ip4, proto, proto_len);
    return chksum_pbuf_chain(p, proto_len, acc);
}

/* Like ip_chksum_pseudo but only sums the first `chksum_len` bytes of the
   chain (data tail was pre-summed elsewhere). Returns uint per lwIP contract;
   the caller folds the result with its own partial sum. */
uint ip_chksum_pseudo_partial(pbuf* p, ubyte proto, ushort proto_len, ushort chksum_len,
                              const(ip_addr_t)* src, const(ip_addr_t)* dst)
{
    import protocol.ip : pseudo_header_checksum;
    if (src is null || dst is null)
        return 0;
    if (src.type != IPADDR_TYPE_V4 || dst.type != IPADDR_TYPE_V4)
        return 0;

    ushort acc = pseudo_header_checksum(src.u_addr.ip4, dst.u_addr.ip4, proto, proto_len);
    return chksum_pbuf_chain(p, chksum_len, acc);
}

private ushort chksum_pbuf_chain(const(pbuf)* p, ushort len, ushort acc)
{
    import urt.hash : internet_checksum;
    import urt.util : byte_reverse;
    bool swapped = false;
    for (const(pbuf)* q = p; q !is null && len > 0; q = q.next)
    {
        ushort take = q.len < len ? q.len : len;
        acc = internet_checksum((cast(const(ubyte)*)q.payload)[0 .. take], acc);
        if (take & 1)
        {
            swapped = !swapped;
            acc = byte_reverse(acc);
        }
        len = cast(ushort)(len - take);
    }
    if (swapped)
        acc = byte_reverse(acc);
    return acc;
}

/* Per-segment flag bits — defined here because struct tcp_seg below uses them
   when version (TCP_CHECKSUM_ON_COPY) is set. lwIP puts them in tcp_priv.h. */
enum ubyte TF_SEG_OPTS_MSS         = 0x01U;
enum ubyte TF_SEG_OPTS_TS          = 0x02U;
enum ubyte TF_SEG_DATA_CHECKSUMMED = 0x04U;
enum ubyte TF_SEG_OPTS_WND_SCALE   = 0x08U;
enum ubyte TF_SEG_OPTS_SACK_PERM   = 0x10U;

/* struct tcp_seg lives here (not in tcp_priv.d) because tcp_pcb holds
   tcp_seg* fields and D can't have two distinct definitions of the same
   struct across modules. lwIP puts this in tcp_priv.h. */
struct tcp_seg {
  tcp_seg* next;
  pbuf* p;
  ushort len;
  version (TCP_OVERSIZE_DBGCHECK) ushort oversize_left;
  version (TCP_CHECKSUM_ON_COPY) {
    ushort chksum;
    ubyte  chksum_swapped;
  }
  ubyte  flags;
  tcp_hdr* tcphdr;
}

/** Function prototype for tcp accept callback functions. Called when a new
 * connection can be accepted on a listening pcb.
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param newpcb The new connection pcb
 * @param err An error code if there has been an error accepting.
 *            Only return ERR_ABRT if you have called tcp_abort from within the
 *            callback function!
 */
alias tcp_accept_fn = err_t function(void* arg, tcp_pcb* newpcb, err_t err);

/** Function prototype for tcp receive callback functions. Called when data has
 * been received.
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param tpcb The connection pcb which received data
 * @param p The received data (or NULL when the connection has been closed!)
 * @param err An error code if there has been an error receiving
 *            Only return ERR_ABRT if you have called tcp_abort from within the
 *            callback function!
 */
alias tcp_recv_fn = err_t function(void* arg, tcp_pcb* tpcb,
                                   pbuf* p, err_t err);

/** Function prototype for tcp sent callback functions. Called when sent data has
 * been acknowledged by the remote side. Use it to free corresponding resources.
 * This also means that the pcb has now space available to send new data.
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param tpcb The connection pcb for which data has been acknowledged
 * @param len The amount of bytes acknowledged
 * @return ERR_OK: try to send some data by calling tcp_output
 *            Only return ERR_ABRT if you have called tcp_abort from within the
 *            callback function!
 */
alias tcp_sent_fn = err_t function(void* arg, tcp_pcb* tpcb,
                                   ushort len);

/** Function prototype for tcp poll callback functions. Called periodically as
 * specified by @see tcp_poll.
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param tpcb tcp pcb
 * @return ERR_OK: try to send some data by calling tcp_output
 *            Only return ERR_ABRT if you have called tcp_abort from within the
 *            callback function!
 */
alias tcp_poll_fn = err_t function(void* arg, tcp_pcb* tpcb);

/** Function prototype for tcp error callback functions. Called when the pcb
 * receives a RST or is unexpectedly closed for any other reason.
 *
 * @note The corresponding pcb is already freed when this callback is called!
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param err Error code to indicate why the pcb has been closed
 *            ERR_ABRT: aborted through tcp_abort or by a TCP timer
 *            ERR_RST: the connection was reset by the remote host
 */
alias tcp_err_fn  = void function(void* arg, err_t err);

/** Function prototype for tcp connected callback functions. Called when a pcb
 * is connected to the remote side after initiating a connection attempt by
 * calling tcp_connect().
 *
 * @param arg Additional argument to pass to the callback function (@see tcp_arg())
 * @param tpcb The connection pcb which is connected
 * @param err An unused error code, always ERR_OK currently ;-) @todo!
 *            Only return ERR_ABRT if you have called tcp_abort from within the
 *            callback function!
 *
 * @note When a connection attempt fails, the error callback is currently called!
 */
alias tcp_connected_fn = err_t function(void* arg, tcp_pcb* tpcb, err_t err);

version (LWIP_WND_SCALE) {
tcpwnd_size_t RCV_WND_SCALE(const(tcp_pcb)* pcb, tcpwnd_size_t wnd) pure => cast(tcpwnd_size_t)(wnd >> pcb.rcv_scale);
tcpwnd_size_t SND_WND_SCALE(const(tcp_pcb)* pcb, tcpwnd_size_t wnd) pure => cast(tcpwnd_size_t)(wnd << pcb.snd_scale);
ushort TCPWND16(tcpwnd_size_t x) pure => cast(ushort)(x < 0xFFFF ? x : 0xFFFF);
tcpwnd_size_t TCP_WND_MAX(const(tcp_pcb)* pcb) pure => (pcb.flags & TF_WND_SCALE) ? cast(tcpwnd_size_t)TCP_WND : cast(tcpwnd_size_t)TCPWND16(TCP_WND);
} else {
tcpwnd_size_t RCV_WND_SCALE(const(tcp_pcb)* pcb, tcpwnd_size_t wnd) pure => wnd;
tcpwnd_size_t SND_WND_SCALE(const(tcp_pcb)* pcb, tcpwnd_size_t wnd) pure => wnd;
tcpwnd_size_t TCPWND16(tcpwnd_size_t x) pure => x;
tcpwnd_size_t TCP_WND_MAX(const(tcp_pcb)* pcb) pure => TCP_WND;
}
/* Increments a tcpwnd_size_t and holds at max value rather than rollover */
void TCP_WND_INC(ref tcpwnd_size_t wnd, tcpwnd_size_t inc) pure {
    if (cast(tcpwnd_size_t)(wnd + inc) >= wnd) {
        wnd = cast(tcpwnd_size_t)(wnd + inc);
    } else {
        wnd = cast(tcpwnd_size_t)-1;
    }
}

version (LWIP_TCP_SACK_OUT) {
/** SACK ranges to include in ACK packets.
 * SACK entry is invalid if left==right. */
struct tcp_sack_range {
  /** Left edge of the SACK: the first acknowledged sequence number. */
  uint left;
  /** Right edge of the SACK: the last acknowledged sequence number +1 (so first NOT acknowledged). */
  uint right;
}
} /* LWIP_TCP_SACK_OUT */

/** Function prototype for deallocation of arguments. Called *just before* the
 * pcb is freed, so don't expect to be able to do anything with this pcb!
 *
 * @param id ext arg id (allocated via @ref tcp_ext_arg_alloc_id)
 * @param data pointer to the data (set via @ref tcp_ext_arg_set before)
 */
alias tcp_extarg_callback_pcb_destroyed_fn = void function(ubyte id, void* data);

/** Function prototype to transition arguments from a listening pcb to an accepted pcb
 *
 * @param id ext arg id (allocated via @ref tcp_ext_arg_alloc_id)
 * @param lpcb the listening pcb accepting a connection
 * @param cpcb the newly allocated connection pcb
 * @return ERR_OK if OK, any error if connection should be dropped
 */
alias tcp_extarg_callback_passive_open_fn = err_t function(ubyte id, tcp_pcb_listen* lpcb, tcp_pcb* cpcb);

/** A table of callback functions that is invoked for ext arguments */
struct tcp_ext_arg_callbacks {
  /** @ref tcp_extarg_callback_pcb_destroyed_fn */
  tcp_extarg_callback_pcb_destroyed_fn destroy;
  /** @ref tcp_extarg_callback_passive_open_fn */
  tcp_extarg_callback_passive_open_fn passive_open;
}

enum LWIP_TCP_PCB_NUM_EXT_ARG_ID_INVALID = 0xFF;

version (LWIP_TCP_PCB_NUM_EXT_ARGS) {
/* This is the structure for ext args in tcp pcbs (used as array) */
struct tcp_pcb_ext_args {
  const(tcp_ext_arg_callbacks)* callbacks;
  void* data;
}
/* This is a helper define to prevent zero size arrays if disabled */
mixin template TCP_PCB_EXTARGS() {
    tcp_pcb_ext_args[LWIP_TCP_PCB_NUM_EXT_ARGS] ext_args;
}
} else {
mixin template TCP_PCB_EXTARGS() {}
}

alias tcpflags_t = ushort;
enum TCP_ALLFLAGS = 0xffffU;

/**
 * Common prefix of every IP-based PCB. lwIP keeps this as a #define so that
 * `IP_PCB;` plopped inside a struct body inlines the fields. D's mixin
 * template does the same.
 */
mixin template IP_PCB() {
    ip_addr_t local_ip;
    ip_addr_t remote_ip;
    /* Bound netif index, NETIF_NO_INDEX for unbound. */
    ubyte netif_idx;
    /* Socket options bitfield (SOF_*). */
    ubyte so_options;
    /* Type of service. */
    ubyte tos;
    /* Time to live. */
    ubyte ttl;
    /* netif_hints — always included; lwIP gates this on LWIP_NETIF_USE_HINTS
       but the cost is two bytes per PCB and avoids version-conditional field
       access at the call sites. */
    netif_hint netif_hints;
}

/**
 * members common to struct tcp_pcb and struct tcp_listen_pcb
 */
mixin template TCP_PCB_COMMON(T) {
    T* next; /* for the linked list */
    void* callback_arg;
    mixin TCP_PCB_EXTARGS;
    tcp_state state; /* TCP state */
    ubyte prio;
    /* ports are in host byte order */
    ushort local_port;
}


/** the TCP protocol control block for listening pcbs */
struct tcp_pcb_listen {
/** Common members of all PCB types */
  mixin IP_PCB;
/** Protocol specific PCB members */
  mixin TCP_PCB_COMMON!tcp_pcb_listen;

  /* Function to call when a listener has been connected. */
  tcp_accept_fn accept;

version (TCP_LISTEN_BACKLOG) {
  ubyte backlog;
  ubyte accepts_pending;
} /* TCP_LISTEN_BACKLOG */
}


/* lwIP has TCP_SNDQUEUELEN_OVERFLOW inline mid-struct. Lifted here. */
enum TCP_SNDQUEUELEN_OVERFLOW = cast(ushort)(0xffffU - 3);

/* Flag bits for struct tcp_pcb.flags. Defined at module scope (lwIP has them inside the struct). */
enum tcpflags_t TF_ACK_DELAY   = 0x01U;   /* Delayed ACK. */
enum tcpflags_t TF_ACK_NOW     = 0x02U;   /* Immediate ACK. */
enum tcpflags_t TF_INFR        = 0x04U;   /* In fast recovery. */
enum tcpflags_t TF_CLOSEPEND   = 0x08U;   /* If this is set, tcp_close failed to enqueue the FIN (retried in tcp_tmr) */
enum tcpflags_t TF_RXCLOSED    = 0x10U;   /* rx closed by tcp_shutdown */
enum tcpflags_t TF_FIN         = 0x20U;   /* Connection was closed locally (FIN segment enqueued). */
enum tcpflags_t TF_NODELAY     = 0x40U;   /* Disable Nagle algorithm */
enum tcpflags_t TF_NAGLEMEMERR = 0x80U;   /* nagle enabled, memerr, try to output to prevent delayed ACK to happen */
version (LWIP_WND_SCALE) {
enum tcpflags_t TF_WND_SCALE   = 0x0100U; /* Window Scale option enabled */
}
version (TCP_LISTEN_BACKLOG) {
enum tcpflags_t TF_BACKLOGPEND = 0x0200U; /* If this is set, a connection pcb has increased the backlog on its listener */
}
version (LWIP_TCP_TIMESTAMPS) {
enum tcpflags_t TF_TIMESTAMP   = 0x0400U;   /* Timestamp option enabled */
}
enum tcpflags_t TF_RTO         = 0x0800U; /* RTO timer has fired, in-flight data moved to unsent and being retransmitted */
version (LWIP_TCP_SACK_OUT) {
enum tcpflags_t TF_SACK        = 0x1000U; /* Selective ACKs enabled */
}

/** the TCP protocol control block */
struct tcp_pcb {
/** common PCB members */
  mixin IP_PCB;
/** protocol specific PCB members */
  mixin TCP_PCB_COMMON!tcp_pcb;

  /* ports are in host byte order */
  ushort remote_port;

  tcpflags_t flags;

  /* the rest of the fields are in host byte order
     as we have to do some math with them */

  /* Timers */
  ubyte polltmr, pollinterval;
  ubyte last_timer;
  uint tmr;

  /* receiver variables */
  uint rcv_nxt;   /* next seqno expected */
  tcpwnd_size_t rcv_wnd;   /* receiver window available */
  tcpwnd_size_t rcv_ann_wnd; /* receiver window to announce */
  uint rcv_ann_right_edge; /* announced right edge of window */

version (LWIP_TCP_SACK_OUT) {
  /* SACK ranges to include in ACK packets (entry is invalid if left==right) */
  tcp_sack_range[LWIP_TCP_MAX_SACK_NUM] rcv_sacks;
} /* LWIP_TCP_SACK_OUT */

  /* Retransmission timer. */
  short rtime;

  ushort mss;   /* maximum segment size */

  /* RTT (round trip time) estimation variables */
  uint rttest; /* RTT estimate in 500ms ticks */
  uint rtseq;  /* sequence number being timed */
  short sa, sv; /* @see "Congestion Avoidance and Control" by Van Jacobson and Karels */

  short rto;    /* retransmission time-out (in ticks of TCP_SLOW_INTERVAL) */
  ubyte nrtx;   /* number of retransmissions */

  /* fast retransmit/recovery */
  ubyte dupacks;
  uint lastack; /* Highest acknowledged seqno. */

  /* congestion avoidance/control variables */
  tcpwnd_size_t cwnd;
  tcpwnd_size_t ssthresh;

  /* first byte following last rto byte */
  uint rto_end;

  /* sender variables */
  uint snd_nxt;   /* next new seqno to be sent */
  uint snd_wl1, snd_wl2; /* Sequence and acknowledgement numbers of last
                            window update. */
  uint snd_lbb;       /* Sequence number of next byte to be buffered. */
  tcpwnd_size_t snd_wnd;   /* sender window */
  tcpwnd_size_t snd_wnd_max; /* the maximum sender window announced by the remote host */

  tcpwnd_size_t snd_buf;   /* Available buffer space for sending (in bytes). */
  ushort snd_queuelen; /* Number of pbufs currently in the send buffer. */
  /* TCP_SNDQUEUELEN_OVERFLOW lifted to module scope below; lwIP has it
     inline mid-struct as a #define. */

version (TCP_OVERSIZE) {
  /* Extra bytes available at the end of the last pbuf in unsent. */
  ushort unsent_oversize;
} /* TCP_OVERSIZE */

  tcpwnd_size_t bytes_acked;

  /* These are ordered by sequence number: */
  tcp_seg* unsent;   /* Unsent (queued) segments. */
  tcp_seg* unacked;  /* Sent but unacknowledged segments. */
version (TCP_QUEUE_OOSEQ) {
  tcp_seg* ooseq;    /* Received out of sequence segments. */
} /* TCP_QUEUE_OOSEQ */

  pbuf* refused_data; /* Data previously received but not yet taken by upper layer */

version (TCP_PCB_HAS_LISTENER) {
  tcp_pcb_listen* listener;
} /* LWIP_CALLBACK_API || TCP_LISTEN_BACKLOG */

  /* Function to be called when more send buffer space is available. */
  tcp_sent_fn sent;
  /* Function to be called when (in-sequence) data has arrived. */
  tcp_recv_fn recv;
  /* Function to be called when a connection has been set up. */
  tcp_connected_fn connected;
  /* Function which is called periodically. */
  tcp_poll_fn poll;
  /* Function to be called whenever a fatal error occurs. */
  tcp_err_fn errf;

version (LWIP_TCP_TIMESTAMPS) {
  uint ts_lastacksent;
  uint ts_recent;
} /* LWIP_TCP_TIMESTAMPS */

  /* idle time before KEEPALIVE is sent */
  uint keep_idle;
version (LWIP_TCP_KEEPALIVE) {
  uint keep_intvl;
  uint keep_cnt;
} /* LWIP_TCP_KEEPALIVE */

  /* Persist timer counter */
  ubyte persist_cnt;
  /* Persist timer back-off */
  ubyte persist_backoff;
  /* Number of persist probes */
  ubyte persist_probe;

  /* KEEPALIVE counter */
  ubyte keep_cnt_sent;

version (LWIP_WND_SCALE) {
  ubyte snd_scale;
  ubyte rcv_scale;
}
}

/* Bodies live in tcp.d / tcp_in.d / tcp_out.d. D mangles names by module
   path, so forward-declaring them here would mint dangling symbols at the
   package module path. Public-import the implementation modules instead. */
public import protocol.ip.tcp.tcp;
public import protocol.ip.tcp.tcp_in;
public import protocol.ip.tcp.tcp_out;

/* Application program's interface (inline helpers; the bodied APIs above are
   re-exported by the public imports). */

void tcp_set_flags(tcp_pcb* pcb, tcpflags_t set_flags) pure { pcb.flags = cast(tcpflags_t)(pcb.flags | set_flags); }
void tcp_clear_flags(tcp_pcb* pcb, tcpflags_t clr_flags) pure { pcb.flags = cast(tcpflags_t)(pcb.flags & cast(tcpflags_t)(~clr_flags & TCP_ALLFLAGS)); }
bool tcp_is_flag_set(const(tcp_pcb)* pcb, tcpflags_t flag) pure => (pcb.flags & flag) != 0;

version (LWIP_TCP_TIMESTAMPS) {
ushort           tcp_mss(const(tcp_pcb)* pcb) pure => (pcb.flags & TF_TIMESTAMP) ? cast(ushort)(pcb.mss - 12) : pcb.mss;
} else { /* LWIP_TCP_TIMESTAMPS */
/** @ingroup tcp_raw */
ushort           tcp_mss(const(tcp_pcb)* pcb) pure => pcb.mss;
} /* LWIP_TCP_TIMESTAMPS */
/** @ingroup tcp_raw */
ushort           tcp_sndbuf(const(tcp_pcb)* pcb) pure => TCPWND16(pcb.snd_buf);
/** @ingroup tcp_raw */
ushort           tcp_sndqueuelen(const(tcp_pcb)* pcb) pure => pcb.snd_queuelen;
/** @ingroup tcp_raw */
void             tcp_nagle_disable(tcp_pcb* pcb) pure { tcp_set_flags(pcb, TF_NODELAY); }
/** @ingroup tcp_raw */
void             tcp_nagle_enable(tcp_pcb* pcb) pure { tcp_clear_flags(pcb, TF_NODELAY); }
/** @ingroup tcp_raw */
bool             tcp_nagle_disabled(const(tcp_pcb)* pcb) pure => tcp_is_flag_set(pcb, TF_NODELAY);

version (TCP_LISTEN_BACKLOG) {
void tcp_backlog_set(tcp_pcb* pcb, ubyte new_backlog) {
    assert(pcb.state == LISTEN, "pcb->state == LISTEN (called for wrong pcb?)");
    (cast(tcp_pcb_listen*)pcb).backlog = (new_backlog ? new_backlog : 1);
}
void             tcp_backlog_delayed(tcp_pcb* pcb);
void             tcp_backlog_accepted(tcp_pcb* pcb);
} else { /* TCP_LISTEN_BACKLOG */
void             tcp_backlog_set(tcp_pcb* pcb, ubyte new_backlog) pure {}
void             tcp_backlog_delayed(tcp_pcb* pcb) pure {}
void             tcp_backlog_accepted(tcp_pcb* pcb) pure {}
} /* TCP_LISTEN_BACKLOG */
void             tcp_accepted(tcp_pcb* pcb) pure {} /* compatibility define, not needed any more */

/** @ingroup tcp_raw */
tcp_pcb*         tcp_listen(tcp_pcb* pcb) { return tcp_listen_with_backlog(pcb, TCP_DEFAULT_LISTEN_BACKLOG); }

tcp_state tcp_dbg_get_tcp_state(const(tcp_pcb)* pcb) pure => pcb.state;

/* for compatibility with older implementation */
tcp_pcb* tcp_new_ip6() { return tcp_new_ip_type(IPADDR_TYPE_V6); }


/* -- Project-side adapters (not part of upstream lwIP) ---------------------- */
/* These bridge our IPStack / Console / ICMP into the lwIP-port API. They live
   here so consumers can `import protocol.ip.tcp;` and get the full surface. */

/* IP-stack ingress entry. The caller (IPStack.ingress_v4) has already filled
   ip_data.current_src / current_dst / current_input_netif. We just strip the
   IP header, copy the TCP segment into a fresh pbuf, hand off. */
void tcp_ingress_v4(ref IPStack stack, ref Packet pkt)
{
    import urt.mem : memcpy;
    if (pkt.data.length < IPv4Header.sizeof)
        return;
    const(IPv4Header)* ip = cast(const(IPv4Header)*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    ushort total = cast(ushort)((ushort(ip.total_length[0]) << 8) | ip.total_length[1]);
    if (total < ip_hdr_len || total > pkt.data.length)
        return;
    ushort seg_len = cast(ushort)(total - ip_hdr_len);

    pbuf* p = pbuf_alloc(PBUF_RAW, seg_len, PBUF_RAM);
    if (p is null)
        return;
    memcpy(p.payload, cast(const(void)*)(pkt.data.ptr + ip_hdr_len), seg_len);
    tcp_input(p, ip_data.current_input_netif);
}

/* ICMP unreachable matched a TCP socket. Find the PCB by 4-tuple and abort
   it so the next read/write returns immediately rather than waiting for the
   RTO to expire. `code` / `code_data` are the ICMP code byte and the 32-bit
   rest-of-header field (carries next-hop MTU for frag-needed); we ignore
   both for now and just reset. */
void tcp_handle_unreachable(ref IPStack stack, ubyte code, uint code_data,
                            IPAddr local_ip, ushort local_port,
                            IPAddr remote_ip, ushort remote_port)
{
    for (tcp_pcb* pcb = tcp_active_pcbs; pcb !is null; pcb = pcb.next)
    {
        if (pcb.local_port  == local_port  &&
            pcb.remote_port == remote_port &&
            pcb.local_ip.u_addr.ip4  == local_ip &&
            pcb.remote_ip.u_addr.ip4 == remote_ip)
        {
            tcp_abort(pcb);
            return;
        }
    }
}

/* /protocol/ip/tcp print — walk the listen / active / time-wait PCB lists. */
void tcp_print(Session session)
{
    import manager.console.table : Table;
    import urt.mem.temp : tconcat;
    import urt.inet : InetAddress;

    Table t;
    t.add_column("state");
    t.add_column("local");
    t.add_column("remote");
    t.add_column("snd-buf", Table.TextAlign.right);
    t.add_column("rcv-wnd", Table.TextAlign.right);

    bool any = false;

    void add(const(tcp_pcb)* pcb)
    {
        any = true;
        t.add_row();
        t.cell(tcp_state_str[pcb.state]);
        t.cell(tconcat(InetAddress(pcb.local_ip.u_addr.ip4, pcb.local_port)));
        t.cell(tconcat(InetAddress(pcb.remote_ip.u_addr.ip4, pcb.remote_port)));
        t.cell(tconcat(pcb.snd_buf));
        t.cell(tconcat(pcb.rcv_wnd));
    }

    for (const(tcp_pcb)* pcb = cast(const(tcp_pcb)*)tcp_listen_pcbs.pcbs; pcb !is null; pcb = pcb.next)
        add(pcb);
    for (const(tcp_pcb)* pcb = tcp_active_pcbs; pcb !is null; pcb = pcb.next)
        add(pcb);
    for (const(tcp_pcb)* pcb = tcp_tw_pcbs; pcb !is null; pcb = pcb.next)
        add(pcb);

    if (!any)
    {
        session.write_line("No TCP PCBs");
        return;
    }

    t.render(session);
}

} /* LWIP_TCP */

/* Cross-package symbols pulled in for the adapters above. Outside the
   LWIP_TCP gate so the imports always resolve even when TCP is off. */
import urt.inet : IPAddr;
import protocol.ip.stack : IPStack, IPv4Header;
import router.iface.packet : Packet;
import manager.console.session : Session;
