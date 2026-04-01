CONFIG ?= debug
COMPILER ?= dmd

ifeq ($(PLATFORM),esp8266)
    # ESP8266 has no FPU!
    BUILDNAME := esp8266
    PROCESSOR := l106
    OS = freertos
else ifeq ($(PLATFORM),esp32)
    BUILDNAME := esp32
    PROCESSOR := lx6
    OS = freertos
else ifeq ($(PLATFORM),esp32-s2)
    BUILDNAME := esp32-s2
    PROCESSOR := lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-s3)
    BUILDNAME := esp32-s3
    PROCESSOR := lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-h2)
    BUILDNAME := esp32-h2
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c2)
    BUILDNAME := esp32-c2
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c3)
    BUILDNAME := esp32-c3
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c5)
    # RV32IMAC, 240MHz — has atomics
    BUILDNAME := esp32-c5
    PROCESSOR := e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-c6)
    # RV32IMAC, 160MHz — has atomics
    BUILDNAME := esp32-c6
    PROCESSOR := e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-p4)
    # HP core: RV32IMAFDCV, 400MHz
    BUILDNAME := esp32-p4
    PROCESSOR := esp32p4
    OS = freertos
else ifeq ($(PLATFORM),bl808)
    BUILDNAME := bl808
    PROCESSOR := c906
    OS = baremetal
else ifeq ($(PLATFORM),stm7xx)
    BUILDNAME := stm7xx
    PROCESSOR := cortex-m7
    OS = freertos
else ifeq ($(PLATFORM),stm4xx)
    BUILDNAME := stm4xx
    PROCESSOR := cortex-m4
    OS = freertos
else ifeq ($(PLATFORM),routeros)
    # MikroTik RouterOS container (ARM64 Linux)
    BUILDNAME := routeros
    ARCH = arm64
    OS := linux
    ROUTEROS_BUILD = 1
else
  ifeq ($(origin PLATFORM),undefined)
    # No platform specified — auto-detect host
    UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
    UNAME_M := $(shell uname -m 2>/dev/null || echo unknown)

    ifneq ($(findstring MINGW,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifneq ($(findstring MSYS,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifneq ($(findstring CYGWIN,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifeq ($(UNAME_S),Unknown)
        # no uname, probably native Windows - assume x86_64
        PLATFORM := windows
        OS := windows
        UNAME_M := x86_64
    else
        OS ?= linux
    endif

    PLATFORM := $(OS)

    # detect architecture from uname -m
    ifndef ARCH
        ifeq ($(UNAME_M),x86_64)
            ARCH := x86_64
        else ifeq ($(UNAME_M),amd64)
            ARCH := x86_64
        else ifeq ($(UNAME_M),i686)
            ARCH := x86
        else ifeq ($(UNAME_M),i386)
            ARCH := x86
        else ifeq ($(UNAME_M),aarch64)
            ARCH := arm64
        else ifeq ($(UNAME_M),arm64)
            ARCH := arm64
        else ifeq ($(UNAME_M),armv7l)
            ARCH := arm
        else ifeq ($(UNAME_M),riscv64)
            ARCH := riscv64
        endif
    endif
  else
    # Unrecognized PLATFORM value (e.g., e902) — treat as bare processor name
    PROCESSOR := $(PLATFORM)
  endif
endif

# Allow bare processor names as PLATFORM (e.g., make PLATFORM=e906)
ifndef PROCESSOR
  ifdef PLATFORM
    PROCESSOR := $(PLATFORM)
  endif
endif

ifdef PROCESSOR
  ifeq ($(PROCESSOR),cortex-a7)
      BUILDNAME ?= cortex-a7
      ARCH = arm
  else ifeq ($(PROCESSOR),cortex-m4)
      BUILDNAME ?= cortex-m4
      ARCH = thumb
  else ifeq ($(PROCESSOR),cortex-m7)
      BUILDNAME ?= cortex-m7
      ARCH = thumb
  else ifeq ($(PROCESSOR),l106)
      BUILDNAME ?= l106
      ARCH = xtensa
  else ifeq ($(PROCESSOR),lx6)
      BUILDNAME ?= lx6
      ARCH = xtensa
  else ifeq ($(PROCESSOR),lx7)
      BUILDNAME ?= lx7
      ARCH = xtensa
  else ifeq ($(PROCESSOR),k210)
      BUILDNAME ?= k210
      ARCH = riscv64
      OS = baremetal
  else ifeq ($(PROCESSOR),c906)
      BUILDNAME ?= c906
      ARCH = riscv64
      OS = baremetal
  else ifeq ($(PROCESSOR),e902)
      BUILDNAME ?= e902
      ARCH = riscv
      OS = baremetal
  else ifeq ($(PROCESSOR),e906)
      BUILDNAME ?= e906
      ARCH = riscv
      OS = freertos
  else ifeq ($(PROCESSOR),e907)
      BUILDNAME ?= e907
      ARCH = riscv
      OS = freertos
  else ifeq ($(PROCESSOR),esp32p4)
      BUILDNAME ?= esp32-p4
      ARCH = riscv
      OS = freertos
  endif
endif

# cross-compilers use LDC
ifeq ($(COMPILER),dmd)
ifdef ARCH
ifneq ($(ARCH),x86_64)
ifneq ($(ARCH),x86)
    COMPILER = ldc
endif
endif
endif
endif

RTSRCDIR := third_party/urt/src
SRCDIR := src
TARGETNAME := openwatt

ifndef BUILDNAME
    BUILDNAME := $(ARCH)_$(OS)
endif

OBJDIR := obj/$(BUILDNAME)_$(CONFIG)
TARGETDIR := bin/$(BUILDNAME)_$(CONFIG)
DEPFILE = $(OBJDIR)/$(TARGETNAME).d

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=in #-preview=nosharedaccess <- TODO: fix this

SOURCES := $(shell find "$(SRCDIR)" -type f -name '*.d')
SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)" -type f -name '*.d' -not -path '*/sys/bl808/*')
# mbedtls C glue needs host mbedtls headers — exclude for embedded targets
ifeq ($(filter freertos baremetal,$(OS)),)
    SOURCES := $(SOURCES) $(RTSRCDIR)/urt/internal/mbedtls.c
endif
ifeq ($(PLATFORM),bl808)
    SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)/sys/bl808" -type f -name '*.d')
    DFLAGS := $(DFLAGS) -d-version=BL808 -J platforms/bl808
endif

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).exe
else
    TARGET = $(TARGETDIR)/$(TARGETNAME)
endif

ifeq ($(COMPILER),ldc)
    # Prefer dlang-installer LDC (avoids system package conflicts with cross-compile)
    DC ?= $(or $(wildcard $(HOME)/dlang/ldc-*/bin/ldc2),ldc2)
    DC := $(lastword $(sort $(wildcard $(HOME)/dlang/ldc-*/bin/ldc2)))
    DC := $(if $(DC),$(DC),ldc2)
    DFLAGS := $(DFLAGS) -I $(RTSRCDIR) -I $(SRCDIR) -J $(SRCDIR)

    ifeq ($(ARCH),x86_64)
#        DFLAGS := $(DFLAGS) -mtriple=x86_64-linux-gnu
    else ifeq ($(ARCH),x86)
        ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=i686-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=i686-linux-gnu
        endif
    else ifeq ($(ARCH),arm64)
        ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=aarch64-none-elf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=aarch64-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=aarch64-linux-gnu
            # Use ARM64 cross-compilation toolchain linker
            # Build fully static binary for minimal container size
            DFLAGS := $(DFLAGS) -gcc=aarch64-linux-gnu-gcc -static -L-static
        endif
    else ifeq ($(ARCH),thumb)
        DFLAGS := $(DFLAGS) -mtriple=thumbv7em-none-eabihf -gcc=arm-none-eabi-gcc
        ifdef PROCESSOR
            DFLAGS := $(DFLAGS) -mcpu=$(PROCESSOR)
        endif
    else ifeq ($(ARCH),arm)
        ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=arm-none-eabihf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=armv7-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=armv7-linux-gnueabihf
        endif
        ifeq ($(PROCESSOR),cortex-a7)
            DFLAGS := $(DFLAGS) -mcpu=cortex-a7
        endif
    else ifeq ($(ARCH),riscv64)
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf -gcc=riscv64-unknown-elf-gcc -code-model=medium
        # ImportC needs picolibc headers for C imports (stdio.h etc.)
        PICOLIBC_INCLUDE := $(firstword $(wildcard /usr/riscv64-unknown-elf/include /usr/lib/picolibc/riscv64-unknown-elf/include))
        DFLAGS := $(DFLAGS) $(if $(PICOLIBC_INCLUDE),-P=-isystem -P=$(PICOLIBC_INCLUDE))
        ifeq ($(PROCESSOR),c906)
            # C906: RV64GC + T-Head extensions (vector is draft v0.7.1, not RVV 1.0)
            DFLAGS := $(DFLAGS) -mattr=+m,+a,+f,+d,+c,+unaligned-scalar-mem \
                -mattr=+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov \
                -mattr=+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadsync
        else ifeq ($(PROCESSOR),k210)
            # K210: RV64GC, no vector
            DFLAGS := $(DFLAGS) -mattr=+m,+a,+f,+d,+c,+zicsr,+zifencei
        endif
    else ifeq ($(ARCH),riscv)
        DFLAGS := $(DFLAGS) -mtriple=riscv32-unknown-elf -gcc=riscv64-unknown-elf-gcc
        ifeq ($(PROCESSOR),esp32p4)
            # ESP32-P4: RV32IMAFDCV, 400MHz
            DFLAGS := $(DFLAGS) -mattr=+m,+a,+f,+d,+c,+v
        else ifeq ($(PROCESSOR),e902)
            # E902: RV32EMC — 16 registers only, no FPU
            DFLAGS := $(DFLAGS) -mattr=+e,+m,+c -mabi=ilp32e -d-version=RISCV32E
        else ifeq ($(PROCESSOR),e906)
            # E906: RV32IMC — no atomic, no FPU
            DFLAGS := $(DFLAGS) -mattr=+m,+c -mabi=ilp32
        else ifeq ($(PROCESSOR),e907)
            # E907: RV32IMAFC — atomics + single-precision FP
            DFLAGS := $(DFLAGS) -mattr=+m,+a,+f,+c -mabi=ilp32f
        endif
    else ifeq ($(ARCH),xtensa)
        # Xtensa targets — requires Espressif toolchain (chip-specific GCC wrappers)
        XTENSA_GCC_DIR ?= $(dir $(shell which xtensa-esp-elf-gcc 2>/dev/null))
        # Features common to all ESP32 Xtensa cores (LX6, S2 LX7, S3 LX7)
        # Note: +fp and +loop are NOT universal — S2 lacks both
        XTENSA_COMMON := -mtriple=xtensa-none-elf \
            -mattr=+density,+mul16,+mul32,+mul32high,+div32 \
            -mattr=+sext,+nsa,+clamps,+minmax,+bool \
            -mattr=+windowed,+threadptr \
            -mattr=+exception,+interrupt,+highpriinterrupts,+debug
        ifeq ($(PROCESSOR),lx6)
            # ESP32: dual-core LX6, 240MHz — FPU, loops, MAC16, DFP acceleration
            DFLAGS := $(DFLAGS) $(XTENSA_COMMON) \
                -mattr=+fp,+loop,+mac16,+dfpaccel \
                -gcc=$(XTENSA_GCC_DIR)xtensa-esp32-elf-gcc
        else ifeq ($(PROCESSOR),lx7)
            ifeq ($(PLATFORM),esp32-s3)
                # ESP32-S3: dual-core LX7, 240MHz, 512KB SRAM — FPU, loops
                # Has PIE (SIMD) — not yet exposed in LLVM Xtensa backend
                # S3 supports unaligned load/store in hardware
                DFLAGS := $(DFLAGS) $(XTENSA_COMMON) \
                    -mattr=+fp,+loop \
                    -d-version=SupportUnaligned \
                    -gcc=$(XTENSA_GCC_DIR)xtensa-esp32s3-elf-gcc
            else
                # ESP32-S2: single-core LX7, 240MHz, 320KB SRAM — NO FPU, NO loops
                # All float math is software-emulated
                DFLAGS := $(DFLAGS) $(XTENSA_COMMON) \
                    -gcc=$(XTENSA_GCC_DIR)xtensa-esp32s2-elf-gcc
            endif
        endif
    else
        $(error "Unsupported ARCH: $(ARCH)")
    endif

    # Embedded targets: per-platform link support or compile-only fallback
    ifneq ($(filter freertos baremetal,$(OS)),)
      ifeq ($(PLATFORM),bl808)
        # BL808 D0 core (C906 RV64GC) — use LLD internally to avoid picolibc.ld injection
        BAREMETAL_DIR   := third_party/urt/src/sys/bl808
        BAREMETAL_SRCS  := start.S hbn_ram.c
        BAREMETAL_LD    := platforms/bl808/ld/openwatt.ld
        BAREMETAL_GCC   := riscv64-unknown-elf-gcc
        BAREMETAL_MARCH := rv64imafdc
        BAREMETAL_MABI  := lp64d
        BAREMETAL_LIBGCC := $(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-libgcc-file-name)
        # Find picolibc libs: try --specs=picolibc.specs (Ubuntu), then native (Debian --with-picolibc), then search /usr/lib/picolibc
        BAREMETAL_LIBC   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libc.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libc.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/libc.a))
        BAREMETAL_LIBM   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libm.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libm.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/libm.a))
        DFLAGS := $(DFLAGS) -L-T$(BAREMETAL_LD) -L--gc-sections --link-internally -frame-pointer=all -L-z -Lnorelro -L$(BAREMETAL_LIBC) -L$(BAREMETAL_LIBM) -L$(BAREMETAL_LIBGCC)
      else
        # No linker script yet — compile only
        DFLAGS := $(DFLAGS) -c
      endif
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release --enable-asserts -O3 -enable-inlining
    else ifdef BAREMETAL_DIR
        # Embedded: optimize even for debug/unittest to fit in firmware partition
        DFLAGS := $(DFLAGS) --enable-asserts -O2 -enable-inlining
    else
        DFLAGS := $(DFLAGS) -g -d-debug
    endif

    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(BAREMETAL_OBJS) $(SOURCES)
else ifeq ($(COMPILER),dmd)
    DC ?= dmd
    DFLAGS := $(DFLAGS) -I=$(RTSRCDIR) -I=$(SRCDIR) -J=$(SRCDIR)

    ifeq ($(ARCH),x86_64)
#        DFLAGS := $(DFLAGS) -m64
    else ifeq ($(ARCH),x86)
        DFLAGS := $(DFLAGS) -m32
    else
        $(error "Unsupported platform: $(PLATFORM)")
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release -O -inline
    else
        DFLAGS := $(DFLAGS) -g -debug
    endif

    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -makedeps $(SOURCES) > $(DEPFILE)
else
    $(error "Unknown D compiler: $(COMPILER)")
endif

ifeq ($(CONFIG),unittest)
    DFLAGS := $(DFLAGS) -unittest
    TARGETNAME := $(TARGETNAME)_test
endif

# Strip druntime/phobos, use URT's own object.d and runtime support
# LDC: ldc2.conf in the project root is auto-discovered and sets -defaultlib=
# DMD: uses its own default config for import/lib paths; on Windows we add
#      third_party/dmd first so our self-contained __importc_builtins.di
#      shadows druntime's (which has MSVC-specific va_list issues). On Linux
#      the system __importc_builtins.di already handles GCC builtins correctly
ifeq ($(COMPILER),dmd)
    ifeq ($(OS),windows)
        DFLAGS := -I=third_party/dmd $(DFLAGS) -defaultlib=
    else
        DFLAGS := $(DFLAGS) -defaultlib=
    endif
endif

# Note: LDC's -deps format is not compatible with Make (it's a custom D module dependency format)
# so we don't use -include here. The build will rebuild everything when any file changes.

# Bare-metal support files (startup, stubs) — compiled with cross-GCC
ifdef BAREMETAL_DIR
BAREMETAL_OBJS := $(patsubst %.S,$(OBJDIR)/%.o,$(patsubst %.c,$(OBJDIR)/%.o,$(BAREMETAL_SRCS)))
BAREMETAL_CFLAGS := -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) -ffreestanding -O2

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.S
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.c
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<
endif

$(TARGET): $(SOURCES) $(BAREMETAL_OBJS)
	mkdir -p $(OBJDIR) $(TARGETDIR)
	$(COMPILE_CMD)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-container
	@$(MAKE) --no-print-directory routeros-tar
endif
ifeq ($(PLATFORM),bl808)
	riscv64-unknown-elf-objcopy -O binary $(TARGET) $(TARGETDIR)/d0fw.bin
endif

# MikroTik RouterOS container packaging
.PHONY: routeros-container routeros-tar routeros-clean

# Detect container engine (podman or docker)
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

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-clean
endif
