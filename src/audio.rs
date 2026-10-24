//! Audio input, its level, monitoring on an output device, and chunks for
//! plugins and the recorder. cpal streams can't move between threads, so one
//! thread owns them and takes commands.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{mpsc, Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};
use tokio::sync::broadcast;

/// Interleaved f32 samples as the input delivered them.
pub struct Chunk {
    pub pts: f64, // app clock, at the start of the chunk
    pub rate: u32,
    pub channels: u16,
    pub samples: Vec<f32>,
}

#[derive(Clone, Default, serde::Serialize)]
pub struct Status {
    pub input: Option<String>, // None: no audio
    pub output: Option<String>,
    pub monitoring: bool,
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
}

enum Cmd {
    Input(Option<String>),
    Output(Option<String>),
    Monitor(bool),
}

#[derive(Clone)]
pub struct Audio {
    tx: mpsc::Sender<Cmd>,
    level: Arc<AtomicU32>, // f32 bits, dBFS
    pub chunks: broadcast::Sender<Arc<Chunk>>,
    status: Arc<Mutex<Status>>,
}

pub fn input_names() -> Vec<String> {
    cpal::default_host().input_devices().map(|d| d.filter_map(|d| d.name().ok()).collect()).unwrap_or_default()
}

pub fn output_names() -> Vec<String> {
    cpal::default_host().output_devices().map(|d| d.filter_map(|d| d.name().ok()).collect()).unwrap_or_default()
}

/// The input whose name contains `name` (case-insensitive).
fn pick_input(name: &str) -> Option<cpal::Device> {
    let needle = name.to_lowercase();
    cpal::default_host().input_devices().ok()?.find(|d| d.name().map(|n| n.to_lowercase().contains(&needle)).unwrap_or(false))
}

fn pick_output(name: Option<&str>) -> Option<cpal::Device> {
    let host = cpal::default_host();
    match name {
        Some(n) => host.output_devices().ok()?.find(|d| d.name().map(|x| x == n).unwrap_or(false)),
        None => host.default_output_device(),
    }
}

impl Audio {
    /// `input`: a substring of the input's name, "none" for no audio, or None
    /// for `preferred` if present, else the system default.
    pub fn start(input: Option<String>, preferred: Option<&str>, output: Option<String>) -> Audio {
        let (tx, rx) = mpsc::channel();
        let (chunks, _) = broadcast::channel(256);
        let audio = Audio {
            tx,
            level: Arc::new(AtomicU32::new((-160f32).to_bits())),
            chunks,
            status: Arc::new(Mutex::new(Status { output, ..Default::default() })),
        };
        let a = audio.clone();
        let first = match input.as_deref() {
            Some("none") => None,
            Some(n) => Some(n.to_string()),
            None => preferred
                .and_then(pick_input)
                .or_else(|| cpal::default_host().default_input_device())
                .and_then(|d| d.name().ok()),
        };
        std::thread::Builder::new().name("audio".into()).spawn(move || a.run(first, rx)).unwrap();
        audio
    }

    pub fn level_db(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    /// The current choices, with the device lists (slow to enumerate).
    pub fn status(&self) -> Status {
        let mut s = self.status_light();
        s.inputs = input_names();
        s.outputs = output_names();
        s
    }

    /// The current choices only.
    pub fn status_light(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    pub fn set_input(&self, name: Option<String>) {
        let _ = self.tx.send(Cmd::Input(name));
    }
    pub fn set_output(&self, name: Option<String>) {
        let _ = self.tx.send(Cmd::Output(name));
    }
    pub fn set_monitoring(&self, on: bool) {
        let _ = self.tx.send(Cmd::Monitor(on));
    }

    fn run(self, first: Option<String>, rx: mpsc::Receiver<Cmd>) {
        // Samples on their way to the monitor output, in the input's layout.
        let ring: Arc<Mutex<Ring>> = Arc::new(Mutex::new(Ring::default()));
        let mut input: Option<Stream> = None;
        let mut monitor: Option<Stream> = None;
        let mut want_input = first;
        let mut rebuild_input = true;
        loop {
            if rebuild_input {
                rebuild_input = false;
                drop(input.take()); // close it first: some devices can't be opened twice
                self.level.store((-160f32).to_bits(), Ordering::Relaxed);
                let opened = want_input.as_deref().and_then(|n| self.open_input(n, ring.clone()));
                self.status.lock().unwrap().input = opened.as_ref().map(|(_, n)| n.clone());
                input = opened.map(|(s, _)| s);
                if self.status.lock().unwrap().monitoring {
                    monitor = None; // the input's format may have changed
                }
            }
            let (monitoring, output) = {
                let s = self.status.lock().unwrap();
                (s.monitoring, s.output.clone())
            };
            if monitoring && monitor.is_none() && input.is_some() {
                monitor = open_monitor(output.as_deref(), ring.clone());
                if monitor.is_none() {
                    self.status.lock().unwrap().monitoring = false;
                }
            } else if !monitoring {
                monitor = None;
            }
            match rx.recv() {
                Ok(Cmd::Input(n)) => {
                    want_input = n;
                    rebuild_input = true;
                }
                Ok(Cmd::Output(n)) => {
                    self.status.lock().unwrap().output = n;
                    monitor = None;
                }
                Ok(Cmd::Monitor(on)) => self.status.lock().unwrap().monitoring = on,
                Err(_) => return,
            }
        }
    }

    fn open_input(&self, name: &str, ring: Arc<Mutex<Ring>>) -> Option<(Stream, String)> {
        let Some(dev) = pick_input(name) else {
            crate::log!("audio input \"{name}\" not found; inputs: {}", input_names().join(", "));
            return None;
        };
        let dev_name = dev.name().unwrap_or_default();
        let cfg = dev.default_input_config().ok()?;
        let (rate, channels, format) = (cfg.sample_rate().0, cfg.channels(), cfg.sample_format());
        let config: cpal::StreamConfig = cfg.into();
        let level = self.level.clone();
        let chunks = self.chunks.clone();
        ring.lock().unwrap().reset(rate, channels);
        let deliver = move |samples: Vec<f32>| {
            let frames = samples.len() / channels.max(1) as usize;
            let pts = crate::now() - frames as f64 / rate as f64;
            let power = samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32;
            level.store((10.0 * power.max(1e-16).log10()).max(-160.0).to_bits(), Ordering::Relaxed);
            ring.lock().unwrap().push(&samples);
            let _ = chunks.send(Arc::new(Chunk { pts, rate, channels, samples }));
        };
        let err = |e| crate::log!("audio input: {e}");
        let stream = match format {
            SampleFormat::F32 => dev.build_input_stream(&config, move |d: &[f32], _: &_| deliver(d.to_vec()), err, None),
            SampleFormat::I16 => dev.build_input_stream(
                &config,
                move |d: &[i16], _: &_| deliver(d.iter().map(|&s| s as f32 / 32768.0).collect()),
                err,
                None,
            ),
            SampleFormat::I32 => dev.build_input_stream(
                &config,
                move |d: &[i32], _: &_| deliver(d.iter().map(|&s| s as f32 / 2147483648.0).collect()),
                err,
                None,
            ),
            SampleFormat::U16 => dev.build_input_stream(
                &config,
                move |d: &[u16], _: &_| deliver(d.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).collect()),
                err,
                None,
            ),
            other => {
                crate::log!("audio input {dev_name}: unsupported sample format {other:?}");
                return None;
            }
        };
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                crate::log!("cannot open audio input {dev_name}: {e}");
                return None;
            }
        };
        if let Err(e) = stream.play() {
            crate::log!("cannot start audio input {dev_name}: {e}");
            return None;
        }
        crate::log!("audio input: {dev_name} ({rate} Hz, {channels} ch)");
        Some((stream, dev_name))
    }
}

/// Input samples waiting for the monitor output, at most ~0.25 s so the
/// monitor never drifts behind.
#[derive(Default)]
struct Ring {
    rate: u32,
    channels: u16,
    buf: VecDeque<f32>,
}

impl Ring {
    fn reset(&mut self, rate: u32, channels: u16) {
        *self = Ring { rate, channels, buf: VecDeque::new() };
    }
    fn push(&mut self, s: &[f32]) {
        self.buf.extend(s);
        let max = (self.rate as usize / 4) * self.channels.max(1) as usize;
        if self.buf.len() > max {
            let extra = self.buf.len() - max;
            self.buf.drain(..extra);
        }
    }
}

fn open_monitor(name: Option<&str>, ring: Arc<Mutex<Ring>>) -> Option<Stream> {
    let dev = pick_output(name)?;
    let dev_name = dev.name().unwrap_or_default();
    let cfg = dev.default_output_config().ok()?;
    if cfg.sample_format() != SampleFormat::F32 {
        crate::log!("monitor output {dev_name}: needs f32 samples, has {:?}", cfg.sample_format());
        return None;
    }
    let out_ch = cfg.channels();
    let out_rate = cfg.sample_rate().0;
    let config: cpal::StreamConfig = cfg.into();
    let mut resampler: Option<Resampler> = None;
    let stream = dev
        .build_output_stream(
            &config,
            move |out: &mut [f32], _: &_| {
                let mut r = ring.lock().unwrap();
                let (rate, ch) = (r.rate, r.channels);
                if rate == 0 {
                    out.fill(0.0);
                    return;
                }
                let rs = resampler.get_or_insert_with(|| Resampler::new(rate, ch, out_rate, out_ch));
                if rs.from != (rate, ch) {
                    *rs = Resampler::new(rate, ch, out_rate, out_ch);
                }
                // Take about as much input as this callback needs.
                let frames_out = out.len() / out_ch as usize;
                let frames_in = ((frames_out as f64 * rate as f64 / out_rate as f64).ceil() as usize).min(r.buf.len() / ch as usize);
                let input: Vec<f32> = r.buf.drain(..frames_in * ch as usize).collect();
                drop(r);
                let got = rs.process(&input);
                let n = got.len().min(out.len());
                out[..n].copy_from_slice(&got[..n]);
                out[n..].fill(0.0);
            },
            |e| crate::log!("monitor output: {e}"),
            None,
        )
        .ok()?;
    stream.play().ok()?;
    crate::log!("monitoring on {dev_name}");
    Some(stream)
}

/// Linear-interpolating resampler and channel mapper for interleaved f32,
/// continuous across calls. Mono output averages the input channels; more
/// channels repeat the last input channel when the input has fewer.
pub struct Resampler {
    pub from: (u32, u16),
    to_rate: u32,
    to_ch: u16,
    pos: f64,       // position of the next output frame, in input frames from the start of `prev`
    prev: Vec<f32>, // the last input frame of the previous call, mapped to output channels
}

impl Resampler {
    pub fn new(rate: u32, channels: u16, to_rate: u32, to_channels: u16) -> Resampler {
        Resampler { from: (rate, channels), to_rate, to_ch: to_channels.max(1), pos: 1.0, prev: Vec::new() }
    }

    fn map(&self, frame: &[f32]) -> Vec<f32> {
        let n = frame.len();
        if self.to_ch == 1 {
            return vec![frame.iter().sum::<f32>() / n as f32];
        }
        (0..self.to_ch as usize).map(|c| frame[c.min(n - 1)]).collect()
    }

    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        let cin = self.from.1.max(1) as usize;
        let frames: Vec<Vec<f32>> = input.chunks_exact(cin).map(|f| self.map(f)).collect();
        if frames.is_empty() {
            return Vec::new();
        }
        if self.prev.is_empty() {
            self.prev = frames[0].clone();
        }
        let step = self.from.0 as f64 / self.to_rate as f64;
        let mut out = Vec::with_capacity(((frames.len() as f64 / step) as usize + 2) * self.to_ch as usize);
        // Index 0 is `prev`, then 1..=len are this call's frames.
        let at = |i: usize| -> &[f32] { if i == 0 { &self.prev } else { &frames[i - 1] } };
        while self.pos <= frames.len() as f64 {
            let i = self.pos.floor() as usize;
            let frac = (self.pos - i as f64) as f32;
            let a = at(i);
            let b = if i < frames.len() { at(i + 1) } else { a };
            for c in 0..self.to_ch as usize {
                out.push(a[c] + (b[c] - a[c]) * frac);
            }
            self.pos += step;
        }
        self.pos -= frames.len() as f64;
        self.prev = frames.last().unwrap().clone();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::Resampler;

    #[test]
    fn resample_rate_and_continuity() {
        // 48 kHz stereo ramp → 16 kHz mono: a third as many frames, still a ramp.
        let mut r = Resampler::new(48000, 2, 16000, 1);
        let mut out = Vec::new();
        for block in 0..10 {
            let input: Vec<f32> = (0..480).flat_map(|i| {
                let v = (block * 480 + i) as f32;
                [v, v]
            }).collect();
            out.extend(r.process(&input));
        }
        assert!((out.len() as i32 - 1600).abs() <= 1, "{}", out.len());
        for w in out.windows(2).skip(1) {
            assert!((w[1] - w[0] - 3.0).abs() < 1e-3, "{w:?}");
        }
    }

    #[test]
    fn upsample_and_upmix() {
        let mut r = Resampler::new(8000, 1, 16000, 2);
        let out = r.process(&[0.0, 1.0, 2.0, 3.0]);
        assert_eq!(&out[..6], &[0.0, 0.0, 0.5, 0.5, 1.0, 1.0]);
    }
}
