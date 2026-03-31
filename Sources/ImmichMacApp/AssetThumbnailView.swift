#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ImmichMedia

#if canImport(AppKit)
import AppKit
import ImageIO

@MainActor
final class ThumbnailStore: ObservableObject {
  private let cache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>()
    c.countLimit = 2000
    c.totalCostLimit = 512 * 1024 * 1024 // 512 MB
    return c
  }()
  private let localThumbnailLoader = ThumbnailLoader()
  private var inFlightLoads: [String: Task<NSImage?, Never>] = [:]

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
    let cacheKey = cacheKey(for: item, context: context, size: size)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }

    if let task = inFlightLoads[cacheKey] {
      return await task.value
    }

    let task = Task<NSImage?, Never> { [item, context, size, localThumbnailLoader] in
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

    inFlightLoads[cacheKey] = task
    let image = await task.value
    inFlightLoads[cacheKey] = nil

    if let image {
      let cost = Int(image.size.width * image.size.height * 4)
      cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
    }

    return image
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

      return await decodeImage(from: data)
    } catch {
      return nil
    }
  }

  private static func loadFullResolutionImage(from fileURL: URL) async -> NSImage? {
    let result = await Task.detached(priority: .userInitiated) { () -> DecodedImageResult in
      guard
        let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(
          source,
          0,
          [kCGImageSourceShouldCache: false] as CFDictionary
        )
      else {
        return DecodedImageResult(cgImage: nil)
      }

      return DecodedImageResult(cgImage: cgImage)
    }.value

    guard let cgImage = result.cgImage else { return nil }
    return await MainActor.run {
      NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
  }

  private static func decodeImage(from data: Data) async -> NSImage? {
    let result = await Task.detached(priority: .userInitiated) { () -> DecodedImageResult in
      guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(
          source,
          0,
          [kCGImageSourceShouldCache: false] as CFDictionary
        )
      else {
        return DecodedImageResult(cgImage: nil)
      }

      return DecodedImageResult(cgImage: cgImage)
    }.value

    guard let cgImage = result.cgImage else { return nil }
    return await MainActor.run {
      NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
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
        } else {
          Image(systemName: item.isVideo ? "video" : "photo")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
    .task(id: thumbnailTaskID) {
      image = await store.loadImage(for: item, context: context)
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
