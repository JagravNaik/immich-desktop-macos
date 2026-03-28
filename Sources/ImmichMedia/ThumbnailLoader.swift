import Foundation

#if canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage

public actor ThumbnailLoader {
  private let cache = NSCache<NSURL, NSImage>()

  public init() {}

  public func loadThumbnail(for fileURL: URL, maxPixelSize: CGFloat = 256) -> PlatformImage? {
    if let cached = cache.object(forKey: fileURL as NSURL) {
      return cached
    }

    guard let image = NSImage(contentsOf: fileURL) else {
      return nil
    }

    let thumbnail = NSImage(size: NSSize(width: maxPixelSize, height: maxPixelSize))
    thumbnail.lockFocus()
    image.draw(
      in: NSRect(x: 0, y: 0, width: maxPixelSize, height: maxPixelSize),
      from: .zero,
      operation: .copy,
      fraction: 1
    )
    thumbnail.unlockFocus()

    cache.setObject(thumbnail, forKey: fileURL as NSURL)
    return thumbnail
  }
}

#else

public struct PlatformImage: Sendable {}

public actor ThumbnailLoader {
  public init() {}

  public func loadThumbnail(for _: URL, maxPixelSize _: Double = 256) -> PlatformImage? {
    nil
  }
}
#endif
