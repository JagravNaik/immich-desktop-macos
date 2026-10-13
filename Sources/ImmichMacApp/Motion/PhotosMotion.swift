import CoreGraphics
import Foundation

/// Motion constants and physics recovered from Photos 12 for macOS (static disassembly; see
/// docs/photos-reverse-engineering.md, "Part 4 — Motion, trackpad, and Live Photos").
///
/// Photos doesn't use CASpringAnimation for its viewer physics. It drives its own critically
/// damped spring (`IPXSpringAnimation`) from a display link, rubber-bands trackpad overscroll
/// (`IPXElasticScrollAnimator`), and coasts drags with a quartic ease-out
/// (`IPXElasticPanGestureAnimator`).
enum PhotosMotion {
  /// `+[IPXAnimationUtilities standardDuration]`: the `IPXAnimationStandardDuration` default (0.25 s)
  /// × `animationDragCoefficient` (1.0). Also the grid ⇄ viewer transition duration
  /// (`IPXAssetTransitionController` init) and `IPXAnimationEditDuration`.
  static let standardDuration: TimeInterval = 0.25

  /// `kCAMediaTimingFunctionEaseInEaseOut`, used by `+[IPXAnimationUtilities mediaTimingFunction]`
  /// and `-[IPXAssetTransitionController _timingFunction:]`.
  static let easeInEaseOut = (x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)

  /// `-[IPXBadgesOverlayController _showMouseOverBadges:]` collapses the LIVE badge after 3 s.
  static let badgeCollapseDelay: TimeInterval = 3

  /// `-[IPXElasticPanGestureAnimator processPanDelta:…]`: releases slower than this (pt/s) don't coast.
  static let minimumMomentumSpeed: Double = 40
}

// MARK: - Spring

/// Photos' critically damped spring (`-[IPXSpringAnimation updateFrame]`):
///
///     x(t) = (x₀ + v₀ · amplitude · t) · e^(−stiffness · t / period)
///
/// `x` is the remaining displacement from rest. The animation stops once `x` drops below 1e-6.
struct PhotosSpring: Equatable, Sendable {
  var amplitude: Double
  var period: Double
  var stiffness: Double

  /// `IPXSpringAnimation` stops when the displacement falls below this.
  static let restThreshold = 1e-6

  /// `-[IPXElasticScrollAnimator initWithTarget:view:]`: trackpad overscroll spring-back.
  static let elasticScroll = PhotosSpring(amplitude: 0.31, period: 1.6, stiffness: 20)
  /// The scroll spring's default initial velocity.
  static let elasticScrollInitialVelocity: Double = 100

  /// `-[IPXElasticPanGestureAnimator initWithDelegate:view:]`: drag-release spring-back (x and y).
  static let elasticPan = PhotosSpring(amplitude: 0.31, period: 0.5, stiffness: 20)

  func displacement(at time: Double, initialPosition: Double, initialVelocity: Double) -> Double {
    let t = max(time, 0)
    return (initialPosition + initialVelocity * amplitude * t) * exp(-stiffness * t / period)
  }

  /// Time until the displacement settles below `restThreshold` (or `limit`), for scheduling.
  func settleTime(initialPosition: Double, initialVelocity: Double, limit: Double = 3) -> Double {
    var t = 0.0
    while t < limit {
      if abs(displacement(at: t, initialPosition: initialPosition, initialVelocity: initialVelocity)) < 0.5 {
        return t
      }
      t += 1.0 / 120
    }
    return limit
  }
}

// MARK: - Rubber band

/// `IPXElasticScrollAnimator` / `IPXElasticPanGestureAnimator` overscroll resistance: past an edge,
/// content moves `1 / stiffness` (= 1/20) as far as the finger. Photos applies it to trackpad
/// scrolls only; mouse-wheel scrolling clamps hard.
enum PhotosRubberBand {
  static let resistance: Double = 1 / PhotosSpring.elasticScroll.stiffness

  static func resisted(_ raw: Double, lower: Double, upper: Double) -> Double {
    if raw < lower { return lower - (lower - raw) * resistance }
    if raw > upper { return upper + (raw - upper) * resistance }
    return raw
  }

  /// Inverts `resisted` so a displayed offset can be continued from a raw one.
  static func raw(fromResisted value: Double, lower: Double, upper: Double) -> Double {
    if value < lower { return lower - (lower - value) / resistance }
    if value > upper { return upper + (value - upper) / resistance }
    return value
  }

  static func overshoot(_ value: Double, lower: Double, upper: Double) -> Double {
    if value < lower { return value - lower }
    if value > upper { return value - upper }
    return 0
  }
}

// MARK: - Momentum

/// `-[IPXElasticPanGestureAnimator _startMomentum]`: a quartic ease-out coast.
///
///     K = 1000 × viewToContentRatio
///     D = sign(v) · K · (|v| / 4K)^(4/3)        (per axis)
///     T = min((|D| / K)^(1/4), 2 s)
///     offset(t) = D · (1 − (1 − t/T)⁴)
///
/// The initial slope 4D/T equals the release velocity, so the coast picks up exactly where the
/// finger left off.
struct PhotosMomentum: Equatable, Sendable {
  let displacement: CGVector
  let duration: Double

  static let maximumDuration: Double = 2

  init(velocity: CGVector, viewToContentRatio: Double = 1) {
    let k = viewToContentRatio > 0 ? 1000 * viewToContentRatio : 1000
    func distance(_ v: Double) -> Double {
      guard v != 0 else { return 0 }
      return (v < 0 ? -1 : 1) * k * pow(abs(v) / (4 * k), 4.0 / 3.0)
    }
    let dx = distance(velocity.dx)
    let dy = distance(velocity.dy)
    displacement = CGVector(dx: dx, dy: dy)
    duration = min(pow(hypot(dx, dy) / k, 0.25), Self.maximumDuration)
  }

  /// Fraction of the total displacement covered at `time`.
  func progress(at time: Double) -> Double {
    guard duration > 0 else { return 1 }
    let remaining = 1 - min(max(time / duration, 0), 1)
    return 1 - pow(remaining, 4)
  }

  func offset(at time: Double) -> CGVector {
    let p = progress(at: time)
    return CGVector(dx: displacement.dx * p, dy: displacement.dy * p)
  }
}

// MARK: - Velocity

/// `IPXElasticScrollAnimator` velocity smoothing: v = 0.4 · instantaneous + 0.6 · previous,
/// ignoring samples closer than 2 ms apart (`_sampleVelocityForTotalDelta:`).
struct PhotosVelocityTracker: Sendable {
  private(set) var velocity = CGVector.zero
  private var lastTimestamp: TimeInterval?

  static let minimumInterval: TimeInterval = 0.002

  mutating func reset() {
    velocity = .zero
    lastTimestamp = nil
  }

  mutating func add(delta: CGVector, timestamp: TimeInterval) {
    defer { lastTimestamp = timestamp }
    guard let lastTimestamp else { return }
    let interval = timestamp - lastTimestamp
    guard interval >= Self.minimumInterval else { return }
    let instantaneous = CGVector(dx: delta.dx / interval, dy: delta.dy / interval)
    velocity = CGVector(
      dx: 0.4 * instantaneous.dx + 0.6 * velocity.dx,
      dy: 0.4 * instantaneous.dy + 0.6 * velocity.dy
    )
  }
}
