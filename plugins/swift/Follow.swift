// Closed-loop gimbal following, shared by face-follow and tracker.

import CoreGraphics
import CoreVideo
import Foundation

// Field of view at zoom 100, measured on a Pocket 3 in landscape: a 10° pan
// moved the picture 37/320 of its width at zoom 110 → ~95° wide. Assumes the
// 16:9 formats; not verified in portrait.
let wideFOV = 95.0
let narrowFOV = wideFOV * 9 / 16

/// Turns the gimbal so a point in the picture moves to a target point.
///
/// It moves only once the gimbal has reached its last target and held still:
/// a frame taken mid-move shows an error that is already being corrected, and
/// acting on it again overshoots and oscillates.
final class Follower {
  var gain = 0.8       // fraction of the error corrected per move
  var deadzone = 0.06  // normalized distance from the target that counts as framed
  var settle = 0.4     // seconds the gimbal must hold still before the next move (> state period)
  var maxStep = 20.0   // degrees per move
  var log: ((String) -> Void)?  // set to log every move
  private var settledSince: Double?

  /// Forget the settle timer, e.g. after the target or a setting changed.
  func reset() { settledSince = nil }

  /// `point` and `target` are normalized, origin top-left. Call once per frame.
  func update(point: CGPoint, target: CGPoint, frame: VideoFrame, pv: PocketViewer) {
    let st = pv.state
    guard let pan = st["pan"] as? Double, let tilt = st["tilt"] as? Double,
          let actualPan = st["actualPan"] as? Double, let actualTilt = st["actualTilt"] as? Double else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard abs(pan - actualPan) < 1, abs(tilt - actualTilt) < 1 else {
      settledSince = nil
      return
    }
    if settledSince == nil { settledSince = now }
    guard now - settledSince! >= settle else { return }

    let ex = point.x - target.x, ey = point.y - target.y
    guard abs(ex) > deadzone || abs(ey) > deadzone else { return }
    // Normalized error → degrees, for the current zoom and orientation. A
    // camera other than the Pocket 3 (StackChan) reports its own "fov".
    let zoom = max(1, (st["zoom"] as? Double ?? 100) / 100)
    let landscape = frame.width >= frame.height
    let fov = st["fov"] as? [Double] ?? [wideFOV, narrowFOV]
    let (wide, narrow) = fov.count == 2 ? (fov[0], fov[1]) : (wideFOV, narrowFOV)
    let hfov = (landscape ? wide : narrow) / zoom
    let vfov = (landscape ? narrow : wide) / zoom
    // +pan turns right, +tilt turns up (both measured). Absolute targets from
    // the real position, so nothing accumulates if a move falls short.
    let dpan = abs(ex) > deadzone ? max(-maxStep, min(maxStep, ex * hfov * gain)) : 0
    let dtilt = abs(ey) > deadzone ? max(-maxStep, min(maxStep, -ey * vfov * gain)) : 0
    pv.gimbal(pan: actualPan + dpan, tilt: actualTilt + dtilt)
    log?(String(format: "at (%.2f, %.2f) err (%+.2f, %+.2f) → pan %.1f%+.1f tilt %.1f%+.1f (zoom %.0f%%)",
                point.x, point.y, ex, ey, actualPan, dpan, actualTilt, dtilt, zoom * 100))
    settledSince = nil
  }
}

/// Wraps BGRA frame bytes in a CVPixelBuffer for Vision, without copying.
func withPixelBuffer<T>(_ frame: VideoFrame, _ body: (CVPixelBuffer) -> T?) -> T? {
  var data = frame.data
  return data.withUnsafeMutableBytes { raw -> T? in
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreateWithBytes(nil, frame.width, frame.height, kCVPixelFormatType_32BGRA, raw.baseAddress!,
                                       frame.width * 4, nil, nil, nil, &pb) == kCVReturnSuccess, let pb else { return nil }
    return body(pb)
  }
}
