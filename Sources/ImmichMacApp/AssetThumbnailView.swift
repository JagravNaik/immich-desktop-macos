#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ImmichMedia

#if canImport(AppKit)
import AppKit
import ImageIO

@MainActor
final class ThumbnailStore: ObservableObject {
  private final class InFlightRegistry: @unchecked Sendable {
    private struct InFlightLoad {
      let task: Task<NSImage?, Never>
      var waiterIDs: Set<UUID>
    }

    private let lock = NSLock()
    private var loads: [String: InFlightLoad] = [:]

    func existingTask(cacheKey: String, waiterID: UUID) -> Task<NSImage?, Never>? {
      lock.lock()
      defer { lock.unlock() }

      guard var load = loads[cacheKey] else {
        return nil
      }

      load.waiterIDs.insert(waiterID)
      loads[cacheKey] = load
      return load.task
    }

    func insert(task: Task<NSImage?, Never>, cacheKey: String, waiterID: UUID) {
      lock.lock()
      loads[cacheKey] = InFlightLoad(task: task, waiterIDs: [waiterID])
      lock.unlock()
    }

    func clear(cacheKey: String) {
      lock.lock()
      loads[cacheKey] = nil
      lock.unlock()
    }

    func releaseWaiter(cacheKey: String, waiterID: UUID, cancelTask: Bool) {
      lock.lock()
      defer { lock.unlock() }

      guard var load = loads[cacheKey] else {
        return
      }

      load.waiterIDs.remove(waiterID)
      if cancelTask && load.waiterIDs.isEmpty {
        load.task.cancel()
        loads[cacheKey] = nil
        return
      }

      loads[cacheKey] = load
    }
  }

  private let cache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>()
    c.countLimit = 2000
    c.totalCostLimit = 512 * 1024 * 1024 // 512 MB
    return c
  }()
  private let localThumbnailLoader = ThumbnailLoader()
  private let inFlightRegistry = InFlightRegistry()

  private struct DecodedImageResult: @unchecked Sendable {
    let cgImage: CGImage?
  }

  /// Synchronous cache-only lookup — returns nil if not cached, never triggers a network fetch.
  func cachedImage(
    for item: AppState.PhotoItem,
    context: AppState.ThumbnailContext?,
    size: ThumbnailSize = .thumbnail
  ) -> NSImage? {
    let key = cacheKey(for: item, context: context, size: size)
    return cache.object(forKey: key as NSString)
  }

  func loadImage(
    for item: AppState.PhotoItem,
    context: AppState.ThumbnailContext?,
    size: ThumbnailSize = .thumbnail
  ) async -> NSImage? {
    guard !Task.isCancelled else { return nil }

    let cacheKey = cacheKey(for: item, context: context, size: size)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }

    let waiterID = UUID()
    let task = inFlightRegistry.existingTask(cacheKey: cacheKey, waiterID: waiterID) ?? {
      let task = Task<NSImage?, Never> { [item, context, size, localThumbnailLoader] in
        guard !Task.isCancelled else { return nil }

        switch item.source {
        case .localFile(let fileURL):
          if size == .original {
            return await Self.loadFullResolutionImage(from: fileURL)
          }
          return await localThumbnailLoader.loadThumbnail(
            for: fileURL,
            maxPixelSize: size.maxPixelSize
          )
        case .remoteAsset(let assetID):
          guard let context else { return nil }
          return await Self.loadRemoteImage(
            assetID: assetID,
            context: context,
            size: size
          )
        }
      }

      inFlightRegistry.insert(task: task, cacheKey: cacheKey, waiterID: waiterID)
      return task
    }()

    return await withTaskCancellationHandler(
      operation: {
        let image = await task.value
        guard !Task.isCancelled else {
          inFlightRegistry.releaseWaiter(cacheKey: cacheKey, waiterID: waiterID, cancelTask: true)
          return nil
        }

        inFlightRegistry.clear(cacheKey: cacheKey)

        if let image {
          let cost = cacheCost(for: image)
          cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
        }

        return image
      },
      onCancel: {
        inFlightRegistry.releaseWaiter(cacheKey: cacheKey, waiterID: waiterID, cancelTask: true)
      }
    )
  }

  func loadPersonImage(
    personID: String,
    context: AppState.ThumbnailContext
  ) async -> NSImage? {
    guard !Task.isCancelled else { return nil }

    let cacheKey = "person::\(context.baseURL.absoluteString)::\(personID)"
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }

    let waiterID = UUID()
    let task = inFlightRegistry.existingTask(cacheKey: cacheKey, waiterID: waiterID) ?? {
      let task = Task<NSImage?, Never> { [context] in
        await Self.loadPersonRemoteImage(personID: personID, context: context)
      }

      inFlightRegistry.insert(task: task, cacheKey: cacheKey, waiterID: waiterID)
      return task
    }()

    return await withTaskCancellationHandler(
      operation: {
        let image = await task.value
        guard !Task.isCancelled else {
          inFlightRegistry.releaseWaiter(cacheKey: cacheKey, waiterID: waiterID, cancelTask: true)
          return nil
        }

        inFlightRegistry.clear(cacheKey: cacheKey)

        if let image {
          let cost = cacheCost(for: image)
          cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
        }

        return image
      },
      onCancel: {
        inFlightRegistry.releaseWaiter(cacheKey: cacheKey, waiterID: waiterID, cancelTask: true)
      }
    )
  }

  private func cacheKey(
    for item: AppState.PhotoItem,
    context: AppState.ThumbnailContext?,
    size: ThumbnailSize = .thumbnail
  ) -> String {
    switch item.source {
    case .localFile(let fileURL):
      return "local::\(fileURL.path)::\(size.rawValue)"
    case .remoteAsset(let assetID):
      return "remote::\(context?.baseURL.absoluteString ?? "")::\(assetID)::\(size.rawValue)"
    }
  }

  private func cacheCost(for image: NSImage) -> Int {
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      return max(cgImage.width * cgImage.height * 4, 1)
    }

    if let bitmapRep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
      return max(bitmapRep.pixelsWide * bitmapRep.pixelsHigh * 4, 1)
    }

    return max(Int(image.size.width * image.size.height * 4), 1)
  }

  private static func loadRemoteImage(
    assetID: String,
    context: AppState.ThumbnailContext,
    size: ThumbnailSize
  ) async -> NSImage? {
    let url: URL?
    if size == .original {
      url = originalURL(baseURL: context.baseURL, assetID: assetID)
    } else {
      url = thumbnailURL(baseURL: context.baseURL, assetID: assetID, size: size)
    }
    guard let url else { return nil }

    var request = URLRequest(url: url)
    context.apply(to: &request)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard
        let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      else {
        return nil
      }

      return await decodeImage(from: data, size: size)
    } catch {
      return nil
    }
  }

  private static func loadPersonRemoteImage(
    personID: String,
    context: AppState.ThumbnailContext
  ) async -> NSImage? {
    let url = context.baseURL.appending(path: "people").appending(path: personID).appending(path: "thumbnail")

    var request = URLRequest(url: url)
    context.apply(to: &request)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard
        let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      else {
        return nil
      }

      return await decodeImage(from: data, size: .thumbnail)
    } catch {
      return nil
    }
  }

  private static func loadFullResolutionImage(from fileURL: URL) async -> NSImage? {
    let result = await Task.detached(priority: .userInitiated) { () -> DecodedImageResult in
      guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
        return DecodedImageResult(cgImage: nil)
      }

      return makeDecodedImageResult(from: source, maxPixelSize: maxPixelSize(for: source, size: .original))
    }.value

    guard let cgImage = result.cgImage else { return nil }
    return await MainActor.run {
      NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
  }

  private static func decodeImage(from data: Data, size: ThumbnailSize) async -> NSImage? {
    let result = await Task.detached(priority: .userInitiated) { () -> DecodedImageResult in
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return DecodedImageResult(cgImage: nil)
      }

      return makeDecodedImageResult(from: source, maxPixelSize: maxPixelSize(for: source, size: size))
    }.value

    guard let cgImage = result.cgImage else { return nil }
    return await MainActor.run {
      NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
  }

  private nonisolated static func makeDecodedImageResult(from source: CGImageSource, maxPixelSize: Int) -> DecodedImageResult {
    let options: CFDictionary = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      return DecodedImageResult(cgImage: nil)
    }

    return DecodedImageResult(cgImage: cgImage)
  }

  private nonisolated static func maxPixelSize(for source: CGImageSource, size: ThumbnailSize) -> Int {
    if size != .original {
      return Int(ceil(Double(size.maxPixelSize)))
    }

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return Int(ceil(Double(size.maxPixelSize)))
    }

    let largestDimension = max(pixelWidth.intValue, pixelHeight.intValue)
    let maxAllowedSize = Int(ceil(Double(size.maxPixelSize)))
    return min(largestDimension, maxAllowedSize)
  }

  private static func thumbnailURL(baseURL: URL, assetID: String, size: ThumbnailSize = .thumbnail) -> URL? {
    var components = URLComponents(
      url: baseURL
        .appending(path: "assets")
        .appending(path: assetID)
        .appending(path: "thumbnail"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
    return components?.url
  }

  private static func originalURL(baseURL: URL, assetID: String) -> URL? {
    var components = URLComponents(
      url: baseURL
        .appending(path: "assets")
        .appending(path: assetID)
        .appending(path: "original"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = []
    return components?.url
  }

  enum ThumbnailSize: String {
    case thumbnail = "thumbnail"
    case preview = "preview"
    case original = "original"

    var maxPixelSize: ThumbnailPixelSize {
      switch self {
      case .thumbnail:
        return 512
      case .preview:
        return 2048
      case .original:
        return 4096
      }
    }
  }
}

struct AssetThumbnailView: View {
  let item: AppState.PhotoItem
  let context: AppState.ThumbnailContext?
  let store: ThumbnailStore

  @State private var image: NSImage?
  @State private var imageOpacity: Double = 0

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Rectangle()
          .fill(.quaternary)

        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .opacity(imageOpacity)
        } else {
          Image(systemName: item.isVideo ? "video" : "photo")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
    .task(id: thumbnailTaskID) {
      let cached = store.cachedImage(for: item, context: context)
      if cached == nil {
        image = nil
        imageOpacity = 0
      }
      let loaded = await store.loadImage(for: item, context: context)
      image = loaded
      if cached != nil || loaded == nil {
        imageOpacity = 1
      } else {
        withAnimation(.easeIn(duration: 0.2)) {
          imageOpacity = 1
        }
      }
    }
  }

  private var thumbnailTaskID: String {
    switch item.source {
    case .localFile(let fileURL):
      return "local::\(fileURL.path)"
    case .remoteAsset(let assetID):
      return "remote::\(assetID)::\(context?.baseURL.absoluteString ?? "")"
    }
  }
}
#endif
#endif
