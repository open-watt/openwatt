/**
 * @file
 * TCP internal implementations (do not use in application code)
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
module protocol.ip.tcp.tcp_priv;

version (UseInternalIPStack):

/* File-local versions — flip the commented ones to enable per-subsystem
   debug traces. CHECKSUM_GEN_TCP stays in the build flags. */
//version = TCP_OUTPUT_DEBUG;
//version = TCP_DEBUG_PCB_LISTS;

import protocol.ip.tcp.opt;

version (LWIP_TCP) { /* don't build if not configured for use in lwipopts.h */

import protocol.ip.tcp;
import protocol.ip.tcp.tcpbase;
import protocol.ip.tcp.pbuf;
import protocol.ip.tcp.prot_tcp;
import protocol.ip.tcp.ip;

/* Bodies live in tcp.d / tcp_in.d / tcp_out.d. Public-import them so the
   helper bodies below (TCP_REG, TCP_EVENT_*, tcp_output_nagle, etc.) can
   resolve the names without redeclaring them at this module path. */
public import protocol.ip.tcp.tcp;
public import protocol.ip.tcp.tcp_in;
public import protocol.ip.tcp.tcp_out;

/* Composite version identifiers (mirror lwIP's compound #if conditions and derived flags). */
version (TCP_OVERSIZE) version (LWIP_DEBUG) version = TCP_OVERSIZE_DBGCHECK;
version (LWIP_CHECKSUM_ON_COPY) version (CHECKSUM_GEN_TCP) version = TCP_CHECKSUM_ON_COPY;
version (TCP_DEBUG) version = TCP_HAS_DEBUG_PRINT;
version (TCP_INPUT_DEBUG) version = TCP_HAS_DEBUG_PRINT;
version (TCP_OUTPUT_DEBUG) version = TCP_HAS_DEBUG_PRINT;

nothrow @nogc:

/* Function declarations live in tcp.d / tcp_in.d / tcp_out.d; the public
   imports above bring their symbols into scope at their original module
   path so the linker resolves them. */

/**
 * This is the Nagle algorithm: try to combine user data to send as few TCP
 * segments as possible. Only send if
 * - no previously transmitted data on the connection remains unacknowledged or
 * - the TF_NODELAY flag is set (nagle algorithm turned off for this pcb) or
 * - the only unsent segment is at least pcb->mss bytes long (or there is more
 *   than one unsent segment - with lwIP, this can happen although unsent->len < mss)
 * - or if we are in fast-retransmit (TF_INFR)
 */
int tcp_do_output_nagle(const(tcp_pcb)* tpcb) pure =>
    ((tpcb.unacked is null) ||
     (tpcb.flags & (TF_NODELAY | TF_INFR)) ||
     ((tpcb.unsent !is null) && ((tpcb.unsent.next !is null) ||
       (tpcb.unsent.len >= tpcb.mss))) ||
     ((tcp_sndbuf(tpcb) == 0) || (tcp_sndqueuelen(tpcb) >= TCP_SND_QUEUELEN))
    ) ? 1 : 0;
err_t tcp_output_nagle(tcp_pcb* tpcb) { return tcp_do_output_nagle(tpcb) ? tcp_output(tpcb) : ERR_OK; }


bool TCP_SEQ_LT(uint a, uint b) pure     => ((a - b) & 0x80000000u) != 0;
bool TCP_SEQ_LEQ(uint a, uint b) pure    => !TCP_SEQ_LT(b, a);
bool TCP_SEQ_GT(uint a, uint b) pure     => TCP_SEQ_LT(b, a);
bool TCP_SEQ_GEQ(uint a, uint b) pure    => TCP_SEQ_LEQ(b, a);
/* is b<=a<=c? */
bool TCP_SEQ_BETWEEN(uint a, uint b, uint c) pure => TCP_SEQ_GEQ(a, b) && TCP_SEQ_LEQ(a, c);

enum TCP_TMR_INTERVAL       = 250;  /* The TCP timer interval in milliseconds. */

enum TCP_FAST_INTERVAL      = TCP_TMR_INTERVAL; /* the fine grained timeout in milliseconds */

enum TCP_SLOW_INTERVAL      = (2*TCP_TMR_INTERVAL);  /* the coarse grained timeout in milliseconds */

enum TCP_FIN_WAIT_TIMEOUT = 20000; /* milliseconds */
enum TCP_SYN_RCVD_TIMEOUT = 20000; /* milliseconds */

enum TCP_OOSEQ_TIMEOUT        = 6U; /* x RTO */

enum TCP_MSL = 60000UL; /* The maximum segment lifetime in milliseconds */

/* Keepalive values, compliant with RFC 1122. Don't change this unless you know what you're doing */
enum TCP_KEEPIDLE_DEFAULT     = 7200000UL; /* Default KEEPALIVE timer in milliseconds */

enum TCP_KEEPINTVL_DEFAULT    = 75000UL;   /* Default Time between KEEPALIVE probes in milliseconds */

enum TCP_KEEPCNT_DEFAULT      = 9U;        /* Default Counter for KEEPALIVE probes */

enum TCP_MAXIDLE              = TCP_KEEPCNT_DEFAULT * TCP_KEEPINTVL_DEFAULT;  /* Maximum KEEPALIVE probe time */

ushort TCP_TCPLEN(const(tcp_seg)* seg) pure => cast(ushort)(seg.len + ((TCPH_FLAGS(seg.tcphdr) & (TCP_FIN | TCP_SYN)) != 0 ? 1U : 0U));

/** Flags used on input processing, not on pcb->flags
*/
enum ubyte TF_RESET     = 0x08U;   /* Connection was reset. */
enum ubyte TF_CLOSED    = 0x10U;   /* Connection was successfully closed. */
enum ubyte TF_GOT_FIN   = 0x20U;   /* Connection was closed by the remote end. */


/* Raw callback API event dispatchers. LWIP_EVENT_API alternative removed —
   we use the per-PCB function-pointer model exclusively. */

void TCP_EVENT_ACCEPT(tcp_pcb_listen* lpcb, tcp_pcb* pcb, void* arg, err_t err, ref err_t ret) {
    if (lpcb.accept !is null)
        ret = lpcb.accept(arg, pcb, err);
    else ret = ERR_ARG;
}

void TCP_EVENT_SENT(tcp_pcb* pcb, ushort space, ref err_t ret) {
    if (pcb.sent !is null)
        ret = pcb.sent(pcb.callback_arg, pcb, space);
    else ret = ERR_OK;
}

void TCP_EVENT_RECV(tcp_pcb* pcb, pbuf* p, err_t err, ref err_t ret) {
    if (pcb.recv !is null) {
        ret = pcb.recv(pcb.callback_arg, pcb, p, err);
    } else {
        ret = tcp_recv_null(null, pcb, p, err);
    }
}

void TCP_EVENT_CLOSED(tcp_pcb* pcb, ref err_t ret) {
    if (pcb.recv !is null) {
        ret = pcb.recv(pcb.callback_arg, pcb, null, ERR_OK);
    } else {
        ret = ERR_OK;
    }
}

void TCP_EVENT_CONNECTED(tcp_pcb* pcb, err_t err, ref err_t ret) {
    if (pcb.connected !is null)
        ret = pcb.connected(pcb.callback_arg, pcb, err);
    else ret = ERR_OK;
}

void TCP_EVENT_POLL(tcp_pcb* pcb, ref err_t ret) {
    if (pcb.poll !is null)
        ret = pcb.poll(pcb.callback_arg, pcb);
    else ret = ERR_OK;
}

void TCP_EVENT_ERR(tcp_state last_state, tcp_err_fn errf, void* arg, err_t err) {
    cast(void)last_state;
    if (errf !is null)
        errf(arg, err);
}

/** Enabled extra-check for TCP_OVERSIZE if LWIP_DEBUG is enabled */
/* TCP_OVERSIZE_DBGCHECK: composite version, set at top of file. */

/** Don't generate checksum on copy if CHECKSUM_GEN_TCP is disabled */
/* TCP_CHECKSUM_ON_COPY: composite version, set at top of file. */

/* TF_SEG_* flags and struct tcp_seg live in package.d alongside tcp_pcb. */

enum LWIP_TCP_OPT_EOL        = 0;
enum LWIP_TCP_OPT_NOP        = 1;
enum LWIP_TCP_OPT_MSS        = 2;
enum LWIP_TCP_OPT_WS         = 3;
enum LWIP_TCP_OPT_SACK_PERM  = 4;
enum LWIP_TCP_OPT_TS         = 8;

enum LWIP_TCP_OPT_LEN_MSS    = 4;
version (LWIP_TCP_TIMESTAMPS) {
enum LWIP_TCP_OPT_LEN_TS     = 10;
enum LWIP_TCP_OPT_LEN_TS_OUT = 12; /* aligned for output (includes NOP padding) */
} else {
enum LWIP_TCP_OPT_LEN_TS_OUT = 0;
}
version (LWIP_WND_SCALE) {
enum LWIP_TCP_OPT_LEN_WS     = 3;
enum LWIP_TCP_OPT_LEN_WS_OUT = 4; /* aligned for output (includes NOP padding) */
} else {
enum LWIP_TCP_OPT_LEN_WS_OUT = 0;
}

version (LWIP_TCP_SACK_OUT) {
enum LWIP_TCP_OPT_LEN_SACK_PERM     = 2;
enum LWIP_TCP_OPT_LEN_SACK_PERM_OUT = 4; /* aligned for output (includes NOP padding) */
} else {
enum LWIP_TCP_OPT_LEN_SACK_PERM_OUT = 0;
}

uint LWIP_TCP_OPT_LENGTH(ubyte flags) pure =>
    ((flags & TF_SEG_OPTS_MSS)       ? LWIP_TCP_OPT_LEN_MSS           : 0) +
    ((flags & TF_SEG_OPTS_TS)        ? LWIP_TCP_OPT_LEN_TS_OUT        : 0) +
    ((flags & TF_SEG_OPTS_WND_SCALE) ? LWIP_TCP_OPT_LEN_WS_OUT        : 0) +
    ((flags & TF_SEG_OPTS_SACK_PERM) ? LWIP_TCP_OPT_LEN_SACK_PERM_OUT : 0);

/** This returns a TCP header option for MSS in an u32_t */
/* TCP_BUILD_MSS_OPTION inlined at its single call site in tcp_out.d. */

version (LWIP_WND_SCALE) {
enum TCPWND_MAX         = 0xFFFFFFFFU;
void TCPWND_CHECK16(tcpwnd_size_t x) { assert(x <= 0xFFFF, "window size > 0xFFFF"); }
ushort TCPWND_MIN16(tcpwnd_size_t x) pure => cast(ushort)(x < 0xFFFF ? x : 0xFFFF);
} else { /* LWIP_WND_SCALE */
enum TCPWND_MAX         = 0xFFFFU;
void TCPWND_CHECK16(tcpwnd_size_t x) pure {}
tcpwnd_size_t TCPWND_MIN16(tcpwnd_size_t x) pure => x;
} /* LWIP_WND_SCALE */

/* The TCP PCB lists. lwIP keeps the union type local to tcp_priv.h; the
   storage lives in tcp.d. We declare the type here and import the storage. */
union tcp_listen_pcbs_t { /* List of all TCP PCBs in LISTEN state. */
  tcp_pcb_listen* listen_pcbs;
  tcp_pcb* pcbs;
}

enum NUM_TCP_PCB_LISTS_NO_TIME_WAIT = 3;
enum NUM_TCP_PCB_LISTS              = 4;

/* Global variables defined in tcp.d. D module-path mangling means we have to
   re-export them rather than declare `extern` — `extern` would mint a new
   symbol at the tcp_priv module path that no definition matches. */
public import protocol.ip.tcp.tcp :
    tcp_ticks,
    tcp_active_pcbs_changed,
    tcp_bound_pcbs,
    tcp_listen_pcbs,
    tcp_active_pcbs,
    tcp_tw_pcbs,
    tcp_pcb_lists;
public import protocol.ip.tcp.tcp_in : tcp_input_pcb;

/* Axioms about the above lists:
   1) Every TCP PCB that is not CLOSED is in one of the lists.
   2) A PCB is only in one of the lists.
   3) All PCBs in the tcp_listen_pcbs list is in LISTEN state.
   4) All PCBs in the tcp_tw_pcbs list is in TIME-WAIT state.
*/
/* Define two macros, TCP_REG and TCP_RMV that registers a TCP PCB
   with a PCB list or removes a PCB from a list, respectively. */
enum TCP_DEBUG_PCB_LISTS = 0;
version (TCP_DEBUG_PCB_LISTS) {
void TCP_REG(T)(T** pcbs, T* npcb) {
    T* tcp_tmp_pcb;
    LWIP_DEBUGF(TCP_DEBUG, "TCP_REG ", npcb, " local port ", npcb.local_port);
    for (tcp_tmp_pcb = *pcbs; tcp_tmp_pcb !is null; tcp_tmp_pcb = tcp_tmp_pcb.next) {
        assert(tcp_tmp_pcb !is npcb, "TCP_REG: already registered");
    }
    assert((pcbs == &tcp_bound_pcbs) || (npcb.state != CLOSED), "TCP_REG: pcb->state != CLOSED");
    npcb.next = *pcbs;
    assert(npcb.next !is npcb, "TCP_REG: npcb->next != npcb");
    *pcbs = npcb;
    assert(tcp_pcbs_sane(), "TCP_REG: tcp_pcbs sane");
    tcp_timer_needed();
}
void TCP_RMV(T)(T** pcbs, T* npcb) {
    T* tcp_tmp_pcb;
    assert(*pcbs !is null, "TCP_RMV: pcbs != NULL");
    LWIP_DEBUGF(TCP_DEBUG, "TCP_RMV: removing ", npcb, " from ", *pcbs);
    if (*pcbs is npcb) {
        *pcbs = (*pcbs).next;
    } else for (tcp_tmp_pcb = *pcbs; tcp_tmp_pcb !is null; tcp_tmp_pcb = tcp_tmp_pcb.next) {
        if (tcp_tmp_pcb.next is npcb) {
            tcp_tmp_pcb.next = npcb.next;
            break;
        }
    }
    npcb.next = null;
    assert(tcp_pcbs_sane(), "TCP_RMV: tcp_pcbs sane");
    LWIP_DEBUGF(TCP_DEBUG, "TCP_RMV: removed ", npcb, " from ", *pcbs);
}

} else { /* LWIP_DEBUG */

void TCP_REG(T)(T** pcbs, T* npcb) {
    npcb.next = *pcbs;
    *pcbs = npcb;
    tcp_timer_needed();
}

void TCP_RMV(T)(T** pcbs, T* npcb) {
    if (*pcbs is npcb) {
        *pcbs = (*pcbs).next;
    }
    else {
        T* tcp_tmp_pcb;
        for (tcp_tmp_pcb = *pcbs; tcp_tmp_pcb !is null; tcp_tmp_pcb = tcp_tmp_pcb.next) {
            if (tcp_tmp_pcb.next is npcb) {
                tcp_tmp_pcb.next = npcb.next;
                break;
            }
        }
    }
    npcb.next = null;
}

} /* LWIP_DEBUG */

void TCP_REG_ACTIVE(tcp_pcb* npcb) {
    TCP_REG(&tcp_active_pcbs, npcb);
    tcp_active_pcbs_changed = 1;
}

void TCP_RMV_ACTIVE(tcp_pcb* npcb) {
    TCP_RMV(&tcp_active_pcbs, npcb);
    tcp_active_pcbs_changed = 1;
}

void TCP_PCB_REMOVE_ACTIVE(tcp_pcb* pcb) {
    tcp_pcb_remove(&tcp_active_pcbs, pcb);
    tcp_active_pcbs_changed = 1;
}


/* Internal functions: */
tcp_pcb* tcp_pcb_copy(tcp_pcb* pcb);

void tcp_ack(tcp_pcb* pcb) {
    if (pcb.flags & TF_ACK_DELAY) {
        tcp_clear_flags(pcb, TF_ACK_DELAY);
        tcp_ack_now(pcb);
    }
    else {
        tcp_set_flags(pcb, TF_ACK_DELAY);
    }
}

void tcp_ack_now(tcp_pcb* pcb) {
    tcp_set_flags(pcb, TF_ACK_NOW);
}

version (TCP_CALCULATE_EFF_SEND_MSS) {
ushort tcp_eff_send_mss(ushort sendmss, const(ip_addr_t)* src, const(ip_addr_t)* dest) {
    return tcp_eff_send_mss_netif(sendmss, ip_route(src, dest), dest);
}
} /* TCP_CALCULATE_EFF_SEND_MSS */


version (TCP_HAS_DEBUG_PRINT) {
void tcp_debug_print(tcp_hdr* tcphdr);
void tcp_debug_print_flags(ubyte flags);
void tcp_debug_print_state(tcp_state s);
void tcp_debug_print_pcbs();
short tcp_pcbs_sane();
} else {
void tcp_debug_print(tcp_hdr* tcphdr) pure {}
void tcp_debug_print_flags(ubyte flags) pure {}
void tcp_debug_print_state(tcp_state s) pure {}
void tcp_debug_print_pcbs() pure {}
short tcp_pcbs_sane() pure => 1;
} /* TCP_DEBUG */

/** External function (in lwIP: implemented in timers.c), called when TCP
 * detects that a timer is needed. We drive timers from tcp_tick() so this
 * is a no-op. */
void tcp_timer_needed() pure {}

version (LWIP_TCP_PCB_NUM_EXT_ARGS) {
err_t tcp_ext_arg_invoke_callbacks_passive_open(tcp_pcb_listen* lpcb, tcp_pcb* cpcb);
}

} /* LWIP_TCP */
