# Minimal ESP-IDF project for OpenWatt on ESP32-S3
#
# This project provides the ESP-IDF runtime (bootloader, flash cache, FreeRTOS,
# hardware drivers) and links in the pre-compiled D object file produced by LDC.
#
# Build flow:
#   1. make PLATFORM=esp32-s3  ->  LDC compiles D code to .o
#   2. idf.py build            ->  links .o with ESP-IDF, produces flashable bin

cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Not using MINIMAL_BUILD -- we need lwIP for sockets
project(openwatt)
