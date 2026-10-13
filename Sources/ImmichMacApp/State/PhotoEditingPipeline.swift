#if canImport(AppKit) && canImport(CoreImage)
import Foundation
@preconcurrency import AppKit
@preconcurrency import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Drives the Photos-style editor: owns the current `PhotoAdjustments`, renders previews off the
/// main actor, and keeps editor-local undo/redo, compare, and copy/paste state.
@MainActor
final class PhotoEditingPipeline: ObservableObject {
  /// Tools that take clicks on the image instead of passing them to the viewer.
  enum CanvasTool: Equatable {
    case none
    case crop
    case retouch
    case redEye
    case whiteBalancePicker
    case selectiveColorPicker
  }

  // MARK: - Published state

  @Published var adjustments = PhotoAdjustments() {
    didSet {
      guard adjustments != oldValue else { return }
      scheduleRender()
      scheduleUndoCommit(previous: oldValue)
    }
  }

  @Published var canvasTool: CanvasTool = .none {
    didSet {
      guard (canvasTool == .crop) != (oldValue == .crop) else { return }
      scheduleRender(immediately: true)
    }
  }

  /// Photos' Compare (hold M or press the compare button): shows the unedited original.
  @Published var isShowingOriginal = false
  @Published private(set) var editedImage: NSImage?
  @Published private(set) var histogram: Histogram?
  @Published private(set) var isProcessing = false
  @Published private(set) var isSourceLoaded = false
  @Published private(set) var filterPreviewCacheVersion: UInt64 = 0
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var sourceSize: CGSize = .zero
  @Published private(set) var originalImage: NSImage?

  /// Adjustments as last loaded from Immich; `hasUnsavedChanges` compares against this.
  @Published private(set) var baseline = PhotoAdjustments()

  /// Shared by every editing session, like Photos' Copy Edits / Paste Edits.
  @Published private(set) var copiedAdjustments: PhotoAdjustments?

  var hasEdits: Bool { !adjustments.isIdentity }
  var hasUnsavedChanges: Bool { adjustments != baseline }

  // MARK: - Private state

  private struct SourceBox: @unchecked Sendable {
    let full: CIImage
    let preview: CIImage
  }

  private final class RenderContext: @unchecked Sendable {
    let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
  }

  private struct RenderOutput: @unchecked Sendable {
    let cgImage: CGImage?
    let histogram: Histogram?
  }

  private nonisolated static let renderContext = RenderContext()
  private static let previewMaxDimension: CGFloat = 2560

  private var source: SourceBox?
  private var renderTask: Task<Void, Never>?
  private var renderGeneration: UInt64 = 0
  private var filterPreviewCache: [PhotoFilter: NSImage] = [:]
  private var filterPreviewSource: CIImage?

  private var undoStack: [PhotoAdjustments] = []
  private var redoStack: [PhotoAdjustments] = []
  private var pendingUndoBase: PhotoAdjustments?
  private var undoCommitTask: Task<Void, Never>?
  private var isApplyingHistory = false

  // MARK: - Session

  /// Starts a session on the unedited original. `adjustments` restores saved Immich edits.
  func beginSession(original: NSImage, adjustments initial: PhotoAdjustments) {
    renderTask?.cancel()
    undoCommitTask?.cancel()
    guard let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      isSourceLoaded = false
      return
    }
    let full = CIImage(cgImage: cgImage)
    let preview = PhotoEditRenderer.downsampled(full, maxDimension: Self.previewMaxDimension)
    source = SourceBox(full: full, preview: preview)
    sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
    originalImage = original
    filterPreviewCache.removeAll()
    filterPreviewSource = PhotoEditRenderer.downsampled(full, maxDimension: 192)
    filterPreviewCacheVersion &+= 1
    undoStack.removeAll()
    redoStack.removeAll()
    pendingUndoBase = nil
    updateUndoAvailability()
    isShowingOriginal = false
    canvasTool = .none
    baseline = initial
    isApplyingHistory = true
    adjustments = initial
    isApplyingHistory = false
    isSourceLoaded = true
    scheduleRender(immediately: true)
  }

  /// Ends the session and releases image memory.
  func endSession() {
    renderTask?.cancel()
    undoCommitTask?.cancel()
    source = nil
    editedImage = nil
    originalImage = nil
    histogram = nil
    isSourceLoaded = false
    canvasTool = .none
    isShowingOriginal = false
  }

  /// Marks the current state as saved (after writing edits to Immich).
  func markSaved() {
    baseline = adjustments
  }

  // MARK: - Rendering

  private func scheduleRender(immediately: Bool = false) {
    guard let source else { return }
    renderTask?.cancel()
    renderGeneration &+= 1
    let generation = renderGeneration
    let adjustments = adjustments
    let cropPreview = canvasTool == .crop
    isProcessing = true
    renderTask = Task { [weak self] in
      if !immediately {
        // Coalesce slider drags into one render per frame-ish interval.
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
      }
      let output = await Task.detached(priority: .userInitiated) { () -> RenderOutput in
        let context = Self.renderContext.context
        let image = PhotoEditRenderer.render(source.preview, adjustments: adjustments, cropPreview: cropPreview)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return RenderOutput(cgImage: nil, histogram: nil) }
        let cgImage = context.createCGImage(image, from: extent)
        let histogram = PhotoEditRenderer.histogram(of: image, context: context)
        return RenderOutput(cgImage: cgImage, histogram: histogram)
      }.value
      guard let self, !Task.isCancelled, self.renderGeneration == generation else { return }
      if let cgImage = output.cgImage {
        self.editedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      }
      self.histogram = output.histogram
      self.isProcessing = false
    }
  }

  /// The image the canvas should show right now.
  var displayImage: NSImage? {
    isShowingOriginal ? originalImage : editedImage
  }

  /// Geometry mapping for the preview, used to place spot clicks and draw the crop overlay.
  var previewGeometry: PhotoEditGeometry {
    PhotoEditGeometry(sourceSize: sourceSize, geometry: adjustments.geometry)
  }

  // MARK: - Filter thumbnails

  func cachedFilterPreview(for filter: PhotoFilter) -> NSImage? {
    filterPreviewCache[filter]
  }

  func loadFilterPreview(for filter: PhotoFilter) async -> NSImage? {
    if let cached = filterPreviewCache[filter] { return cached }
    guard let small = filterPreviewSource else { return nil }
    let box = SourceBox(full: small, preview: small)
    let cgImage = await Task.detached(priority: .utility) { () -> RenderOutput in
      let image = PhotoEditRenderer.applyFilter(filter, to: box.preview)
      return RenderOutput(cgImage: Self.renderContext.context.createCGImage(image, from: image.extent.integral), histogram: nil)
    }.value.cgImage
    guard let cgImage else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    filterPreviewCache[filter] = image
    return image
  }

  // MARK: - Undo / Redo

  private func scheduleUndoCommit(previous: PhotoAdjustments) {
    guard !isApplyingHistory else { return }
    if pendingUndoBase == nil {
      pendingUndoBase = previous
    }
    redoStack.removeAll()
    undoCommitTask?.cancel()
    // A slider drag becomes one undo step once it settles, like Photos' Adjust undo actions.
    undoCommitTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.commitPendingUndo()
    }
    updateUndoAvailability()
  }

  private func commitPendingUndo() {
    guard let base = pendingUndoBase else { return }
    pendingUndoBase = nil
    if base != adjustments {
      undoStack.append(base)
      if undoStack.count > 100 { undoStack.removeFirst() }
    }
    updateUndoAvailability()
  }

  func undo() {
    undoCommitTask?.cancel()
    commitPendingUndo()
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(adjustments)
    applyHistory(previous)
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(adjustments)
    applyHistory(next)
  }

  private func applyHistory(_ state: PhotoAdjustments) {
    isApplyingHistory = true
    withAnimation(ImmichMotion.Curves.structuralShort) {
      adjustments = state
    }
    isApplyingHistory = false
    updateUndoAvailability()
  }

  private func updateUndoAvailability() {
    canUndo = !undoStack.isEmpty || pendingUndoBase != nil
    canRedo = !redoStack.isEmpty
  }

  // MARK: - Commands

  func autoEnhance() {
    guard let source else { return }
    adjustments = PhotoEditRenderer.autoEnhancedAdjustments(for: source.preview, base: adjustments)
  }

  func autoStraighten() {
    guard let source, let angle = PhotoEditRenderer.detectHorizonAngle(in: source.preview) else { return }
    adjustments.geometry.straighten = angle
  }

  func copyEdits() {
    copiedAdjustments = adjustments
  }

  func pasteEdits() {
    guard let copiedAdjustments else { return }
    adjustments = adjustments.pastingAdjustments(from: copiedAdjustments)
  }

  /// Photos' Revert to Original: clears every adjustment and geometry change.
  func revertToOriginal() {
    adjustments = .identity
  }

  func resetCrop() {
    adjustments.geometry = PhotoAdjustments.Geometry()
  }

  func rotateLeft() {
    rotate(by: -1)
  }

  func rotateRight() {
    rotate(by: 1)
  }

  private func rotate(by turns: Int) {
    adjustments.geometry = adjustments.geometry.rotated(by: turns)
  }

  func flip(horizontal: Bool) {
    if horizontal {
      adjustments.geometry.flipHorizontal.toggle()
    } else {
      adjustments.geometry.flipVertical.toggle()
    }
  }

  func setCropAspect(_ aspect: CropAspect, portrait: Bool? = nil) {
    var geometry = adjustments.geometry
    geometry.aspect = aspect
    if let portrait { geometry.isPortrait = portrait }
    geometry.crop = PhotoEditGeometry.centeredCrop(
      aspect: targetCropAspect(for: geometry),
      validAspect: PhotoEditGeometry(sourceSize: sourceSize, geometry: geometry).validAspect
    )
    adjustments.geometry = geometry
  }

  /// Output aspect (width / height) the crop must keep, or nil for Freeform.
  func targetCropAspect(for geometry: PhotoAdjustments.Geometry? = nil) -> Double? {
    let geometry = geometry ?? adjustments.geometry
    let oriented = PhotoEditGeometry(sourceSize: sourceSize, geometry: geometry).orientedSize
    let sourceAspect = oriented.height > 0 ? oriented.width / oriented.height : 1
    guard let ratio = geometry.aspect.ratio(sourceAspect: sourceAspect) else { return nil }
    if geometry.aspect == .original { return ratio }
    return geometry.isPortrait ? 1 / ratio : ratio
  }

  // MARK: - Spot tools

  /// Handles a click on the canvas at a normalized point in the displayed (output) image.
  func handleCanvasClick(at outputPoint: PhotoAdjustments.NormalizedPoint, optionKey: Bool) {
    let mapped = previewGeometry.sourcePoint(fromOutput: outputPoint)
    // Clicks exactly on an edge can land a hair outside after rotation; clamp those in.
    let tolerance = 0.001
    guard (-tolerance...(1 + tolerance)).contains(mapped.x), (-tolerance...(1 + tolerance)).contains(mapped.y) else { return }
    let point = PhotoAdjustments.NormalizedPoint(x: min(max(mapped.x, 0), 1), y: min(max(mapped.y, 0), 1))
    switch canvasTool {
    case .redEye:
      adjustments.redEye.isEnabled = true
      adjustments.redEye.spots.append(.init(center: point, radius: 0.012))
    case .retouch:
      if optionKey {
        pendingRetouchSource = point
        return
      }
      let size = adjustments.retouch.brushSize
      let offset: PhotoAdjustments.NormalizedPoint
      if let source = pendingRetouchSource {
        offset = .init(x: source.x - point.x, y: source.y - point.y)
      } else {
        // Without an Option-click source, borrow texture from just beside the spot.
        offset = .init(x: size * 2.2 * sourceAspectCorrection, y: 0)
      }
      adjustments.retouch.isEnabled = true
      adjustments.retouch.spots.append(.init(center: point, sourceOffset: offset, radius: size))
    case .whiteBalancePicker:
      guard let source, let color = PhotoEditRenderer.sampleColor(in: source.preview, at: point, context: Self.renderContext.context) else { return }
      adjustments.whiteBalance.isEnabled = true
      adjustments.whiteBalance.sampledColor = color
      canvasTool = .none
    case .selectiveColorPicker:
      guard let source, let color = PhotoEditRenderer.sampleColor(in: source.preview, at: point, context: Self.renderContext.context) else { return }
      let hue = HSL(rgb: color).hue
      var selective = adjustments.selectiveColor
      selective.isEnabled = true
      if !selective.ranges.contains(where: { abs($0.hue - hue) < 0.01 }) {
        selective.ranges.append(.init(hue: hue))
      }
      adjustments.selectiveColor = selective
      canvasTool = .none
    case .none, .crop:
      break
    }
  }

  /// Photos' Option-click retouch source, held until the next brush stroke.
  @Published var pendingRetouchSource: PhotoAdjustments.NormalizedPoint?

  private var sourceAspectCorrection: Double {
    guard sourceSize.width > 0 else { return 1 }
    return min(sourceSize.width, sourceSize.height) / sourceSize.width
  }

  // MARK: - Export

  func renderFinalJPEG(compressionQuality: CGFloat = 0.92) async -> Data? {
    await renderFinal(type: .jpeg, quality: Double(compressionQuality))
  }

  func renderFinalPNG() async -> Data? {
    await renderFinal(type: .png, quality: 1)
  }

  private func renderFinal(type: UTType, quality: Double) async -> Data? {
    guard let source else { return nil }
    let adjustments = adjustments
    let identifier = type.identifier
    return await Task.detached(priority: .userInitiated) { () -> Data? in
      // Spot sizes and blur radii are relative, so the full-size render matches the preview.
      let image = PhotoEditRenderer.render(source.full, adjustments: adjustments)
      guard let cgImage = Self.renderContext.context.createCGImage(image, from: image.extent.integral) else { return nil }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil) else { return nil }
      let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
      CGImageDestinationAddImage(destination, cgImage, properties)
      return CGImageDestinationFinalize(destination) ? data as Data : nil
    }.value
  }
}
#endif
