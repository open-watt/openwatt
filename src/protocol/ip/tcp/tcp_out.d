/**
 * @file
 * Transmission Control Protocol, outgoing traffic
 *
 * The output functions of TCP.
 *
 * There are two distinct ways for TCP segments to get sent:
 * - queued data: these are segments transferring data or segments containing
 *   SYN or FIN (which both count as one sequence number). They are created as
 *   struct @ref pbuf together with a struct tcp_seg and enqueue to the
 *   unsent list of the pcb. They are sent by tcp_output:
 *   - @ref tcp_write : creates data segments
 *   - @ref tcp_split_unsent_seg : splits a data segment
 *   - @ref tcp_enqueue_flags : creates SYN-only or FIN-only segments
 *   - @ref tcp_output / tcp_output_segment : finalize the tcp header
 *      (e.g. sequence numbers, options, checksum) and output to IP
 *   - the various tcp_rexmit functions shuffle around segments between the
 *     unsent an unacked lists to retransmit them
 *   - tcp_create_segment and tcp_pbuf_prealloc allocate pbuf and
 *     segment for these functions
 * - direct send: these segments don't contain data but control the connection
 *   behaviour. They are created as pbuf only and sent directly without
 *   enqueueing them:
 *   - @ref tcp_send_empty_ack sends an ACK-only segment
 *   - @ref tcp_rst sends a RST segment
 *   - @ref tcp_keepalive sends a keepalive segment
 *   - @ref tcp_zero_window_probe sends a window probe segment
 *   - tcp_output_alloc_header allocates a header-only pbuf for these functions
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
module protocol.ip.tcp.tcp_out;

version (UseInternalIPStack):

/* File-local versions — flip the commented one to enable per-output debug
   traces. CHECKSUM_GEN_TCP stays in the build flags because it's a source in
   composite derivations across multiple files. */
//version = TCP_CWND_DEBUG;

/* Composite version derivations (file-local — see tcp.d for explanation). */
version (TCP_OVERSIZE) version (LWIP_DEBUG)           version = TCP_OVERSIZE_DBGCHECK;
version (LWIP_CHECKSUM_ON_COPY) version (CHECKSUM_GEN_TCP) version = TCP_CHECKSUM_ON_COPY;

import protocol.ip.tcp.opt;

version (LWIP_TCP) { /* don't build if not configured for use in lwipopts.h */

import protocol.ip.tcp;
import protocol.ip.tcp.tcpbase;
import protocol.ip.tcp.tcp_priv;
import protocol.ip.tcp.pbuf;
import protocol.ip.tcp.prot_tcp;
import protocol.ip.tcp.ip;
version (LWIP_TCP_TIMESTAMPS) {
import urt.time : getTime;
}

import urt.endian : loadBigEndian, storeBigEndian;
import urt.hash : internet_checksum;
import urt.mem : memcpy;
import urt.mem.allocator : defaultAllocator;
import urt.util : min, max, byte_reverse;

nothrow @nogc:

/* Define some copy-macros for checksum-on-copy so that the code looks nicer. */
version (TCP_CHECKSUM_ON_COPY) {
void TCP_DATA_COPY(void* dst, const(void)* src, size_t len, tcp_seg* seg) {
    tcp_seg_add_chksum(ip_chksum_copy(dst, src, len), cast(ushort)len, &seg.chksum, &seg.chksum_swapped);
    seg.flags |= TF_SEG_DATA_CHECKSUMMED;
}
void TCP_DATA_COPY2(void* dst, const(void)* src, size_t len, ushort* chksum, ubyte* chksum_swapped) {
    tcp_seg_add_chksum(ip_chksum_copy(dst, src, len), cast(ushort)len, chksum, chksum_swapped);
}
} else { /* TCP_CHECKSUM_ON_COPY */
void TCP_DATA_COPY(void* dst, const(void)* src, size_t len, tcp_seg* seg) { memcpy(dst, src, len); }
void TCP_DATA_COPY2(void* dst, const(void)* src, size_t len, ushort* chksum, ubyte* chksum_swapped) { memcpy(dst, src, len); }
} /* TCP_CHECKSUM_ON_COPY */

version (TCP_OVERSIZE) {
ushort TCP_OVERSIZE_CALC_LENGTH(ushort length) pure => cast(ushort)(length + TCP_OVERSIZE);
}

/* Forward declarations. */
private err_t tcp_output_segment(tcp_seg* seg, tcp_pcb* pcb, netif nif);
private err_t tcp_output_control_segment_netif(const(tcp_pcb)* pcb, pbuf* p,
                                              const(ip_addr_t)* src, const(ip_addr_t)* dst,
                                              netif nif);

/* tcp_route: common code that returns a fixed bound netif or calls ip_route */
private netif
tcp_route(const(tcp_pcb)* pcb, const(ip_addr_t)* src, const(ip_addr_t)* dst)
{
  if ((pcb !is null) && (pcb.netif_idx != NETIF_NO_INDEX)) {
    return netif_get_by_index(pcb.netif_idx);
  } else {
    return ip_route(src, dst);
  }
}

/**
 * Create a TCP segment with prefilled header.
 *
 * @param pcb Protocol control block for the TCP connection.
 * @param p pbuf that is used to hold the TCP header.
 * @param hdrflags TCP flags for header.
 * @param seqno TCP sequence number of this packet
 * @param optflags options to include in TCP header
 * @return a new tcp_seg pointing to p, or NULL.
 */
private tcp_seg*
tcp_create_segment(const(tcp_pcb)* pcb, pbuf* p, ubyte hdrflags, uint seqno, ubyte optflags)
{
  tcp_seg* seg;
  ubyte optlen;

  assert(pcb !is null, "tcp_create_segment: invalid pcb");
  assert(p !is null, "tcp_create_segment: invalid pbuf");

  optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(optflags);

  if ((seg = cast(tcp_seg*)defaultAllocator.alloc(tcp_seg.sizeof).ptr) is null) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_create_segment: no memory.\n");
    pbuf_free(p);
    return null;
  }
  seg.flags = optflags;
  seg.next = null;
  seg.p = p;
  assert(p.tot_len >= optlen, "p->tot_len >= optlen");
  seg.len = cast(ushort)(p.tot_len - optlen);
version (TCP_OVERSIZE_DBGCHECK) {
  seg.oversize_left = 0;
} /* TCP_OVERSIZE_DBGCHECK */
version (TCP_CHECKSUM_ON_COPY) {
  seg.chksum = 0;
  seg.chksum_swapped = 0;
  assert((optflags & TF_SEG_DATA_CHECKSUMMED) == 0,
              "invalid optflags passed: TF_SEG_DATA_CHECKSUMMED");
} /* TCP_CHECKSUM_ON_COPY */

  /* build TCP header */
  if (pbuf_add_header(p, TCP_HLEN)) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_create_segment: no room for TCP header in pbuf.\n");
    tcp_seg_free(seg);
    return null;
  }
  seg.tcphdr = cast(tcp_hdr*)seg.p.payload;
  storeBigEndian(&seg.tcphdr.src, pcb.local_port);
  storeBigEndian(&seg.tcphdr.dest, pcb.remote_port);
  storeBigEndian(&seg.tcphdr.seqno, seqno);
  /* ackno is set in tcp_output */
  TCPH_HDRLEN_FLAGS_SET(seg.tcphdr, (5 + optlen / 4), hdrflags);
  /* wnd and chksum are set in tcp_output */
  seg.tcphdr.urgp = 0;
  return seg;
}

/**
 * Allocate a PBUF_RAM pbuf, perhaps with extra space at the end.
 */
version (TCP_OVERSIZE) {
private pbuf*
tcp_pbuf_prealloc(pbuf_layer layer, ushort length, ushort max_length,
                  ushort* oversize, const(tcp_pcb)* pcb, ubyte apiflags,
                  ubyte first_seg)
{
  pbuf* p;
  ushort alloc = length;

  assert(oversize !is null, "tcp_pbuf_prealloc: invalid oversize");
  assert(pcb !is null, "tcp_pbuf_prealloc: invalid pcb");

version (LWIP_NETIF_TX_SINGLE_PBUF) {
  alloc = max_length;
} else { /* LWIP_NETIF_TX_SINGLE_PBUF */
  if (length < max_length) {
    if ((apiflags & TCP_WRITE_FLAG_MORE) ||
        (!(pcb.flags & TF_NODELAY) &&
         (!first_seg ||
          pcb.unsent !is null ||
          pcb.unacked !is null))) {
      alloc = cast(ushort)min(max_length, ((TCP_OVERSIZE_CALC_LENGTH(length + 3) & ~3)));
    }
  }
} /* LWIP_NETIF_TX_SINGLE_PBUF */
  p = pbuf_alloc(layer, alloc, PBUF_RAM);
  if (p is null) {
    return null;
  }
  assert(p.next is null, "need unchained pbuf");
  *oversize = cast(ushort)(p.len - length);
  /* trim p->len to the currently used size */
  p.len = p.tot_len = length;
  return p;
}
} else { /* TCP_OVERSIZE */
pbuf* tcp_pbuf_prealloc(pbuf_layer layer, ushort length, ushort mx, ushort* os, const(tcp_pcb)* pcb, ubyte api, ubyte fst) {
    return pbuf_alloc(layer, length, PBUF_RAM);
}
} /* TCP_OVERSIZE */

version (TCP_CHECKSUM_ON_COPY) {
/** Add a checksum of newly added data to the segment. */
private void
tcp_seg_add_chksum(ushort chksum, ushort len, ushort* seg_chksum,
                   ubyte* seg_chksum_swapped)
{
  uint helper;
  helper = chksum + *seg_chksum;
  chksum = ((helper >> 16) + (helper & 0xFFFF));
  if ((len & 1) != 0) {
    *seg_chksum_swapped = cast(ubyte)(1 - *seg_chksum_swapped);
    chksum = byte_reverse(chksum);
  }
  *seg_chksum = chksum;
}
} /* TCP_CHECKSUM_ON_COPY */

/** Checks if tcp_write is allowed or not. */
private err_t
tcp_write_checks(tcp_pcb* pcb, ushort len)
{
  assert(pcb !is null, "tcp_write_checks: invalid pcb");

  if ((pcb.state != ESTABLISHED) &&
      (pcb.state != CLOSE_WAIT) &&
      (pcb.state != SYN_SENT) &&
      (pcb.state != SYN_RCVD)) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_STATE | LWIP_DBG_LEVEL_SEVERE, "tcp_write() called in invalid state\n");
    return ERR_CONN;
  } else if (len == 0) {
    return ERR_OK;
  }

  /* fail on too much data */
  if (len > pcb.snd_buf) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SEVERE, "tcp_write: too much data (len=", len, " > snd_buf=", pcb.snd_buf, ")\n");
    tcp_set_flags(pcb, TF_NAGLEMEMERR);
    return ERR_MEM;
  }

  LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_write: queuelen: ", cast(tcpwnd_size_t)pcb.snd_queuelen, "\n");

  if (pcb.snd_queuelen >= min(TCP_SND_QUEUELEN, (TCP_SNDQUEUELEN_OVERFLOW + 1))) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SEVERE, "tcp_write: too long queue ", pcb.snd_queuelen, " (max ", cast(ushort)TCP_SND_QUEUELEN, ")\n");
    tcp_set_flags(pcb, TF_NAGLEMEMERR);
    return ERR_MEM;
  }
  if (pcb.snd_queuelen != 0) {
    assert(pcb.unacked !is null || pcb.unsent !is null,
                "tcp_write: pbufs on queue => at least one queue non-empty");
  } else {
    assert(pcb.unacked is null && pcb.unsent is null,
                "tcp_write: no pbufs on queue => both queues empty");
  }
  return ERR_OK;
}

/**
 * @ingroup tcp_raw
 * Write data for sending (but does not send it immediately).
 */
err_t
tcp_write(tcp_pcb* pcb, const(void)* arg, ushort len, ubyte apiflags)
{
  pbuf* concat_p = null;
  tcp_seg* last_unsent = null, seg = null, prev_seg = null, queue = null;
  ushort pos = 0;
  ushort queuelen;
  ubyte optlen;
  ubyte optflags = 0;
  /* These were conditionally declared in lwIP (TCP_OVERSIZE/TCP_CHECKSUM_ON_COPY)
     but call sites reference them unconditionally; in D we declare them at
     function scope and the disabled paths just leave them at zero. */
  ushort oversize = 0;
  ushort oversize_used = 0;
  ushort oversize_add = 0;
  ushort extendlen = 0;
  ushort concat_chksum = 0;
  ubyte concat_chksum_swapped = 0;
  ushort concat_chksummed = 0;
  err_t err;
  ushort mss_local;

  if (pcb is null) return ERR_ARG; /* LWIP_ERROR("tcp_write: invalid pcb", ...) */

  mss_local = cast(ushort)min(pcb.mss, TCPWND_MIN16(pcb.snd_wnd_max / 2));
  mss_local = mss_local ? mss_local : pcb.mss;

version (LWIP_NETIF_TX_SINGLE_PBUF) {
  apiflags |= TCP_WRITE_FLAG_COPY;
}

  LWIP_DEBUGF(TCP_OUTPUT_DEBUG, "tcp_write(pcb=", pcb, ", data=", arg, ", len=", len, ", apiflags=", cast(ushort)apiflags, ")\n");
  if (arg is null) return ERR_ARG; /* LWIP_ERROR("tcp_write: arg == NULL", ...) */

  err = tcp_write_checks(pcb, len);
  if (err != ERR_OK) {
    return err;
  }
  queuelen = pcb.snd_queuelen;

  bool _need_default_optlen = true;
version (LWIP_TCP_TIMESTAMPS) {
  if ((pcb.flags & TF_TIMESTAMP)) {
    optflags = TF_SEG_OPTS_TS;
    optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(TF_SEG_OPTS_TS);
    mss_local = cast(ushort)max(mss_local, LWIP_TCP_OPT_LEN_TS + 1);
    _need_default_optlen = false;
  }
}
  if (_need_default_optlen) {
    optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(0);
  }

  /* Find the tail of the unsent queue. */
  if (pcb.unsent !is null) {
    ushort space;
    ushort unsent_optlen;

    for (last_unsent = pcb.unsent; last_unsent.next !is null;
         last_unsent = last_unsent.next) {}

    unsent_optlen = cast(ushort)LWIP_TCP_OPT_LENGTH(last_unsent.flags);
    assert(mss_local >= last_unsent.len + unsent_optlen, "mss_local is too small");
    space = cast(ushort)(mss_local - (last_unsent.len + unsent_optlen));

    /*
     * Phase 1: Copy data directly into an oversized pbuf.
     */
version (TCP_OVERSIZE) {
version (TCP_OVERSIZE_DBGCHECK) {
    assert(pcb.unsent_oversize == last_unsent.oversize_left,
                "unsent_oversize mismatch (pcb vs. last_unsent)");
} /* TCP_OVERSIZE_DBGCHECK */
    oversize = pcb.unsent_oversize;
    if (oversize > 0) {
      assert(oversize <= space, "inconsistent oversize vs. space");
      seg = last_unsent;
      oversize_used = cast(ushort)min(space, min(oversize, len));
      pos += oversize_used;
      oversize -= oversize_used;
      space -= oversize_used;
    }
    assert((oversize == 0) || (pos == len), "inconsistent oversize vs. len");
} /* TCP_OVERSIZE */

version (LWIP_NETIF_TX_SINGLE_PBUF) {} else {
    /*
     * Phase 2: Chain a new pbuf to the end of pcb->unsent.
     */
    if ((pos < len) && (space > 0) && (last_unsent.len > 0)) {
      ushort seglen = cast(ushort)min(space, len - pos);
      seg = last_unsent;

      if (apiflags & TCP_WRITE_FLAG_COPY) {
        if ((concat_p = tcp_pbuf_prealloc(PBUF_RAW, seglen, space, &oversize, pcb, apiflags, 1)) is null) {
          LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                      "tcp_write : could not allocate memory for pbuf copy size ", seglen, "\n");
          goto memerr;
        }
version (TCP_OVERSIZE_DBGCHECK) {
        oversize_add = oversize;
} /* TCP_OVERSIZE_DBGCHECK */
        TCP_DATA_COPY2(concat_p.payload, cast(const(ubyte)*)arg + pos, seglen, &concat_chksum, &concat_chksum_swapped);
version (TCP_CHECKSUM_ON_COPY) {
        concat_chksummed += seglen;
} /* TCP_CHECKSUM_ON_COPY */
        queuelen += pbuf_clen(concat_p);
      } else {
        pbuf* p;
        for (p = last_unsent.p; p.next !is null; p = p.next) {}
        if (((p.type_internal & (PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS | PBUF_TYPE_FLAG_DATA_VOLATILE)) == 0) &&
            cast(const(ubyte)*)p.payload + p.len == cast(const(ubyte)*)arg) {
          assert(pos == 0, "tcp_write: ROM pbufs cannot be oversized");
          extendlen = seglen;
        } else {
          if ((concat_p = pbuf_alloc(PBUF_RAW, seglen, PBUF_ROM)) is null) {
            LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                        "tcp_write: could not allocate memory for zero-copy pbuf\n");
            goto memerr;
          }
          (cast(pbuf_rom*)concat_p).payload = cast(void*)(cast(const(ubyte)*)arg + pos);
          queuelen += pbuf_clen(concat_p);
        }
version (TCP_CHECKSUM_ON_COPY) {
        tcp_seg_add_chksum(cast(ushort)~internet_checksum((cast(const(ubyte)*)arg + pos)[0 .. seglen]), seglen,
                           &concat_chksum, &concat_chksum_swapped);
        concat_chksummed += seglen;
} /* TCP_CHECKSUM_ON_COPY */
      }

      pos += seglen;
    }
} /* !LWIP_NETIF_TX_SINGLE_PBUF */
  } else {
version (TCP_OVERSIZE) {
    assert(pcb.unsent_oversize == 0,
                "unsent_oversize mismatch (pcb->unsent is NULL)");
} /* TCP_OVERSIZE */
  }

  /*
   * Phase 3: Create new segments.
   */
  while (pos < len) {
    pbuf* p;
    ushort left = cast(ushort)(len - pos);
    ushort max_len = cast(ushort)(mss_local - optlen);
    ushort seglen = cast(ushort)min(left, max_len);
    /* Were inside `version (TCP_CHECKSUM_ON_COPY)` in lwIP; unconditional here
       because TCP_DATA_COPY2 takes their addresses regardless of the version. */
    ushort chksum = 0;
    ubyte chksum_swapped = 0;

    if (apiflags & TCP_WRITE_FLAG_COPY) {
      if ((p = tcp_pbuf_prealloc(PBUF_TRANSPORT, cast(ushort)(seglen + optlen), mss_local, &oversize, pcb, apiflags, queue is null)) is null) {
        LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_write : could not allocate memory for pbuf copy size ", seglen, "\n");
        goto memerr;
      }
      assert(p.len >= seglen, "tcp_write: check that first pbuf can hold the complete seglen");
      TCP_DATA_COPY2(cast(char*)p.payload + optlen, cast(const(ubyte)*)arg + pos, seglen, &chksum, &chksum_swapped);
    } else {
      pbuf* p2;
version (TCP_OVERSIZE) {
      assert(oversize == 0, "oversize == 0");
} /* TCP_OVERSIZE */
      if ((p2 = pbuf_alloc(PBUF_TRANSPORT, seglen, PBUF_ROM)) is null) {
        LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_write: could not allocate memory for zero-copy pbuf\n");
        goto memerr;
      }
version (TCP_CHECKSUM_ON_COPY) {
      chksum = cast(ushort)~internet_checksum((cast(const(ubyte)*)arg + pos)[0 .. seglen]);
      if (seglen & 1) {
        chksum_swapped = 1;
        chksum = byte_reverse(chksum);
      }
} /* TCP_CHECKSUM_ON_COPY */
      (cast(pbuf_rom*)p2).payload = cast(void*)(cast(const(ubyte)*)arg + pos);

      if ((p = pbuf_alloc(PBUF_TRANSPORT, optlen, PBUF_RAM)) is null) {
        pbuf_free(p2);
        LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_write: could not allocate memory for header pbuf\n");
        goto memerr;
      }
      pbuf_cat(p/*header*/, p2/*data*/);
    }

    queuelen += pbuf_clen(p);

    if (queuelen > min(TCP_SND_QUEUELEN, TCP_SNDQUEUELEN_OVERFLOW)) {
      LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_write: queue too long ", queuelen, " (", cast(int)TCP_SND_QUEUELEN, ")\n");
      pbuf_free(p);
      goto memerr;
    }

    if ((seg = tcp_create_segment(pcb, p, 0, pcb.snd_lbb + pos, optflags)) is null) {
      goto memerr;
    }
version (TCP_OVERSIZE_DBGCHECK) {
    seg.oversize_left = oversize;
} /* TCP_OVERSIZE_DBGCHECK */
version (TCP_CHECKSUM_ON_COPY) {
    seg.chksum = chksum;
    seg.chksum_swapped = chksum_swapped;
    seg.flags |= TF_SEG_DATA_CHECKSUMMED;
} /* TCP_CHECKSUM_ON_COPY */

    if (queue is null) {
      queue = seg;
    } else {
      assert(prev_seg !is null, "prev_seg != NULL");
      prev_seg.next = seg;
    }
    prev_seg = seg;

    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_TRACE, "tcp_write: queueing ",
                loadBigEndian(&seg.tcphdr.seqno), ":",
                loadBigEndian(&seg.tcphdr.seqno) + TCP_TCPLEN(seg), "\n");

    pos += seglen;
  }

  /* All three segmentation phases were successful. We can commit the transaction. */
version (TCP_OVERSIZE_DBGCHECK) {
  if ((last_unsent !is null) && (oversize_add != 0)) {
    last_unsent.oversize_left += oversize_add;
  }
} /* TCP_OVERSIZE_DBGCHECK */

  /* Phase 1: If data has been added to the preallocated tail of last_unsent, we update the length fields of the pbuf chain. */
version (TCP_OVERSIZE) {
  if (oversize_used > 0) {
    pbuf* p;
    for (p = last_unsent.p; p; p = p.next) {
      p.tot_len += oversize_used;
      if (p.next is null) {
        TCP_DATA_COPY(cast(char*)p.payload + p.len, arg, oversize_used, last_unsent);
        p.len += oversize_used;
      }
    }
    last_unsent.len += oversize_used;
version (TCP_OVERSIZE_DBGCHECK) {
    assert(last_unsent.oversize_left >= oversize_used,
                "last_unsent->oversize_left >= oversize_used");
    last_unsent.oversize_left -= oversize_used;
} /* TCP_OVERSIZE_DBGCHECK */
  }
  pcb.unsent_oversize = oversize;
} /* TCP_OVERSIZE */

  /* Phase 2: concat_p can be concatenated onto last_unsent->p. */
  if (concat_p !is null) {
    assert(last_unsent !is null,
                "tcp_write: cannot concatenate when pcb->unsent is empty");
    pbuf_cat(last_unsent.p, concat_p);
    last_unsent.len += concat_p.tot_len;
  } else if (extendlen > 0) {
    pbuf* p;
    assert(last_unsent !is null && last_unsent.p !is null,
                "tcp_write: extension of reference requires reference");
    for (p = last_unsent.p; p.next !is null; p = p.next) {
      p.tot_len += extendlen;
    }
    p.tot_len += extendlen;
    p.len += extendlen;
    last_unsent.len += extendlen;
  }

version (TCP_CHECKSUM_ON_COPY) {
  if (concat_chksummed) {
    assert(concat_p !is null || extendlen > 0,
                "tcp_write: concat checksum needs concatenated data");
    if (concat_chksum_swapped) {
      concat_chksum = byte_reverse(concat_chksum);
    }
    tcp_seg_add_chksum(concat_chksum, concat_chksummed, &last_unsent.chksum,
                       &last_unsent.chksum_swapped);
    last_unsent.flags |= TF_SEG_DATA_CHECKSUMMED;
  }
} /* TCP_CHECKSUM_ON_COPY */

  /* Phase 3: Append queue to pcb->unsent. */
  if (last_unsent is null) {
    pcb.unsent = queue;
  } else {
    last_unsent.next = queue;
  }

  /* Finally update the pcb state. */
  pcb.snd_lbb += len;
  pcb.snd_buf -= len;
  pcb.snd_queuelen = queuelen;

  LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_write: ", pcb.snd_queuelen, " (after enqueued)\n");
  if (pcb.snd_queuelen != 0) {
    assert(pcb.unacked !is null || pcb.unsent !is null, "tcp_write: valid queue length");
  }

  /* Set the PSH flag in the last segment that we enqueued. */
  if (seg !is null && seg.tcphdr !is null && ((apiflags & TCP_WRITE_FLAG_MORE) == 0)) {
    TCPH_SET_FLAG(seg.tcphdr, TCP_PSH);
  }

  return ERR_OK;
memerr:
  tcp_set_flags(pcb, TF_NAGLEMEMERR);

  if (concat_p !is null) {
    pbuf_free(concat_p);
  }
  if (queue !is null) {
    tcp_segs_free(queue);
  }
  if (pcb.snd_queuelen != 0) {
    assert(pcb.unacked !is null || pcb.unsent !is null, "tcp_write: valid queue length");
  }
  LWIP_DEBUGF(TCP_QLEN_DEBUG | LWIP_DBG_STATE, "tcp_write: ", pcb.snd_queuelen, " (with mem err)\n");
  return ERR_MEM;
}

/**
 * Split segment on the head of the unsent queue.
 */
err_t
tcp_split_unsent_seg(tcp_pcb* pcb, ushort split)
{
  tcp_seg* seg = null, useg = null;
  pbuf* p = null;
  ubyte optlen;
  ubyte optflags;
  ubyte split_flags;
  ubyte remainder_flags;
  ushort remainder;
  ushort offset;
version (TCP_CHECKSUM_ON_COPY) {
  ushort chksum = 0;
  ubyte chksum_swapped = 0;
  pbuf* q;
} /* TCP_CHECKSUM_ON_COPY */

  assert(pcb !is null, "tcp_split_unsent_seg: invalid pcb");

  useg = pcb.unsent;
  if (useg is null) {
    return ERR_MEM;
  }

  if (split == 0) {
    assert(0, "Can't split segment into length 0");
    return ERR_VAL;
  }

  if (useg.len <= split) {
    return ERR_OK;
  }

  assert(split <= pcb.mss, "split <= mss");
  assert(useg.len > 0, "useg->len > 0");

  LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_enqueue: split_unsent_seg: ", cast(uint)pcb.snd_queuelen, "\n");

  optflags = useg.flags;
version (TCP_CHECKSUM_ON_COPY) {
  optflags &= ~TF_SEG_DATA_CHECKSUMMED;
} /* TCP_CHECKSUM_ON_COPY */
  optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(optflags);
  remainder = cast(ushort)(useg.len - split);

  p = pbuf_alloc(PBUF_TRANSPORT, cast(ushort)(remainder + optlen), PBUF_RAM);
  if (p is null) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                "tcp_split_unsent_seg: could not allocate memory for pbuf remainder ", remainder, "\n");
    goto memerr;
  }

  offset = cast(ushort)(useg.p.tot_len - useg.len + split);
  if (pbuf_copy_partial(useg.p, cast(ubyte*)p.payload + optlen, remainder, offset) != remainder) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                "tcp_split_unsent_seg: could not copy pbuf remainder ", remainder, "\n");
    goto memerr;
  }
version (TCP_CHECKSUM_ON_COPY) {
  tcp_seg_add_chksum(cast(ushort)~internet_checksum((cast(const(ubyte)*)p.payload + optlen)[0 .. remainder]), remainder,
                     &chksum, &chksum_swapped);
} /* TCP_CHECKSUM_ON_COPY */

  /* Migrate flags from original segment */
  split_flags = TCPH_FLAGS(useg.tcphdr);
  remainder_flags = 0;

  if (split_flags & TCP_PSH) {
    split_flags &= ~TCP_PSH;
    remainder_flags |= TCP_PSH;
  }
  if (split_flags & TCP_FIN) {
    split_flags &= ~TCP_FIN;
    remainder_flags |= TCP_FIN;
  }

  seg = tcp_create_segment(pcb, p, remainder_flags, loadBigEndian(&useg.tcphdr.seqno) + split, optflags);
  if (seg is null) {
    p = null;
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                "tcp_split_unsent_seg: could not create new TCP segment\n");
    goto memerr;
  }

version (TCP_CHECKSUM_ON_COPY) {
  seg.chksum = chksum;
  seg.chksum_swapped = chksum_swapped;
  seg.flags |= TF_SEG_DATA_CHECKSUMMED;
} /* TCP_CHECKSUM_ON_COPY */

  pcb.snd_queuelen -= pbuf_clen(useg.p);

  pbuf_realloc(useg.p, cast(ushort)(useg.p.tot_len - remainder));
  useg.len -= remainder;
  TCPH_SET_FLAG(useg.tcphdr, split_flags);
version (TCP_OVERSIZE_DBGCHECK) {
  useg.oversize_left = 0;
} /* TCP_OVERSIZE_DBGCHECK */

  pcb.snd_queuelen += pbuf_clen(useg.p);

version (TCP_CHECKSUM_ON_COPY) {
  useg.chksum = 0;
  useg.chksum_swapped = 0;
  q = useg.p;
  offset = cast(ushort)(q.tot_len - useg.len);

  while (q !is null && offset > q.len) {
    offset -= q.len;
    q = q.next;
  }
  assert(q !is null, "Found start of payload pbuf");
  for (; q !is null; offset = 0, q = q.next) {
    tcp_seg_add_chksum(cast(ushort)~internet_checksum((cast(const(ubyte)*)q.payload + offset)[0 .. cast(ushort)(q.len - offset)]), cast(ushort)(q.len - offset),
                       &useg.chksum, &useg.chksum_swapped);
  }
} /* TCP_CHECKSUM_ON_COPY */

  pcb.snd_queuelen += pbuf_clen(seg.p);

  seg.next = useg.next;
  useg.next = seg;

version (TCP_OVERSIZE) {
  if (seg.next is null) {
    pcb.unsent_oversize = 0;
  }
} /* TCP_OVERSIZE */

  return ERR_OK;
memerr:

  assert(seg is null, "seg == NULL");
  if (p !is null) {
    pbuf_free(p);
  }

  return ERR_MEM;
}

/**
 * Called by tcp_close() to send a segment including FIN flag but not data.
 */
err_t
tcp_send_fin(tcp_pcb* pcb)
{
  assert(pcb !is null, "tcp_send_fin: invalid pcb");

  if (pcb.unsent !is null) {
    tcp_seg* last_unsent;
    for (last_unsent = pcb.unsent; last_unsent.next !is null;
         last_unsent = last_unsent.next) {}

    if ((TCPH_FLAGS(last_unsent.tcphdr) & (TCP_SYN | TCP_FIN | TCP_RST)) == 0) {
      TCPH_SET_FLAG(last_unsent.tcphdr, TCP_FIN);
      tcp_set_flags(pcb, TF_FIN);
      return ERR_OK;
    }
  }
  return tcp_enqueue_flags(pcb, TCP_FIN);
}

/**
 * Enqueue SYN or FIN for transmission.
 */
err_t
tcp_enqueue_flags(tcp_pcb* pcb, ubyte flags)
{
  pbuf* p;
  tcp_seg* seg;
  ubyte optflags = 0;
  ubyte optlen = 0;

  assert((flags & (TCP_SYN | TCP_FIN)) != 0,
              "tcp_enqueue_flags: need either TCP_SYN or TCP_FIN in flags");
  assert(pcb !is null, "tcp_enqueue_flags: invalid pcb");

  LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_enqueue_flags: queuelen: ", cast(ushort)pcb.snd_queuelen, "\n");

  if (flags & TCP_SYN) {
    optflags = TF_SEG_OPTS_MSS;
version (LWIP_WND_SCALE) {
    if ((pcb.state != SYN_RCVD) || (pcb.flags & TF_WND_SCALE)) {
      optflags |= TF_SEG_OPTS_WND_SCALE;
    }
} /* LWIP_WND_SCALE */
version (LWIP_TCP_SACK_OUT) {
    if ((pcb.state != SYN_RCVD) || (pcb.flags & TF_SACK)) {
      optflags |= TF_SEG_OPTS_SACK_PERM;
    }
} /* LWIP_TCP_SACK_OUT */
  }
version (LWIP_TCP_TIMESTAMPS) {
  if ((pcb.flags & TF_TIMESTAMP) || ((flags & TCP_SYN) && (pcb.state != SYN_RCVD))) {
    optflags |= TF_SEG_OPTS_TS;
  }
} /* LWIP_TCP_TIMESTAMPS */
  optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(optflags);

  if ((p = pbuf_alloc(PBUF_TRANSPORT, optlen, PBUF_RAM)) is null) {
    tcp_set_flags(pcb, TF_NAGLEMEMERR);
    return ERR_MEM;
  }
  assert(p.len >= optlen, "tcp_enqueue_flags: check that first pbuf can hold optlen");

  if ((seg = tcp_create_segment(pcb, p, flags, pcb.snd_lbb, optflags)) is null) {
    tcp_set_flags(pcb, TF_NAGLEMEMERR);
    return ERR_MEM;
  }
  assert(seg.len == 0, "tcp_enqueue_flags: invalid segment length");

  LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_TRACE,
              "tcp_enqueue_flags: queueing ", loadBigEndian(&seg.tcphdr.seqno), ":",
               loadBigEndian(&seg.tcphdr.seqno) + TCP_TCPLEN(seg),
               " (0x", cast(ushort)flags, ")\n");

  if (pcb.unsent is null) {
    pcb.unsent = seg;
  } else {
    tcp_seg* useg;
    for (useg = pcb.unsent; useg.next !is null; useg = useg.next) {}
    useg.next = seg;
  }
version (TCP_OVERSIZE) {
  pcb.unsent_oversize = 0;
} /* TCP_OVERSIZE */

  if ((flags & TCP_SYN) || (flags & TCP_FIN)) {
    pcb.snd_lbb++;
  }
  if (flags & TCP_FIN) {
    tcp_set_flags(pcb, TF_FIN);
  }

  pcb.snd_queuelen += pbuf_clen(seg.p);
  LWIP_DEBUGF(TCP_QLEN_DEBUG, "tcp_enqueue_flags: ", pcb.snd_queuelen, " (after enqueued)\n");
  if (pcb.snd_queuelen != 0) {
    assert(pcb.unacked !is null || pcb.unsent !is null, "tcp_enqueue_flags: invalid queue length");
  }

  return ERR_OK;
}

version (LWIP_TCP_TIMESTAMPS) {
/* Build a timestamp option (12 bytes long) at the specified options pointer */
private void
tcp_build_timestamp_option(const(tcp_pcb)* pcb, uint* opts)
{
  assert(pcb !is null, "tcp_build_timestamp_option: invalid pcb");

  storeBigEndian(&opts[0], cast(uint)(0x0101080A));
  storeBigEndian(&opts[1], cast(uint)(getTime().ticks / 1_000_000L));
  storeBigEndian(&opts[2], pcb.ts_recent);
}
}

version (LWIP_TCP_SACK_OUT) {
/**
 * Calculates the number of SACK entries that should be generated.
 */
private ubyte
tcp_get_num_sacks(const(tcp_pcb)* pcb, ubyte optlen)
{
  ubyte num_sacks = 0;

  assert(pcb !is null, "tcp_get_num_sacks: invalid pcb");

  if (pcb.flags & TF_SACK) {
    ubyte i;

    optlen += 12;

    for (i = 0; (i < LWIP_TCP_MAX_SACK_NUM) && (optlen <= TCP_MAX_OPTION_BYTES) &&
         LWIP_TCP_SACK_VALID(pcb, i); ++i) {
      ++num_sacks;
      optlen += 8;
    }
  }

  return num_sacks;
}

/** Build a SACK option (12 or more bytes long) at the specified options pointer */
private void
tcp_build_sack_option(const(tcp_pcb)* pcb, uint* opts, ubyte num_sacks)
{
  ubyte i;

  assert(pcb !is null, "tcp_build_sack_option: invalid pcb");
  assert(opts !is null, "tcp_build_sack_option: invalid opts");

  storeBigEndian(opts++, cast(uint)(0x01010500 + 2 + num_sacks * 8));

  for (i = 0; i < num_sacks; ++i) {
    storeBigEndian(opts++, pcb.rcv_sacks[i].left);
    storeBigEndian(opts++, pcb.rcv_sacks[i].right);
  }
}

}

version (LWIP_WND_SCALE) {
/** Build a window scale option (3 bytes long) at the specified options pointer */
private void
tcp_build_wnd_scale_option(uint* opts)
{
  assert(opts !is null, "tcp_build_wnd_scale_option: invalid opts");

  storeBigEndian(&opts[0], cast(uint)(0x01030300 | TCP_RCV_SCALE));
}
}

/**
 * @ingroup tcp_raw
 * Find out what we can send and send it.
 */
err_t
tcp_output(tcp_pcb* pcb)
{
  tcp_seg* seg, useg;
  uint wnd, snd_nxt;
  err_t err;
  netif nif;
version (TCP_CWND_DEBUG) {
  short i = 0;
} /* TCP_CWND_DEBUG */

  assert(pcb !is null, "tcp_output: invalid pcb");
  assert(pcb.state != LISTEN,
              "don't call tcp_output for listen-pcbs");

  if (tcp_input_pcb == pcb) {
    return ERR_OK;
  }

  wnd = min(pcb.snd_wnd, pcb.cwnd);

  seg = pcb.unsent;

  if (seg is null) {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG, "tcp_output: nothing to send (", pcb.unsent, ")\n");
    LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_output: snd_wnd ", pcb.snd_wnd,
                                 ", cwnd ", pcb.cwnd, ", wnd ", wnd,
                                 ", seg == NULL, ack ", pcb.lastack, "\n");

    if (pcb.flags & TF_ACK_NOW) {
      return tcp_send_empty_ack(pcb);
    }
    goto output_done;
  } else {
    LWIP_DEBUGF(TCP_CWND_DEBUG,
                "tcp_output: snd_wnd ", pcb.snd_wnd, ", cwnd ", pcb.cwnd, ", wnd ", wnd,
                 ", effwnd ", loadBigEndian(&seg.tcphdr.seqno) - pcb.lastack + seg.len,
                 ", seq ", loadBigEndian(&seg.tcphdr.seqno), ", ack ", pcb.lastack, "\n");
  }

  nif = tcp_route(pcb, &pcb.local_ip, &pcb.remote_ip);
  if (nif is null) {
    return ERR_RTE;
  }

  if (ip_addr_isany(&pcb.local_ip)) {
    const(ip_addr_t)* local_ip = ip_netif_get_local_ip(nif, &pcb.remote_ip);
    if (local_ip is null) {
      return ERR_RTE;
    }
    ip_addr_copy(pcb.local_ip, *local_ip);
  }

  /* Handle the current segment not fitting within the window */
  if (loadBigEndian(&seg.tcphdr.seqno) - pcb.lastack + seg.len > wnd) {
    if (wnd == pcb.snd_wnd && pcb.unacked is null && pcb.persist_backoff == 0) {
      pcb.persist_cnt = 0;
      pcb.persist_backoff = 1;
      pcb.persist_probe = 0;
    }
    if (pcb.flags & TF_ACK_NOW) {
      return tcp_send_empty_ack(pcb);
    }
    goto output_done;
  }
  pcb.persist_backoff = 0;

  useg = pcb.unacked;
  if (useg !is null) {
    for (; useg.next !is null; useg = useg.next) {}
  }
  /* data available and window allows it to be sent? */
  while (seg !is null &&
         loadBigEndian(&seg.tcphdr.seqno) - pcb.lastack + seg.len <= wnd) {
    assert((TCPH_FLAGS(seg.tcphdr) & TCP_RST) == 0,
                "RST not expected here!");
    if ((tcp_do_output_nagle(pcb) == 0) &&
        ((pcb.flags & (TF_NAGLEMEMERR | TF_FIN)) == 0)) {
      break;
    }
version (TCP_CWND_DEBUG) {
    LWIP_DEBUGF(TCP_CWND_DEBUG, "tcp_output: snd_wnd ", pcb.snd_wnd, ", cwnd ", pcb.cwnd, ", wnd ", wnd, ", effwnd ",
                                 loadBigEndian(&seg.tcphdr.seqno) + seg.len - pcb.lastack,
                                 ", seq ", loadBigEndian(&seg.tcphdr.seqno), ", ack ", pcb.lastack, ", i ", i, "\n");
    ++i;
} /* TCP_CWND_DEBUG */

    if (pcb.state != SYN_SENT) {
      TCPH_SET_FLAG(seg.tcphdr, TCP_ACK);
    }

    err = tcp_output_segment(seg, pcb, nif);
    if (err != ERR_OK) {
      tcp_set_flags(pcb, TF_NAGLEMEMERR);
      return err;
    }
version (TCP_OVERSIZE_DBGCHECK) {
    seg.oversize_left = 0;
} /* TCP_OVERSIZE_DBGCHECK */
    pcb.unsent = seg.next;
    if (pcb.state != SYN_SENT) {
      tcp_clear_flags(pcb, TF_ACK_DELAY | TF_ACK_NOW);
    }
    snd_nxt = loadBigEndian(&seg.tcphdr.seqno) + TCP_TCPLEN(seg);
    if (TCP_SEQ_LT(pcb.snd_nxt, snd_nxt)) {
      pcb.snd_nxt = snd_nxt;
    }
    /* put segment on unacknowledged list if length > 0 */
    if (TCP_TCPLEN(seg) > 0) {
      seg.next = null;
      if (pcb.unacked is null) {
        pcb.unacked = seg;
        useg = seg;
      } else {
        if (TCP_SEQ_LT(loadBigEndian(&seg.tcphdr.seqno), loadBigEndian(&useg.tcphdr.seqno))) {
          tcp_seg** cur_seg = &(pcb.unacked);
          while (*cur_seg &&
                 TCP_SEQ_LT(loadBigEndian(&(*cur_seg).tcphdr.seqno), loadBigEndian(&seg.tcphdr.seqno))) {
            cur_seg = &((*cur_seg).next);
          }
          seg.next = (*cur_seg);
          (*cur_seg) = seg;
        } else {
          useg.next = seg;
          useg = useg.next;
        }
      }
    } else {
      tcp_seg_free(seg);
    }
    seg = pcb.unsent;
  }
version (TCP_OVERSIZE) {
  if (pcb.unsent is null) {
    pcb.unsent_oversize = 0;
  }
} /* TCP_OVERSIZE */

output_done:
  tcp_clear_flags(pcb, TF_NAGLEMEMERR);
  return ERR_OK;
}

/** Check if a segment's pbufs are used by someone else than TCP. */
private int
tcp_output_segment_busy(const(tcp_seg)* seg)
{
  assert(seg !is null, "tcp_output_segment_busy: invalid seg");

  if (seg.p.ref_ != 1) {
    return 1;
  }
  return 0;
}

/**
 * Called by tcp_output() to actually send a TCP segment over IP.
 */
private err_t
tcp_output_segment(tcp_seg* seg, tcp_pcb* pcb, netif nif)
{
  err_t err;
  ushort len;
  uint* opts;
version (TCP_CHECKSUM_ON_COPY) {
  int seg_chksum_was_swapped = 0;
}

  assert(seg !is null, "tcp_output_segment: invalid seg");
  assert(pcb !is null, "tcp_output_segment: invalid pcb");
  assert(nif !is null, "tcp_output_segment: invalid netif");

  if (tcp_output_segment_busy(seg)) {
    LWIP_DEBUGF(TCP_RTO_DEBUG | LWIP_DBG_LEVEL_SERIOUS, "tcp_output_segment: segment busy\n");
    return ERR_OK;
  }

  /* The TCP header has already been constructed, but the ackno and wnd fields remain. */
  storeBigEndian(&seg.tcphdr.ackno, pcb.rcv_nxt);

  /* advertise our receive window size in this TCP segment */
  bool _wnd_set = false;
  version (LWIP_WND_SCALE) {
    if (seg.flags & TF_SEG_OPTS_WND_SCALE) {
      /* The Window field in a SYN segment itself (the only type where we send
         the window scale option) is never scaled. */
      storeBigEndian(&seg.tcphdr.wnd, TCPWND_MIN16(pcb.rcv_ann_wnd));
      _wnd_set = true;
    }
  }
  if (!_wnd_set) {
    storeBigEndian(&seg.tcphdr.wnd, TCPWND_MIN16(RCV_WND_SCALE(pcb, pcb.rcv_ann_wnd)));
  }

  pcb.rcv_ann_right_edge = pcb.rcv_nxt + pcb.rcv_ann_wnd;

  /* Add any requested options. */
  opts = cast(uint*)cast(void*)(seg.tcphdr + 1);
  if (seg.flags & TF_SEG_OPTS_MSS) {
    ushort mss;
version (TCP_CALCULATE_EFF_SEND_MSS) {
    mss = tcp_eff_send_mss_netif(TCP_MSS, nif, &pcb.remote_ip);
} else { /* TCP_CALCULATE_EFF_SEND_MSS */
    mss = TCP_MSS;
} /* TCP_CALCULATE_EFF_SEND_MSS */
    storeBigEndian(opts, 0x02040000U | (mss & 0xFFFF));
    opts += 1;
  }
version (LWIP_TCP_TIMESTAMPS) {
  pcb.ts_lastacksent = pcb.rcv_nxt;

  if (seg.flags & TF_SEG_OPTS_TS) {
    tcp_build_timestamp_option(pcb, opts);
    opts += 3;
  }
}
version (LWIP_WND_SCALE) {
  if (seg.flags & TF_SEG_OPTS_WND_SCALE) {
    tcp_build_wnd_scale_option(opts);
    opts += 1;
  }
}
version (LWIP_TCP_SACK_OUT) {
  if (seg.flags & TF_SEG_OPTS_SACK_PERM) {
    storeBigEndian(opts++, cast(uint)(0x01010402));
  }
}

  if (pcb.rtime < 0) {
    pcb.rtime = 0;
  }

  if (pcb.rttest == 0) {
    pcb.rttest = tcp_ticks;
    pcb.rtseq = loadBigEndian(&seg.tcphdr.seqno);

    LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_output_segment: rtseq ", pcb.rtseq, "\n");
  }
  LWIP_DEBUGF(TCP_OUTPUT_DEBUG, "tcp_output_segment: ", loadBigEndian(&seg.tcphdr.seqno), ":",
                                 loadBigEndian(&seg.tcphdr.seqno) + seg.len, "\n");

  len = cast(ushort)(cast(ubyte*)seg.tcphdr - cast(ubyte*)seg.p.payload);
  if (len == 0) {
  }

  seg.p.len -= len;
  seg.p.tot_len -= len;

  seg.p.payload = seg.tcphdr;

  seg.tcphdr.chksum = 0;

version (CHECKSUM_GEN_TCP) {
  if (IF__NETIF_CHECKSUM_ENABLED(nif, NETIF_CHECKSUM_GEN_TCP)) {
version (TCP_CHECKSUM_ON_COPY) {
    uint acc;
    if ((seg.flags & TF_SEG_DATA_CHECKSUMMED) == 0) {
      assert(seg.p.tot_len == TCPH_HDRLEN_BYTES(seg.tcphdr),
                  "data included but not checksummed");
    }

    acc = ip_chksum_pseudo_partial(seg.p, IP_PROTO_TCP,
                                   seg.p.tot_len, TCPH_HDRLEN_BYTES(seg.tcphdr), &pcb.local_ip, &pcb.remote_ip);
    if (seg.chksum_swapped) {
      seg_chksum_was_swapped = 1;
      seg.chksum = byte_reverse(seg.chksum);
      seg.chksum_swapped = 0;
    }
    acc = cast(ushort)~acc + seg.chksum;
    storeBigEndian(&seg.tcphdr.chksum, cast(ushort)~((acc >> 16) + (acc & 0xFFFF)));
} else { /* TCP_CHECKSUM_ON_COPY */
    storeBigEndian(&seg.tcphdr.chksum, ip_chksum_pseudo(seg.p, IP_PROTO_TCP,
                                           seg.p.tot_len, &pcb.local_ip, &pcb.remote_ip));
} /* TCP_CHECKSUM_ON_COPY */
  }
} /* CHECKSUM_GEN_TCP */

  NETIF_SET_HINTS(nif, &(pcb.netif_hints));
  err = ip_output_if(seg.p, &pcb.local_ip, &pcb.remote_ip, pcb.ttl,
                     pcb.tos, IP_PROTO_TCP, nif);
  NETIF_RESET_HINTS(nif);

version (TCP_CHECKSUM_ON_COPY) {
  if (seg_chksum_was_swapped) {
    seg.chksum = byte_reverse(seg.chksum);
    seg.chksum_swapped = 1;
  }
}

  return err;
}

/**
 * Requeue all unacked segments for retransmission.
 */
err_t
tcp_rexmit_rto_prepare(tcp_pcb* pcb)
{
  tcp_seg* seg;

  assert(pcb !is null, "tcp_rexmit_rto_prepare: invalid pcb");

  if (pcb.unacked is null) {
    return ERR_VAL;
  }

  for (seg = pcb.unacked; seg.next !is null; seg = seg.next) {
    if (tcp_output_segment_busy(seg)) {
      LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_rexmit_rto: segment busy\n");
      return ERR_VAL;
    }
  }
  if (tcp_output_segment_busy(seg)) {
    LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_rexmit_rto: segment busy\n");
    return ERR_VAL;
  }
  /* concatenate unsent queue after unacked queue */
  seg.next = pcb.unsent;
version (TCP_OVERSIZE_DBGCHECK) {
  if (pcb.unsent is null) {
    pcb.unsent_oversize = seg.oversize_left;
  }
} /* TCP_OVERSIZE_DBGCHECK */
  pcb.unsent = pcb.unacked;
  pcb.unacked = null;

  tcp_set_flags(pcb, TF_RTO);
  pcb.rto_end = loadBigEndian(&seg.tcphdr.seqno) + TCP_TCPLEN(seg);
  pcb.rttest = 0;

  return ERR_OK;
}

/**
 * Requeue all unacked segments for retransmission - commit.
 */
void
tcp_rexmit_rto_commit(tcp_pcb* pcb)
{
  assert(pcb !is null, "tcp_rexmit_rto_commit: invalid pcb");

  if (pcb.nrtx < 0xFF) {
    ++pcb.nrtx;
  }
  tcp_output(pcb);
}

/**
 * Requeue all unacked segments for retransmission.
 */
void
tcp_rexmit_rto(tcp_pcb* pcb)
{
  assert(pcb !is null, "tcp_rexmit_rto: invalid pcb");

  if (tcp_rexmit_rto_prepare(pcb) == ERR_OK) {
    tcp_rexmit_rto_commit(pcb);
  }
}

/**
 * Requeue the first unacked segment for retransmission.
 */
err_t
tcp_rexmit(tcp_pcb* pcb)
{
  tcp_seg* seg;
  tcp_seg** cur_seg;

  assert(pcb !is null, "tcp_rexmit: invalid pcb");

  if (pcb.unacked is null) {
    return ERR_VAL;
  }

  seg = pcb.unacked;

  if (tcp_output_segment_busy(seg)) {
    LWIP_DEBUGF(TCP_RTO_DEBUG, "tcp_rexmit busy\n");
    return ERR_VAL;
  }

  pcb.unacked = seg.next;

  cur_seg = &(pcb.unsent);
  while (*cur_seg &&
         TCP_SEQ_LT(loadBigEndian(&(*cur_seg).tcphdr.seqno), loadBigEndian(&seg.tcphdr.seqno))) {
    cur_seg = &((*cur_seg).next);
  }
  seg.next = *cur_seg;
  *cur_seg = seg;
version (TCP_OVERSIZE) {
  if (seg.next is null) {
    pcb.unsent_oversize = 0;
  }
} /* TCP_OVERSIZE */

  if (pcb.nrtx < 0xFF) {
    ++pcb.nrtx;
  }

  pcb.rttest = 0;

  return ERR_OK;
}


/**
 * Handle retransmission after three dupacks received.
 */
void
tcp_rexmit_fast(tcp_pcb* pcb)
{
  assert(pcb !is null, "tcp_rexmit_fast: invalid pcb");

  if (pcb.unacked !is null && !(pcb.flags & TF_INFR)) {
    LWIP_DEBUGF(TCP_FR_DEBUG,
                "tcp_receive: dupacks ", cast(ushort)pcb.dupacks, " (", pcb.lastack,
                 "), fast retransmit ", loadBigEndian(&pcb.unacked.tcphdr.seqno), "\n");
    if (tcp_rexmit(pcb) == ERR_OK) {
      pcb.ssthresh = min(pcb.cwnd, pcb.snd_wnd) / 2;

      if (pcb.ssthresh < (2U * pcb.mss)) {
        LWIP_DEBUGF(TCP_FR_DEBUG,
                    "tcp_receive: The minimum value for ssthresh ", pcb.ssthresh,
                     " should be min 2 mss ", cast(ushort)(2 * pcb.mss), "...\n");
        pcb.ssthresh = cast(tcpwnd_size_t)(2 * pcb.mss);
      }

      pcb.cwnd = cast(tcpwnd_size_t)(pcb.ssthresh + 3 * pcb.mss);
      tcp_set_flags(pcb, TF_INFR);

      pcb.rtime = 0;
    }
  }
}

private pbuf*
tcp_output_alloc_header_common(uint ackno, ushort optlen, ushort datalen,
                        uint seqno_be /* already in network byte order */,
                        ushort src_port, ushort dst_port, ubyte flags, ushort wnd)
{
  tcp_hdr* tcphdr;
  pbuf* p;

  p = pbuf_alloc(PBUF_IP, cast(ushort)(TCP_HLEN + optlen + datalen), PBUF_RAM);
  if (p !is null) {
    assert(p.len >= TCP_HLEN + optlen,
                "check that first pbuf can hold struct tcp_hdr");
    tcphdr = cast(tcp_hdr*)p.payload;
    storeBigEndian(&tcphdr.src, src_port);
    storeBigEndian(&tcphdr.dest, dst_port);
    tcphdr.seqno = seqno_be;
    storeBigEndian(&tcphdr.ackno, ackno);
    TCPH_HDRLEN_FLAGS_SET(tcphdr, (5 + optlen / 4), flags);
    storeBigEndian(&tcphdr.wnd, wnd);
    tcphdr.chksum = 0;
    tcphdr.urgp = 0;
  }
  return p;
}

/** Allocate a pbuf and create a tcphdr at p->payload, used for output functions other than the default tcp_output -> tcp_output_segment */
private pbuf*
tcp_output_alloc_header(tcp_pcb* pcb, ushort optlen, ushort datalen,
                        uint seqno_be /* already in network byte order */)
{
  pbuf* p;

  assert(pcb !is null, "tcp_output_alloc_header: invalid pcb");

  p = tcp_output_alloc_header_common(pcb.rcv_nxt, optlen, datalen,
    seqno_be, pcb.local_port, pcb.remote_port, TCP_ACK,
    TCPWND_MIN16(RCV_WND_SCALE(pcb, pcb.rcv_ann_wnd)));
  if (p !is null) {
    pcb.rcv_ann_right_edge = pcb.rcv_nxt + pcb.rcv_ann_wnd;
  }
  return p;
}

/* Fill in options for control segments */
private void
tcp_output_fill_options(const(tcp_pcb)* pcb, pbuf* p, ubyte optflags, ubyte num_sacks)
{
  tcp_hdr* tcphdr;
  uint* opts;
  ushort sacks_len = 0;

  assert(p !is null, "tcp_output_fill_options: invalid pbuf");

  tcphdr = cast(tcp_hdr*)p.payload;
  opts = cast(uint*)cast(void*)(tcphdr + 1);

version (LWIP_TCP_TIMESTAMPS) {
  if (optflags & TF_SEG_OPTS_TS) {
    tcp_build_timestamp_option(pcb, opts);
    opts += 3;
  }
}

version (LWIP_TCP_SACK_OUT) {
  if (pcb && (num_sacks > 0)) {
    tcp_build_sack_option(pcb, opts, num_sacks);
    sacks_len = 1 + num_sacks * 2;
    opts += sacks_len;
  }
}
}

/** Output a control segment pbuf to IP. */
private err_t
tcp_output_control_segment(const(tcp_pcb)* pcb, pbuf* p,
                           const(ip_addr_t)* src, const(ip_addr_t)* dst)
{
  netif nif;

  assert(p !is null, "tcp_output_control_segment: invalid pbuf");

  nif = tcp_route(pcb, src, dst);
  if (nif is null) {
    pbuf_free(p);
    return ERR_RTE;
  }
  return tcp_output_control_segment_netif(pcb, p, src, dst, nif);
}

/** Output a control segment pbuf to IP, when we don't have a pcb but we do know the interface. */
private err_t
tcp_output_control_segment_netif(const(tcp_pcb)* pcb, pbuf* p,
                                 const(ip_addr_t)* src, const(ip_addr_t)* dst,
                                 netif nif)
{
  err_t err;
  ubyte ttl, tos;

  assert(nif !is null, "tcp_output_control_segment_netif: no netif given");

version (CHECKSUM_GEN_TCP) {
  if (IF__NETIF_CHECKSUM_ENABLED(nif, NETIF_CHECKSUM_GEN_TCP)) {
    tcp_hdr* tcphdr = cast(tcp_hdr*)p.payload;
    storeBigEndian(&tcphdr.chksum, ip_chksum_pseudo(p, IP_PROTO_TCP, p.tot_len,
                                      src, dst));
  }
}
  if (pcb !is null) {
    NETIF_SET_HINTS(nif, cast(netif_hint*)&pcb.netif_hints);
    ttl = pcb.ttl;
    tos = pcb.tos;
  } else {
    ttl = TCP_TTL;
    tos = 0;
  }
  err = ip_output_if(p, src, dst, ttl, tos, IP_PROTO_TCP, nif);
  NETIF_RESET_HINTS(nif);

  pbuf_free(p);
  return err;
}

private pbuf*
tcp_rst_common(const(tcp_pcb)* pcb, uint seqno, uint ackno,
               const(ip_addr_t)* local_ip, const(ip_addr_t)* remote_ip,
               ushort local_port, ushort remote_port)
{
  pbuf* p;
  ushort wnd;
  ubyte optlen;

  assert(local_ip !is null, "tcp_rst: invalid local_ip");
  assert(remote_ip !is null, "tcp_rst: invalid remote_ip");

  optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(0);

version (LWIP_WND_SCALE) {
  storeBigEndian(&wnd, cast(ushort)((TCP_WND >> TCP_RCV_SCALE) & 0xFFFF));
} else {
  storeBigEndian(&wnd, cast(ushort)TCP_WND);
}

  uint seqno_be;
  storeBigEndian(&seqno_be, seqno);
  p = tcp_output_alloc_header_common(ackno, optlen, 0, seqno_be, local_port,
    remote_port, TCP_RST | TCP_ACK, wnd);
  if (p is null) {
    LWIP_DEBUGF(TCP_DEBUG, "tcp_rst: could not allocate memory for pbuf\n");
    return null;
  }
  tcp_output_fill_options(pcb, p, 0, 0);


  LWIP_DEBUGF(TCP_RST_DEBUG, "tcp_rst: seqno ", seqno, " ackno ", ackno, ".\n");
  return p;
}

/**
 * Send a TCP RESET packet to abort a connection.
 */
void
tcp_rst(const(tcp_pcb)* pcb, uint seqno, uint ackno,
        const(ip_addr_t)* local_ip, const(ip_addr_t)* remote_ip,
        ushort local_port, ushort remote_port)
{
  pbuf* p;

  p = tcp_rst_common(pcb, seqno, ackno, local_ip, remote_ip, local_port, remote_port);
  if (p !is null) {
    tcp_output_control_segment(pcb, p, local_ip, remote_ip);
  }
}

/**
 * Send a TCP RESET packet to show that there is no matching local connection.
 */
void
tcp_rst_netif(netif nif, uint seqno, uint ackno,
              const(ip_addr_t)* local_ip, const(ip_addr_t)* remote_ip,
              ushort local_port, ushort remote_port)
{
  if (nif) {
    pbuf* p = tcp_rst_common(null, seqno, ackno, local_ip, remote_ip, local_port, remote_port);
    if (p !is null) {
      tcp_output_control_segment_netif(null, p, local_ip, remote_ip, nif);
    }
  } else {
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG, "tcp_rst_netif: no netif given\n");
  }
}

/**
 * Send an ACK without data.
 */
err_t
tcp_send_empty_ack(tcp_pcb* pcb)
{
  err_t err;
  pbuf* p;
  ubyte optlen, optflags = 0;
  ubyte num_sacks = 0;

  assert(pcb !is null, "tcp_send_empty_ack: invalid pcb");

version (LWIP_TCP_TIMESTAMPS) {
  if (pcb.flags & TF_TIMESTAMP) {
    optflags = TF_SEG_OPTS_TS;
  }
}
  optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(optflags);

version (LWIP_TCP_SACK_OUT) {
  /* For now, SACKs are only sent with empty ACKs */
  if ((num_sacks = tcp_get_num_sacks(pcb, optlen)) > 0) {
    optlen += 4 + num_sacks * 8;
  }
}

  uint snd_nxt_be;
  storeBigEndian(&snd_nxt_be, pcb.snd_nxt);
  p = tcp_output_alloc_header(pcb, optlen, 0, snd_nxt_be);
  if (p is null) {
    tcp_set_flags(pcb, TF_ACK_DELAY | TF_ACK_NOW);
    LWIP_DEBUGF(TCP_OUTPUT_DEBUG, "tcp_output: (ACK) could not allocate pbuf\n");
    return ERR_BUF;
  }
  tcp_output_fill_options(pcb, p, optflags, num_sacks);

version (LWIP_TCP_TIMESTAMPS) {
  pcb.ts_lastacksent = pcb.rcv_nxt;
}

  LWIP_DEBUGF(TCP_OUTPUT_DEBUG,
              "tcp_output: sending ACK for ", pcb.rcv_nxt, "\n");
  err = tcp_output_control_segment(pcb, p, &pcb.local_ip, &pcb.remote_ip);
  if (err != ERR_OK) {
    tcp_set_flags(pcb, TF_ACK_DELAY | TF_ACK_NOW);
  } else {
    tcp_clear_flags(pcb, TF_ACK_DELAY | TF_ACK_NOW);
  }

  return err;
}

/**
 * Send keepalive packets.
 */
err_t
tcp_keepalive(tcp_pcb* pcb)
{
  err_t err;
  pbuf* p;
  ubyte optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(0);

  assert(pcb !is null, "tcp_keepalive: invalid pcb");

  LWIP_DEBUGF(TCP_DEBUG, "tcp_keepalive: sending KEEPALIVE probe to ");
  LWIP_DEBUGF(TCP_DEBUG, "\n");

  LWIP_DEBUGF(TCP_DEBUG, "tcp_keepalive: tcp_ticks ", tcp_ticks, "   pcb->tmr ", pcb.tmr, " pcb->keep_cnt_sent ", cast(ushort)pcb.keep_cnt_sent, "\n");

  uint snd_nxt_be;
  storeBigEndian(&snd_nxt_be, pcb.snd_nxt - 1);
  p = tcp_output_alloc_header(pcb, optlen, 0, snd_nxt_be);
  if (p is null) {
    LWIP_DEBUGF(TCP_DEBUG,
                "tcp_keepalive: could not allocate memory for pbuf\n");
    return ERR_MEM;
  }
  tcp_output_fill_options(pcb, p, 0, 0);
  err = tcp_output_control_segment(pcb, p, &pcb.local_ip, &pcb.remote_ip);

  LWIP_DEBUGF(TCP_DEBUG, "tcp_keepalive: seqno ", pcb.snd_nxt - 1, " ackno ", pcb.rcv_nxt, " err ", cast(int)err, ".\n");
  return err;
}

/**
 * Send persist timer zero-window probes to keep a connection active.
 */
err_t
tcp_zero_window_probe(tcp_pcb* pcb)
{
  err_t err;
  pbuf* p;
  tcp_hdr* tcphdr;
  tcp_seg* seg;
  ushort len;
  ubyte is_fin;
  uint snd_nxt;
  ubyte optlen = cast(ubyte)LWIP_TCP_OPT_LENGTH(0);

  assert(pcb !is null, "tcp_zero_window_probe: invalid pcb");

  LWIP_DEBUGF(TCP_DEBUG, "tcp_zero_window_probe: sending ZERO WINDOW probe to ");
  LWIP_DEBUGF(TCP_DEBUG, "\n");

  LWIP_DEBUGF(TCP_DEBUG, "tcp_zero_window_probe: tcp_ticks ", tcp_ticks,
               "   pcb->tmr ", pcb.tmr, " pcb->keep_cnt_sent ", cast(ushort)pcb.keep_cnt_sent, "\n");

  /* Only consider unsent, persist timer should be off when there is data in-flight */
  seg = pcb.unsent;
  if (seg is null) {
    return ERR_OK;
  }

  if (pcb.persist_probe < 0xFF) {
    ++pcb.persist_probe;
  }

  is_fin = ((TCPH_FLAGS(seg.tcphdr) & TCP_FIN) != 0) && (seg.len == 0);
  len = is_fin ? 0 : 1;

  p = tcp_output_alloc_header(pcb, optlen, len, seg.tcphdr.seqno);
  if (p is null) {
    LWIP_DEBUGF(TCP_DEBUG, "tcp_zero_window_probe: no memory for pbuf\n");
    return ERR_MEM;
  }
  tcphdr = cast(tcp_hdr*)p.payload;

  if (is_fin) {
    /* FIN segment, no data */
    TCPH_FLAGS_SET(tcphdr, TCP_ACK | TCP_FIN);
  } else {
    /* Data segment, copy in one byte from the head of the unacked queue */
    char* d = (cast(char*)p.payload + TCP_HLEN);
    pbuf_copy_partial(seg.p, d, 1, cast(ushort)(seg.p.tot_len - seg.len));
  }

  snd_nxt = loadBigEndian(&seg.tcphdr.seqno) + 1;
  if (TCP_SEQ_LT(pcb.snd_nxt, snd_nxt)) {
    pcb.snd_nxt = snd_nxt;
  }
  tcp_output_fill_options(pcb, p, 0, 0);

  err = tcp_output_control_segment(pcb, p, &pcb.local_ip, &pcb.remote_ip);

  LWIP_DEBUGF(TCP_DEBUG, "tcp_zero_window_probe: seqno ", pcb.snd_nxt - 1,
                          " ackno ", pcb.rcv_nxt, " err ", cast(int)err, ".\n");
  return err;
}
} /* LWIP_TCP */
