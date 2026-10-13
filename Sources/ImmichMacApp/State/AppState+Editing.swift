#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Foundation
import ImmichAPI
import ImmichCore

/// Loading and saving state for the Photos-style editor.
enum EditingSessionState: Equatable {
  case idle
  case loading
  case ready
  case saving
  case failed(String)
}

/// How Done should persist the current edit, decided by what changed.
enum EditSaveStrategy: Equatable {
  /// Nothing changed since the session loaded.
  case nothing
  /// Only crop/rotate/flip changed: saved as Immich non-destructive edits (revertible).
  case immichEdits([AssetEditAction])
  /// Pixel adjustments (or a straighten angle) changed. Immich cannot store these on the
  /// original, so the rendered result is uploaded as a new photo.
  case newPhoto
}

/// Photos' editor session on top of Immich: loads the unedited original with saved
/// crop/rotate/mirror edits and saves edits back as non-destructively as Immich allows.
@MainActor
extension AppState {
  /// Starts editing the selected item. Uses the unedited original so saved server edits are not
  /// applied twice, then restores those edits as editable geometry.
  func beginEditingSession(pipeline: PhotoEditingPipeline, fallbackImage: NSImage?) async {
    guard let item = selectedItem, !item.isVideo else { return }
    editingSessionState = .loading

    switch item.source {
    case .localFile(let fileURL):
      guard let image = NSImage(contentsOf: fileURL) ?? fallbackImage else {
        editingSessionState = .failed("The photo could not be opened.")
        return
      }
      pipeline.beginSession(original: image, adjustments: .identity)
      editingSessionState = .ready

    case .remoteAsset(let assetID):
      guard let connectedServer, let currentSession else {
        editingSessionState = .failed("Not connected to server.")
        return
      }
      do {
        async let original = apiClient.downloadOriginalAsset(server: connectedServer, session: currentSession, assetId: assetID)
        async let edits = apiClient.fetchAssetEdits(server: connectedServer, session: currentSession, assetId: assetID)
        let (data, _) = try await original
        let savedEdits = (try? await edits) ?? []
        guard selectedItem?.id == item.id else { return }
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
          editingSessionState = .failed("This photo format can’t be edited.")
          return
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        var adjustments = PhotoAdjustments()
        adjustments.geometry = PhotoEditGeometry.geometry(from: savedEdits, sourceSize: size)
        pipeline.beginSession(original: image, adjustments: adjustments)
        editingSessionState = .ready
      } catch {
        immichLog("[Edit] Failed to load original: \(error)")
        editingSessionState = .failed(error.localizedDescription)
      }
    }
  }

  func endEditingSession(pipeline: PhotoEditingPipeline) {
    pipeline.endSession()
    editingSessionState = .idle
    isEditing = false
  }

  static func saveStrategy(for pipeline: PhotoEditingPipeline) -> EditSaveStrategy {
    saveStrategy(adjustments: pipeline.adjustments, baseline: pipeline.baseline, sourceSize: pipeline.sourceSize)
  }

  static func saveStrategy(adjustments: PhotoAdjustments, baseline: PhotoAdjustments, sourceSize: CGSize) -> EditSaveStrategy {
    guard adjustments != baseline else { return .nothing }
    if adjustments.hasPixelAdjustments {
      return .newPhoto
    }
    guard let edits = PhotoEditGeometry(sourceSize: sourceSize, geometry: adjustments.geometry).immichEdits() else {
      return .newPhoto
    }
    return .immichEdits(edits)
  }

  /// Saves crop/rotate/flip to Immich as non-destructive edits. Returns false when the current
  /// edit needs `saveEditedCopy` instead.
  @discardableResult
  func saveGeometryEdits(pipeline: PhotoEditingPipeline, thumbnailStore: ThumbnailStore) async throws -> Bool {
    guard let item = selectedItem, case .remoteAsset(let assetID) = item.source else { return false }
    let strategy = Self.saveStrategy(for: pipeline)
    guard case .immichEdits(let edits) = strategy else { return strategy == .nothing }
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    editingSessionState = .saving
    defer { if editingSessionState == .saving { editingSessionState = .ready } }
    try await apiClient.replaceAssetEdits(server: connectedServer, session: currentSession, assetId: assetID, edits: edits)
    pipeline.markSaved()
    thumbnailStore.invalidate(assetID: assetID, context: thumbnailContext)
    return true
  }

  /// Renders the edit at full resolution and uploads it as a new photo dated like the original.
  func saveEditedCopy(pipeline: PhotoEditingPipeline) async throws {
    guard let item = selectedItem else { return }
    editingSessionState = .saving
    defer { if editingSessionState == .saving { editingSessionState = .ready } }
    guard let data = await pipeline.renderFinalJPEG() else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "The edited photo could not be rendered.")
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "ImmichEdits", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let baseName = item.title.isEmpty ? "Photo" : (item.title as NSString).deletingPathExtension
    let fileURL = directory.appending(path: "\(baseName) (Edited) \(UUID().uuidString.prefix(4)).jpg")
    try data.write(to: fileURL)
    // The import queue dates uploads from file metadata; keep the original capture date.
    try FileManager.default.setAttributes([.creationDate: item.date, .modificationDate: item.date], ofItemAtPath: fileURL.path)
    importFiles([fileURL])
    pipeline.markSaved()
  }

  /// Photos' Image ▸ Rotate (⌘R / ⌥⌘R) and Flip outside the editor: updates each asset's
  /// non-destructive Immich edits directly, carrying any saved crop along.
  func applyQuickGeometry(
    to itemIDs: [String],
    thumbnailStore: ThumbnailStore,
    transform: (PhotoAdjustments.Geometry) -> PhotoAdjustments.Geometry
  ) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    for itemID in itemIDs {
      guard let item = photoItem(withID: itemID), !item.isVideo, case .remoteAsset(let assetID) = item.source else { continue }
      let saved = try await apiClient.fetchAssetEdits(server: connectedServer, session: currentSession, assetId: assetID)
      var size = CGSize(width: 1000, height: 1000)
      if saved.contains(where: { if case .crop = $0 { return true } else { return false } }) {
        let detail = try await apiClient.fetchAssetDetail(server: connectedServer, session: currentSession, assetId: assetID)
        if let width = detail.width, let height = detail.height, width > 0, height > 0 {
          size = CGSize(width: width, height: height)
        }
      }
      let geometry = transform(PhotoEditGeometry.geometry(from: saved, sourceSize: size))
      let edits = PhotoEditGeometry(sourceSize: size, geometry: geometry).immichEdits() ?? []
      try await apiClient.replaceAssetEdits(server: connectedServer, session: currentSession, assetId: assetID, edits: edits)
      thumbnailStore.invalidate(assetID: assetID, context: thumbnailContext)
    }
  }

  /// Downloads an asset's original bytes, for building Live Photos from the still + motion pair.
  func originalDownloader() -> LivePhotoStore.Downloader? {
    guard let connectedServer, let currentSession else { return nil }
    let apiClient = apiClient
    return { assetID in
      try await apiClient.downloadOriginalAsset(server: connectedServer, session: currentSession, assetId: assetID)
    }
  }

  /// Photos' Revert to Original for a saved photo: removes Immich's crop/rotate/mirror edits.
  func revertSavedEdits(itemID: String, thumbnailStore: ThumbnailStore) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    try await apiClient.deleteAssetEdits(server: connectedServer, session: currentSession, assetId: itemID)
    thumbnailStore.invalidate(assetID: itemID, context: thumbnailContext)
  }
}
#endif
