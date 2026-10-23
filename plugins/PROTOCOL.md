# pocket-viewer plugin protocol (v1)

A plugin is any program that connects to pocket-viewer's Unix socket. It can subscribe to the camera's video frames, the audio, the gimbal state and the user's clicks on the video. It can send back drawing commands, shown over the video, status text for the HUD, gimbal commands, and recording and snapshot commands.

- **Socket:** `$POCKET_VIEWER_SOCKET` when pocket-viewer launched the plugin. Otherwise use `$TMPDIR/pocket-viewer.sock`, the per-user temporary directory (Python: `tempfile.gettempdir()`). Only the current user can connect.
- **Launching:** use *Plugins → Load Plugin…* (right-click or the menu bar), or `pocket-viewer -p "command"` (repeatable). The command runs via `/bin/sh -c` with `POCKET_VIEWER_SOCKET` and `POCKET_VIEWER_TOKEN` set. Plugins started any other way connect as *external* clients.
- **SDKs:** [`python/pocketviewer.py`](python/pocketviewer.py) (standard library only), [`swift/PocketViewer.swift`](swift/PocketViewer.swift) and [`node/pocketviewer.ts`](node/pocketviewer.ts) (Node 22.18+, no dependencies).

## Framing

Every message in both directions has the same layout:

```
u32 big-endian   length of the JSON header
JSON object      the header; always has "type"; has "size" when a payload follows
bytes            payload of "size" bytes (frames, audio)
```

pocket-viewer validates everything it receives. Malformed input, unknown types and wrong field types are ignored, or at worst close that connection.

## pocket-viewer → plugin

| type | fields | payload |
|---|---|---|
| `hello` | `protocol` (1), `clientID`, plus the `state` fields below | — |
| `video` | `pts` (host-clock seconds), `width`, `height`, `format` | `bgra`: width×height×4 bytes, rows top to bottom. `jpeg`: a JPEG |
| `audio` | `pts`, `rate`, `channels`, `frames`, `format` (`s16le`) | interleaved signed 16-bit little-endian samples |
| `set` | `key`, `value` | — the user changed a setting declared with `options` |
| `input` | `event`: `click` (`x`, `y`), `select` (`x`, `y`, `w`, `h`) or `cancel` | — see below |
| `state` | `pan`, `tilt`, `roll`, `zoom` (commanded); `actualPan`, `actualTilt` (read back from the camera); `panRange`, `tiltRange`, `zoomRange`; `video` {`width`, `height`, `fps`}; `recording`; `fov` [horizontal, vertical] degrees at zoom 100, only when the camera is not a Pocket 3 (StackChan) | — |

`state` arrives every 0.2 s while subscribed. All timestamps share the host clock, so video and audio `pts` can be compared directly.

`input` reports the user's mouse on the video, in the same normalized coordinates as `draw`. A plain click (no drag) is `click`; dragging with ⌥ held draws a dashed box and sends `select` when released; Esc sends `cancel`. Plain drags still steer the gimbal and are not reported. Every subscribed plugin receives every event.

## plugin → pocket-viewer

### `hello`
`{"type": "hello", "name": "face-follow", "token": "$POCKET_VIEWER_TOKEN"}` names the plugin in the Plugins menu. The token ties the connection to the process pocket-viewer launched.

### `subscribe`
```json
{"type": "subscribe",
 "video": {"maxWidth": 640, "fps": 15, "format": "bgra", "quality": 0.7},
 "audio": {"rate": 16000, "channels": 1},
 "state": true,
 "input": true}
```
Each part is optional: `null`, `false` or a missing key unsubscribes, and `true` uses the defaults shown. A new `subscribe` replaces the previous one.

- **Video** is scaled down to `maxWidth`, keeping the aspect ratio. `quality` applies to `jpeg` only.
- **Backpressure:** a client still receiving its previous frame skips frames instead of queueing them. Audio is queued up to a limit, then dropped.
- **Audio source:** the selected audio input. With echo cancellation on, it is the echo-cancelled signal.

### `draw`
```json
{"type": "draw", "layer": "faces", "ttl": 0.5, "items": [
  {"shape": "rect", "x": 0.4, "y": 0.3, "w": 0.2, "h": 0.25, "color": "#00ff88", "width": 3, "label": "face"},
  {"shape": "line", "x1": 0.5, "y1": 0.45, "x2": 0.5, "y2": 0.55},
  {"shape": "text", "x": 0.02, "y": 0.02, "text": "hello", "size": 15},
  {"shape": "subtitle", "text": "Hello everyone", "size": 26}
]}
```
- **Coordinates** are normalized to the video frame: 0…1, origin top-left. They follow the window's scaling mode (fill, fit or stretch).
- **Layers:** each `layer` belongs to the sending plugin and is replaced wholesale by the next `draw` to it. With `ttl` > 0, the layer disappears that many seconds after it was drawn, so a crashed plugin can't leave stale boxes behind.
- **Colors** are `#rrggbb` or `#rrggbbaa`. Optional fields: rect `fill` and `label`; text `color` and `background`; subtitle `color`, `background` and `size`.
- **Subtitles** from all plugins stack upward from the bottom of the picture.

### `hud`
```json
{"type": "hud", "key": "status", "text": "🎯 tracking", "color": "#ffcc00", "ttl": 0}
```
- **Placement:** plugin segments share one line above the built-in HUD (format, gimbal, audio meter) at the bottom left, ordered by plugin and then `key`.
- **Segments:** each `key` (default `"default"`) is one segment of this plugin, replaced by the next `hud` with that key. Empty `text` removes it, and `ttl` > 0 removes it after that many seconds. Segments are removed when the plugin disconnects.
- **Limits:** text is one line, up to 200 characters; `color` is `#rrggbb` or `#rrggbbaa` (default white).

### `clear`
`{"type": "clear", "layer": "faces"}` removes one layer. Without `layer`, it removes all of this plugin's layers. They are also removed when the plugin disconnects.

### `gimbal`, `zoom`, `roll`, `center`
```json
{"type": "gimbal", "pan": 120, "tilt": -10}     // absolute degrees
{"type": "gimbal", "dpan": 5, "dtilt": -2}      // relative to the commanded position
{"type": "zoom", "zoom": 200}                   // 100…400, or "dzoom"
{"type": "roll", "roll": 0}                     // −30…30 degrees, or "droll"
{"type": "center"}
```
- **Direction:** +pan turns right and +tilt turns up. Both were measured on a Pocket 3 in landscape.
- **Speed:** the gimbal moves at roughly 8°/s. For closed-loop control, such as following a subject, wait until `actualPan`/`actualTilt` reach `pan`/`tilt` before acting on the next frame. A frame taken mid-move shows an error that is already being corrected, and correcting it again overshoots. [`FaceFollow.swift`](swift/FaceFollow.swift) does this.
- **Field of view:** about 95° × 53° at zoom 100 in 16:9, divided by zoom/100. Other cameras report theirs in `state.fov`.
- **Zoom** changes glide smoothly to the target.

### `record`, `snapshot`
```json
{"type": "record", "action": "start"}           // "start", "stop" or "toggle"
{"type": "snapshot"}
```
- **Recording** uses the settings in the Record menu. `start` while recording and `stop` while stopped do nothing; `state.recording` tells which it is.
- **Snapshots** save the next camera frame at full resolution as a JPEG in the recordings folder.

### `options` (settings in the Plugins menu)
```json
{"type": "options", "items": [
  {"key": "follow", "title": "Move the gimbal to follow", "type": "bool", "value": true},
  {"key": "to", "title": "Translate to", "type": "choice", "value": "English",
   "choices": [["English", "English"], ["Japanese", "日本語"]]}
]}
```
- **Menu:** the items appear under *Plugins → (plugin name)*, in the right-click menu and the menu bar. A `bool` is a checkmark item; a `choice` is a submenu of `[value, label]` pairs, where `value` is a string or a number.
- **Changes:** when the user changes a setting, pocket-viewer sends `{"type": "set", "key": …, "value": …}`. Apply it, then send `options` again with the new values.
- **Saved values:** pocket-viewer remembers choices per plugin name. When a plugin first declares its options with different values, pocket-viewer sends `set` for each saved value that is still valid. A plugin may re-exec itself to apply a setting, as `interpreter` does; it keeps its identity through `POCKET_VIEWER_TOKEN`.

### `log`
`{"type": "log", "text": "…"}` is written to pocket-viewer's log, prefixed with the plugin name.

## Example plugins

| | |
|---|---|
| [`python/hello_overlay.py`](python/hello_overlay.py) | Minimal example: draws from video, audio and state. |
| [`swift/FaceFollow.swift`](swift/FaceFollow.swift) → `plugins/bin/face-follow` | Detects faces with Apple Vision, boxes them, and keeps the largest one framed. Pass `--no-follow` to only draw, or `--verbose` to log each move. |
| [`node/ai-agent/ai-agent.ts`](node/ai-agent/ai-agent.ts) | A voice agent on the pi SDK with OpenAI models. It listens through `transcribe`, answers in subtitles and speech, and has tools to `look` at the current frame(s), review `recent_keyframes`, turn and zoom the camera, record and take snapshots. `make ai-agent` installs its npm dependencies. |
| [`swift/Transcribe.swift`](swift/Transcribe.swift) → `plugins/bin/transcribe` | Not a plugin: a helper for plugins in any language. It reads 16 kHz mono s16le on stdin and writes `{"partial"}` / `{"phrase"}` JSON lines, using Apple Speech on-device. |
| [`swift/Tracker.swift`](swift/Tracker.swift) → `plugins/bin/tracker` | Click something in the video, or ⌥-drag a box around it, and the gimbal keeps it centered (Apple Vision object tracking). Esc stops. |
| [`swift/Gestures.swift`](swift/Gestures.swift) → `plugins/bin/gestures` | Teaching example, not meant for everyday use. Hand gestures (Apple Vision hand pose): hold ✋ to start or stop recording, ✌️ for a snapshot, point ☝️ to turn the gimbal, 👍 / 👎 to zoom. |
| [`swift/VoiceControl.swift`](swift/VoiceControl.swift) → `plugins/bin/voice-control` | Spoken commands, recognized on-device: 左转 / 右转 [30度], 抬头 / 低头, 放大 / 缩小 [到2倍], 回中, 开始录像 / 停止录像, 拍照, or the English equivalents ("turn left 30 degrees", "zoom in", "take a photo"). `--lang zh-CN\|en-US`; `--wake 相机` acts only on words after the wake word. |
| [`swift/Interpreter.swift`](swift/Interpreter.swift) → `plugins/bin/interpreter` | Live subtitles, with two engines. `--asr apple` (the default) recognizes speech locally with Apple Speech and translates each phrase after a pause (`--pause 1.5`) with the OpenAI chat API (`--model gpt-5.4-mini`). `--asr openai` streams the audio to OpenAI's `gpt-realtime-translate`, which recognizes and translates while the speaker talks; it is more accurate, has no per-phrase pauses, and is billed per minute. Use `--from zh-CN --to English` (a name or a code). The key comes from `--key-file`, `$OPENAI_API_KEY`, `./.openai-key` or `~/.config/pocket-viewer/openai-key`. Without a key, `--asr apple` shows the transcript only. |

`make plugins` builds the Swift examples into `plugins/bin/`. Shared code: `Follow.swift` (closed-loop gimbal following, used by face-follow and tracker) and `Speech.swift` (Apple speech recognition, used by interpreter and voice-control).
