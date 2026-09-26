# mcudev DevEBox STM32H7XX_M V2.0: STM32H743VIT6, 25 MHz HSE, 8 MB QSPI W25Q64, microSD.
# Hold K1 (PE3, active low) through reset for the ROM DFU bootloader; there is no BOOT button.
BOARD_PLATFORM := stm32h7
BOARD_FLASH_SIZE := 2MB
BOARD_PSRAM_SIZE := 0MB
STM32_PART := h743vi
STM32_HSE_HZ := 25000000
STM32_DFU_BUTTON := 67
