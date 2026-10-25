//! The local web server: the UI (embedded in the binary), the video as an
//! MJPEG stream, and a WebSocket for status, the plugin overlay and commands.

use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};

use crate::app::App;

const INDEX: &str = include_str!("../web/index.html");
const APP_JS: &str = include_str!("../web/app.js");
const STYLE: &str = include_str!("../web/style.css");

pub fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/", get(|| async { ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], INDEX) }))
        .route("/app.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript; charset=utf-8")], APP_JS) }))
        .route("/style.css", get(|| async { ([(header::CONTENT_TYPE, "text/css; charset=utf-8")], STYLE) }))
        .route("/stream.mjpg", get(stream))
        .route("/frame.jpg", get(frame))
        .route("/ws", get(ws))
        .with_state(app)
}

/// The newest frame as a JPEG, encoding it off the async threads if needed.
async fn preview(f: Arc<crate::frame::Frame>) -> Option<Bytes> {
    tokio::task::spawn_blocking(move || f.preview_jpeg()).await.ok().flatten()
}

/// multipart/x-mixed-replace: every browser shows it in an <img>, and a slow
/// connection simply gets fewer frames (each waits for the previous write).
async fn stream(State(app): State<Arc<App>>) -> Response {
    let rx = app.frames.subscribe();
    let body = futures_util::stream::unfold(rx, |mut rx| async move {
        loop {
            rx.changed().await.ok()?;
            let Some(f) = rx.borrow_and_update().clone() else { continue };
            let Some(jpeg) = preview(f).await else { continue };
            let mut part = format!("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n", jpeg.len()).into_bytes();
            part.extend_from_slice(&jpeg);
            part.extend_from_slice(b"\r\n");
            return Some((Ok::<_, Infallible>(Bytes::from(part)), rx));
        }
    });
    Response::builder()
        .header(header::CONTENT_TYPE, "multipart/x-mixed-replace; boundary=frame")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from_stream(body))
        .unwrap()
}

async fn frame(State(app): State<Arc<App>>) -> Response {
    let f = app.frames.borrow().clone();
    match match f {
        Some(f) => preview(f).await,
        None => None,
    } {
        Some(jpeg) => ([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "no-store")], jpeg).into_response(),
        None => (axum::http::StatusCode::SERVICE_UNAVAILABLE, "no video yet").into_response(),
    }
}

async fn ws(State(app): State<Arc<App>>, upgrade: WebSocketUpgrade) -> Response {
    upgrade.on_upgrade(move |socket| session(app, socket))
}

fn devices(app: &App) -> String {
    let a = app.audio.status();
    json!({"type": "devices", "inputs": a.inputs, "outputs": a.outputs, "plugins": catalog()}).to_string()
}

async fn session(app: Arc<App>, socket: WebSocket) {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    session_loop(&app, socket, id).await;
    app.screen_stop(id);
}

async fn session_loop(app: &Arc<App>, socket: WebSocket, id: u64) {
    let (mut tx, mut rx) = socket.split();
    let mut events = app.events.subscribe();
    let first = [json!({"type": "session", "id": id}).to_string(), app.status().to_string(), app.overlay_message(), devices(app)];
    for m in first {
        if tx.send(Message::Text(m.into())).await.is_err() {
            return;
        }
    }
    let mut tick = tokio::time::interval(Duration::from_millis(200));
    loop {
        let out = tokio::select! {
            _ = tick.tick() => app.status().to_string(),
            ev = events.recv() => match ev {
                Ok(m) => m,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => app.overlay_message(),
                Err(_) => return,
            },
            msg = rx.next() => match msg {
                Some(Ok(Message::Text(t))) => {
                    let Ok(m) = serde_json::from_str::<Value>(&t) else { continue };
                    if m["cmd"] == "devices" {
                        let a = app.clone();
                        tokio::task::spawn_blocking(move || devices(&a)).await.unwrap_or_default()
                    } else if m["cmd"] == "screenStop" {
                        app.screen_stop(id);
                        continue;
                    } else {
                        app.command(&m);
                        continue;
                    }
                }
                // A binary message is a JPEG from this browser's camera, for the StackChan's screen.
                Some(Ok(Message::Binary(jpeg))) => {
                    if jpeg.len() <= 1 << 20 {
                        app.screen_picture(id, jpeg);
                    }
                    continue;
                }
                Some(Ok(_)) => continue,
                _ => return,
            },
        };
        if tx.send(Message::Text(out.into())).await.is_err() {
            return;
        }
    }
}

/// The repository's plugins directory: next to the working directory, or
/// above the executable (target/release/pocket-viewer → the repository).
pub fn plugins_dir() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok();
    let exe = std::env::current_exe().ok();
    cwd.into_iter()
        .chain(exe.iter().flat_map(|e| e.ancestors().skip(1).take(4).map(Path::to_path_buf)))
        .map(|d| d.join("plugins"))
        .find(|d| d.join("PROTOCOL.md").exists())
}

/// Plugins found in the repository, as commands to launch: the built Swift
/// plugins, the Python and Node examples.
fn catalog() -> Vec<Value> {
    let Some(dir) = plugins_dir() else { return Vec::new() };
    let q = |p: &Path| shell_quote(&p.to_string_lossy());
    let mut out = Vec::new();
    let mut files = |sub: &str, ext: Option<&str>, run: &dyn Fn(&Path) -> String| {
        let Ok(rd) = std::fs::read_dir(dir.join(sub)) else { return };
        let mut entries: Vec<PathBuf> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
        entries.sort();
        for p in entries {
            let name = p.file_name().unwrap().to_string_lossy().into_owned();
            let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
            // Not plugins: the SDKs, and transcribe (a helper other plugins run).
            if name.starts_with('.') || stem == "pocketviewer" || stem == "transcribe" || !p.is_file() {
                continue;
            }
            if ext.is_some_and(|e| p.extension().and_then(|x| x.to_str()) != Some(e)) {
                continue;
            }
            out.push(json!({"label": stem, "command": run(&p)}));
        }
    };
    files("bin", None, &|p| q(p));
    let python = if cfg!(windows) { "python" } else { "python3" };
    files("python", Some("py"), &|p| format!("{python} {}", q(p)));
    files("node", Some("ts"), &|p| format!("node {}", q(p)));
    let agent = dir.join("node/ai-agent/ai-agent.ts");
    if agent.exists() {
        out.push(json!({"label": "ai-agent", "command": format!("node {}", q(&agent))}));
    }
    out
}

pub fn shell_quote(s: &str) -> String {
    if cfg!(windows) {
        format!("\"{s}\"")
    } else if s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+:".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}
