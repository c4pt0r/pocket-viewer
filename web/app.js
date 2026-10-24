// pocket-viewer's web UI: the video (an MJPEG stream), the plugin overlay and
// HUD drawn over it, keyboard / mouse control, and a settings panel. All state
// lives in the server; this page sends commands and shows what it reports.
"use strict";

const $ = (id) => document.getElementById(id);
const stage = $("stage"), video = $("video"), canvas = $("overlay"), panel = $("panel");
const ctx = canvas.getContext("2d");

let status = null;        // the server's latest status message
let overlay = { layers: [], hud: [] };
let ws = null;
let step = 5;             // degrees per key press
let scaling = localStorage.getItem("scaling") || "fill";
let selection = null;     // ⌥-drag box, normalized {x, y, w, h}

// MARK: Connection

function send(cmd, fields = {}) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ cmd, ...fields }));
}

function connect() {
  ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  ws.onopen = () => {
    $("waiting").textContent = "waiting for video…";
    video.src = `/stream.mjpg?${Date.now()}`;
  };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "status") { status = m; render(); }
    else if (m.type === "overlay") { overlay = m; draw(); renderHud(); }
    else if (m.type === "devices") renderDevices(m);
    else if (m.type === "toast") toast(m.text);
  };
  ws.onclose = () => {
    $("waiting").hidden = false;
    $("waiting").textContent = "pocket-viewer is not running — reconnecting…";
    video.removeAttribute("src");
    setTimeout(connect, 1000);
  };
}

// An MJPEG stream never finishes loading, so `load` may not fire and Chrome
// reports no natural size: go by the server, which knows frames are flowing.
function checkVideo() {
  const c = status?.camera;
  const up = !!video.getAttribute("src") && (video.naturalWidth > 0 || (!!c?.connected && c.width > 0));
  if ($("waiting").hidden !== up) { $("waiting").hidden = up; draw(); }
}
video.onload = checkVideo;
video.onerror = () => { $("waiting").hidden = false; };

// MARK: Geometry

// Where the video lands on the stage under the current scaling, in CSS pixels.
function videoRect() {
  const W = stage.clientWidth, H = stage.clientHeight;
  const vw = video.naturalWidth || status?.camera?.width || 16, vh = video.naturalHeight || status?.camera?.height || 9;
  if (scaling === "stretch") return { x: 0, y: 0, w: W, h: H };
  const s = scaling === "fill" ? Math.max(W / vw, H / vh) : Math.min(W / vw, H / vh);
  const w = vw * s, h = vh * s;
  return { x: (W - w) / 2, y: (H - h) / 2, w, h };
}

function normalize(clientX, clientY) {
  const r = videoRect(), b = stage.getBoundingClientRect();
  return { x: (clientX - b.left - r.x) / r.w, y: (clientY - b.top - r.y) / r.h };
}

// MARK: Overlay

function color(c, fallback) {
  return typeof c === "string" && /^#([0-9a-f]{6}|[0-9a-f]{8})$/i.test(c) ? c : fallback;
}

function label(text, x, y, size, fg, bg) {
  ctx.font = `600 ${size}px -apple-system, system-ui, sans-serif`;
  const w = ctx.measureText(text).width + 8, h = size + 6;
  if (bg) { ctx.fillStyle = bg; roundRect(x, y, w, h, 3); ctx.fill(); }
  ctx.fillStyle = fg;
  ctx.textBaseline = "top";
  ctx.fillText(text, x + 4, y + 3);
}

function roundRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h);
}

function wrap(text, maxWidth) {
  const lines = [];
  for (const para of String(text).split("\n")) {
    // Words where there are spaces, characters otherwise (CJK has no spaces).
    const parts = para.includes(" ") ? para.split(/(?<= )/) : [...para];
    let line = "";
    for (const p of parts) {
      if (line && ctx.measureText(line + p).width > maxWidth) { lines.push(line.trimEnd()); line = p.trimStart(); }
      else line += p;
    }
    lines.push(line);
  }
  return lines;
}

function draw() {
  const dpr = window.devicePixelRatio || 1;
  const W = stage.clientWidth, H = stage.clientHeight;
  if (canvas.width !== Math.round(W * dpr) || canvas.height !== Math.round(H * dpr)) {
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  const v = videoRect();
  const px = (x) => v.x + x * v.w, py = (y) => v.y + y * v.h;
  const subtitles = [];
  for (const items of overlay.layers) {
    for (const it of Array.isArray(items) ? items : []) {
      if (!it || typeof it !== "object") continue;
      const stroke = color(it.color, "#30d158"), width = +it.width || 2;
      ctx.lineWidth = width;
      ctx.strokeStyle = stroke;
      if (it.shape === "rect") {
        const x = px(+it.x || 0), y = py(+it.y || 0), w = (+it.w || 0) * v.w, h = (+it.h || 0) * v.h;
        if (it.fill) { ctx.fillStyle = color(it.fill, "transparent"); ctx.fillRect(x, y, w, h); }
        ctx.strokeRect(x, y, w, h);
        if (typeof it.label === "string") {
          const size = +it.size || 13;
          label(it.label, x - width / 2, y - size - 6 - width / 2, size, "#000", stroke);
        }
      } else if (it.shape === "line") {
        ctx.beginPath();
        ctx.moveTo(px(+it.x1 || 0), py(+it.y1 || 0));
        ctx.lineTo(px(+it.x2 || 0), py(+it.y2 || 0));
        ctx.stroke();
      } else if (it.shape === "text" && typeof it.text === "string") {
        label(it.text, px(+it.x || 0), py(+it.y || 0), +it.size || 15, color(it.color, "#fff"), color(it.background, "rgba(0,0,0,.55)"));
      } else if (it.shape === "subtitle" && typeof it.text === "string") {
        subtitles.push(it);
      }
    }
  }
  if (selection) {
    ctx.setLineDash([6, 4]);
    ctx.lineWidth = 2;
    ctx.strokeStyle = "#fff";
    ctx.strokeRect(px(selection.x), py(selection.y), selection.w * v.w, selection.h * v.h);
    ctx.setLineDash([]);
  }
  // Subtitles stack upward from the bottom of the visible video, centred and wrapped.
  const vis = { x: Math.max(v.x, 0), y: Math.max(v.y, 0), r: Math.min(v.x + v.w, W), b: Math.min(v.y + v.h, H) };
  let bottom = vis.b - 24 - 40; // clear of the HUD
  for (const it of subtitles.reverse()) {
    const size = +it.size || 24;
    ctx.font = `500 ${size}px -apple-system, system-ui, sans-serif`;
    const lines = wrap(it.text, (vis.r - vis.x) * 0.9);
    const lh = size * 1.25;
    const tw = Math.max(...lines.map((l) => ctx.measureText(l).width));
    const bw = tw + 24, bh = lines.length * lh + 12;
    const bx = (vis.x + vis.r) / 2 - bw / 2, by = bottom - bh;
    ctx.fillStyle = color(it.background, "rgba(0,0,0,.6)");
    roundRect(bx, by, bw, bh, 6);
    ctx.fill();
    ctx.fillStyle = color(it.color, "#fff");
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    lines.forEach((l, i) => ctx.fillText(l, (vis.x + vis.r) / 2, by + 6 + i * lh + (lh - size) / 2));
    ctx.textAlign = "start";
    bottom = by - 8;
  }
}

// MARK: HUD and panel

function pad(n) { return String(Math.floor(n)).padStart(2, "0"); }
function fixed(x, d, w) { return (x ?? 0).toFixed(d).padStart(w); }

function renderHud() {
  const p = $("hud-plugins");
  p.replaceChildren(...overlay.hud.map((s) => {
    const e = document.createElement("span");
    e.textContent = s.text;
    e.style.color = s.color;
    return e;
  }));
  const main = $("hud-main");
  if (!status) return;
  const c = status.camera, g = status.gimbal, a = status.audio;
  const parts = [];
  let rec = "";
  if (status.recording) {
    const t = status.recording.seconds;
    rec = `🔴 REC ${pad(t / 3600)}:${pad((t / 60) % 60)}:${pad(t % 60)}   `;
  } else if (status.saving) rec = "saving…   ";
  const fps = c.kind === "stackchan" ? c.measuredFps : c.fps;
  parts.push(c.connected ? `${c.width}x${c.height}@${(+fps || 0).toFixed(c.kind === "stackchan" ? 1 : 0)}` : `waiting for ${c.name || "the camera"}`);
  parts.push(scaling);
  parts.push(g.pan !== undefined
    ? `pan ${fixed(g.pan, 1, 6)}°  tilt ${fixed(g.tilt, 1, 5)}°${g.hasRoll ? `  roll ${fixed(g.roll, 0, 3)}°` : ""}${g.zoomRange?.[1] > g.zoomRange?.[0] ? `  zoom ${fixed(g.zoom, 0, 3)}` : ""}  step ${fixed(step, 1, 4)}°`
    : "gimbal: n/a");
  const bars = Math.max(0, Math.min(20, Math.floor((a.level + 60) / 3)));
  parts.push(a.input ? `audio ${a.monitoring ? "🔊" : "🔇"} ${"|".repeat(bars).padEnd(20)} ${fixed(a.level, 0, 5)} dB` : "audio: none");
  main.replaceChildren();
  if (rec) {
    const r = document.createElement("span");
    r.className = "rec";
    r.textContent = rec;
    main.append(r);
  }
  main.append(` ${parts.join("   ")} `);
}

// Sets a control's value unless the user is using it right now.
function setIfIdle(el, value) {
  if (document.activeElement !== el && String(el.value) !== String(value)) el.value = value;
}

function fillSelect(el, options, value) {
  const key = JSON.stringify(options);
  if (el.dataset.key !== key) {
    el.dataset.key = key;
    el.replaceChildren(...options.map(([v, label]) => new Option(label, v)));
  }
  setIfIdle(el, value);
}

function render() {
  checkVideo();
  renderHud();
  draw();
  if (panel.hidden) return;
  const s = status, c = s.camera, g = s.gimbal;
  $("camera-name").textContent = c.connected ? `${c.name} — ${c.width}×${c.height}` : `Waiting for ${c.name || "the camera"}…`;
  document.querySelectorAll(".uvc-only").forEach((e) => (e.hidden = c.kind !== "uvc"));
  if (c.kind === "uvc") {
    fillSelect($("size"), s.sizes.map(([w, h]) => [`${w}x${h}`, `${w}×${h}${h > w ? " (portrait)" : ""}`]), `${c.width}x${c.height}`);
    fillSelect($("rate"), s.rates.map((r) => [r, `${r} fps`]), c.fps);
  }
  setIfIdle($("scaling"), scaling);

  const has = g.pan !== undefined;
  $("no-gimbal").hidden = has;
  document.querySelectorAll(".gimbal, .zoom-only, .roll-only").forEach((e) => (e.hidden = !has));
  if (has) {
    $("pan").textContent = `${g.pan.toFixed(1)}°`;
    $("tilt").textContent = `${g.tilt.toFixed(1)}°`;
    const z = $("zoom");
    z.min = g.zoomRange[0]; z.max = g.zoomRange[1];
    document.querySelector(".zoom-only").hidden = !(g.zoomRange[1] > g.zoomRange[0]);
    document.querySelector(".roll-only").hidden = !g.hasRoll;
    setIfIdle(z, g.zoom);
    $("zoom-value").textContent = Math.round(g.zoom);
    setIfIdle($("roll"), g.roll);
    $("roll-value").textContent = `${Math.round(g.roll)}°`;
  }
  setIfIdle($("step"), step);

  const rec = $("record");
  rec.textContent = s.recording ? "Stop" : s.saving ? "Saving…" : "Record";
  rec.classList.toggle("recording", !!s.recording);
  setIfIdle($("codec"), s.codec);
  setIfIdle($("audio-format"), s.audioFormat);
  setIfIdle($("output-dir"), s.outputDir);

  const a = s.audio;
  setIfIdle($("audio-input"), a.input ?? "");
  $("monitor").checked = a.monitoring;
  setIfIdle($("audio-output"), a.output ?? "");
  $("meter-bar").style.width = `${Math.max(0, Math.min(100, ((a.level + 60) / 60) * 100))}%`;

  renderPlugins();
  $("socket").textContent = s.socket;
}

function renderPlugins() {
  const key = JSON.stringify([status.plugins, status.pending]);
  const box = $("plugins");
  if (box.dataset.key === key || box.contains(document.activeElement)) return;
  box.dataset.key = key;
  const cards = status.plugins.map((p) => {
    const card = document.createElement("div");
    card.className = "plugin";
    const head = document.createElement("div");
    head.className = "head";
    const name = document.createElement("b");
    name.textContent = p.name + (p.external ? " (external)" : "");
    const stop = document.createElement("button");
    stop.textContent = "Stop";
    stop.onclick = () => send("stopPlugin", { id: p.id });
    head.append(name, stop);
    card.append(head);
    for (const o of p.options) {
      const row = document.createElement("label");
      row.className = "opt";
      if (o.type === "bool") {
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = !!o.value;
        cb.onchange = () => send("pluginOption", { id: p.id, key: o.key, value: cb.checked });
        row.append(cb, o.title);
      } else {
        const sel = document.createElement("select");
        o.choices.forEach(([v, l], i) => {
          const opt = new Option(l, i);
          if (v === o.value) opt.selected = true;
          sel.append(opt);
        });
        sel.onchange = () => send("pluginOption", { id: p.id, key: o.key, value: o.choices[sel.value][0] });
        row.append(`${o.title} `, sel);
      }
      card.append(row);
    }
    return card;
  });
  for (const t of status.pending) {
    const card = document.createElement("div");
    card.className = "plugin";
    card.innerHTML = `<div class="head"><span class="muted"></span><button>Stop</button></div>`;
    card.querySelector("span").textContent = `${t.command} (starting)`;
    card.querySelector("button").onclick = () => send("stopPlugin", { token: t.token });
    cards.push(card);
  }
  if (!cards.length) {
    const none = document.createElement("p");
    none.className = "muted";
    none.textContent = "No plugins running.";
    cards.push(none);
  }
  box.replaceChildren(...cards);
}

function renderDevices(m) {
  const input = $("audio-input");
  fillSelect(input, [["", "None (video only)"], ...m.inputs.map((n) => [n, n])], status?.audio?.input ?? "");
  fillSelect($("audio-output"), [["", "System default"], ...m.outputs.map((n) => [n, n])], status?.audio?.output ?? "");
  fillSelect($("catalog"), m.plugins.map((p) => [p.command, p.label]), $("catalog").value || m.plugins[0]?.command || "");
}

function toast(text) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = text;
  $("toasts").append(t);
  setTimeout(() => t.remove(), 5000);
}

// MARK: Controls

function setScaling(mode) {
  scaling = mode;
  try { localStorage.setItem("scaling", mode); } catch {}
  video.className = mode === "fill" ? "" : mode;
  draw();
  renderHud();
}

function openPanel(open) {
  panel.hidden = !open;
  if (open) { send("devices"); if (status) render(); }
  else stage.focus();
}

function fullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen?.();
}

function move(dx, dy) { send("gimbal", { dpan: dx * step, dtilt: dy * step }); }
function zoomRange() { const r = status?.gimbal?.zoomRange; return r ? r[1] - r[0] : 0; }

const typing = (e) => ["INPUT", "SELECT", "TEXTAREA"].includes(e.target.tagName) && e.target.type !== "range" && e.target.type !== "checkbox";

document.addEventListener("keydown", (e) => {
  if (typing(e) || e.metaKey || e.ctrlKey) return;
  const k = e.key;
  const handled = () => e.preventDefault();
  switch (k) {
    case "Escape":
      if (!panel.hidden) openPanel(false);
      send("input", { event: { event: "cancel" } });
      return handled();
    case " ":
      if (!e.repeat) send("input", { event: { event: "key", key: "space", state: "down" } });
      return handled();
    case "ArrowUp": move(0, 1); return handled();
    case "ArrowDown": move(0, -1); return handled();
    case "ArrowLeft": move(-1, 0); return handled();
    case "ArrowRight": move(1, 0); return handled();
  }
  switch (k.toLowerCase()) {
    case "w": move(0, 1); break;
    case "s": move(0, -1); break;
    case "a": move(-1, 0); break;
    case "d": move(1, 0); break;
    case "c": send("center"); break;
    case ",": send("roll", { droll: -2 }); break;
    case ".": send("roll", { droll: 2 }); break;
    case "r": send("record", { action: "toggle" }); break;
    case "]": step = Math.min(45, step * 2); renderHud(); break;
    case "[": step = Math.max(0.5, step / 2); renderHud(); break;
    case "+": case "=": send("zoom", { dzoom: zoomRange() / 10 }); break;
    case "-": send("zoom", { dzoom: -zoomRange() / 10 }); break;
    case "m": if (status) send("monitor", { on: !status.audio.monitoring }); break;
    case "f": fullscreen(); break;
    case "v": setScaling({ fill: "fit", fit: "stretch", stretch: "fill" }[scaling]); break;
    default: return;
  }
  handled();
});

document.addEventListener("keyup", (e) => {
  if (e.key === " " && !typing(e)) send("input", { event: { event: "key", key: "space", state: "up" } });
});

// Mouse: drag the scene to pan and tilt, click to point, ⌥/Alt-drag to box.
let down = null; // {x, y, alt, dragged}
let pending = { dpan: 0, dtilt: 0 }, frameQueued = false;

stage.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || e.target !== stage && e.target !== video) return;
  stage.focus();
  stage.setPointerCapture(e.pointerId);
  down = { x: e.clientX, y: e.clientY, lastX: e.clientX, lastY: e.clientY, alt: e.altKey, dragged: false };
});

stage.addEventListener("pointermove", (e) => {
  if (!down) return;
  if (Math.hypot(e.clientX - down.x, e.clientY - down.y) > 3) down.dragged = true;
  if (down.alt) {
    const a = normalize(down.x, down.y), b = normalize(e.clientX, e.clientY);
    const x = Math.max(0, Math.min(a.x, b.x)), y = Math.max(0, Math.min(a.y, b.y));
    selection = { x, y, w: Math.min(1, Math.max(a.x, b.x)) - x, h: Math.min(1, Math.max(a.y, b.y)) - y };
    draw();
    return;
  }
  if (!down.dragged) return;
  stage.classList.add("dragging");
  // Moving the mouse right pans right, up tilts up.
  pending.dpan += (e.clientX - down.lastX) * 0.15;
  pending.dtilt -= (e.clientY - down.lastY) * 0.15;
  down.lastX = e.clientX;
  down.lastY = e.clientY;
  if (!frameQueued) {
    frameQueued = true;
    requestAnimationFrame(() => {
      frameQueued = false;
      if (pending.dpan || pending.dtilt) send("gimbal", pending);
      pending = { dpan: 0, dtilt: 0 };
    });
  }
});

stage.addEventListener("pointerup", (e) => {
  if (!down) return;
  const d = down;
  down = null;
  stage.classList.remove("dragging");
  if (d.alt && d.dragged && selection) {
    const s = selection;
    selection = null;
    draw();
    if (s.w > 0.005 && s.h > 0.005) send("input", { event: { event: "select", ...s } });
    return;
  }
  selection = null;
  if (d.dragged) return;
  const n = normalize(d.x, d.y);
  if (n.x >= 0 && n.x <= 1 && n.y >= 0 && n.y <= 1) send("input", { event: { event: "click", x: n.x, y: n.y } });
});

stage.addEventListener("wheel", (e) => {
  e.preventDefault();
  const lines = e.deltaMode === 1 ? 20 : e.deltaMode === 2 ? 400 : 1;
  send("zoom", { dzoom: -e.deltaY * lines * 0.05 });
}, { passive: false });

stage.addEventListener("contextmenu", (e) => { e.preventDefault(); openPanel(panel.hidden); });
$("menu-button").onclick = () => openPanel(panel.hidden);
$("close-panel").onclick = () => openPanel(false);
window.addEventListener("resize", draw);

// Panel controls.
document.querySelectorAll("[data-move]").forEach((b) => {
  const [x, y] = b.dataset.move.split(",").map(Number);
  b.onclick = () => move(x, y);
});
$("center").onclick = () => send("center");
$("step").onchange = (e) => { step = +e.target.value; renderHud(); };
$("zoom").oninput = (e) => send("zoom", { zoom: +e.target.value });
$("roll").oninput = (e) => send("roll", { roll: +e.target.value });
$("size").onchange = $("rate").onchange = () => {
  const [w, h] = $("size").value.split("x").map(Number);
  send("format", { width: w, height: h, fps: +$("rate").value });
};
$("scaling").onchange = (e) => setScaling(e.target.value);
$("fullscreen").onclick = fullscreen;
$("record").onclick = () => send("record", { action: "toggle" });
$("snapshot").onclick = () => send("snapshot");
$("codec").onchange = (e) => send("codec", { value: e.target.value });
$("audio-format").onchange = (e) => send("audioFormat", { value: e.target.value });
$("output-dir").onchange = (e) => send("outputDir", { value: e.target.value });
$("audio-input").onchange = (e) => send("audioInput", { name: e.target.value || null });
$("audio-output").onchange = (e) => send("audioOutput", { name: e.target.value || null });
$("monitor").onchange = (e) => send("monitor", { on: e.target.checked });
$("launch-catalog").onclick = () => $("catalog").value && send("launchPlugin", { command: $("catalog").value });
$("launch-command").onclick = () => { send("launchPlugin", { command: $("command").value }); $("command").value = ""; };
$("command").onkeydown = (e) => { if (e.key === "Enter") $("launch-command").click(); };
$("quit").onclick = () => { if (confirm("Quit pocket-viewer? This stops the camera and all plugins.")) send("quit"); };

setScaling(scaling);
connect();
stage.focus();
if (location.hash === "#panel") openPanel(true);
