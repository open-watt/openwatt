# MikroTik hEX S (RB760iGS): MT7621A, 256MB DDR3, 16MB SPI NOR, MT7530 ports 0-4 as ether1..ether5,
# sfp1 on GE2 through a SerDes PHY at MDIO 7, buzzer on GPIO15, power LED on GPIO16.
# RouterBOOT loads the ELF, over the network or as the `kernel` file in flash.
BOARD_PLATFORM := mt7621
BOARD_FLASH_SIZE := 16MB
BOARD_PSRAM_SIZE := 0MB
BOARD_RAM_SIZE := 256MB
BOARD_CPU_HZ := 880000000

ifneq ($(VERSIONS),)
    VERSIONS := $(VERSIONS),RouterBoot
else
    VERSIONS := RouterBoot
endif
