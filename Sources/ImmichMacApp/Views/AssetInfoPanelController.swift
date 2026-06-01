#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

@MainActor
final class AssetInfoPanelController: NSObject, ObservableObject, NSWindowDelegate {
  private var panel: NSPanel?
  private weak var appState: AppState?

  func present(appState: AppState, item: AppState.PhotoItem) {
    self.appState = appState

    let hostingController = NSHostingController(
      rootView: AssetInfoInspector(appState: appState, item: item)
    )

    let panel = self.panel ?? makePanel(contentViewController: hostingController)
    panel.contentViewController = hostingController
    sizePanelToFitContent(panel, hostingView: hostingController.view)
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    panel?.close()
  }

  func windowWillClose(_ notification: Notification) {
    appState?.showInfoPopover = false
  }

  private func makePanel(contentViewController: NSViewController) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = "Info"
    panel.contentViewController = contentViewController
    panel.delegate = self
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    panel.setFrameAutosaveName("ImmichAssetInfoPanel")
    self.panel = panel
    return panel
  }

  private func sizePanelToFitContent(_ panel: NSPanel, hostingView: NSView) {
    hostingView.layoutSubtreeIfNeeded()

    var fittingSize = hostingView.fittingSize

    if fittingSize.width <= 0 || fittingSize.height <= 0 {
      fittingSize = NSSize(width: 420, height: 540)
    }

    let screenVisibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    let maxHeight = max((screenVisibleFrame?.height ?? 900) - 120, 420)
    let targetSize = NSSize(
      width: 420,
      height: min(max(fittingSize.height, 420), maxHeight)
    )

    panel.contentMinSize = NSSize(width: 420, height: 360)
    panel.setContentSize(targetSize)
  }
}
#endif
