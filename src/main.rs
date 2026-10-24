//! pocket-viewer — live view, recording and gimbal control for the DJI Osmo
//! Pocket 3 (webcam mode) or an M5Stack StackChan, run from a web page.
//!
//! It serves a local web UI (http://127.0.0.1:8642 by default, opened in the
//! browser at launch) and a plugin socket; see README.md and plugins/PROTOCOL.md.

mod app;
mod audio;
mod frame;
mod gimbal;
mod plugins;
mod record;
mod settings;
mod stackchan;
mod uvc;
mod web;

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use clap::Parser;

use app::{App, Camera};

#[derive(Parser, Debug)]
#[command(name = "pocket-viewer", version, about = "Live view, recording and gimbal control for the DJI Osmo Pocket 3 or an M5Stack StackChan, in the browser")]
struct Args {
    /// Camera: "stackchan" (or stackchan:PORT) for a StackChan on USB, else part
    /// of a camera's name; default the Pocket 3 (OsmoPocket3)
    #[arg(short = 'd')]
    device: Option<String>,
    /// Initial resolution, e.g. 3840x2160 or 1080x1920 (portrait)
    #[arg(short = 's', default_value = "1920x1080")]
    size: String,
    /// Initial frame rate
    #[arg(short = 'r', default_value_t = 30)]
    fps: u32,
    /// Audio input (part of its name); "none" for video only. Default: the
    /// Pocket 3's microphone with the Pocket 3, else the system input
    #[arg(short = 'a')]
    audio: Option<String>,
    /// Where recordings and snapshots go (default ~/Movies or ~/Videos)
    #[arg(short = 'o')]
    output: Option<String>,
    /// Recording codec: hevc, h264 or prores
    #[arg(short = 'c')]
    codec: Option<String>,
    /// Launch a plugin (a shell command); repeatable
    #[arg(short = 'p')]
    plugin: Vec<String>,
    /// Record for this many seconds as soon as video arrives, then quit
    #[arg(short = 't')]
    time: Option<f64>,
    /// List cameras, resolutions, audio devices and StackChans, then exit
    #[arg(short = 'l')]
    list: bool,
    /// Port of the web UI
    #[arg(long, default_value_t = 8642)]
    port: u16,
    /// Address to serve on; 0.0.0.0 lets other machines on the network in (no password!)
    #[arg(long, default_value = "127.0.0.1")]
    host: String,
    /// Don't open the browser
    #[arg(long)]
    no_open: bool,
}

/// Seconds since launch: the clock of every frame and audio pts.
pub fn now() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        eprintln!("{} {}", chrono::Local::now().format("%H:%M:%S%.3f"), format!($($arg)*))
    };
}

/// ~/.config/pocket-viewer, or %APPDATA%\pocket-viewer on Windows.
pub fn config_dir() -> std::path::PathBuf {
    if cfg!(windows) {
        if let Some(d) = std::env::var_os("APPDATA") {
            return std::path::PathBuf::from(d).join("pocket-viewer");
        }
    }
    app::home().join(".config").join("pocket-viewer")
}

static APP: OnceLock<Arc<App>> = OnceLock::new();

/// Finishes a recording in progress, stops plugins, and exits.
pub fn quit(app: &Arc<App>) {
    let app = app.clone();
    std::thread::spawn(move || {
        app.shutdown();
        std::process::exit(0);
    });
}

fn list() {
    println!("Cameras:");
    for c in uvc::list() {
        println!("  {c}");
    }
    println!("Pocket 3 resolutions: {}", uvc::SIZES.iter().map(|(w, h)| format!("{w}x{h}")).collect::<Vec<_>>().join(", "));
    println!("  at {} fps", uvc::RATES.iter().map(|r| r.to_string()).collect::<Vec<_>>().join(", "));
    println!("Audio inputs:");
    for a in audio::input_names() {
        println!("  {a}");
    }
    println!("Audio outputs:");
    for a in audio::output_names() {
        println!("  {a}");
    }
    match stackchan::find_port() {
        Some(p) => println!("StackChan: {p}"),
        None => println!("StackChan: none on USB"),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    now();
    let args = Args::parse();
    if args.list {
        list();
        return Ok(());
    }
    let (width, height) = args
        .size
        .split_once('x')
        .and_then(|(w, h)| Some((w.parse::<u32>().ok()?, h.parse::<u32>().ok()?)))
        .ok_or_else(|| anyhow::anyhow!("-s wants WxH, e.g. 1920x1080"))?;

    let mut settings = settings::Settings::load();
    if let Some(c) = &args.codec {
        anyhow::ensure!(["hevc", "h264", "prores"].contains(&c.as_str()), "-c wants hevc, h264 or prores");
        settings.codec = Some(c.clone());
    }
    if let Some(o) = &args.output {
        settings.output_dir = Some(o.clone());
    }

    let sink: stackchan::FrameSink = Arc::new(|f| {
        if let Some(app) = APP.get() {
            app.on_frame(f);
        }
    });
    let device = args.device.clone().unwrap_or_else(|| uvc::POCKET3.to_string());
    let (camera, backend, preferred_mic): (Camera, Option<Box<dyn gimbal::Backend>>, Option<&str>) =
        if device == "stackchan" || device.starts_with("stackchan:") {
            let port = match device.strip_prefix("stackchan:") {
                Some(p) => p.to_string(),
                None => {
                    let mut said = false;
                    loop {
                        if let Some(p) = stackchan::find_port() {
                            break p;
                        }
                        if !said {
                            log!("no StackChan on USB yet; plug it in (and press its power button)");
                            said = true;
                        }
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
            };
            let link = stackchan::Link::start(port, sink);
            (Camera::StackChan(link.clone()), Some(Box::new(stackchan::Head::new(link))), None)
        } else {
            let cam = uvc::Uvc::start(device.clone(), width, height, args.fps, sink);
            let is_pocket3 = device.eq_ignore_ascii_case(uvc::POCKET3);
            #[cfg(target_os = "macos")]
            let backend: Option<Box<dyn gimbal::Backend>> = is_pocket3.then(|| Box::new(gimbal::iokit::Pocket3) as _);
            #[cfg(not(target_os = "macos"))]
            let backend: Option<Box<dyn gimbal::Backend>> = Some(Box::new(uvc::Controls::new(&cam)));
            (Camera::Uvc(cam), backend, is_pocket3.then_some(uvc::POCKET3))
        };

    let gimbal = gimbal::Gimbal::spawn(backend);
    let audio = audio::Audio::start(args.audio.clone(), preferred_mic, settings.monitor_output.clone());
    let plugins = plugins::Server::new();
    let app = App::new(camera, gimbal, audio, plugins.clone(), settings);
    let _ = APP.set(app.clone());

    match plugins.start(Arc::new(app::PluginHost(Arc::downgrade(&app)))).await {
        Ok(addr) => log!("plugin socket: {addr}"),
        Err(e) => log!("plugin socket unavailable: {e}"),
    }

    // Video and audio to plugins; state 5×/s; overlay expiry 10×/s.
    let a = app.clone();
    tokio::spawn(async move {
        let mut rx = a.frames.subscribe();
        while rx.changed().await.is_ok() {
            let f = rx.borrow_and_update().clone();
            if let Some(f) = f {
                a.plugins.push_video(f);
            }
        }
    });
    let a = app.clone();
    tokio::spawn(async move {
        let mut rx = a.audio.chunks.subscribe();
        loop {
            match rx.recv().await {
                Ok(c) => a.plugins.push_audio(&c),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });
    let a = app.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        let mut n = 0u64;
        loop {
            tick.tick().await;
            a.expire_overlay();
            n += 1;
            if n % 2 == 0 {
                a.plugins.broadcast_state(&a.plugin_state());
            }
        }
    });

    for p in &args.plugin {
        plugins.launch(p);
    }

    if let Some(secs) = args.time {
        let a = app.clone();
        tokio::spawn(async move {
            let mut rx = a.frames.subscribe();
            while rx.borrow().is_none() {
                if rx.changed().await.is_err() {
                    return;
                }
            }
            a.toggle_recording();
            if !a.is_recording() {
                std::process::exit(1);
            }
            tokio::time::sleep(Duration::from_secs_f64(secs)).await;
            quit(&a);
        });
    }

    let a = app.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            quit(&a);
        }
    });

    // The first free port from --port up.
    let mut listener = None;
    for port in args.port..args.port.saturating_add(10) {
        if let Ok(l) = tokio::net::TcpListener::bind((args.host.as_str(), port)).await {
            listener = Some(l);
            break;
        }
    }
    let listener = listener.ok_or_else(|| anyhow::anyhow!("no free port from {} up", args.port))?;
    let addr = listener.local_addr()?;
    let shown = if addr.ip().is_unspecified() { format!("127.0.0.1:{}", addr.port()) } else { addr.to_string() };
    let url = format!("http://{shown}/");
    log!("pocket-viewer at {url}");
    if !args.no_open {
        let _ = webbrowser::open(&url);
    }
    axum::serve(listener, web::router(app)).await?;
    Ok(())
}
