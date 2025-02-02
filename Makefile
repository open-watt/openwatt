SRCDIR := src
OBJDIR := obj/linux
TARGETDIR := bin/linux
TARGETNAME := enms
TARGET := $(TARGETDIR)/$(TARGETNAME)

config ?= debug
D_COMPILER ?= dmd

SOURCES := $(shell find $(SRCDIR) -type f -name '*.d')
DEPFILE := $(OBJDIR)/$(TARGETNAME).d

ifeq ($(D_COMPILER),dmd)
	DFLAGS := -I=$(SRCDIR) -preview=bitfields -preview=rvaluerefparam -preview=nosharedaccess -preview=in
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
	DFLAGS := -I $(SRCDIR)
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

-include $(DEPFILE)

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
	$(COMPILE_CMD)

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
