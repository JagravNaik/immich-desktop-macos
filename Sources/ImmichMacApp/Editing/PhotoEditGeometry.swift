import CoreGraphics
import Foundation
import ImmichCore

/// Maps between source pixels and the edited output for one `PhotoAdjustments.Geometry`.
///
/// The order matches Photos and Immich: quarter turns, then flips, then straighten. After
/// straightening, the crop lives inside the largest centered rectangle with the oriented aspect
/// that still contains only image pixels, so a straightened photo never shows empty corners
/// (Photos zooms in the same way while you drag Straighten).
///
/// All transform math is in Core Image pixel space (origin bottom-left, y up). The public
/// helpers take and return normalized y-down points, which is what SwiftUI overlays use.
struct PhotoEditGeometry: Equatable, Sendable {
  let sourceSize: CGSize
  let geometry: PhotoAdjustments.Geometry

  /// Size after quarter turns (W', H').
  var orientedSize: CGSize {
    geometry.quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
  }

  /// Scale of the valid, corner-free area relative to the oriented image.
  var straightenScale: Double {
    Self.inscribedScale(size: orientedSize, degrees: geometry.straighten)
  }

  /// The corner-free area, centered on the origin of the straightened frame.
  var validRect: CGRect {
    let scale = straightenScale
    let width = orientedSize.width * scale
    let height = orientedSize.height * scale
    return CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
  }

  /// Output crop in the centered straightened frame (pixels, y up).
  var cropRectInStraightenedFrame: CGRect {
    let valid = validRect
    let crop = geometry.crop
    let width = crop.width * valid.width
    let height = crop.height * valid.height
    let x = valid.minX + crop.minX * valid.width
    let top = valid.maxY - crop.minY * valid.height
    return CGRect(x: x, y: top - height, width: width, height: height)
  }

  var outputSize: CGSize { cropRectInStraightenedFrame.size }

  /// Transform from source pixels to output pixels, both with a bottom-left origin.
  var sourceToOutput: CGAffineTransform {
    let quarter = -Double(((geometry.quarterTurns % 4) + 4) % 4) * .pi / 2
    let straighten = -geometry.straighten * .pi / 180
    let crop = cropRectInStraightenedFrame
    return CGAffineTransform(translationX: -sourceSize.width / 2, y: -sourceSize.height / 2)
      .concatenating(CGAffineTransform(rotationAngle: quarter))
      .concatenating(CGAffineTransform(
        scaleX: geometry.flipHorizontal ? -1 : 1,
        y: geometry.flipVertical ? -1 : 1
      ))
      .concatenating(CGAffineTransform(rotationAngle: straighten))
      .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
  }

  /// Transform used while cropping: the whole straightened image, fitted to the valid area.
  /// The crop overlay is drawn in this frame's normalized coordinates.
  var sourceToValidArea: CGAffineTransform {
    var uncropped = geometry
    uncropped.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    return PhotoEditGeometry(sourceSize: sourceSize, geometry: uncropped).sourceToOutput
  }

  // MARK: - Point mapping (normalized, y-down)

  func outputPoint(fromSource point: PhotoAdjustments.NormalizedPoint) -> PhotoAdjustments.NormalizedPoint {
    let pixel = CGPoint(x: point.x * sourceSize.width, y: (1 - point.y) * sourceSize.height)
    let mapped = pixel.applying(sourceToOutput)
    let size = outputSize
    let width = Double(max(size.width, 1))
    let height = Double(max(size.height, 1))
    return .init(x: Double(mapped.x) / width, y: 1.0 - Double(mapped.y) / height)
  }

  func sourcePoint(fromOutput point: PhotoAdjustments.NormalizedPoint) -> PhotoAdjustments.NormalizedPoint {
    let size = outputSize
    let pixel = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    let mapped = pixel.applying(sourceToOutput.inverted())
    let width = Double(max(sourceSize.width, 1))
    let height = Double(max(sourceSize.height, 1))
    return .init(x: Double(mapped.x) / width, y: 1.0 - Double(mapped.y) / height)
  }

  // MARK: - Crop helpers

  /// Largest centered crop with the given output aspect (width / height), normalized to the valid area.
  static func centeredCrop(aspect: Double?, validAspect: Double) -> CGRect {
    guard let aspect, aspect > 0, validAspect > 0 else {
      return CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    if validAspect > aspect {
      let width = aspect / validAspect
      return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
    let height = validAspect / aspect
    return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
  }

  /// Aspect (width / height) of the corner-free area.
  var validAspect: Double {
    let valid = validRect
    return valid.height > 0 ? valid.width / valid.height : 1
  }

  /// Largest scale `s` such that an `s`-scaled, axis-aligned copy of a `size` rectangle fits
  /// inside the same rectangle rotated by `degrees`.
  static func inscribedScale(size: CGSize, degrees: Double) -> Double {
    let radians = abs(degrees) * .pi / 180
    guard radians > 0, size.width > 0, size.height > 0 else { return 1 }
    let c = cos(radians)
    let s = sin(radians)
    let w = size.width
    let h = size.height
    return min(w / (w * c + h * s), h / (w * s + h * c))
  }

  // MARK: - Immich edits

  /// Immich v3 `PUT /assets/{id}/edits` actions for this geometry, or nil when it cannot be
  /// expressed server-side (Immich has no straighten; rotation must be a quarter turn).
  /// Order: rotate, mirror, crop. The crop is in pixels of the rotated and mirrored image,
  /// measured from its top-left corner.
  func immichEdits() -> [AssetEditAction]? {
    guard geometry.straighten == 0 else { return nil }
    var actions: [AssetEditAction] = []
    let turns = ((geometry.quarterTurns % 4) + 4) % 4
    if turns != 0 {
      actions.append(.rotate(degrees: turns * 90))
    }
    if geometry.flipHorizontal {
      actions.append(.mirror(axis: "horizontal"))
    }
    if geometry.flipVertical {
      actions.append(.mirror(axis: "vertical"))
    }
    if !geometry.isFullFrame {
      let size = orientedSize
      let crop = geometry.crop
      let x = Int((crop.minX * size.width).rounded())
      let y = Int((crop.minY * size.height).rounded())
      let width = max(1, min(Int((crop.width * size.width).rounded()), Int(size.width) - x))
      let height = max(1, min(Int((crop.height * size.height).rounded()), Int(size.height) - y))
      actions.append(.crop(x: x, y: y, width: width, height: height))
    }
    return actions
  }

  /// Rebuilds geometry from Immich edit actions so reopening the editor shows saved edits.
  static func geometry(from actions: [AssetEditAction], sourceSize: CGSize) -> PhotoAdjustments.Geometry {
    var geometry = PhotoAdjustments.Geometry()
    for action in actions {
      switch action {
      case .rotate(let degrees):
        geometry.quarterTurns = (geometry.quarterTurns + degrees / 90) % 4
      case .mirror(let axis):
        if axis == "vertical" {
          geometry.flipVertical.toggle()
        } else {
          geometry.flipHorizontal.toggle()
        }
      case .crop(let x, let y, let width, let height):
        let oriented = PhotoEditGeometry(sourceSize: sourceSize, geometry: geometry).orientedSize
        guard oriented.width > 0, oriented.height > 0 else { continue }
        geometry.crop = CGRect(
          x: Double(x) / oriented.width,
          y: Double(y) / oriented.height,
          width: Double(width) / oriented.width,
          height: Double(height) / oriented.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      }
    }
    return geometry
  }
}
