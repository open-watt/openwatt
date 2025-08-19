PLATFORM ?= x86_64
CONFIG ?= debug
COMPILER ?= dmd

ifeq ($(PLATFORM),esp8266)
    # ESP8266 has no FPU!
    ARCH = xtensa
    PLATFORM = l106
    OS = freertos
else ifeq ($(PLATFORM),esp32)
    ARCH = xtensa
    PLATFORM = lx6
    OS = freertos
else ifeq ($(PLATFORM),esp32-s2)
    ARCH = xtensa
    PLATFORM = lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-s3)
    ARCH = xtensa
    PLATFORM = lx7
    OS = freertos
else ifeq ($(PLATFORM),esp32-h2)
    PLATFORM = e906
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),esp32-c2)
    PLATFORM = e906
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),esp32-c3)
    PLATFORM = e906
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),esp32-c5)
    PLATFORM = e907
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),esp32-c6)
    PLATFORM = e907
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),esp32-p4)
    # P4 is apparently 32bit variant of c906, but it does have double and 64bit data paths for vectors...
    # can we have some clarity here?
    PLATFORM = c906
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),stm7xx)
    PLATFORM = cortex-a7
    ARCH = arm
    OS = freertos
else ifeq ($(PLATFORM),stm4xx)
    PLATFORM = cortex-a7
    ARCH = arm
    OS = freertos
else ifeq ($(PLATFORM),k210)
    # K210 is RV64GC, 400mhz x2 (dual core) 
    ARCH = riscv64
    OS = freertos
else ifeq ($(PLATFORM),c906)
    # C906 is RV64GCV, 480mhz (D0 (main) core in BL808)
    ARCH = riscv64
    OS = freertos
else ifeq ($(PLATFORM),e902)
    # E902 is RV32EMC, no FPU!
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),e906)
    # E906 is RV32IMC, no FPU!
    ARCH = riscv
    OS = freertos
else ifeq ($(PLATFORM),e907)
    # E907 is RV32IMAFCP, 320mhz (M0 core in BL808)
    ARCH = riscv
    OS = freertos
else
    ARCH ?= $(PLATFORM)
    OS ?= ubuntu
endif

RTSRCDIR := third_party/urt/src
SRCDIR := src
OBJDIR := obj/$(PLATFORM)_$(CONFIG)
TARGETDIR := bin/$(PLATFORM)_$(CONFIG)
TARGETNAME := openwatt
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
    DFLAGS := $(DFLAGS) -I $(RTSRCDIR) -I $(SRCDIR)

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
        ifeq ($(PLATFORM),c906) # ESP32-P4's weird 32-bit version...
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
    DFLAGS := $(DFLAGS) -I=$(RTSRCDIR) -I=$(SRCDIR)

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

-include $(DEPFILE)

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
	$(COMPILE_CMD)

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
