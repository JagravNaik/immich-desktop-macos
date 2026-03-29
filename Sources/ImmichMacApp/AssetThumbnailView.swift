#if canImport(SwiftUI)
import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit

@MainActor
final class ThumbnailStore: ObservableObject {
  private let cache = NSCache<NSString, NSImage>()

  func loadImage(
    for item: ContentViewModel.PhotoItem,
    context: ContentViewModel.ThumbnailContext?
  ) async -> NSImage? {
    let cacheKey = cacheKey(for: item, context: context)
    if let cached = cache.object(forKey: cacheKey as NSString) {
      return cached
    }

    let image: NSImage?
    switch item.source {
    case .localFile(let fileURL):
      image = NSImage(contentsOf: fileURL)
    case .remoteAsset(let assetID):
      guard let context, let url = Self.thumbnailURL(baseURL: context.baseURL, assetID: assetID) else {
        return nil
      }

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
    for item: ContentViewModel.PhotoItem,
    context: ContentViewModel.ThumbnailContext?
  ) -> String {
    switch item.source {
    case .localFile(let fileURL):
      return "local::\(fileURL.path)"
    case .remoteAsset(let assetID):
      return "remote::\(context?.baseURL.absoluteString ?? "")::\(assetID)"
    }
  }

  private static func thumbnailURL(baseURL: URL, assetID: String) -> URL? {
    var components = URLComponents(
      url: baseURL
        .appending(path: "assets")
        .appending(path: assetID)
        .appending(path: "thumbnail"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "size", value: "preview")]
    return components?.url
  }
}

struct AssetThumbnailView: View {
  let item: ContentViewModel.PhotoItem
  let context: ContentViewModel.ThumbnailContext?
  @ObservedObject var store: ThumbnailStore

  @State private var image: NSImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(.quaternary)

      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: item.isVideo ? "video" : "photo")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .clipped()
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
