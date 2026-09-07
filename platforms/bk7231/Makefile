PLATFORM  ?= bk7231n
BUILDDIR ?= build/$(PLATFORM)
OUTPUT   ?= $(BUILDDIR)/libbeken.a

BK_SDK_ROOT ?= ../../../OpenBK7231T_App

ifeq ($(PLATFORM),bk7231n)
    BK_SDK := $(BK_SDK_ROOT)/sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378
else ifeq ($(PLATFORM),bk7231t)
    BK_SDK := $(BK_SDK_ROOT)/sdk/OpenBK7231T/platforms/bk7231t/bk7231t_os/beken378
endif

CC      := arm-none-eabi-gcc
AR      := arm-none-eabi-ar

CFLAGS  := -mcpu=arm968e-s -marm -mfloat-abi=soft
CFLAGS  += -Os -g
CFLAGS  += -ffunction-sections -fdata-sections
CFLAGS  += -fno-strict-aliasing
CFLAGS  += -Wall -Wno-unused-parameter -Wno-missing-field-initializers
CFLAGS  += -Wno-unused-variable -Wno-unused-function
CFLAGS  += -Wno-implicit-function-declaration -Wno-sign-compare
CFLAGS  += -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-pointer-sign
CFLAGS  += -std=gnu99

SOC_COMMON := -DSOC_BK7231=1 -DSOC_BK7231U=2 -DSOC_BK7221U=3

ifeq ($(PLATFORM),bk7231n)
    SOC_DEF := $(SOC_COMMON) -DSOC_BK7231N=5
else ifeq ($(PLATFORM),bk7231t)
    SOC_DEF := $(SOC_COMMON)
endif

CFLAGS += $(SOC_DEF)
CFLAGS += -DCFG_SUPPORT_ALIOS=0 -DCFG_SUPPORT_RTT=0 -DCFG_OS_FREERTOS=1
# lsig_monitor.c uses AliOS-only WLAN_ENC_* enums unconditionally.
CFLAGS += -DWLAN_ENC_OPEN=0 -DWLAN_ENC_WEP=1 -DWLAN_ENC_CCMP=2 -DWLAN_ENC_TKIP=3

S := $(BK_SDK)

CFLAGS += -I$(S)/common
CFLAGS += -I$(S)/app -I$(S)/app/config
CFLAGS += -I$(S)/app/standalone-station -I$(S)/app/standalone-ap
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
CFLAGS += -I$(S)/driver/include -I$(S)/driver/common/reg -I$(S)/driver/common
CFLAGS += -I$(S)/driver/entry -I$(S)/driver/dma -I$(S)/driver/intc
CFLAGS += -I$(S)/driver/phy -I$(S)/driver/pwm -I$(S)/driver/rc_beken
CFLAGS += -I$(S)/driver/flash -I$(S)/driver/rw_pub -I$(S)/driver/uart
CFLAGS += -I$(S)/driver/sys_ctrl -I$(S)/driver/gpio -I$(S)/driver/general_dma
CFLAGS += -I$(S)/driver/spidma -I$(S)/driver/icu -I$(S)/driver/i2c
CFLAGS += -I$(S)/func/include -I$(S)/func/misc -I$(S)/func/rf_test
CFLAGS += -I$(S)/func/bk7011_cal -I$(S)/func/user_driver -I$(S)/func/power_save
CFLAGS += -I$(S)/func/uart_debug -I$(S)/func/ethernet_intf -I$(S)/func/rwnx_intf
CFLAGS += -I$(S)/func/joint_up -I$(S)/func/temp_detect -I$(S)/func/spidma_intf
CFLAGS += -I$(S)/func/hostapd-2.5/hostapd -I$(S)/func/hostapd-2.5/bk_patch
CFLAGS += -I$(S)/func/hostapd-2.5/src/utils -I$(S)/func/hostapd-2.5/src/ap
CFLAGS += -I$(S)/func/hostapd-2.5/src/common -I$(S)/func/hostapd-2.5/src/drivers
CFLAGS += -I$(S)/func/hostapd-2.5/src
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/port
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/src/include
CFLAGS += -I$(S)/func/lwip_intf/lwip-2.0.2/src/include/lwip
CFLAGS += -I$(S)/os/include
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/include
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/portable/Keil/ARM968es
CFLAGS += -I$(S)/os/FreeRTOSv9.0.0
ifeq ($(PLATFORM),bk7231n)
CFLAGS += $(shell find $(S)/driver/ble_5_x_rw -type d 2>/dev/null | sed 's|^|-I|')
else
CFLAGS += $(shell find $(S)/driver/ble -type d 2>/dev/null | sed 's|^|-I|')
endif

SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/tasks.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/queue.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/list.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/timers.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/event_groups.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/croutine.c
SRCS += $(S)/os/FreeRTOSv9.0.0/FreeRTOS/Source/portable/Keil/ARM968es/port.c
SRCS += $(S)/os/FreeRTOSv9.0.0/rtos_pub.c
SRCS += $(S)/os/mem_arch.c
SRCS += $(S)/os/str_arch.c
SRCS += $(S)/os/platform_stub.c

SRCS += $(S)/app/ate_app.c
SRCS += $(S)/app/standalone-ap/sa_ap.c
SRCS += $(S)/app/standalone-station/sa_station.c
SRCS += $(S)/driver/i2c/i2c1.c
SRCS += $(S)/driver/i2c/i2c2.c
SRCS += $(S)/func/hostapd-2.5/bk_patch/fake_socket.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ap_drv_ops.c
SRCS += $(S)/func/hostapd-2.5/src/ap/drv_callbacks.c
SRCS += $(S)/func/hostapd-2.5/src/ap/hw_features.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ieee802_11_ht.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ieee802_11_shared.c
SRCS += $(S)/func/hostapd-2.5/src/ap/wmm.c
SRCS += $(S)/func/hostapd-2.5/src/common/hw_features_common.c
SRCS += $(S)/func/hostapd-2.5/src/common/ieee802_11_common.c
SRCS += $(S)/func/hostapd-2.5/src/rsn_supp/wpa_ie.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/events.c
SRCS += $(S)/func/misc/start_type.c
SRCS += $(S)/func/uart_debug/cmd_evm.c
SRCS += $(S)/func/uart_debug/cmd_rx_sensitivity.c
SRCS += $(S)/func/user_driver/BkDriverFlash.c
SRCS += $(S)/func/user_driver/BkDriverRng.c

URT_BK := ../../third_party/urt/src/urt/driver/bk7231
SHIM_SRCS := $(URT_BK)/ow_rw.c $(URT_BK)/ow_shim.c

SRCS += $(S)/driver/common/dd.c
SRCS += $(S)/driver/common/drv_model.c
SRCS += $(S)/driver/dma/dma.c
SRCS += $(S)/driver/driver.c
SRCS += $(S)/driver/entry/arch_main.c
SRCS += $(S)/driver/flash/flash.c
ifeq ($(PLATFORM),bk7231t)
SRCS += $(S)/driver/fft/fft.c
SRCS += $(S)/driver/i2s/i2s.c
endif
SRCS += $(S)/driver/general_dma/general_dma.c
SRCS += $(S)/driver/gpio/gpio.c
SRCS += $(S)/driver/icu/icu.c
SRCS += $(S)/driver/intc/intc.c
SRCS += $(S)/driver/irda/irda.c
SRCS += $(S)/driver/macphy_bypass/mac_phy_bypass.c
SRCS += $(S)/driver/phy/phy_trident.c
SRCS += $(S)/driver/pwm/pwm.c
ifeq ($(PLATFORM),bk7231n)
SRCS += $(S)/driver/pwm/pwm_new.c
endif
SRCS += $(S)/driver/pwm/mcu_ps_timer.c
SRCS += $(S)/driver/pwm/bk_timer.c
SRCS += $(S)/driver/rw_pub/rw_platf_pub.c
SRCS += $(S)/driver/saradc/saradc.c
ifeq ($(PLATFORM),bk7231t)
SRCS += $(S)/driver/spi/spi.c
SRCS += $(S)/driver/ble/ble.c
SRCS += $(S)/driver/ble/ble_pub/ip/ble/hl/src/prf/prf.c
SRCS += $(S)/driver/ble/ble_pub/ip/ble/profiles/sdp/src/sdp_service.c
SRCS += $(S)/driver/ble/ble_pub/ip/ble/profiles/sdp/src/sdp_service_task.c
SRCS += $(S)/driver/ble/ble_pub/ip/ble/profiles/comm/src/comm.c
SRCS += $(S)/driver/ble/ble_pub/ip/ble/profiles/comm/src/comm_task.c
SRCS += $(S)/driver/ble/ble_pub/modules/app/src/app_ble.c
SRCS += $(S)/driver/ble/ble_pub/modules/app/src/app_task.c
SRCS += $(S)/driver/ble/ble_pub/modules/app/src/app_sdp.c
SRCS += $(S)/driver/ble/ble_pub/modules/app/src/app_sec.c
SRCS += $(S)/driver/ble/ble_pub/modules/app/src/app_comm.c
SRCS += $(S)/driver/ble/ble_pub/modules/common/src/common_list.c
SRCS += $(S)/driver/ble/ble_pub/modules/common/src/common_utils.c
SRCS += $(S)/driver/ble/ble_pub/modules/common/src/RomCallFlash.c
SRCS += $(S)/driver/ble/ble_pub/modules/dbg/src/dbg.c
SRCS += $(S)/driver/ble/ble_pub/modules/dbg/src/dbg_mwsgen.c
SRCS += $(S)/driver/ble/ble_pub/modules/dbg/src/dbg_swdiag.c
SRCS += $(S)/driver/ble/ble_pub/modules/dbg/src/dbg_task.c
SRCS += $(S)/driver/ble/ble_pub/modules/rwip/src/rwip.c
SRCS += $(S)/driver/ble/ble_pub/modules/rf/src/ble_rf_xvr.c
SRCS += $(S)/driver/ble/ble_pub/modules/ecc_p256/src/ecc_p256.c
SRCS += $(S)/driver/ble/ble_pub/plf/refip/src/driver/uart/uart.c
endif
SRCS += $(S)/driver/spidma/spidma.c
SRCS += $(S)/driver/sys_ctrl/sys_ctrl.c
SRCS += $(S)/driver/uart/Retarget.c
SRCS += $(S)/driver/uart/uart_bk.c
SRCS += $(S)/driver/wdt/wdt.c

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

SRCS += $(S)/func/func.c
SRCS += $(S)/func/rwnx_intf/rw_ieee80211.c
SRCS += $(S)/func/rwnx_intf/rw_msdu.c
SRCS += $(S)/func/rwnx_intf/rw_msg_rx.c
SRCS += $(S)/func/rwnx_intf/rw_msg_tx.c
SRCS += $(S)/func/joint_up/role_launch.c
SRCS += $(S)/func/hostapd_intf/hostapd_intf.c

SRCS += $(S)/func/wlan_ui/wlan_ui.c
SRCS += $(S)/func/wlan_ui/lsig_monitor.c

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
SRCS += $(S)/func/hostapd-2.5/bk_patch/ddrv.c
SRCS += $(S)/func/hostapd-2.5/bk_patch/signal.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/aes-internal.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/aes-internal-dec.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/aes-internal-enc.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/aes-unwrap.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/aes-wrap.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/bk_md5.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/md5-internal.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/rc4.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/bk_sha1.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/sha1-internal.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/sha1-pbkdf2.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/sha1-prf.c
SRCS += $(S)/func/hostapd-2.5/src/crypto/tls_none.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ap_mlme.c
SRCS += $(S)/func/hostapd-2.5/src/ap/ieee802_1x.c
SRCS += $(S)/func/hostapd-2.5/src/ap/tkip_countermeasures.c
SRCS += $(S)/func/hostapd-2.5/src/ap/utils.c
SRCS += $(S)/func/hostapd-2.5/src/ap/wpa_auth_ie.c
SRCS += $(S)/func/hostapd-2.5/src/drivers/drivers.c
SRCS += $(S)/func/hostapd-2.5/src/utils/common.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/blacklist.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/bss.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/notify.c
SRCS += $(S)/func/hostapd-2.5/wpa_supplicant/wmm_ac.c

ifeq ($(PLATFORM),bk7231n)
SRCS += $(S)/func/bk7011_cal/bk7231N_cal.c
else
SRCS += $(S)/func/bk7011_cal/bk7231U_cal.c
endif
SRCS += $(S)/func/bk7011_cal/manual_cal_bk7231U.c

SRCS += $(S)/func/power_save/power_save.c
SRCS += $(S)/func/power_save/manual_ps.c
SRCS += $(S)/func/power_save/mcu_ps.c
SRCS += $(S)/func/misc/fake_clock.c
SRCS += $(S)/func/misc/target_util.c
SRCS += $(S)/func/rf_test/tx_evm.c
SRCS += $(S)/func/rf_test/rx_sensitivity.c
SRCS += $(S)/func/temp_detect/temp_detect.c
SRCS += $(S)/func/net_param_intf/net_param.c

SRCS += $(S)/app/app_bk.c
SRCS += $(S)/app/config/param_config.c

OBJS := $(patsubst $(S)/%.c,$(BUILDDIR)/%.o,$(SRCS))
OBJS += $(patsubst $(URT_BK)/%.c,$(BUILDDIR)/urt/%.o,$(SHIM_SRCS))

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(OBJS)
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $^

$(BUILDDIR)/%.o: $(S)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILDDIR)/urt/%.o: $(URT_BK)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build/
