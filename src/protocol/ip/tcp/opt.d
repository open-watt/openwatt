/**
 * @file
 * Numeric tunables and debug-trace dispatcher for the lwIP TCP port.
 *
 * Boolean feature flags (LWIP_TCP, LWIP_WND_SCALE, etc.) are NOT defined here.
 * They are driven by the Makefile via -version= flags and tested with
 * `version (FOO)` blocks in the ported source.
 *
 * Contains:
 *   - numeric tunables (sizes, counts, defaults) — lwIP defaults reproduced.
 *   - IP address-type tags from ip_addr.h.
 *   - debug-flag numeric tags (TCP_DEBUG, TCP_INPUT_DEBUG, …).
 *   - severity bits (LWIP_DBG_LEVEL_*) and the LWIP_DEBUGF dispatcher.
 */
module protocol.ip.tcp.opt;

version (UseInternalIPStack):

nothrow @nogc:

enum LWIP_TCP_MAX_SACK_NUM          = 4;
enum TCP_DEFAULT_LISTEN_BACKLOG     = 0xff;
enum TCP_MSS                        = 1460;
enum TCP_SND_BUF                    = 2 * TCP_MSS;
enum TCP_SND_QUEUELEN               = 9;
enum TCP_SNDLOWAT                   = (TCP_SND_BUF / 2);
enum TCP_SNDQUEUELOWAT              = (TCP_SND_QUEUELEN < 5 ? 1 : (TCP_SND_QUEUELEN / 2));
enum TCP_WND                        = 4 * TCP_MSS;
enum TCP_MAXRTX                     = 12;
enum TCP_SYNMAXRTX                  = 6;

/* LWIP_TCP_PCB_NUM_EXT_ARGS is dual-purpose in lwIP: a version flag (on/off)
   and an integer count (array dimension). Both are accessible by the same
   name because versions and symbols live in separate namespaces. */
version (LWIP_TCP_PCB_NUM_EXT_ARGS) {
    enum LWIP_TCP_PCB_NUM_EXT_ARGS  = 1; /* default count when enabled */
}

/* IP address-type tags (from ip_addr.h); should move to a future port of that header. */
enum IPADDR_TYPE_V4                 = 0;
enum IPADDR_TYPE_V6                 = 6;
enum IPADDR_TYPE_ANY                = 46;

/* Debug-flag numeric tags. Used as the first arg of LWIP_DEBUGF; OR'd with
   severity bits (LWIP_DBG_LEVEL_*) at call sites. The TYPE on/off booleans
   for whole-subsystem debug are version()-gated; these are just opaque tags
   that the LWIP_DEBUGF stub ignores. */
enum TCP_DEBUG                      = 0x0001;
enum TCP_INPUT_DEBUG                = 0x0002;
enum TCP_OUTPUT_DEBUG               = 0x0004;
enum TCP_RTO_DEBUG                  = 0x0008;
enum TCP_CWND_DEBUG                 = 0x0010;
enum TCP_RST_DEBUG                  = 0x0020;
enum TCP_FR_DEBUG                   = 0x0040;
enum TCP_WND_DEBUG                  = 0x0080;
enum TCP_QLEN_DEBUG                 = 0x0100;
enum NETIF_DEBUG                    = 0x0200;
enum MEMP_DEBUG                     = 0x0400;
enum API_LIB_DEBUG                  = 0x0800;
enum API_MSG_DEBUG                  = 0x1000;

/* Severity bits OR'd into LWIP_DEBUGF's flag arg. */
enum LWIP_DBG_TRACE                 = 0x40;
enum LWIP_DBG_STATE                 = 0x20;
enum LWIP_DBG_FRESH                 = 0x10;
enum LWIP_DBG_HALT                  = 0x08;
enum LWIP_DBG_LEVEL_ALL             = 0x00;
enum LWIP_DBG_LEVEL_WARNING         = 0x01;
enum LWIP_DBG_LEVEL_SERIOUS         = 0x02;
enum LWIP_DBG_LEVEL_SEVERE          = 0x03;

/* lwIP's debug.h dispatcher. Gated by `-d-version=DebugLwipTcp`; when off,
   the variadic template compiles to nothing. When on, it routes to urt.log
   at debug severity tagged "tcp". The `flag` argument carries the lwIP-style
   subsystem tag OR'd with a LWIP_DBG_LEVEL_*. Currently ignored — per-tag
   gating can be added later by inspecting the bits. */
void LWIP_DEBUGF(Args...)(int flag, Args args)
{
    version (DebugLwipTcp)
    {
        import urt.log : Log;
        Log!"tcp".debug_(args);
    }
}

/* lwIP fires a window-update segment when the right edge moved this much. */
enum TCP_WND_UPDATE_THRESHOLD       = (TCP_WND / 4);
