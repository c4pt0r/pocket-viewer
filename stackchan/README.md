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
| Field of view | ~95° × 53° | ~41° × 31°, or as measured by [calibrate](#calibration); sent to plugins as `state.fov` |
| Moves | glide at ~8°/s | about 1 s; the servos stop 1–2° short, which counts as arrived once still |
| Recording | raw frames to ffmpeg | its JPEG frames to ffmpeg, at a steady 15 fps |

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

## Calibration

The field of view (41° × 31°) and the head's directions were measured on one robot. To measure yours:

```sh
./pocket-viewer -d stackchan -p plugins/bin/calibrate
```

Point the robot at a still scene with some texture, such as a bookshelf, and stay out of view while it runs (about a minute). It turns the head ±15° left and right and ±12° up and down from where it is, measures how far the picture moves each time (cross-correlation, to a fraction of a pixel), and works out the field of view from the angles the servos report. The HUD shows the result, and it is saved to `~/.config/pocket-viewer/stackchan.json`. pocket-viewer reads that file at once, without a restart, and sends it to plugins as `state.fov`, so face-follow and tracker aim with it. If the steps disagree by more than 15%, because someone walked through or the scene was blank, nothing is saved; try again. `--dry-run` measures without saving, and `--shots DIR` keeps each step's picture. It also reports how far short of their targets the servos stop. Delete the file to go back to the built-in values.

The servos' zero points are a different calibration: they live in the robot's NVS, set by the factory firmware, and are not changed here.

## How it works

- **Video.** The GC0308 camera delivers RGB565 frames. One task on the robot encodes them to JPEG, and another sends the newest JPEG over USB, so a slow link drops frames rather than adding delay. pocket-viewer passes each JPEG on as it is: to the browser, to snapshots and recordings, and, decoded, to plugins. Frames are stamped on arrival, on the clock that audio uses too.
- **USB.** The firmware runs the chip's USB in USB-OTG mode (TinyUSB CDC). The built-in USB-Serial-JTAG port managed only about 30 KB/s (2 fps). esptool cannot reset TinyUSB by itself, so [`bootloader-port.sh`](bootloader-port.sh) opens the port at 1200 baud. That reboots the robot into its ROM bootloader, which comes back as a different port. If it ever fails, hold RST (bottom, by the microSD slot) for 3 s until the LED turns green, then run the script again.
- **Gimbal.** The head is a gimbal backend in `src/stackchan.rs`. Yaw and pitch map directly to pan and tilt: + turns the camera right and up, as measured against a static ceiling. M5Stack's examples call +yaw "left", meaning as seen from in front of the robot. The servos stop 1–2° short of a target, so once the head is still and within 3°, it reports the target. Otherwise face-follow, which waits for the head to arrive, would wait forever.
- **Field of view.** Tilting 10° moved a static ceiling 77.5 of 240 pixels, so the view is 31° tall. The width, 41°, follows from the 4:3 sensor. `calibrate` measures it the same way, on both axes, with the pinhole relation shift = f·tan(angle).

## Protocol

The robot is a serial port (`/dev/cu.usbmodem…`, Espressif's USB vendor ID 0x303a). It sends nothing until it hears `stream`.

| | |
|---|---|
| up | packets: `SCF1`, a type byte, a little-endian u32 length, the payload. `J` is a JPEG frame. `S` is the head state as JSON, every 0.2 s: `yaw`, `pitch`, `moving`, `yawRange`, `pitchRange`, `width`, `height`, `fps`, `camera`, `version` |
| down | text lines: `stream` (start; re-send at least every 3 s), `move YAW PITCH [SPEED]` (degrees; speed 0…1000), `home` |
