# =======================================================================
# OpenWatt -- feature gating
#
# Included by the main Makefile after third_party/urt/platforms.mk has
# resolved $(PLATFORM) and $(VERSION_FLAG). Exports:
#   FEATURE_DIRS    Source-tree subdirs (relative to $(SRCDIR)) included
#                   for the chosen preset.
#   FEATURE_DFLAGS  D version flags appended to $(DFLAGS).
#   FEATURE_EXCLUDES Sources (relative to $(SRCDIR)) dropped from those dirs.
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
#                   <2MB-flash targets (esp8266, bk7231n/t, esp32-c2/h2/s2),
#                   overridable via TINY=1/0. Strips verbose
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
#   MODBUS, HTTP_CLIENT, HTTP_FILESERVER
#                   Optional components within a feature tier. Each defaults
#                   to 1 and may be disabled by a constrained BOARD profile.
#
#   IPV6            IPV6=0 drops the IPv6 side of the in-tree IP stack and
#                   its address, route, and pool collections. Defaults to 1.
#
#   GATEWAY         The router-role axis. GATEWAY=0 builds a plain node:
#                   no transit forwarding and no DHCP server or leases.
#                   DHCP clients and diagnostics stay. Defaults to 1, except
#                   TINY targets which default to 0.
#
#   RDP             RDP=1 builds reliable UDP: rdp_open sessions and
#                   /interface/udp reliable=, and sync over UDP. Defaults
#                   to 1 on every target.
#
#   SFP             SFP=1 builds the SFP cage, its module decoder and
#                   /interface/sfp. Few boards have a cage, so it defaults
#                   to 0 on embedded targets: a board with one sets SFP ?= 1
#                   in its board.mk. Windows and Linux take pluggable
#                   hardware, and unittest builds test it, so both default
#                   to 1.
# =======================================================================

# -- Per-platform defaults -----------------------------------------------
# Set BEFORE the ?= fallbacks below.

ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    FEATURES ?= switch
    HEADLESS ?= 1
endif

# -- Defaults ------------------------------------------------------------

FEATURES ?= full
HEADLESS ?= 0
MODBUS ?= 1
HTTP_CLIENT ?= 1
HTTP_FILESERVER ?= 1
IPV6 ?= 1
ifeq ($(TINY),1)
  GATEWAY ?= 0
endif
GATEWAY ?= 1
ifneq ($(filter windows linux,$(OS))$(filter unittest,$(CONFIG)),)
  SFP ?= 1
endif
SFP ?= 0
RDP ?= 1

# -- Validate ------------------------------------------------------------

ifeq ($(filter $(FEATURES),switch switch-ip switch-http switch-https full),)
    $(error Unknown FEATURES='$(FEATURES)'; valid: switch | switch-ip | switch-http | switch-https | full)
endif
ifneq ($(filter-out 0 1,$(MODBUS) $(HTTP_CLIENT) $(HTTP_FILESERVER) $(IPV6) $(GATEWAY) $(RDP) $(SFP)),)
    $(error MODBUS, HTTP_CLIENT, HTTP_FILESERVER, IPV6, GATEWAY, RDP and SFP must be 0 or 1)
endif

# -- Module selection ----------------------------------------------------
# The legacy variables give the default set; the resolved set projects back onto the smallest tier that compiles it.

include modules.mk

LEGACY_MODS_switch := shell sync profile bridge vlan l2_udp rdp pcap serial wifi wpan ethernet i2c spi sfp modbus sunspec
LEGACY_MODS_switch-ip := $(LEGACY_MODS_switch) ip_stack inet inet6 udp tcp ip_forward ipv6_ra dhcp_client dhcp_server
LEGACY_MODS_switch-http := $(LEGACY_MODS_switch-ip) http_server http_client http_binding websocket http_files api ota automation
LEGACY_MODS_switch-https := $(LEGACY_MODS_switch-http) tls

LEGACY_BARRED := $(if $(filter 0,$(MODBUS)),modbus) $(if $(filter 0,$(HTTP_CLIENT)),http_client) \
    $(if $(filter 0,$(HTTP_FILESERVER)),http_files) $(if $(filter 0,$(IPV6)),inet6) \
    $(if $(filter 0,$(GATEWAY)),ip_forward ipv6_ra dhcp_server) $(if $(filter 0,$(RDP)),rdp) \
    $(if $(filter 0,$(SFP)),sfp) $(if $(filter 1,$(HEADLESS)),shell)

mod_comma := ,
LEGACY_CLI := $(foreach v,FEATURES HEADLESS MODBUS HTTP_CLIENT HTTP_FILESERVER IPV6 GATEWAY RDP SFP,$(if $(filter command line,$(origin $v)),$v))
$(foreach v,$(LEGACY_CLI),$(warning $v= is deprecated; select modules with MODULES$(mod_comma) WITH and WITHOUT))

ifneq ($(origin MODULES),command line)
    $(call mod_root,default,default FEATURES=$(FEATURES),$(if $(filter full,$(FEATURES)),full,$(addsuffix ?,$(LEGACY_MODS_$(FEATURES)))))
    MOD_ROOTS := default
    MOD_LEGACY_BARRED := $(LEGACY_BARRED)
else ifneq ($(filter FEATURES,$(LEGACY_CLI)),)
    $(error MODULES replaces FEATURES; give one of them)
else
    $(call mod_root,modules,MODULES,$(MODULES))
    MOD_ROOTS := modules
    MOD_LEGACY_BARRED := $(if $(LEGACY_CLI),$(LEGACY_BARRED))
endif
$(call mod_root,with,WITH,$(WITH))
$(call mod_resolve,$(MOD_ROOTS) with,$(WITHOUT) $(filter-out $(WITH),$(MOD_LEGACY_BARRED)))
$(mod_report)

MOD_TIER := $(firstword $(foreach t,switch switch-ip switch-http switch-https,$(if $(filter-out $(LEGACY_MODS_$t) $(MOD_UMBRELLAS),$(MOD_SET)),,$t)) full)
legacy_axis = $(if $(filter full,$(MOD_TIER))$(filter $(firstword $1),$(LEGACY_MODS_$(MOD_TIER))),$(if $(filter $1,$(MOD_SET)),$2,$3),$4)
override FEATURES := $(MOD_TIER)
override MODBUS := $(call legacy_axis,modbus,1,0,$(MODBUS))
override HTTP_CLIENT := $(call legacy_axis,http_client,1,0,$(HTTP_CLIENT))
override HTTP_FILESERVER := $(call legacy_axis,http_files,1,0,$(HTTP_FILESERVER))
override IPV6 := $(call legacy_axis,inet6,1,0,$(IPV6))
override GATEWAY := $(call legacy_axis,ip_forward dhcp_server ipv6_ra,1,0,$(GATEWAY))
override RDP := $(call legacy_axis,rdp,1,0,$(RDP))
override SFP := $(call legacy_axis,sfp,1,0,$(SFP))
override HEADLESS := $(call legacy_axis,shell,0,1,$(HEADLESS))

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
ifeq ($(HTTP_CLIENT),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTPClient
endif
ifeq ($(HTTP_FILESERVER),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTPFileServer
endif
ifeq ($(IPV6),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoIPv6
endif
ifeq ($(GATEWAY),0)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoGateway
endif
ifeq ($(RDP),1)
    FEATURE_DFLAGS += $(VERSION_FLAG)HasRDP
else
    FEATURE_EXCLUDES += router/iface/rdp.d manager/sync/udp_server.d
endif
ifeq ($(SFP),1)
    FEATURE_DFLAGS += $(VERSION_FLAG)HasSFP
else
    FEATURE_EXCLUDES += router/iface/sfp.d router/iface/sff8472.d driver/sfp.d driver/baremetal/sfp.d
endif

# Explicit source roots must match manager.features.has_tesla_vehicle.
ifeq ($(filter windows,$(OS))$(filter 1,$(USE_MBEDTLS)),)
    FEATURE_EXCLUDES += protocol/tesla/vehicle_%.d
endif

# -- D version flags per preset ------------------------------------------
# Defaults are "everything on" so builds that don't run features.mk
# (Visual Studio, fresh checkouts, ad-hoc tools) get a full standalone
# instance. Reduced tiers emit -version=No* flags to opt out.

ifeq ($(FEATURES),switch)
    FEATURE_DFLAGS += $(VERSION_FLAG)NoAll
    FEATURE_DFLAGS += $(VERSION_FLAG)NoHTTP
    FEATURE_DFLAGS += $(VERSION_FLAG)NoIP
    FEATURE_DFLAGS += $(VERSION_FLAG)NoIPv6
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

ifeq ($(FRAMING_DIAGNOSTICS),1)
    FEATURE_DFLAGS += $(VERSION_FLAG)FramingDiagnostics
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
