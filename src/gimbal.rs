//! Pan / tilt / zoom / roll, behind one controller whatever moves the camera:
//! the Pocket 3 (UVC camera-terminal controls; on macOS through gimbal.c and
//! IOKit, elsewhere through the camera API) or the StackChan's servos.
//!
//! The controller owns the device on a thread of its own. Input only moves
//! targets; the thread sends the latest one (so key repeat and mouse drags
//! never queue up), glides zoom one level at a time, and reads the real
//! position back every 0.2 s.

use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

#[derive(Clone, Copy, Debug)]
pub struct Range {
    pub pan: (f64, f64),
    pub tilt: (f64, f64),
    pub zoom: (i32, i32),
    pub roll: bool,
}

/// A pan/tilt head. Methods block for at most a USB round trip.
pub trait Backend: Send {
    fn open(&mut self) -> Option<Range>;
    fn get(&mut self) -> Option<(f64, f64)>;
    fn set(&mut self, pan: f64, tilt: f64);
    fn get_zoom(&mut self) -> Option<i32> {
        Some(100)
    }
    fn set_zoom(&mut self, _zoom: i32) {}
    fn get_roll(&mut self) -> Option<f64> {
        Some(0.0)
    }
    fn set_roll(&mut self, _roll: f64) {}
}

#[derive(Debug, Clone, Copy)]
pub enum Cmd {
    /// Absolute values win over relative ones.
    Move { pan: Option<f64>, tilt: Option<f64>, dpan: f64, dtilt: f64 },
    Zoom { zoom: Option<f64>, dzoom: f64 },
    Roll { roll: Option<f64>, droll: f64 },
    Center,
}

#[derive(Default)]
struct State {
    range: Option<Range>, // None: no gimbal (yet)
    pan: f64,             // commanded
    tilt: f64,
    actual_pan: f64, // read back
    actual_tilt: f64,
    roll: f64,
    zoom_target: f64,
    zoom: i32, // last level sent
}

#[derive(Clone)]
pub struct Gimbal {
    state: Arc<Mutex<State>>,
    tx: mpsc::Sender<Cmd>,
}

fn clamp(x: f64, (lo, hi): (f64, f64)) -> f64 {
    x.max(lo).min(hi)
}

impl Gimbal {
    /// Starts the controller. Without a backend it reports no gimbal.
    pub fn spawn(backend: Option<Box<dyn Backend>>) -> Gimbal {
        let state = Arc::new(Mutex::new(State::default()));
        let (tx, rx) = mpsc::channel();
        if let Some(backend) = backend {
            let st = state.clone();
            std::thread::Builder::new().name("gimbal".into()).spawn(move || run(backend, st, rx)).unwrap();
        }
        Gimbal { state, tx }
    }

    pub fn command(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }

    pub fn available(&self) -> bool {
        self.state.lock().unwrap().range.is_some()
    }

    /// The plugin protocol's gimbal fields: pan/tilt are the commanded target,
    /// actualPan/actualTilt the last readback. Empty without a gimbal.
    pub fn state_json(&self) -> Map<String, Value> {
        let s = self.state.lock().unwrap();
        let Some(r) = s.range else { return Map::new() };
        let v = json!({
            "pan": s.pan, "tilt": s.tilt,
            "actualPan": s.actual_pan, "actualTilt": s.actual_tilt,
            "roll": s.roll, "zoom": s.zoom_target,
            "panRange": [r.pan.0, r.pan.1], "tiltRange": [r.tilt.0, r.tilt.1],
            "zoomRange": [r.zoom.0, r.zoom.1], "hasRoll": r.roll,
        });
        match v {
            Value::Object(m) => m,
            _ => unreachable!(),
        }
    }
}

fn run(mut dev: Box<dyn Backend>, state: Arc<Mutex<State>>, rx: mpsc::Receiver<Cmd>) {
    // Wait for the device: the Pocket 3 may be plugged in after launch.
    let range = loop {
        if let Some(r) = dev.open() {
            break r;
        }
        // Drop input that arrives meanwhile; there is nothing to move yet.
        match rx.recv_timeout(Duration::from_secs(2)) {
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
            _ => while rx.try_recv().is_ok() {},
        }
    };
    let (pan, tilt) = dev.get().unwrap_or((0.0, 0.0));
    let zoom = dev.get_zoom().unwrap_or(range.zoom.0);
    let roll = dev.get_roll().unwrap_or(0.0);
    {
        let mut s = state.lock().unwrap();
        *s = State {
            range: Some(range),
            pan,
            tilt,
            actual_pan: pan,
            actual_tilt: tilt,
            roll,
            zoom_target: zoom as f64,
            zoom,
        };
    }
    crate::log!("gimbal ready: pan {:.0}…{:.0}°, tilt {:.0}…{:.0}°", range.pan.0, range.pan.1, range.tilt.0, range.tilt.1);

    let mut zoom_pos = zoom as f64;
    let mut last_command = Instant::now() - Duration::from_secs(10);
    let mut last_poll = Instant::now();
    loop {
        let first = match rx.recv_timeout(Duration::from_millis(16)) {
            Ok(c) => Some(c),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        };
        let (mut moved, mut rolled) = (false, false);
        {
            let mut s = state.lock().unwrap();
            for cmd in first.into_iter().chain(rx.try_iter()) {
                match cmd {
                    Cmd::Move { pan, tilt, dpan, dtilt } => {
                        s.pan = clamp(pan.unwrap_or(s.pan + dpan), range.pan);
                        s.tilt = clamp(tilt.unwrap_or(s.tilt + dtilt), range.tilt);
                        moved = true;
                    }
                    Cmd::Zoom { zoom, dzoom } => {
                        let z = zoom.unwrap_or(s.zoom_target + dzoom);
                        s.zoom_target = z.max(range.zoom.0 as f64).min(range.zoom.1 as f64);
                    }
                    Cmd::Roll { roll, droll } => {
                        s.roll = roll.unwrap_or(s.roll + droll).clamp(-30.0, 30.0);
                        rolled = true;
                    }
                    Cmd::Center => {
                        s.pan = clamp(0.0, range.pan);
                        s.tilt = clamp(0.0, range.tilt);
                        s.roll = 0.0;
                        moved = true;
                        rolled = true;
                    }
                }
            }
        }
        if moved {
            let (pan, tilt) = {
                let s = state.lock().unwrap();
                (s.pan, s.tilt)
            };
            dev.set(pan, tilt);
            last_command = Instant::now();
        }
        if rolled && range.roll {
            let roll = state.lock().unwrap().roll;
            dev.set_roll(roll);
        }

        // Zoom eases toward its target: a fraction of the remaining distance
        // per tick, at least half a level, so the camera never jumps.
        let (target, sent) = {
            let s = state.lock().unwrap();
            (s.zoom_target, s.zoom)
        };
        let diff = target - zoom_pos;
        if diff.abs() < 0.5 {
            zoom_pos = target;
        } else {
            let step = diff * 0.12;
            zoom_pos += if step.abs() < 0.5 { 0.5f64.copysign(diff) } else { step };
        }
        let z = zoom_pos.round() as i32;
        if z != sent {
            state.lock().unwrap().zoom = z;
            dev.set_zoom(z);
        }

        // Read back where it really is. Once nothing has been commanded for a
        // while, a mismatch means something else moved it (a plugin's own
        // client, the handle's follow mode): adopt that as the base.
        if last_poll.elapsed() >= Duration::from_millis(200) {
            last_poll = Instant::now();
            if let Some((pan, tilt)) = dev.get() {
                let mut s = state.lock().unwrap();
                s.actual_pan = pan;
                s.actual_tilt = tilt;
                if last_command.elapsed() > Duration::from_secs(2) && ((pan - s.pan).abs() > 1.0 || (tilt - s.tilt).abs() > 1.0) {
                    s.pan = pan;
                    s.tilt = tilt;
                }
            }
        }
    }
}

/// The Pocket 3 on macOS: gimbal.c sends UVC requests through IOKit.
#[cfg(target_os = "macos")]
pub mod iokit {
    use std::os::raw::c_int;

    #[repr(C)]
    #[derive(Default)]
    struct GimbalRange {
        pan_min: f64,
        pan_max: f64,
        tilt_min: f64,
        tilt_max: f64,
        zoom_min: c_int,
        zoom_max: c_int,
    }

    extern "C" {
        fn gimbal_open(range: *mut GimbalRange) -> c_int;
        fn gimbal_get(pan: *mut f64, tilt: *mut f64) -> c_int;
        fn gimbal_set(pan: f64, tilt: f64) -> c_int;
        fn gimbal_get_zoom(zoom: *mut c_int) -> c_int;
        fn gimbal_set_zoom(zoom: c_int) -> c_int;
        fn gimbal_get_roll(roll: *mut f64) -> c_int;
        fn gimbal_set_roll(roll: f64) -> c_int;
    }

    pub struct Pocket3;

    impl super::Backend for Pocket3 {
        fn open(&mut self) -> Option<super::Range> {
            let mut r = GimbalRange::default();
            (unsafe { gimbal_open(&mut r) } == 0).then_some(super::Range {
                pan: (r.pan_min, r.pan_max),
                tilt: (r.tilt_min, r.tilt_max),
                zoom: (r.zoom_min, r.zoom_max),
                roll: true,
            })
        }
        fn get(&mut self) -> Option<(f64, f64)> {
            let (mut p, mut t) = (0.0, 0.0);
            (unsafe { gimbal_get(&mut p, &mut t) } == 0).then_some((p, t))
        }
        fn set(&mut self, pan: f64, tilt: f64) {
            unsafe { gimbal_set(pan, tilt) };
        }
        fn get_zoom(&mut self) -> Option<i32> {
            let mut z = 0;
            (unsafe { gimbal_get_zoom(&mut z) } == 0).then_some(z)
        }
        fn set_zoom(&mut self, zoom: i32) {
            unsafe { gimbal_set_zoom(zoom) };
        }
        fn get_roll(&mut self) -> Option<f64> {
            let mut r = 0.0;
            (unsafe { gimbal_get_roll(&mut r) } == 0).then_some(r)
        }
        fn set_roll(&mut self, roll: f64) {
            unsafe { gimbal_set_roll(roll) };
        }
    }
}
