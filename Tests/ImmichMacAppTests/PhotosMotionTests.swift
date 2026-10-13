import CoreGraphics
import XCTest
@testable import ImmichMacApp

final class PhotosMotionTests: XCTestCase {
  func testSpringMatchesPhotosFormulaAndSettles() {
    let spring = PhotosSpring.elasticPan
    // x(t) = (x0 + v0·A·t)·e^(−k t / T)
    let t = 0.1
    let expected = (20.0 + 50 * 0.31 * t) * exp(-20 * t / 0.5)
    XCTAssertEqual(spring.displacement(at: t, initialPosition: 20, initialVelocity: 50), expected, accuracy: 1e-9)
    XCTAssertEqual(spring.displacement(at: 0, initialPosition: 20, initialVelocity: 0), 20)
    XCTAssertLessThan(abs(spring.displacement(at: 1, initialPosition: 200, initialVelocity: 0)), 0.01)
    // The scroll spring (period 1.6) settles more slowly than the pan spring (period 0.5).
    XCTAssertGreaterThan(
      PhotosSpring.elasticScroll.settleTime(initialPosition: 40, initialVelocity: 0),
      PhotosSpring.elasticPan.settleTime(initialPosition: 40, initialVelocity: 0)
    )
  }

  func testRubberBandResistsOverscrollAtOneTwentiethAndInverts() {
    XCTAssertEqual(PhotosRubberBand.resisted(50, lower: -100, upper: 100), 50)
    XCTAssertEqual(PhotosRubberBand.resisted(140, lower: -100, upper: 100), 102, accuracy: 1e-9)
    XCTAssertEqual(PhotosRubberBand.resisted(-160, lower: -100, upper: 100), -103, accuracy: 1e-9)
    let displayed = PhotosRubberBand.resisted(175, lower: -100, upper: 100)
    XCTAssertEqual(PhotosRubberBand.raw(fromResisted: displayed, lower: -100, upper: 100), 175, accuracy: 1e-9)
    XCTAssertEqual(PhotosRubberBand.overshoot(displayed, lower: -100, upper: 100), 3.75, accuracy: 1e-9)
  }

  func testMomentumStartsAtReleaseVelocityAndCapsDuration() {
    let velocity = CGVector(dx: 1200, dy: -300)
    let momentum = PhotosMomentum(velocity: velocity)
    XCTAssertGreaterThan(momentum.displacement.dx, 0)
    XCTAssertLessThan(momentum.displacement.dy, 0)
    // Quartic ease-out: initial slope 4D/T equals the release velocity (the D·K relation is exact).
    let initialSpeedX = 4 * momentum.displacement.dx / momentum.duration
    let speed = hypot(velocity.dx, velocity.dy)
    let displacement = hypot(momentum.displacement.dx, momentum.displacement.dy)
    XCTAssertEqual(4 * displacement / momentum.duration, speed, accuracy: speed * 0.05)
    XCTAssertGreaterThan(initialSpeedX, 0)
    XCTAssertEqual(momentum.progress(at: 0), 0)
    XCTAssertEqual(momentum.progress(at: momentum.duration), 1)
    XCTAssertLessThanOrEqual(PhotosMomentum(velocity: CGVector(dx: 1e7, dy: 0)).duration, PhotosMomentum.maximumDuration)
  }

  func testVelocityTrackerSmoothsAndIgnoresTooCloseSamples() {
    var tracker = PhotosVelocityTracker()
    tracker.add(delta: CGVector(dx: 0, dy: 0), timestamp: 0)
    tracker.add(delta: CGVector(dx: 10, dy: 0), timestamp: 0.01) // 1000 pt/s
    XCTAssertEqual(tracker.velocity.dx, 400, accuracy: 1e-6)
    tracker.add(delta: CGVector(dx: 99, dy: 0), timestamp: 0.011) // < 2 ms: ignored
    XCTAssertEqual(tracker.velocity.dx, 400, accuracy: 1e-6)
    tracker.add(delta: CGVector(dx: 10, dy: 0), timestamp: 0.021)
    XCTAssertEqual(tracker.velocity.dx, 0.4 * 1000 + 0.6 * 400, accuracy: 1e-6)
  }

  func testStandardTimingMatchesPhotos() {
    XCTAssertEqual(PhotosMotion.standardDuration, 0.25)
    XCTAssertEqual(PhotosMotion.badgeCollapseDelay, 3)
    XCTAssertEqual(PhotosMotion.minimumMomentumSpeed, 40)
  }
}
