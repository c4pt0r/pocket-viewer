#!/usr/bin/env python3
"""face-follow for Linux and Windows: the Swift plugin's port, with OpenCV in
place of Apple Vision. Boxes every face and turns the gimbal to keep the
largest one framed.

    python3 plugins/python/face_follow.py [--no-follow] [--no-boxes] [--verbose]
        [--gain 0.8] [--deadzone 0.06] [--target-y 0.4] [--name face-follow] [--model PATH]

Needs OpenCV and numpy (apt install python3-opencv). Faces are found with
YuNet if its model is at --model (default
~/.cache/pocket-viewer/face_detection_yunet_2023mar.onnx, from
github.com/opencv/opencv_zoo), otherwise with OpenCV's Haar cascade.
"""

import argparse
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pocketviewer  # noqa: E402

DEFAULT_MODEL = os.path.expanduser("~/.cache/pocket-viewer/face_detection_yunet_2023mar.onnx")

# Pocket 3 field of view at zoom 100 (16:9); other cameras report state.fov.
WIDE_FOV = 95.0
NARROW_FOV = WIDE_FOV * 9 / 16


class Detector:
    """Faces as (x, y, w, h, confidence), normalized top-left, largest first."""

    def __init__(self, model):
        self.yunet = None
        self.size = None
        if model and os.path.exists(model):
            self.model = model
            self.kind = "YuNet"
        else:
            path = os.path.join(cv2.data.haarcascades if hasattr(cv2, "data") else "/usr/share/opencv4/haarcascades",
                                "haarcascade_frontalface_default.xml")
            self.haar = cv2.CascadeClassifier(path)
            self.kind = "Haar cascade"

    def detect(self, bgr):
        h, w = bgr.shape[:2]
        faces = []
        if self.kind == "YuNet":
            if self.size != (w, h):
                self.yunet = cv2.FaceDetectorYN.create(self.model, "", (w, h), 0.7)
                self.size = (w, h)
            _, found = self.yunet.detect(bgr)
            for f in found if found is not None else []:
                faces.append((f[0] / w, f[1] / h, f[2] / w, f[3] / h, float(f[14])))
        else:
            gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
            for x, y, fw, fh in self.haar.detectMultiScale(gray, 1.1, 5, minSize=(24, 24)):
                faces.append((x / w, y / h, fw / w, fh / h, 1.0))
        return sorted(faces, key=lambda f: f[2] * f[3], reverse=True)


class Follower:
    """Turns the gimbal so a point in the picture moves to a target point.

    It moves only once the gimbal has reached its last target and held still:
    a frame taken mid-move shows an error that is already being corrected, and
    acting on it again overshoots and oscillates.
    """

    def __init__(self, gain=0.8, deadzone=0.06):
        self.gain = gain          # fraction of the error corrected per move
        self.deadzone = deadzone  # normalized distance from the target that counts as framed
        self.settle = 0.4         # seconds the gimbal must hold still before the next move
        self.max_step = 20.0      # degrees per move
        self.log = None
        self.settled_since = None

    def reset(self):
        self.settled_since = None

    def update(self, point, target, frame, pv):
        st = pv.state
        try:
            pan, tilt = float(st["pan"]), float(st["tilt"])
            actual_pan, actual_tilt = float(st["actualPan"]), float(st["actualTilt"])
        except (KeyError, TypeError, ValueError):
            return
        now = time.monotonic()
        if abs(pan - actual_pan) >= 1 or abs(tilt - actual_tilt) >= 1:
            self.settled_since = None
            return
        if self.settled_since is None:
            self.settled_since = now
        if now - self.settled_since < self.settle:
            return

        ex, ey = point[0] - target[0], point[1] - target[1]
        if abs(ex) <= self.deadzone and abs(ey) <= self.deadzone:
            return
        zoom = max(1.0, float(st.get("zoom") or 100) / 100)
        landscape = frame.width >= frame.height
        fov = st.get("fov")
        wide, narrow = (fov[0], fov[1]) if isinstance(fov, list) and len(fov) == 2 else (WIDE_FOV, NARROW_FOV)
        hfov = (wide if landscape else narrow) / zoom
        vfov = (narrow if landscape else wide) / zoom
        # +pan turns right, +tilt turns up. Absolute targets from the real
        # position, so nothing accumulates if a move falls short.
        clamp = lambda v: max(-self.max_step, min(self.max_step, v))  # noqa: E731
        dpan = clamp(ex * hfov * self.gain) if abs(ex) > self.deadzone else 0
        dtilt = clamp(-ey * vfov * self.gain) if abs(ey) > self.deadzone else 0
        pv.gimbal(pan=actual_pan + dpan, tilt=actual_tilt + dtilt)
        if self.log:
            self.log(f"at ({point[0]:.2f}, {point[1]:.2f}) err ({ex:+.2f}, {ey:+.2f}) → "
                     f"pan {actual_pan:.1f}{dpan:+.1f} tilt {actual_tilt:.1f}{dtilt:+.1f} (zoom {zoom * 100:.0f}%)")
        self.settled_since = None


class FaceFollow(pocketviewer.Plugin):
    def __init__(self, opt):
        super().__init__(opt.name)
        self.opt = opt
        self.detector = Detector(opt.model)
        self.follower = Follower(opt.gain, opt.deadzone)
        if opt.verbose:
            self.follower.log = lambda s: self.log("face " + s)
        self.last_count = -1

    def on_video(self, frame):
        if frame.format != "bgra":
            return
        opt = self.opt
        bgra = np.frombuffer(frame.data, np.uint8).reshape(frame.height, frame.width, 4)
        faces = self.detector.detect(cv2.cvtColor(bgra, cv2.COLOR_BGRA2BGR))
        if len(faces) != self.last_count:
            n = f"{len(faces)} face{'' if len(faces) == 1 else 's'}"
            self.log(n + " in view")
            self.hud("🙂 " + n + (" · following" if opt.follow and faces else ""),
                     color="#00ff88" if faces else "#bbbbbb")
            self.last_count = len(faces)
        if opt.boxes:
            ty = opt.target_y
            items = [  # target point
                {"shape": "line", "x1": 0.48, "y1": ty, "x2": 0.52, "y2": ty, "color": "#ffffff80", "width": 1},
                {"shape": "line", "x1": 0.5, "y1": ty - 0.03, "x2": 0.5, "y2": ty + 0.03, "color": "#ffffff80", "width": 1},
            ]
            for i, (x, y, w, h, conf) in enumerate(faces):
                items.append({"shape": "rect", "x": x, "y": y, "w": w, "h": h,
                              "color": "#00ff88" if i == 0 else "#ffffffaa", "width": 3 if i == 0 else 1.5,
                              "label": ("following" if opt.follow else "face") if i == 0 else f"{conf * 100:.0f}%"})
            self.draw("faces", items, ttl=0.5)

        if opt.follow and faces:
            x, y, w, h, _ = faces[0]
            self.follower.update((x + w / 2, y + h / 2), (0.5, opt.target_y), frame, self)

    # Settings in pocket-viewer's Plugins menu; they apply immediately.
    def declare_options(self):
        opt = self.opt
        self.set_options([
            {"key": "follow", "title": "Move the gimbal to follow", "type": "bool", "value": opt.follow},
            {"key": "boxes", "title": "Show face boxes", "type": "bool", "value": opt.boxes},
            {"key": "gain", "title": "Correction per move", "type": "choice", "value": opt.gain,
             "choices": [[0.5, "Gentle (50%)"], [0.8, "Normal (80%)"], [1.0, "Full (100%)"]]},
            {"key": "targetY", "title": "Keep the face at", "type": "choice", "value": opt.target_y,
             "choices": [[0.33, "Upper third"], [0.4, "Slightly above center"], [0.5, "Center"]]},
        ])

    def on_set(self, key, value):
        opt = self.opt
        if key == "follow" and isinstance(value, bool):
            opt.follow = value
        elif key == "boxes" and isinstance(value, bool):
            opt.boxes = value
            if not value:
                self.clear("faces")
        elif key == "gain" and isinstance(value, (int, float)):
            opt.gain = self.follower.gain = float(value)
        elif key == "targetY" and isinstance(value, (int, float)):
            opt.target_y = float(value)
        else:
            return
        self.follower.reset()
        self.last_count = -1  # refresh the HUD
        self.log(f"{key} → {value}")
        self.declare_options()


def main():
    p = argparse.ArgumentParser(description="pocket-viewer plugin: keep the largest face framed")
    p.add_argument("--no-follow", dest="follow", action="store_false")
    p.add_argument("--no-boxes", dest="boxes", action="store_false")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--gain", type=float, default=0.8)
    p.add_argument("--deadzone", type=float, default=0.06)
    p.add_argument("--target-y", type=float, default=0.4)
    p.add_argument("--name", default="face-follow")
    p.add_argument("--model", default=DEFAULT_MODEL)
    opt = p.parse_args()

    pv = FaceFollow(opt)
    pv.declare_options()
    pv.log(f"face-follow started ({pv.detector.kind}, follow: {opt.follow}, gain {opt.gain})")
    pv.run(video={"maxWidth": 640, "fps": 15, "format": "bgra"}, state=True)


if __name__ == "__main__":
    main()
