import Foundation

#if canImport(AppKit)
import AppKit
import ImageIO

public typealias PlatformImage = NSImage

@MainActor
public final class ThumbnailLoader {
  private let cache = NSCache<NSURL, NSImage>()

  public init() {}

  public func loadThumbnail(for fileURL: URL, maxPixelSize: CGFloat = 256) -> PlatformImage? {
    if let cached = cache.object(forKey: fileURL as NSURL) {
      return cached
    }

    guard
      let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
      )
    else {
      return nil
    }

    let size = NSSize(width: cgImage.width, height: cgImage.height)
    let thumbnail = NSImage(cgImage: cgImage, size: size)
    cache.setObject(thumbnail, forKey: fileURL as NSURL)
    return thumbnail
  }
}

#else

public struct PlatformImage: Sendable {}

@MainActor
public final class ThumbnailLoader {
  public init() {}

  public func loadThumbnail(for _: URL, maxPixelSize _: Double = 256) -> PlatformImage? {
    nil
  }
}
#endif
