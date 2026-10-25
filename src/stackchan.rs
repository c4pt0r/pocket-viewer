//! The M5Stack StackChan robot as camera and gimbal. It runs
//! stackchan/firmware/stackchan-cam and is plugged in over USB, where it shows
//! up as a serial port. It sends JPEG frames and its head angles up and takes
//! move commands down:
//!
//!   up    "SCF1", a type byte ('J' JPEG, 'S' state JSON), u32 LE length, payload
//!   down  text lines: "stream" (re-sent every second, or it stops), "move YAW PITCH",
//!         "show LENGTH" and that many bytes of JPEG for its screen, "show off"
//!
//! Yaw and pitch are pan and tilt as on the Pocket 3: + turns the camera right
//! and up.

use std::io::{Read, Write};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime};

use bytes::Bytes;
use serde_json::{json, Value};

use crate::frame::{cover_rgb, decode_jpeg, encode_jpeg, jpeg_size, Frame, Pixels};
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
    fixed: Option<String>, // the port given with -d stackchan:PORT; else found on USB
    writer: Mutex<Option<Box<dyn serialport::SerialPort>>>, // used by the tx thread only, once set
    write_failed: AtomicBool, // the tx thread lost the port; the reader reconnects
    state: Mutex<Option<Value>>, // the robot's last report
    tx: (Mutex<Tx>, Condvar),
}

/// What waits to go down to the robot. One thread writes it all, so the reader
/// never waits on a write: a write can block while the robot is busy sending,
/// and the robot gets to read only once we have read what it sends.
#[derive(Default)]
struct Tx {
    lines: VecDeque<String>,
    picture: Option<Picture>, // only the newest
}

enum Picture {
    Show(Bytes),
    Off,
}

pub type FrameSink = Arc<dyn Fn(Frame) + Send + Sync>;

impl Link {
    /// Connects on a thread of its own and keeps reconnecting, so the robot can
    /// be plugged in late, unplugged or reset while the app runs. Without a
    /// port, it looks for one on USB.
    pub fn start(port: Option<String>, on_frame: FrameSink) -> Arc<Link> {
        let link = Arc::new(Link {
            fixed: port,
            writer: Mutex::new(None),
            write_failed: AtomicBool::new(false),
            state: Mutex::new(None),
            tx: Default::default(),
        });
        let l = link.clone();
        std::thread::Builder::new().name("stackchan".into()).spawn(move || l.run(on_frame)).unwrap();
        let l = link.clone();
        std::thread::Builder::new().name("stackchan-tx".into()).spawn(move || l.run_tx()).unwrap();
        link
    }

    /// The robot's screen size, if its firmware can show pictures (stackchan-cam 2).
    pub fn screen(&self) -> Option<(u32, u32)> {
        let st = self.state()?;
        let s = st.get("screen")?.as_array()?;
        let (w, h) = (s.first()?.as_u64()? as u32, s.get(1)?.as_u64()? as u32);
        (w > 0 && h > 0).then_some((w, h))
    }

    /// Puts a JPEG on the robot's screen, scaled to fill it. Returns at once; a
    /// picture still waiting when the next arrives is dropped.
    pub fn show(&self, jpeg: Bytes) {
        self.tx.0.lock().unwrap().picture = Some(Picture::Show(jpeg));
        self.tx.1.notify_one();
    }

    /// Back to the robot's status screen.
    pub fn show_off(&self) {
        self.tx.0.lock().unwrap().picture = Some(Picture::Off);
        self.tx.1.notify_one();
    }

    pub fn state(&self) -> Option<Value> {
        self.state.lock().unwrap().clone()
    }

    /// Queues a command for the robot.
    pub fn send_line(&self, line: &str) {
        let mut tx = self.tx.0.lock().unwrap();
        if tx.lines.len() >= 64 {
            tx.lines.pop_front(); // not connected, or not reading: keep the newest
        }
        tx.lines.push_back(format!("{line}\n"));
        self.tx.1.notify_one();
    }

    /// The tx thread: commands first, then the newest picture, and "stream" every second.
    fn run_tx(&self) {
        let mut last_stream = Instant::now() - Duration::from_secs(1);
        loop {
            let (data, picture) = {
                let mut tx = self.tx.0.lock().unwrap();
                loop {
                    if let Some(line) = tx.lines.pop_front() {
                        break (line.into_bytes(), None);
                    }
                    if let Some(p) = tx.picture.take() {
                        break (Vec::new(), Some(p));
                    }
                    let due = Duration::from_secs(1).saturating_sub(last_stream.elapsed());
                    if due.is_zero() {
                        last_stream = Instant::now();
                        break (b"stream\n".to_vec(), None);
                    }
                    tx = self.tx.1.wait_timeout(tx, due).unwrap().0;
                }
            };
            let data = match picture {
                None => data,
                Some(Picture::Off) => b"show off\n".to_vec(),
                Some(Picture::Show(jpeg)) => {
                    let Some((w, h)) = self.screen() else { continue };
                    // Re-encoded here so the robot always gets a baseline JPEG
                    // of its screen's size, whatever the browser sent.
                    let Some((sw, sh, rgb)) = decode_jpeg(&jpeg) else { continue };
                    let Some(out) = encode_jpeg(&cover_rgb(&rgb, sw, sh, w, h), w, h, 70) else { continue };
                    // The newline first: if the robot ever lost bytes of a picture
                    // (its USB queue overflowed), it is back in step at the next one.
                    let mut packet = format!("\nshow {}\n", out.len()).into_bytes();
                    packet.extend_from_slice(&out);
                    packet
                }
            };
            let mut w = self.writer.lock().unwrap();
            if let Some(port) = w.as_mut() {
                if port.write_all(&data).is_err() {
                    *w = None;
                    self.write_failed.store(true, Ordering::Relaxed);
                }
            }
        }
    }

    fn run(self: Arc<Self>, on_frame: FrameSink) {
        let mut last_error = String::new();
        loop {
            let Some(port) = self.fixed.clone().or_else(find_port) else {
                if last_error != "missing" {
                    crate::log!("no StackChan on USB yet; plug it in (and press its power button)");
                    last_error = "missing".into();
                }
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            match self.session(&port, &on_frame) {
                Ok(()) => crate::log!("StackChan: {port} disconnected, waiting for it"),
                Err(e) => {
                    let e = e.to_string();
                    if e != last_error {
                        crate::log!("StackChan: cannot use {port}: {e}");
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
    fn session(&self, path: &str, on_frame: &FrameSink) -> anyhow::Result<()> {
        let mut port = serialport::new(path, 115_200).timeout(Duration::from_millis(200)).open()?;
        // DTR on tells the robot's USB CDC someone is listening. RTS stays off:
        // RTS without DTR is half of the sequence that reboots it into the bootloader.
        // Best effort: a virtual port (a pty) has neither line.
        let _ = port.write_data_terminal_ready(true);
        let _ = port.write_request_to_send(false);
        self.tx.0.lock().unwrap().lines.clear(); // stale commands from before
        self.write_failed.store(false, Ordering::Relaxed);
        let mut writer = port.try_clone()?;
        writer.set_timeout(Duration::from_secs(1))?; // the robot may be busy sending for a while
        *self.writer.lock().unwrap() = Some(writer);
        crate::log!("StackChan: connected on {path}");
        self.send_line("stream");

        let mut buf: Vec<u8> = Vec::with_capacity(1 << 20);
        let mut chunk = vec![0u8; 1 << 16];
        let mut frames = 0u64;
        loop {
            if self.write_failed.load(Ordering::Relaxed) {
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
