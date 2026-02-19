CONFIG ?= debug
COMPILER ?= dmd

ifeq ($(PLATFORM),esp8266)
    # ESP8266 has no FPU!
    BUILDNAME := esp8266
    PLATFORM = l106
    OS = freertos
else ifeq ($(PLATFORM),esp32)
    BUILDNAME := esp32
    PLATFORM = lx6
    OS = freertos
else ifeq ($(PLATFORM),esp32-s2)
    BUILDNAME := esp32-s2
    PLATFORM = lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-s3)
    BUILDNAME := esp32-s3
    PLATFORM = lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-h2)
    BUILDNAME := esp32-h2
    PLATFORM = e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c2)
    BUILDNAME := esp32-c2
    PLATFORM = e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c3)
    BUILDNAME := esp32-c3
    PLATFORM = e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c5)
    BUILDNAME := esp32-c5
    PLATFORM = e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-c6)
    BUILDNAME := esp32-c6
    PLATFORM = e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-p4)
    # P4 is apparently 32bit variant of c906, but it does have double and 64bit data paths for vectors...
    # can we have some clarity here?
    BUILDNAME := esp32-p4
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),stm7xx)
    BUILDNAME := stm7xx
    PLATFORM = cortex-a7
    OS = freertos
else ifeq ($(PLATFORM),stm4xx)
    BUILDNAME := stm4xx
    PLATFORM = cortex-a7
    OS = freertos
else ifeq ($(PLATFORM),routeros)
    # MikroTik RouterOS container (ARM64 Linux)
    BUILDNAME := routeros
    ARCH = arm64
    OS := linux
    ROUTEROS_BUILD = 1
else
    # no platform specified or unknown - auto-detect
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

ifeq ($(PLATFORM),cortex-a7)
    BUILDNAME := cortex-a7
    ARCH = arm
else ifeq ($(PLATFORM),l106)
    BUILDNAME := l106
    ARCH = xtensa
else ifeq ($(PLATFORM),lx6)
    BUILDNAME := lx6
    ARCH = xtensa
else ifeq ($(PLATFORM),lx7)
    BUILDNAME := lx7
    ARCH = xtensa
else ifeq ($(PLATFORM),k210)
    # K210 is RV64GC, 400mhz x2 (dual core)
    BUILDNAME := k210
    ARCH = riscv64
    OS = freertos
else ifeq ($(PLATFORM),c906)
    # C906 is RV64GCV, 480mhz (D0 (main) core in BL808)
    BUILDNAME := c906
    ARCH = riscv64
    OS = freertos
else ifeq ($(PLATFORM),e902)
    # E902 is RV32EMC, no FPU!
    BUILDNAME := e902
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),e906)
    # E906 is RV32IMC, no FPU!
    BUILDNAME := e906
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),e907)
    # E907 is RV32IMAFCP, 320mhz (M0 core in BL808)
    BUILDNAME := e907
    ARCH = riscv
    OS = freertos
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
SOURCES := $(SOURCES) $(shell find "$(RTSRCDIR)" -type f -name '*.d')

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).exe
else
    TARGET = $(TARGETDIR)/$(TARGETNAME)
endif

ifeq ($(COMPILER),ldc)
    DC ?= ldc2
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
    else ifeq ($(ARCH),arm)
        ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=arm-none-eabihf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=armv7-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=armv7-linux-gnueabihf
        endif
        ifeq ($(PLATFORM),cortex-a7)
            DFLAGS := $(DFLAGS) -mcpu=cortex-a7
        endif
    else ifeq ($(ARCH),riscv64)
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf
        ifeq ($(PLATFORM),c906)
            DFLAGS := $(DFLAGS) -mcpu=c906 -mattr=+m,+a,+f,+d,+c,+v
        else ifeq ($(PLATFORM),k210)
            DFLAGS := $(DFLAGS) -march=rv64imafdc -mattr=+zicsr,+zifencei # no vector!
        endif
    else ifeq ($(ARCH),riscv)
        DFLAGS := $(DFLAGS) -mtriple=riscv32-unknown-elf
        ifeq ($(PLATFORM),esp32-p4) # ESP32-P4's weird 32-bit version...
            DFLAGS := $(DFLAGS) -march=rv32imafdcv
        else ifeq ($(PLATFORM),e902)
            DFLAGS := $(DFLAGS) -march=rv32emc -mabi=ilp32e
        else ifeq ($(PLATFORM),e906)
            DFLAGS := $(DFLAGS) -march=rv32imac -mabi=ilp32 # Apparently C2/C3 doesn't support 'A' flag?
        else ifeq ($(PLATFORM),e907)
            DFLAGS := $(DFLAGS) -march=rv32imafc -mabi=ilp32f
        else
            DFLAGS := $(DFLAGS) -march=rv32
        endif
        # T-Head extensions: -mattr=+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmov,+xtheadmemidx,+xtheadmempair,+xtheadmac,+xtheadcmo,+xtheadsync,+xtheadfmemidx
    else
        $(error "Unsupported platform: $(PLATFORM)")
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release -O3 -enable-inlining
    else
        DFLAGS := $(DFLAGS) -g -d-debug
    endif

    COMPILE_CMD = "$(DC)" $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(SOURCES)
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

# Note: LDC's -deps format is not compatible with Make (it's a custom D module dependency format)
# so we don't use -include here. The build will rebuild everything when any file changes.

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
	$(COMPILE_CMD)
ifeq ($(ROUTEROS_BUILD),1)
	@$(MAKE) --no-print-directory routeros-container
	@$(MAKE) --no-print-directory routeros-tar
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
