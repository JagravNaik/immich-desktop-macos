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
    .commands {
      SidebarCommands()
      ViewMenuCommands()
      ImageMenuCommands()
    }
  }
}

/// Keys for Photos' View ▸ Metadata badge toggles, shared by the menu and grid cells.
enum GridMetadataPreference {
  static let favoriteKey = "grid.metadata.favorite"
  static let locationKey = "grid.metadata.location"
  static let ratingKey = "grid.metadata.rating"
}

/// Photos' View ▸ Metadata submenu (badges drawn on grid thumbnails).
private struct ViewMenuCommands: Commands {
  @AppStorage(GridMetadataPreference.favoriteKey) private var showsFavorite = true
  @AppStorage(GridMetadataPreference.locationKey) private var showsLocation = false
  @AppStorage(GridMetadataPreference.ratingKey) private var showsRating = false

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Menu("Metadata") {
        Toggle("Favorite", isOn: $showsFavorite)
        Toggle("Location", isOn: $showsLocation)
        Toggle("Star Rating", isOn: $showsRating)
      }
      Divider()
    }
  }
}

/// Photos' Image menu (MainMenu.nib selectors noted inline). Hide Location and Revert to Original
/// Location are omitted: Immich v3 cannot clear or restore coordinates.
private struct ImageMenuCommands: Commands {
  @FocusedObject private var appState: AppState?
  @FocusedObject private var pipeline: PhotoEditingPipeline?
  @FocusedObject private var thumbnailStore: ThumbnailStore?

  private var isEditing: Bool { appState?.isEditing == true && pipeline?.isSourceLoaded == true }

  var body: some Commands {
    CommandMenu("Image") {
      let targets = appState?.commandTargetItemIDs ?? []

      // a_toggleEdit: (Return opens the editor, as in Photos)
      Button(appState?.isEditing == true ? "Hide Edit Tools" : "Show Edit Tools") {
        guard let appState else { return }
        if !appState.isEditing, appState.selectedItem?.isVideo == false, appState.isViewingPhoto {
          appState.isEditing = true
        }
      }
      .disabled(appState?.isViewingPhoto != true || appState?.isEditing == true)

      Divider()

      // a_rotateLeft: ⌘R, a_rotateRight: ⌥⌘R, a_flipHorizontal:, a_flipVertical:
      Button("Rotate Left") { geometryCommand(targets) { $0.rotated(by: -1) } editing: { $0.rotateLeft() } }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(targets.isEmpty)
      Button("Rotate Right") { geometryCommand(targets) { $0.rotated(by: 1) } editing: { $0.rotateRight() } }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(targets.isEmpty)
      Button("Flip Horizontal") {
        geometryCommand(targets) { var g = $0; g.flipHorizontal.toggle(); return g } editing: { $0.flip(horizontal: true) }
      }
      .disabled(targets.isEmpty)
      Button("Flip Vertical") {
        geometryCommand(targets) { var g = $0; g.flipVertical.toggle(); return g } editing: { $0.flip(horizontal: false) }
      }
      .disabled(targets.isEmpty)

      // a_autoEnhance: ⌘E (editor only: Immich cannot store tonal adjustments on the original)
      Button("Auto Enhance") { pipeline?.autoEnhance() }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!isEditing)

      Divider()

      // a_copyAdjustments: / a_pasteAdjustments: / a_revertToOriginal:
      Button("Copy Edits") { pipeline?.copyEdits() }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(!isEditing)
      Button("Paste Edits") { pipeline?.pasteEdits() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!isEditing || pipeline?.copiedAdjustments == nil)
      Button("Revert to Original") {
        if isEditing {
          pipeline?.revertToOriginal()
        } else if let appState, let thumbnailStore {
          Task {
            for id in targets {
              try? await appState.revertSavedEdits(itemID: id, thumbnailStore: thumbnailStore)
            }
          }
        }
      }
      .disabled(targets.isEmpty)

      Divider()

      // a_adjustDateTime:
      Button(targets.count > 1 ? "Adjust Date and Time of \(targets.count) Items…" : "Adjust Date and Time…") {
        appState?.presentAdjustDateTime(for: targets)
      }
      .disabled(targets.isEmpty)

      Menu("Location") {
        // a_copyLocation:
        Button("Copy Location") {
          appState?.copyLocation(from: targets)
        }
        .disabled(targets.isEmpty)

        Button("Paste Location") {
          guard let appState else { return }
          Task { try? await appState.pasteLocation(to: targets) }
        }
        .disabled(targets.isEmpty || appState?.copiedLocation == nil)

        Divider()

        // a_assignLocation:
        Button(appState?.assignLocationMenuTitle(for: targets) ?? "Assign Location…") {
          appState?.presentAssignLocation(for: targets)
        }
        .disabled(targets.isEmpty)
      }

      Divider()

      // a_setStarRating: (⌥0–⌥5), a_incrementStarRating: (⌥]), a_decrementStarRating: (⌥[)
      Menu("Set Rating") {
        Button("Remove Rating") { rate(nil, targets) }
          .keyboardShortcut("0", modifiers: .option)
        ForEach(1...5, id: \.self) { stars in
          Button(String(repeating: "★", count: stars)) { rate(stars, targets) }
            .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .option)
        }
        Divider()
        Button("Increment Star Rating") { adjustRating(1, targets) }
          .keyboardShortcut("]", modifiers: .option)
        Button("Decrement Star Rating") { adjustRating(-1, targets) }
          .keyboardShortcut("[", modifiers: .option)
      }
      .disabled(targets.isEmpty)

      Divider()

      // a_hidePhoto: (⌘L)
      Button(hideTitle(targets)) {
        guard let appState else { return }
        let hides = appState.hideCommandHides(targets)
        Task { try? await appState.setHidden(hides, for: targets) }
      }
      .keyboardShortcut("l", modifiers: .command)
      .disabled(targets.isEmpty)
    }
  }

  /// Applies a geometry change to the open editor, or saves it to Immich for the selection.
  private func geometryCommand(
    _ targets: [String],
    grid: @escaping (PhotoAdjustments.Geometry) -> PhotoAdjustments.Geometry,
    editing: (PhotoEditingPipeline) -> Void
  ) {
    if isEditing, let pipeline {
      editing(pipeline)
      return
    }
    guard let appState, let thumbnailStore else { return }
    Task { try? await appState.applyQuickGeometry(to: targets, thumbnailStore: thumbnailStore, transform: grid) }
  }

  private func hideTitle(_ targets: [String]) -> String {
    let hides = appState?.hideCommandHides(targets) ?? true
    let noun = targets.count == 1 ? "Photo" : "\(targets.count) Photos"
    return hides ? "Hide \(noun)" : "Show \(noun)"
  }

  private func rate(_ stars: Int?, _ targets: [String]) {
    guard let appState else { return }
    Task { try? await appState.setRating(stars, for: targets) }
  }

  private func adjustRating(_ delta: Int, _ targets: [String]) {
    guard let appState else { return }
    Task { try? await appState.adjustRating(by: delta, for: targets) }
  }
}
#else
import Foundation

@main
struct ImmichMacApp {
  static func main() {}
}
#endif
