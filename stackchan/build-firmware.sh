#!/bin/sh
# Builds stackchan-cam into stackchan/firmware/stackchan-cam/build/.
#
#   stackchan/build-firmware.sh
#
# The toolchain is pinned below and installed inside this repository, in
# stackchan/firmware/.arduino (git-ignored), so the build neither depends on
# nor changes a global Arduino setup. The first run downloads about 1.7 GB and
# leaves about 6 GB installed: arduino-cli's ESP32 core ships compilers and
# libraries for every ESP32 chip. Delete that folder to reclaim the space.
set -e
cd "$(dirname "$0")/firmware"

CORE="esp32:esp32@3.3.11"
LIBS="M5StackChan@1.1.1 M5Unified@0.2.27 M5GFX@0.2.34 IRremoteESP8266@2.9.0 M5Unit-NFC@0.1.2 M5UnitUnified@0.6.3 M5HAL@0.1.4 M5Utility@0.3.1"
FQBN="esp32:esp32:esp32s3:PSRAM=enabled,FlashSize=16M,PartitionScheme=custom,CDCOnBoot=cdc,USBMode=default"

A="$PWD/.arduino"
export ARDUINO_DIRECTORIES_DATA="$A/data" ARDUINO_DIRECTORIES_USER="$A/user" ARDUINO_DIRECTORIES_DOWNLOADS="$A/downloads"
export ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS="https://espressif.github.io/arduino-esp32/package_esp32_index.json"

if [ "$(cat "$A/installed" 2>/dev/null)" != "$CORE $LIBS" ]; then
  arduino-cli core update-index
  arduino-cli core install "$CORE"
  arduino-cli lib update-index
  arduino-cli lib install --no-deps $LIBS  # every dependency is listed, so all are pinned
  arduino-cli cache clean                   # the downloaded archives
  echo "$CORE $LIBS" > "$A/installed"
fi
arduino-cli compile --fqbn "$FQBN" --build-path "$A/build" --output-dir stackchan-cam/build stackchan-cam
