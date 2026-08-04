# SmartEVSE v3.0: ESP32-D0WD-V3, 4 MB flash, no PSRAM.
# HTTP provides the setup, API, sync, and OTA control plane.
BOARD_PLATFORM := esp32
BOARD_FLASH_SIZE := 4MB
BOARD_PSRAM_SIZE := 0MB
FEATURES ?= switch-http
HEADLESS ?= 1
TINY ?= 1
IDF_LOG_LEVEL ?= none
PRESERVE_NVS ?= 1
BOARD_OTA_FILENAME := firmware.bin

ifneq ($(VERSIONS),)
    VERSIONS := $(VERSIONS),SmartEVSE,SmartEVSE_v30,NoECSecret
else
    VERSIONS := SmartEVSE,SmartEVSE_v30,NoECSecret
endif
