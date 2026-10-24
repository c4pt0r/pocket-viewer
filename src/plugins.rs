//! The plugin server: the wire protocol of plugins/PROTOCOL.md over a Unix
//! socket ($TMPDIR/pocket-viewer.sock), or on Windows a localhost TCP port
//! (POCKET_VIEWER_SOCKET=tcp:127.0.0.1:PORT). It launches plugins, fans video,
//! audio, state and input out to them, and hands everything else they send to
//! the app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::audio::{Chunk, Resampler};
use crate::frame::{encode_jpeg, fit_width, resize_rgb, rgb_to_bgra, Frame};

const MAX_HEADER: usize = 1 << 20; // 1 MB of JSON is plenty
const MAX_PAYLOAD: usize = 64 << 20; // plugins rarely send payloads
const WRITE_TIMEOUT: Duration = Duration::from_secs(3); // a client stuck this long is dropped
const MAX_AUDIO_IN_FLIGHT: usize = 64;

/// A plugin process pocket-viewer started.
pub struct Launch {
    pub token: String,
    pub command: String,
    #[cfg_attr(not(unix), allow(dead_code))]
    pid: Option<u32>,
    kill: Mutex<Option<tokio::sync::oneshot::Sender<()>>>, // to the task waiting on the process
}

impl Launch {
    /// SIGTERM where there is one, so plugins can clean up; else kill.
    fn terminate(&self) {
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            // SAFETY: plain kill(2) on a process we started and haven't reaped.
            unsafe { libc_kill(pid as i32, 15) };
            return;
        }
        if let Some(tx) = self.kill.lock().unwrap().take() {
            let _ = tx.send(());
        }
    }
}

#[cfg(unix)]
extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

struct Out {
    header: Value,
    payload: Bytes,
    done: Option<Box<dyn FnOnce() + Send>>,
}

#[derive(Default, Clone)]
struct Spec {
    video: Option<Value>,
    audio: Option<Value>,
    state: bool,
    input: bool,
}

pub struct Client {
    pub id: u32,
    pub name: Mutex<String>,
    pub launch: Mutex<Option<Arc<Launch>>>,
    /// Settings the plugin declared, with the user's choices applied.
    pub options: Mutex<Option<Vec<Value>>>,
    tx: mpsc::UnboundedSender<Out>,
    spec: Mutex<Spec>,
    video_busy: AtomicBool,
    last_video: Mutex<f64>,
    audio_in_flight: Arc<AtomicUsize>,
    resampler: Mutex<Option<Resampler>>,
    dead: AtomicBool,
}

impl Client {
    pub fn send(&self, header: Value) {
        self.send_with(header, Bytes::new(), None);
    }

    fn send_with(&self, mut header: Value, payload: Bytes, done: Option<Box<dyn FnOnce() + Send>>) {
        if !payload.is_empty() {
            header["size"] = json!(payload.len());
        }
        let _ = self.tx.send(Out { header, payload, done });
    }

    pub fn name(&self) -> String {
        self.name.lock().unwrap().clone()
    }
}

/// What the app does with plugins' messages.
pub trait Host: Send + Sync + 'static {
    /// Extra fields of the hello message (the current state).
    fn hello_info(&self) -> Value;
    fn message(&self, client: &Arc<Client>, msg: Value);
    /// Clients connected, disconnected, or were renamed.
    fn clients_changed(&self);
}

pub struct Server {
    /// What plugins connect to: a socket path, or "tcp:127.0.0.1:PORT".
    pub address: Mutex<String>,
    clients: Mutex<Vec<Arc<Client>>>,
    pending: Mutex<HashMap<String, Arc<Launch>>>,  // launched, not yet connected
    launched: Mutex<HashMap<String, Arc<Launch>>>, // connected at least once
    next_id: AtomicU32,
    converting: AtomicBool,
    host: Mutex<Option<Arc<dyn Host>>>,
}

trait Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + 'static> Stream for T {}

impl Server {
    pub fn new() -> Arc<Server> {
        Arc::new(Server {
            address: Mutex::new(String::new()),
            clients: Mutex::new(Vec::new()),
            pending: Mutex::new(HashMap::new()),
            launched: Mutex::new(HashMap::new()),
            next_id: AtomicU32::new(0),
            converting: AtomicBool::new(false),
            host: Mutex::new(None),
        })
    }

    fn host(&self) -> Arc<dyn Host> {
        self.host.lock().unwrap().clone().expect("plugin host set before start")
    }

    pub fn clients(&self) -> Vec<Arc<Client>> {
        self.clients.lock().unwrap().clone()
    }

    pub fn pending(&self) -> Vec<Arc<Launch>> {
        self.pending.lock().unwrap().values().cloned().collect()
    }

    /// Listens for plugins. Returns the address they connect to.
    pub async fn start(self: &Arc<Self>, host: Arc<dyn Host>) -> anyhow::Result<String> {
        *self.host.lock().unwrap() = Some(host);
        #[cfg(unix)]
        let address = {
            let path = std::env::temp_dir().join("pocket-viewer.sock");
            let _ = std::fs::remove_file(&path); // stale socket from a previous run
            let listener = tokio::net::UnixListener::bind(&path)?;
            // Owner-only: any process of this user can connect, nobody else.
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            let me = self.clone();
            tokio::spawn(async move {
                while let Ok((s, _)) = listener.accept().await {
                    me.add(Box::new(s));
                }
            });
            path.to_string_lossy().into_owned()
        };
        #[cfg(not(unix))]
        let address = {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
            let addr = format!("tcp:{}", listener.local_addr()?);
            // Plugins started on their own find the port here.
            let _ = std::fs::write(std::env::temp_dir().join("pocket-viewer.port"), &addr);
            let me = self.clone();
            tokio::spawn(async move {
                while let Ok((s, _)) = listener.accept().await {
                    let _ = s.set_nodelay(true);
                    me.add(Box::new(s));
                }
            });
            addr
        };
        *self.address.lock().unwrap() = address.clone();
        Ok(address)
    }

    pub fn shutdown(&self) {
        for c in self.clients() {
            if let Some(l) = c.launch.lock().unwrap().as_ref() {
                l.terminate();
            }
        }
        for l in self.pending() {
            l.terminate();
        }
        #[cfg(unix)]
        let _ = std::fs::remove_file(self.address.lock().unwrap().as_str());
    }

    fn add(self: &Arc<Self>, stream: Box<dyn Stream>) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, mut rx) = mpsc::unbounded_channel::<Out>();
        let client = Arc::new(Client {
            id,
            name: Mutex::new(format!("client {id}")),
            launch: Mutex::new(None),
            options: Mutex::new(None),
            tx,
            spec: Mutex::new(Spec::default()),
            video_busy: AtomicBool::new(false),
            last_video: Mutex::new(0.0),
            audio_in_flight: Arc::new(AtomicUsize::new(0)),
            resampler: Mutex::new(None),
            dead: AtomicBool::new(false),
        });
        self.clients.lock().unwrap().push(client.clone());
        self.host().clients_changed();

        let (mut reader, mut writer) = tokio::io::split(stream);
        // Writer: one message at a time; a client that stops reading is dropped.
        let me = self.clone();
        let c = client.clone();
        tokio::spawn(async move {
            while let Some(out) = rx.recv().await {
                let header = serde_json::to_vec(&out.header).unwrap_or_default();
                let mut msg = Vec::with_capacity(4 + header.len() + out.payload.len());
                msg.extend_from_slice(&(header.len() as u32).to_be_bytes());
                msg.extend_from_slice(&header);
                msg.extend_from_slice(&out.payload);
                let ok = matches!(tokio::time::timeout(WRITE_TIMEOUT, writer.write_all(&msg)).await, Ok(Ok(())));
                if let Some(done) = out.done {
                    done();
                }
                if !ok {
                    me.disconnect(&c);
                    break;
                }
            }
            let _ = writer.shutdown().await;
        });
        // Reader.
        let me = self.clone();
        let c = client.clone();
        tokio::spawn(async move {
            let result: anyhow::Result<()> = async {
                loop {
                    let hlen = reader.read_u32().await? as usize;
                    anyhow::ensure!(hlen > 0 && hlen <= MAX_HEADER, "bad header length");
                    let mut h = vec![0u8; hlen];
                    reader.read_exact(&mut h).await?;
                    let msg: Value = serde_json::from_slice(&h)?;
                    anyhow::ensure!(msg.is_object(), "header is not an object");
                    let size = msg.get("size").and_then(Value::as_u64).unwrap_or(0) as usize;
                    anyhow::ensure!(size <= MAX_PAYLOAD, "payload too large");
                    let mut payload = vec![0u8; size];
                    reader.read_exact(&mut payload).await?;
                    me.handle(&c, msg);
                }
            }
            .await;
            let _ = result;
            me.disconnect(&c);
        });

        let mut hello = json!({"type": "hello", "protocol": 1, "clientID": id});
        if let (Value::Object(h), Value::Object(extra)) = (&mut hello, self.host().hello_info()) {
            h.extend(extra);
        }
        client.send(hello);
    }

    fn disconnect(&self, c: &Arc<Client>) {
        if c.dead.swap(true, Ordering::Relaxed) {
            return;
        }
        self.clients.lock().unwrap().retain(|x| x.id != c.id);
        crate::log!("plugin disconnected: {}", c.name());
        self.host().clients_changed();
    }

    fn handle(&self, c: &Arc<Client>, msg: Value) {
        match msg["type"].as_str() {
            Some("hello") => {
                if let Some(n) = msg["name"].as_str() {
                    *c.name.lock().unwrap() = n.to_string();
                }
                let token = msg["token"].as_str().unwrap_or("");
                let launch = self.pending.lock().unwrap().remove(token).or_else(|| self.launched.lock().unwrap().get(token).cloned());
                if let Some(l) = launch {
                    // Remember it: a plugin that re-execs itself (to apply
                    // settings) reconnects with the same token and is still ours.
                    self.launched.lock().unwrap().insert(token.to_string(), l.clone());
                    *c.launch.lock().unwrap() = Some(l);
                }
                crate::log!("plugin connected: {}", c.name());
                self.host().clients_changed();
            }
            Some("subscribe") => {
                let part = |k: &str| match &msg[k] {
                    Value::Null | Value::Bool(false) => None,
                    Value::Bool(true) => Some(json!({})),
                    v @ Value::Object(_) => Some(v.clone()),
                    _ => None,
                };
                *c.spec.lock().unwrap() =
                    Spec { video: part("video"), audio: part("audio"), state: part("state").is_some(), input: part("input").is_some() };
                *c.resampler.lock().unwrap() = None; // the spec may have changed
            }
            Some(_) => self.host().message(c, msg),
            None => {}
        }
    }

    /// Starts `command` through the shell, with the socket and a token in its
    /// environment so its connection can be told apart from external ones.
    pub fn launch(self: &Arc<Self>, command: &str) {
        let token = uuid::Uuid::new_v4().to_string();
        #[cfg(unix)]
        let mut cmd = {
            let mut c = tokio::process::Command::new("/bin/sh");
            c.arg("-c").arg(command);
            c
        };
        #[cfg(windows)]
        let mut cmd = {
            let mut c = tokio::process::Command::new("cmd");
            c.arg("/C").arg(command);
            c
        };
        cmd.env("POCKET_VIEWER_SOCKET", self.address.lock().unwrap().as_str()).env("POCKET_VIEWER_TOKEN", &token).kill_on_drop(true);
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                crate::log!("cannot launch plugin {command}: {e}");
                return;
            }
        };
        crate::log!("launched plugin: {command}");
        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel::<()>();
        let launch = Arc::new(Launch { token: token.clone(), command: command.to_string(), pid: child.id(), kill: Mutex::new(Some(kill_tx)) });
        self.pending.lock().unwrap().insert(token.clone(), launch.clone());
        self.host().clients_changed();
        let me = self.clone();
        tokio::spawn(async move {
            let status = tokio::select! {
                s = child.wait() => s.ok(),
                _ = kill_rx => {
                    let _ = child.start_kill();
                    child.wait().await.ok()
                }
            };
            crate::log!(
                "plugin exited ({}): {}",
                status.and_then(|s| s.code()).map(|c| c.to_string()).unwrap_or_else(|| "signal".into()),
                launch.command
            );
            me.pending.lock().unwrap().remove(&launch.token);
            me.launched.lock().unwrap().remove(&launch.token);
            me.host().clients_changed();
        });
    }

    /// Stops a plugin: kills the process if we launched it, and drops the connection.
    pub fn stop(&self, id: u32) {
        if let Some(c) = self.clients().into_iter().find(|c| c.id == id) {
            if let Some(l) = c.launch.lock().unwrap().as_ref() {
                l.terminate();
            }
            self.disconnect(&c);
        }
    }

    pub fn stop_pending(&self, token: &str) {
        if let Some(l) = self.pending.lock().unwrap().get(token) {
            l.terminate();
        }
    }

    pub fn broadcast_state(&self, state: &Value) {
        let mut msg = state.clone();
        msg["type"] = json!("state");
        for c in self.clients() {
            if c.spec.lock().unwrap().state {
                c.send(msg.clone());
            }
        }
    }

    pub fn broadcast_input(&self, event: &Value) {
        let mut msg = event.clone();
        msg["type"] = json!("input");
        for c in self.clients() {
            if c.spec.lock().unwrap().input {
                c.send(msg.clone());
            }
        }
    }

    /// Hands a new frame to every plugin that is due one at its frame rate and
    /// has taken its previous frame (it skips frames rather than queueing them).
    pub fn push_video(self: &Arc<Self>, frame: Arc<Frame>) {
        let now = crate::now();
        let due: Vec<(Arc<Client>, Value)> = self
            .clients()
            .into_iter()
            .filter_map(|c| {
                let spec = c.spec.lock().unwrap().video.clone()?;
                if c.video_busy.load(Ordering::Relaxed) {
                    return None;
                }
                let fps = spec["fps"].as_f64().filter(|&f| f > 0.0).unwrap_or(15.0);
                let last = *c.last_video.lock().unwrap();
                (now - last >= 0.9 / fps).then_some((c, spec))
            })
            .collect();
        if due.is_empty() || self.converting.swap(true, Ordering::Relaxed) {
            return; // one conversion at a time
        }
        let me = self.clone();
        tokio::task::spawn_blocking(move || {
            me.convert_video(&frame, due);
            me.converting.store(false, Ordering::Relaxed);
        });
    }

    fn convert_video(&self, frame: &Frame, clients: Vec<(Arc<Client>, Value)>) {
        let mut cache: HashMap<String, (u32, u32, Bytes)> = HashMap::new();
        let mut scaled: HashMap<u32, (u32, Vec<u8>)> = HashMap::new();
        for (c, spec) in clients {
            let format = if spec["format"] == "jpeg" { "jpeg" } else { "bgra" };
            let max_w = spec["maxWidth"].as_f64().unwrap_or(640.0).max(16.0) as u32;
            let (w, h) = fit_width(frame.width, frame.height, max_w);
            let quality = spec["quality"].as_f64().unwrap_or(0.7).clamp(0.1, 1.0);
            let key = format!("{format} {w} {quality:.2}");
            if !cache.contains_key(&key) {
                let data = if format == "jpeg" && w == frame.width && matches!(frame.pixels, crate::frame::Pixels::Jpeg(_)) {
                    frame.full_jpeg(90)
                } else {
                    let Some(rgb) = frame.rgb() else { continue };
                    let (_, px) = scaled.entry(w).or_insert_with(|| (h, resize_rgb(&rgb, frame.width, frame.height, w, h)));
                    if format == "jpeg" {
                        encode_jpeg(px, w, h, (quality * 100.0) as u8).map(Bytes::from)
                    } else {
                        Some(Bytes::from(rgb_to_bgra(px)))
                    }
                };
                let Some(data) = data else { continue };
                cache.insert(key.clone(), (w, h, data));
            }
            let (w, h, data) = cache[&key].clone();
            c.video_busy.store(true, Ordering::Relaxed);
            *c.last_video.lock().unwrap() = crate::now();
            let cc = c.clone();
            c.send_with(
                json!({"type": "video", "pts": frame.pts, "width": w, "height": h, "format": format}),
                data,
                Some(Box::new(move || cc.video_busy.store(false, Ordering::Relaxed))),
            );
        }
    }

    /// Converts a chunk to each subscriber's rate and channels, 16-bit.
    pub fn push_audio(&self, chunk: &Chunk) {
        for c in self.clients() {
            let Some(spec) = c.spec.lock().unwrap().audio.clone() else { continue };
            if c.audio_in_flight.load(Ordering::Relaxed) >= MAX_AUDIO_IN_FLIGHT {
                continue;
            }
            let rate = spec["rate"].as_f64().unwrap_or(16000.0).clamp(8000.0, 192000.0) as u32;
            let channels = spec["channels"].as_f64().unwrap_or(1.0).clamp(1.0, 8.0) as u16;
            let out = {
                let mut r = c.resampler.lock().unwrap();
                let rs = r.get_or_insert_with(|| Resampler::new(chunk.rate, chunk.channels, rate, channels));
                if rs.from != (chunk.rate, chunk.channels) {
                    *rs = Resampler::new(chunk.rate, chunk.channels, rate, channels);
                }
                rs.process(&chunk.samples)
            };
            if out.is_empty() {
                continue;
            }
            let mut data = Vec::with_capacity(out.len() * 2);
            for s in &out {
                data.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes());
            }
            c.audio_in_flight.fetch_add(1, Ordering::Relaxed);
            let n = c.audio_in_flight.clone();
            c.send_with(
                json!({"type": "audio", "pts": chunk.pts, "rate": rate, "channels": channels, "format": "s16le",
                       "frames": out.len() / channels as usize}),
                Bytes::from(data),
                Some(Box::new(move || {
                    n.fetch_sub(1, Ordering::Relaxed);
                })),
            );
        }
    }
}
