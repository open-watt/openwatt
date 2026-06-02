/**
 * @file
 * TCP protocol definitions
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
module protocol.ip.tcp.prot_tcp;

version (UseInternalIPStack):

import urt.endian : loadBigEndian, storeBigEndian;

nothrow @nogc:

/* Length of the TCP header, excluding options. */
enum TCP_HLEN = 20;

/* Fields are (of course) in network byte order.
 * Some fields are converted to host byte order in tcp_input().
 */
align(1) struct tcp_hdr {
align(1):
  ushort src;
  ushort dest;
  uint seqno;
  uint ackno;
  ushort _hdrlen_rsvd_flags;
  ushort wnd;
  ushort chksum;
  ushort urgp;
}

/* TCP header flags bits */
enum ubyte TCP_FIN = 0x01U;
enum ubyte TCP_SYN = 0x02U;
enum ubyte TCP_RST = 0x04U;
enum ubyte TCP_PSH = 0x08U;
enum ubyte TCP_ACK = 0x10U;
enum ubyte TCP_URG = 0x20U;
enum ubyte TCP_ECE = 0x40U;
enum ubyte TCP_CWR = 0x80U;
/* Valid TCP header flags */
enum ubyte TCP_FLAGS = 0x3fU;

enum TCP_MAX_OPTION_BYTES = 40;

ushort TCPH_HDRLEN(const(tcp_hdr)* phdr) pure => cast(ushort)(loadBigEndian(&phdr._hdrlen_rsvd_flags) >> 12);
ubyte TCPH_HDRLEN_BYTES(const(tcp_hdr)* phdr) pure => cast(ubyte)(TCPH_HDRLEN(phdr) << 2);
ubyte TCPH_FLAGS(const(tcp_hdr)* phdr) pure => cast(ubyte)(loadBigEndian(&phdr._hdrlen_rsvd_flags) & TCP_FLAGS);

void TCPH_HDRLEN_SET(tcp_hdr* phdr, uint len) pure {
    storeBigEndian(&phdr._hdrlen_rsvd_flags, cast(ushort)((len << 12) | TCPH_FLAGS(phdr)));
}
void TCPH_FLAGS_SET(tcp_hdr* phdr, ushort flags) pure {
    ushort cur = loadBigEndian(&phdr._hdrlen_rsvd_flags);
    storeBigEndian(&phdr._hdrlen_rsvd_flags, cast(ushort)((cur & ~TCP_FLAGS) | flags));
}
void TCPH_HDRLEN_FLAGS_SET(tcp_hdr* phdr, uint len, ushort flags) pure {
    storeBigEndian(&phdr._hdrlen_rsvd_flags, cast(ushort)((len << 12) | flags));
}

void TCPH_SET_FLAG(tcp_hdr* phdr, ushort flags) pure {
    ushort cur = loadBigEndian(&phdr._hdrlen_rsvd_flags);
    storeBigEndian(&phdr._hdrlen_rsvd_flags, cast(ushort)(cur | flags));
}
void TCPH_UNSET_FLAG(tcp_hdr* phdr, ushort flags) pure {
    ushort cur = loadBigEndian(&phdr._hdrlen_rsvd_flags);
    storeBigEndian(&phdr._hdrlen_rsvd_flags, cast(ushort)(cur & ~flags));
}
