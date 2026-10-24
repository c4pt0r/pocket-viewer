# pocket-viewer

A viewer, recorder and gimbal controller for the **DJI Osmo Pocket 3** in webcam (UVC) mode, used from your browser. One program runs on your machine (macOS, Windows or Linux), talks to the camera, and serves the controls as a web page at `http://127.0.0.1:8642`.

> **StackChan:** an M5Stack StackChan robot can stand in for the Pocket 3 (`-d stackchan`): plugged in over USB, its head camera is the video and its servos the gimbal. See [stackchan/README.md](stackchan/README.md).

> **Of gimbal cameras, only the DJI Osmo Pocket 3 is supported at the moment.** It is found by its name (`OsmoPocket3`) and, on macOS, its USB IDs (`2ca3:0023`). Any other webcam works for viewing and recording (`-d "part of its name"`), without gimbal control.

## Features

- **Live preview** in the browser, scaled to fill, fit or stretch the window, plus full screen. Every setting is in a side panel (right-click, or ☰).
- **Gimbal control** over standard UVC camera-terminal controls: pan, tilt, roll and zoom. You can use the arrow keys, drag with the mouse, or scroll the wheel. Zoom glides smoothly between levels instead of jumping.
- **Resolution and frame-rate switching**: 720p, 1080p and 4K, in landscape or portrait, at up to 30 fps.
- **Audio**: record from any input (the Pocket 3 mic, a USB audio interface, BlackHole, …) and monitor it on any output device.
- **Recording** to `.mov` with HEVC, H.264 or ProRes 422 video and AAC or 24-bit PCM audio, through ffmpeg (hardware encoders on macOS), plus full-resolution snapshots.
- **Plugins**: external programs in any language receive the video, the audio and the gimbal state over a local socket. They can draw boxes, labels and subtitles over the picture, show their status in the HUD, react to clicks on it, steer the gimbal, and start recordings or take snapshots. Examples included: an **AI agent** you talk to that can see through the camera and steer it, **face follow**, **click-to-track**, **voice commands** and **live interpretation** (speech-to-subtitles plus translation), plus **hand gestures** as a teaching example.
- Runs on **macOS, Windows and Linux**: one self-contained program; open its page in any browser on the same machine.
- `pocketctl`, a command-line gimbal controller.

## Requirements

- macOS 14 or later, Windows 10 or later, or Linux with V4L2 (Apple Silicon macOS is tested with the Pocket 3 and StackChan; Windows and Linux are built in CI but untested with the hardware)
- [Rust](https://rustup.rs) to build it; on Linux also `libasound2-dev`, `libv4l-dev`, `libclang-dev` and `pkg-config`
- [ffmpeg](https://ffmpeg.org) on the `PATH` to record (`brew install ffmpeg`, `winget install ffmpeg`, `apt install ffmpeg`); viewing and control work without it
- A DJI Osmo Pocket 3 connected over USB in webcam mode, or a StackChan

## Build

```sh
make            # builds ./pocket-viewer (cargo build --release); on macOS also pocketctl and the Swift plugins in plugins/bin/
make ai-agent   # optional: installs the AI agent's npm dependencies (needs Node 22.18+)
```

On Windows, or without make: `cargo build --release`, then run `target/release/pocket-viewer`.

On first launch, macOS asks for camera and microphone access. If you run the app from a terminal, the permission is granted to that terminal.

## pocket-viewer

```sh
./pocket-viewer                         # 1080p30, Pocket 3 mic; opens http://127.0.0.1:8642 in the browser
./pocket-viewer -s 3840x2160 -a AG06    # 4K, record audio from another input
./pocket-viewer -l                      # list resolutions, audio inputs and outputs
./pocket-viewer -t 60 -c h264           # record 60 s with H.264, then quit
```

| Option | |
|---|---|
| `-d stackchan` | use a StackChan robot on USB instead of the Pocket 3 ([details](stackchan/README.md)); `-d name` uses another webcam |
| `-s WxH` | initial resolution, e.g. `3840x2160` or `1080x1920` (portrait) |
| `-r fps` | initial frame rate |
| `-a name` | audio input (substring of its name); with `-d stackchan`, `none` for video only |
| `-o dir` | where recordings go (default `~/Movies`) |
| `-c codec` | `hevc`, `h264` or `prores` |
| `-p cmd` | launch a plugin (repeatable) |
| `-t secs` | record immediately for `secs` seconds, then quit |
| `-l` | list cameras, formats, audio devices and StackChans |
| `--port N` | port of the web UI (default 8642; the next free one if taken) |
| `--host ADDR` | address to serve on (default `127.0.0.1`; `0.0.0.0` lets other machines in, with no password) |
| `--no-open` | don't open the browser |

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
| Space (hold) | push-to-talk, for plugins such as `ai-agent` |
| right-click, ☰ | the settings panel: resolution, recording, audio, plugins |

Recording settings, audio input and output, and plugins are in the settings panel. The page only shows what pocket-viewer reports, so several browser windows can be open at once; closing them leaves it running. Quit with Ctrl+C in the terminal or *Quit* in the panel.

## Plugins

A plugin is any program that connects to pocket-viewer's Unix socket. It subscribes to frames (BGRA or JPEG, at the size and rate it asks for), audio (16-bit PCM at the rate it asks for) and gimbal state. It sends back `draw` commands, which render as an overlay on the video, `hud` status text, `gimbal` / `zoom` commands, and `record` / `snapshot`. The wire format is in [plugins/PROTOCOL.md](plugins/PROTOCOL.md), with SDKs for [Python](plugins/python/pocketviewer.py) (standard library only), [Swift](plugins/swift/PocketViewer.swift) and [Node / TypeScript](plugins/node/pocketviewer.ts).

```sh
./pocket-viewer -p "plugins/bin/face-follow"                # keep the largest face framed
./pocket-viewer -p plugins/bin/tracker                       # click something to keep it framed
./pocket-viewer -p "plugins/bin/interpreter --from zh-CN --to English"
./pocket-viewer -p "python3 plugins/python/hello_overlay.py"
./pocket-viewer -p "node plugins/node/ai-agent/ai-agent.ts"  # talk to an agent that sees the camera
```

Plugins can also be loaded from the settings panel, which lists the ones in `plugins/` or runs any command. The panel lists running plugins, shows each plugin's own settings (for example the interpreter's engine and target language, or face-follow's on/off), and stops plugins. Settings are remembered per plugin. A plugin started on its own, while pocket-viewer is running, connects to `$TMPDIR/pocket-viewer.sock` (on Windows, the localhost port written to `%TEMP%\\pocket-viewer.port`). The Swift plugins use Apple frameworks and run on macOS only; the Python and Node SDKs run everywhere.

```python
import pocketviewer

class Boxes(pocketviewer.Plugin):
    def on_video(self, frame):            # frame.data: BGRA, rows top to bottom
        self.draw("demo", [{"shape": "rect", "x": .4, "y": .4, "w": .2, "h": .2, "label": "hi"}], ttl=1)

Boxes("boxes").run(video={"maxWidth": 320, "fps": 5})
```

- **face-follow** uses Apple Vision to box every face. It turns the gimbal to keep the largest one centered a little above the middle, and moves only once the gimbal has settled, so it converges without oscillating. Pass `--no-follow` to only draw.
- **calibrate** (StackChan only) measures the robot camera's field of view by turning its head and tracking how far the picture moves, and saves it, so following aims right. See [stackchan/README.md](stackchan/README.md#calibration).
- **tracker** follows whatever you click in the video, or box with ⌥-drag: a cup, a pet, a hand. It uses Apple Vision's object tracker and the same settle-then-move control as face-follow. Esc stops it.
- **gestures** (a teaching example; load it yourself from the panel) reads hand poses with Apple Vision. Hold an open palm ✋ for a second to start or stop recording, or ✌️ to save a snapshot. Point ☝️ left, right, up or down to turn the gimbal that way, and hold a thumb up 👍 or down 👎 to zoom. Each gesture can be switched off in its menu.
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

A command-line gimbal controller for the Pocket 3, macOS only.

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

- **Architecture.** `pocket-viewer` is one Rust program (`src/`). A capture thread reads the camera ([nokhwa](https://crates.io/crates/nokhwa): AVFoundation, Media Foundation or V4L2) or the StackChan's serial link; a gimbal thread owns pan/tilt/zoom/roll; [cpal](https://crates.io/crates/cpal) does audio in and monitoring out. A local [axum](https://crates.io/crates/axum) server sends the page (`web/`, compiled into the binary), the video as an MJPEG stream (the browser shows it in an `<img>`), and a WebSocket carrying status five times a second, the plugin overlay, and commands back.
- **Gimbal control.** In webcam mode the Pocket 3 exposes standard UVC camera-terminal controls: *PanTilt Absolute* (pan −35°…215°, tilt ±90°, 1° steps, in arc-seconds on the wire), *Zoom Absolute* (100…400) and *Roll Absolute* (−30°…30°, in whole degrees). On macOS, `UVCAssistant` owns the device, so libusb can't open it; `gimbal.c` sends class requests to the default control pipe through IOKit `DeviceRequest` instead, which needs no root and works while video is streaming. On Windows and Linux the camera API's pan, tilt and zoom controls are used; roll has no standard control there and is not offered.
- **Not supported by the device.** Focus responds but ignores writes. Image controls (brightness, white balance, …) are stubs. A vendor extension unit exists but is undocumented and is left untouched.
- **Video formats.** On macOS, AVFoundation also lists `2vuy` formats for the Pocket 3, including the only 4K60 mode, but they deliver no frames. The offered modes are capped at 30 fps for that reason. Raw frames are converted to JPEG for the browser (at most 1920 wide) and passed to ffmpeg untouched for recording.
- **Recording.** A writer feeds ffmpeg the newest frame on a fixed clock at the camera's frame rate, so the file's timeline is wall time. Audio goes to a side file and is muxed in at its measured offset when recording stops.
- **Plugin direction and field of view.** +pan turns right and +tilt turns up. The field of view is about 95° × 53° at zoom 100 (16:9), measured by panning and cross-correlating frames through the plugin interface.
- **Not carried over from the macOS app.** Echo cancellation (macOS voice processing) and ⌘1…⌘5 resolution shortcuts (the browser keeps those keys).

## License

MIT, see [LICENSE](LICENSE).

DJI and Osmo are trademarks of SZ DJI Technology Co., Ltd. This project is not affiliated with or endorsed by DJI.
