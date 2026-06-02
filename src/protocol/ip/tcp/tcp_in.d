/**
 * @file
 * Transmission Control Protocol, incoming traffic
 *
 * The input processing functions of the TCP layer.
 *
 * These functions are generally called in the order (ip_input() ->)
 * tcp_input() -> * tcp_process() -> tcp_receive() (-> application).
 *
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
module protocol.ip.tcp.tcp_in;

version (UseInternalIPStack):

/* File-local versions — flip the commented ones to enable per-subsystem
   debug traces; CHECKSUM_CHECK_TCP is build-default on. */
version = CHECKSUM_CHECK_TCP;
//version = TCP_WND_DEBUG;

/* Composite version derivations (file-local — see tcp.d for explanation).
   LWIP_CALLBACK_API is hard-wired on, so TCP_PCB_HAS_LISTENER is too. */
version = TCP_PCB_HAS_LISTENER;

import protocol.ip.tcp.opt;

version (LWIP_TCP) { /* don't build if not configured for use in lwipopts.h */

import protocol.ip.tcp;
import protocol.ip.tcp.tcpbase;
import protocol.ip.tcp.tcp_priv;
import protocol.ip.tcp.pbuf;
import protocol.ip.tcp.prot_tcp;
import protocol.ip.tcp.ip;

import urt.endian : loadBigEndian, storeBigEndian;
import urt.mem : memset, memcpy;
import urt.mem.allocator : defaultAllocator;
import urt.util : min, max, byte_reverse;

nothrow @nogc:

/** Initial CWND calculation as defined RFC 2581 */
tcpwnd_size_t LWIP_TCP_CALC_INITIAL_CWND(ushort mss) pure => cast(tcpwnd_size_t)min((4U * mss), max((2U * mss), 4380U));

/* These variables are global to all functions involved in the input
   processing of TCP segments. They are set by the tcp_input()
   function. */
private tcp_seg inseg;
private tcp_hdr* tcphdr;
private ushort tcphdr_optlen;
private ushort tcphdr_opt1len;
private ubyte* tcphdr_opt2;
private ushort tcp_optidx;
private uint seqno, ackno;
private tcpwnd_size_t recv_acked;
private ushort tcplen;
private ubyte flags;

private ubyte recv_flags;
private pbuf* recv_data;

tcp_pcb* tcp_input_pcb;

/* Forward declarations. */
private err_t tcp_process(tcp_pcb* pcb);
private void tcp_receive(tcp_pcb* pcb);
private void tcp_parseopt(tcp_pcb* pcb);

private void tcp_listen_input(tcp_pcb_listen* pcb);
private void tcp_timewait_input(tcp_pcb* pcb);

private int tcp_input_delayed_close(tcp_pcb* pcb);

version (LWIP_TCP_SACK_OUT) {
private void tcp_add_sack(tcp_pcb* pcb, uint left, uint right);
private void tcp_remove_sacks_lt(tcp_pcb* pcb, uint seq);
version (TCP_OOSEQ_BYTES_LIMIT) version = TCP_OOSEQ_HAS_LIMIT;
version (TCP_OOSEQ_PBUFS_LIMIT) version = TCP_OOSEQ_HAS_LIMIT;
version (TCP_OOSEQ_HAS_LIMIT) {
private void tcp_remove_sacks_gt(tcp_pcb* pcb, uint seq);
} /* TCP_OOSEQ_BYTES_LIMIT || TCP_OOSEQ_PBUFS_LIMIT */
} /* LWIP_TCP_SACK_OUT */

/**
 * The initial input processing of TCP. It verifies the TCP header, demultiplexes
 * the segment between the PCBs and passes it on to tcp_process(), which implements
 * the TCP finite state machine. This function is called by the IP layer (in
 * ip_input()).
 *
 * @param p received TCP segment to process (p->payload pointing to the TCP header)
 * @param inp network interface on which this segment was received
 */
void
tcp_input(pbuf* p, netif inp)
{
  tcp_pcb* pcb, prev;
  tcp_pcb_listen* lpcb;
version (SO_REUSE) {
  tcp_pcb* lpcb_prev = null;
  tcp_pcb_listen* lpcb_any = null;
} /* SO_REUSE */
  ubyte hdrlen_bytes;
  err_t err;

  assert(p !is null, "tcp_input: invalid pbuf");



  tcphdr = cast(tcp_hdr*)p.payload;

version (TCP_INPUT_DEBUG) {
  tcp_debug_print(tcphdr);
}

  /* Check that TCP header fits in payload */
  if (p.len < TCP_HLEN) {
    /* drop short packets */
    LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: short packet (", p.tot_len, " bytes) discarded\n");
    goto dropped;
  }

  /* Don't even process incoming broadcasts/multicasts. */
  if (ip_addr_isbroadcast(ip_current_dest_addr(), ip_current_netif()) ||
      ip_addr_ismulticast(ip_current_dest_addr())) {
    goto dropped;
  }

version (CHECKSUM_CHECK_TCP) {
  if (IF__NETIF_CHECKSUM_ENABLED(inp, NETIF_CHECKSUM_CHECK_TCP)) {
    /* Verify TCP checksum. */
    ushort chksum = ip_chksum_pseudo(p, IP_PROTO_TCP, p.tot_len,
                                    ip_current_src_addr(), ip_current_dest_addr());
    if (chksum != 0) {
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: packet discarded due to failing checksum 0x", chksum, "\n");
      tcp_debug_print(tcphdr);
      goto dropped;
    }
  }
} /* CHECKSUM_CHECK_TCP */

  /* sanity-check header length */
  hdrlen_bytes = TCPH_HDRLEN_BYTES(tcphdr);
  if ((hdrlen_bytes < TCP_HLEN) || (hdrlen_bytes > p.tot_len)) {
    LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: invalid header length (", cast(ushort)hdrlen_bytes, ")\n");
    goto dropped;
  }

  /* Move the payload pointer in the pbuf so that it points to the
     TCP data instead of the TCP header. */
  tcphdr_optlen = cast(ushort)(hdrlen_bytes - TCP_HLEN);
  tcphdr_opt2 = null;
  if (p.len >= hdrlen_bytes) {
    /* all options are in the first pbuf */
    tcphdr_opt1len = tcphdr_optlen;
    pbuf_remove_header(p, hdrlen_bytes); /* cannot fail */
  } else {
    ushort opt2len;
    /* TCP header fits into first pbuf, options don't - data is in the next pbuf */
    /* there must be a next pbuf, due to hdrlen_bytes sanity check above */
    assert(p.next !is null, "p->next != NULL");

    /* advance over the TCP header (cannot fail) */
    pbuf_remove_header(p, TCP_HLEN);

    /* determine how long the first and second parts of the options are */
    tcphdr_opt1len = p.len;
    opt2len = cast(ushort)(tcphdr_optlen - tcphdr_opt1len);

    /* options continue in the next pbuf: set p to zero length and hide the
        options in the next pbuf (adjusting p->tot_len) */
    pbuf_remove_header(p, tcphdr_opt1len);

    /* check that the options fit in the second pbuf */
    if (opt2len > p.next.len) {
      /* drop short packets */
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: options overflow second pbuf (", p.next.len, " bytes)\n");
      goto dropped;
    }

    /* remember the pointer to the second part of the options */
    tcphdr_opt2 = cast(ubyte*)p.next.payload;

    /* advance p->next to point after the options, and manually
        adjust p->tot_len to keep it consistent with the changed p->next */
    pbuf_remove_header(p.next, opt2len);
    p.tot_len = cast(ushort)(p.tot_len - opt2len);

    assert(p.len == 0, "p->len == 0");
    assert(p.tot_len == p.next.tot_len, "p->tot_len == p->next->tot_len");
  }

  /* Convert fields in TCP header to host byte order. */
  tcphdr.src = loadBigEndian(&tcphdr.src);
  tcphdr.dest = loadBigEndian(&tcphdr.dest);
  seqno = tcphdr.seqno = loadBigEndian(&tcphdr.seqno);
  ackno = tcphdr.ackno = loadBigEndian(&tcphdr.ackno);
  tcphdr.wnd = loadBigEndian(&tcphdr.wnd);

  flags = TCPH_FLAGS(tcphdr);
  tcplen = p.tot_len;
  if (flags & (TCP_FIN | TCP_SYN)) {
    tcplen++;
    if (tcplen < p.tot_len) {
      /* u16_t overflow, cannot handle this */
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: length u16_t overflow, cannot handle this\n");
      goto dropped;
    }
  }

  /* Demultiplex an incoming segment. First, we check if it is destined
     for an active connection. */
  prev = null;

  for (pcb = tcp_active_pcbs; pcb !is null; pcb = pcb.next) {
    assert(pcb.state != CLOSED, "tcp_input: active pcb->state != CLOSED");
    assert(pcb.state != TIME_WAIT, "tcp_input: active pcb->state != TIME-WAIT");
    assert(pcb.state != LISTEN, "tcp_input: active pcb->state != LISTEN");

    /* check if PCB is bound to specific netif */
    if ((pcb.netif_idx != NETIF_NO_INDEX) &&
        (pcb.netif_idx != netif_get_index(ip_data.current_input_netif))) {
      prev = pcb;
      continue;
    }

    if (pcb.remote_port == tcphdr.src &&
        pcb.local_port == tcphdr.dest &&
        ip_addr_eq(&pcb.remote_ip, ip_current_src_addr()) &&
        ip_addr_eq(&pcb.local_ip, ip_current_dest_addr())) {
      /* Move this PCB to the front of the list so that subsequent
         lookups will be faster (we exploit locality in TCP segment
         arrivals). */
      assert(pcb.next !is pcb, "tcp_input: pcb->next != pcb (before cache)");
      if (prev !is null) {
        prev.next = pcb.next;
        pcb.next = tcp_active_pcbs;
        tcp_active_pcbs = pcb;
      } else {
      }
      assert(pcb.next !is pcb, "tcp_input: pcb->next != pcb (after cache)");
      break;
    }
    prev = pcb;
  }

  if (pcb is null) {
    /* If it did not go to an active connection, we check the connections
       in the TIME-WAIT state. */
    for (pcb = tcp_tw_pcbs; pcb !is null; pcb = pcb.next) {
      assert(pcb.state == TIME_WAIT, "tcp_input: TIME-WAIT pcb->state == TIME-WAIT");

      /* check if PCB is bound to specific netif */
      if ((pcb.netif_idx != NETIF_NO_INDEX) &&
          (pcb.netif_idx != netif_get_index(ip_data.current_input_netif))) {
        continue;
      }

      if (pcb.remote_port == tcphdr.src &&
          pcb.local_port == tcphdr.dest &&
          ip_addr_eq(&pcb.remote_ip, ip_current_src_addr()) &&
          ip_addr_eq(&pcb.local_ip, ip_current_dest_addr())) {
        /* We don't really care enough to move this PCB to the front
           of the list since we are not very likely to receive that
           many segments for connections in TIME-WAIT. */
        LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: packed for TIME_WAITing connection.\n");
//version (LWIP_HOOK_TCP_INPACKET_PCB) {
//        if (LWIP_HOOK_TCP_INPACKET_PCB(pcb, tcphdr, tcphdr_optlen, tcphdr_opt1len,
//                                       tcphdr_opt2, p) == ERR_OK)
//}
        {
          tcp_timewait_input(pcb);
        }
        pbuf_free(p);
        return;
      }
    }

    /* Finally, if we still did not get a match, we check all PCBs that
       are LISTENing for incoming connections. */
    prev = null;
    for (lpcb = tcp_listen_pcbs.listen_pcbs; lpcb !is null; lpcb = lpcb.next) {
      /* check if PCB is bound to specific netif */
      if ((lpcb.netif_idx != NETIF_NO_INDEX) &&
          (lpcb.netif_idx != netif_get_index(ip_data.current_input_netif))) {
        prev = cast(tcp_pcb*)lpcb;
        continue;
      }

      if (lpcb.local_port == tcphdr.dest) {
        if (IP_IS_ANY_TYPE_VAL(lpcb.local_ip)) {
          /* found an ANY TYPE (IPv4/IPv6) match */
version (SO_REUSE) {
          lpcb_any = lpcb;
          lpcb_prev = prev;
} else { /* SO_REUSE */
          break;
} /* SO_REUSE */
        } else if (IP_ADDR_PCB_VERSION_MATCH_EXACT(lpcb, ip_current_dest_addr())) {
          if (ip_addr_eq(&lpcb.local_ip, ip_current_dest_addr())) {
            /* found an exact match */
            break;
          } else if (ip_addr_isany(&lpcb.local_ip)) {
            /* found an ANY-match */
version (SO_REUSE) {
            lpcb_any = lpcb;
            lpcb_prev = prev;
} else { /* SO_REUSE */
            break;
} /* SO_REUSE */
          }
        }
      }
      prev = cast(tcp_pcb*)lpcb;
    }
version (SO_REUSE) {
    /* first try specific local IP */
    if (lpcb is null) {
      /* only pass to ANY if no specific local IP has been found */
      lpcb = lpcb_any;
      prev = lpcb_prev;
    }
} /* SO_REUSE */
    if (lpcb !is null) {
      /* Move this PCB to the front of the list so that subsequent
         lookups will be faster (we exploit locality in TCP segment
         arrivals). */
      if (prev !is null) {
        (cast(tcp_pcb_listen*)prev).next = lpcb.next;
        /* our successor is the remainder of the listening list */
        lpcb.next = tcp_listen_pcbs.listen_pcbs;
        /* put this listening pcb at the head of the listening list */
        tcp_listen_pcbs.listen_pcbs = lpcb;
      } else {
      }

      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: packed for LISTENing connection.\n");
      {
        tcp_listen_input(lpcb);
      }
      pbuf_free(p);
      return;
    }
  }

version (TCP_INPUT_DEBUG) {
  LWIP_DEBUGF(TCP_INPUT_DEBUG, "+-+-+-+-+-+-+-+-+-+-+-+-+-+- tcp_input: flags ");
  tcp_debug_print_flags(TCPH_FLAGS(tcphdr));
  LWIP_DEBUGF(TCP_INPUT_DEBUG, "-+-+-+-+-+-+-+-+-+-+-+-+-+-+\n");
} /* TCP_INPUT_DEBUG */


  if (pcb !is null) {
    /* The incoming segment belongs to a connection. */
version (TCP_INPUT_DEBUG) {
    tcp_debug_print_state(pcb.state);
} /* TCP_INPUT_DEBUG */

    /* Set up a tcp_seg structure. */
    inseg.next = null;
    inseg.len = p.tot_len;
    inseg.p = p;
    inseg.tcphdr = tcphdr;

    recv_data = null;
    recv_flags = 0;
    recv_acked = 0;

    if (flags & TCP_PSH) {
      p.flags |= PBUF_FLAG_PUSH;
    }

    /* If there is data which was previously "refused" by upper layer */
    if (pcb.refused_data !is null) {
      if ((tcp_process_refused_data(pcb) == ERR_ABRT) ||
          ((pcb.refused_data !is null) && (tcplen > 0))) {
        /* pcb has been aborted or refused data is still refused and the new
           segment contains data */
        if (pcb.rcv_ann_wnd == 0) {
          /* this is a zero-window probe, we respond to it with current RCV.NXT
          and drop the data segment */
          tcp_send_empty_ack(pcb);
        }
        goto aborted;
      }
    }
    tcp_input_pcb = pcb;
    err = tcp_process(pcb);
    /* A return value of ERR_ABRT means that tcp_abort() was called
       and that the pcb has been freed. If so, we don't do anything. */
    if (err != ERR_ABRT) {
      if (recv_flags & TF_RESET) {
        /* TF_RESET means that the connection was reset by the other
           end. We then call the error callback to inform the
           application that the connection is dead before we
           deallocate the PCB. */
        TCP_EVENT_ERR(pcb.state, pcb.errf, pcb.callback_arg, ERR_RST);
        tcp_pcb_remove(&tcp_active_pcbs, pcb);
        tcp_free(pcb);
      } else {
        err = ERR_OK;
        /* If the application has registered a "sent" function to be
           called when new send buffer space is available, we call it
           now. */
        if (recv_acked > 0) {
          ushort acked16;
          /* recv_acked is u32_t but the sent callback only takes a u16_t,
             so we might have to call it multiple times when LWIP_WND_SCALE
             allows acked > 0xFFFF. */
          uint acked = recv_acked;
          while (true) {
            version (LWIP_WND_SCALE) {
              acked16 = cast(ushort)min(acked, 0xffffu);
              acked -= acked16;
            } else {
              acked16 = cast(ushort)recv_acked;
            }
            TCP_EVENT_SENT(pcb, cast(ushort)acked16, err);
            if (err == ERR_ABRT) {
              goto aborted;
            }
            version (LWIP_WND_SCALE) {
              if (acked == 0) break;
            } else {
              break;
            }
          }
          recv_acked = 0;
        }
        if (tcp_input_delayed_close(pcb)) {
          goto aborted;
        }
        while (recv_data !is null) {
          pbuf* rest = null;
          version (TCP_QUEUE_OOSEQ) version (LWIP_WND_SCALE) {
            pbuf_split_64k(recv_data, &rest);
          }

          assert(pcb.refused_data is null, "pcb->refused_data == NULL");
          if (pcb.flags & TF_RXCLOSED) {
            /* received data although already closed -> abort (send RST) */
            pbuf_free(recv_data);
            if (rest !is null) pbuf_free(rest);
            tcp_abort(pcb);
            goto aborted;
          }

          TCP_EVENT_RECV(pcb, recv_data, ERR_OK, err);
          if (err == ERR_ABRT) {
            if (rest !is null) pbuf_free(rest);
            goto aborted;
          }

          if (err != ERR_OK) {
            if (rest !is null) pbuf_cat(recv_data, rest);
            pcb.refused_data = recv_data;
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_input: keep incoming packet, because pcb is \"full\"\n");
            break;
          }

          version (TCP_QUEUE_OOSEQ) version (LWIP_WND_SCALE) {
            recv_data = rest;
            continue;
          }
          break;
        }

        /* If a FIN segment was received, we call the callback
           function with a NULL buffer to indicate EOF. */
        if (recv_flags & TF_GOT_FIN) {
          if (pcb.refused_data !is null) {
            /* Delay this if we have refused data. */
            pcb.refused_data.flags |= PBUF_FLAG_TCP_FIN;
          } else {
            /* correct rcv_wnd as the application won't call tcp_recved()
               for the FIN's seqno */
            if (pcb.rcv_wnd != TCP_WND_MAX(pcb)) {
              pcb.rcv_wnd++;
            }
            TCP_EVENT_CLOSED(pcb, err);
            if (err == ERR_ABRT) {
              goto aborted;
            }
          }
        }

        tcp_input_pcb = null;
        if (tcp_input_delayed_close(pcb)) {
          goto aborted;
        }
        /* Try to send something out. */
        tcp_output(pcb);
version (TCP_INPUT_DEBUG) {
version (TCP_DEBUG) {
        tcp_debug_print_state(pcb.state);
} /* TCP_DEBUG */
} /* TCP_INPUT_DEBUG */
      }
    }
    /* Jump target if pcb has been aborted in a callback (by calling tcp_abort()).
       Below this line, 'pcb' may not be dereferenced! */
aborted:
    tcp_input_pcb = null;
    recv_data = null;

    /* give up our reference to inseg.p */
    if (inseg.p !is null) {
      pbuf_free(inseg.p);
      inseg.p = null;
    }
  } else {
    /* If no matching PCB was found, send a TCP RST (reset) to the
       sender. */
    LWIP_DEBUGF(TCP_RST_DEBUG, "tcp_input: no PCB match found, resetting.\n");
    if (!(TCPH_FLAGS(tcphdr) & TCP_RST)) {
      tcp_rst_netif(ip_data.current_input_netif, ackno, seqno + tcplen, ip_current_dest_addr(),
              ip_current_src_addr(), tcphdr.dest, tcphdr.src);
    }
    pbuf_free(p);
  }

  assert(tcp_pcbs_sane(), "tcp_input: tcp_pcbs_sane()");
  return;
dropped:
  pbuf_free(p);
}

/** Called from tcp_input to check for TF_CLOSED flag. This results in closing
 * and deallocating a pcb at the correct place to ensure no one references it
 * any more.
 * @returns 1 if the pcb has been closed and deallocated, 0 otherwise
 */
private int
tcp_input_delayed_close(tcp_pcb* pcb)
{
  assert(pcb !is null, "tcp_input_delayed_close: invalid pcb");

  if (recv_flags & TF_CLOSED) {
    /* The connection has been closed and we will deallocate the
        PCB. */
    if (!(pcb.flags & TF_RXCLOSED)) {
      /* Connection closed although the application has only shut down the
          tx side: call the PCB's err callback and indicate the closure to
          ensure the application doesn't continue using the PCB. */
      TCP_EVENT_ERR(pcb.state, pcb.errf, pcb.callback_arg, ERR_CLSD);
    }
    tcp_pcb_remove(&tcp_active_pcbs, pcb);
    tcp_free(pcb);
    return 1;
  }
  return 0;
}

/**
 * Called by tcp_input() when a segment arrives for a listening
 * connection (from tcp_input()).
 *
 * @param pcb the tcp_pcb_listen for which a segment arrived
 *
 * @note the segment which arrived is saved in global variables, therefore only the pcb
 *       involved is passed as a parameter to this function
 */
private void
tcp_listen_input(tcp_pcb_listen* pcb)
{
  tcp_pcb* npcb;
  uint iss;
  err_t rc;

  if (flags & TCP_RST) {
    /* An incoming RST should be ignored. Return. */
    return;
  }

  assert(pcb !is null, "tcp_listen_input: invalid pcb");

  /* In the LISTEN state, we check for incoming SYN segments,
     creates a new PCB, and responds with a SYN|ACK. */
  if (flags & TCP_ACK) {
    /* For incoming segments with the ACK flag set, respond with a
       RST. */
    LWIP_DEBUGF(TCP_RST_DEBUG, "tcp_listen_input: ACK in LISTEN, sending reset\n");
    tcp_rst_netif(ip_data.current_input_netif, ackno, seqno + tcplen, ip_current_dest_addr(),
            ip_current_src_addr(), tcphdr.dest, tcphdr.src);
  } else if (flags & TCP_SYN) {
    LWIP_DEBUGF(TCP_DEBUG, "TCP connection request ", tcphdr.src, " -> ", tcphdr.dest, ".\n");
version (TCP_LISTEN_BACKLOG) {
    if (pcb.accepts_pending >= pcb.backlog) {
      LWIP_DEBUGF(TCP_DEBUG, "tcp_listen_input: listen backlog exceeded for port ", tcphdr.dest, "\n");
      return;
    }
} /* TCP_LISTEN_BACKLOG */
    npcb = tcp_alloc(pcb.prio);
    /* If a new PCB could not be created (probably due to lack of memory),
       we don't do anything, but rely on the sender will retransmit the
       SYN at a time when we have more memory available. */
    if (npcb is null) {
      err_t err;
      LWIP_DEBUGF(TCP_DEBUG, "tcp_listen_input: could not allocate PCB\n");
      TCP_EVENT_ACCEPT(pcb, null, pcb.callback_arg, ERR_MEM, err);
      return;
    }
version (TCP_LISTEN_BACKLOG) {
    pcb.accepts_pending++;
    tcp_set_flags(npcb, TF_BACKLOGPEND);
} /* TCP_LISTEN_BACKLOG */
    /* Set up the new PCB. */
    ip_addr_copy(npcb.local_ip, *ip_current_dest_addr());
    ip_addr_copy(npcb.remote_ip, *ip_current_src_addr());
    npcb.local_port = pcb.local_port;
    npcb.remote_port = tcphdr.src;
    npcb.state = SYN_RCVD;
    npcb.rcv_nxt = seqno + 1;
    npcb.rcv_ann_right_edge = npcb.rcv_nxt;
    iss = tcp_next_iss(npcb);
    npcb.snd_wl2 = iss;
    npcb.snd_nxt = iss;
    npcb.lastack = iss;
    npcb.snd_lbb = iss;
    npcb.snd_wl1 = seqno - 1;/* initialise to seqno-1 to force window update */
    npcb.callback_arg = pcb.callback_arg;
version (TCP_PCB_HAS_LISTENER) {
    npcb.listener = pcb;
} /* LWIP_CALLBACK_API || TCP_LISTEN_BACKLOG */
version (LWIP_VLAN_PCP) {
    npcb.netif_hints.tci = pcb.netif_hints.tci;
} /* LWIP_VLAN_PCP */
    /* inherit socket options */
    npcb.so_options = pcb.so_options & SOF_INHERITED;
    npcb.netif_idx = pcb.netif_idx;
    /* Register the new PCB so that we can begin receiving segments
       for it. */
    TCP_REG_ACTIVE(npcb);

    /* Parse any options in the SYN. */
    tcp_parseopt(npcb);
    npcb.snd_wnd = tcphdr.wnd;
    npcb.snd_wnd_max = npcb.snd_wnd;

version (TCP_CALCULATE_EFF_SEND_MSS) {
    npcb.mss = tcp_eff_send_mss(npcb.mss, &npcb.local_ip, &npcb.remote_ip);
} /* TCP_CALCULATE_EFF_SEND_MSS */


version (LWIP_TCP_PCB_NUM_EXT_ARGS) {
    if (tcp_ext_arg_invoke_callbacks_passive_open(pcb, npcb) != ERR_OK) {
      tcp_abandon(npcb, 0);
      return;
    }
}

    /* Send a SYN|ACK together with the MSS option. */
    rc = tcp_enqueue_flags(npcb, TCP_SYN | TCP_ACK);
    if (rc != ERR_OK) {
      tcp_abandon(npcb, 0);
      return;
    }
    tcp_output(npcb);
  }
  return;
}

/**
 * Called by tcp_input() when a segment arrives for a connection in
 * TIME_WAIT.
 *
 * @param pcb the tcp_pcb for which a segment arrived
 *
 * @note the segment which arrived is saved in global variables, therefore only the pcb
 *       involved is passed as a parameter to this function
 */
private void
tcp_timewait_input(tcp_pcb* pcb)
{
  /* RFC 1337: in TIME_WAIT, ignore RST and ACK FINs + any 'acceptable' segments */
  /* RFC 793 3.9 Event Processing - Segment Arrives:
   * - first check sequence number - we skip that one in TIME_WAIT (always
   *   acceptable since we only send ACKs)
   * - second check the RST bit (... return) */
  if (flags & TCP_RST) {
    return;
  }

  assert(pcb !is null, "tcp_timewait_input: invalid pcb");

  /* - fourth, check the SYN bit, */
  if (flags & TCP_SYN) {
    /* If an incoming segment is not acceptable, an acknowledgment
       should be sent in reply */
    if (TCP_SEQ_BETWEEN(seqno, pcb.rcv_nxt, pcb.rcv_nxt + pcb.rcv_wnd)) {
      /* If the SYN is in the window it is an error, send a reset */
      tcp_rst(pcb, ackno, seqno + tcplen, ip_current_dest_addr(),
              ip_current_src_addr(), tcphdr.dest, tcphdr.src);
      return;
    }
  } else if (flags & TCP_FIN) {
    /* - eighth, check the FIN bit: Remain in the TIME-WAIT state.
         Restart the 2 MSL time-wait timeout.*/
    pcb.tmr = tcp_ticks;
  }

  if ((tcplen > 0)) {
    /* Acknowledge data, FIN or out-of-window SYN */
    tcp_ack_now(pcb);
    tcp_output(pcb);
  }
  return;
}

/**
 * Implements the TCP state machine. Called by tcp_input. In some
 * states tcp_receive() is called to receive data. The tcp_seg
 * argument will be freed by the caller (tcp_input()) unless the
 * recv_data pointer in the pcb is set.
 *
 * @param pcb the tcp_pcb for which a segment arrived
 *
 * @note the segment which arrived is saved in global variables, therefore only the pcb
 *       involved is passed as a parameter to this function
 */
private err_t
tcp_process(tcp_pcb* pcb)
{
  tcp_seg* rseg;
  ubyte acceptable = 0;
  err_t err;

  err = ERR_OK;

  assert(pcb !is null, "tcp_process: invalid pcb");

  /* Process incoming RST segments. */
  if (flags & TCP_RST) {
    /* First, determine if the reset is acceptable. */
    if (pcb.state == SYN_SENT) {
      /* "In the SYN-SENT state (a RST received in response to an initial SYN),
          the RST is acceptable if the ACK field acknowledges the SYN." */
      if (ackno == pcb.snd_nxt) {
        acceptable = 1;
      }
    } else {
      /* "In all states except SYN-SENT, all reset (RST) segments are validated
          by checking their SEQ-fields." */
      if (seqno == pcb.rcv_nxt) {
        acceptable = 1;
      } else  if (TCP_SEQ_BETWEEN(seqno, pcb.rcv_nxt,
                                  pcb.rcv_nxt + pcb.rcv_wnd)) {
        /* If the sequence number is inside the window, we send a challenge ACK
           and wait for a re-send with matching sequence number.
           This follows RFC 5961 section 3.2 and addresses CVE-2004-0230
           (RST spoofing attack), which is present in RFC 793 RST handling. */
        tcp_ack_now(pcb);
      }
    }

    if (acceptable) {
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_process: Connection RESET\n");
      assert(pcb.state != CLOSED, "tcp_input: pcb->state != CLOSED");
      recv_flags |= TF_RESET;
      tcp_clear_flags(pcb, TF_ACK_DELAY);
      return ERR_RST;
    } else {
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_process: unacceptable reset seqno ", seqno, " rcv_nxt ", pcb.rcv_nxt, "\n");
      LWIP_DEBUGF(TCP_DEBUG, "tcp_process: unacceptable reset seqno ", seqno, " rcv_nxt ", pcb.rcv_nxt, "\n");
      return ERR_OK;
    }
  }

  if ((flags & TCP_SYN) && (pcb.state != SYN_SENT && pcb.state != SYN_RCVD)) {
    /* Cope with new connection attempt after remote end crashed */
    tcp_ack_now(pcb);
    return ERR_OK;
  }

  if ((pcb.flags & TF_RXCLOSED) == 0) {
    /* Update the PCB (in)activity timer unless rx is closed (see tcp_shutdown) */
    pcb.tmr = tcp_ticks;
  }
  pcb.keep_cnt_sent = 0;
  pcb.persist_probe = 0;

  tcp_parseopt(pcb);

  if (flags & TCP_SYN) {
    /* accept SYN only in 2 states: */
    if ((pcb.state != SYN_SENT) && (pcb.state != SYN_RCVD)) {
      return ERR_OK;
    }
  }

  /* Do different things depending on the TCP state. */
  switch (pcb.state) {
    case SYN_SENT:
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "SYN-SENT: ackno ", ackno, " pcb->snd_nxt ", pcb.snd_nxt, " unacked ",
                                    pcb.unacked ? "" : " empty:",
                                    pcb.unacked ? loadBigEndian(&pcb.unacked.tcphdr.seqno) : 0, "\n");
      /* received SYN ACK with expected sequence number? */
      if ((flags & TCP_ACK) && (flags & TCP_SYN)
          && (ackno == pcb.lastack + 1)) {
        pcb.rcv_nxt = seqno + 1;
        pcb.rcv_ann_right_edge = pcb.rcv_nxt;
        pcb.lastack = ackno;
        pcb.snd_wnd = tcphdr.wnd;
        pcb.snd_wnd_max = pcb.snd_wnd;
        pcb.snd_wl1 = seqno - 1; /* initialise to seqno - 1 to force window update */
        pcb.state = ESTABLISHED;

version (TCP_CALCULATE_EFF_SEND_MSS) {
        pcb.mss = tcp_eff_send_mss(pcb.mss, &pcb.local_ip, &pcb.remote_ip);
} /* TCP_CALCULATE_EFF_SEND_MSS */

        pcb.cwnd = LWIP_TCP_CALC_INITIAL_CWND(pcb.mss);
        LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_process (SENT): cwnd ", pcb.cwnd, " ssthresh ", pcb.ssthresh, "\n");
        assert(pcb.snd_queuelen > 0, "pcb->snd_queuelen > 0");
        --pcb.snd_queuelen;
        LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_process: SYN-SENT --queuelen ", cast(tcpwnd_size_t)pcb.snd_queuelen, "\n");
        rseg = pcb.unacked;
        if (rseg is null) {
          /* might happen if tcp_output fails in tcp_rexmit_rto()
             in which case the segment is on the unsent list */
          rseg = pcb.unsent;
          assert(rseg !is null, "no segment to free");
          pcb.unsent = rseg.next;
        } else {
          pcb.unacked = rseg.next;
        }
        tcp_seg_free(rseg);

        /* If there's nothing left to acknowledge, stop the retransmit
           timer, otherwise reset it to start again */
        if (pcb.unacked is null) {
          pcb.rtime = -1;
        } else {
          pcb.rtime = 0;
          pcb.nrtx = 0;
        }

        /* Call the user specified function to call when successfully
         * connected. */
        TCP_EVENT_CONNECTED(pcb, ERR_OK, err);
        if (err == ERR_ABRT) {
          return ERR_ABRT;
        }
        tcp_ack_now(pcb);
      }
      /* received ACK? possibly a half-open connection */
      else if (flags & TCP_ACK) {
        /* send a RST to bring the other side in a non-synchronized state. */
        tcp_rst(pcb, ackno, seqno + tcplen, ip_current_dest_addr(),
                ip_current_src_addr(), tcphdr.dest, tcphdr.src);
        /* Resend SYN immediately (don't wait for rto timeout) to establish
          connection faster, but do not send more SYNs than we otherwise would
          have, or we might get caught in a loop on loopback interfaces. */
        if (pcb.nrtx < TCP_SYNMAXRTX) {
          pcb.rtime = 0;
          tcp_rexmit_rto(pcb);
        }
      }
      break;
    case SYN_RCVD:
      if (flags & TCP_SYN) {
        if (seqno == pcb.rcv_nxt - 1) {
          /* Looks like another copy of the SYN - retransmit our SYN-ACK */
          tcp_rexmit(pcb);
        }
      } else if (flags & TCP_ACK) {
        /* expected ACK number? */
        if (TCP_SEQ_BETWEEN(ackno, pcb.lastack + 1, pcb.snd_nxt)) {
          pcb.state = ESTABLISHED;
          LWIP_DEBUGF(TCP_DEBUG, "TCP connection established ", inseg.tcphdr.src, " -> ", inseg.tcphdr.dest, ".\n");
          bool _listener_lost = false;
          version (TCP_PCB_HAS_LISTENER) {
            if (pcb.listener is null) {
              /* listen pcb might be closed by now */
              err = ERR_VAL;
              _listener_lost = true;
            }
          }
          if (!_listener_lost) {
            assert(pcb.listener.accept !is null, "pcb->listener->accept != NULL");
            tcp_backlog_accepted(pcb);
            /* Call the accept function. */
            TCP_EVENT_ACCEPT(pcb.listener, pcb, pcb.callback_arg, ERR_OK, err);
          }
          if (err != ERR_OK) {
            /* If the accept function returns with an error, we abort
             * the connection. */
            /* Already aborted? */
            if (err != ERR_ABRT) {
              tcp_abort(pcb);
            }
            return ERR_ABRT;
          }
          /* If there was any data contained within this ACK,
           * we'd better pass it on to the application as well. */
          tcp_receive(pcb);

          /* Prevent ACK for SYN to generate a sent event */
          if (recv_acked != 0) {
            recv_acked--;
          }

          pcb.cwnd = LWIP_TCP_CALC_INITIAL_CWND(pcb.mss);
          LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_process (SYN_RCVD): cwnd ", pcb.cwnd, " ssthresh ", pcb.ssthresh, "\n");

          if (recv_flags & TF_GOT_FIN) {
            tcp_ack_now(pcb);
            pcb.state = CLOSE_WAIT;
          }
        } else {
          /* incorrect ACK number, send RST */
          tcp_rst(pcb, ackno, seqno + tcplen, ip_current_dest_addr(),
                  ip_current_src_addr(), tcphdr.dest, tcphdr.src);
        }
      }
      break;
    case CLOSE_WAIT:
    /* FALLTHROUGH */
      goto case;
    case ESTABLISHED:
      tcp_receive(pcb);
      if (recv_flags & TF_GOT_FIN) { /* passive close */
        tcp_ack_now(pcb);
        pcb.state = CLOSE_WAIT;
      }
      break;
    case FIN_WAIT_1:
      tcp_receive(pcb);
      if (recv_flags & TF_GOT_FIN) {
        if ((flags & TCP_ACK) && (ackno == pcb.snd_nxt) &&
            pcb.unsent is null) {
          LWIP_DEBUGF(TCP_DEBUG,
                      "TCP connection closed: FIN_WAIT_1 ", inseg.tcphdr.src, " -> ", inseg.tcphdr.dest, ".\n");
          tcp_ack_now(pcb);
          tcp_pcb_purge(pcb);
          TCP_RMV_ACTIVE(pcb);
          pcb.state = TIME_WAIT;
          TCP_REG(&tcp_tw_pcbs, pcb);
        } else {
          tcp_ack_now(pcb);
          pcb.state = CLOSING;
        }
      } else if ((flags & TCP_ACK) && (ackno == pcb.snd_nxt) &&
                 pcb.unsent is null) {
        pcb.state = FIN_WAIT_2;
      }
      break;
    case FIN_WAIT_2:
      tcp_receive(pcb);
      if (recv_flags & TF_GOT_FIN) {
        LWIP_DEBUGF(TCP_DEBUG, "TCP connection closed: FIN_WAIT_2 ", inseg.tcphdr.src, " -> ", inseg.tcphdr.dest, ".\n");
        tcp_ack_now(pcb);
        tcp_pcb_purge(pcb);
        TCP_RMV_ACTIVE(pcb);
        pcb.state = TIME_WAIT;
        TCP_REG(&tcp_tw_pcbs, pcb);
      }
      break;
    case CLOSING:
      tcp_receive(pcb);
      if ((flags & TCP_ACK) && ackno == pcb.snd_nxt && pcb.unsent is null) {
        LWIP_DEBUGF(TCP_DEBUG, "TCP connection closed: CLOSING ", inseg.tcphdr.src, " -> ", inseg.tcphdr.dest, ".\n");
        tcp_pcb_purge(pcb);
        TCP_RMV_ACTIVE(pcb);
        pcb.state = TIME_WAIT;
        TCP_REG(&tcp_tw_pcbs, pcb);
      }
      break;
    case LAST_ACK:
      tcp_receive(pcb);
      if ((flags & TCP_ACK) && ackno == pcb.snd_nxt && pcb.unsent is null) {
        LWIP_DEBUGF(TCP_DEBUG, "TCP connection closed: LAST_ACK ", inseg.tcphdr.src, " -> ", inseg.tcphdr.dest, ".\n");
        /* bugfix #21699: don't set pcb->state to CLOSED here or we risk leaking segments */
        recv_flags |= TF_CLOSED;
      }
      break;
    default:
      break;
  }
  return ERR_OK;
}

version (TCP_QUEUE_OOSEQ) {
/**
 * Insert segment into the list (segments covered with new one will be deleted)
 *
 * Called from tcp_receive()
 */
private void
tcp_oos_insert_segment(tcp_seg* cseg, tcp_seg* next)
{
  tcp_seg* old_seg;

  assert(cseg !is null, "tcp_oos_insert_segment: invalid cseg");

  if (TCPH_FLAGS(cseg.tcphdr) & TCP_FIN) {
    /* received segment overlaps all following segments */
    tcp_segs_free(next);
    next = null;
  } else {
    /* delete some following segments
       oos queue may have segments with FIN flag */
    while (next &&
           TCP_SEQ_GEQ((seqno + cseg.len),
                       (next.tcphdr.seqno + next.len))) {
      /* cseg with FIN already processed */
      if (TCPH_FLAGS(next.tcphdr) & TCP_FIN) {
        TCPH_SET_FLAG(cseg.tcphdr, TCP_FIN);
      }
      old_seg = next;
      next = next.next;
      tcp_seg_free(old_seg);
    }
    if (next &&
        TCP_SEQ_GT(seqno + cseg.len, next.tcphdr.seqno)) {
      /* We need to trim the incoming segment. */
      cseg.len = cast(ushort)(next.tcphdr.seqno - seqno);
      pbuf_realloc(cseg.p, cseg.len);
    }
  }
  cseg.next = next;
}
} /* TCP_QUEUE_OOSEQ */

/** Remove segments from a list if the incoming ACK acknowledges them */
private tcp_seg*
tcp_free_acked_segments(tcp_pcb* pcb, tcp_seg* seg_list, const(char)* dbg_list_name,
                        tcp_seg* dbg_other_seg_list)
{
  tcp_seg* next;
  ushort clen;

  while (seg_list !is null &&
         TCP_SEQ_LEQ(loadBigEndian(&seg_list.tcphdr.seqno) +
                     TCP_TCPLEN(seg_list), ackno)) {
    LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_receive: removing ",
                                  loadBigEndian(&seg_list.tcphdr.seqno), ":",
                                  loadBigEndian(&seg_list.tcphdr.seqno) + TCP_TCPLEN(seg_list),
                                  " from pcb->", dbg_list_name, "\n");

    next = seg_list;
    seg_list = seg_list.next;

    clen = pbuf_clen(next.p);
    LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_receive: queuelen ", cast(tcpwnd_size_t)pcb.snd_queuelen, " ... ");
    assert(pcb.snd_queuelen >= clen, "pcb->snd_queuelen >= pbuf_clen(next->p)");

    pcb.snd_queuelen = cast(ushort)(pcb.snd_queuelen - clen);
    recv_acked = cast(tcpwnd_size_t)(recv_acked + next.len);
    tcp_seg_free(next);

    LWIP_DEBUGF(TCP_QLEN_DEBUG, cast(tcpwnd_size_t)pcb.snd_queuelen, " (after freeing ", dbg_list_name, ")\n");
    if (pcb.snd_queuelen != 0) {
      assert(seg_list !is null || dbg_other_seg_list !is null, "tcp_receive: valid queue length");
    }
  }
  return seg_list;
}

/**
 * Called by tcp_process. Checks if the given segment is an ACK for outstanding
 * data, and if so frees the memory of the buffered data. Next, it places the
 * segment on any of the receive queues (pcb->recved or pcb->ooseq). If the segment
 * is buffered, the pbuf is referenced by pbuf_ref so that it will not be freed until
 * it has been removed from the buffer.
 *
 * If the incoming segment constitutes an ACK for a segment that was used for RTT
 * estimation, the RTT is estimated here as well.
 *
 * Called from tcp_process().
 */
private void
tcp_receive(tcp_pcb* pcb)
{
  short m;
  uint right_wnd_edge;

  assert(pcb !is null, "tcp_receive: invalid pcb");
  assert(pcb.state >= ESTABLISHED, "tcp_receive: wrong state");

  if (flags & TCP_ACK) {
    right_wnd_edge = pcb.snd_wnd + pcb.snd_wl2;

    /* Update window. */
    if (TCP_SEQ_LT(pcb.snd_wl1, seqno) ||
        (pcb.snd_wl1 == seqno && TCP_SEQ_LT(pcb.snd_wl2, ackno)) ||
        (pcb.snd_wl2 == ackno && cast(uint)SND_WND_SCALE(pcb, tcphdr.wnd) > pcb.snd_wnd)) {
      pcb.snd_wnd = SND_WND_SCALE(pcb, tcphdr.wnd);
      /* keep track of the biggest window announced by the remote host to calculate
         the maximum segment size */
      if (pcb.snd_wnd_max < pcb.snd_wnd) {
        pcb.snd_wnd_max = pcb.snd_wnd;
      }
      pcb.snd_wl1 = seqno;
      pcb.snd_wl2 = ackno;
      LWIP_DEBUGF(TCP_WND_DEBUG, "tcp_receive: window update ", pcb.snd_wnd, "\n");
version (TCP_WND_DEBUG) {
    } else {
      if (pcb.snd_wnd != cast(tcpwnd_size_t)SND_WND_SCALE(pcb, tcphdr.wnd)) {
        LWIP_DEBUGF(TCP_WND_DEBUG,
                    "tcp_receive: no window update lastack ", pcb.lastack, " ackno ", ackno,
                    " wl1 ", pcb.snd_wl1, " seqno ", seqno, " wl2 ", pcb.snd_wl2, "\n");
      }
} /* TCP_WND_DEBUG */
    }

    /* (From Stevens TCP/IP Illustrated Vol II, p970.) Its only a
     * duplicate ack if:
     * 1) It doesn't ACK new data
     * 2) length of received packet is zero (i.e. no payload)
     * 3) the advertised window hasn't changed
     * 4) There is outstanding unacknowledged data (retransmission timer running)
     * 5) The ACK is == biggest ACK sequence number so far seen (snd_una)
     *
     * If it passes all five, should process as a dupack:
     * a) dupacks < 3: do nothing
     * b) dupacks == 3: fast retransmit
     * c) dupacks > 3: increase cwnd
     *
     * If it only passes 1-3, should reset dupack counter (and add to
     * stats, which we don't do in lwIP)
     *
     * If it only passes 1, should reset dupack counter
     *
     */

    /* Clause 1 */
    if (TCP_SEQ_LEQ(ackno, pcb.lastack)) {
      /* Clause 2 */
      if (tcplen == 0) {
        /* Clause 3 */
        if (pcb.snd_wl2 + pcb.snd_wnd == right_wnd_edge) {
          /* Clause 4 */
          if (pcb.rtime >= 0) {
            /* Clause 5 */
            if (pcb.lastack == ackno) {
              if (cast(ubyte)(pcb.dupacks + 1) > pcb.dupacks) {
                ++pcb.dupacks;
              }
              if (pcb.dupacks > 3) {
                /* Inflate the congestion window */
                TCP_WND_INC(pcb.cwnd, pcb.mss);
              }
              if (pcb.dupacks >= 3) {
                /* Do fast retransmit (checked via TF_INFR, not via dupacks count) */
                tcp_rexmit_fast(pcb);
              }
            }
          }
        }
      }
    } else if (TCP_SEQ_BETWEEN(ackno, pcb.lastack + 1, pcb.snd_nxt)) {
      /* We come here when the ACK acknowledges new data. */
      tcpwnd_size_t acked;

      /* Reset the "IN Fast Retransmit" flag, since we are no longer
         in fast retransmit. Also reset the congestion window to the
         slow start threshold. */
      if (pcb.flags & TF_INFR) {
        tcp_clear_flags(pcb, TF_INFR);
        pcb.cwnd = pcb.ssthresh;
        pcb.bytes_acked = 0;
      }

      /* Reset the number of retransmissions. */
      pcb.nrtx = 0;

      /* Reset the retransmission time-out. */
      pcb.rto = cast(short)((pcb.sa >> 3) + pcb.sv);

      /* Record how much data this ACK acks */
      acked = cast(tcpwnd_size_t)(ackno - pcb.lastack);

      /* Reset the fast retransmit variables. */
      pcb.dupacks = 0;
      pcb.lastack = ackno;

      /* Update the congestion control variables (cwnd and
         ssthresh). */
      if (pcb.state >= ESTABLISHED) {
        if (pcb.cwnd < pcb.ssthresh) {
          tcpwnd_size_t increase;
          /* limit to 1 SMSS segment during period following RTO */
          ubyte num_seg = (pcb.flags & TF_RTO) ? 1 : 2;
          /* RFC 3465, section 2.2 Slow Start */
          increase = min(acked, cast(tcpwnd_size_t)(num_seg * pcb.mss));
          TCP_WND_INC(pcb.cwnd, increase);
          LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_receive: slow start cwnd ", pcb.cwnd, "\n");
        } else {
          /* RFC 3465, section 2.1 Congestion Avoidance */
          TCP_WND_INC(pcb.bytes_acked, acked);
          if (pcb.bytes_acked >= pcb.cwnd) {
            pcb.bytes_acked = cast(tcpwnd_size_t)(pcb.bytes_acked - pcb.cwnd);
            TCP_WND_INC(pcb.cwnd, pcb.mss);
          }
          LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_receive: congestion avoidance cwnd ", pcb.cwnd, "\n");
        }
      }
      LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_receive: ACK for ", ackno, ", unacked->seqno ",
                                    pcb.unacked !is null ?
                                    loadBigEndian(&pcb.unacked.tcphdr.seqno) : 0,
                                    ":",
                                    pcb.unacked !is null ?
                                    loadBigEndian(&pcb.unacked.tcphdr.seqno) + TCP_TCPLEN(pcb.unacked) : 0, "\n");

      /* Remove segment from the unacknowledged list if the incoming
         ACK acknowledges them. */
      pcb.unacked = tcp_free_acked_segments(pcb, pcb.unacked, "unacked", pcb.unsent);
      /* We go through the ->unsent list to see if any of the segments
         on the list are acknowledged by the ACK. This may seem
         strange since an "unsent" segment shouldn't be acked. The
         rationale is that lwIP puts all outstanding segments on the
         ->unsent list after a retransmission, so these segments may
         in fact have been sent once. */
      pcb.unsent = tcp_free_acked_segments(pcb, pcb.unsent, "unsent", pcb.unacked);

      /* If there's nothing left to acknowledge, stop the retransmit
         timer, otherwise reset it to start again */
      if (pcb.unacked is null) {
        pcb.rtime = -1;
      } else {
        pcb.rtime = 0;
      }

      pcb.polltmr = 0;

version (TCP_OVERSIZE) {
      if (pcb.unsent is null) {
        pcb.unsent_oversize = 0;
      }
} /* TCP_OVERSIZE */

version (LWIP_IPV6) version (LWIP_ND6_TCP_REACHABILITY_HINTS) {
      if (ip_current_is_v6()) {
        /* Inform neighbor reachability of forward progress. */
        nd6_reachability_hint(ip6_current_src_addr());
      }
} /* LWIP_IPV6 && LWIP_ND6_TCP_REACHABILITY_HINTS*/

      pcb.snd_buf = cast(tcpwnd_size_t)(pcb.snd_buf + recv_acked);
      /* check if this ACK ends our retransmission of in-flight data */
      if (pcb.flags & TF_RTO) {
        /* RTO is done if
            1) both queues are empty or
            2) unacked is empty and unsent head contains data not part of RTO or
            3) unacked head contains data not part of RTO */
        if (pcb.unacked is null) {
          if ((pcb.unsent is null) ||
              (TCP_SEQ_LEQ(pcb.rto_end, loadBigEndian(&pcb.unsent.tcphdr.seqno)))) {
            tcp_clear_flags(pcb, TF_RTO);
          }
        } else if (TCP_SEQ_LEQ(pcb.rto_end, loadBigEndian(&pcb.unacked.tcphdr.seqno))) {
          tcp_clear_flags(pcb, TF_RTO);
        }
      }
      /* End of ACK for new data processing. */
    } else {
      /* Out of sequence ACK, didn't really ack anything */
      tcp_send_empty_ack(pcb);
    }

    LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_receive: pcb->rttest ", pcb.rttest, " rtseq ", pcb.rtseq, " ackno ", ackno, "\n");

    /* RTT estimation calculations. This is done by checking if the
       incoming segment acknowledges the segment we use to take a
       round-trip time measurement. */
    if (pcb.rttest && TCP_SEQ_LT(pcb.rtseq, ackno)) {
      /* diff between this shouldn't exceed 32K since this are tcp timer ticks
         and a round-trip shouldn't be that long... */
      m = cast(short)(tcp_ticks - pcb.rttest);

      LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_receive: experienced rtt ", m, " ticks (", cast(ushort)(m * TCP_SLOW_INTERVAL), " msec).\n");

      /* This is taken directly from VJs original code in his paper */
      m = cast(short)(m - (pcb.sa >> 3));
      pcb.sa = cast(short)(pcb.sa + m);
      if (m < 0) {
        m = cast(short) - m;
      }
      m = cast(short)(m - (pcb.sv >> 2));
      pcb.sv = cast(short)(pcb.sv + m);
      pcb.rto = cast(short)((pcb.sa >> 3) + pcb.sv);

      LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_receive: RTO ", pcb.rto, " (", cast(ushort)(pcb.rto * TCP_SLOW_INTERVAL), " milliseconds)\n");

      pcb.rttest = 0;
    }
  }

  /* If the incoming segment contains data, we must process it
     further unless the pcb already received a FIN.
     (RFC 793, chapter 3.9, "SEGMENT ARRIVES" in states CLOSE-WAIT, CLOSING,
     LAST-ACK and TIME-WAIT: "Ignore the segment text.") */
  if ((tcplen > 0) && (pcb.state < CLOSE_WAIT)) {
    /* This code basically does three things:

    +) If the incoming segment contains data that is the next
    in-sequence data, this data is passed to the application. This
    might involve trimming the first edge of the data. The rcv_nxt
    variable and the advertised window are adjusted.

    +) If the incoming segment has data that is above the next
    sequence number expected (->rcv_nxt), the segment is placed on
    the ->ooseq queue. This is done by finding the appropriate
    place in the ->ooseq queue (which is ordered by sequence
    number) and trim the segment in both ends if needed. An
    immediate ACK is sent to indicate that we received an
    out-of-sequence segment.

    +) Finally, we check if the first segment on the ->ooseq queue
    now is in sequence (i.e., if rcv_nxt >= ooseq->seqno). If
    rcv_nxt > ooseq->seqno, we must trim the first edge of the
    segment on ->ooseq before we adjust rcv_nxt. The data in the
    segments that are now on sequence are chained onto the
    incoming segment so that we only need to call the application
    once.
    */

    /* First, we check if we must trim the first edge. We have to do
       this if the sequence number of the incoming segment is less
       than rcv_nxt, and the sequence number plus the length of the
       segment is larger than rcv_nxt. */
    if (TCP_SEQ_BETWEEN(pcb.rcv_nxt, seqno + 1, seqno + tcplen - 1)) {
      /* Trimming the first edge — see C source for the full explanation. */

      pbuf* p = inseg.p;
      uint off32 = pcb.rcv_nxt - seqno;
      ushort new_tot_len, off;
      assert(inseg.p, "inseg.p != NULL");
      assert(off32 < 0xffff, "insane offset!");
      off = cast(ushort)off32;
      assert(cast(int)inseg.p.tot_len >= off, "pbuf too short!");
      inseg.len -= off;
      new_tot_len = cast(ushort)(inseg.p.tot_len - off);
      while (p.len < off) {
        off -= p.len;
        /* all pbufs up to and including this one have len==0, so tot_len is equal */
        p.tot_len = new_tot_len;
        p.len = 0;
        p = p.next;
      }
      /* cannot fail... */
      pbuf_remove_header(p, off);
      inseg.tcphdr.seqno = seqno = pcb.rcv_nxt;
    } else {
      if (TCP_SEQ_LT(seqno, pcb.rcv_nxt)) {
        /* the whole segment is < rcv_nxt */
        /* must be a duplicate of a packet that has already been correctly handled */

        LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_receive: duplicate seqno ", seqno, "\n");
        tcp_ack_now(pcb);
      }
    }

    /* The sequence number must be within the window (above rcv_nxt
       and below rcv_nxt + rcv_wnd) in order to be further
       processed. */
    if (TCP_SEQ_BETWEEN(seqno, pcb.rcv_nxt,
                        pcb.rcv_nxt + pcb.rcv_wnd - 1)) {
      if (pcb.rcv_nxt == seqno) {
        /* The incoming segment is the next in sequence. We check if
           we have to trim the end of the segment and update rcv_nxt
           and pass the data to the application. */
        tcplen = TCP_TCPLEN(&inseg);

        if (tcplen > pcb.rcv_wnd) {
          LWIP_DEBUGF(TCP_INPUT_DEBUG,
                      "tcp_receive: other end overran receive window seqno ", seqno, " len ", tcplen, " right edge ", pcb.rcv_nxt + pcb.rcv_wnd, "\n");
          if (TCPH_FLAGS(inseg.tcphdr) & TCP_FIN) {
            /* Must remove the FIN from the header as we're trimming
             * that byte of sequence-space from the packet */
            TCPH_FLAGS_SET(inseg.tcphdr, cast(ushort)(TCPH_FLAGS(inseg.tcphdr) & ~cast(uint)TCP_FIN));
          }
          /* Adjust length of segment to fit in the window. */
          TCPWND_CHECK16(pcb.rcv_wnd);
          inseg.len = cast(ushort)pcb.rcv_wnd;
          if (TCPH_FLAGS(inseg.tcphdr) & TCP_SYN) {
            inseg.len -= 1;
          }
          pbuf_realloc(inseg.p, inseg.len);
          tcplen = TCP_TCPLEN(&inseg);
          assert((seqno + tcplen) == (pcb.rcv_nxt + pcb.rcv_wnd),
                      "tcp_receive: segment not trimmed correctly to rcv_wnd");
        }
version (TCP_QUEUE_OOSEQ) {
        /* Received in-sequence data, adjust ooseq data if:
           - FIN has been received or
           - inseq overlaps with ooseq */
        if (pcb.ooseq !is null) {
          if (TCPH_FLAGS(inseg.tcphdr) & TCP_FIN) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG,
                        "tcp_receive: received in-order FIN, binning ooseq queue\n");
            /* Received in-order FIN means anything that was received
             * out of order must now have been received in-order, so
             * bin the ooseq queue */
            while (pcb.ooseq !is null) {
              tcp_seg* old_ooseq = pcb.ooseq;
              pcb.ooseq = pcb.ooseq.next;
              tcp_seg_free(old_ooseq);
            }
          } else {
            tcp_seg* next = pcb.ooseq;
            /* Remove all segments on ooseq that are covered by inseg already.
             * FIN is copied from ooseq to inseg if present. */
            while (next &&
                   TCP_SEQ_GEQ(seqno + tcplen,
                               next.tcphdr.seqno + next.len)) {
              tcp_seg* tmp;
              /* inseg cannot have FIN here (already processed above) */
              if ((TCPH_FLAGS(next.tcphdr) & TCP_FIN) != 0 &&
                  (TCPH_FLAGS(inseg.tcphdr) & TCP_SYN) == 0) {
                TCPH_SET_FLAG(inseg.tcphdr, TCP_FIN);
                tcplen = TCP_TCPLEN(&inseg);
              }
              tmp = next;
              next = next.next;
              tcp_seg_free(tmp);
            }
            /* Now trim right side of inseg if it overlaps with the first
             * segment on ooseq */
            if (next &&
                TCP_SEQ_GT(seqno + tcplen,
                           next.tcphdr.seqno)) {
              /* inseg cannot have FIN here (already processed above) */
              inseg.len = cast(ushort)(next.tcphdr.seqno - seqno);
              if (TCPH_FLAGS(inseg.tcphdr) & TCP_SYN) {
                inseg.len -= 1;
              }
              pbuf_realloc(inseg.p, inseg.len);
              tcplen = TCP_TCPLEN(&inseg);
              assert((seqno + tcplen) == next.tcphdr.seqno,
                          "tcp_receive: segment not trimmed correctly to ooseq queue");
            }
            pcb.ooseq = next;
          }
        }
} /* TCP_QUEUE_OOSEQ */

        pcb.rcv_nxt = seqno + tcplen;

        /* Update the receiver's (our) window. */
        assert(pcb.rcv_wnd >= tcplen, "tcp_receive: tcplen > rcv_wnd");
        pcb.rcv_wnd -= tcplen;

        tcp_update_rcv_ann_wnd(pcb);

        /* If there is data in the segment, we make preparations to
           pass this up to the application. */
        if (inseg.p.tot_len > 0) {
          recv_data = inseg.p;
          /* Since this pbuf now is the responsibility of the
             application, we delete our reference to it so that we won't
             (mistakenly) deallocate it. */
          inseg.p = null;
        }
        if (TCPH_FLAGS(inseg.tcphdr) & TCP_FIN) {
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_receive: received FIN.\n");
          recv_flags |= TF_GOT_FIN;
        }

version (TCP_QUEUE_OOSEQ) {
        /* We now check if we have segments on the ->ooseq queue that
           are now in sequence. */
        while (pcb.ooseq !is null &&
               pcb.ooseq.tcphdr.seqno == pcb.rcv_nxt) {

          tcp_seg* cseg = pcb.ooseq;
          seqno = pcb.ooseq.tcphdr.seqno;

          pcb.rcv_nxt += TCP_TCPLEN(cseg);
          assert(pcb.rcv_wnd >= TCP_TCPLEN(cseg), "tcp_receive: ooseq tcplen > rcv_wnd");
          pcb.rcv_wnd -= TCP_TCPLEN(cseg);

          tcp_update_rcv_ann_wnd(pcb);

          if (cseg.p.tot_len > 0) {
            /* Chain this pbuf onto the pbuf that we will pass to
               the application. */
            if (recv_data) {
              pbuf_cat(recv_data, cseg.p);
            } else {
              recv_data = cseg.p;
            }
            cseg.p = null;
          }
          if (TCPH_FLAGS(cseg.tcphdr) & TCP_FIN) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_receive: dequeued FIN.\n");
            recv_flags |= TF_GOT_FIN;
            if (pcb.state == ESTABLISHED) { /* force passive close or we can move to active close */
              pcb.state = CLOSE_WAIT;
            }
          }

          pcb.ooseq = cseg.next;
          tcp_seg_free(cseg);
        }
version (LWIP_TCP_SACK_OUT) {
        if (pcb.flags & TF_SACK) {
          if (pcb.ooseq !is null) {
            /* Some segments may have been removed from ooseq, let's remove all SACKs that
               describe anything before the new beginning of that list. */
            tcp_remove_sacks_lt(pcb, pcb.ooseq.tcphdr.seqno);
          } else if (LWIP_TCP_SACK_VALID(pcb, 0)) {
            /* ooseq has been cleared. Nothing to SACK */
            memset(pcb.rcv_sacks.ptr, 0, pcb.rcv_sacks.sizeof);
          }
        }
} /* LWIP_TCP_SACK_OUT */
} /* TCP_QUEUE_OOSEQ */


        /* Acknowledge the segment(s). */
        tcp_ack(pcb);

version (LWIP_TCP_SACK_OUT) {
        if (LWIP_TCP_SACK_VALID(pcb, 0)) {
          /* Normally the ACK for the data received could be piggy-backed on a data packet,
             but lwIP currently does not support including SACKs in data packets. So we force
             it to respond with an empty ACK packet (only if there is at least one SACK to be sent).
             NOTE: tcp_send_empty_ack() on success clears the ACK flags (set by tcp_ack()) */
          tcp_send_empty_ack(pcb);
        }
} /* LWIP_TCP_SACK_OUT */

version (LWIP_IPV6) version (LWIP_ND6_TCP_REACHABILITY_HINTS) {
        if (ip_current_is_v6()) {
          /* Inform neighbor reachability of forward progress. */
          nd6_reachability_hint(ip6_current_src_addr());
        }
} /* LWIP_IPV6 && LWIP_ND6_TCP_REACHABILITY_HINTS*/

      } else {
        /* We get here if the incoming segment is out-of-sequence. */

version (TCP_QUEUE_OOSEQ) {
        /* We queue the segment on the ->ooseq queue. */
        if (pcb.ooseq is null) {
          pcb.ooseq = tcp_seg_copy(&inseg);
version (LWIP_TCP_SACK_OUT) {
          if (pcb.flags & TF_SACK) {
            /* All the SACKs should be invalid, so we can simply store the most recent one: */
            pcb.rcv_sacks[0].left = seqno;
            pcb.rcv_sacks[0].right = seqno + inseg.len;
          }
} /* LWIP_TCP_SACK_OUT */
        } else {
          /* If the queue is not empty, we walk through the queue and
             try to find a place where the sequence number of the
             incoming segment is between the sequence numbers of the
             previous and the next segment on the ->ooseq queue. */

version (LWIP_TCP_SACK_OUT) {
          /* This is the left edge of the lowest possible SACK range. */
          uint sackbeg = TCP_SEQ_LT(seqno, pcb.ooseq.tcphdr.seqno) ? seqno : pcb.ooseq.tcphdr.seqno;
} /* LWIP_TCP_SACK_OUT */
          tcp_seg* next2, prev = null;
          for (next2 = pcb.ooseq; next2 !is null; next2 = next2.next) {
            if (seqno == next2.tcphdr.seqno) {
              if (inseg.len > next2.len) {
                tcp_seg* cseg;

                if (next2.next is null) {
                  break;
                }

                /* The incoming segment is larger than the old segment. We replace some segments with the new one. */
                cseg = tcp_seg_copy(&inseg);
                if (cseg !is null) {
                  if (prev !is null) {
                    prev.next = cseg;
                  } else {
                    pcb.ooseq = cseg;
                  }
                  tcp_oos_insert_segment(cseg, next2);
                }
                break;
              } else {
                break;
              }
            } else {
              if (prev is null) {
                if (TCP_SEQ_LT(seqno, next2.tcphdr.seqno)) {
                  tcp_seg* cseg = tcp_seg_copy(&inseg);
                  if (cseg !is null) {
                    pcb.ooseq = cseg;
                    tcp_oos_insert_segment(cseg, next2);
                  }
                  break;
                }
              } else {
                if (TCP_SEQ_BETWEEN(seqno, prev.tcphdr.seqno + 1, next2.tcphdr.seqno - 1)) {
                  tcp_seg* cseg = tcp_seg_copy(&inseg);
                  if (cseg !is null) {
                    if (TCP_SEQ_GT(prev.tcphdr.seqno + prev.len, seqno)) {
                      /* We need to trim the prev segment. */
                      prev.len = cast(ushort)(seqno - prev.tcphdr.seqno);
                      pbuf_realloc(prev.p, prev.len);
                    }
                    prev.next = cseg;
                    tcp_oos_insert_segment(cseg, next2);
                  }
                  break;
                }
              }

version (LWIP_TCP_SACK_OUT) {
              if (prev !is null && prev.tcphdr.seqno + prev.len != next2.tcphdr.seqno) {
                sackbeg = next2.tcphdr.seqno;
              }
} /* LWIP_TCP_SACK_OUT */

              prev = next2;

              /* If the "next" segment is the last segment on the ooseq queue, we add the incoming segment to the end of the list. */
              if (next2.next is null &&
                  TCP_SEQ_GT(seqno, next2.tcphdr.seqno)) {
                if (TCPH_FLAGS(next2.tcphdr) & TCP_FIN) {
                  break;
                }
                next2.next = tcp_seg_copy(&inseg);
                if (next2.next !is null) {
                  if (TCP_SEQ_GT(next2.tcphdr.seqno + next2.len, seqno)) {
                    /* We need to trim the last segment. */
                    next2.len = cast(ushort)(seqno - next2.tcphdr.seqno);
                    pbuf_realloc(next2.p, next2.len);
                  }
                  /* check if the remote side overruns our receive window */
                  if (TCP_SEQ_GT(cast(uint)tcplen + seqno, pcb.rcv_nxt + cast(uint)pcb.rcv_wnd)) {
                    LWIP_DEBUGF(TCP_INPUT_DEBUG,
                                "tcp_receive: other end overran receive window seqno ", seqno, " len ", tcplen, " right edge ", pcb.rcv_nxt + pcb.rcv_wnd, "\n");
                    if (TCPH_FLAGS(next2.next.tcphdr) & TCP_FIN) {
                      TCPH_FLAGS_SET(next2.next.tcphdr, cast(ushort)(TCPH_FLAGS(next2.next.tcphdr) & ~TCP_FIN));
                    }
                    /* Adjust length of segment to fit in the window. */
                    next2.next.len = cast(ushort)(pcb.rcv_nxt + pcb.rcv_wnd - seqno);
                    pbuf_realloc(next2.next.p, next2.next.len);
                    tcplen = TCP_TCPLEN(next2.next);
                    assert((seqno + tcplen) == (pcb.rcv_nxt + pcb.rcv_wnd),
                                "tcp_receive: segment not trimmed correctly to rcv_wnd");
                  }
                }
                break;
              }
            }
          }

version (LWIP_TCP_SACK_OUT) {
          if (pcb.flags & TF_SACK) {
            if (prev is null) {
              next2 = pcb.ooseq;
            } else if (prev.next !is null) {
              next2 = prev.next;
              if (prev.tcphdr.seqno + prev.len != next2.tcphdr.seqno) {
                sackbeg = next2.tcphdr.seqno;
              }
            } else {
              next2 = null;
            }
            if (next2 !is null) {
              uint sackend = next2.tcphdr.seqno;
              for ( ; (next2 !is null) && (sackend == next2.tcphdr.seqno); next2 = next2.next) {
                sackend += next2.len;
              }
              tcp_add_sack(pcb, sackbeg, sackend);
            }
          }
} /* LWIP_TCP_SACK_OUT */
        }
version (TCP_OOSEQ_HAS_LIMIT) {
        {
          /* Check that the data on ooseq doesn't exceed one of the limits and throw away everything above that limit. */
version (TCP_OOSEQ_BYTES_LIMIT) {
          const uint ooseq_max_blen = TCP_OOSEQ_BYTES_LIMIT(pcb);
          uint ooseq_blen = 0;
}
version (TCP_OOSEQ_PBUFS_LIMIT) {
          const ushort ooseq_max_qlen = TCP_OOSEQ_PBUFS_LIMIT(pcb);
          ushort ooseq_qlen = 0;
}
          tcp_seg* next3, prev3 = null;
          for (next3 = pcb.ooseq; next3 !is null; prev3 = next3, next3 = next3.next) {
            pbuf* p = next3.p;
            int stop_here = 0;
version (TCP_OOSEQ_BYTES_LIMIT) {
            ooseq_blen += p.tot_len;
            if (ooseq_blen > ooseq_max_blen) {
              stop_here = 1;
            }
}
version (TCP_OOSEQ_PBUFS_LIMIT) {
            ooseq_qlen += pbuf_clen(p);
            if (ooseq_qlen > ooseq_max_qlen) {
              stop_here = 1;
            }
}
            if (stop_here) {
version (LWIP_TCP_SACK_OUT) {
              if (pcb.flags & TF_SACK) {
                tcp_remove_sacks_gt(pcb, next3.tcphdr.seqno);
              }
} /* LWIP_TCP_SACK_OUT */
              tcp_segs_free(next3);
              if (prev3 is null) {
                pcb.ooseq = null;
              } else {
                prev3.next = null;
              }
              break;
            }
          }
        }
} /* TCP_OOSEQ_BYTES_LIMIT || TCP_OOSEQ_PBUFS_LIMIT */
} /* TCP_QUEUE_OOSEQ */

        /* We send the ACK packet after we've (potentially) dealt with SACKs,
           so they can be included in the acknowledgment. */
        tcp_send_empty_ack(pcb);
      }
    } else {
      /* The incoming segment is not within the window. */
      tcp_send_empty_ack(pcb);
    }
  } else {
    /* Segments with length 0 is taken care of here. Segments that
       fall out of the window are ACKed. */
    if (!TCP_SEQ_BETWEEN(seqno, pcb.rcv_nxt, pcb.rcv_nxt + pcb.rcv_wnd - 1)) {
      tcp_ack_now(pcb);
    }
  }
}

private ubyte
tcp_get_next_optbyte()
{
  ushort optidx = tcp_optidx++;
  if ((tcphdr_opt2 is null) || (optidx < tcphdr_opt1len)) {
    ubyte* opts = cast(ubyte*)tcphdr + TCP_HLEN;
    return opts[optidx];
  } else {
    ubyte idx = cast(ubyte)(optidx - tcphdr_opt1len);
    return tcphdr_opt2[idx];
  }
}

/**
 * Parses the options contained in the incoming segment.
 *
 * Called from tcp_listen_input() and tcp_process().
 * Currently, only the MSS option is supported!
 *
 * @param pcb the tcp_pcb for which a segment arrived
 */
private void
tcp_parseopt(tcp_pcb* pcb)
{
  ubyte data;
  ushort mss;
version (LWIP_TCP_TIMESTAMPS) {
  uint tsval;
}

  assert(pcb !is null, "tcp_parseopt: invalid pcb");

  /* Parse the TCP MSS option, if present. */
  if (tcphdr_optlen != 0) {
    for (tcp_optidx = 0; tcp_optidx < tcphdr_optlen; ) {
      ubyte opt = tcp_get_next_optbyte();
      switch (opt) {
        case LWIP_TCP_OPT_EOL:
          /* End of options. */
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: EOL\n");
          return;
        case LWIP_TCP_OPT_NOP:
          /* NOP option. */
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: NOP\n");
          break;
        case LWIP_TCP_OPT_MSS:
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: MSS\n");
          if (tcp_get_next_optbyte() != LWIP_TCP_OPT_LEN_MSS || (tcp_optidx - 2 + LWIP_TCP_OPT_LEN_MSS) > tcphdr_optlen) {
            /* Bad length */
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: bad length\n");
            return;
          }
          /* An MSS option with the right option length. */
          mss = cast(ushort)(tcp_get_next_optbyte() << 8);
          mss |= tcp_get_next_optbyte();
          /* Limit the mss to the configured TCP_MSS and prevent division by zero */
          pcb.mss = ((mss > TCP_MSS) || (mss == 0)) ? TCP_MSS : mss;
          break;
version (LWIP_WND_SCALE) {
        case LWIP_TCP_OPT_WS:
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: WND_SCALE\n");
          if (tcp_get_next_optbyte() != LWIP_TCP_OPT_LEN_WS || (tcp_optidx - 2 + LWIP_TCP_OPT_LEN_WS) > tcphdr_optlen) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: bad length\n");
            return;
          }
          data = tcp_get_next_optbyte();
          if ((flags & TCP_SYN) && !(pcb.flags & TF_WND_SCALE)) {
            pcb.snd_scale = data;
            if (pcb.snd_scale > 14U) {
              pcb.snd_scale = 14U;
            }
            pcb.rcv_scale = TCP_RCV_SCALE;
            tcp_set_flags(pcb, TF_WND_SCALE);
            assert(pcb.rcv_wnd == TCPWND_MIN16(TCP_WND), "window not at default value");
            assert(pcb.rcv_ann_wnd == TCPWND_MIN16(TCP_WND), "window not at default value");
            pcb.rcv_wnd = pcb.rcv_ann_wnd = TCP_WND;
          }
          break;
} /* LWIP_WND_SCALE */
version (LWIP_TCP_TIMESTAMPS) {
        case LWIP_TCP_OPT_TS:
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: TS\n");
          if (tcp_get_next_optbyte() != LWIP_TCP_OPT_LEN_TS || (tcp_optidx - 2 + LWIP_TCP_OPT_LEN_TS) > tcphdr_optlen) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: bad length\n");
            return;
          }
          tsval = (tcp_get_next_optbyte() << 24);
          tsval |= (tcp_get_next_optbyte() << 16);
          tsval |= (tcp_get_next_optbyte() << 8);
          tsval |= tcp_get_next_optbyte();
          if (flags & TCP_SYN) {
            pcb.ts_recent = tsval;
            tcp_set_flags(pcb, TF_TIMESTAMP);
          } else if (TCP_SEQ_BETWEEN(pcb.ts_lastacksent, seqno, seqno + tcplen)) {
            pcb.ts_recent = tsval;
          }
          tcp_optidx += LWIP_TCP_OPT_LEN_TS - 6;
          break;
} /* LWIP_TCP_TIMESTAMPS */
version (LWIP_TCP_SACK_OUT) {
        case LWIP_TCP_OPT_SACK_PERM:
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: SACK_PERM\n");
          if (tcp_get_next_optbyte() != LWIP_TCP_OPT_LEN_SACK_PERM || (tcp_optidx - 2 + LWIP_TCP_OPT_LEN_SACK_PERM) > tcphdr_optlen) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: bad length\n");
            return;
          }
          if (flags & TCP_SYN) {
            tcp_set_flags(pcb, TF_SACK);
          }
          break;
} /* LWIP_TCP_SACK_OUT */
        default:
          LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: other\n");
          data = tcp_get_next_optbyte();
          if (data < 2) {
            LWIP_DEBUGF(TCP_INPUT_DEBUG, "tcp_parseopt: bad length\n");
            return;
          }
          tcp_optidx += data - 2;
      }
    }
  }
}

void
tcp_trigger_input_pcb_close()
{
  recv_flags |= TF_CLOSED;
}

version (LWIP_TCP_SACK_OUT) {
/**
 * Called by tcp_receive() to add new SACK entry.
 *
 * The new SACK entry will be placed at the beginning of rcv_sacks[], as the newest one.
 * Existing SACK entries will be "pushed back", to preserve their order.
 * This is the behavior described in RFC 2018, section 4.
 *
 * @param pcb the tcp_pcb for which a segment arrived
 * @param left the left side of the SACK (the first sequence number)
 * @param right the right side of the SACK (the first sequence number past this SACK)
 */
private void
tcp_add_sack(tcp_pcb* pcb, uint left, uint right)
{
  ubyte i;
  ubyte unused_idx;

  if ((pcb.flags & TF_SACK) == 0 || !TCP_SEQ_LT(left, right)) {
    return;
  }

  for (i = unused_idx = 0; (i < LWIP_TCP_MAX_SACK_NUM) && LWIP_TCP_SACK_VALID(pcb, i); ++i) {
    if (TCP_SEQ_LEQ(pcb.rcv_sacks[i].right, left) || TCP_SEQ_LEQ(right, pcb.rcv_sacks[i].left)) {
      if (unused_idx != i) {
        pcb.rcv_sacks[unused_idx] = pcb.rcv_sacks[i];
      }
      ++unused_idx;
    }
  }

  for (i = LWIP_TCP_MAX_SACK_NUM - 1; i > 0; --i) {
    if (i - 1 >= unused_idx) {
      pcb.rcv_sacks[i].left = pcb.rcv_sacks[i].right = 0;
    } else {
      pcb.rcv_sacks[i] = pcb.rcv_sacks[i - 1];
    }
  }

  pcb.rcv_sacks[0].left = left;
  pcb.rcv_sacks[0].right = right;
}

/**
 * Called to remove a range of SACKs.
 */
private void
tcp_remove_sacks_lt(tcp_pcb* pcb, uint seq)
{
  ubyte i;
  ubyte unused_idx;

  for (i = unused_idx = 0; (i < LWIP_TCP_MAX_SACK_NUM) && LWIP_TCP_SACK_VALID(pcb, i); ++i) {
    if (TCP_SEQ_GT(pcb.rcv_sacks[i].right, seq)) {
      if (unused_idx != i) {
        pcb.rcv_sacks[unused_idx] = pcb.rcv_sacks[i];
      }
      if (TCP_SEQ_LT(pcb.rcv_sacks[unused_idx].left, seq)) {
        pcb.rcv_sacks[unused_idx].left = seq;
      }
      ++unused_idx;
    }
  }

  for (i = unused_idx; i < LWIP_TCP_MAX_SACK_NUM; ++i) {
    pcb.rcv_sacks[i].left = pcb.rcv_sacks[i].right = 0;
  }
}

version (TCP_OOSEQ_HAS_LIMIT) {
/**
 * Called to remove a range of SACKs.
 */
private void
tcp_remove_sacks_gt(tcp_pcb* pcb, uint seq)
{
  ubyte i;
  ubyte unused_idx;

  for (i = unused_idx = 0; (i < LWIP_TCP_MAX_SACK_NUM) && LWIP_TCP_SACK_VALID(pcb, i); ++i) {
    if (TCP_SEQ_LT(pcb.rcv_sacks[i].left, seq)) {
      if (unused_idx != i) {
        pcb.rcv_sacks[unused_idx] = pcb.rcv_sacks[i];
      }
      if (TCP_SEQ_GT(pcb.rcv_sacks[unused_idx].right, seq)) {
        pcb.rcv_sacks[unused_idx].right = seq;
      }
      ++unused_idx;
    }
  }

  for (i = unused_idx; i < LWIP_TCP_MAX_SACK_NUM; ++i) {
    pcb.rcv_sacks[i].left = pcb.rcv_sacks[i].right = 0;
  }
}
} /* TCP_OOSEQ_BYTES_LIMIT || TCP_OOSEQ_PBUFS_LIMIT */

} /* LWIP_TCP_SACK_OUT */

} /* LWIP_TCP */
