SRCDIR := src
OBJDIR := build/linux
TARGETDIR := bin/linux
TARGETNAME := enms
TARGET = $(TARGETDIR)/$(TARGETNAME)

config ?= debug
D_COMPILER ?= dmd

ifeq ($(config),unittest)
	TARGETNAME := $(TARGETNAME)_test
endif

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=nosharedaccess -preview=in

SOURCES := $(shell find $(SRCDIR) -type f -name '*.d')
DEPFILE := $(OBJDIR)/$(TARGETNAME).d

ifeq ($(config),arm32)
		D_COMPILER = ldc2
		DFLAGS := $(DFLAGS) -mtriple=arm-unknown-linux-eabihf -march=thumb -mcpu=cortex-a7 -I $(SRCDIR)
#		DFLAGS := $(DFLAGS) -mtriple=thumb-unknown-linux-eabihf -march=thumb -mcpu=cortex-a7 -I $(SRCDIR)
#		ifeq ($(config),debug)
			DFLAGS := $(DFLAGS) -g -d-debug
#		else
#			ifeq ($(config),unittest)
#				DFLAGS := $(DFLAGS) -g -d-debug -unittest
#			else
#				DFLAGS := $(DFLAGS) -O3 -release -enable-inlining
#			endif
#		endif
		COMPILE_CMD = $(D_COMPILER) $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(SOURCES)
else
	ifeq ($(D_COMPILER),dmd)
		DFLAGS := $(DFLAGS) -I=$(SRCDIR)
		ifeq ($(config),debug)
			DFLAGS := $(DFLAGS) -g -debug
		else
			ifeq ($(config),unittest)
				DFLAGS := $(DFLAGS) -g -debug -unittest
			else
				DFLAGS := $(DFLAGS) -O -release -inline
			endif
		endif
		COMPILE_CMD = $(D_COMPILER) $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -makedeps $(SOURCES) > $(DEPFILE)
	else ifeq ($(D_COMPILER),ldc2)
		DFLAGS := $(DFLAGS) -I $(SRCDIR)
		ifeq ($(config),debug)
			DFLAGS := $(DFLAGS) -g -d-debug
		else
			ifeq ($(config),unittest)
				DFLAGS := $(DFLAGS) -g -d-debug -unittest
			else
				DFLAGS := $(DFLAGS) -O3 -release -enable-inlining
			endif
		endif
		COMPILE_CMD = $(D_COMPILER) $(DFLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(SOURCES)
	endif
endif

-include $(DEPFILE)

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
	$(COMPILE_CMD)

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
