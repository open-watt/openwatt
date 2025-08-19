OS ?= ubuntu
PLATFORM ?= x86_64
CONFIG ?= debug
COMPILER ?= dmd

RTSRCDIR := third_party/urt/src
SRCDIR := src
OBJDIR := obj/$(PLATFORM)_$(CONFIG)
TARGETDIR := bin/$(PLATFORM)_$(CONFIG)
TARGETNAME := openwatt
DEPFILE = $(OBJDIR)/$(TARGETNAME).d

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=nosharedaccess -preview=in

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

    ifeq ($(PLATFORM),x86_64)
#        DFLAGS := $(DFLAGS) -mtriple=x86_64-linux-gnu
    else ifeq ($(PLATFORM),x86)
        ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=i686-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=i686-linux-gnu
        endif
    else ifeq ($(PLATFORM),arm64)
        DFLAGS := $(DFLAGS) -mtriple=aarch64-linux-gnu
    else ifeq ($(PLATFORM),arm)
        DFLAGS := $(DFLAGS) -mtriple=arm-linux-eabihf -mcpu=cortex-a7
    else ifeq ($(PLATFORM),riscv64)
        # we are building the Sipeed M1s device... which is BL808 as I understand
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf -mcpu=c906 -mattr=+m,+a,+f,+c,+v
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

    ifeq ($(PLATFORM),x86_64)
#        DFLAGS := $(DFLAGS) -m64
    else ifeq ($(PLATFORM),x86)
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
