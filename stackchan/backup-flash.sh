#!/bin/sh
# Saves the whole 16 MB flash of a StackChan, factory firmware and saved
# settings included, before flashing stackchan-cam over it.
#
#   stackchan/backup-flash.sh OUT.bin [PORT]
#
# The image holds the robot's saved Wi-Fi passwords and account data: keep it
# private and out of any repository.
set -e
OUT=$1
[ -n "$OUT" ] || { echo "usage: $0 OUT.bin [PORT]" >&2; exit 2; }
PORT=$("$(dirname "$0")/bootloader-port.sh" ${2:+"$2"})
uvx --from esptool esptool --chip esp32s3 -p "$PORT" -b 921600 read-flash 0 ALL "$OUT"
shasum -a 256 "$OUT"
