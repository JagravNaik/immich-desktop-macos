#if canImport(AppKit) && canImport(CoreImage)
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import Combine
import UniformTypeIdentifiers

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
  private var sourceImageData: Data?
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var renderTask: Task<Void, Never>?
  private var parameterCancellable: AnyCancellable?
  private var renderGeneration: UInt64 = 0
  private nonisolated static let backgroundRenderContext = CIContext(options: [.useSoftwareRenderer: false])

  private struct RenderSnapshot: Sendable {
    let sourceImageData: Data?
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

  private struct DetachedRenderResult: @unchecked Sendable {
    let cgImage: CGImage?
  }

  private enum EncodedRenderFormat: Sendable {
    case jpeg(Double)
    case png
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
    // Observe only render-affecting inputs so output updates do not reschedule renders.
    parameterCancellable = renderTriggerPublisher()
      .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleRender()
      }
  }

  private func renderTriggerPublisher() -> AnyPublisher<Void, Never> {
    let publishers: [AnyPublisher<Void, Never>] = [
      $exposure.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $brightness.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $contrast.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $highlights.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $shadows.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $saturation.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $warmth.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $sharpness.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $selectedFilter.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $rotation.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $rotationSteps.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $flipHorizontal.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $flipVertical.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $cropAspectRatio.dropFirst().map { _ in () }.eraseToAnyPublisher(),
      $cropRect.dropFirst().map { _ in () }.eraseToAnyPublisher(),
    ]

    return Publishers.MergeMany(publishers).eraseToAnyPublisher()
  }

  // MARK: - Set Source Image

  func setSourceImage(_ nsImage: NSImage) {
    sourceNSImage = nsImage
    sourceImageData = nsImage.tiffRepresentation
    if let sourceImageData,
       let ciImage = CIImage(data: sourceImageData) {
      sourceImage = ciImage
    } else {
      sourceImage = nil
    }
    cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    scheduleRender()
  }

  // MARK: - Render Pipeline

  private func scheduleRender() {
    renderTask?.cancel()
    let snapshot = makeRenderSnapshot()
    renderGeneration &+= 1
    let generation = renderGeneration
    isProcessing = true
    renderTask = Task { [weak self, snapshot, generation] in
      let result = await Task.detached(priority: .userInitiated) {
        DetachedRenderResult(cgImage: Self.renderCGImage(from: snapshot))
      }.value
      guard let self else { return }
      guard !Task.isCancelled, self.renderGeneration == generation else { return }
      if let cgImage = result.cgImage {
        self.editedImage = NSImage(
          cgImage: cgImage,
          size: NSSize(width: cgImage.width, height: cgImage.height)
        )
      } else {
        self.editedImage = self.sourceNSImage
      }
      self.isProcessing = false
    }
  }

  private func makeRenderSnapshot() -> RenderSnapshot {
    RenderSnapshot(
      sourceImageData: sourceImageData,
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

  private nonisolated static func renderCGImage(from snapshot: RenderSnapshot) -> CGImage? {
    guard
      let sourceImageData = snapshot.sourceImageData,
      var image = CIImage(data: sourceImageData)
    else {
      return nil
    }

    if snapshot.exposure != 0 {
      let filter = CIFilter.exposureAdjust()
      filter.inputImage = image
      filter.ev = Float(snapshot.exposure)
      if let output = filter.outputImage { image = output }
    }

    if snapshot.brightness != 0 || snapshot.contrast != 0 || snapshot.saturation != 0 {
      let filter = CIFilter.colorControls()
      filter.inputImage = image
      filter.brightness = Float(snapshot.brightness)
      filter.contrast = Float(1.0 + snapshot.contrast)
      filter.saturation = Float(1.0 + snapshot.saturation)
      if let output = filter.outputImage { image = output }
    }

    if snapshot.highlights != 0 || snapshot.shadows != 0 {
      let filter = CIFilter.highlightShadowAdjust()
      filter.inputImage = image
      filter.highlightAmount = Float(1.0 - snapshot.highlights)
      filter.shadowAmount = Float(snapshot.shadows + 1.0)
      if let output = filter.outputImage { image = output }
    }

    if snapshot.warmth != 0 {
      let filter = CIFilter.temperatureAndTint()
      filter.inputImage = image
      let kelvin = 6500 + snapshot.warmth * 1500
      filter.neutral = CIVector(x: CGFloat(kelvin), y: 0)
      filter.targetNeutral = CIVector(x: 6500, y: 0)
      if let output = filter.outputImage { image = output }
    }

    if snapshot.sharpness > 0 {
      let filter = CIFilter.sharpenLuminance()
      filter.inputImage = image
      filter.sharpness = Float(snapshot.sharpness * 2.0)
      if let output = filter.outputImage { image = output }
    }

    image = applyFilterPreset(to: image, preset: snapshot.selectedFilter)

    let totalRotation = snapshot.rotation + Double(snapshot.rotationSteps) * 90.0
    if totalRotation != 0 {
      let radians = totalRotation * .pi / 180.0
      image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
    }

    if snapshot.flipHorizontal {
      image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
        .translatedBy(x: -image.extent.width, y: 0))
    }
    if snapshot.flipVertical {
      image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
        .translatedBy(x: 0, y: -image.extent.height))
    }

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

    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }
    return backgroundRenderContext.createCGImage(image, from: extent)
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
  func renderFinalJPEG(compressionQuality: CGFloat = 0.92) async -> Data? {
    guard sourceImageData != nil else { return nil }
    let snapshot = makeRenderSnapshot()
    let quality = Double(compressionQuality)
    return await Task.detached(priority: .userInitiated) {
      Self.renderEncodedData(from: snapshot, format: .jpeg(quality))
    }.value
  }

  /// Renders the final edited image as PNG data (lossless).
  func renderFinalPNG() async -> Data? {
    guard sourceImageData != nil else { return nil }
    let snapshot = makeRenderSnapshot()
    return await Task.detached(priority: .userInitiated) {
      Self.renderEncodedData(from: snapshot, format: .png)
    }.value
  }

  private nonisolated static func renderEncodedData(from snapshot: RenderSnapshot, format: EncodedRenderFormat) -> Data? {
    guard let cgImage = renderCGImage(from: snapshot) else { return nil }
    let mutableData = NSMutableData()
    let destinationType: CFString
    let properties: CFDictionary
    switch format {
    case .jpeg(let quality):
      destinationType = UTType.jpeg.identifier as CFString
      properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    case .png:
      destinationType = UTType.png.identifier as CFString
      properties = [:] as CFDictionary
    }

    guard let destination = CGImageDestinationCreateWithData(
      mutableData,
      destinationType,
      1,
      nil
    ) else {
      return nil
    }

    CGImageDestinationAddImage(destination, cgImage, properties)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    return mutableData as Data
  }
}
#endif
