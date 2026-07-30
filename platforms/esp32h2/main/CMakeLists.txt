set(OW_BUILDNAME esp32-h2)
set(OW_NO_WIFI 1)
set(OW_EXTRA_REQUIRES esp_driver_usb_serial_jtag)
include("${CMAKE_CURRENT_LIST_DIR}/../../esp32-common/main.cmake")
