#!/bin/sh
# Writes a full flash backup (taken with backup-flash.sh) back to a StackChan,
# restoring the factory firmware and everything it had saved.
#
#   stackchan/restore-factory.sh BACKUP.bin [PORT]
#
# M5Burner can also install the current official firmware instead.
set -e
BACKUP=$1
[ -f "$BACKUP" ] || { echo "usage: $0 BACKUP.bin [PORT]" >&2; exit 2; }
[ "$(wc -c < "$BACKUP")" -eq 16777216 ] || { echo "$BACKUP is not a full 16 MB image" >&2; exit 1; }
PORT=$("$(dirname "$0")/bootloader-port.sh" ${2:+"$2"})
uvx --from esptool esptool --chip esp32s3 -p "$PORT" -b 921600 write-flash 0x0 "$BACKUP"
