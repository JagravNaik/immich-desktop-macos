import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreGraphics)
public typealias ThumbnailPixelSize = CGFloat
#else
public typealias ThumbnailPixelSize = Double
#endif

#if canImport(AppKit)
import AppKit
import ImageIO

public typealias PlatformImage = NSImage

private struct DetachedThumbnailResult: @unchecked Sendable {
  let cgImage: CGImage?
}

public final class ThumbnailLoader: @unchecked Sendable {
  private let cache = NSCache<NSURL, NSImage>()

  public init() {}

  public func loadThumbnail(for fileURL: URL, maxPixelSize: ThumbnailPixelSize = 256) async -> PlatformImage? {
    if let cached = cache.object(forKey: fileURL as NSURL) {
      return cached
    }

    let url = fileURL
    let pixelSize = maxPixelSize
    let result = await Task.detached(priority: .userInitiated) { () -> DetachedThumbnailResult in
      guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let cgImage = CGImageSourceCreateThumbnailAtIndex(
          source,
          0,
          [
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary
        )
      else {
        return DetachedThumbnailResult(cgImage: nil)
      }
      return DetachedThumbnailResult(cgImage: cgImage)
    }.value

    guard let cgImage = result.cgImage else {
      return nil
    }

    let image = NSImage(
      cgImage: cgImage,
      size: NSSize(width: cgImage.width, height: cgImage.height)
    )
    cache.setObject(image, forKey: fileURL as NSURL)
    return image
  }
}

#else

public struct PlatformImage: Sendable {}

public final class ThumbnailLoader: @unchecked Sendable {
  public init() {}

  public func loadThumbnail(for _: URL, maxPixelSize _: ThumbnailPixelSize = 256) async -> PlatformImage? {
    nil
  }
}
#endif
