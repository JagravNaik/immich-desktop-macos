#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit

struct ForceTouchModifier: ViewModifier {
  let onForcePress: (Bool) -> Void

  func body(content: Content) -> some View {
    content
      .background(
        ForceTouchViewRepresentable(onForcePress: onForcePress)
      )
  }
}

extension View {
  func onForcePress(perform: @escaping (Bool) -> Void) -> some View {
    modifier(ForceTouchModifier(onForcePress: perform))
  }
}

private struct ForceTouchViewRepresentable: NSViewRepresentable {
  let onForcePress: (Bool) -> Void

  typealias NSViewType = ForceTouchNSView

  func makeNSView(context: Context) -> ForceTouchNSView {
    let view = ForceTouchNSView()
    view.onForcePress = onForcePress
    return view
  }

  func updateNSView(_ nsView: ForceTouchNSView, context: Context) {
    nsView.onForcePress = onForcePress
  }
}

private final class ForceTouchNSView: NSView {
  var onForcePress: ((Bool) -> Void)?
  private var gesture: NSPressGestureRecognizer!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    // Configure NSPressGestureRecognizer for Force Click
    gesture = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
    // allowedTouchTypes = [.indirectPointer] is Trackpad. By default it handles Force Click well.
    gesture.minimumPressDuration = 0.5 // Standard length? Wait, Force Touch responds to pressure, not strictly duration, but NSPressGestureRecognizer handles both depending on hardware support.
    
    // To specifically listen to deep press, we must rely on the gesture recognizer's intrinsic behavior on Force Touch capable trackpads.
    self.addGestureRecognizer(gesture)
  }

  @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
    switch recognizer.state {
    case .began:
      onForcePress?(true)
    case .ended, .cancelled, .failed:
      onForcePress?(false)
    default:
      break
    }
  }
}
#endif
#endif
