// ai-agent — pocket-viewer plugin: a voice assistant that can see through the
// camera and steer it, built on the pi SDK (@earendil-works/pi-coding-agent).
//
// Hold Space in the video window and talk, release to send (or choose
// "always listening" / a wake word in its menu). Speech is recognized on-device
// (plugins/bin/transcribe); the reply streams in as a subtitle and is read
// aloud with `say`. When the answer depends on what's in view, the model calls
// `look` for the current frame (or several, a moment apart), or
// `recent_keyframes` for how the scene changed in the last minutes. It can
// also turn and zoom the camera, record and take snapshots.
//
//   node plugins/node/ai-agent/ai-agent.ts [--model gpt-5.4-mini] [--thinking low]
//        [--lang zh-CN] [--listen push|always|<wake word>] [--pause 1.8] [--follow] [--no-speak] [--key-file path]
//
// The model is OpenAI's, through pi; the key comes from --key-file,
// $OPENAI_API_KEY, ./.openai-key or ~/.config/pocket-viewer/openai-key.
// Esc in the video window (or saying 「停」 / "stop") interrupts it.

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { crc32, deflateSync } from "node:zlib";
import { Type } from "typebox";
import {
  createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { PocketViewer, type Message, type VideoFrame } from "../pocketviewer.ts";

const REPO = path.resolve(import.meta.dirname, "../../..");

// --- options ---------------------------------------------------------------

/** Whether Chinese is among the user's preferred languages (System Settings → Language & Region). */
function prefersChinese(): boolean {
  try {
    return /\bzh/.test(execFileSync("defaults", ["read", "-g", "AppleLanguages"], { encoding: "utf8" }));
  } catch {
    return Intl.DateTimeFormat().resolvedOptions().locale.startsWith("zh");
  }
}

const opt = {
  model: "gpt-5.4-mini",
  thinking: "low",
  lang: prefersChinese() ? "zh-CN" : "en-US",
  listen: "push",    // "push" (hold Space), "always", or a wake word
  pause: 1.8,        // listen "always" / wake word: seconds of silence that end a phrase
  speak: true,
  follow: false,     // keep the user's face framed (runs plugins/bin/face-follow)
  keyFile: undefined as string | undefined,
};
{
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => args[++i] ?? "";
    if (a === "--model") opt.model = next();
    else if (a === "--thinking") opt.thinking = next();
    else if (a === "--lang") opt.lang = next();
    else if (a === "--listen") opt.listen = next();
    else if (a === "--pause") opt.pause = Number(next()) || opt.pause;
    else if (a === "--no-speak") opt.speak = false;
    else if (a === "--follow") opt.follow = true;
    else if (a === "--key-file") opt.keyFile = next();
    else {
      console.error("usage: ai-agent.ts [--model m] [--thinking off|low|medium] [--lang zh-CN|en-US] [--listen push|always|word] [--pause secs] [--follow] [--no-speak] [--key-file path]");
      process.exit(2);
    }
  }
}

function openAIKey(): string | undefined {
  const read = (p: string) => {
    try { return readFileSync(p, "utf8").trim() || undefined; } catch { return undefined; }
  };
  if (opt.keyFile) return read(opt.keyFile);
  return process.env.OPENAI_API_KEY || read(path.join(process.cwd(), ".openai-key")) || read(path.join(REPO, ".openai-key"))
    || read(path.join(os.homedir(), ".config/pocket-viewer/openai-key"));
}

const pv = await PocketViewer.connect("ai-agent");
pv.onClose = () => process.exit(0);

// --- camera: latest frame and keyframes ------------------------------------

/** Encodes a BGRA frame as an RGB PNG (no dependencies: zlib does the work). */
function encodePNG(f: VideoFrame): Buffer {
  const { width: w, height: h, data } = f;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    const row = y * (w * 3 + 1);  // byte 0 of each row: filter type 0
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 4, d = row + 1 + x * 3;
      raw[d] = data[s + 2]; raw[d + 1] = data[s + 1]; raw[d + 2] = data[s];
    }
  }
  const chunk = (type: string, body: Buffer) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(body.length);
    const tb = Buffer.concat([Buffer.from(type, "ascii"), body]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(tb));
    return Buffer.concat([len, tb, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;  // 8-bit RGB
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 6 })), chunk("IEND", Buffer.alloc(0))]);
}

/** 32×18 grayscale thumbnail, for telling whether the scene changed. */
function thumbnail(f: VideoFrame): Float32Array {
  const tw = 32, th = 18, t = new Float32Array(tw * th);
  for (let y = 0; y < th; y++)
    for (let x = 0; x < tw; x++) {
      const s = (Math.floor((y + 0.5) * f.height / th) * f.width + Math.floor((x + 0.5) * f.width / tw)) * 4;
      t[y * tw + x] = 0.11 * f.data[s] + 0.59 * f.data[s + 1] + 0.3 * f.data[s + 2];
    }
  return t;
}

const difference = (a: Float32Array, b: Float32Array) => a.reduce((sum, v, i) => sum + Math.abs(v - b[i]), 0) / a.length;

function gimbalMoving(): boolean {
  const st = pv.state;
  if (typeof st.pan !== "number") return false;
  return Math.abs(st.pan - st.actualPan) >= 1 || Math.abs(st.tilt - st.actualTilt) >= 1;
}

interface Shot { time: number; frame: VideoFrame; }
let latest: Shot | undefined;
const keyframes: (Shot & { thumb: Float32Array })[] = [];
const KEYFRAME_CHANGE = 12;    // mean gray-level difference that counts as a new scene
const KEYFRAME_MAX_GAP = 20e3; // keep one at least this often (ms), even if nothing changes
const KEYFRAME_KEEP = 10 * 60e3;

pv.onVideo = (frame) => {
  if (frame.format !== "bgra") return;
  const now = Date.now();
  latest = { time: now, frame };
  if (gimbalMoving()) return;  // everything "changes" mid-move
  const thumb = thumbnail(frame);
  const last = keyframes.at(-1);
  if (!last || difference(thumb, last.thumb) > KEYFRAME_CHANGE || now - last.time > KEYFRAME_MAX_GAP) {
    keyframes.push({ time: now, frame, thumb });
    while (keyframes.length && now - keyframes[0].time > KEYFRAME_KEEP) keyframes.shift();
    if (keyframes.length > 40) keyframes.splice(0, keyframes.length - 40);
  }
};

const sleep = (ms: number, signal?: AbortSignal) => new Promise<void>((resolve, reject) => {
  const t = setTimeout(resolve, ms);
  signal?.addEventListener("abort", () => { clearTimeout(t); reject(new Error("aborted")); }, { once: true });
});

/** Waits until the gimbal has stopped, then for a frame taken after that. */
async function settledFrame(signal?: AbortSignal, timeout = 15e3): Promise<Shot | undefined> {
  const start = Date.now();
  let still = 0;
  while (Date.now() - start < timeout && still < 2) {
    still = gimbalMoving() ? 0 : still + 1;
    await sleep(100, signal);
  }
  const since = Date.now();
  while (Date.now() - since < 2000 && (!latest || latest.time < since + 100)) await sleep(50, signal);
  return latest;
}

function cameraDescription(): string {
  const st = pv.state;
  if (typeof st.pan !== "number") return "Gimbal state unknown.";
  const z = (st.zoom ?? 100) / 100;
  const [w, h] = Array.isArray(st.fov) && st.fov.length === 2 ? st.fov : [95, 53];  // StackChan reports its own
  return `Camera: pan ${st.actualPan.toFixed(0)}°, tilt ${st.actualTilt.toFixed(0)}°, zoom ${st.zoom?.toFixed(0)} ` +
    `(field of view about ${(w / z).toFixed(0)}° × ${(h / z).toFixed(0)}°)` + (st.recording ? ", recording." : ".");
}

const image = (f: VideoFrame) => ({ type: "image" as const, mimeType: "image/png", data: encodePNG(f).toString("base64") });
const text = (t: string) => ({ type: "text" as const, text: t });

// --- face following ----------------------------------------------------------

// Runs the face-follow plugin alongside, as its own client: it shows up in the
// Plugins menu as "face-follow (ai-agent)" with its own settings. Without our
// token, so stopping it there doesn't stop this plugin.
let follower: ChildProcess | undefined;
function setFollow(on: boolean) {
  if (on === !!follower) return;
  opt.follow = on;
  if (on) {
    const env = { ...process.env };
    delete env.POCKET_VIEWER_TOKEN;
    const proc = spawn(path.join(REPO, "plugins/bin/face-follow"), ["--name", "face-follow (ai-agent)"], { stdio: "ignore", env });
    follower = proc;
    proc.on("error", (err) => pv.log("cannot start face-follow (run make plugins): " + err.message));
    proc.on("exit", () => {
      if (follower !== proc) return;
      follower = undefined;  // stopped from the Plugins menu, or crashed
      opt.follow = false;
      declareOptions();
    });
  } else {
    const proc = follower;
    follower = undefined;
    proc?.kill();
  }
  pv.log(`face following ${on ? "on" : "off"}`);
  declareOptions();
}

/** The model is about to aim the camera itself: stop face following first. */
function takeCamera(): string {
  if (!follower) return "";
  setFollow(false);
  return " Face following was turned off for this.";
}

// --- tools -----------------------------------------------------------------

const tools: ToolDefinition[] = [
  {
    name: "look",
    label: "Look",
    description: "See what the camera sees now. Waits for the gimbal to stop first. With frames > 1, takes that many " +
      "frames `interval` seconds apart, to see motion or something that takes a moment.",
    parameters: Type.Object({
      frames: Type.Optional(Type.Integer({ minimum: 1, maximum: 4, description: "number of frames, default 1" })),
      interval: Type.Optional(Type.Number({ minimum: 0.3, maximum: 5, description: "seconds between frames, default 1" })),
    }),
    async execute(_id, params: any, signal) {
      status("👀 looking", "#66ccff");
      const content: any[] = [];
      const n = params.frames ?? 1;
      for (let i = 0; i < n; i++) {
        if (i > 0) await sleep((params.interval ?? 1) * 1000, signal);
        const shot = i === 0 ? await settledFrame(signal) : latest;
        if (!shot) return { content: [text("No video from the camera.")], details: {} };
        if (n > 1) content.push(text(`Frame ${i + 1} of ${n}:`));
        content.push(image(shot.frame));
      }
      return { content: [text(cameraDescription()), ...content], details: {} };
    },
  },
  {
    name: "recent_keyframes",
    label: "Recent keyframes",
    description: "Frames from the last minutes, kept whenever the scene changed (and at least every 20 s), oldest " +
      "first. Use for questions about what happened or what was in view earlier.",
    parameters: Type.Object({
      seconds: Type.Optional(Type.Number({ minimum: 5, maximum: 600, description: "how far back, default 60" })),
      max: Type.Optional(Type.Integer({ minimum: 1, maximum: 8, description: "most frames to return, default 6" })),
    }),
    async execute(_id, params: any) {
      status("👀 recalling", "#66ccff");
      const now = Date.now();
      const recent = keyframes.filter((k) => now - k.time <= (params.seconds ?? 60) * 1000);
      if (!recent.length) return { content: [text("No keyframes in that period.")], details: {} };
      const max = params.max ?? 6;
      // Evenly spaced, always including the newest.
      const picked = recent.length <= max ? recent
        : Array.from({ length: max }, (_, i) => recent[Math.round(i * (recent.length - 1) / (max - 1 || 1))]);
      const content: any[] = [];
      for (const k of picked) content.push(text(`${Math.round((now - k.time) / 1000)} s ago:`), image(k.frame));
      return { content, details: {} };
    },
  },
  {
    name: "move_camera",
    label: "Move camera",
    description: "Turn the gimbal, in degrees. Absolute pan/tilt, or relative dpan/dtilt. +pan turns right, +tilt " +
      "turns up; pan 0 / tilt 0 is straight ahead. It moves about 8°/s; this returns once it has arrived.",
    parameters: Type.Object({
      pan: Type.Optional(Type.Number()), tilt: Type.Optional(Type.Number()),
      dpan: Type.Optional(Type.Number()), dtilt: Type.Optional(Type.Number()),
    }),
    async execute(_id, params: any, signal) {
      status("🎥 turning", "#66ccff");
      const note = takeCamera();
      pv.gimbal(params);
      await sleep(300, signal);  // let the state report the new target
      await settledFrame(signal);
      return { content: [text(cameraDescription() + note)], details: {} };
    },
  },
  {
    name: "zoom_camera",
    label: "Zoom",
    description: "Set the zoom, 100 (widest) to 400 (4×).",
    parameters: Type.Object({ zoom: Type.Number({ minimum: 100, maximum: 400 }) }),
    async execute(_id, params: any, signal) {
      status("🎥 zooming", "#66ccff");
      pv.zoom(params.zoom);
      await sleep(1500, signal);
      return { content: [text(cameraDescription())], details: {} };
    },
  },
  {
    name: "center_camera",
    label: "Center",
    description: "Point the camera straight ahead and level it.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal) {
      const note = takeCamera();
      pv.center();
      await sleep(300, signal);
      await settledFrame(signal);
      return { content: [text(cameraDescription() + note)], details: {} };
    },
  },
  {
    name: "face_follow",
    label: "Face follow",
    description: "Turn automatic face following on or off. While on, the gimbal keeps the largest face in view " +
      "framed by itself. Moving or centering the camera with the other tools turns it off.",
    parameters: Type.Object({ on: Type.Boolean() }),
    async execute(_id, params: any) {
      setFollow(params.on);
      return { content: [text(`Face following is ${opt.follow ? "on" : "off"}.`)], details: {} };
    },
  },
  {
    name: "recording",
    label: "Recording",
    description: "Start or stop recording a video.",
    parameters: Type.Object({ action: Type.Union([Type.Literal("start"), Type.Literal("stop")]) }),
    async execute(_id, params: any, signal) {
      pv.record(params.action);
      await sleep(800, signal);
      return { content: [text(pv.state.recording ? "Recording." : "Not recording.")], details: {} };
    },
  },
  {
    name: "snapshot",
    label: "Snapshot",
    description: "Save a full-resolution photo of the current view to the user's recordings folder.",
    parameters: Type.Object({}),
    async execute() {
      pv.snapshot();
      return { content: [text("Snapshot saved.")], details: {} };
    },
  },
];

const SYSTEM_PROMPT = `You are the voice assistant inside pocket-viewer, an app that shows a DJI Osmo Pocket 3 gimbal camera.
The user talks to you through the camera's microphone. Their words come from speech recognition and may contain recognition errors: read them charitably. Your replies are shown as subtitles and read aloud.

- Reply in the user's language. Speak naturally and briefly: usually one to three sentences. No markdown, lists, emoji or code unless asked.
- You can see through the camera. Whenever the answer depends on what is in view, call look; never guess what the camera sees. Use recent_keyframes for questions about what happened earlier.
- You can turn the camera (move_camera, center_camera), zoom, record and take snapshots, and turn on face_follow to keep the user framed automatically (e.g. "跟着我"). To find something out of view, turn toward it and look again. The field of view is about 95° × 53° at zoom 100.
- After looking, say what you saw: that is usually why the user asked you to look.
- If a task takes several steps, say in a few words what you are doing first.`;

// --- the pi session --------------------------------------------------------

const key = openAIKey();
if (!key) {
  pv.log("no OpenAI key: put it in $OPENAI_API_KEY, ./.openai-key or ~/.config/pocket-viewer/openai-key");
  pv.hud("🤖 ai-agent: no OpenAI key", "status", "#ff6666");
  await new Promise(() => {});
}
process.env.OPENAI_API_KEY = key;

// A private, empty pi directory: none of the user's pi settings, sessions,
// extensions or skills apply, and nothing is written.
const piDir = path.join(os.tmpdir(), "pocket-viewer-ai-agent");
mkdirSync(piDir, { recursive: true, mode: 0o700 });
const modelRuntime = await ModelRuntime.create({ authPath: path.join(piDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
const model = modelRuntime.getModel("openai", opt.model);
if (!model) {
  pv.log(`unknown model openai/${opt.model}`);
  process.exit(1);
}

const resourceLoader = new DefaultResourceLoader({
  cwd: piDir,
  agentDir: piDir,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  systemPrompt: SYSTEM_PROMPT,
  appendSystemPrompt: [],
  extensionFactories: [
    (pi) => {
      // Camera frames are large: keep only the two most recent tool results'
      // images in context, so a long conversation doesn't resend every frame.
      pi.on("context", (event) => {
        let withImages = 0;
        const messages = [...event.messages].reverse().map((m: any) => {
          if (m.role !== "toolResult" || !m.content?.some((c: any) => c.type === "image")) return m;
          if (++withImages <= 2) return m;
          return { ...m, content: m.content.map((c: any) => c.type === "image" ? text("[earlier camera frame omitted]") : c) };
        });
        return { messages: messages.reverse() };
      });
    },
  ],
});
await resourceLoader.reload();

const { session } = await createAgentSession({
  cwd: piDir, agentDir: piDir, model, thinkingLevel: opt.thinking as any, modelRuntime, resourceLoader,
  noTools: "builtin", customTools: tools,
  sessionManager: SessionManager.inMemory(piDir),
  settingsManager: SettingsManager.inMemory({}),
});

// --- display ---------------------------------------------------------------

function status(t: string, color = "#ffffff") { pv.hud("🤖 " + t, "status", color); }
const wakeWord = () => (opt.listen === "push" || opt.listen === "always" ? "" : opt.listen);
function idleStatus() {
  if (opt.listen === "push") status(`hold Space to talk · ${opt.model}`, "#00ff88");
  else if (wakeWord() && !engaged()) status(`say “${wakeWord()}”`, "#bbbbbb");
  else status(`listening · ${opt.model}`, "#00ff88");
}
function showYou(t: string, ttl = 4) { pv.draw("you", t ? [{ shape: "subtitle", text: "🗣 " + t, size: 20, color: "#dddddd" }] : [], ttl); }
function showReply(t: string, ttl = 0) { pv.draw("reply", t ? [{ shape: "subtitle", text: t, size: 24 }] : [], ttl); }

// --- speech out --------------------------------------------------------------

const ttsQueue: string[] = [];
let sayProcess: ChildProcess | undefined;
let mutedUntil = 0;  // the mic is ignored while speaking, so the agent doesn't hear itself

function speak(sentence: string) {
  const s = sentence.replace(/[*#`_>]/g, "").trim();
  if (!opt.speak || !s) return;
  ttsQueue.push(s);
  if (!sayProcess) speakNext();
}

function speakNext() {
  const s = ttsQueue.shift();
  if (!s) {
    sayProcess = undefined;
    mutedUntil = Date.now() + 500;
    return;
  }
  const voice = /[㐀-鿿]/.test(s) ? ["-v", "Tingting"] : [];
  sayProcess = spawn("say", [...voice, s], { stdio: "ignore" });
  sayProcess.on("exit", speakNext);
}

function stopSpeaking() {
  ttsQueue.length = 0;
  sayProcess?.removeAllListeners("exit");
  sayProcess?.kill();
  sayProcess = undefined;
  mutedUntil = Date.now() + 300;
}

const listening = () => !sayProcess && Date.now() > mutedUntil;

/** Cuts streamed text into sentences for speech. */
let spoken = "";   // text of the current assistant message not yet spoken
function speakComplete(final: boolean) {
  const re = /^[\s\S]*?[。！？!?；;…]|^[\s\S]*?[.](?=\s)/;
  let m: RegExpMatchArray | null;
  while ((m = spoken.match(re))) {
    speak(m[0]);
    spoken = spoken.slice(m[0].length);
  }
  if (final) { speak(spoken); spoken = ""; }
}

// --- agent events ------------------------------------------------------------

let reply = "";
session.subscribe((e: any) => {
  switch (e.type) {
    case "agent_start":
      status("thinking…", "#ffcc00");
      break;
    case "message_start":
      if (e.message?.role === "assistant") { reply = ""; spoken = ""; }
      break;
    case "message_update":
      if (e.assistantMessageEvent?.type === "text_delta") {
        reply += e.assistantMessageEvent.delta;
        spoken += e.assistantMessageEvent.delta;
        showReply(reply);
        speakComplete(false);
      }
      break;
    case "message_end":
      if (e.message?.role === "assistant") {
        speakComplete(true);
        if (reply.trim()) pv.log("🤖 " + reply.trim());
        const err = e.message.errorMessage;
        if (err && e.message.stopReason !== "aborted") { pv.log("error: " + err); showReply("⚠ " + err, 6); }
      }
      break;
    case "tool_execution_start":
      pv.log(`tool ${e.toolName} ${JSON.stringify(e.args ?? {})}`);
      break;
    case "agent_settled":
      engagedUntil = Date.now() + FOLLOW_UP;
      showReply(reply.trim(), Math.min(20, 6 + reply.length * 0.12));
      idleStatus();
      break;
  }
});

// --- speech in ---------------------------------------------------------------

const FOLLOW_UP = 30e3;  // after a reply, no wake word is needed for this long (ms)
let engagedUntil = 0;
const engaged = () => Date.now() < engagedUntil;
const STOP = /^(停|停下|停止|别说了|闭嘴|安静|stop|cancel|be quiet)[。.!！]?$/i;

async function interrupt() {
  stopSpeaking();
  if (session.isStreaming) await session.abort();
  showReply("");
  idleStatus();
}

/** What the user said: from a push-to-talk press, or a phrase in the other modes. */
function heard(phrase: string, pushed = false) {
  let t = phrase.trim();
  if (!t) return;
  const wake = wakeWord();
  if (!pushed && wake && !engaged()) {
    const i = t.toLowerCase().indexOf(wake.toLowerCase());
    if (i < 0) return;
    t = t.slice(i + wake.length).replace(/^[\s,，。.、!！]+/, "");
    engagedUntil = Date.now() + FOLLOW_UP;
    if (!t) { status("listening…", "#00ff88"); return; }
  }
  if (STOP.test(t)) { pv.log("stopped by voice"); void interrupt(); return; }
  pv.log("🗣 " + t);
  showYou(t, 6);
  engagedUntil = Date.now() + FOLLOW_UP;
  if (session.isStreaming) {
    // Said while the agent works: it sees this after its current step.
    void session.steer(t).catch((err: Error) => pv.log("steer failed: " + err.message));
  } else {
    session.prompt(t).catch((err: Error) => {
      pv.log("prompt failed: " + err.message);
      showReply("⚠ " + err.message, 6);
      idleStatus();
    });
  }
}

/** Runs plugins/bin/transcribe; audio goes to its stdin, results come back per line. */
function transcribe(pause: number, onPartial: (t: string) => void, onPhrase: (t: string) => void): ChildProcess {
  const bin = path.join(REPO, "plugins/bin/transcribe");
  const proc = spawn(bin, ["--lang", opt.lang, "--pause", String(pause)], { stdio: ["pipe", "pipe", "inherit"] });
  proc.on("error", (err) => pv.log(`cannot start ${bin} (run make plugins): ${err.message}`));
  proc.stdin!.on("error", () => {});
  createInterface({ input: proc.stdout! }).on("line", (line) => {
    let m: any;
    try { m = JSON.parse(line); } catch { return; }
    if (m.log && !String(m.log).startsWith("listening")) pv.log("transcribe: " + m.log);
    if (typeof m.partial === "string") onPartial(m.partial);
    if (typeof m.phrase === "string") onPhrase(m.phrase);
  });
  return proc;
}

// "always" / wake word: one long-running recognizer, cut into phrases at pauses.
let continuous: ChildProcess | undefined;
function startListening() {
  continuous?.kill();
  continuous = undefined;
  if (opt.listen === "push") return;
  continuous = transcribe(opt.pause,
    (t) => { if (listening() && t && (!wakeWord() || engaged() || t.includes(wakeWord()))) showYou(t); },
    (t) => { if (listening()) heard(t); });
}

// Push-to-talk: a fresh recognizer per press. Everything said while Space is
// held is one message, however long the pauses; after release it gets a moment
// to finish the last words.
interface Press { proc: ChildProcess; phrases: string[]; partial: string; changed: number; holding: boolean; }
let press: Press | undefined;

function pushDown() {
  if (press?.holding) return;
  press?.proc.kill();
  stopSpeaking();  // talking over the agent interrupts its speech
  const p: Press = { proc: undefined as any, phrases: [], partial: "", changed: Date.now(), holding: true };
  p.proc = transcribe(60,
    (t) => { p.partial = t; p.changed = Date.now(); showYou([...p.phrases, t].join(" ")); },
    (t) => { p.phrases.push(t); p.partial = ""; p.changed = Date.now(); });
  press = p;
  status("🎙 recording… release Space to send", "#ff6666");
  setTimeout(() => { if (press === p && p.holding) pushUp(); }, 120e3);  // missed key-up (focus lost)
}

async function pushUp() {
  const p = press;
  if (!p?.holding) return;
  p.holding = false;
  status("🎙 …", "#ff6666");
  // Keep feeding audio briefly, then wait until the transcript stops changing.
  const released = Date.now();
  await sleep(500);
  while (Date.now() - released < 2500 && Date.now() - p.changed < 400) await sleep(100);
  if (press !== p) return;  // pressed again meanwhile
  press = undefined;
  p.proc.kill();
  const t = [...p.phrases, p.partial].join(" ").trim();
  if (t) heard(t, true);
  else { showYou("(nothing heard)", 2); idleStatus(); }
}

pv.onAudio = (chunk) => {
  if (press) {
    if (press.proc.stdin?.writable) press.proc.stdin.write(chunk.data);
  } else if (continuous?.stdin?.writable) {
    // Silence instead of the mic while speaking, so the agent doesn't hear itself.
    continuous.stdin.write(listening() ? chunk.data : Buffer.alloc(chunk.data.length));
  }
};
pv.onInput = (e: Message) => {
  if (e.event === "cancel" && (session.isStreaming || sayProcess)) void interrupt();
  if (e.event === "key" && e.key === "space" && opt.listen === "push") {
    if (e.state === "down") pushDown(); else void pushUp();
  }
};

// --- settings ----------------------------------------------------------------

function declareOptions() {
  pv.setOptions([
    { key: "model", title: "Model", type: "choice", value: opt.model,
      choices: [["gpt-5.4-mini", "gpt-5.4-mini (fast)"], ["gpt-5.4", "gpt-5.4"], ["gpt-5.5", "gpt-5.5 (best)"]] },
    { key: "thinking", title: "Thinking", type: "choice", value: opt.thinking,
      choices: [["off", "Off (fastest)"], ["low", "Low"], ["medium", "Medium"]] },
    { key: "lang", title: "Spoken language", type: "choice", value: opt.lang,
      choices: [["zh-CN", "中文（普通话）"], ["en-US", "English"]] },
    { key: "listen", title: "Listen", type: "choice", value: opt.listen,
      choices: [["push", "While Space is held"], ["always", "Always"], ["助手", "After “助手”"], ["assistant", "After “assistant”"]] },
    { key: "pause", title: "Phrase ends after (always / wake word)", type: "choice", value: opt.pause,
      choices: [[1.2, "1.2 s pause"], [1.8, "1.8 s pause"], [2.5, "2.5 s pause"], [3.5, "3.5 s pause"]] },
    { key: "follow", title: "Keep my face framed (face-follow)", type: "bool", value: opt.follow },
    { key: "speak", title: "Read replies aloud", type: "bool", value: opt.speak },
  ]);
}

pv.onSet = async (k, v) => {
  if (k === "model" && typeof v === "string" && v !== opt.model) {
    const m = modelRuntime.getModel("openai", v);
    if (!m) return;
    if (session.isStreaming) await session.abort();
    await session.setModel(m);
    opt.model = v;
  } else if (k === "thinking" && typeof v === "string") {
    session.setThinkingLevel(v as any);
    opt.thinking = v;
  } else if (k === "lang" && typeof v === "string" && v !== opt.lang) {
    opt.lang = v;
    startListening();
  } else if (k === "pause" && typeof v === "number" && v !== opt.pause) {
    opt.pause = v;
    startListening();
  } else if (k === "listen" && typeof v === "string" && v !== opt.listen) {
    opt.listen = v;
    startListening();
  } else if (k === "follow" && typeof v === "boolean") {
    setFollow(v);
    return;
  } else if (k === "speak" && typeof v === "boolean") {
    opt.speak = v;
    if (!v) stopSpeaking();
  } else {
    return;
  }
  pv.log(`${k} → ${JSON.stringify(v)}`);
  declareOptions();
  if (!session.isStreaming) idleStatus();
};

declareOptions();
startListening();
if (opt.follow) { opt.follow = false; setFollow(true); }
pv.subscribe({ video: { maxWidth: 640, fps: 4, format: "bgra" }, audio: { rate: 16000, channels: 1 }, state: true, input: true });
idleStatus();
pv.log(`ai-agent ready: openai/${opt.model}, ${opt.lang}, listen: ${opt.listen}`);

process.on("exit", () => { continuous?.kill(); press?.proc.kill(); sayProcess?.kill(); follower?.kill(); });
for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => process.exit(0));
