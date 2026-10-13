#if canImport(AppKit)
import AppKit
import QuartzCore

/// Runs a per-frame closure from the display's refresh, like `IPXSpringAnimation`'s
/// `CADisplayLink`. The closure receives seconds since `start` and returns false to stop.
@MainActor
final class PhotosFrameDriver: NSObject {
  private var displayLink: CADisplayLink?
  private var startTime: CFTimeInterval = 0
  private var onFrame: ((Double) -> Bool)?

  var isRunning: Bool { displayLink != nil }

  func start(on screen: NSScreen? = NSScreen.main, _ onFrame: @escaping (Double) -> Bool) {
    stop()
    self.onFrame = onFrame
    startTime = CACurrentMediaTime()
    guard let screen else {
      // No screen (tests, headless): finish immediately at the end state.
      _ = onFrame(.greatestFiniteMagnitude)
      return
    }
    let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    onFrame = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    let elapsed = CACurrentMediaTime() - startTime
    if onFrame?(elapsed) != true {
      stop()
    }
  }
}
#endif
