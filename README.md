# pocket-viewer

A small native macOS viewer, recorder and gimbal controller for the **DJI Osmo Pocket 3** in webcam (UVC) mode.

> **StackChan:** an M5Stack StackChan robot can stand in for the Pocket 3 (`-d stackchan`): plugged in over USB, its head camera is the video and its servos the gimbal. See [stackchan/README.md](stackchan/README.md).

> **Of cameras, only the DJI Osmo Pocket 3 is supported at the moment.** The device is matched by its USB IDs (`2ca3:0023`) and name (`OsmoPocket3`), and the control ranges below are specific to it. Other DJI cameras or UVC webcams may expose different controls and are untested.

## Features

- **Live preview** of the Pocket 3's video, scaled to fill, fit or stretch the window, plus full screen.
- **Gimbal control** over standard UVC camera-terminal controls: pan, tilt, roll and zoom. You can use the arrow keys, drag with the mouse, or scroll the wheel. Zoom glides smoothly between levels instead of jumping.
- **Resolution and frame-rate switching**: 720p, 1080p and 4K, in landscape or portrait, at up to 30 fps.
- **Audio**: record from any input (the Pocket 3 mic, a USB audio interface, BlackHole, …) and monitor it on any output device.
- **Recording** to `.mov` with HEVC, H.264 or ProRes 422 video and AAC or 24-bit PCM audio.
- **Echo cancellation (experimental)**: uses macOS voice processing so that monitoring through speakers doesn't feed back into the mic.
- **Plugins**: external programs in any language receive the video, the audio and the gimbal state over a local socket. They can draw boxes, labels and subtitles over the picture, show their status in the HUD, react to clicks on it, steer the gimbal, and start recordings or take snapshots. Examples included: an **AI agent** you talk to that can see through the camera and steer it, **face follow**, **click-to-track**, **voice commands** and **live interpretation** (speech-to-subtitles plus translation), plus **hand gestures** as a teaching example.
- Every option is available from the **right-click menu** and the menu bar.
- `pocketctl`, a command-line gimbal controller.

## Requirements

- macOS 14 or later (Apple Silicon tested)
- Xcode Command Line Tools (`xcode-select --install`)
- A DJI Osmo Pocket 3 connected over USB in webcam mode

## Build

```sh
make            # builds ./pocket-viewer, ./pocketctl and the example plugins in plugins/bin/
make ai-agent   # optional: installs the AI agent's npm dependencies (needs Node 22.18+)
```

On first launch, macOS asks for camera and microphone access. If you run the app from a terminal, the permission is granted to that terminal.

## pocket-viewer

```sh
./pocket-viewer                         # 1080p30, Pocket 3 mic
./pocket-viewer -s 3840x2160 -a AG06    # 4K, record audio from another input
./pocket-viewer -l                      # list resolutions, audio inputs and outputs
./pocket-viewer -t 60 -c h264           # record 60 s with H.264, then quit
```

| Option | |
|---|---|
| `-d stackchan` | use a StackChan robot on USB instead of the Pocket 3 ([details](stackchan/README.md)) |
| `-s WxH` | initial resolution, e.g. `3840x2160` or `1080x1920` (portrait) |
| `-r fps` | initial frame rate |
| `-a name` | audio input (substring of its name); with `-d stackchan`, `none` for video only |
| `-o dir` | where recordings go (default `~/Movies`) |
| `-c codec` | `hevc`, `h264` or `prores` |
| `-e` | start with echo cancellation on |
| `-p cmd` | launch a plugin (repeatable) |
| `-t secs` | record immediately for `secs` seconds, then quit |
| `-l` | list formats and audio devices |

| Key / mouse | |
|---|---|
| Arrows / WASD, mouse drag | pan & tilt |
| click, ⌥-drag, Esc | point at / box / cancel, for plugins such as `tracker` |
| `[` `]` | smaller / larger step |
| `,` `.` | roll |
| `+` `-`, scroll | zoom |
| `c` | center the gimbal |
| `r` / ⌘R | start / stop recording |
| `m` | toggle audio monitoring |
| `v` | video scaling: fill / fit / stretch |
| `f` | full screen |
| ⌘1…⌘5 | switch resolution |
| right-click | everything else |

Recording settings, audio input and output, and echo cancellation are in the right-click menu and the menu bar.

## Plugins

A plugin is any program that connects to pocket-viewer's Unix socket. It subscribes to frames (BGRA or JPEG, at the size and rate it asks for), audio (16-bit PCM at the rate it asks for) and gimbal state. It sends back `draw` commands, which render as an overlay on the video, `hud` status text, `gimbal` / `zoom` commands, and `record` / `snapshot`. The wire format is in [plugins/PROTOCOL.md](plugins/PROTOCOL.md), with SDKs for [Python](plugins/python/pocketviewer.py) (standard library only), [Swift](plugins/swift/PocketViewer.swift) and [Node / TypeScript](plugins/node/pocketviewer.ts).

```sh
./pocket-viewer -p "plugins/bin/face-follow"                # keep the largest face framed
./pocket-viewer -p plugins/bin/tracker                       # click something to keep it framed
./pocket-viewer -p "plugins/bin/interpreter --from zh-CN --to English"
./pocket-viewer -p "python3 plugins/python/hello_overlay.py"
./pocket-viewer -p "node plugins/node/ai-agent/ai-agent.ts"  # talk to an agent that sees the camera
```

Plugins can also be loaded from *Plugins → Load Plugin…*. The same menu lists running plugins, shows each plugin's own settings (for example the interpreter's engine and target language, or face-follow's on/off), and stops plugins. Settings are remembered per plugin. A plugin started on its own, while pocket-viewer is running, connects to `$TMPDIR/pocket-viewer.sock`.

```python
import pocketviewer

class Boxes(pocketviewer.Plugin):
    def on_video(self, frame):            # frame.data: BGRA, rows top to bottom
        self.draw("demo", [{"shape": "rect", "x": .4, "y": .4, "w": .2, "h": .2, "label": "hi"}], ttl=1)

Boxes("boxes").run(video={"maxWidth": 320, "fps": 5})
```

- **face-follow** uses Apple Vision to box every face. It turns the gimbal to keep the largest one centered a little above the middle, and moves only once the gimbal has settled, so it converges without oscillating. Pass `--no-follow` to only draw.
- **tracker** follows whatever you click in the video, or box with ⌥-drag: a cup, a pet, a hand. It uses Apple Vision's object tracker and the same settle-then-move control as face-follow. Esc stops it.
- **gestures** (a teaching example; load it yourself from *Load Plugin…*) reads hand poses with Apple Vision. Hold an open palm ✋ for a second to start or stop recording, or ✌️ to save a snapshot. Point ☝️ left, right, up or down to turn the gimbal that way, and hold a thumb up 👍 or down 👎 to zoom. Each gesture can be switched off in its menu.
- **voice-control** listens for spoken commands, recognized on-device: 「左转三十度」「抬头」「放大到两倍」「回中」「开始录像」「拍照」, or "turn left 30 degrees", "zoom in", "take a photo". Choose a wake word (「相机」 or "camera") in its menu so ordinary conversation doesn't move the camera.
- **ai-agent** is a voice assistant built on the [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) SDK with OpenAI models (`gpt-5.4-mini` by default). Talk to it through the camera's microphone: speech is recognized on-device, and the reply appears as a subtitle and is read aloud.
  - **Sight:** when the answer depends on what's in view, it calls `look` for the current frame, or several frames a moment apart. For "what happened just now", it calls `recent_keyframes`: frames kept whenever the scene changed.
  - **Camera control:** it can turn and zoom the camera, record and take snapshots, e.g. 「往右转看看那边有什么」.
  - **Interrupting:** Esc or 「停」 interrupts it.
  - **Settings** in its menu: model, thinking level, spoken language, an optional wake word (「助手」 / "assistant"), and reading aloud.
  - **Privacy:** it runs in a private, in-memory pi session, without your pi settings, sessions or tools; it has no shell or file access. Only the frames it looks at, and your words, are sent to OpenAI. It uses the same OpenAI key as the interpreter. Build it with `make ai-agent`.
- **interpreter** shows live subtitles with one of two engines:
  - `--asr apple` (the default): speech is recognized on-device with Apple Speech, and each phrase is translated with the OpenAI API (`gpt-5.4-mini`) once the speaker pauses. On first run, macOS asks for speech-recognition permission.
  - `--asr openai`: the audio streams to OpenAI's `gpt-realtime-translate`, which transcribes and translates while the speaker is still talking. It is noticeably more accurate. It is billed per minute, so the session runs only while someone talks. A local voice detector opens it, and the last second of audio is replayed so no words are lost. It closes after 10 s without a transcript from OpenAI (`--idle`), so fans, music or typing don't keep it open. A session that heard only noise teaches the detector that noise level.

  Put your key in `$OPENAI_API_KEY` or a `.openai-key` file, which is git-ignored.

## pocketctl

```sh
./pocketctl get              # current pan / tilt / zoom / roll and ranges
./pocketctl set 90 -10       # absolute pan / tilt in degrees
./pocketctl move 15 0        # relative move
./pocketctl zoom 200         # 100 … 400
./pocketctl roll 10          # -30 … 30 degrees
./pocketctl center
./pocketctl                  # interactive: arrow keys, +/-, c, q
```

## How it works / Pocket 3 notes

- **Gimbal control.** In webcam mode the Pocket 3 exposes standard UVC camera-terminal controls: *PanTilt Absolute* (pan −35°…215°, tilt ±90°, 1° steps, in arc-seconds on the wire), *Zoom Absolute* (100…400) and *Roll Absolute* (−30°…30°, in whole degrees). macOS's `UVCAssistant` owns the device, so libusb can't open it. `gimbal.c` sends class requests to the default control pipe through IOKit `DeviceRequest` instead, which needs no root and works while video is streaming.
- **Not supported by the device.** Focus responds but ignores writes. Image controls (brightness, white balance, …) are stubs. A vendor extension unit exists but is undocumented and is left untouched.
- **Video formats.** AVFoundation also lists `2vuy` formats for the Pocket 3, including the only 4K60 mode, but they deliver no frames on macOS. Only the `420v` formats are offered, which caps the frame rate at 4K30.
- **Format locking.** macOS resets the camera format whenever the capture session reconfigures, unless the device stays locked for configuration. pocket-viewer holds that lock while it runs.
- **Plugin direction and field of view.** +pan turns right and +tilt turns up. The field of view is about 95° × 53° at zoom 100 (16:9), measured by panning and cross-correlating frames through the plugin interface.
- **Echo cancellation.** This uses `AVAudioEngine` with voice processing. It only cancels audio the engine itself plays, which is the monitor path, not other apps. Recording in this mode muxes camera frames and processed audio with `AVAssetWriter` on the host clock. See the comments in `echocancel.m` for the macOS voice-processing pitfalls worked around.

## License

MIT, see [LICENSE](LICENSE).

DJI and Osmo are trademarks of SZ DJI Technology Co., Ltd. This project is not affiliated with or endorsed by DJI.
