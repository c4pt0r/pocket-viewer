//! The Pocket 3 (or any webcam) through the platform camera API, via nokhwa:
//! AVFoundation on macOS, Media Foundation on Windows, V4L2 on Linux.
//!
//! The camera lives on a thread of its own, which also serves format changes
//! and, off macOS, the gimbal's controls (they need the open camera). On macOS
//! the gimbal goes through gimbal.c instead, which works alongside capture.

use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use nokhwa::pixel_format::RgbFormat;
use nokhwa::utils::{ApiBackend, CameraFormat, CameraIndex, FrameFormat, RequestedFormat, RequestedFormatType, Resolution};
use nokhwa::Camera;

use crate::frame::{Frame, Pixels};
use crate::stackchan::FrameSink;

/// The Pocket 3's name as cameras are listed on every platform.
pub const POCKET3: &str = "OsmoPocket3";

/// Resolutions the Pocket 3 offers in webcam mode, at up to 30 fps. AVFoundation
/// doesn't let nokhwa list formats, so this list is what the UI offers.
pub const SIZES: &[(u32, u32)] =
    &[(1280, 720), (1920, 1080), (3840, 2160), (720, 1280), (1080, 1920), (2160, 3840)];
pub const RATES: &[u32] = &[24, 25, 30];

#[derive(Clone, Debug, Default)]
pub struct Info {
    pub name: Option<String>, // the camera in use; None while looking for it
    pub width: u32,
    pub height: u32,
    pub fps: u32,
}

enum Request {
    Format(u32, u32, u32),
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    Control(Ctl, mpsc::Sender<Option<(i64, i64, i64)>>),
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
#[derive(Clone, Copy, Debug)]
enum Ctl {
    Get(nokhwa::utils::KnownCameraControl),
    Set(nokhwa::utils::KnownCameraControl, i64),
}

#[derive(Clone)]
pub struct Uvc {
    tx: mpsc::Sender<Request>,
    pub info: Arc<Mutex<Info>>,
}

/// Every camera the platform lists, by name.
pub fn list() -> Vec<String> {
    init();
    nokhwa::query(ApiBackend::Auto).map(|v| v.iter().map(|c| c.human_name()).collect()).unwrap_or_default()
}

fn init() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // On macOS this asks for camera access; frames fail until it is granted.
        nokhwa::nokhwa_initialize(|granted| {
            if !granted {
                crate::log!("camera access denied: allow it in System Settings → Privacy & Security → Camera");
            }
        });
    });
}

impl Uvc {
    /// Opens the first camera whose name contains `name` (retrying until it
    /// appears) and sends its frames to `on_frame`.
    pub fn start(name: String, width: u32, height: u32, fps: u32, on_frame: FrameSink) -> Uvc {
        let (tx, rx) = mpsc::channel();
        let info = Arc::new(Mutex::new(Info { name: None, width, height, fps }));
        let i = info.clone();
        std::thread::Builder::new().name("camera".into()).spawn(move || run(name, i, rx, on_frame)).unwrap();
        Uvc { tx, info }
    }

    pub fn set_format(&self, width: u32, height: u32, fps: u32) {
        let _ = self.tx.send(Request::Format(width, height, fps));
    }
}

fn find(name: &str) -> Option<(CameraIndex, String)> {
    let cams = nokhwa::query(ApiBackend::Auto).ok()?;
    let needle = name.to_lowercase();
    cams.into_iter()
        .find(|c| c.human_name().to_lowercase().contains(&needle))
        .map(|c| (c.index().clone(), c.human_name()))
}

fn run(name: String, info: Arc<Mutex<Info>>, rx: mpsc::Receiver<Request>, on_frame: FrameSink) {
    init();
    let mut said_missing = false;
    loop {
        let Some((index, found)) = find(&name) else {
            if !said_missing {
                crate::log!("camera \"{name}\" not found; waiting for it (is the Pocket 3 in webcam mode?)");
                said_missing = true;
            }
            // Format changes still count while waiting.
            if let Ok(Request::Format(w, h, f)) = rx.recv_timeout(Duration::from_secs(2)) {
                let mut i = info.lock().unwrap();
                (i.width, i.height, i.fps) = (w, h, f);
            }
            continue;
        };
        said_missing = false;
        let (w, h, f) = {
            let i = info.lock().unwrap();
            (i.width, i.height, i.fps)
        };
        let want = CameraFormat::new(Resolution::new(w, h), FrameFormat::YUYV, f);
        let mut cam = match Camera::new(index, RequestedFormat::new::<RgbFormat>(RequestedFormatType::Closest(want))) {
            Ok(c) => c,
            Err(e) => {
                crate::log!("cannot open {found}: {e}");
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        if let Err(e) = cam.open_stream() {
            crate::log!("cannot start {found}: {e}");
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }
        let got = cam.camera_format();
        crate::log!("camera: {found}, {}x{} at {} fps", got.width(), got.height(), got.frame_rate());
        {
            let mut i = info.lock().unwrap();
            *i = Info { name: Some(found.clone()), width: got.width(), height: got.height(), fps: got.frame_rate() };
        }

        // Capture until the camera fails or the format changes.
        let mut failures = 0;
        'stream: loop {
            for req in rx.try_iter() {
                match req {
                    Request::Format(w, h, f) => {
                        let mut i = info.lock().unwrap();
                        (i.width, i.height, i.fps) = (w, h, f);
                        break 'stream;
                    }
                    Request::Control(ctl, reply) => {
                        let _ = reply.send(control(&mut cam, ctl));
                    }
                }
            }
            match cam.frame() {
                Ok(buf) => {
                    failures = 0;
                    let pts = crate::now();
                    let res = buf.resolution();
                    let (w, h) = (res.width(), res.height());
                    let data = buf.buffer();
                    let n = (w * h) as usize;
                    // Trust the size over the label: some backends convert behind nokhwa's back.
                    let pixels = match buf.source_frame_format() {
                        FrameFormat::MJPEG => Pixels::Jpeg(bytes::Bytes::copy_from_slice(data)),
                        _ if data.len() == n * 3 / 2 => Pixels::Nv12(data.to_vec()),
                        FrameFormat::YUYV if data.len() == n * 2 => Pixels::Yuyv(data.to_vec()),
                        FrameFormat::RAWRGB if data.len() == n * 3 => Pixels::Rgb(data.to_vec()),
                        FrameFormat::RAWBGR if data.len() == n * 3 => {
                            Pixels::Rgb(data.chunks_exact(3).flat_map(|p| [p[2], p[1], p[0]]).collect())
                        }
                        FrameFormat::GRAY if data.len() == n => Pixels::Rgb(data.iter().flat_map(|&g| [g, g, g]).collect()),
                        other => {
                            crate::log!("unsupported camera pixels: {other:?}, {} bytes for {w}x{h}", data.len());
                            std::thread::sleep(Duration::from_secs(1));
                            continue;
                        }
                    };
                    on_frame(Frame::new(pts, w, h, pixels));
                }
                Err(e) => {
                    failures += 1;
                    if failures == 1 || failures % 100 == 0 {
                        crate::log!("camera: {e}");
                    }
                    if failures > 30 {
                        crate::log!("camera {found} stopped delivering frames; reopening");
                        break 'stream;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
        let _ = cam.stop_stream();
        info.lock().unwrap().name = None;
    }
}

/// (min, max, value) of an integer control, after setting it if asked.
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn control(cam: &mut Camera, ctl: Ctl) -> Option<(i64, i64, i64)> {
    use nokhwa::utils::{ControlValueDescription as D, ControlValueSetter};
    let which = match ctl {
        Ctl::Get(k) | Ctl::Set(k, _) => k,
    };
    if let Ctl::Set(_, v) = ctl {
        cam.set_camera_control(which, ControlValueSetter::Integer(v)).ok()?;
    }
    match cam.camera_control(which).ok()?.description().clone() {
        D::IntegerRange { min, max, value, .. } => Some((min, max, value)),
        D::Integer { value, .. } => Some((value, value, value)),
        _ => None,
    }
}

/// The Pocket 3's gimbal through the camera API's pan/tilt/zoom controls, for
/// Linux (V4L2) and Windows (Media Foundation). Roll has no standard control
/// there and is not offered.
#[cfg(not(target_os = "macos"))]
pub struct Controls {
    tx: mpsc::Sender<Request>,
    arcsec: bool, // V4L2 reports pan/tilt in arc-seconds, DirectShow in degrees
}

#[cfg(not(target_os = "macos"))]
impl Controls {
    pub fn new(uvc: &Uvc) -> Controls {
        Controls { tx: uvc.tx.clone(), arcsec: false }
    }

    fn ask(&self, ctl: Ctl) -> Option<(i64, i64, i64)> {
        let (tx, rx) = mpsc::channel();
        self.tx.send(Request::Control(ctl, tx)).ok()?;
        rx.recv_timeout(Duration::from_secs(2)).ok()?
    }

    fn deg(&self, v: i64) -> f64 {
        if self.arcsec { v as f64 / 3600.0 } else { v as f64 }
    }

    fn raw(&self, deg: f64) -> i64 {
        if self.arcsec { (deg * 3600.0).round() as i64 } else { deg.round() as i64 }
    }
}

#[cfg(not(target_os = "macos"))]
impl crate::gimbal::Backend for Controls {
    fn open(&mut self) -> Option<crate::gimbal::Range> {
        use nokhwa::utils::KnownCameraControl as K;
        let (pmin, pmax, _) = self.ask(Ctl::Get(K::Pan))?;
        let (tmin, tmax, _) = self.ask(Ctl::Get(K::Tilt))?;
        self.arcsec = pmax.abs().max(pmin.abs()) > 720;
        let zoom = self.ask(Ctl::Get(K::Zoom)).map(|(a, b, _)| (a as i32, b as i32)).unwrap_or((100, 100));
        Some(crate::gimbal::Range {
            pan: (self.deg(pmin), self.deg(pmax)),
            tilt: (self.deg(tmin), self.deg(tmax)),
            zoom,
            roll: false,
        })
    }
    fn get(&mut self) -> Option<(f64, f64)> {
        use nokhwa::utils::KnownCameraControl as K;
        let (_, _, p) = self.ask(Ctl::Get(K::Pan))?;
        let (_, _, t) = self.ask(Ctl::Get(K::Tilt))?;
        Some((self.deg(p), self.deg(t)))
    }
    fn set(&mut self, pan: f64, tilt: f64) {
        use nokhwa::utils::KnownCameraControl as K;
        self.ask(Ctl::Set(K::Pan, self.raw(pan)));
        self.ask(Ctl::Set(K::Tilt, self.raw(tilt)));
    }
    fn get_zoom(&mut self) -> Option<i32> {
        self.ask(Ctl::Get(nokhwa::utils::KnownCameraControl::Zoom)).map(|(_, _, v)| v as i32).or(Some(100))
    }
    fn set_zoom(&mut self, zoom: i32) {
        self.ask(Ctl::Set(nokhwa::utils::KnownCameraControl::Zoom, zoom as i64));
    }
}
