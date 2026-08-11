# SmartEVSE v3.0: ESP32-D0WD-V3, 4 MB flash, no PSRAM.
# A focused EVSE controller does not need the general control plane by default.
BOARD_PLATFORM := esp32
BOARD_FLASH_SIZE := 4MB
BOARD_PSRAM_SIZE := 0MB
FEATURES ?= switch
HEADLESS ?= 1
TINY ?= 1

ifneq ($(VERSIONS),)
    VERSIONS := $(VERSIONS),SmartEVSE,SmartEVSE_v30
else
    VERSIONS := SmartEVSE,SmartEVSE_v30
endif
