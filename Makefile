# =======================================================================
# OpenWatt -- main build
#
# Platform/processor/toolchain config is shared with the URT submodule;
# see third_party/urt/platforms.mk for what it resolves: ARCH, OS, MARCH,
# MATTR, MABI, BUILDNAME, DFLAGS (triples + version flags), URT_SOURCES,
# BAREMETAL_DIR/SRCS/GCC/CFLAGS/LIBC/M/GCC, ESPRESSIF_*, XTENSA_*.
#
# This file is the consumer side: app sources, app config string-imports,
# linker scripts, vendor SDK paths, packaging (RouterOS containers,
# ESP-IDF firmware, .bin via objcopy).
# =======================================================================

URT_DIR    := third_party/urt
URT_SRCDIR := $(URT_DIR)/src

# Discover a board's standard board.mk before platform resolution. BOARD
# describes fitted hardware; PLATFORM describes the SoC/toolchain. An explicit
# PLATFORM wins over the board's default.
ifdef BOARD
    BOARD_MAKEFILES := $(wildcard platforms/*/boards/$(BOARD)/board.mk)
    ifeq ($(BOARD_MAKEFILES),)
        $(error Unknown BOARD='$(BOARD)')
    endif
    ifneq ($(words $(BOARD_MAKEFILES)),1)
        $(error Ambiguous BOARD='$(BOARD)': $(BOARD_MAKEFILES))
    endif
    BOARD_CONFIG_DIR := $(patsubst %/board.mk,%,$(BOARD_MAKEFILES))
    include $(BOARD_MAKEFILES)
    ifeq ($(BOARD_PLATFORM),)
        $(error BOARD='$(BOARD)' must declare BOARD_PLATFORM in $(BOARD_MAKEFILES))
    endif
    ifeq ($(BOARD_FLASH_SIZE),)
        $(error BOARD='$(BOARD)' must declare BOARD_FLASH_SIZE in $(BOARD_MAKEFILES))
    endif
    ifeq ($(BOARD_PSRAM_SIZE),)
        $(error BOARD='$(BOARD)' must declare BOARD_PSRAM_SIZE in $(BOARD_MAKEFILES))
    endif
    PLATFORM ?= $(BOARD_PLATFORM)
endif

ifeq ($(PLATFORM),esp32-s2)
    TINY ?= 0
endif

include $(URT_DIR)/platforms.mk
include features.mk

# =======================================================================
# Paths and names
# =======================================================================

SRCDIR := src
TARGETNAME := openwatt

ifeq ($(CONFIG),unittest)
    TARGETNAME := $(TARGETNAME)_test
endif

# OBJDIR/TARGETDIR and the vendor.mk import come from platforms.mk.
DEPFILE    = $(OBJDIR)/$(TARGETNAME).d

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).exe
else
    TARGET = $(TARGETDIR)/$(TARGETNAME)
endif

# =======================================================================
# Sources (URT_SOURCES already populated by platforms.mk)
# =======================================================================

APP_SOURCES := $(SRCDIR)/main.d \
    $(foreach d,$(FEATURE_DIRS),$(shell find "$(SRCDIR)/$(d)" -type f -name '*.d'))
SOURCES := $(APP_SOURCES) $(URT_SOURCES)

DFLAGS := $(DFLAGS) $(FEATURE_DFLAGS) $(EXTRA_DFLAGS)

# Allocation lifetime profiler (urt.mem.profile): logs an event per
# allocation for host-side analysis; ~50 bytes of target state.
ifeq ($(ALLOC_PROFILE),1)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)AllocProfile
endif

# Allocation recorder (urt.mem.profile.record): keeps a live table so the
# target can answer "what has leaked" by itself, at the cost of the table.
ifeq ($(ALLOC_TRACKING),1)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)AllocTracking
endif

# ModuleInfo only exists to run module ctors/dtors and to enumerate unittests,
# and costs ~27KB of RAM on x86-64. Nothing declares a module ctor - urt.typereg
# registers via crt_constructor - so only the test runner still needs it.
# LDC SILENTLY SKIPS module ctors under this flag, so refuse to build if one
# reappears rather than dropping its initialisation on the floor.
ifeq ($(COMPILER),ldc)
  ifneq ($(CONFIG),unittest)
    # via a variable: make counts parens inside $(shell ...) without regard for quoting
    lparen := (
    MODULE_CTORS := $(shell grep -rlE '(^|[^_[:alnum:]])static[[:space:]]+~?this[[:space:]]*[$(lparen)]' \
        $(SRCDIR) $(URT_SRCDIR) --include=*.d 2>/dev/null)
    ifneq ($(MODULE_CTORS),)
      $(error --fno-moduleinfo would silently skip module ctors declared in: $(MODULE_CTORS))
    endif
    # a scan that cannot even find a file we know exists proves nothing about
    # module ctors, so the flag stays off ($(shell) is unusable under some Windows makes)
    CTOR_SCAN_OK := $(shell grep -rl 'module urt.typereg;' $(URT_SRCDIR) --include=*.d 2>/dev/null)
    ifneq ($(CTOR_SCAN_OK),)
      DFLAGS := $(DFLAGS) --fno-moduleinfo
    endif
  endif
endif


# Linux builds without the in-tree IP stack drive the kernel data plane directly.
ifeq ($(OS),linux)
  ifneq ($(USE_INTERNAL_IP_STACK),1)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)KernelMirror
  endif

  # WiFi backend selection. Default: kernel (nl80211 + the in-process WPA
  # supplicant/authenticator). Override to fall back to the external daemons,
  # independently for STA and AP, e.g. WIFI_AP_BACKEND=hostapd.
  WIFI_STA_BACKEND ?= kernel
  WIFI_AP_BACKEND  ?= kernel
  ifeq ($(WIFI_STA_BACKEND),kernel)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)WifiStaKernel
  else
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)WifiStaDaemon
  endif
  ifeq ($(WIFI_AP_BACKEND),kernel)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)WifiApKernel
  else
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)WifiApDaemon
  endif
endif

# =======================================================================
# App-specific compiler flags
#
# platforms.mk added URT's -I and all platform/version flags. Here we add
# the app source dir as both an import root (-I) and a string-import root
# (-J), then per-platform string-import dirs for runtime config.
# =======================================================================

ifeq ($(COMPILER),ldc)
    DFLAGS := $(DFLAGS) -I $(SRCDIR) -J $(SRCDIR)
else ifeq ($(COMPILER),dmd)
    # On Windows, prepend our self-contained __importc_builtins.di shadow to
    # work around druntime's MSVC-specific va_list handling.
    ifeq ($(OS),windows)
        DFLAGS := -I=third_party/dmd $(DFLAGS)
    endif
    DFLAGS := $(DFLAGS) -I=$(SRCDIR) -J=$(SRCDIR)
endif

# Per-platform string-import dirs (app config for embedded targets)
ifdef BOARD_CONFIG_DIR
    ifeq ($(wildcard $(BOARD_CONFIG_DIR)/system.conf),)
        $(error BOARD='$(BOARD)' is missing $(BOARD_CONFIG_DIR)/system.conf)
    endif
    DFLAGS := $(DFLAGS) -J $(BOARD_CONFIG_DIR)
    # system.conf is baked into the D object, so boards need isolated outputs.
    OBJDIR    := obj/$(BUILDNAME)_$(BOARD)_$(CONFIG)
    TARGETDIR := bin/$(BUILDNAME)_$(BOARD)_$(CONFIG)
else ifeq ($(PLATFORM),esp32)
    DFLAGS := $(DFLAGS) -J platforms/esp32
else ifeq ($(PLATFORM),esp32-s2)
    DFLAGS := $(DFLAGS) -J platforms/esp32s2
else ifeq ($(PLATFORM),esp32-s3)
    DFLAGS := $(DFLAGS) -J platforms/esp32s3
else ifeq ($(PLATFORM),esp32-c2)
    DFLAGS := $(DFLAGS) -J platforms/esp32c2
else ifeq ($(PLATFORM),esp32-c3)
    DFLAGS := $(DFLAGS) -J platforms/esp32c3
else ifeq ($(PLATFORM),esp32-c5)
    DFLAGS := $(DFLAGS) -J platforms/esp32c5
else ifeq ($(PLATFORM),esp32-c6)
    DFLAGS := $(DFLAGS) -J platforms/esp32c6
else ifeq ($(PLATFORM),esp32-h2)
    DFLAGS := $(DFLAGS) -J platforms/esp32h2
else ifeq ($(PLATFORM),esp32-p4)
    DFLAGS := $(DFLAGS) -J platforms/esp32p4
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
    DFLAGS := $(DFLAGS) -J platforms/bl808
  else ifeq ($(PROCESSOR),e907)
    DFLAGS := $(DFLAGS) -J platforms/bl808_m0
  endif
endif
ifeq ($(PLATFORM),bl618)
    DFLAGS := $(DFLAGS) -J platforms/bl618
endif
ifeq ($(PLATFORM),rp2350)
    DFLAGS := $(DFLAGS) -J platforms/rp2350
endif
ifdef STM32_VARIANT
    DFLAGS := $(DFLAGS) -J platforms/stm32
endif
ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    BK_PLATFORM_DIR := platforms/bk7231
    DFLAGS := $(DFLAGS) -J $(BK_PLATFORM_DIR)/$(PLATFORM)
endif

# RouterOS marker drives container packaging at the end of $(TARGET) build
ifeq ($(PLATFORM),routeros)
    ROUTEROS_BUILD = 1
endif

ifeq ($(CONFIG),unittest)
    DFLAGS := $(DFLAGS) -unittest
endif

# =======================================================================
# Linker scripts and vendor SDK wiring (per-platform memory maps + blobs)
#
# platforms.mk wired BAREMETAL_DIR/SRCS/GCC/CFLAGS/LIBC/M/GCC. We add the
# app linker script and any vendor blob libs here.
# =======================================================================

ifdef BAREMETAL_DIR
  # Linker scripts live in URT's platforms/ tree (canonical, shared with
  # URT-side unittest builds).
  URT_PLATFORMS := $(URT_DIR)/platforms
  ifeq ($(PLATFORM),bl808)
    ifeq ($(PROCESSOR),c906)
      BAREMETAL_LD := $(URT_PLATFORMS)/bl808/bl808_d0.ld
    else ifeq ($(PROCESSOR),e907)
      BAREMETAL_LD := $(URT_PLATFORMS)/bl808/bl808_m0.ld
    endif
  else ifeq ($(PLATFORM),bl618)
    BAREMETAL_LD := $(URT_PLATFORMS)/bl618/bl618.ld
  else ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    BAREMETAL_LD := $(URT_PLATFORMS)/bk7231/$(PLATFORM).ld
  else ifeq ($(PLATFORM),rp2350)
    BAREMETAL_LD := $(URT_PLATFORMS)/rp2350/rp2350.ld
  else ifdef STM32_VARIANT
    BAREMETAL_LD := $(URT_PLATFORMS)/stm32/stm32_$(STM32_VARIANT).ld
  endif

  ifdef BAREMETAL_LD
    DFLAGS := $(DFLAGS) -L-T$(BAREMETAL_LD)
  endif

  # BK7231: link SDK (FreeRTOS + drivers + lwIP) + WiFi/BLE blobs
  ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    BK_SDK_ROOT  ?= ../OpenBK7231T_App
    BK_BEKEN_LIB := $(BK_PLATFORM_DIR)/build/$(PLATFORM)/libbeken.a
    ifeq ($(PLATFORM),bk7231n)
      BK_BLOB_DIR := $(BK_SDK_ROOT)/sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/lib
    else
      BK_BLOB_DIR := $(BK_SDK_ROOT)/sdk/OpenBK7231T/platforms/bk7231t/bk7231t_os/beken378/lib
    endif
    DFLAGS := $(DFLAGS) -L$(BK_BEKEN_LIB) -L$(BK_BLOB_DIR)/librwnx.a -L$(BK_BLOB_DIR)/libble.a
  endif
endif

# =======================================================================
# Compile command (response-file form to dodge Windows' 8191-char limit)
# =======================================================================

RSPFILE := $(OBJDIR)/sources.rsp

ifeq ($(COMPILER),ldc)
    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(BAREMETAL_OBJS) $(VENDOR_OBJS) @$(RSPFILE)
else
    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -makedeps @$(RSPFILE) > $(DEPFILE)
endif

# Note: LDC's -deps format is its own (D module deps), not Make-compatible --
# so we don't `-include $(DEPFILE)`; full rebuild on file changes.

# =======================================================================
# Build rules
# =======================================================================

# Bare-metal startup files (compiled with cross-GCC)

ifdef BAREMETAL_DIR
BAREMETAL_OBJS := $(patsubst %.S,$(OBJDIR)/%.o,$(patsubst %.c,$(OBJDIR)/%.o,$(BAREMETAL_SRCS)))
BAREMETAL_CFLAGS := $(BAREMETAL_CFLAGS) -ffreestanding -O2

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.S
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.c
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<
endif

# -- Main target -------------------------------------------------------

$(TARGET): $(SOURCES) $(BAREMETAL_OBJS) $(VENDOR_OBJS) $(BK_BEKEN_LIB)

# -- BK7231 FreeRTOS build (must come after $(TARGET) so it doesn't become default goal)

ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
.PHONY: bk7231-sdk bk7231-clean

bk7231-sdk:
	$(MAKE) -C $(BK_PLATFORM_DIR) PLATFORM=$(PLATFORM) $(if $(BK_SDK_ROOT),BK_SDK_ROOT=$(BK_SDK_ROOT))

bk7231-clean:
	$(MAKE) -C $(BK_PLATFORM_DIR) clean

$(BK_BEKEN_LIB): bk7231-sdk
endif

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
	echo $(APP_SOURCES) > $(RSPFILE)
	echo $(URT_SOURCES) >> $(RSPFILE)
	$(COMPILE_CMD)
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
	riscv64-unknown-elf-objcopy -O binary $(TARGET) $(TARGETDIR)/d0fw.bin
	@# Gzipped variant for faster flash turnaround. M0's d0_image_load sniffs
	@# the gzip magic at offset 0 and decompresses straight to PSRAM.
	gzip -9 -n -c $(TARGETDIR)/d0fw.bin > $(TARGETDIR)/d0fw.bin.gz
  else ifeq ($(PROCESSOR),e907)
	riscv64-unknown-elf-objcopy -O binary $(TARGET) $(TARGETDIR)/m0fw.bin
  endif
endif
ifeq ($(PLATFORM),bl618)
	riscv64-unknown-elf-objcopy -O binary $(TARGET) $(TARGETDIR)/fw.bin
endif
ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
	arm-none-eabi-objcopy -O binary -R .bss -R .tbss -R '.tbss.*' -R .ARM.attributes -R '.debug*' $(TARGET) $(TARGETDIR)/fw.bin
endif
ifeq ($(PLATFORM),rp2350)
	arm-none-eabi-objcopy -O binary -R .bss -R .tbss -R '.tbss.*' -R .ARM.attributes -R '.debug*' $(TARGET) $(TARGETDIR)/fw.bin
endif
ifneq ($(filter esp%,$(PLATFORM)),)
	@echo ""
	@echo "=== D object ready: $(TARGET) ==="
	@echo "To build flashable firmware:  make esp-idf-build PLATFORM=$(PLATFORM)$(if $(BOARD), BOARD=$(BOARD)) CONFIG=$(CONFIG)"
	@echo "To flash:                     make esp-flash PLATFORM=$(PLATFORM)$(if $(BOARD), BOARD=$(BOARD))"
endif
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-container
	@$(MAKE) --no-print-directory routeros-tar
endif

# =======================================================================
# Platform packaging: RouterOS container
# =======================================================================

.PHONY: routeros-container routeros-tar routeros-clean

CONTAINER_ENGINE := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null || echo "")

routeros-container:
ifeq ($(CONTAINER_ENGINE),)
	@echo "Error: Neither podman nor docker found. Please install one to build containers."
	@exit 1
else
	@echo "Building RouterOS container image with $(CONTAINER_ENGINE)..."
	@PODMAN_IGNORE_CGROUPSV1_WARNING=1 $(CONTAINER_ENGINE) build --platform=linux/arm64 \
		--build-arg BUILDNAME=$(BUILDNAME) \
		--build-arg CONFIG=$(CONFIG) \
		-f Dockerfile.mikrotik \
		-t openwatt:latest \
		-t openwatt:routeros .
	@echo ""
	@echo "Container image built successfully!"
	@echo "  Image: openwatt:routeros"
	@echo ""
	@echo "To export for MikroTik deployment:"
	@echo "  make routeros-tar"
	@echo ""
endif

routeros-tar:
ifeq ($(CONTAINER_ENGINE),)
	@echo "Error: Neither podman nor docker found."
	@exit 1
else
	@echo "Exporting container to $(TARGETDIR)/openwatt.tar..."
	@$(CONTAINER_ENGINE) save openwatt:routeros -o $(TARGETDIR)/openwatt.tar
	@echo ""
	@echo "=== Build complete! ==="
	@echo "Container: $(TARGETDIR)/openwatt.tar ($$(du -h $(TARGETDIR)/openwatt.tar | cut -f1))"
	@echo ""
	@echo "Upload to router:"
	@echo "  scp $(TARGETDIR)/openwatt.tar admin@192.168.88.1:/openwatt.tar"
	@echo ""
	@echo "Or use deployment script:"
	@echo "  ./deploy-mikrotik.sh 192.168.88.1 admin"
	@echo ""
endif

routeros-clean:
ifeq ($(CONTAINER_ENGINE),)
	@echo "Skipping container cleanup (no container engine found)"
else
	@echo "Removing RouterOS container images..."
	-@$(CONTAINER_ENGINE) rmi openwatt:latest openwatt:routeros 2>/dev/null || true
	@rm -f openwatt.tar
endif

# =======================================================================
# Platform packaging: ESP-IDF firmware
# =======================================================================

.PHONY: esp-idf-build esp-flash esp-monitor esp-check-isr

ESP_IDF_PATH ?= $(lastword $(sort $(wildcard $(HOME)/.espressif/*/esp-idf)))
ifeq ($(PLATFORM),esp32)
    ESP_PROJECT_DIR := platforms/esp32
    ESP_IDF_TARGET  := esp32
    ESP_REFERENCE_BOARD := ESP32-DevKitC V4 (ESP32-WROOM-32E)
    ESP_FLASH_SIZE := 4MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-s2)
    ESP_PROJECT_DIR := platforms/esp32s2
    ESP_IDF_TARGET  := esp32s2
    ESP_REFERENCE_BOARD := ESP32-S2-DevKitC-1-N8R2
    ESP_FLASH_SIZE := 8MB
    ESP_PSRAM_SIZE := 2MB
else ifeq ($(PLATFORM),esp32-s3)
    ESP_PROJECT_DIR := platforms/esp32s3
    ESP_IDF_TARGET  := esp32s3
    ESP_REFERENCE_BOARD := ESP32-S3-DevKitC-1-N16R8
    ESP_FLASH_SIZE := 16MB
    ESP_PSRAM_SIZE := 8MB
else ifeq ($(PLATFORM),esp32-c2)
    ESP_PROJECT_DIR := platforms/esp32c2
    ESP_IDF_TARGET  := esp32c2
    ESP_REFERENCE_BOARD := ESP8684-DevKitC-02 (4 MB variant)
    ESP_FLASH_SIZE := 4MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-c3)
    ESP_PROJECT_DIR := platforms/esp32c3
    ESP_IDF_TARGET  := esp32c3
    ESP_REFERENCE_BOARD := ESP32-C3-DevKitM-1
    ESP_FLASH_SIZE := 4MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-c5)
    ESP_PROJECT_DIR := platforms/esp32c5
    ESP_IDF_TARGET  := esp32c5
    ESP_REFERENCE_BOARD := ESP32-C5-DevKitC-1 (N4 module)
    ESP_FLASH_SIZE := 4MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-c6)
    ESP_PROJECT_DIR := platforms/esp32c6
    ESP_IDF_TARGET  := esp32c6
    ESP_REFERENCE_BOARD := ESP32-C6-DevKitC-1
    ESP_FLASH_SIZE := 8MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-h2)
    ESP_PROJECT_DIR := platforms/esp32h2
    ESP_IDF_TARGET  := esp32h2
    ESP_REFERENCE_BOARD := ESP32-H2-DevKitM-1-N4
    ESP_FLASH_SIZE := 4MB
    ESP_PSRAM_SIZE := 0MB
else ifeq ($(PLATFORM),esp32-p4)
    ESP_PROJECT_DIR := platforms/esp32p4
    ESP_IDF_TARGET  := esp32p4
    ESP_REFERENCE_BOARD := ESP32-P4-Function-EV-Board
    ESP_FLASH_SIZE := 16MB
    ESP_PSRAM_SIZE := 32MB
endif

ifdef ESP_PROJECT_DIR
    esp_config_has_line = $(shell tr -d '\r' < "$(1)" | grep -Fxc '$(2)')
    ESP_BUILD_DIR := $(abspath $(OBJDIR)/esp-idf)
    ESP_SDKCONFIG := $(ESP_BUILD_DIR)/sdkconfig
    ESP_SDKCONFIG_DEFAULTS := $(abspath $(ESP_PROJECT_DIR)/sdkconfig.defaults)
    ifeq ($(CONFIG),release)
        ESP_RELEASE_SDKCONFIG := platforms/esp32-common/sdkconfig.release.defaults
        ESP_SDKCONFIG_DEFAULTS := $(ESP_SDKCONFIG_DEFAULTS);$(abspath $(ESP_RELEASE_SDKCONFIG))
    endif
    ifdef BOARD_CONFIG_DIR
        ESP_BOARD_SDKCONFIG := $(wildcard $(BOARD_CONFIG_DIR)/sdkconfig.defaults)
        ifeq ($(ESP_BOARD_SDKCONFIG),)
            $(error Espressif BOARD='$(BOARD)' is missing $(BOARD_CONFIG_DIR)/sdkconfig.defaults)
        endif
        ifeq ($(call esp_config_has_line,$(ESP_BOARD_SDKCONFIG),CONFIG_ESPTOOLPY_FLASHSIZE_$(BOARD_FLASH_SIZE)=y),0)
            $(error BOARD_FLASH_SIZE=$(BOARD_FLASH_SIZE) disagrees with $(ESP_BOARD_SDKCONFIG))
        endif
        ifeq ($(BOARD_PSRAM_SIZE),0MB)
            ifeq ($(call esp_config_has_line,$(ESP_BOARD_SDKCONFIG),CONFIG_SPIRAM=n),0)
                $(error BOARD_PSRAM_SIZE=0MB requires CONFIG_SPIRAM=n in $(ESP_BOARD_SDKCONFIG))
            endif
        else
            ifeq ($(call esp_config_has_line,$(ESP_BOARD_SDKCONFIG),CONFIG_SPIRAM=y),0)
                $(error BOARD_PSRAM_SIZE=$(BOARD_PSRAM_SIZE) requires CONFIG_SPIRAM=y in $(ESP_BOARD_SDKCONFIG))
            endif
        endif
        ESP_SDKCONFIG_DEFAULTS := $(ESP_SDKCONFIG_DEFAULTS);$(abspath $(ESP_BOARD_SDKCONFIG))
        ESP_REFERENCE_BOARD := $(BOARD)
        ESP_FLASH_SIZE := $(BOARD_FLASH_SIZE)
        ESP_PSRAM_SIZE := $(BOARD_PSRAM_SIZE)
    endif

    IDF_LOG_LEVEL ?= none
    ifeq ($(filter $(IDF_LOG_LEVEL),none error warn),)
        $(error Unknown IDF_LOG_LEVEL='$(IDF_LOG_LEVEL)'; valid: none | error | warn)
    endif
    ESP_IDF_LOG_SDKCONFIG := $(abspath platforms/esp32-common/sdkconfig.idf-log-$(IDF_LOG_LEVEL).defaults)
    ifeq ($(wildcard $(ESP_IDF_LOG_SDKCONFIG)),)
        $(error Missing ESP-IDF log policy $(ESP_IDF_LOG_SDKCONFIG))
    endif
    ESP_SDKCONFIG_DEFAULTS := $(ESP_SDKCONFIG_DEFAULTS);$(ESP_IDF_LOG_SDKCONFIG)
    ifeq ($(IDF_LOG_LEVEL),none)
        DFLAGS := $(DFLAGS) $(VERSION_FLAG)NoIDFLog
        ESP_IDF_LOG_ENABLED := 0
    else
        ESP_IDF_LOG_ENABLED := 1
    endif
endif

ifeq ($(XTENSA_TWO_STAGE),1)
ESP_LINK_OBJ := $(TARGET).o
$(ESP_LINK_OBJ): $(TARGET)
	"$(ESPRESSIF_LLC)" -O2 -mtriple=xtensa-none-elf --emulated-tls --mtext-section-literals --function-sections --data-sections --emit-dwarf-unwind=always --exception-model=dwarf $(XTENSA_MATTR) --filetype=obj $< -o $@
else
ESP_LINK_OBJ := $(TARGET)
endif

.PHONY: esp-idf-build
esp-idf-build: $(ESP_LINK_OBJ)
ifndef ESP_PROJECT_DIR
	@echo "Error: No ESP-IDF project directory for PLATFORM=$(PLATFORM)"
	@exit 1
endif
	@echo "Building ESP-IDF firmware ($(ESP_IDF_TARGET))..."
	@echo "Hardware: $(ESP_REFERENCE_BOARD), flash $(ESP_FLASH_SIZE), PSRAM $(ESP_PSRAM_SIZE)"
	bash -c '. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		idf.py -B "$(ESP_BUILD_DIR)" -DIDF_TARGET=$(ESP_IDF_TARGET) \
			-DSDKCONFIG="$(ESP_SDKCONFIG)" -DSDKCONFIG_DEFAULTS="$(ESP_SDKCONFIG_DEFAULTS)" \
			-DOPENWATT_OBJ=$(abspath $(ESP_LINK_OBJ)) \
			-DIDF_LOG_ENABLED=$(ESP_IDF_LOG_ENABLED) \
			-DPRESERVE_NVS=$(if $(filter 1,$(PRESERVE_NVS)),1,0) \
			-DUSE_LWIP=$(if $(filter 1,$(USE_INTERNAL_IP_STACK)),0,1) \
			-DUSE_SPIFFS=$(USE_SPIFFS) -DUSE_LITTLEFS=$(USE_LITTLEFS) build'
	cp "$(ESP_BUILD_DIR)/openwatt.bin" "$(TARGETDIR)/openwatt.bin"
	$(if $(BOARD_OTA_FILENAME),cp "$(ESP_BUILD_DIR)/openwatt.bin" "$(TARGETDIR)/$(BOARD_OTA_FILENAME)")
	cp "$(ESP_BUILD_DIR)/bootloader/bootloader.bin" "$(TARGETDIR)/bootloader.bin"
	cp "$(ESP_BUILD_DIR)/partition_table/partition-table.bin" "$(TARGETDIR)/partition-table.bin"
	cp -f "$(ESP_BUILD_DIR)/ota_data_initial.bin" "$(TARGETDIR)/ota_data_initial.bin" 2>/dev/null || true
	@echo ""
	@echo "=== Firmware ready: $(TARGETDIR)/ ==="
	@echo "  openwatt.bin       $$(du -h $(TARGETDIR)/openwatt.bin | cut -f1)"
	$(if $(BOARD_OTA_FILENAME),@echo "  $(BOARD_OTA_FILENAME)       app-only OTA image")
	@echo "  bootloader.bin     $$(du -h $(TARGETDIR)/bootloader.bin | cut -f1)"
	@echo "  partition-table.bin"
	@echo ""
	@echo "Flash with:"
	@echo "  make esp-flash PLATFORM=$(PLATFORM)$(if $(BOARD), BOARD=$(BOARD)) ESPPORT=<port>"

# @critical code must not call into flash-mapped sections; the call would fault
# whenever it runs with the instruction cache disabled.
ESP_OBJDUMP := $(if $(filter xtensa,$(ARCH)),$(ESPRESSIF_XTENSA_BIN)/xtensa-esp-elf-objdump,$(ESPRESSIF_RISCV32_BIN)/riscv32-esp-elf-objdump)

esp-check-isr:
	@python3 test/check_isr_safety.py "$(ESP_BUILD_DIR)/openwatt.elf" --objdump "$(ESP_OBJDUMP)"

esp-flash: esp-idf-build
	. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		idf.py -B "$(ESP_BUILD_DIR)" flash

esp-monitor:
	. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		idf.py -B "$(ESP_BUILD_DIR)" monitor

# =======================================================================
# Clean
# =======================================================================

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-clean
endif
