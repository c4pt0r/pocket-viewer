// Client for pocket-viewer plugins in Node (22.18+ runs this TypeScript as is).
//
//   import { PocketViewer } from "../pocketviewer.ts";
//   const pv = await PocketViewer.connect("hello");
//   pv.onVideo = (frame) => pv.draw("box", [{ shape: "rect", x: 0.4, y: 0.4, w: 0.2, h: 0.2 }], 1);
//   pv.subscribe({ video: { maxWidth: 320, fps: 5 } });
//
// See PROTOCOL.md for the wire format.

import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface VideoFrame {
  pts: number;      // host-clock seconds
  width: number;
  height: number;
  format: string;   // "bgra" (rows top to bottom, 4 bytes per pixel) or "jpeg"
  data: Buffer;
}

export interface AudioChunk {
  pts: number;
  rate: number;
  channels: number;
  frames: number;
  data: Buffer;     // signed 16-bit little-endian, interleaved
}

export type Message = Record<string, any>;

export function defaultSocketPath(): string {
  if (process.env.POCKET_VIEWER_SOCKET) return process.env.POCKET_VIEWER_SOCKET;
  // On Windows pocket-viewer listens on a localhost port and writes it here.
  if (process.platform === "win32") {
    try {
      return fs.readFileSync(path.join(os.tmpdir(), "pocket-viewer.port"), "utf8").trim();
    } catch {}
  }
  return path.join(os.tmpdir(), "pocket-viewer.sock");
}

export class PocketViewer {
  onHello?: (hello: Message) => void;
  onVideo?: (frame: VideoFrame) => void;
  onAudio?: (chunk: AudioChunk) => void;
  onState?: (state: Message) => void;
  /** The user changed a setting declared with setOptions. */
  onSet?: (key: string, value: unknown) => void;
  /** {event: "click", x, y} / {event: "select", x, y, w, h} / {event: "cancel"}. */
  onInput?: (event: Message) => void;
  onClose?: () => void;
  state: Message = {};

  private sock: net.Socket;
  private inbox: Buffer = Buffer.alloc(0);

  private constructor(sock: net.Socket, name: string) {
    this.sock = sock;
    sock.on("data", (d) => this.receive(d));
    sock.on("close", () => this.onClose?.());
    sock.on("error", () => {});
    this.send({ type: "hello", name, token: process.env.POCKET_VIEWER_TOKEN ?? "" });
  }

  static connect(name: string, socketPath = defaultSocketPath()): Promise<PocketViewer> {
    return new Promise((resolve, reject) => {
      // "tcp:HOST:PORT" (Windows) or a Unix socket path.
      const tcp = socketPath.match(/^tcp:(.+):(\d+)$/);
      const sock = tcp ? net.createConnection(Number(tcp[2]), tcp[1]) : net.createConnection(socketPath);
      sock.once("connect", () => resolve(new PocketViewer(sock, name)));
      sock.once("error", (e) => reject(new Error(`cannot connect to ${socketPath} — is pocket-viewer running? (${e.message})`)));
    });
  }

  // --- sending -------------------------------------------------------------

  send(header: Message, payload?: Buffer): void {
    const h = payload?.length ? { ...header, size: payload.length } : header;
    const json = Buffer.from(JSON.stringify(h));
    const len = Buffer.alloc(4);
    len.writeUInt32BE(json.length);
    this.sock.write(payload?.length ? Buffer.concat([len, json, payload]) : Buffer.concat([len, json]));
  }

  /** video: {maxWidth, fps, format: "bgra"|"jpeg", quality}; audio: {rate, channels}. */
  subscribe(opts: { video?: Message | null; audio?: Message | null; state?: boolean; input?: boolean }): void {
    this.send({ type: "subscribe", video: opts.video ?? null, audio: opts.audio ?? null,
                state: !!opts.state, input: !!opts.input });
  }

  /** Replaces this plugin's `layer`; it disappears after `ttl` seconds (0 = keep). */
  draw(layer: string, items: Message[], ttl = 0): void { this.send({ type: "draw", layer, items, ttl }); }
  clear(layer?: string): void { this.send(layer ? { type: "clear", layer } : { type: "clear" }); }
  /** One HUD segment per key; "" removes it, ttl > 0 expires it. */
  hud(text: string, key = "default", color?: string, ttl = 0): void {
    this.send({ type: "hud", key, text, ttl, ...(color ? { color } : {}) });
  }
  gimbal(m: { pan?: number; tilt?: number; dpan?: number; dtilt?: number }): void { this.send({ type: "gimbal", ...m }); }
  zoom(zoom: number): void { this.send({ type: "zoom", zoom }); }
  center(): void { this.send({ type: "center" }); }
  /** "start", "stop" or "toggle". */
  record(action: string): void { this.send({ type: "record", action }); }
  snapshot(): void { this.send({ type: "snapshot" }); }
  /** Settings for the Plugins menu; see "options" in PROTOCOL.md. */
  setOptions(items: Message[]): void { this.send({ type: "options", items }); }
  log(text: string): void { this.send({ type: "log", text: String(text) }); }

  // --- receiving -----------------------------------------------------------

  private receive(data: Buffer): void {
    this.inbox = this.inbox.length ? Buffer.concat([this.inbox, data]) : data;
    for (;;) {
      if (this.inbox.length < 4) return;
      const hlen = this.inbox.readUInt32BE(0);
      if (this.inbox.length < 4 + hlen) return;
      const h = JSON.parse(this.inbox.subarray(4, 4 + hlen).toString("utf8"));
      const size = h.size ?? 0;
      if (this.inbox.length < 4 + hlen + size) return;
      const payload = this.inbox.subarray(4 + hlen, 4 + hlen + size);
      this.inbox = this.inbox.subarray(4 + hlen + size);
      this.dispatch(h, Buffer.from(payload));
    }
  }

  private dispatch(h: Message, payload: Buffer): void {
    switch (h.type) {
      case "hello": this.state = h; this.onHello?.(h); break;
      case "state": this.state = h; this.onState?.(h); break;
      case "set": this.onSet?.(h.key, h.value); break;
      case "input": this.onInput?.(h); break;
      case "video": this.onVideo?.({ pts: h.pts, width: h.width, height: h.height, format: h.format, data: payload }); break;
      case "audio": this.onAudio?.({ pts: h.pts, rate: h.rate, channels: h.channels, frames: h.frames, data: payload }); break;
    }
  }
}
