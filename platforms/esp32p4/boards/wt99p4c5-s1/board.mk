# Wireless-Tag WT99P4C5-S1: a WT0132P4-A1 module (ESP32-P4 N16R32) on a carrier with
# an IP101GRI Ethernet PHY, an ESP32-C5-WROOM-1 over SDIO, RS485, and an SD slot.
# BOARD_PLATFORM pins the pre-v3.0 silicon family; the part reads as v1.0.
# No feature overrides: this board keeps the normal full OpenWatt image.
BOARD_PLATFORM := esp32-p4
BOARD_FLASH_SIZE := 16MB
BOARD_PSRAM_SIZE := 32MB
