# =======================================================================
# OpenWatt -- feature gating
#
# Included by the main Makefile after third_party/urt/platforms.mk has
# resolved $(PLATFORM) and $(VERSION_FLAG). Exports:
#   FEATURE_DIRS    Source-tree subdirs (relative to $(SRCDIR)) included
#                   for the chosen preset.
#   FEATURE_DFLAGS  D version flags appended to $(DFLAGS).
#
# Axes (orthogonal, can combine freely):
#
#   FEATURES        What's compiled in. Drives binary cost.
#                     switch -- main + manager + db + driver + router
#                               (L2 packet fabric; no IP/protocols/apps).
#                               Suited to a coprocessor data-plane build.
#                     full   -- + protocol + apps + devices + tools.
#                               Current default; standalone instance.
#                     minimal (DEFERRED -- needs manager/ decoupling from
#                               router/protocol; see Phase 2 TODOs at the
#                               bottom of this file.)
#
#   TINY            Set by third_party/urt/platforms.mk for <~350KB-RAM,
#                   <2MB-flash targets (esp8266, bk7231n/t, esp32-c2/h2/s2,
#                   bl808-e907), overridable via TINY=1/0. Strips verbose
#                   strings, simplifies CLI help, drops heavy-weight
#                   helpers. Lives in platforms.mk because urt itself
#                   gates against it.
#
#   HEADLESS        Set with HEADLESS=1 when the instance is embedded in
#                   a larger design and humans don't shell/web in directly
#                   for configuration -- the parent system drives it via
#                   the binary sync side-channel. Gates verbose CLI help,
#                   interactive prompts, banners, MOTDs. Orthogonal to
#                   FEATURES and TINY.
# =======================================================================

# -- Per-platform defaults -----------------------------------------------
# Set BEFORE the ?= fallbacks below.

# BL808 e907 is the bouffalo coprocessor: switch-tier data-plane only,
# never directly addressed by humans. Exercises the switch+headless
# build path in CI.
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),e907)
    FEATURES ?= switch
    HEADLESS ?= 1
  endif
endif

# -- Defaults ------------------------------------------------------------

FEATURES ?= full
HEADLESS ?= 0

# -- Validate ------------------------------------------------------------

ifeq ($(filter $(FEATURES),switch full),)
    $(error Unknown FEATURES='$(FEATURES)'; valid: switch | full)
endif

# -- Source-tree subset per preset ---------------------------------------
# main.d at $(SRCDIR) root is always included by the main Makefile.

FEATURE_DIRS_minimal := manager db driver
# Modbus iface is part of the switching fabric -- every embedded device
# has a UART so modbus-rtu plumbing belongs with the data plane, not
# the higher-level control plane. The rest of protocol/modbus rides
# along here until the iface/control split is teased apart (Phase 2).
FEATURE_DIRS_switch  := manager db driver router protocol/modbus
FEATURE_DIRS_full    := manager db driver router protocol apps devices tools

FEATURE_DIRS := $(FEATURE_DIRS_$(FEATURES))

# -- D version flags per preset (cumulative) -----------------------------

ifneq ($(filter $(FEATURES),switch full),)
    FEATURE_DFLAGS += $(VERSION_FLAG)Feature_Switch
endif
ifeq ($(FEATURES),full)
    FEATURE_DFLAGS += $(VERSION_FLAG)Feature_All
    FEATURE_DFLAGS += $(VERSION_FLAG)Feature_HTTP
    FEATURE_DFLAGS += $(VERSION_FLAG)Feature_IP
    FEATURE_DFLAGS += $(VERSION_FLAG)Feature_TLS
endif

ifeq ($(HEADLESS),1)
    FEATURE_DFLAGS += $(VERSION_FLAG)Headless
endif

# =======================================================================
# Phase 2 TODOs -- cleanups surfaced by the BL808_M0 switch+headless build
#
# Confirmed cross-layer link errors at SWITCH (manager/router code
# referencing protocol/* symbols, even though protocol/ isn't compiled in).
# Each needs a move, split, or `static if (has_all)` gate:
#
#   manager/certificate.d          -> protocol.http.{message,client,server,websocket}
#                                     move/split to apps/ or protocol/tls/
#   manager/sync/ws_server.d       -> protocol.http.{server,websocket}
#                                     move out of manager/sync/, gate at has_all
#   manager/console/session.d      -> protocol.telnet.stream
#                                     telnet should register itself as a transport;
#                                     console core shouldn't know it exists
#   manager/profile.d              -> protocol.http.message (HTTPMethod enum)
#                                  -> protocol.modbus.{message,binding}
#                                  -> protocol.goodwe.aa55
#                                     factor protocol-specific decoders out into
#                                     each protocol module, register with profile
#   router/iface/bridge.d          -> protocol.modbus.ServerMap
#                                     (currently masked by including protocol/modbus
#                                      in SWITCH; revisit when modbus splits)
#   router/pcap.d                  -> protocol.zigbee.iface
#                                     gate the zigbee-aware pcap encoding at has_all
#
# Deeper refactors (prerequisites for MINIMAL):
#
#   manager/value.d                Variant router-type support
#                                  -> extract to router/value.d
#   manager/console/argument.d     router-type convertVariants
#                                  -> extract to router/console_args.d
#   manager/sync/peer.d            packet-forwarding via router.iface
#                                  -> split or static if (has_switch)
#
# Protocol/module internal splits (matches the radio-coprocessor topology
# discussion -- fabric layer is switch-tier, control layer is full-tier):
#
#   protocol/modbus/               iface+message are switch-tier;
#                                  client/sampler/binding/sunspec are full-tier
#   protocol/zigbee/               iface+aps+coordinator are switch-tier;
#                                  zcl/zdo are full-tier
#   protocol/ble/                  LL/HCI are switch-tier;
#                                  GATT services + Tesla-BLE app logic are full-tier
# =======================================================================
