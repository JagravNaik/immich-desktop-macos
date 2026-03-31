#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit

/// A transparent view that catches all pressure (force touch) events 
/// on the current window and forwards them to the provided callback.
struct ForceTouchOverlay: NSViewRepresentable {
  let onPressureChange: (Int, Double) -> Void

  func makeNSView(context: Context) -> ForceTouchNSView {
    let view = ForceTouchNSView()
    view.onPressureChange = onPressureChange
    return view
  }

  func updateNSView(_ nsView: ForceTouchNSView, context: Context) {
    nsView.onPressureChange = onPressureChange
  }
}

private final class ForceTouchEventMonitor {
  private var monitor: Any?

  deinit {
    remove()
  }

  func replace(with monitor: Any?) {
    remove()
    self.monitor = monitor
  }

  func remove() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }
}

final class ForceTouchNSView: NSView {
  var onPressureChange: ((Int, Double) -> Void)?
  private let eventMonitor = ForceTouchEventMonitor()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    eventMonitor.remove()

    if window != nil {
      let monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { [weak self] event in
        guard let self = self else { return event }
        self.onPressureChange?(event.stage, Double(event.pressure))
        return event
      }
      eventMonitor.replace(with: monitor)
    }
  }
}
#endif
#endif
