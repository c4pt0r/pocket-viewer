#!/bin/sh
# Prints the serial port of a StackChan's ROM bootloader, rebooting it there
# first if it runs stackchan-cam.
#
#   stackchan/bootloader-port.sh [PORT]   PORT defaults to the first /dev/cu.usbmodem*
#
# stackchan-cam uses TinyUSB, which esptool cannot reset on its own: opening the
# port at 1200 baud reboots the robot into the bootloader, which comes back as
# a different port. Already in the bootloader (or on factory firmware, which
# uses the chip's USB-Serial-JTAG), nothing changes and PORT is printed as is.
set -e
PORT=${1:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}
[ -n "$PORT" ] || { echo "no StackChan on USB (expected /dev/cu.usbmodem*)" >&2; exit 1; }
before=$(ls /dev/cu.usbmodem* 2>/dev/null)
stty -f "$PORT" 1200 2>/dev/null || true
for _ in $(seq 50); do
  sleep 0.1
  new=$(ls /dev/cu.usbmodem* 2>/dev/null | grep -vxF "$before" | head -1 || true)
  [ -n "$new" ] && { PORT=$new; break; }
done
echo "$PORT"
