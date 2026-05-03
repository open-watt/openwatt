set(ESP32_SYS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/urt/src/urt/driver/esp32")

set(MAIN_PRIV_REQUIRES esp_hal_uart esp_rom esp_wifi esp_event esp_driver_gpio driver nvs_flash bt)
if(USE_LWIP)
    list(APPEND MAIN_PRIV_REQUIRES esp_netif lwip)
endif()

idf_component_register(SRCS "${ESP32_SYS_DIR}/main.c" "${ESP32_SYS_DIR}/ow_shim.c"
                       INCLUDE_DIRS ""
                       PRIV_REQUIRES ${MAIN_PRIV_REQUIRES}
                       WHOLE_ARCHIVE)

# Path to LDC-compiled OpenWatt object file (passed in from make)
if(NOT DEFINED OPENWATT_OBJ)
    set(OPENWATT_OBJ "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin/esp32-s3_debug/openwatt")
endif()

# Link D object. -u main pulls the object in; -Wl,--no-check-sections around it
# prevents the linker from dropping TLS sections that are only referenced via relocations.
# Suppress misaligned literal warnings from LLVM-generated Xtensa code (l32r alignment)
target_link_libraries(${COMPONENT_LIB} INTERFACE
    "-u main" "-Wl,--no-check-sections" "${OPENWATT_OBJ}")

if(USE_LWIP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_USE_LWIP)
endif()

message(STATUS "Linking OpenWatt D object: ${OPENWATT_OBJ}")
