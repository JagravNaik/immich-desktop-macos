#if canImport(AppKit) && canImport(PhotosUI)
import AppKit
import Foundation
import Photos
import PhotosUI

/// Builds `PHLivePhoto` objects from an Immich still + motion pair so the viewer can use Apple's
/// own `PHLivePhotoView`, the player Photos uses (`IPXViewerMediaController._livePhotoView`).
@MainActor
final class LivePhotoStore: ObservableObject {
  enum State: Equatable {
    case loading
    case ready(PHLivePhoto)
    /// The pair couldn't be combined (e.g. missing or mismatched content identifiers);
    /// the viewer falls back to playing the motion video directly.
    case unavailable
  }

  @Published private(set) var states: [String: State] = [:]

  typealias Downloader = @Sendable (String) async throws -> (Data, String)

  private var tasks: [String: Task<Void, Never>] = [:]
  private let directory: URL = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appending(path: "ImmichLivePhotos", directoryHint: .isDirectory)
  }()

  func state(for itemID: String) -> State? {
    states[itemID]
  }

  /// Starts loading the pair once per item. `download` returns an original's bytes and filename.
  func load(itemID: String, stillAssetID: String, videoAssetID: String, placeholder: NSImage?, download: @escaping Downloader) {
    guard states[itemID] == nil, tasks[itemID] == nil else { return }
    states[itemID] = .loading
    let directory = directory
    tasks[itemID] = Task { [weak self] in
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        async let still = Self.cachedFile(assetID: stillAssetID, directory: directory, download: download)
        async let video = Self.cachedFile(assetID: videoAssetID, directory: directory, download: download)
        let urls = try await [still, video]
        let livePhoto = await Self.makeLivePhoto(urls: urls, placeholder: placeholder)
        self?.finish(itemID: itemID, state: livePhoto.map(State.ready) ?? .unavailable)
      } catch {
        self?.finish(itemID: itemID, state: .unavailable)
      }
    }
  }

  private func finish(itemID: String, state: State) {
    states[itemID] = state
    tasks[itemID] = nil
  }

  private nonisolated static func cachedFile(assetID: String, directory: URL, download: Downloader) async throws -> URL {
    let fileManager = FileManager.default
    if let existing = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .first(where: { $0.deletingPathExtension().lastPathComponent == assetID }) {
      return existing
    }
    let (data, filename) = try await download(assetID)
    let ext = (filename as NSString).pathExtension.isEmpty ? "dat" : (filename as NSString).pathExtension
    let url = directory.appending(path: "\(assetID).\(ext.lowercased())")
    try data.write(to: url, options: .atomic)
    return url
  }

  private nonisolated static func makeLivePhoto(urls: [URL], placeholder: NSImage?) async -> PHLivePhoto? {
    await withCheckedContinuation { continuation in
      var resumed = false
      PHLivePhoto.request(
        withResourceFileURLs: urls,
        placeholderImage: placeholder,
        targetSize: .zero,
        contentMode: .aspectFit
      ) { livePhoto, info in
        // The handler can fire twice: a degraded result, then the final one.
        let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
        let failed = info[PHLivePhotoInfoErrorKey] != nil || (info[PHLivePhotoInfoCancelledKey] as? Bool) == true
        guard !resumed, failed || !isDegraded || livePhoto == nil else { return }
        resumed = true
        continuation.resume(returning: failed ? nil : livePhoto)
      }
    }
  }
}
#endif
