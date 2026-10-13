import CoreImage
import XCTest
import ImmichCore
@testable import ImmichMacApp

final class PhotoEditGeometryTests: XCTestCase {
  private let landscape = CGSize(width: 4000, height: 3000)

  func testInscribedScaleIsOneWithoutStraightenAndShrinksWhenRotated() {
    XCTAssertEqual(PhotoEditGeometry.inscribedScale(size: landscape, degrees: 0), 1)
    XCTAssertEqual(
      PhotoEditGeometry.inscribedScale(size: CGSize(width: 100, height: 100), degrees: 45),
      1 / sqrt(2),
      accuracy: 0.0001
    )
    XCTAssertLessThan(PhotoEditGeometry.inscribedScale(size: landscape, degrees: -10), 1)
  }

  func testStraightenedValidAreaContainsOnlyImagePixels() {
    var geometry = PhotoAdjustments.Geometry()
    geometry.straighten = 12
    let mapping = PhotoEditGeometry(sourceSize: landscape, geometry: geometry)
    // Every output corner must map back inside the source image.
    for corner in [(0.0, 0.0), (1, 0), (0, 1), (1, 1)] {
      let source = mapping.sourcePoint(fromOutput: .init(x: corner.0, y: corner.1))
      XCTAssertTrue((-0.0001...1.0001).contains(source.x), "x \(source.x)")
      XCTAssertTrue((-0.0001...1.0001).contains(source.y), "y \(source.y)")
    }
  }

  func testPointMappingRoundTripsThroughRotateFlipStraightenAndCrop() {
    var geometry = PhotoAdjustments.Geometry()
    geometry.quarterTurns = 1
    geometry.flipHorizontal = true
    geometry.straighten = -7
    geometry.crop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
    let mapping = PhotoEditGeometry(sourceSize: landscape, geometry: geometry)
    let point = PhotoAdjustments.NormalizedPoint(x: 0.42, y: 0.37)
    let roundTrip = mapping.sourcePoint(fromOutput: mapping.outputPoint(fromSource: point))
    XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.0001)
    XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.0001)
  }

  func testClockwiseQuarterTurnMovesTopLeftToTopRightAndSwapsSize() {
    var geometry = PhotoAdjustments.Geometry()
    geometry.quarterTurns = 1
    let mapping = PhotoEditGeometry(sourceSize: landscape, geometry: geometry)
    XCTAssertEqual(mapping.outputSize.width, 3000, accuracy: 0.5)
    XCTAssertEqual(mapping.outputSize.height, 4000, accuracy: 0.5)
    let mapped = mapping.outputPoint(fromSource: .init(x: 0, y: 0))
    XCTAssertEqual(mapped.x, 1, accuracy: 0.0001)
    XCTAssertEqual(mapped.y, 0, accuracy: 0.0001)
  }

  func testRotatingGeometryCarriesTheCropWithTheImage() {
    var geometry = PhotoAdjustments.Geometry()
    geometry.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1) // left half
    let rotated = geometry.rotated(by: 1)
    XCTAssertEqual(rotated.quarterTurns, 1)
    XCTAssertEqual(rotated.crop, CGRect(x: 0, y: 0, width: 1, height: 0.5)) // now the top half
    XCTAssertEqual(rotated.rotated(by: -1).crop, geometry.crop)
  }

  func testImmichEditsUseRotateMirrorCropOrderInRotatedPixels() throws {
    var geometry = PhotoAdjustments.Geometry()
    geometry.quarterTurns = 1
    geometry.flipHorizontal = true
    geometry.crop = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    let edits = try XCTUnwrap(PhotoEditGeometry(sourceSize: landscape, geometry: geometry).immichEdits())
    XCTAssertEqual(edits, [
      .rotate(degrees: 90),
      .mirror(axis: "horizontal"),
      .crop(x: 750, y: 2000, width: 1500, height: 1000),
    ])
    let restored = PhotoEditGeometry.geometry(from: edits, sourceSize: landscape)
    XCTAssertEqual(restored.quarterTurns, 1)
    XCTAssertTrue(restored.flipHorizontal)
    XCTAssertEqual(restored.crop.minX, 0.25, accuracy: 0.001)
    XCTAssertEqual(restored.crop.height, 0.25, accuracy: 0.001)
  }

  func testStraightenCannotBeStoredAsImmichEdits() {
    var geometry = PhotoAdjustments.Geometry()
    geometry.straighten = 3
    XCTAssertNil(PhotoEditGeometry(sourceSize: landscape, geometry: geometry).immichEdits())
    XCTAssertEqual(PhotoEditGeometry(sourceSize: landscape, geometry: .init()).immichEdits(), [])
  }

  func testCenteredCropKeepsRequestedAspect() {
    let crop = PhotoEditGeometry.centeredCrop(aspect: 1, validAspect: 4.0 / 3.0)
    XCTAssertEqual(crop.width * 4 / (crop.height * 3), 1, accuracy: 0.0001)
    XCTAssertEqual(crop.midX, 0.5, accuracy: 0.0001)
  }
}

final class PhotoEditRendererTests: XCTestCase {
  func testCurveInterpolationIsIdentityByDefaultAndNeverOvershoots() {
    XCTAssertEqual(CurveLUTs.evaluate(PhotoAdjustments.Curves.identityPoints, at: 0.3), 0.3, accuracy: 0.0001)
    let points: [PhotoAdjustments.CurvePoint] = [.init(x: 0, y: 0), .init(x: 0.4, y: 0.8), .init(x: 0.5, y: 0.82), .init(x: 1, y: 1)]
    var previous = 0.0
    for step in 0...100 {
      let value = CurveLUTs.evaluate(points, at: Double(step) / 100)
      XCTAssertGreaterThanOrEqual(value + 0.000001, previous, "curve must stay monotone")
      XCTAssertLessThanOrEqual(value, 1)
      previous = value
    }
  }

  func testLevelsMapBlackGrayAndWhitePoints() {
    let values = PhotoAdjustments.Levels.Values(black: 0.2, gray: 0.5, white: 0.8)
    XCTAssertEqual(values.map(0.2), 0, accuracy: 0.0001)
    XCTAssertEqual(values.map(0.5), 0.5, accuracy: 0.0001)
    XCTAssertEqual(values.map(0.9), 1, accuracy: 0.0001)
    XCTAssertGreaterThan(PhotoAdjustments.Levels.Values(gray: 0.3).map(0.5), 0.5)
  }

  func testHSLRoundTrip() {
    let color = PhotoAdjustments.RGB(red: 0.8, green: 0.3, blue: 0.15)
    let back = HSL(rgb: color).rgb
    XCTAssertEqual(back.red, color.red, accuracy: 0.0001)
    XCTAssertEqual(back.green, color.green, accuracy: 0.0001)
    XCTAssertEqual(back.blue, color.blue, accuracy: 0.0001)
  }

  func testNeutralGrayGainsMakeTheSampleGray() throws {
    let sample = PhotoAdjustments.RGB(red: 0.6, green: 0.5, blue: 0.35)
    let gains = try XCTUnwrap(PhotoEditRenderer.whiteBalanceGains(sample: sample, mode: .neutralGray))
    XCTAssertEqual(sample.red * gains.red, sample.green * gains.green, accuracy: 0.0001)
    XCTAssertEqual(sample.blue * gains.blue, sample.green * gains.green, accuracy: 0.0001)
  }

  func testSelectiveColorOnlyChangesTheTargetedHue() {
    var selective = PhotoAdjustments.SelectiveColor()
    selective.ranges[0].saturation = -1 // desaturate reds
    let red = PhotoEditRenderer.applySelectiveColor(selective, to: .init(red: 0.9, green: 0.1, blue: 0.1))
    let blue = PhotoEditRenderer.applySelectiveColor(selective, to: .init(red: 0.1, green: 0.2, blue: 0.9))
    XCTAssertLessThan(HSL(rgb: red).saturation, 0.2)
    XCTAssertEqual(blue.blue, 0.9, accuracy: 0.001)
  }

  func testLightMasterPushesOptionsThroughWeights() {
    var light = PhotoAdjustments.Light()
    light.master = 1
    let effective = light.effective
    XCTAssertGreaterThan(effective.exposure, 0)
    XCTAssertLessThan(effective.highlights, 0)
    XCTAssertGreaterThan(effective.shadows, 0)
  }

  func testRenderAppliesExposureCropAndKeepsOutputSize() throws {
    let source = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
    var adjustments = PhotoAdjustments()
    adjustments.light.exposure = 0.5
    adjustments.geometry.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

    let output = PhotoEditRenderer.render(source, adjustments: adjustments)
    XCTAssertEqual(output.extent.width, 200, accuracy: 0.5)
    XCTAssertEqual(output.extent.height, 150, accuracy: 0.5)

    let context = CIContext()
    func sample(_ image: CIImage) -> Float {
      var pixel = [Float](repeating: 0, count: 4)
      context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 100, y: 75, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
      return pixel[0]
    }
    let unadjusted = PhotoEditRenderer.render(source, adjustments: PhotoAdjustments())
    // +0.5 maps to +1 EV, which doubles linear light.
    XCTAssertEqual(sample(output) / sample(unadjusted), 2, accuracy: 0.05)
  }

  func testFiltersProduceAnImageForEveryPreset() {
    let source = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    for filter in PhotoFilter.allCases {
      XCTAssertFalse(PhotoEditRenderer.applyFilter(filter, to: source).extent.isEmpty, filter.rawValue)
    }
    XCTAssertEqual(PhotoFilter.allCases.map(\.rawValue), [
      "Original", "Vivid", "Vivid Warm", "Vivid Cool", "Dramatic", "Dramatic Warm", "Dramatic Cool", "Mono", "Silvertone", "Noir",
    ])
  }
}

@MainActor
final class EditSaveStrategyTests: XCTestCase {
  private let size = CGSize(width: 1000, height: 800)

  func testNothingChangedSavesNothing() {
    XCTAssertEqual(AppState.saveStrategy(adjustments: .init(), baseline: .init(), sourceSize: size), .nothing)
  }

  func testGeometryOnlyEditsAreSavedToImmich() {
    var adjustments = PhotoAdjustments()
    adjustments.geometry.quarterTurns = 2
    XCTAssertEqual(
      AppState.saveStrategy(adjustments: adjustments, baseline: .init(), sourceSize: size),
      .immichEdits([.rotate(degrees: 180)])
    )
  }

  func testRevertingSavedGeometrySendsNoEdits() {
    var saved = PhotoAdjustments()
    saved.geometry.flipVertical = true
    XCTAssertEqual(AppState.saveStrategy(adjustments: .init(), baseline: saved, sourceSize: size), .immichEdits([]))
  }

  func testPixelAdjustmentsAndStraightenNeedANewPhoto() {
    var light = PhotoAdjustments()
    light.light.exposure = 0.2
    XCTAssertEqual(AppState.saveStrategy(adjustments: light, baseline: .init(), sourceSize: size), .newPhoto)

    var straightened = PhotoAdjustments()
    straightened.geometry.straighten = 2
    XCTAssertEqual(AppState.saveStrategy(adjustments: straightened, baseline: .init(), sourceSize: size), .newPhoto)
  }

  func testPasteEditsKeepsTheTargetsCropAndSpots() {
    var source = PhotoAdjustments()
    source.filter = .noir
    source.geometry.quarterTurns = 1
    source.retouch.spots = [.init(center: .init(x: 0.5, y: 0.5), sourceOffset: .init(x: 0.1, y: 0), radius: 0.02)]
    var target = PhotoAdjustments()
    target.geometry.flipHorizontal = true

    let pasted = target.pastingAdjustments(from: source)
    XCTAssertEqual(pasted.filter, .noir)
    XCTAssertEqual(pasted.geometry, target.geometry)
    XCTAssertTrue(pasted.retouch.spots.isEmpty)
  }
}

@MainActor
final class PhotoEditingPipelineTests: XCTestCase {
  private func makeImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 64, height: 48))
    image.lockFocus()
    NSColor(calibratedRed: 0.4, green: 0.5, blue: 0.6, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 64, height: 48).fill()
    image.unlockFocus()
    return image
  }

  func testUndoRedoRestoresAdjustments() async throws {
    let pipeline = PhotoEditingPipeline()
    pipeline.beginSession(original: makeImage(), adjustments: .init())
    pipeline.adjustments.light.exposure = 0.4
    try await Task.sleep(for: .milliseconds(450))
    pipeline.adjustments.filter = .mono
    XCTAssertTrue(pipeline.canUndo)

    pipeline.undo()
    XCTAssertEqual(pipeline.adjustments.filter, .original)
    XCTAssertEqual(pipeline.adjustments.light.exposure, 0.4)
    pipeline.undo()
    XCTAssertEqual(pipeline.adjustments.light.exposure, 0)
    pipeline.redo()
    XCTAssertEqual(pipeline.adjustments.light.exposure, 0.4)
  }

  func testCopyPasteAndRevert() {
    let pipeline = PhotoEditingPipeline()
    pipeline.beginSession(original: makeImage(), adjustments: .init())
    pipeline.adjustments.color.saturation = 0.5
    pipeline.copyEdits()
    pipeline.revertToOriginal()
    XCTAssertFalse(pipeline.hasEdits)
    pipeline.pasteEdits()
    XCTAssertEqual(pipeline.adjustments.color.saturation, 0.5)
  }

  func testCropAspectProducesRequestedOutputRatio() {
    let pipeline = PhotoEditingPipeline()
    pipeline.beginSession(original: makeImage(), adjustments: .init())
    pipeline.setCropAspect(.square)
    let output = pipeline.previewGeometry.outputSize
    XCTAssertEqual(output.width / output.height, 1, accuracy: 0.01)
    pipeline.setCropAspect(.sixteenNine, portrait: true)
    let portrait = pipeline.previewGeometry.outputSize
    XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16.0, accuracy: 0.01)
  }

  func testRetouchClickAddsSpotInSourceCoordinates() {
    let pipeline = PhotoEditingPipeline()
    var initial = PhotoAdjustments()
    initial.geometry.quarterTurns = 1
    pipeline.beginSession(original: makeImage(), adjustments: initial)
    pipeline.canvasTool = .retouch
    pipeline.handleCanvasClick(at: .init(x: 1, y: 0), optionKey: false)
    let spot = try? XCTUnwrap(pipeline.adjustments.retouch.spots.first)
    // Output top-right after a clockwise turn is the source's top-left.
    XCTAssertEqual(spot?.center.x ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(spot?.center.y ?? -1, 0, accuracy: 0.001)
  }
}
