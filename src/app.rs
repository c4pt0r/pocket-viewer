//! The app: one camera, its gimbal, audio, recording and plugins, driven by
//! commands from the browser and from plugins. Browsers get a status message
//! five times a second and the plugin overlay whenever it changes.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::{broadcast, watch};

use crate::audio::Audio;
use crate::frame::Frame;
use crate::gimbal::{Cmd, Gimbal};
use crate::plugins::{self, Client};
use crate::record::{self, Recorder};
use crate::settings::Settings;
use crate::{stackchan, uvc};

pub enum Camera {
    StackChan(Arc<stackchan::Link>),
    Uvc(uvc::Uvc),
}

#[derive(Default)]
struct Overlay {
    layers: BTreeMap<String, (Value, f64)>,       // "clientID/layer" → (items, expires)
    hud: BTreeMap<String, (String, String, f64)>, // "clientID/key" → (text, color, expires)
}

#[derive(Default)]
struct Meter {
    window_start: f64,
    frames: u32,
    fps: f64,
}

pub struct App {
    pub camera: Camera,
    pub frames: watch::Sender<Option<Arc<Frame>>>,
    pub gimbal: Gimbal,
    pub audio: Audio,
    pub plugins: Arc<plugins::Server>,
    pub settings: Mutex<Settings>,
    recorder: Mutex<Option<Recorder>>,
    saving: AtomicBool,
    overlay: Mutex<Overlay>,
    meter: Mutex<Meter>,
    /// JSON messages for every browser.
    pub events: broadcast::Sender<String>,
    pub default_dir: PathBuf,
}

fn num(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(Value::as_f64)
}

impl App {
    pub fn new(camera: Camera, gimbal: Gimbal, audio: Audio, plugins: Arc<plugins::Server>, settings: Settings) -> Arc<App> {
        let (frames, _) = watch::channel(None);
        let (events, _) = broadcast::channel(64);
        let default_dir = dirs_home().join(if cfg!(target_os = "macos") { "Movies" } else { "Videos" });
        Arc::new(App {
            camera,
            frames,
            gimbal,
            audio,
            plugins,
            settings: Mutex::new(settings),
            recorder: Mutex::new(None),
            saving: AtomicBool::new(false),
            overlay: Mutex::new(Overlay::default()),
            meter: Mutex::new(Meter::default()),
            events,
            default_dir,
        })
    }

    /// From the camera thread: publishes a frame to the browser, plugins and recorder.
    pub fn on_frame(&self, frame: Frame) {
        {
            let mut m = self.meter.lock().unwrap();
            m.frames += 1;
            let elapsed = frame.pts - m.window_start;
            if elapsed >= 1.0 {
                m.fps = m.frames as f64 / elapsed;
                m.frames = 0;
                m.window_start = frame.pts;
            }
        }
        self.frames.send_replace(Some(Arc::new(frame)));
    }

    pub fn output_dir(&self) -> PathBuf {
        self.settings.lock().unwrap().output_dir.as_ref().map(PathBuf::from).unwrap_or_else(|| self.default_dir.clone())
    }

    fn video_size(&self) -> (u32, u32, f64) {
        let f = self.frames.borrow().clone();
        let fps = self.meter.lock().unwrap().fps;
        match &self.camera {
            Camera::Uvc(u) => {
                let i = u.info.lock().unwrap();
                let (w, h) = f.map(|f| (f.width, f.height)).unwrap_or((i.width, i.height));
                (w, h, i.fps as f64)
            }
            Camera::StackChan(_) => f.map(|f| (f.width, f.height, (fps * 10.0).round() / 10.0)).unwrap_or((0, 0, 0.0)),
        }
    }

    pub fn is_recording(&self) -> bool {
        self.recorder.lock().unwrap().is_some()
    }

    /// The `state` message for plugins (also the body of their hello).
    pub fn plugin_state(&self) -> Value {
        let mut st = Value::Object(self.gimbal.state_json());
        if let Value::Object(m) = &mut st {
            m.remove("hasRoll");
        }
        let (w, h, fps) = self.video_size();
        st["video"] = json!({"width": w, "height": h, "fps": fps});
        st["recording"] = json!(self.is_recording());
        if let Camera::StackChan(link) = &self.camera {
            let (hf, vf) = stackchan::fov();
            st["fov"] = json!([hf, vf]);
            if let Some(head) = link.head() {
                st["head"] = head;
            }
        }
        st
    }

    /// The browser's status line, panels and menus.
    pub fn status(&self) -> Value {
        let (w, h, fps) = self.video_size();
        let measured = self.meter.lock().unwrap().fps;
        let (camera, sizes, rates) = match &self.camera {
            Camera::Uvc(u) => {
                let i = u.info.lock().unwrap();
                let name = i.name.clone();
                let connected = name.is_some();
                (json!({"kind": "uvc", "name": name, "connected": connected, "width": w, "height": h, "fps": fps, "measuredFps": measured}),
                 json!(uvc::SIZES), json!(uvc::RATES))
            }
            Camera::StackChan(link) => {
                let connected = link.state().is_some();
                (json!({"kind": "stackchan", "name": "StackChan", "connected": connected, "width": w, "height": h, "fps": fps, "measuredFps": measured}),
                 json!([]), json!([]))
            }
        };
        let rec = self.recorder.lock().unwrap().as_ref().map(|r| json!({"seconds": r.since.elapsed().as_secs_f64(), "path": r.path}));
        let s = self.settings.lock().unwrap().clone();
        let plugins: Vec<Value> = self
            .plugins
            .clients()
            .iter()
            .map(|c| json!({"id": c.id, "name": c.name(), "external": c.launch.lock().unwrap().is_none(),
                             "options": c.options.lock().unwrap().clone().unwrap_or_default()}))
            .collect();
        let pending: Vec<Value> = self.plugins.pending().iter().map(|l| json!({"token": l.token, "command": l.command})).collect();
        let audio = self.audio.status_light();
        json!({
            "type": "status",
            "camera": camera, "sizes": sizes, "rates": rates,
            "gimbal": self.gimbal.state_json(),
            "recording": rec, "saving": self.saving.load(Ordering::Relaxed),
            "codec": s.codec.unwrap_or_else(|| "hevc".into()),
            "audioFormat": s.audio_format.unwrap_or_else(|| "aac".into()),
            "outputDir": self.output_dir(),
            "audio": {"input": audio.input, "output": audio.output, "monitoring": audio.monitoring, "level": self.audio.level_db()},
            "plugins": plugins, "pending": pending,
            "socket": self.plugins.address.lock().unwrap().clone(),
        })
    }

    pub fn overlay_message(&self) -> String {
        let o = self.overlay.lock().unwrap();
        let layers: Vec<&Value> = o.layers.values().map(|(items, _)| items).collect();
        let hud: Vec<Value> = o.hud.values().map(|(t, c, _)| json!({"text": t, "color": c})).collect();
        json!({"type": "overlay", "layers": layers, "hud": hud}).to_string()
    }

    fn overlay_changed(&self) {
        let _ = self.events.send(self.overlay_message());
    }

    pub fn toast(&self, text: impl Into<String>) {
        let text = text.into();
        crate::log!("{text}");
        let _ = self.events.send(json!({"type": "toast", "text": text}).to_string());
    }

    /// Drops overlay layers and HUD segments whose time is up, and those of
    /// plugins that went away.
    pub fn expire_overlay(&self) {
        let now = crate::now();
        let alive: Vec<String> = self.plugins.clients().iter().map(|c| format!("{}/", c.id)).collect();
        let keep = |k: &String| alive.iter().any(|p| k.starts_with(p.as_str()));
        let changed = {
            let mut o = self.overlay.lock().unwrap();
            let before = (o.layers.len(), o.hud.len());
            o.layers.retain(|k, (_, exp)| *exp > now && keep(k));
            o.hud.retain(|k, (_, _, exp)| *exp > now && keep(k));
            before != (o.layers.len(), o.hud.len())
        };
        if changed {
            self.overlay_changed();
        }
    }

    // MARK: Recording

    pub fn toggle_recording(self: &Arc<Self>) {
        let current = self.recorder.lock().unwrap().take();
        match current {
            Some(rec) => {
                self.saving.store(true, Ordering::Relaxed);
                let me = self.clone();
                tokio::task::spawn_blocking(move || {
                    let result = rec.finish();
                    me.saving.store(false, Ordering::Relaxed);
                    match result {
                        Ok(path) => me.toast(format!("saved {}", path.display())),
                        Err(e) => me.toast(format!("recording failed: {e}")),
                    }
                });
            }
            None => {
                if self.saving.load(Ordering::Relaxed) {
                    return self.toast("still saving the last recording");
                }
                let s = self.settings.lock().unwrap().clone();
                let (_, _, fps) = self.video_size();
                let fps = match &self.camera {
                    Camera::Uvc(_) => fps.round().max(1.0) as u32,
                    Camera::StackChan(_) => 15, // ~10 fps, irregular: a steady 15 keeps motion smooth
                };
                let opt = record::Options {
                    dir: self.output_dir(),
                    codec: s.codec.unwrap_or_else(|| "hevc".into()),
                    audio_format: s.audio_format.unwrap_or_else(|| "aac".into()),
                    fps,
                };
                // Always listen: the input may open a moment after the video (with
                // -t), and with no input at all the file just has no audio.
                match Recorder::start(&opt, self.frames.subscribe(), Some(self.audio.chunks.subscribe())) {
                    Ok(r) => *self.recorder.lock().unwrap() = Some(r),
                    Err(e) => self.toast(format!("cannot record: {e}")),
                }
            }
        }
    }

    /// Before exiting: finish a recording in progress and stop plugins. Blocks.
    pub fn shutdown(&self) {
        if let Some(rec) = self.recorder.lock().unwrap().take() {
            crate::log!("finishing the recording…");
            match rec.finish() {
                Ok(p) => crate::log!("saved {}", p.display()),
                Err(e) => crate::log!("recording failed: {e}"),
            }
        }
        while self.saving.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        self.plugins.shutdown();
    }

    pub fn snapshot(&self) {
        let Some(frame) = self.frames.borrow().clone() else { return self.toast("no video yet") };
        match record::snapshot(&frame, &self.output_dir()) {
            Ok(p) => self.toast(format!("snapshot {}", p.display())),
            Err(e) => self.toast(format!("snapshot failed: {e}")),
        }
    }

    // MARK: Commands from the browser

    pub fn command(self: &Arc<Self>, m: &Value) {
        match m["cmd"].as_str().unwrap_or("") {
            "gimbal" => self.gimbal.command(Cmd::Move {
                pan: num(m, "pan"),
                tilt: num(m, "tilt"),
                dpan: num(m, "dpan").unwrap_or(0.0),
                dtilt: num(m, "dtilt").unwrap_or(0.0),
            }),
            "zoom" => self.gimbal.command(Cmd::Zoom { zoom: num(m, "zoom"), dzoom: num(m, "dzoom").unwrap_or(0.0) }),
            "roll" => self.gimbal.command(Cmd::Roll { roll: num(m, "roll"), droll: num(m, "droll").unwrap_or(0.0) }),
            "center" => self.gimbal.command(Cmd::Center),
            "record" => self.record_action(m["action"].as_str().unwrap_or("toggle")),
            "snapshot" => self.snapshot(),
            "monitor" => self.audio.set_monitoring(m["on"].as_bool().unwrap_or(false)),
            "audioInput" => self.audio.set_input(m["name"].as_str().map(String::from)),
            "audioOutput" => {
                let name = m["name"].as_str().map(String::from);
                self.settings.lock().unwrap().monitor_output = name.clone();
                self.audio.set_output(name);
            }
            "format" => {
                if let Camera::Uvc(u) = &self.camera {
                    if self.is_recording() {
                        return self.toast("stop recording before changing the format");
                    }
                    let (w, h, f) = (num(m, "width"), num(m, "height"), num(m, "fps"));
                    if let (Some(w), Some(h), Some(f)) = (w, h, f) {
                        u.set_format(w as u32, h as u32, f as u32);
                    }
                }
            }
            "codec" | "audioFormat" | "outputDir" | "scaling" => {
                let v = m["value"].as_str().map(String::from);
                let mut s = self.settings.lock().unwrap();
                match m["cmd"].as_str().unwrap() {
                    "codec" => s.codec = v,
                    "audioFormat" => s.audio_format = v,
                    "outputDir" => s.output_dir = v.filter(|d| !d.trim().is_empty()),
                    _ => s.scaling = v,
                }
                s.save();
            }
            "input" => {
                if let Some(ev) = m.get("event") {
                    self.plugins.broadcast_input(ev);
                }
            }
            "pluginOption" => self.set_plugin_option(m),
            "stopPlugin" => {
                if let Some(id) = m["id"].as_u64() {
                    self.plugins.stop(id as u32);
                } else if let Some(t) = m["token"].as_str() {
                    self.plugins.stop_pending(t);
                }
            }
            "launchPlugin" => {
                if let Some(c) = m["command"].as_str().filter(|c| !c.trim().is_empty()) {
                    self.plugins.launch(c);
                }
            }
            "quit" => crate::quit(self),
            _ => {}
        }
    }

    fn record_action(self: &Arc<Self>, action: &str) {
        let rec = self.is_recording();
        if action == "toggle" || (action == "start" && !rec) || (action == "stop" && rec) {
            self.toggle_recording();
        }
    }

    // MARK: Plugins

    fn set_plugin_option(&self, m: &Value) {
        let (Some(id), Some(key), Some(value)) = (m["id"].as_u64(), m["key"].as_str(), m.get("value")) else { return };
        let Some(c) = self.plugins.clients().into_iter().find(|c| c.id as u64 == id) else { return };
        c.send(json!({"type": "set", "key": key, "value": value}));
        if let Some(opts) = c.options.lock().unwrap().as_mut() {
            for o in opts.iter_mut().filter(|o| o["key"] == key) {
                o["value"] = value.clone();
            }
        }
        let mut s = self.settings.lock().unwrap();
        s.plugins.entry(c.name()).or_default().insert(key.to_string(), value.clone());
        s.save();
    }

    /// Keeps only well-formed items: {key, title, type: bool} or {key, title,
    /// type: choice, choices: [[value, label], …]}, plus a value. On a plugin's
    /// first declaration, re-applies what the user chose last time.
    fn declare_options(&self, c: &Arc<Client>, items: &Value) {
        let mut options = Vec::new();
        for o in items.as_array().into_iter().flatten() {
            let (Some(key), Some(title)) = (o["key"].as_str(), o["title"].as_str()) else { continue };
            match o["type"].as_str() {
                Some("bool") => options.push(json!({"key": key, "title": title, "type": "bool", "value": o["value"].as_bool().unwrap_or(false)})),
                Some("choice") => {
                    let choices: Vec<&Value> = o["choices"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|c| {
                            c.as_array().map(|a| a.len() == 2 && a[1].is_string() && (a[0].is_string() || a[0].is_number())).unwrap_or(false)
                        })
                        .collect();
                    if !choices.is_empty() {
                        options.push(json!({"key": key, "title": title, "type": "choice", "choices": choices, "value": o["value"]}));
                    }
                }
                _ => {}
            }
        }
        let first = c.options.lock().unwrap().is_none();
        if first {
            let saved = self.settings.lock().unwrap().plugins.get(&c.name()).cloned().unwrap_or_default();
            for o in options.iter_mut() {
                let Some(want) = saved.get(o["key"].as_str().unwrap()) else { continue };
                // Saved values must still fit: plugins change their choices over time.
                let fits = if o["type"] == "bool" {
                    want.is_boolean()
                } else {
                    o["choices"].as_array().unwrap().iter().any(|ch| &ch[0] == want)
                };
                if fits && &o["value"] != want {
                    c.send(json!({"type": "set", "key": o["key"], "value": want}));
                    o["value"] = want.clone();
                }
            }
        }
        *c.options.lock().unwrap() = Some(options);
    }
}

fn dirs_home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

pub fn home() -> PathBuf {
    dirs_home()
}

/// Plugins hand everything but hello/subscribe to the app.
pub struct PluginHost(pub std::sync::Weak<App>);

impl plugins::Host for PluginHost {
    fn hello_info(&self) -> Value {
        self.0.upgrade().map(|a| a.plugin_state()).unwrap_or(json!({}))
    }

    fn clients_changed(&self) {
        if let Some(app) = self.0.upgrade() {
            app.expire_overlay();
        }
    }

    fn message(&self, c: &Arc<Client>, msg: Value) {
        let Some(app) = self.0.upgrade() else { return };
        let prefix = format!("{}/", c.id);
        let ttl = num(&msg, "ttl").unwrap_or(0.0);
        let expires = if ttl > 0.0 { crate::now() + ttl } else { f64::INFINITY };
        match msg["type"].as_str().unwrap_or("") {
            "draw" => {
                let layer = msg["layer"].as_str().unwrap_or("default");
                let items = if msg["items"].is_array() { msg["items"].clone() } else { json!([]) };
                app.overlay.lock().unwrap().layers.insert(format!("{prefix}{layer}"), (items, expires));
                app.overlay_changed();
            }
            "clear" => {
                {
                    let mut o = app.overlay.lock().unwrap();
                    match msg["layer"].as_str() {
                        Some(l) => {
                            o.layers.remove(&format!("{prefix}{l}"));
                        }
                        None => o.layers.retain(|k, _| !k.starts_with(&prefix)),
                    }
                }
                app.overlay_changed();
            }
            "gimbal" | "zoom" | "roll" | "center" => {
                let mut m = msg.clone();
                m["cmd"] = msg["type"].clone();
                app.command(&m);
            }
            "hud" => {
                let key = format!("{prefix}{}", msg["key"].as_str().unwrap_or("default"));
                let text: String = msg["text"].as_str().unwrap_or("").chars().take(200).map(|c| if c == '\n' { ' ' } else { c }).collect();
                let color = msg["color"].as_str().filter(|c| c.starts_with('#') && matches!(c.len(), 7 | 9)).unwrap_or("#ffffff").to_string();
                {
                    let mut o = app.overlay.lock().unwrap();
                    if text.is_empty() {
                        o.hud.remove(&key);
                    } else {
                        o.hud.insert(key, (text, color, expires));
                    }
                }
                app.overlay_changed();
            }
            "record" => app.record_action(msg["action"].as_str().unwrap_or("")),
            "snapshot" => app.snapshot(),
            "options" => app.declare_options(c, &msg["items"]),
            "log" => crate::log!("[{}] {}", c.name(), msg["text"].as_str().map(String::from).unwrap_or_else(|| msg["text"].to_string())),
            other => crate::log!("[{}] unknown message type {other}", c.name()),
        }
    }
}
