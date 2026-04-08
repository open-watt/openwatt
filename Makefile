CONFIG ?= debug
COMPILER ?= dmd

# ═══════════════════════════════════════════════════════════════════════
# PLATFORM — SoC/board identity
#
# Sets: BUILDNAME, PROCESSOR (default), OS, vendor version flags,
#       platform source paths, linker scripts, string imports,
#       vendor-specific GCC wrappers (Xtensa).
# ═══════════════════════════════════════════════════════════════════════

ifeq ($(PLATFORM),esp8266)
    # ESP8266 has no FPU!
    BUILDNAME := esp8266
    PROCESSOR := l106
    OS = freertos
    XTENSA_GCC := xtensa-lx106-elf-gcc
else ifeq ($(PLATFORM),esp32)
    BUILDNAME := esp32
    PROCESSOR := lx6
    OS = freertos
    XTENSA_GCC := xtensa-esp32-elf-gcc
else ifeq ($(PLATFORM),esp32-s2)
    # Single-core LX7, 240MHz — NO FPU, NO loops
    BUILDNAME := esp32-s2
    PROCESSOR := lx7
    OS = freertos
    XTENSA_GCC := xtensa-esp32s2-elf-gcc
else ifeq ($(PLATFORM),esp32-s3)
    # Dual-core LX7, 240MHz — FPU, loops, hardware unaligned access
    BUILDNAME := esp32-s3
    PROCESSOR := lx7
    OS = freertos
    XTENSA_GCC := xtensa-esp32s3-elf-gcc
    MATTR = +fp,+loop
    DFLAGS := $(DFLAGS) -d-version=SupportUnaligned
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
    # BL808 multi-core SoC — default to D0 (C906 RV64GC)
    # Override with PROCESSOR=e907 for M0 core (E907 RV32IMAFC)
    PROCESSOR ?= c906
    OS = baremetal
    ifeq ($(PROCESSOR),c906)
        BUILDNAME := bl808-d0
    else ifeq ($(PROCESSOR),e907)
        BUILDNAME := bl808-m0
    else
        $(error "BL808: unsupported PROCESSOR=$(PROCESSOR) (expected c906 or e907)")
    endif
else ifeq ($(PLATFORM),bl618)
    # Sipeed M0P — Bouffalo BL618, single-core T-Head E907 RV32IMAFC, 320MHz
    BUILDNAME := bl618
    PROCESSOR := e907
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
    PROCESSOR := aarch64-generic
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
  endif
endif

# Bare-processor fallback: if PLATFORM was set but didn't match any known
# platform above, treat it as a raw processor name (e.g., make PLATFORM=e906).
# The PROCESSOR block below will set ARCH/OS defaults.
ifndef PROCESSOR
  ifdef PLATFORM
    ifneq ($(PLATFORM),$(OS))
      PROCESSOR := $(PLATFORM)
    endif
  endif
endif

# ═══════════════════════════════════════════════════════════════════════
# PROCESSOR — CPU core identity
#
# Sets: ARCH, MARCH, MABI.  Pure ISA/compiler-target config.
# OS is set with ?= only as a fallback for bare-processor builds;
# PLATFORM always takes precedence.
# ═══════════════════════════════════════════════════════════════════════

ifdef PROCESSOR
  ifeq ($(PROCESSOR),aarch64-generic)
      ARCH = arm64
  else ifeq ($(PROCESSOR),cortex-a7)
      ARCH = arm
      MARCH = cortex-a7
  else ifeq ($(PROCESSOR),cortex-m4)
      ARCH = thumb
      MARCH = cortex-m4
  else ifeq ($(PROCESSOR),cortex-m7)
      ARCH = thumb
      MARCH = cortex-m7
  else ifeq ($(PROCESSOR),l106)
      ARCH  = xtensa
  else ifeq ($(PROCESSOR),lx6)
      ARCH  = xtensa
      MATTR = +fp,+loop,+mac16,+dfpaccel
  else ifeq ($(PROCESSOR),lx7)
      ARCH  = xtensa
  else ifeq ($(PROCESSOR),k210)
      ARCH  = riscv64
      MARCH = rv64imafdc
      MATTR = +m,+a,+f,+d,+c,+zicsr,+zifencei
      MABI  = lp64d
      OS ?= baremetal
  else ifeq ($(PROCESSOR),c906)
      ARCH  = riscv64
      MARCH = rv64imafdc
      MATTR = +m,+a,+f,+d,+c,+unaligned-scalar-mem,+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov,+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadsync
      MABI  = lp64d
      OS ?= baremetal
  else ifeq ($(PROCESSOR),e902)
      ARCH  = riscv
      MARCH = rv32emc
      MATTR = +e,+m,+c
      MABI  = ilp32e
      OS ?= baremetal
  else ifeq ($(PROCESSOR),e906)
      ARCH  = riscv
      MARCH = rv32imc
      MATTR = +m,+c
      MABI  = ilp32
      OS ?= freertos
  else ifeq ($(PROCESSOR),e907)
      ARCH  = riscv
      MARCH = rv32imafc
      MATTR = +m,+a,+f,+c
      MABI  = ilp32f
      OS ?= freertos
  else ifeq ($(PROCESSOR),esp32p4)
      ARCH  = riscv
      MARCH = rv32imafdcv
      MATTR = +m,+a,+f,+d,+c,+v
      MABI  = ilp32f
      OS ?= freertos
  endif
endif

# ═══════════════════════════════════════════════════════════════════════
# Compiler auto-selection: cross-compilation targets use LDC
# ═══════════════════════════════════════════════════════════════════════

ifeq ($(COMPILER),dmd)
ifdef ARCH
ifneq ($(ARCH),x86_64)
ifneq ($(ARCH),x86)
    COMPILER = ldc
endif
endif
endif
endif

# ═══════════════════════════════════════════════════════════════════════
# Toolchain discovery
# ═══════════════════════════════════════════════════════════════════════

# Espressif toolchain path — set to override auto-detection
# e.g.: make PLATFORM=esp32-s3 ESPRESSIF_PATH=~/.espressif
ESPRESSIF_PATH ?= $(wildcard $(HOME)/.espressif)
ifdef ESPRESSIF_PATH
    ESPRESSIF_XTENSA_BIN := $(lastword $(sort $(wildcard $(ESPRESSIF_PATH)/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin)))
    ESPRESSIF_RISCV32_BIN := $(lastword $(sort $(wildcard $(ESPRESSIF_PATH)/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin)))
endif

# ═══════════════════════════════════════════════════════════════════════
# Paths and names
# ═══════════════════════════════════════════════════════════════════════

RTSRCDIR := third_party/urt/src
SRCDIR := src
TARGETNAME := openwatt

ifndef BUILDNAME
    ifdef PROCESSOR
        BUILDNAME := $(PROCESSOR)
    else
        BUILDNAME := $(ARCH)_$(OS)
    endif
endif

OBJDIR := obj/$(BUILDNAME)_$(CONFIG)
TARGETDIR := bin/$(BUILDNAME)_$(CONFIG)
DEPFILE = $(OBJDIR)/$(TARGETNAME).d

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).exe
else
    TARGET = $(TARGETDIR)/$(TARGETNAME)
endif

# ═══════════════════════════════════════════════════════════════════════
# Sources
# ═══════════════════════════════════════════════════════════════════════

SOURCES := $(shell find "$(SRCDIR)" -type f -name '*.d')
SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)" -type f -name '*.d' -not -path '*/sys/bl808/*' -not -path '*/sys/bl618/*')
# mbedtls C glue needs host mbedtls headers — exclude for embedded targets
ifeq ($(filter freertos baremetal,$(OS)),)
    SOURCES := $(SOURCES) $(RTSRCDIR)/urt/internal/mbedtls.c
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
    SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)/sys/bl808" -type f -name '*.d')
  else ifeq ($(PROCESSOR),e907)
    # BL808 M0 core — E907 uses same peripheral drivers as BL618
    SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)/sys/bl618" -type f -name '*.d')
  endif
endif
ifeq ($(PLATFORM),bl618)
    SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)/sys/bl618" -type f -name '*.d')
endif

# ═══════════════════════════════════════════════════════════════════════
# PLATFORM post-config: version flags, string imports
# (runs after PROCESSOR is resolved so we can branch on sub-cores)
# ═══════════════════════════════════════════════════════════════════════
# Version flags use -d-version (LDC syntax) but all guarded platforms force LDC
# via compiler auto-selection above, so these are never reached by DMD builds.

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=in #-preview=nosharedaccess <- TODO: fix this

# OS and C runtime versions
ifeq ($(OS),freertos)
    DFLAGS := $(DFLAGS) -d-version=FreeRTOS
endif
ifneq ($(filter esp%,$(PLATFORM)),)
    # ESP-IDF toolchain uses picolibc (a newlib fork, since IDF v6.0)
    DFLAGS := $(DFLAGS) -d-version=Espressif -d-version=lwIP -d-version=CRuntime_Picolibc -J platforms/esp32s3
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
    DFLAGS := $(DFLAGS) -d-version=BL808 -d-version=Bouffalo -d-version=CRuntime_Picolibc -J platforms/bl808
  else ifeq ($(PROCESSOR),e907)
    DFLAGS := $(DFLAGS) -d-version=BL808 -d-version=BL808_M0 -d-version=Bouffalo -d-version=CRuntime_Picolibc -J platforms/bl808_m0
  endif
endif
ifeq ($(PLATFORM),bl618)
    DFLAGS := $(DFLAGS) -d-version=BL618 -d-version=Bouffalo -d-version=CRuntime_Picolibc -J platforms/bl618
endif

# Chip-specific versions
ifeq ($(PLATFORM),esp8266)
    DFLAGS := $(DFLAGS) -d-version=ESP8266
else ifeq ($(PLATFORM),esp32)
    DFLAGS := $(DFLAGS) -d-version=ESP32
else ifeq ($(PLATFORM),esp32-s2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_S2
else ifeq ($(PLATFORM),esp32-s3)
    DFLAGS := $(DFLAGS) -d-version=ESP32_S3
else ifeq ($(PLATFORM),esp32-c2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C2
else ifeq ($(PLATFORM),esp32-c3)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C3
else ifeq ($(PLATFORM),esp32-c5)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C5
else ifeq ($(PLATFORM),esp32-c6)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C6
else ifeq ($(PLATFORM),esp32-h2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_H2
else ifeq ($(PLATFORM),esp32-p4)
    DFLAGS := $(DFLAGS) -d-version=ESP32_P4
endif

ifeq ($(CONFIG),unittest)
    DFLAGS := $(DFLAGS) -unittest
    TARGETNAME := $(TARGETNAME)_test
endif

# ═══════════════════════════════════════════════════════════════════════
# Compiler configuration
# ═══════════════════════════════════════════════════════════════════════

ifeq ($(COMPILER),ldc)
    # Prefer dlang-installer LDC (avoids system package conflicts with cross-compile)
    DC ?= $(or $(wildcard $(HOME)/dlang/ldc-*/bin/ldc2),ldc2)
    DC := $(lastword $(sort $(wildcard $(HOME)/dlang/ldc-*/bin/ldc2)))
    DC := $(if $(DC),$(DC),ldc2)

    # Strip druntime/phobos - ldc2.conf in the project root is auto-discovered and sets -defaultlib=
    DFLAGS := $(DFLAGS) -I $(RTSRCDIR) -I $(SRCDIR) -J $(SRCDIR)

    # Architecture-specific target triples and machine flags
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
        ifdef MARCH
            DFLAGS := $(DFLAGS) -mcpu=$(MARCH)
        endif
    else ifeq ($(ARCH),arm)
        ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=arm-none-eabihf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=armv7-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=armv7-linux-gnueabihf
        endif
        ifdef MARCH
            DFLAGS := $(DFLAGS) -mcpu=$(MARCH)
        endif
    else ifeq ($(ARCH),riscv64)
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf -gcc=riscv64-unknown-elf-gcc -code-model=medium
        DFLAGS := $(DFLAGS) -mattr=$(MATTR)
        # ImportC needs picolibc headers for C imports (stdio.h etc.)
        PICOLIBC_INCLUDE := $(firstword $(wildcard /usr/riscv64-unknown-elf/include /usr/lib/picolibc/riscv64-unknown-elf/include))
        DFLAGS := $(DFLAGS) $(if $(PICOLIBC_INCLUDE),-P=-isystem -P=$(PICOLIBC_INCLUDE))
    else ifeq ($(ARCH),riscv)
        RISCV32_GCC ?= $(or $(if $(ESPRESSIF_RISCV32_BIN),$(ESPRESSIF_RISCV32_BIN)/riscv32-esp-elf-gcc),$(shell which riscv32-esp-elf-gcc 2>/dev/null),riscv64-unknown-elf-gcc)
        DFLAGS := $(DFLAGS) -mtriple=riscv32-unknown-elf -gcc=$(RISCV32_GCC)
        DFLAGS := $(DFLAGS) -mattr=$(MATTR) -mabi=$(MABI)
        ifeq ($(PROCESSOR),e902)
            DFLAGS := $(DFLAGS) -d-version=RISCV32E
        endif
    else ifeq ($(ARCH),xtensa)
        # Xtensa targets — requires Espressif toolchain (chip-specific GCC wrappers)
        XTENSA_GCC_DIR ?= $(or $(if $(ESPRESSIF_XTENSA_BIN),$(ESPRESSIF_XTENSA_BIN)/),$(dir $(shell which xtensa-esp-elf-gcc 2>/dev/null)))
        # Features common to all ESP32 Xtensa cores (LX6, S2 LX7, S3 LX7)
        # Note: +fp and +loop are NOT universal — S2 lacks both
        # Xtensa generic CPU has no atomic instructions — use single-thread model
        # so LLVM lowers atomics (e.g. shared static this() gates) to plain loads/stores
        # LLVM Xtensa workarounds:
        # - emulated TLS: @TPOFF symbol suffixes incompatible with GNU ld
        # - align-all-functions=2: ensures 4-byte alignment for l32r literal targets
        # Base features common to all ESP32 Xtensa cores
        XTENSA_MATTR := -mattr=+density,+mul16,+mul32,+mul32high,+div32 \
            -mattr=+sext,+nsa,+clamps,+minmax,+bool \
            -mattr=+windowed,+threadptr \
            -mattr=+exception,+interrupt,+highpriinterrupts,+debug
        # Add processor features (MATTR from PROCESSOR block)
        # and SoC features (XTENSA_FEATURES from PLATFORM block, for lx7)
        ifdef MATTR
            XTENSA_MATTR := $(XTENSA_MATTR) -mattr=$(MATTR)
        endif
        # Xtensa workarounds:
        # - single-thread model: no atomic instructions, LLVM lowers to plain loads/stores
        # - emulated TLS: @TPOFF symbol suffixes incompatible with GNU ld
        # - align-all-functions=2: ensures 4-byte alignment for l32r literal targets
        DFLAGS := $(DFLAGS) -mtriple=xtensa-none-elf --thread-model=single -emulated-tls \
            --align-all-functions=2 $(XTENSA_MATTR) \
            -gcc=$(XTENSA_GCC_DIR)$(XTENSA_GCC)
    else
        $(error "Unsupported ARCH: $(ARCH)")
    endif

    # Embedded targets: per-platform link support or compile-only fallback
    ifneq ($(filter freertos baremetal,$(OS)),)
      # Bouffalo baremetal — per-target dirs/srcs, common linking below
      ifeq ($(PLATFORM),bl808)
        ifeq ($(PROCESSOR),c906)
          BAREMETAL_DIR  := third_party/urt/src/sys/bl808
          BAREMETAL_SRCS := start.S hbn_ram.c
          BAREMETAL_LD   := platforms/bl808/ld/openwatt.ld
        else ifeq ($(PROCESSOR),e907)
          BAREMETAL_DIR  := third_party/urt/src/sys/bl618
          BAREMETAL_SRCS := start.S
          BAREMETAL_LD   := platforms/bl808_m0/ld/openwatt.ld
        endif
      else ifeq ($(PLATFORM),bl618)
        BAREMETAL_DIR  := third_party/urt/src/sys/bl618
        BAREMETAL_SRCS := start.S
        BAREMETAL_LD   := platforms/bl618/ld/openwatt.ld
      endif

      ifdef BAREMETAL_DIR
        # Common baremetal link config — MARCH/MABI come from PROCESSOR block
        BAREMETAL_GCC   := riscv64-unknown-elf-gcc
        BAREMETAL_MARCH := $(MARCH)
        BAREMETAL_MABI  := $(MABI)
        BAREMETAL_LIBGCC := $(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-libgcc-file-name)
        # Find picolibc libs: try --specs=picolibc.specs (Ubuntu), then native (Debian), then search /usr/lib/picolibc
        BAREMETAL_LIBC   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libc.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libc.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/libc.a))
        BAREMETAL_LIBM   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libm.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) -march=$(BAREMETAL_MARCH) -mabi=$(BAREMETAL_MABI) --print-file-name=libm.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/libm.a))
        DFLAGS := $(DFLAGS) -L-T$(BAREMETAL_LD) -L--gc-sections --link-internally -frame-pointer=all -L-z -Lnorelro -L$(BAREMETAL_LIBC) -L$(BAREMETAL_LIBM) -L$(BAREMETAL_LIBGCC)
      else
        # No linker script yet — compile only
        DFLAGS := $(DFLAGS) -c
      endif
    endif

    # Xtensa two-stage build: LDC emits bitcode, then Espressif's llc does codegen.
    # Upstream LLVM's Xtensa backend crashes on invoke+landingpad at -O1+
    # (LiveVariables segfault) and has l32r literal alignment bugs.
    ifeq ($(ARCH),xtensa)
        ESPRESSIF_LLC := $(lastword $(sort $(wildcard $(HOME)/.espressif/tools/esp-clang/*/esp-clang/bin/llc)))
        XTENSA_TWO_STAGE := 1
    endif

    ifeq ($(CONFIG),release)
      ifeq ($(ARCH),xtensa)
        DFLAGS := $(DFLAGS) -release --enable-asserts -Oz -enable-inlining --output-bc
      else
        DFLAGS := $(DFLAGS) -release --enable-asserts -O3 -enable-inlining
      endif
    else ifdef BAREMETAL_DIR
        # Embedded: optimize even for debug/unittest to fit in firmware partition
        DFLAGS := $(DFLAGS) --enable-asserts -O2 -enable-inlining
    else ifeq ($(ARCH),xtensa)
        # Xtensa embedded: optimize to fit in flash, emit bitcode for two-stage
        DFLAGS := $(DFLAGS) --enable-asserts -Oz -enable-inlining --output-bc -d-debug
    else
        DFLAGS := $(DFLAGS) -g -d-debug
    endif

    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(BAREMETAL_OBJS) $(SOURCES)
else ifeq ($(COMPILER),dmd)
    DC ?= dmd

    # Strip druntime/phobos, use URT's own object.d and runtime support.
    # DMD uses its own default config for import/lib paths; on Windows we add
    # third_party/dmd first so our self-contained __importc_builtins.di
    # shadows druntime's (which has MSVC-specific va_list issues). On Linux
    # the system __importc_builtins.di already handles GCC builtins correctly.
    ifeq ($(OS),windows)
        DFLAGS := -I=third_party/dmd $(DFLAGS) -defaultlib=
    else
        DFLAGS := $(DFLAGS) -defaultlib=
    endif

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

# Note: LDC's -deps format is not compatible with Make (it's a custom D module dependency format)
# so we don't use -include here. The build will rebuild everything when any file changes.

# ═══════════════════════════════════════════════════════════════════════
# Build rules
# ═══════════════════════════════════════════════════════════════════════

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

# ── Main target ───────────────────────────────────────────────────────

$(TARGET): $(SOURCES) $(BAREMETAL_OBJS)
	mkdir -p $(OBJDIR) $(TARGETDIR)
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

# ═══════════════════════════════════════════════════════════════════════
# Platform packaging: RouterOS container
# ═══════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════
# Platform packaging: ESP-IDF firmware
# ═══════════════════════════════════════════════════════════════════════

.PHONY: esp-idf-build esp-flash esp-monitor

# Map platform name to ESP-IDF project directory and IDF target
ESP_IDF_PATH ?= $(lastword $(sort $(wildcard $(HOME)/.espressif/*/esp-idf)))
ifeq ($(PLATFORM),esp32-s3)
    ESP_PROJECT_DIR := platforms/esp32s3
    ESP_IDF_TARGET  := esp32s3
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

# ═══════════════════════════════════════════════════════════════════════
# Clean
# ═══════════════════════════════════════════════════════════════════════

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-clean
endif
