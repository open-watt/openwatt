# SmartEVSE v3.0 OTA migration

Build the app-only migration image with:

```sh
make esp-idf-build BOARD=smartevse-v30 CONFIG=release
```

The build produces `bin/esp32_smartevse-v30_release/firmware.bin`. In the stock
SmartEVSE web interface, open `/update` and upload that file as the firmware.
Do not upload OpenWatt's bootloader, partition table, or OTA data images.

OpenWatt retains the stock partition table, NVS partition, and SPIFFS partition.
It starts an open `OpenWatt-SmartEVSE` access point at `192.168.4.1`. To return
to SmartEVSE, download its normal app-only `firmware.bin`, connect to that access
point, and upload the image to OpenWatt:

```sh
curl --fail --upload-file firmware.bin http://192.168.4.1/ota
```

OpenWatt validates the ESP application image, writes the inactive stock OTA
slot, selects it for boot, and reboots. The preserved SmartEVSE settings become
available again when the stock firmware starts.

This path cannot recover an image that never boots far enough to start WiFi and
HTTP. Keep USB access available for the first hardware smoke tests.
