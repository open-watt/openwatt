# Shared main-component config for the ESP32 family. Each variant's
# main/CMakeLists.txt sets the variation knobs below, then includes this file:
#
#   OW_BUILDNAME      (required)  -- bin/<name>_<config>/ subdir, e.g. esp32-s3.
#   OW_EXTRA_REQUIRES (optional)  -- extra component names for PRIV_REQUIRES.
#   OW_NO_WIFI        (optional)  -- set truthy on chips without esp_wifi (h2, p4).

if(NOT DEFINED OW_BUILDNAME)
    message(FATAL_ERROR "esp32-common/main.cmake: OW_BUILDNAME must be set before include()")
endif()

set(ESP32_SYS_DIR    "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/urt/src/urt/driver/esp32")
set(URT_INTERNAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/urt/src/urt/internal")

set(MAIN_PRIV_REQUIRES esp_hal_uart esp_rom esp_event esp_driver_gpio driver nvs_flash mbedtls)
if(NOT OW_NO_WIFI)
    list(APPEND MAIN_PRIV_REQUIRES esp_wifi)
endif()
if(USE_LWIP)
    list(APPEND MAIN_PRIV_REQUIRES esp_netif lwip)
endif()
if(OW_EXTRA_REQUIRES)
    list(APPEND MAIN_PRIV_REQUIRES ${OW_EXTRA_REQUIRES})
endif()

idf_component_register(SRCS "${ESP32_SYS_DIR}/main.c"
                            "${ESP32_SYS_DIR}/ow_shim.c"
                            "${URT_INTERNAL_DIR}/mbedtls.c"
                       INCLUDE_DIRS ""
                       PRIV_REQUIRES ${MAIN_PRIV_REQUIRES}
                       WHOLE_ARCHIVE)

# Makefile typically passes OPENWATT_OBJ via -D; fall back to the debug path
# under bin/<buildname>_debug/ for direct idf.py invocations.
if(NOT DEFINED OPENWATT_OBJ)
    set(OPENWATT_OBJ "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin/${OW_BUILDNAME}_debug/openwatt")
endif()

# -u main pulls the D object in even though nothing in IDF references it.
# -Wl,--no-check-sections suppresses bogus warnings about TLS sections that are
# only reached via relocations rather than direct loads.
target_link_libraries(${COMPONENT_LIB} INTERFACE
    "-u main" "-Wl,--no-check-sections" "${OPENWATT_OBJ}")

if(USE_LWIP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_USE_LWIP)
endif()

message(STATUS "Linking OpenWatt D object: ${OPENWATT_OBJ}")
