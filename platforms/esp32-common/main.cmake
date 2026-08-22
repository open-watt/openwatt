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

set(MAIN_PRIV_REQUIRES esp_hal_uart esp_rom esp_event esp_driver_gpio esp_driver_ledc
                       esp_driver_gptimer esp_adc driver nvs_flash mbedtls)
list(APPEND MAIN_PRIV_REQUIRES esp_driver_i2c)
list(APPEND MAIN_PRIV_REQUIRES esp_driver_spi)
if(NOT OW_NO_WIFI)
    list(APPEND MAIN_PRIV_REQUIRES esp_wifi)
endif()
list(APPEND MAIN_PRIV_REQUIRES esp_driver_twai)
if(USE_LWIP)
    list(APPEND MAIN_PRIV_REQUIRES esp_netif lwip)
endif()
list(APPEND MAIN_PRIV_REQUIRES esp_driver_uart)
list(APPEND MAIN_PRIV_REQUIRES esp_driver_ledc esp_driver_spi esp_driver_gptimer esp_adc)
# Unconditional: IDF collects PRIV_REQUIRES during an early expansion pass that
# cannot see -D cache variables, so gating this on USE_SPIFFS silently drops it.
# The component is only referenced when OW_USE_SPIFFS is defined below, so an
# unused spiffs is discarded at link time.
list(APPEND MAIN_PRIV_REQUIRES spiffs esp_partition)
# Unconditional: requirements are resolved in an early expansion pass that sees
# neither -D project variables nor CONFIG_ values, so anything conditional here
# is simply dropped from the component graph - which left COREDUMP=1 builds
# unable to find esp_core_dump.h. With coredump disabled the component registers
# no sources and no include dirs, so naming it always costs nothing.
list(APPEND MAIN_PRIV_REQUIRES espcoredump)
if(OW_EXTRA_REQUIRES)
    list(APPEND MAIN_PRIV_REQUIRES ${OW_EXTRA_REQUIRES})
endif()

set(LITTLEFS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/urt/third_party/littlefs")

set(ESP32_SYS_SOURCES "${ESP32_SYS_DIR}/main.c"
                      "${ESP32_SYS_DIR}/ow_shim.c"
                      "${ESP32_SYS_DIR}/littlefs_port.c"
                      "${LITTLEFS_DIR}/lfs.c"
                      "${LITTLEFS_DIR}/lfs_util.c"
                      "${URT_INTERNAL_DIR}/mbedtls.c")
if(IDF_LOG_ENABLED)
    list(APPEND ESP32_SYS_SOURCES "${ESP32_SYS_DIR}/idf_log.c")
endif()

idf_component_register(SRCS ${ESP32_SYS_SOURCES}
                       INCLUDE_DIRS ""
                       PRIV_REQUIRES ${MAIN_PRIV_REQUIRES}
                       WHOLE_ARCHIVE)

if(PRESERVE_NVS)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_PRESERVE_NVS)
endif()

if(USE_SPIFFS)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_USE_SPIFFS=1)
endif()

# littlefs talks to esp_partition directly, so it needs no VFS and no newlib.
# LFS_NO_DEBUG/_WARN keep its logging out of the image; asserts stay on.
target_include_directories(${COMPONENT_LIB} PRIVATE "${LITTLEFS_DIR}")
target_compile_definitions(${COMPONENT_LIB} PRIVATE LFS_NO_DEBUG LFS_NO_WARN)
if(USE_LITTLEFS)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_USE_LITTLEFS=1)
endif()
if(OPENWATT_COREDUMP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_ENABLE_COREDUMP=1)
endif()

# Makefile typically passes OPENWATT_OBJ via -D; fall back to the debug path
# under bin/<buildname>_debug/ for direct idf.py invocations.
if(NOT DEFINED OPENWATT_OBJ)
    set(OPENWATT_OBJ "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin/${OW_BUILDNAME}_debug/openwatt")
endif()

# Keep the D object inside the main component's whole archive. Linking it as a
# trailing object prevents its references from pulling earlier IDF archives.
set_source_files_properties("${OPENWATT_OBJ}" PROPERTIES
    EXTERNAL_OBJECT TRUE
    GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${OPENWATT_OBJ}")

# -Wl,--no-check-sections suppresses bogus warnings about TLS sections that are
# only reached via relocations rather than direct loads.
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--no-check-sections")

if(USE_LWIP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE OW_USE_LWIP)
else()
    foreach(SYSCALL _write_r _read_r _close_r _fcntl_r)
        target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=${SYSCALL}")
    endforeach()
    target_compile_definitions(mbedx509 PRIVATE MBEDTLS_TEST_SW_INET_PTON)
endif()

message(STATUS "Linking OpenWatt D object: ${OPENWATT_OBJ}")
