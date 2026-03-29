#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit
import ImmichAPI

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

final class ForceTouchNSView: NSView {
  var onPressureChange: ((Int, Double) -> Void)?
  private var monitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    immichLog("[Pressure] ForceTouchNSView moved to window: \(window != nil)")
    
    // Remove existing monitor if any
    if let monitor = self.monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    
    // Add a new monitor for the current window's lifecycle
    if window != nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { [weak self] event in
        guard let self = self else { return event }
        // Pass the stage and pressure to the callback
        self.onPressureChange?(event.stage, Double(event.pressure))
        return event
      }
    }
  }
}
#endif
#endif
