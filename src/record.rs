//! Recording through ffmpeg, and snapshots.
//!
//! Video: a writer thread hands ffmpeg the newest frame on a fixed clock (the
//! camera's frame rate), repeating or skipping frames as needed, so the file's
//! timeline is wall time. Audio is written raw to a side file meanwhile, then
//! muxed in at its measured offset when recording stops: no timestamp guessing
//! across two pipes.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, watch};

use crate::audio::Chunk;
use crate::frame::{Frame, Pixels};

#[derive(Clone, Debug)]
pub struct Options {
    pub dir: PathBuf,
    pub codec: String,       // hevc, h264, prores
    pub audio_format: String, // aac, pcm
    pub fps: u32,
}

pub fn timestamp() -> String {
    chrono::Local::now().format("%Y-%m-%d at %H.%M.%S").to_string()
}

/// ffmpeg's encoders, listed once.
fn encoders() -> Option<&'static str> {
    static LIST: OnceLock<Option<String>> = OnceLock::new();
    LIST.get_or_init(|| {
        let out = Command::new("ffmpeg").args(["-hide_banner", "-encoders"]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    })
    .as_deref()
}

fn has_encoder(name: &str) -> bool {
    encoders().map(|l| l.lines().any(|line| line.split_whitespace().nth(1) == Some(name))).unwrap_or(false)
}

/// Encoder arguments for `codec`: the platform's hardware encoder when ffmpeg
/// has it, else a software one.
fn video_args(codec: &str, w: u32, h: u32, fps: u32) -> anyhow::Result<Vec<String>> {
    let bits = |bpp: f64| format!("{}k", ((w * h * fps.max(1)) as f64 * bpp / 1000.0).round() as u64);
    let pick = |names: &[&str]| names.iter().find(|n| has_encoder(n)).map(|s| s.to_string());
    let args: Vec<String> = match codec {
        "h264" => match pick(&["h264_videotoolbox", "libx264", "h264_mf", "libopenh264"]) {
            Some(e) if e == "libx264" => vec!["-c:v".into(), e, "-preset".into(), "veryfast".into(), "-crf".into(), "20".into(), "-pix_fmt".into(), "yuv420p".into()],
            Some(e) => vec!["-c:v".into(), e, "-b:v".into(), bits(0.12), "-pix_fmt".into(), "yuv420p".into()],
            None => anyhow::bail!("ffmpeg has no H.264 encoder"),
        },
        "prores" => match pick(&["prores_videotoolbox", "prores_ks"]) {
            Some(e) => vec!["-c:v".into(), e, "-profile:v".into(), "2".into(), "-pix_fmt".into(), "yuv422p10le".into()],
            None => anyhow::bail!("ffmpeg has no ProRes encoder"),
        },
        _ => match pick(&["hevc_videotoolbox", "libx265", "hevc_mf"]) {
            Some(e) if e == "libx265" => vec!["-c:v".into(), e, "-preset".into(), "fast".into(), "-crf".into(), "24".into(), "-pix_fmt".into(), "yuv420p".into(), "-tag:v".into(), "hvc1".into()],
            Some(e) => vec!["-c:v".into(), e, "-b:v".into(), bits(0.07), "-pix_fmt".into(), "yuv420p".into(), "-tag:v".into(), "hvc1".into()],
            None => anyhow::bail!("ffmpeg has no HEVC encoder"),
        },
    };
    Ok(args)
}

pub fn ffmpeg_missing_hint() -> &'static str {
    if cfg!(target_os = "macos") {
        "recording needs ffmpeg: brew install ffmpeg"
    } else if cfg!(windows) {
        "recording needs ffmpeg: winget install ffmpeg"
    } else {
        "recording needs ffmpeg: install it with your package manager (e.g. apt install ffmpeg)"
    }
}

pub struct Recorder {
    pub since: Instant,
    pub path: PathBuf,
    stop: Arc<AtomicBool>,
    video: Option<std::thread::JoinHandle<anyhow::Result<(Child, f64)>>>,
    audio: Option<std::thread::JoinHandle<Option<AudioFile>>>,
    video_tmp: PathBuf,
    audio_format: String,
}

struct AudioFile {
    path: PathBuf,
    start: f64, // app clock of its first sample
    rate: u32,
    channels: u16,
}

impl Recorder {
    pub fn start(
        opt: &Options,
        frames: watch::Receiver<Option<Arc<Frame>>>,
        audio: Option<broadcast::Receiver<Arc<Chunk>>>,
    ) -> anyhow::Result<Recorder> {
        if encoders().is_none() {
            anyhow::bail!(ffmpeg_missing_hint());
        }
        let first = frames.borrow().clone().ok_or_else(|| anyhow::anyhow!("no video yet"))?;
        std::fs::create_dir_all(&opt.dir)?;
        let name = format!("pocket-viewer {}", timestamp());
        let path = opt.dir.join(format!("{name}.mov"));
        let video_tmp = opt.dir.join(format!(".{name}.video.mov"));
        let (w, h, fps) = (first.width, first.height, opt.fps.clamp(1, 60));
        let input: Vec<String> = match &first.pixels {
            Pixels::Jpeg(_) => vec!["-f".into(), "mjpeg".into()],
            Pixels::Yuyv(_) => raw("yuyv422", w, h),
            Pixels::Uyvy(_) => raw("uyvy422", w, h),
            Pixels::Nv12(_) => raw("nv12", w, h),
            Pixels::Rgb(_) => raw("rgb24", w, h),
        };
        let mut cmd = Command::new("ffmpeg");
        cmd.args(["-hide_banner", "-loglevel", "error", "-y", "-framerate", &fps.to_string()])
            .args(&input)
            .args(["-i", "-"])
            .args(video_args(&opt.codec, w, h, fps)?)
            .arg(&video_tmp)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let mut child = cmd.spawn()?;
        let mut stdin = child.stdin.take().unwrap();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let mut frames = frames;
        let video = std::thread::Builder::new().name("record-video".into()).spawn(move || {
            let start = crate::now();
            let tick = 1.0 / fps as f64;
            let mut written: u64 = 0;
            while !s.load(Ordering::Relaxed) {
                let due = ((crate::now() - start) / tick).floor() as u64 + 1;
                if written >= due {
                    std::thread::sleep(Duration::from_secs_f64((start + written as f64 * tick - crate::now()).max(0.001)));
                    continue;
                }
                let frame = frames.borrow_and_update().clone();
                let Some(frame) = frame else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                if frame.width != w || frame.height != h {
                    crate::log!("recording stopped: the video format changed");
                    break;
                }
                let bytes: &[u8] = match &frame.pixels {
                    Pixels::Jpeg(b) => b,
                    Pixels::Yuyv(b) | Pixels::Uyvy(b) | Pixels::Nv12(b) | Pixels::Rgb(b) => b,
                };
                // Catch up by repeating the frame, but never by more than a few.
                let n = (due - written).min(5);
                for _ in 0..n {
                    stdin.write_all(bytes)?;
                }
                written = due;
            }
            drop(stdin); // ffmpeg finishes the file
            Ok((child, start))
        })?;

        let audio = audio.map(|mut rx| {
            let s = stop.clone();
            let tmp = opt.dir.join(format!(".{name}.audio.raw"));
            std::thread::spawn(move || -> Option<AudioFile> {
                let mut file = std::io::BufWriter::new(std::fs::File::create(&tmp).ok()?);
                let mut meta: Option<AudioFile> = None;
                while !s.load(Ordering::Relaxed) {
                    match rx.try_recv() {
                        Ok(c) => {
                            let m = meta.get_or_insert_with(|| AudioFile { path: tmp.clone(), start: c.pts, rate: c.rate, channels: c.channels });
                            if (m.rate, m.channels) != (c.rate, c.channels) {
                                continue; // the input changed mid-recording; keep the first format
                            }
                            for v in &c.samples {
                                file.write_all(&v.to_le_bytes()).ok()?;
                            }
                        }
                        Err(broadcast::error::TryRecvError::Lagged(_)) => {}
                        Err(_) => std::thread::sleep(Duration::from_millis(5)),
                    }
                }
                file.flush().ok()?;
                if meta.is_none() {
                    let _ = std::fs::remove_file(&tmp);
                }
                meta
            })
        });

        crate::log!("recording to {}", path.display());
        Ok(Recorder {
            since: Instant::now(),
            path,
            stop,
            video: Some(video),
            audio,
            video_tmp,
            audio_format: opt.audio_format.clone(),
        })
    }

    /// Stops and writes the file; blocks until ffmpeg is done.
    pub fn finish(mut self) -> anyhow::Result<PathBuf> {
        self.stop.store(true, Ordering::Relaxed);
        let (mut child, video_start) = self.video.take().unwrap().join().map_err(|_| anyhow::anyhow!("recorder crashed"))??;
        let status = child.wait()?;
        if !status.success() {
            anyhow::bail!("ffmpeg failed ({status})");
        }
        let audio = self.audio.take().and_then(|h| h.join().ok().flatten());
        let Some(a) = audio else {
            std::fs::rename(&self.video_tmp, &self.path)?;
            return Ok(self.path.clone());
        };
        // Audio started `offset` seconds after the video's first frame.
        let offset = a.start - video_start;
        let mut cmd = Command::new("ffmpeg");
        cmd.args(["-hide_banner", "-loglevel", "error", "-y", "-i"]).arg(&self.video_tmp);
        if offset >= 0.0 {
            cmd.args(["-itsoffset", &format!("{offset:.4}")]);
        } else {
            cmd.args(["-ss", &format!("{:.4}", -offset)]);
        }
        cmd.args(["-f", "f32le", "-ar", &a.rate.to_string(), "-ac", &a.channels.to_string(), "-i"])
            .arg(&a.path)
            .args(["-map", "0:v", "-map", "1:a", "-c:v", "copy"])
            .args(if self.audio_format == "pcm" { vec!["-c:a", "pcm_s24le"] } else { vec!["-c:a", "aac", "-b:a", "192k"] })
            .args(["-shortest"])
            .arg(&self.path);
        let ok = cmd.status().map(|s| s.success()).unwrap_or(false);
        let _ = std::fs::remove_file(&a.path);
        if !ok {
            std::fs::rename(&self.video_tmp, &self.path)?;
            anyhow::bail!("adding the audio failed; saved the video only");
        }
        let _ = std::fs::remove_file(&self.video_tmp);
        Ok(self.path.clone())
    }
}

fn raw(pix_fmt: &str, w: u32, h: u32) -> Vec<String> {
    vec!["-f".into(), "rawvideo".into(), "-pix_fmt".into(), pix_fmt.into(), "-s".into(), format!("{w}x{h}")]
}

/// Saves `frame` at full resolution as a JPEG in `dir`.
pub fn snapshot(frame: &Frame, dir: &Path) -> anyhow::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let path = dir.join(format!("pocket-viewer {}.jpg", timestamp()));
    let jpeg = frame.full_jpeg(92).ok_or_else(|| anyhow::anyhow!("cannot encode the frame"))?;
    std::fs::write(&path, &jpeg)?;
    Ok(path)
}
