#!/bin/sh
# Builds stackchan-cam and flashes it to a StackChan on USB.
#
#   stackchan/flash.sh [PORT]      PORT defaults to the first /dev/cu.usbmodem*
#
# Needs arduino-cli and uv; build-firmware.sh installs the pinned toolchain on
# first use. Writes the bootloader, the partition table (the factory one) and
# the app, and clears otadata so the app boots; NVS (servo calibration) is left
# alone.
#
# The firmware runs USB in USB-OTG mode (TinyUSB CDC), about 5× the throughput
# of the chip's built-in USB-Serial-JTAG port. bootloader-port.sh reboots it
# into the bootloader over the same cable; if that ever fails, hold RST (bottom,
# by the microSD slot) for 3 s until the LED turns green, then run this again.
set -e
cd "$(dirname "$0")"
./build-firmware.sh
cd firmware/stackchan-cam

PORT=$(../../bootloader-port.sh ${1:+"$1"})
echo "flashing via $PORT"
esptool() { uvx --from esptool esptool --chip esp32s3 -p "$PORT" -b 921600 "$@"; }
esptool erase-region 0xd000 0x2000
esptool write-flash 0x0 build/stackchan-cam.ino.bootloader.bin 0x8000 build/stackchan-cam.ino.partitions.bin \
  0x20000 build/stackchan-cam.ino.bin
echo "flashed: StackChan restarts; run ./pocket-viewer -d stackchan"
