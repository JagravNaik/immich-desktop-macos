#if canImport(SwiftUI)
import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit

@MainActor
final class ThumbnailStore: ObservableObject {
  private let cache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>()
    c.countLimit = 2000
    c.totalCostLimit = 512 * 1024 * 1024 // 512 MB
    return c
  }()

  func loadImage(
    for item: AppState.PhotoItem,
    context: AppState.ThumbnailContext?,
    size: ThumbnailSize = .thumbnail
  ) async -> NSImage? {
    let cacheKey = cacheKey(for: item, context: context, size: size)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }

    let image: NSImage?
    switch item.source {
    case .localFile(let fileURL):
      image = NSImage(contentsOf: fileURL)
    case .remoteAsset(let assetID):
      guard let context else { return nil }

      let url: URL?
      if size == .original {
        url = Self.originalURL(baseURL: context.baseURL, assetID: assetID)
      } else {
        url = Self.thumbnailURL(baseURL: context.baseURL, assetID: assetID, size: size)
      }
      guard let url else { return nil }

      var request = URLRequest(url: url)
      request.addValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")

      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
          let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode)
        else {
          return nil
        }

        image = NSImage(data: data)
      } catch {
        return nil
      }
    }

    if let image {
      cache.setObject(image, forKey: cacheKey as NSString)
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
      return "local::\(fileURL.path)"
    case .remoteAsset(let assetID):
      return "remote::\(context?.baseURL.absoluteString ?? "")::\(assetID)::\(size.rawValue)"
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
