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

include $(URT_DIR)/platforms.mk

# =======================================================================
# Paths and names
# =======================================================================

SRCDIR := src
TARGETNAME := openwatt

ifeq ($(CONFIG),unittest)
    TARGETNAME := $(TARGETNAME)_test
endif

OBJDIR    := obj/$(BUILDNAME)_$(CONFIG)
TARGETDIR := bin/$(BUILDNAME)_$(CONFIG)
DEPFILE    = $(OBJDIR)/$(TARGETNAME).d

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).exe
else
    TARGET = $(TARGETDIR)/$(TARGETNAME)
endif

# =======================================================================
# Sources (URT_SOURCES already populated by platforms.mk)
# =======================================================================

APP_SOURCES := $(shell find "$(SRCDIR)" -type f -name '*.d')
SOURCES := $(APP_SOURCES) $(URT_SOURCES)

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
ifeq ($(PLATFORM),esp32)
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
    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(BAREMETAL_OBJS) @$(RSPFILE)
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

$(TARGET): $(SOURCES) $(BAREMETAL_OBJS) $(BK_BEKEN_LIB)

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
ifeq ($(XTENSA_TWO_STAGE),1)
	"$(ESPRESSIF_LLC)" -O2 -mtriple=xtensa-none-elf --emulated-tls --mtext-section-literals --function-sections --data-sections --emit-dwarf-unwind=always --exception-model=dwarf $(XTENSA_MATTR) --filetype=obj $(TARGET) -o $(TARGET).o
	mv $(TARGET).o $(TARGET)
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
	riscv64-unknown-elf-objcopy -O binary $(TARGET) $(TARGETDIR)/d0fw.bin
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
	@echo "To build flashable firmware:  make esp-idf-build PLATFORM=$(PLATFORM) CONFIG=$(CONFIG)"
	@echo "To flash:                     make esp-flash PLATFORM=$(PLATFORM)"
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

.PHONY: esp-idf-build esp-flash esp-monitor

ESP_IDF_PATH ?= $(lastword $(sort $(wildcard $(HOME)/.espressif/*/esp-idf)))
ifeq ($(PLATFORM),esp32)
    ESP_PROJECT_DIR := platforms/esp32
    ESP_IDF_TARGET  := esp32
else ifeq ($(PLATFORM),esp32-s2)
    ESP_PROJECT_DIR := platforms/esp32s2
    ESP_IDF_TARGET  := esp32s2
else ifeq ($(PLATFORM),esp32-s3)
    ESP_PROJECT_DIR := platforms/esp32s3
    ESP_IDF_TARGET  := esp32s3
else ifeq ($(PLATFORM),esp32-c2)
    ESP_PROJECT_DIR := platforms/esp32c2
    ESP_IDF_TARGET  := esp32c2
else ifeq ($(PLATFORM),esp32-c3)
    ESP_PROJECT_DIR := platforms/esp32c3
    ESP_IDF_TARGET  := esp32c3
else ifeq ($(PLATFORM),esp32-c5)
    ESP_PROJECT_DIR := platforms/esp32c5
    ESP_IDF_TARGET  := esp32c5
else ifeq ($(PLATFORM),esp32-c6)
    ESP_PROJECT_DIR := platforms/esp32c6
    ESP_IDF_TARGET  := esp32c6
else ifeq ($(PLATFORM),esp32-h2)
    ESP_PROJECT_DIR := platforms/esp32h2
    ESP_IDF_TARGET  := esp32h2
else ifeq ($(PLATFORM),esp32-p4)
    ESP_PROJECT_DIR := platforms/esp32p4
    ESP_IDF_TARGET  := esp32p4
endif

esp-idf-build:
ifndef ESP_PROJECT_DIR
	@echo "Error: No ESP-IDF project directory for PLATFORM=$(PLATFORM)"
	@exit 1
endif
	@echo "Building ESP-IDF firmware ($(ESP_IDF_TARGET))..."
	bash -c '. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		if [ ! -f build/CMakeCache.txt ]; then idf.py set-target $(ESP_IDF_TARGET); fi && \
		idf.py -DOPENWATT_OBJ=$(abspath $(TARGET)) reconfigure build'
	cp "$(ESP_PROJECT_DIR)/build/openwatt.bin" "$(TARGETDIR)/openwatt.bin"
	cp "$(ESP_PROJECT_DIR)/build/bootloader/bootloader.bin" "$(TARGETDIR)/bootloader.bin"
	cp "$(ESP_PROJECT_DIR)/build/partition_table/partition-table.bin" "$(TARGETDIR)/partition-table.bin"
	cp -f "$(ESP_PROJECT_DIR)/build/ota_data_initial.bin" "$(TARGETDIR)/ota_data_initial.bin" 2>/dev/null || true
	@echo ""
	@echo "=== Firmware ready: $(TARGETDIR)/ ==="
	@echo "  openwatt.bin       $$(du -h $(TARGETDIR)/openwatt.bin | cut -f1)"
	@echo "  bootloader.bin     $$(du -h $(TARGETDIR)/bootloader.bin | cut -f1)"
	@echo "  partition-table.bin"
	@echo ""
	@echo "Flash from Windows:"
	@echo "  python -m esptool --chip $(ESP_IDF_TARGET) -p COM5 -b 460800 write_flash \\"
	@echo "    0x0 $(TARGETDIR)/bootloader.bin \\"
	@echo "    0x8000 $(TARGETDIR)/partition-table.bin \\"
	@echo "    0xf000 $(TARGETDIR)/ota_data_initial.bin \\"
	@echo "    0x20000 $(TARGETDIR)/openwatt.bin"

esp-flash:
	. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		idf.py flash

esp-monitor:
	. "$(ESP_IDF_PATH)/export.sh" > /dev/null 2>&1 && \
		cd "$(ESP_PROJECT_DIR)" && \
		idf.py monitor

# =======================================================================
# Clean
# =======================================================================

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-clean
endif
