// calibrate — pocket-viewer plugin for the StackChan: turns the head by known
// angles, measures how far the picture moves, and saves the camera's field of
// view to ~/.config/pocket-viewer/stackchan.json. pocket-viewer picks the file
// up at once and sends it to plugins as state.fov, so face-follow and tracker
// aim with the measured value instead of the built-in 41° × 31°.
//
//   calibrate [--pan 15] [--tilt 12] [--rounds 2] [--dry-run] [--shots DIR]
//
// Point the robot at a still, textured scene (a bookshelf, not a blank wall or
// a person) and keep out of the picture while it runs, about a minute. It
// starts from where the head is and returns there.
//
// Each step turns the head ±pan / ±tilt degrees from the start, waits until the
// servos are still, and averages a few frames. The shift between that picture
// and the one at the start (normalized cross-correlation, coarse to fine, sub-
// pixel) and the real angle turned, from the robot's own readback (state.head,
// not actualPan, which rounds to the target), give the focal length in pixels:
// shift = f·tan(angle). The FOV is 2·atan(size / 2f). It also reports how far
// short of their targets the servos stop. It saves nothing when the steps
// disagree by more than 15%: something in view moved. --shots DIR keeps each
// picture as a PNG, to see what it measured.

import CoreGraphics
import Foundation
import ImageIO

struct Options {
  var pan = 15.0    // degrees each side; at ~41° wide that shifts ~1/3 of the frame
  var tilt = 12.0
  var rounds = 2
  var save = true
  var shots: String?  // directory for each step's picture

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--pan": pan = Double(it.next() ?? "") ?? pan
      case "--tilt": tilt = Double(it.next() ?? "") ?? tilt
      case "--rounds": rounds = max(1, Int(it.next() ?? "") ?? rounds)
      case "--dry-run": save = false
      case "--shots": shots = it.next()
      default:
        FileHandle.standardError.write("usage: calibrate [--pan deg] [--tilt deg] [--rounds n] [--dry-run] [--shots dir]\n".data(using: .utf8)!)
        exit(2)
      }
    }
  }
}

/// A grayscale picture, row 0 at the top.
struct Gray {
  let w: Int, h: Int
  var px: [Float]

  init(w: Int, h: Int, px: [Float]) { self.w = w; self.h = h; self.px = px }

  init(_ frame: VideoFrame) {
    w = frame.width
    h = frame.height
    px = [Float](repeating: 0, count: w * h)
    frame.data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
      for i in 0..<(w * h) {  // BGRA
        px[i] = 0.114 * Float(b[4 * i]) + 0.587 * Float(b[4 * i + 1]) + 0.299 * Float(b[4 * i + 2])
      }
    }
  }

  func writePNG(to path: String) {
    let bytes = px.map { UInt8(max(0, min(255, $0.rounded()))) }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
  }

  /// Half the size, each pixel the mean of a 2×2 block.
  func half() -> Gray {
    let hw = w / 2, hh = h / 2
    var out = [Float](repeating: 0, count: hw * hh)
    for y in 0..<hh {
      for x in 0..<hw {
        let i = 2 * y * w + 2 * x
        out[y * hw + x] = (px[i] + px[i + 1] + px[i + w] + px[i + w + 1]) / 4
      }
    }
    return Gray(w: hw, h: hh, px: out)
  }
}

/// Normalized cross-correlation of a(x, y) with b(x + dx, y + dy) over their
/// overlap; nil when the overlap is under 30% of the picture.
func ncc(_ a: Gray, _ b: Gray, _ dx: Int, _ dy: Int) -> Double? {
  let x0 = max(0, -dx), x1 = min(a.w, a.w - dx), y0 = max(0, -dy), y1 = min(a.h, a.h - dy)
  guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) * 10 >= a.w * a.h * 3 else { return nil }
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
  for y in y0..<y1 {
    var ra: Float = 0, rb: Float = 0, raa: Float = 0, rbb: Float = 0, rab: Float = 0
    let ia = y * a.w, ib = (y + dy) * b.w + dx
    for x in x0..<x1 {
      let p = a.px[ia + x], q = b.px[ib + x]
      ra += p; rb += q; raa += p * p; rbb += q * q; rab += p * q
    }
    sa += Double(ra); sb += Double(rb); saa += Double(raa); sbb += Double(rbb); sab += Double(rab)
  }
  let n = Double((x1 - x0) * (y1 - y0))
  let va = saa - sa * sa / n, vb = sbb - sb * sb / n
  guard va > 1e-6, vb > 1e-6 else { return nil }
  return (sab - sa * sb / n) / (va * vb).squareRoot()
}

/// Where the content of a has moved to in b, in pixels (+x right, +y down),
/// and how well they match (NCC, 1 = identical). Searches up to 45% of the
/// frame at 1/4 size, then refines at 1/2 and full size, with a parabola fit
/// for the sub-pixel peak.
func shift(from a: Gray, to b: Gray) -> (dx: Double, dy: Double, score: Double)? {
  let pyramid = [(a, b), (a.half(), b.half()), (a.half().half(), b.half().half())]
  var best = (dx: 0, dy: 0, score: -2.0)
  for level in stride(from: 2, through: 0, by: -1) {
    let (pa, pb) = pyramid[level]
    let candidates: [(Int, Int)]
    if level == 2 {
      let rx = Int(Double(pa.w) * 0.45), ry = Int(Double(pa.h) * 0.45)
      candidates = (-ry...ry).flatMap { dy in (-rx...rx).map { dx in (dx, dy) } }
    } else {
      candidates = (-2...2).flatMap { dy in (-2...2).map { dx in (best.dx * 2 + dx, best.dy * 2 + dy) } }
    }
    best = (0, 0, -2)
    for (dx, dy) in candidates {
      if let s = ncc(pa, pb, dx, dy), s > best.score { best = (dx, dy, s) }
    }
    guard best.score > -2 else { return nil }
  }
  // Fit a parabola through the peak and its neighbours on each axis.
  func vertex(_ m: Double?, _ c: Double, _ p: Double?) -> Double {
    guard let m, let p else { return 0 }
    let d = m - 2 * c + p
    return d < 0 ? max(-0.5, min(0.5, 0.5 * (m - p) / d)) : 0
  }
  let fx = vertex(ncc(a, b, best.dx - 1, best.dy), best.score, ncc(a, b, best.dx + 1, best.dy))
  let fy = vertex(ncc(a, b, best.dx, best.dy - 1), best.score, ncc(a, b, best.dx, best.dy + 1))
  return (Double(best.dx) + fx, Double(best.dy) + fy, best.score)
}

/// The latest head state and frames, filled by the plugin's receive loop and
/// read by the calibration thread.
final class Feed {
  struct Head { var yaw, pitch: Double; var moving: Bool }
  private let cond = NSCondition()
  private var head: Head?
  private var frame: VideoFrame?
  private var frameCount = 0
  var state: [String: Any] = [:]

  func update(state st: [String: Any]) {
    cond.lock()
    state = st
    if let h = st["head"] as? [String: Any], let yaw = h["yaw"] as? Double, let pitch = h["pitch"] as? Double {
      head = Head(yaw: yaw, pitch: pitch, moving: h["moving"] as? Bool ?? false)
    }
    cond.broadcast()
    cond.unlock()
  }

  func update(frame f: VideoFrame) {
    cond.lock()
    frame = f
    frameCount += 1
    cond.broadcast()
    cond.unlock()
  }

  /// The head, waiting up to `timeout` seconds for the first report.
  func currentHead(timeout: Double = 3) -> Head? {
    cond.lock()
    defer { cond.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while head == nil && cond.wait(until: deadline) {}
    return head
  }

  /// The `n` frames that arrive after `skip` more, or nil after `timeout` seconds.
  func frames(skip: Int, take n: Int, timeout: Double = 5) -> [VideoFrame]? {
    cond.lock()
    defer { cond.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    var seen = frameCount, arrived = 0, out: [VideoFrame] = []
    while out.count < n {
      while frameCount == seen { if !cond.wait(until: deadline) { return nil } }
      seen = frameCount
      arrived += 1
      if arrived > skip, let frame { out.append(frame) }
    }
    return out
  }
}

/// One still picture at a head position.
struct Shot {
  let pan, tilt: Double    // commanded
  let yaw, pitch: Double   // where the head really stopped
  let image: Gray
}

final class Calibration {
  let pv: PocketViewer
  let feed: Feed
  let opt: Options

  init(pv: PocketViewer, feed: Feed, opt: Options) { self.pv = pv; self.feed = feed; self.opt = opt }

  func status(_ text: String, color: String = "#ffcc00", ttl: Double = 0) {
    pv.hud("📐 " + text, key: "status", color: color, ttl: ttl)
    pv.log(text)
    print(text)
  }

  /// Turns the head to pan/tilt, waits until it has been still for 0.8 s, and
  /// averages three frames taken after that.
  func shoot(pan: Double, tilt: Double) -> Shot? {
    pv.gimbal(pan: pan, tilt: tilt)
    let start = ProcessInfo.processInfo.systemUptime
    var last = feed.currentHead(), stillSince: Double?
    while true {
      Thread.sleep(forTimeInterval: 0.1)
      let now = ProcessInfo.processInfo.systemUptime
      guard let h = feed.currentHead(), let l = last else { return nil }
      let still = !h.moving && abs(h.yaw - l.yaw) < 0.15 && abs(h.pitch - l.pitch) < 0.15
      stillSince = still ? (stillSince ?? now) : nil
      last = h
      if let s = stillSince, now - s >= 0.8, now - start >= 0.6 { break }
      if now - start > 8 { break }  // still jittering: measure anyway, the readback says where it is
    }
    // The robot encodes and sends frames a moment behind: skip what was in flight.
    guard let frames = feed.frames(skip: 3, take: 3), let head = feed.currentHead(),
          let first = frames.first, first.format == "bgra" else { return nil }
    var image = Gray(first)
    for f in frames.dropFirst() where f.width == first.width && f.height == first.height {
      let g = Gray(f)
      for i in image.px.indices { image.px[i] += g.px[i] }
    }
    let n = Float(frames.count)
    for i in image.px.indices { image.px[i] /= n }
    return Shot(pan: pan, tilt: tilt, yaw: head.yaw, pitch: head.pitch, image: image)
  }

  func run() -> Int32 {
    guard let start = feed.currentHead() else {
      status("no StackChan head state — calibrate works with pocket-viewer -d stackchan", color: "#ff5555", ttl: 15)
      return 1
    }
    let st = feed.state
    let panRange = st["panRange"] as? [Double] ?? [-128, 128], tiltRange = st["tiltRange"] as? [Double] ?? [5, 85]
    // Start where the user pointed the head, moved in so every step fits the range.
    let p0 = min(max(start.yaw.rounded(), panRange[0] + opt.pan), panRange[1] - opt.pan)
    let t0 = min(max(start.pitch.rounded(), tiltRange[0] + opt.tilt), tiltRange[1] - opt.tilt)

    status("calibrating: keep the scene still and stay out of view")
    Thread.sleep(forTimeInterval: 2)

    // Each round: centre, right, left, centre, up, down. Every off-centre shot
    // is compared with the centre shot just before it.
    let steps: [(dp: Double, dt: Double, axis: Character)] =
      [(0, 0, "c"), (opt.pan, 0, "p"), (-opt.pan, 0, "p"), (0, 0, "c"), (0, opt.tilt, "t"), (0, -opt.tilt, "t")]
    var fx: [Double] = [], fy: [Double] = [], panErr: [Double] = [], tiltErr: [Double] = []
    var reversed: [String] = [], rejected = 0
    var ref: Shot?
    var width = 0, height = 0
    let total = steps.count * opt.rounds
    for round in 0..<opt.rounds {
      for (i, step) in steps.enumerated() {
        let n = round * steps.count + i + 1
        let name = step.axis == "c" ? "centre" : step.axis == "p" ? String(format: "pan %+.0f°", step.dp)
                                                                 : String(format: "tilt %+.0f°", step.dt)
        status("calibrating \(n)/\(total): \(name)")
        guard let shot = shoot(pan: p0 + step.dp, tilt: t0 + step.dt) else {
          status("no frames from the camera", color: "#ff5555", ttl: 15)
          return 1
        }
        if let dir = opt.shots {
          try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
          let file = String(format: "%02d-%@.png", n, name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "°", with: ""))
          shot.image.writePNG(to: (dir as NSString).appendingPathComponent(file))
        }
        width = shot.image.w
        height = shot.image.h
        panErr.append(shot.yaw - shot.pan)
        tiltErr.append(shot.pitch - shot.tilt)
        if step.axis == "c" { ref = shot; continue }
        guard let r = ref, let m = shift(from: r.image, to: shot.image) else { rejected += 1; continue }
        let dyaw = shot.yaw - r.yaw, dpitch = shot.pitch - r.pitch
        let angle = step.axis == "p" ? dyaw : dpitch
        let along = step.axis == "p" ? m.dx : m.dy
        // +pan turns right, so the scene moves left (−x); +tilt turns up, so it moves down (+y).
        let expectedSign = step.axis == "p" ? -1.0 : 1.0
        let f = abs(along) / tan(abs(angle) * .pi / 180)
        let line = String(format: "%@: head moved %+.1f°, picture %+.1f, %+.1f px, match %.2f → f = %.0f px",
                          name, angle, m.dx, m.dy, m.score, f)
        pv.log(line)
        print(line)
        guard m.score > 0.5, abs(angle) > 4 else { rejected += 1; continue }
        if (along * angle).sign != expectedSign.sign { reversed.append(name) }
        if step.axis == "p" { fx.append(f) } else { fy.append(f) }
      }
    }
    pv.gimbal(pan: start.yaw, tilt: start.pitch)

    func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
    func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
    let stops = String(format: "servos stop off target by %+.1f° pan, %+.1f° tilt on average (worst %.1f°, %.1f°)",
                       mean(panErr), mean(tiltErr), panErr.map(abs).max() ?? 0, tiltErr.map(abs).max() ?? 0)
    pv.log(stops)
    print(stops)
    guard fx.count >= opt.rounds, fy.count >= opt.rounds else {
      status("failed: \(rejected) of \(2 * steps.count / 3 * opt.rounds) steps didn't match — point the robot at a still, textured scene",
             color: "#ff5555", ttl: 20)
      return 1
    }
    let fh = median(fx), fv = median(fy)
    let hfov = 2 * atan(Double(width) / 2 / fh) * 180 / .pi
    let vfov = 2 * atan(Double(height) / 2 / fv) * 180 / .pi
    let spread = max(((fx.max()! - fx.min()!) / fh), ((fy.max()! - fy.min()!) / fv))
    var summary = String(format: "FOV %.1f° × %.1f° (focal %.0f / %.0f px, spread %.0f%%)", hfov, vfov, fh, fv, spread * 100)
    if !reversed.isEmpty { summary += " — direction reversed on " + reversed.joined(separator: ", ") }
    let consistent = spread <= 0.15
    if !consistent { summary += " — steps disagree, something in view moved; not saved" }

    if opt.save && consistent {
      let path = NSHomeDirectory() + "/.config/pocket-viewer/stackchan.json"
      let json: [String: Any] = [
        "fov": [(hfov * 10).rounded() / 10, (vfov * 10).rounded() / 10],
        "focalPx": [fh.rounded(), fv.rounded()],
        "frame": [width, height],
        "servoStopError": [(mean(panErr) * 10).rounded() / 10, (mean(tiltErr) * 10).rounded() / 10],
        "date": ISO8601DateFormatter().string(from: Date()),
      ]
      do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        summary += ", saved"
        print("saved \(path)")
      } catch {
        status("could not save \(path): \(error.localizedDescription)", color: "#ff5555", ttl: 20)
        return 1
      }
    }
    status(summary, color: !consistent ? "#ff5555" : reversed.isEmpty ? "#66ff99" : "#ffcc00")
    Thread.sleep(forTimeInterval: 15)  // the HUD line goes when the plugin does
    return consistent ? 0 : 1
  }
}

@main
struct Calibrate {
  static func main() {
    let opt = Options(CommandLine.arguments)
    let pv: PocketViewer
    do {
      pv = try PocketViewer(name: "calibrate")
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    let feed = Feed()
    pv.onState = { feed.update(state: $0) }
    pv.onVideo = { feed.update(frame: $0) }
    pv.subscribe(video: ["maxWidth": 640, "fps": 15, "format": "bgra"], state: true)
    Thread {
      exit(Calibration(pv: pv, feed: feed, opt: opt).run())
    }.start()
    pv.run()
  }
}
