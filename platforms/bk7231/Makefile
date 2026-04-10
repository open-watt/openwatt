# Beken BK7231 SDK build -- FreeRTOS + drivers + lwIP
#
# Builds everything the WiFi/BLE blobs need into a single libbeken.a.
# Source files and headers come from the external SDK.
#
# Usage:
#   make PLATFORM=bk7231n
#   make PLATFORM=bk7231t
#   make clean
#
# SDK layout expected at BK_SDK_ROOT:
#   sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/
#   sdk/OpenBK7231T/platforms/bk7231t/bk7231t_os/beken378/

PLATFORM  ?= bk7231n
BUILDDIR ?= build/$(PLATFORM)
OUTPUT   ?= $(BUILDDIR)/libbeken.a

# ── SDK paths ────────────────────────────────────────────────────────
BK_SDK_ROOT ?= ../../../OpenBK7231T_App

ifeq ($(PLATFORM),bk7231n)
    BK_SDK := $(BK_SDK_ROOT)/sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378
else ifeq ($(PLATFORM),bk7231t)
    BK_SDK := $(BK_SDK_ROOT)/sdk/OpenBK7231T/platforms/bk7231t/bk7231t_os/beken378
endif

# ── Toolchain ────────────────────────────────────────────────────────
CC      := arm-none-eabi-gcc
AR      := arm-none-eabi-ar
AS      := arm-none-eabi-gcc

CFLAGS  := -mcpu=arm968e-s -marm -mfloat-abi=soft
CFLAGS  += -Os -g
CFLAGS  += -ffunction-sections -fdata-sections
CFLAGS  += -fno-strict-aliasing
CFLAGS  += -Wall -Wno-unused-parameter -Wno-missing-field-initializers
CFLAGS  += -Wno-unused-variable -Wno-unused-function
CFLAGS  += -Wno-implicit-function-declaration -Wno-sign-compare
CFLAGS  += -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-pointer-sign
CFLAGS  += -std=gnu99

ASFLAGS := -mcpu=arm968e-s -marm -mfloat-abi=soft

# ── SOC defines ──────────────────────────────────────────────────────
SOC_COMMON := -DSOC_BK7231=1 -DSOC_BK7231U=2 -DSOC_BK7221U=3

ifeq ($(PLATFORM),bk7231n)
    SOC_DEF := $(SOC_COMMON) -DSOC_BK7231N=5 -DCFG_SOC_NAME=5
else ifeq ($(PLATFORM),bk7231t)
    SOC_DEF := $(SOC_COMMON) -DCFG_SOC_NAME=2
endif

CFLAGS += $(SOC_DEF)
# Most CFG_* flags come from SDK's sys_config.h. Only override what we need.
CFLAGS += -DCFG_SUPPORT_ALIOS=0 -DCFG_SUPPORT_RTT=0 -DCFG_OS_FREERTOS=1
# SDK bug: lsig_monitor.c uses AliOS-only WLAN_ENC_* enums unconditionally
CFLAGS += -DWLAN_ENC_OPEN=0 -DWLAN_ENC_WEP=1 -DWLAN_ENC_CCMP=2 -DWLAN_ENC_TKIP=3

# ── Include paths (from SDK application.mk) ──────────────────────────
S := $(BK_SDK)

CFLAGS += -I$(S)/common
CFLAGS += -I$(S)/app -I$(S)/app/config
CFLAGS += -I$(S)/app/standalone-station -I$(S)/app/standalone-ap
# IP stack headers
CFLAGS += -I$(S)/ip/common -I$(S)/ip/ke -I$(S)/ip/mac
CFLAGS += -I$(S)/ip/lmac/src/hal -I$(S)/ip/lmac/src/mm -I$(S)/ip/lmac/src/ps
CFLAGS += -I$(S)/ip/lmac/src/rd -I$(S)/ip/lmac/src/rwnx -I$(S)/ip/lmac/src/rx
CFLAGS += -I$(S)/ip/lmac/src/scan -I$(S)/ip/lmac/src/sta -I$(S)/ip/lmac/src/tx
CFLAGS += -I$(S)/ip/lmac/src/vif -I$(S)/ip/lmac/src/rx/rxl -I$(S)/ip/lmac/src/tx/txl
CFLAGS += -I$(S)/ip/lmac/src/p2p -I$(S)/ip/lmac/src/chan -I$(S)/ip/lmac/src/td
CFLAGS += -I$(S)/ip/lmac/src/tpc -I$(S)/ip/lmac/src/tdls
CFLAGS += -I$(S)/ip/umac/src/mesh -I$(S)/ip/umac/src/rc -I$(S)/ip/umac/src/apm
CFLAGS += -I$(S)/ip/umac/src/bam -I$(S)/ip/umac/src/llc -I$(S)/ip/umac/src/me
CFLAGS += -I$(S)/ip/umac/src/rxu -I$(S)/ip/umac/src/scanu -I$(S)/ip/umac/src/sm
CFLAGS += -I$(S)/ip/umac/src/txu
# Driver headers
CFLAGS += -I$(S)/driver/include -I$(S)/driver/common/reg -I$(S)/driver/common
CFLAGS += -I$(S)/driver/entry -I$(S)/driver/dma -I$(S)/driver/intc
CFLAGS += -I$(S)/driver/phy -I$(S)/driver/pwm -I$(S)/driver/rc_beken
CFLAGS += -I$(S)/driver/flash -I$(S)/driver/rw_pub -I$(S)/driver/uart
CFLAGS += -I$(S)/driver/sys_ctrl -I$(S)/driver/gpio -I$(S)/driver/general_dma
CFLAGS += -I$(S)/driver/spidma -I$(S)/driver/icu -I$(S)/driver/i2c
# Func headers
CFLAGS += -I$(S)/func/include -I$(S)/func/misc -I$(S)/func/rf_test
CFLAGS += -I$(S)/func/bk7011_cal -I$(S)/func/user_driver -I$(S)/func/power_save
CFLAGS += -I$(S)/func/uart_debug -I$(S)/func/ethernet_intf -I$(S)/func/rwnx_intf
CFLAGS += -I$(S)/func/joint_up -I$(S)/func/temp_detect -I$(S)/func/spidma_intf
CFLAGS += -I$(S)/func/hostapd-2.5/hostapd -I$(S)/func/hostapd-2.5/bk_patch
CFLAGS += -I$(S)/func/hostapd-2.5/src/utils -I$(S)/func/hostapd-2.5/src/ap
CFLAGS += -I$(S)/func/hostapd-2.5/src/common -I$(S)/func/hostapd-2.5/src/drivers
CFLAGS += -I$(S)/func/hostapd-2.5/src
# lwIP
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/port
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/src/include
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/src/include/lwip
# FreeRTOS
CFLAGS += -I$(S)/os/include
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/include
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/portable/Keil/ARM968es
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0
# BLE 5.x (all subdirs -- the BLE stack headers are deeply nested)
CFLAGS += $(shell find $(S)/driver/ble_5_x_rw -type d 2>/dev/null | sed 's|^|-I|')

# ── Source files (from SDK application.mk, uncommented SRC_C) ────────
# Using the SDK's own file list ensures we compile exactly what the
# blobs expect. Paths are relative to $(BK_SDK).

# FreeRTOS kernel
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/tasks.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/queue.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/list.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/timers.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/event_groups.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/croutine.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/portable/Keil/ARM968es/port.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/portable/MemMang/heap_4.c
SRCS += $(S)/os/FreeRTOSv9.0.0/rtos_pub.c
SRCS += $(S)/os/mem_arch.c
SRCS += $(S)/os/str_arch.c
SRCS += $(S)/os/platform_stub.c

ASM_SRCS += portasm.s

# Drivers
SRCS += $(S)/driver/common/dd.c
SRCS += $(S)/driver/common/drv_model.c
SRCS += $(S)/driver/dma/dma.c
SRCS += $(S)/driver/driver.c
SRCS += $(S)/driver/entry/arch_main.c
SRCS += $(S)/driver/flash/flash.c
SRCS += $(S)/driver/general_dma/general_dma.c
SRCS += $(S)/driver/gpio/gpio.c
SRCS += $(S)/driver/icu/icu.c
SRCS += $(S)/driver/intc/intc.c
SRCS += $(S)/driver/irda/irda.c
SRCS += $(S)/driver/macphy_bypass/mac_phy_bypass.c
SRCS += $(S)/driver/phy/phy_trident.c
SRCS += $(S)/driver/pwm/pwm.c
SRCS += $(S)/driver/pwm/pwm_new.c
SRCS += $(S)/driver/pwm/mcu_ps_timer.c
SRCS += $(S)/driver/pwm/bk_timer.c
SRCS += $(S)/driver/rw_pub/rw_platf_pub.c
SRCS += $(S)/driver/saradc/saradc.c
SRCS += $(S)/driver/spidma/spidma.c
SRCS += $(S)/driver/sys_ctrl/sys_ctrl.c
SRCS += $(S)/driver/uart/Retarget.c
SRCS += $(S)/driver/uart/uart_bk.c
SRCS += $(S)/driver/wdt/wdt.c

# BLE 5.x glue (BK7231N) -- stack itself is in libble.a
ifeq ($(PLATFORM),bk7231n)
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/entry/ble_main.c
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/rwip/src/rwip.c
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/rwip/src/rwble.c
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/driver/rf/rf_xvr.c
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/driver/rf/ble_rf_port.c
SRCS += $(S)/driver/ble_5_x_rw/platform/7231n/driver/uart/uart_ble.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/prf/prf.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/prf/prf_utils.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/profiles/comm/src/comm.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/profiles/comm/src/comm_task.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/app/src/app_ble.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/app/src/app_ble_task.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/app/src/app_comm.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/app/src/app_task.c
SRCS += $(S)/driver/ble_5_x_rw/ble_pub/ui/ble_ui.c
endif

# Func: WiFi MAC glue
SRCS += $(S)/func/func.c
SRCS += $(S)/func/rwnx_intf/rw_ieee80211.c
SRCS += $(S)/func/rwnx_intf/rw_msdu.c
SRCS += $(S)/func/rwnx_intf/rw_msg_rx.c
SRCS += $(S)/func/rwnx_intf/rw_msg_tx.c
SRCS += $(S)/func/joint_up/role_launch.c
SRCS += $(S)/func/hostapd_intf/hostapd_intf.c

# Func: WiFi UI
SRCS += $(S)/func/wlan_ui/wlan_ui.c
SRCS += $(S)/func/wlan_ui/lsig_monitor.c

# Func: WPA supplicant
SRCS += $(S)/func/hostapd-2.5/bk_patch/sk_intf.c
SRCS += $(S)/func/hostapd-2.5/hostapd/main_none.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ap_config.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ap_list.c
SRCS += $(S)/func/hostapd-2.5/src/ap/beacon.c
SRCS += $(S)/func/hostapd-2.5/src/ap/hostapd.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ieee802_11.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ieee802_11_auth.c
SRCS += $(S)/func/hostapd-2.5/src/ap/sta_info.c
SRCS += $(S)/func/hostapd-2.5/src/ap/wpa_auth.c
SRCS += $(S)/func/hostapd-2.5/src/ap/wpa_auth_glue.c
SRCS += $(S)/func/hostapd-2.5/src/common/wpa_common.c
SRCS += $(S)/func/hostapd-2.5/src/drivers/driver_beken.c
SRCS += $(S)/func/hostapd-2.5/src/drivers/driver_common.c
SRCS += $(S)/func/hostapd-2.5/src/l2_packet/l2_packet_none.c
SRCS += $(S)/func/hostapd-2.5/src/rsn_supp/wpa.c
SRCS += $(S)/func/hostapd-2.5/src/utils/eloop.c
SRCS += $(S)/func/hostapd-2.5/src/utils/os_none.c
SRCS += $(S)/func/hostapd-2.5/src/utils/wpabuf.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/config.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/config_none.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/main_supplicant.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/wpas_glue.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/wpa_scan.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/wpa_supplicant.c

# Func: RF calibration
ifeq ($(PLATFORM),bk7231n)
SRCS += $(S)/func/bk7011_cal/bk7231N_cal.c
else
SRCS += $(S)/func/bk7011_cal/bk7221U_cal.c
endif
SRCS += $(S)/func/bk7011_cal/manual_cal_bk7231U.c

# Func: power save, misc
SRCS += $(S)/func/power_save/power_save.c
SRCS += $(S)/func/power_save/manual_ps.c
SRCS += $(S)/func/power_save/mcu_ps.c
SRCS += $(S)/func/misc/fake_clock.c
SRCS += $(S)/func/misc/target_util.c
SRCS += $(S)/func/rf_test/tx_evm.c
SRCS += $(S)/func/rf_test/rx_sensitivity.c
SRCS += $(S)/func/temp_detect/temp_detect.c
SRCS += $(S)/func/net_param_intf/net_param.c

# Func: lwIP
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/port/ethernetif.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/port/net.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/def.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/dns.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/inet_chksum.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/init.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ip.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/mem.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/memp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/netif.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/pbuf.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/tcp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/tcp_in.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/tcp_out.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/timeouts.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/udp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/autoip.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/dhcp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/etharp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/icmp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/igmp.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/ip4.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/ip4_addr.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/core/ipv4/ip4_frag.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/netif/ethernet.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/tcpip.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/sockets.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/netbuf.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/api_msg.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/api_lib.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/netdb.c
SRCS += $(S)/func/lwip_intf/lwip-2.0.2/src/api/err.c
SRCS += $(S)/func/lwip_intf/dhcpd/dhcp-server.c
SRCS += $(S)/func/lwip_intf/dhcpd/dhcp-server-main.c

# App layer (entry point, config)
SRCS += $(S)/app/app_bk.c
SRCS += $(S)/app/config/param_config.c

# Assembly (portasm needs GNU AS conversion -- use our local copy)
# The SDK ships Keil ARMASM syntax; we maintain a GNU AS version.
ASM_DIR := asm

OBJS := $(patsubst $(S)/%.c,$(BUILDDIR)/%.o,$(SRCS))
OBJS += $(patsubst %.s,$(BUILDDIR)/%.o,$(ASM_SRCS))

# ── Rules ────────────────────────────────────────────────────────────

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(OBJS)
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $^

$(BUILDDIR)/%.o: $(S)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILDDIR)/%.o: $(ASM_DIR)/%.s
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) -c $< -o $@

clean:
	rm -rf build/
