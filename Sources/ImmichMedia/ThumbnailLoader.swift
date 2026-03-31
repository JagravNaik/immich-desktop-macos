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

public final class ThumbnailLoader: @unchecked Sendable {
  private let cache = NSCache<NSURL, NSImage>()

  public init() {}

  public func loadThumbnail(for fileURL: URL, maxPixelSize: ThumbnailPixelSize = 256) async -> PlatformImage? {
    if let cached = cache.object(forKey: fileURL as NSURL) {
      return cached
    }

    let url = fileURL
    let pixelSize = maxPixelSize
    let result: NSImage? = await Task.detached(priority: .userInitiated) {
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
        return nil
      }
      let size = NSSize(width: cgImage.width, height: cgImage.height)
      return NSImage(cgImage: cgImage, size: size)
    }.value

    if let result {
      cache.setObject(result, forKey: fileURL as NSURL)
    }
    return result
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
