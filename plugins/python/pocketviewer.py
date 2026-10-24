"""Client for pocket-viewer plugins. Standard library only.

    import pocketviewer

    class Hello(pocketviewer.Plugin):
        def on_video(self, frame):           # frame.data: BGRA bytes, row 0 = top
            self.draw("box", [{"shape": "rect", "x": .4, "y": .4, "w": .2, "h": .2}], ttl=1)

    Hello("hello").run(video={"maxWidth": 320, "fps": 5})

See ../PROTOCOL.md for the wire format.
"""

import json
import os
import socket
import struct
import tempfile
import threading
from dataclasses import dataclass


def default_socket_path():
    if os.environ.get("POCKET_VIEWER_SOCKET"):
        return os.environ["POCKET_VIEWER_SOCKET"]
    # On Windows pocket-viewer listens on a localhost port and writes it here.
    port_file = os.path.join(tempfile.gettempdir(), "pocket-viewer.port")
    if os.name == "nt" and os.path.exists(port_file):
        with open(port_file) as f:
            return f.read().strip()
    return os.path.join(tempfile.gettempdir(), "pocket-viewer.sock")


@dataclass
class VideoFrame:
    pts: float      # host-clock seconds
    width: int
    height: int
    format: str     # "bgra" (rows top to bottom, 4 bytes per pixel) or "jpeg"
    data: bytes


@dataclass
class AudioChunk:
    pts: float
    rate: int
    channels: int
    frames: int
    data: bytes     # signed 16-bit little-endian, interleaved


class Plugin:
    """Subclass and override on_hello / on_video / on_audio / on_state."""

    def __init__(self, name, socket_path=None):
        self.name = name
        address = socket_path or default_socket_path()
        if address.startswith("tcp:"):  # "tcp:HOST:PORT", on Windows
            host, port = address[4:].rsplit(":", 1)
            self.sock = socket.create_connection((host, int(port)))
        else:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(address)
        self._send_lock = threading.Lock()
        self.hello = {}
        self.state = {}
        self.send({"type": "hello", "name": name, "token": os.environ.get("POCKET_VIEWER_TOKEN", "")})

    # --- sending -----------------------------------------------------------

    def send(self, header, payload=b""):
        if payload:
            header = dict(header, size=len(payload))
        body = json.dumps(header, separators=(",", ":")).encode()
        with self._send_lock:
            self.sock.sendall(struct.pack(">I", len(body)) + body + payload)

    def subscribe(self, video=None, audio=None, state=False, input=False):
        """video: {"maxWidth", "fps", "format": "bgra"|"jpeg", "quality"}; audio: {"rate", "channels"};
        input: receive clicks / ⌥-drag boxes / Esc on the video in on_input."""
        self.send({"type": "subscribe", "video": video, "audio": audio, "state": state, "input": input})

    def draw(self, layer, items, ttl=0):
        """Replace this plugin's `layer` with `items`; it disappears after `ttl` seconds (0 = keep)."""
        self.send({"type": "draw", "layer": layer, "items": items, "ttl": ttl})

    def hud(self, text, key="default", color=None, ttl=0):
        """Show `text` on the HUD's plugin line under `key`; "" removes it, ttl > 0 expires it."""
        msg = {"type": "hud", "key": key, "text": text, "ttl": ttl}
        if color:
            msg["color"] = color
        self.send(msg)

    def clear(self, layer=None):
        self.send({"type": "clear", "layer": layer} if layer else {"type": "clear"})

    def gimbal(self, pan=None, tilt=None, dpan=None, dtilt=None):
        msg = {"type": "gimbal"}
        for k, v in (("pan", pan), ("tilt", tilt), ("dpan", dpan), ("dtilt", dtilt)):
            if v is not None:
                msg[k] = v
        self.send(msg)

    def zoom(self, zoom=None, dzoom=None):
        self.send({"type": "zoom", **({"zoom": zoom} if zoom is not None else {"dzoom": dzoom or 0})})

    def roll(self, roll=None, droll=None):
        self.send({"type": "roll", **({"roll": roll} if roll is not None else {"droll": droll or 0})})

    def center(self):
        self.send({"type": "center"})

    def record(self, action="toggle"):
        """action: "start", "stop" or "toggle"."""
        self.send({"type": "record", "action": action})

    def snapshot(self):
        """Save the next frame, full resolution, as a JPEG next to the recordings."""
        self.send({"type": "snapshot"})

    def set_options(self, items):
        """Declare settings for pocket-viewer's Plugins menu, e.g.
        {"key": "follow", "title": "Follow", "type": "bool", "value": True} or
        {"key": "to", "title": "Translate to", "type": "choice", "choices": [["en", "English"]], "value": "en"}.
        Changes arrive in on_set; send again whenever values change."""
        self.send({"type": "options", "items": items})

    def log(self, text):
        self.send({"type": "log", "text": str(text)})

    # --- receiving ---------------------------------------------------------

    def on_hello(self, hello): pass
    def on_video(self, frame: VideoFrame): pass
    def on_audio(self, chunk: AudioChunk): pass
    def on_state(self, state): pass
    def on_set(self, key, value): pass
    def on_input(self, event): pass  # {"event": "click", x, y} / {"event": "select", x, y, w, h} / {"event": "cancel"}

    def _read_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("pocket-viewer closed the connection")
            buf += chunk
        return bytes(buf)

    def receive(self):
        """Read one message; returns (header, payload)."""
        (hlen,) = struct.unpack(">I", self._read_exact(4))
        header = json.loads(self._read_exact(hlen))
        payload = self._read_exact(header["size"]) if header.get("size") else b""
        return header, payload

    def run(self, video=None, audio=None, state=False, input=False):
        """Subscribe and dispatch messages until pocket-viewer goes away."""
        self.subscribe(video=video, audio=audio, state=state, input=input)
        try:
            while True:
                h, payload = self.receive()
                t = h.get("type")
                if t == "hello":
                    self.hello = h
                    self.on_hello(h)
                elif t == "video":
                    self.on_video(VideoFrame(h["pts"], h["width"], h["height"], h["format"], payload))
                elif t == "audio":
                    self.on_audio(AudioChunk(h["pts"], int(h["rate"]), h["channels"], h["frames"], payload))
                elif t == "input":
                    self.on_input(h)
                elif t == "set":
                    self.on_set(h.get("key"), h.get("value"))
                elif t == "state":
                    self.state = h
                    self.on_state(h)
        except (ConnectionError, BrokenPipeError):
            pass
