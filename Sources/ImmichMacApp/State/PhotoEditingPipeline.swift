#if canImport(AppKit) && canImport(CoreImage)
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Combine

/// A CoreImage-backed photo editing pipeline that applies adjustment sliders,
/// filter presets, and geometric transforms to produce an edited NSImage in real time.
@MainActor
final class PhotoEditingPipeline: ObservableObject {

  // MARK: - Adjustment Parameters

  @Published var exposure: Double = 0           // -2 … 2
  @Published var brightness: Double = 0         // -1 … 1
  @Published var contrast: Double = 0           // -1 … 1
  @Published var highlights: Double = 0         // -1 … 1
  @Published var shadows: Double = 0            // -1 … 1
  @Published var saturation: Double = 0         // -1 … 1
  @Published var warmth: Double = 0             // -1 … 1
  @Published var sharpness: Double = 0          //  0 … 1

  // MARK: - Filter Preset

  @Published var selectedFilter: FilterPreset = .original

  // MARK: - Geometry

  @Published var rotation: Double = 0           // degrees, -45 … 45 (straighten)
  @Published var rotationSteps: Int = 0         // 90° increments: 0, 1, 2, 3
  @Published var flipHorizontal: Bool = false
  @Published var flipVertical: Bool = false
  @Published var cropAspectRatio: CropAspect = .free
  @Published var cropRect: CGRect = .zero       // normalized 0…1

  // MARK: - Source & Output

  @Published private(set) var editedImage: NSImage?
  @Published private(set) var isProcessing = false

  private var sourceImage: CIImage?
  private var sourceNSImage: NSImage?
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var renderTask: Task<Void, Never>?
  private var parameterCancellable: AnyCancellable?
  private nonisolated static let backgroundRenderContext = CIContext(options: [.useSoftwareRenderer: false])

  private struct RenderSnapshot: @unchecked Sendable {
    let sourceImage: CIImage?
    let sourceNSImage: NSImage?
    let exposure: Double
    let brightness: Double
    let contrast: Double
    let highlights: Double
    let shadows: Double
    let saturation: Double
    let warmth: Double
    let sharpness: Double
    let selectedFilter: FilterPreset
    let rotation: Double
    let rotationSteps: Int
    let flipHorizontal: Bool
    let flipVertical: Bool
    let cropRect: CGRect
  }

  private struct RenderResult: @unchecked Sendable {
    let image: NSImage?
  }

  var hasEdits: Bool {
    exposure != 0 || brightness != 0 || contrast != 0 ||
    highlights != 0 || shadows != 0 || saturation != 0 ||
    warmth != 0 || sharpness != 0 ||
    selectedFilter != .original ||
    rotation != 0 || rotationSteps != 0 ||
    flipHorizontal || flipVertical
  }

  // MARK: - Filter Presets

  enum FilterPreset: String, CaseIterable, Identifiable, Hashable {
    case original = "Original"
    case vivid = "Vivid"
    case dramatic = "Dramatic"
    case mono = "Mono"
    case noir = "Noir"
    case silvertone = "Silvertone"
    case fade = "Fade"
    case chrome = "Chrome"
    case process = "Process"

    var id: String { rawValue }
  }

  enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case threeTwo = "3:2"

    var id: String { rawValue }

    var ratio: Double? {
      switch self {
      case .free: nil
      case .square: 1.0
      case .fourThree: 4.0 / 3.0
      case .sixteenNine: 16.0 / 9.0
      case .threeTwo: 3.0 / 2.0
      }
    }
  }

  // MARK: - Init

  init() {
    // Observe all published properties and debounce re-renders
    parameterCancellable = objectWillChange
      .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleRender()
      }
  }

  // MARK: - Set Source Image

  func setSourceImage(_ nsImage: NSImage) {
    sourceNSImage = nsImage
    guard let tiffData = nsImage.tiffRepresentation,
          let ciImage = CIImage(data: tiffData) else { return }
    sourceImage = ciImage
    cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    scheduleRender()
  }

  // MARK: - Render Pipeline

  private func scheduleRender() {
    renderTask?.cancel()
    let snapshot = makeRenderSnapshot()
    renderTask = Task { [weak self, snapshot] in
      guard let self else { return }
      self.isProcessing = true
      defer { self.isProcessing = false }
      let result = await Task.detached(priority: .userInitiated) {
        RenderResult(image: Self.renderEditedImage(from: snapshot))
      }.value
      guard !Task.isCancelled else { return }
      self.editedImage = result.image
    }
  }

  private func makeRenderSnapshot() -> RenderSnapshot {
    RenderSnapshot(
      sourceImage: sourceImage,
      sourceNSImage: sourceNSImage,
      exposure: exposure,
      brightness: brightness,
      contrast: contrast,
      highlights: highlights,
      shadows: shadows,
      saturation: saturation,
      warmth: warmth,
      sharpness: sharpness,
      selectedFilter: selectedFilter,
      rotation: rotation,
      rotationSteps: rotationSteps,
      flipHorizontal: flipHorizontal,
      flipVertical: flipVertical,
      cropRect: cropRect
    )
  }

  private func renderEditedImage() -> NSImage? {
    Self.renderEditedImage(from: makeRenderSnapshot())
  }

  private nonisolated static func renderEditedImage(from snapshot: RenderSnapshot) -> NSImage? {
    guard var image = snapshot.sourceImage else { return snapshot.sourceNSImage }

    // 1. Exposure
    if snapshot.exposure != 0 {
      let filter = CIFilter.exposureAdjust()
      filter.inputImage = image
      filter.ev = Float(snapshot.exposure)
      if let output = filter.outputImage { image = output }
    }

    // 2. Color Controls (brightness, contrast, saturation)
    if snapshot.brightness != 0 || snapshot.contrast != 0 || snapshot.saturation != 0 {
      let filter = CIFilter.colorControls()
      filter.inputImage = image
      filter.brightness = Float(snapshot.brightness)
      filter.contrast = Float(1.0 + snapshot.contrast) // CIFilter expects 0…2 centered at 1
      filter.saturation = Float(1.0 + snapshot.saturation) // CIFilter expects 0…2 centered at 1
      if let output = filter.outputImage { image = output }
    }

    // 3. Highlights & Shadows
    if snapshot.highlights != 0 || snapshot.shadows != 0 {
      let filter = CIFilter.highlightShadowAdjust()
      filter.inputImage = image
      filter.highlightAmount = Float(1.0 - snapshot.highlights) // higher value = less highlights
      filter.shadowAmount = Float(snapshot.shadows + 1.0) // 0…2 centered at 1
      if let output = filter.outputImage { image = output }
    }

    // 4. Temperature (warmth)
    if snapshot.warmth != 0 {
      let filter = CIFilter.temperatureAndTint()
      filter.inputImage = image
      // Neutral is 6500K. Shift ±1500K based on warmth slider
      let kelvin = 6500 + snapshot.warmth * 1500
      filter.neutral = CIVector(x: CGFloat(kelvin), y: 0)
      filter.targetNeutral = CIVector(x: 6500, y: 0)
      if let output = filter.outputImage { image = output }
    }

    // 5. Sharpness
    if snapshot.sharpness > 0 {
      let filter = CIFilter.sharpenLuminance()
      filter.inputImage = image
      filter.sharpness = Float(snapshot.sharpness * 2.0) // 0…2 effective range
      if let output = filter.outputImage { image = output }
    }

    // 6. Filter preset
    image = applyFilterPreset(to: image, preset: snapshot.selectedFilter)

    // 7. Geometry: rotation (straighten + 90° steps)
    let totalRotation = snapshot.rotation + Double(snapshot.rotationSteps) * 90.0
    if totalRotation != 0 {
      let radians = totalRotation * .pi / 180.0
      image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
    }

    // 8. Flip
    if snapshot.flipHorizontal {
      image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
        .translatedBy(x: -image.extent.width, y: 0))
    }
    if snapshot.flipVertical {
      image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
        .translatedBy(x: 0, y: -image.extent.height))
    }

    // 9. Crop (if not full frame)
    if snapshot.cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) &&
        snapshot.cropRect.width > 0 &&
        snapshot.cropRect.height > 0 {
      let extent = image.extent
      let cropCGRect = CGRect(
        x: extent.origin.x + snapshot.cropRect.origin.x * extent.width,
        y: extent.origin.y + snapshot.cropRect.origin.y * extent.height,
        width: snapshot.cropRect.width * extent.width,
        height: snapshot.cropRect.height * extent.height
      )
      image = image.cropped(to: cropCGRect)
    }

    // Render to NSImage
    let extent = image.extent
    guard extent.width > 0, extent.height > 0,
          let cgImage = backgroundRenderContext.createCGImage(image, from: extent) else {
      return snapshot.sourceNSImage
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: extent.width, height: extent.height))
  }

  // MARK: - Filter Presets (CIFilter-based)

  private nonisolated static func applyFilterPreset(to image: CIImage, preset: FilterPreset) -> CIImage {
    switch preset {
    case .original:
      return image

    case .vivid:
      let filter = CIFilter.vibrance()
      filter.inputImage = image
      filter.amount = 0.8
      return filter.outputImage ?? image

    case .dramatic:
      // High contrast + slight desaturation
      let contrast = CIFilter.colorControls()
      contrast.inputImage = image
      contrast.contrast = 1.4
      contrast.saturation = 0.85
      contrast.brightness = -0.05
      return contrast.outputImage ?? image

    case .mono:
      let filter = CIFilter.colorMonochrome()
      filter.inputImage = image
      filter.color = CIColor(red: 0.7, green: 0.7, blue: 0.7)
      filter.intensity = 1.0
      return filter.outputImage ?? image

    case .noir:
      let filter = CIFilter.photoEffectNoir()
      filter.inputImage = image
      return filter.outputImage ?? image

    case .silvertone:
      let filter = CIFilter.photoEffectTonal()
      filter.inputImage = image
      return filter.outputImage ?? image

    case .fade:
      let filter = CIFilter.photoEffectFade()
      filter.inputImage = image
      return filter.outputImage ?? image

    case .chrome:
      let filter = CIFilter.photoEffectChrome()
      filter.inputImage = image
      return filter.outputImage ?? image

    case .process:
      let filter = CIFilter.photoEffectProcess()
      filter.inputImage = image
      return filter.outputImage ?? image
    }
  }

  // MARK: - Actions

  /// Renders a small preview of the source image with only the given filter preset applied.
  func previewImage(for preset: FilterPreset) -> NSImage? {
    guard let sourceImage else { return sourceNSImage }
    let filtered = Self.applyFilterPreset(to: sourceImage, preset: preset)
    guard let cgImage = ciContext.createCGImage(filtered, from: filtered.extent) else { return sourceNSImage }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }

  func autoEnhance() {
    exposure = 0.1
    brightness = 0.05
    contrast = 0.1
    highlights = -0.1
    shadows = 0.15
    saturation = 0.15
    sharpness = 0.3
  }

  func resetAll() {
    exposure = 0; brightness = 0; contrast = 0
    highlights = 0; shadows = 0; saturation = 0
    warmth = 0; sharpness = 0
    selectedFilter = .original
    rotation = 0; rotationSteps = 0
    flipHorizontal = false; flipVertical = false
    cropAspectRatio = .free
    cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
  }

  func rotateLeft() {
    rotationSteps = (rotationSteps - 1 + 4) % 4
  }

  func rotateRight() {
    rotationSteps = (rotationSteps + 1) % 4
  }

  // MARK: - Export

  /// Renders the final edited image as JPEG data suitable for upload/save.
  func renderFinalJPEG(compressionQuality: CGFloat = 0.92) -> Data? {
    guard sourceImage != nil else { return nil }

    // Re-run the full pipeline at original resolution
    // (Same as renderEditedImage but returns Data instead of NSImage)
    let rendered = renderEditedImage()
    guard let rendered,
          let tiffData = rendered.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
  }

  /// Renders the final edited image as PNG data (lossless).
  func renderFinalPNG() -> Data? {
    let rendered = renderEditedImage()
    guard let rendered,
          let tiffData = rendered.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

    return bitmap.representation(using: .png, properties: [:])
  }
}
#endif
