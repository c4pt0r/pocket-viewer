# StackChan

pocket-viewer can use an [M5Stack StackChan](https://docs.m5stack.com/en/StackChan) instead of the Pocket 3. The robot's head camera becomes the video, and its two servos become the gimbal, so the plugins work unchanged: face-follow turns the robot's head to keep you in frame, and the interpreter puts subtitles over its view.

```sh
./pocket-viewer -d stackchan                           # the StackChan on USB
./pocket-viewer -d stackchan -p plugins/bin/face-follow
./pocket-viewer -d stackchan -a none                   # video only, no microphone
```

The robot runs its own firmware, [`firmware/stackchan-cam`](firmware/stackchan-cam/stackchan-cam.ino), and is plugged into the Mac with the USB-C port on its body. Over that cable it sends JPEG frames and its head angles, and takes move commands back; there is nothing to configure. Heavy work (face detection, speech, translation) stays on the Mac. Audio comes from a Mac input (`-a`, default the system input); the robot's microphones are not used.

## What differs from the Pocket 3

| | Pocket 3 | StackChan |
|---|---|---|
| Video | up to 4K30 | 320×240 at about 10 fps (the robot's JPEG encoder is the limit) |
| Pan | −35…215° | −128…128° (+ turns right) |
| Tilt | ±90° | 5…85° (+ up) |
| Zoom, roll | yes | no (zoom stays 100) |
| Field of view | ~95° × 53° | ~41° × 31°, sent to plugins as `state.fov` |
| Moves | glide at ~8°/s | about 1 s; the servos stop 1–2° short, which counts as arrived once still |
| Recording | movie file output | the writer (as with echo cancellation) |

## Setup

Flashing replaces the factory firmware (AI agent, app control). **Back up first**, so you can put the factory firmware back exactly as it was. Install [arduino-cli](https://arduino.github.io/arduino-cli/) and [uv](https://docs.astral.sh/uv/) (it runs esptool), plug the StackChan in, and press its power button if the screen is off:

```sh
brew install arduino-cli uv
stackchan/backup-flash.sh ~/Documents/stackchan-factory.bin   # 16 MB, about a minute
stackchan/flash.sh
make
./pocket-viewer -d stackchan -p plugins/bin/face-follow
```

The backup holds the factory firmware's saved Wi-Fi passwords and account data. Keep it private, and out of this repository.

The first `flash.sh` installs the pinned ESP32 core and libraries ([`build-firmware.sh`](build-firmware.sh)) into `stackchan/firmware/.arduino`. That is about 1.7 GB to download and 6 GB on disk, because the ESP32 core ships compilers for every ESP32 chip. It stays inside the repository and leaves any global Arduino setup alone; delete the folder to reclaim the space. Flashing leaves NVS alone, so the servo calibration survives. Once running stackchan-cam, the robot's screen says *waiting for the Mac (USB)*, then *streaming to the Mac* while pocket-viewer runs.

To go back to the factory firmware:

```sh
stackchan/restore-factory.sh ~/Documents/stackchan-factory.bin
```

M5Burner can also install the current official firmware: search for StackChan, then choose *Burn*.

## How it works

- **Video.** The GC0308 camera delivers RGB565 frames. One task on the robot encodes them to JPEG, and another sends the newest JPEG over USB, so a slow link drops frames rather than adding delay. The Mac decodes each JPEG into a host-clock sample buffer. From there it goes where Pocket 3 frames go: the window, plugins, snapshots, and recordings.
- **USB.** The firmware runs the chip's USB in USB-OTG mode (TinyUSB CDC). The built-in USB-Serial-JTAG port managed only about 30 KB/s (2 fps). esptool cannot reset TinyUSB by itself, so [`bootloader-port.sh`](bootloader-port.sh) opens the port at 1200 baud. That reboots the robot into its ROM bootloader, which comes back as a different port. If it ever fails, hold RST (bottom, by the microSD slot) for 3 s until the LED turns green, then run the script again.
- **Gimbal.** `gimbal.c` routes its calls to a backend in `stackchan.m`. Yaw and pitch map directly to pan and tilt: + turns the camera right and up, as measured against a static ceiling. M5Stack's examples call +yaw "left", meaning as seen from in front of the robot. The servos stop 1–2° short of a target, so once the head is still and within 3°, it reports the target. Otherwise face-follow, which waits for the head to arrive, would wait forever.
- **Field of view.** Tilting 10° moved a static ceiling 77.5 of 240 pixels, so the view is 31° tall. The width, 41°, follows from the 4:3 sensor.

## Protocol

The robot is a serial port (`/dev/cu.usbmodem…`, Espressif's USB vendor ID 0x303a). It sends nothing until it hears `stream`.

| | |
|---|---|
| up | packets: `SCF1`, a type byte, a little-endian u32 length, the payload. `J` is a JPEG frame. `S` is the head state as JSON, every 0.2 s: `yaw`, `pitch`, `moving`, `yawRange`, `pitchRange`, `width`, `height`, `fps`, `camera`, `version` |
| down | text lines: `stream` (start; re-send at least every 3 s), `move YAW PITCH [SPEED]` (degrees; speed 0…1000), `home` |
