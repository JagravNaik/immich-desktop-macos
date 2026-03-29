#if canImport(SwiftUI)
import SwiftUI
import AVKit

@main
struct ImmichMacApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: .init())
        .frame(minWidth: 720, minHeight: 480)
    }
    .windowResizability(.contentMinSize)
  }
}
#else
import Foundation

@main
struct ImmichMacApp {
  static func main() {
    print("ImmichMacApp is only available when SwiftUI is supported (macOS).")
  }
}
#endif
