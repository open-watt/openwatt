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
#                     switch  - main + manager + driver + router
#                               (L2 packet fabric; no IP/protocols/apps).
#                               Suited to a coprocessor data-plane build.
#                     switch-ip - switch + protocol/ip + protocol/dhcp.
#                               Used by small WiFi/AP targets that need L3
#                               service but not the full control plane.
#                     switch-http - switch-ip + HTTP, API, sync, and OTA, without TLS.
#                     switch-https - switch-http + TLS.
#                     full   - + protocol + apps + devices + tools.
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
#
#   MODBUS, TCP, HTTP_CLIENT, HTTP_FILESERVER
#                   Optional components within a feature tier. Each defaults
#                   to 1 and may be disabled by a constrained BOARD profile.
#                   TCP=0 drops the in-tree TCP engine (router/transport/tcp/engine.d);
#                   kernel-socket TCP survives on OS platforms, but ether-TCP
#                   and internal-stack TCP disappear.
# =======================================================================

# -- Per-platform defaults -----------------------------------------------
# Set BEFORE the ?= fallbacks below.

# BL808 e907 is the bouffalo wifi coprocessor.
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),e907)
    FEATURES ?= switch-ip
    HEADLESS ?= 1
  endif
endif

# -- Defaults ------------------------------------------------------------

FEATURES ?= full
HEADLESS ?= 0
MODBUS ?= 1
TCP ?= 1
HTTP_CLIENT ?= 1
HTTP_FILESERVER ?= 1

# -- Validate ------------------------------------------------------------

ifeq ($(filter $(FEATURES),switch switch-ip switch-http switch-https full),)
    $(error Unknown FEATURES='$(FEATURES)'; valid: switch | switch-ip | switch-http | switch-https | full)
endif
ifneq ($(filter-out 0 1,$(MODBUS) $(TCP) $(HTTP_CLIENT) $(HTTP_FILESERVER)),)
    $(error MODBUS, TCP, HTTP_CLIENT and HTTP_FILESERVER must be 0 or 1)
endif

# TCP=0 drops the in-tree engine; on a target driving the in-tree IP stack that leaves no TCP
# backend at all, so every tier carrying a TCP consumer (http, mqtt, telnet, dns, esphome) is out.
ifeq ($(TCP)$(USE_INTERNAL_IP_STACK),01)
    ifneq ($(filter-out switch switch-ip,$(FEATURES)),)
        $(error TCP=0 with the in-tree IP stack leaves no TCP backend, but FEATURES='$(FEATURES)' needs TCP streams; use FEATURES=switch or switch-ip, or build TCP=1)
    endif
endif

# -- Source-tree subset per preset ---------------------------------------
# main.d at $(SRCDIR) root is always included by the main Makefile.

FEATURE_DIRS_minimal := manager driver
# Modbus iface is part of the switching fabric -- every embedded device
# has a UART so modbus-rtu plumbing belongs with the data plane, not
# the higher-level control plane. The rest of protocol/modbus rides
# along here until the iface/control split is teased apart (Phase 2).
FEATURE_DIRS_switch  := manager driver router protocol/modbus
FEATURE_DIRS_switch-ip := $(FEATURE_DIRS_switch) protocol/ip protocol/dhcp
FEATURE_DIRS_switch-http := $(FEATURE_DIRS_switch-ip) protocol/http protocol/tls apps/api apps/automation apps/ota
FEATURE_DIRS_switch-https := $(FEATURE_DIRS_switch-http)
FEATURE_DIRS_full    := manager driver router protocol apps devices tools

FEATURE_DIRS := $(FEATURE_DIRS_$(FEATURES))

ifeq ($(MODBUS),0)
    FEATURE_DIRS := $(filter-out protocol/modbus,$(FEATURE_DIRS))
    FEATURE_DFLAGS += $(VERSION_FLAG)NoModbus
endif
ifeq ($(TCP),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoTCP
endif
ifeq ($(HTTP_CLIENT),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTPClient
endif
ifeq ($(HTTP_FILESERVER),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTPFileServer
endif

# -- D version flags per preset ------------------------------------------
# Defaults are "everything on" so builds that don't run features.mk
# (Visual Studio, fresh checkouts, ad-hoc tools) get a full standalone
# instance. Reduced tiers emit -version=No* flags to opt out.

ifeq ($(FEATURES),switch)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoAll
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTP
    FEATURE_DFLAGS += $(VERSION_FLAG)NoIP
    FEATURE_DFLAGS += $(VERSION_FLAG)NoTLS
endif
ifeq ($(FEATURES),switch-ip)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoAll
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTP
    FEATURE_DFLAGS += $(VERSION_FLAG)NoTLS
endif
ifeq ($(FEATURES),switch-http)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoAll
    FEATURE_DFLAGS += $(VERSION_FLAG)NoTLS
    FEATURE_DFLAGS += $(VERSION_FLAG)HasAPI
    FEATURE_DFLAGS += $(VERSION_FLAG)HasOTA
endif
ifeq ($(FEATURES),switch-https)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoAll
    FEATURE_DFLAGS += $(VERSION_FLAG)HasAPI
    FEATURE_DFLAGS += $(VERSION_FLAG)HasOTA
endif
# minimal (deferred) would additionally emit -version=NoSwitch.

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
