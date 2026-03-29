#if canImport(SwiftUI)
import SwiftUI
import AVKit

@main
struct ImmichMacApp: App {
  var body: some Scene {
    WindowGroup {
      MainContentView(appState: .init())
        .frame(minWidth: 900, minHeight: 600)
    }
    .windowResizability(.contentMinSize)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
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
