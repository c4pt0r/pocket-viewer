//! The M5Stack StackChan robot as camera and gimbal. It runs
//! stackchan/firmware/stackchan-cam and is plugged in over USB, where it shows
//! up as a serial port. It sends JPEG frames and its head angles up and takes
//! move commands down:
//!
//!   up    "SCF1", a type byte ('J' JPEG, 'S' state JSON), u32 LE length, payload
//!   down  text lines: "stream" (re-sent every second, or it stops), "move YAW PITCH"
//!
//! Yaw and pitch are pan and tilt as on the Pocket 3: + turns the camera right
//! and up.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use bytes::Bytes;
use serde_json::{json, Value};

use crate::frame::{jpeg_size, Frame, Pixels};
use crate::gimbal::{Backend, Range};

/// The serial port of a StackChan on USB (an Espressif device, VID 0x303a).
pub fn find_port() -> Option<String> {
    serialport::available_ports().ok()?.into_iter().find_map(|p| match p.port_type {
        // macOS lists each port twice; the callout (cu.) side doesn't wait for carrier.
        serialport::SerialPortType::UsbPort(u) if u.vid == 0x303a && !p.port_name.starts_with("/dev/tty.") => Some(p.port_name),
        _ => None,
    })
}

pub struct Link {
    port: String,
    writer: Mutex<Option<Box<dyn serialport::SerialPort>>>,
    state: Mutex<Option<Value>>, // the robot's last report
}

pub type FrameSink = Arc<dyn Fn(Frame) + Send + Sync>;

impl Link {
    /// Connects on a thread of its own and keeps reconnecting, so the robot can
    /// be unplugged or reset while the app runs.
    pub fn start(port: String, on_frame: FrameSink) -> Arc<Link> {
        let link = Arc::new(Link { port, writer: Mutex::new(None), state: Mutex::new(None) });
        let l = link.clone();
        std::thread::Builder::new().name("stackchan".into()).spawn(move || l.run(on_frame)).unwrap();
        link
    }

    pub fn state(&self) -> Option<Value> {
        self.state.lock().unwrap().clone()
    }

    pub fn send_line(&self, line: &str) {
        let mut w = self.writer.lock().unwrap();
        if let Some(port) = w.as_mut() {
            if port.write_all(format!("{line}\n").as_bytes()).is_err() {
                *w = None; // the reader notices too, and reconnects
            }
        }
    }

    fn run(self: Arc<Self>, on_frame: FrameSink) {
        let mut last_error = String::new();
        loop {
            match self.session(&on_frame) {
                Ok(()) => crate::log!("StackChan: {} disconnected, waiting for it", self.port),
                Err(e) => {
                    let e = e.to_string();
                    if e != last_error {
                        crate::log!("StackChan: cannot use {}: {e}", self.port);
                        last_error = e;
                    }
                }
            }
            *self.writer.lock().unwrap() = None;
            *self.state.lock().unwrap() = None;
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    /// One connection, until the port goes away.
    fn session(&self, on_frame: &FrameSink) -> anyhow::Result<()> {
        let mut port = serialport::new(&self.port, 115_200).timeout(Duration::from_millis(200)).open()?;
        // DTR on tells the robot's USB CDC someone is listening. RTS stays off:
        // RTS without DTR is half of the sequence that reboots it into the bootloader.
        port.write_data_terminal_ready(true)?;
        port.write_request_to_send(false)?;
        *self.writer.lock().unwrap() = Some(port.try_clone()?);
        crate::log!("StackChan: connected on {}", self.port);
        self.send_line("stream");

        let mut buf: Vec<u8> = Vec::with_capacity(1 << 20);
        let mut chunk = vec![0u8; 1 << 16];
        let mut last_keepalive = Instant::now();
        let mut frames = 0u64;
        loop {
            if last_keepalive.elapsed() >= Duration::from_secs(1) {
                self.send_line("stream");
                last_keepalive = Instant::now();
            }
            if self.writer.lock().unwrap().is_none() {
                return Ok(());
            }
            let n = match port.read(&mut chunk) {
                Ok(0) => return Ok(()),
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Ok(()), // unplugged
            };
            buf.extend_from_slice(&chunk[..n]);

            // Parse every complete packet; of several frames only the newest is worth showing.
            let mut latest: Option<Bytes> = None;
            let mut pos = 0;
            loop {
                let Some(at) = find(&buf[pos..], b"SCF1").map(|i| pos + i) else {
                    pos = pos.max(buf.len().saturating_sub(3)); // keep a partial magic
                    break;
                };
                if buf.len() < at + 9 {
                    pos = at;
                    break;
                }
                let len = u32::from_le_bytes([buf[at + 5], buf[at + 6], buf[at + 7], buf[at + 8]]) as usize;
                if len > 1 << 20 {
                    pos = at + 4; // not a real header: resync
                    continue;
                }
                if buf.len() < at + 9 + len {
                    pos = at;
                    break;
                }
                let payload = &buf[at + 9..at + 9 + len];
                match buf[at + 4] {
                    b'J' => latest = Some(Bytes::copy_from_slice(payload)),
                    b'S' => {
                        if let Ok(v @ Value::Object(_)) = serde_json::from_slice::<Value>(payload) {
                            *self.state.lock().unwrap() = Some(v);
                        }
                    }
                    _ => {}
                }
                pos = at + 9 + len;
            }
            buf.drain(..pos);
            if let Some(jpeg) = latest {
                if let Some((w, h)) = jpeg_size(&jpeg) {
                    frames += 1;
                    if frames == 1 {
                        crate::log!("StackChan: streaming {w}x{h}");
                    }
                    on_frame(Frame::new(crate::now(), w, h, Pixels::Jpeg(jpeg)));
                }
            }
        }
    }

    /// The head exactly as the robot last reported it; plugins get it as
    /// state.head (calibrate measures with it, since actualPan rounds).
    pub fn head(&self) -> Option<Value> {
        let st = self.state()?;
        Some(json!({"yaw": st.get("yaw")?.as_f64()?, "pitch": st.get("pitch")?.as_f64()?,
                    "moving": st.get("moving").and_then(Value::as_bool).unwrap_or(false)}))
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// The robot's head as a gimbal backend.
pub struct Head {
    pub link: Arc<Link>,
    target: Option<(f64, f64)>,
}

impl Head {
    pub fn new(link: Arc<Link>) -> Head {
        Head { link, target: None }
    }

    /// The first report after connecting, waiting up to 3 s.
    fn report(&self) -> Option<Value> {
        for _ in 0..30 {
            if let Some(st) = self.link.state() {
                return Some(st);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        None
    }
}

impl Backend for Head {
    fn open(&mut self) -> Option<Range> {
        let st = self.report()?;
        let r = |k: &str| -> Option<(f64, f64)> {
            let a = st.get(k)?.as_array()?;
            Some((a.first()?.as_f64()?, a.get(1)?.as_f64()?))
        };
        // No zoom: 100 keeps plugins' field-of-view maths at 1×.
        Some(Range { pan: r("yawRange")?, tilt: r("pitchRange")?, zoom: (100, 100), roll: false })
    }

    fn get(&mut self) -> Option<(f64, f64)> {
        let st = self.report()?;
        let (pan, tilt) = (st.get("yaw")?.as_f64()?, st.get("pitch")?.as_f64()?);
        // The servos stop 1–2° short of a target (their deadband). Once the head
        // is still, call that arrived, or closed loops that wait for the
        // readback to reach the target (face-follow) would wait forever.
        let moving = st.get("moving").and_then(Value::as_bool).unwrap_or(false);
        if let Some((tp, tt)) = self.target {
            if !moving && (pan - tp).abs() < 3.0 && (tilt - tt).abs() < 3.0 {
                return Some((tp, tt));
            }
        }
        Some((pan, tilt))
    }

    fn set(&mut self, pan: f64, tilt: f64) {
        self.target = Some((pan, tilt));
        self.link.send_line(&format!("move {pan:.1} {tilt:.1}"));
    }
}

/// Where calibrate saves its measurement.
pub fn calibration_path() -> std::path::PathBuf {
    crate::config_dir().join("stackchan.json")
}

/// The camera's field of view in degrees (horizontal, vertical): as measured by
/// plugins/bin/calibrate if it saved one, else the built-in 41° × 31°. A new
/// calibration takes effect without restarting.
pub fn fov() -> (f64, f64) {
    // Measured against a static ceiling: tilting 10° moved it 77.5 of 240 px,
    // so 31° tall; the width follows from the 4:3 sensor.
    static CACHE: Mutex<(Option<SystemTime>, (f64, f64))> = Mutex::new((None, (41.0, 31.0)));
    let mut cache = CACHE.lock().unwrap();
    let path = calibration_path();
    let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    if mtime.is_some() && mtime != cache.0 {
        cache.0 = mtime;
        let parsed = std::fs::read(&path)
            .ok()
            .and_then(|d| serde_json::from_slice::<Value>(&d).ok())
            .and_then(|v| Some((v["fov"][0].as_f64()?, v["fov"][1].as_f64()?)))
            .filter(|&(h, v)| (10.0..170.0).contains(&h) && (10.0..170.0).contains(&v));
        match parsed {
            Some(f) => {
                cache.1 = f;
                crate::log!("StackChan: field of view {:.1}° × {:.1}° (calibrated, {})", f.0, f.1, path.display());
            }
            None => crate::log!("StackChan: ignoring {} (no valid \"fov\")", path.display()),
        }
    }
    cache.1
}
