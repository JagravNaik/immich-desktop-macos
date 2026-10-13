import CoreGraphics
import Foundation

/// The complete, non-destructive edit state of one photo, modeled on Photos for macOS.
///
/// Section names and slider titles come from Photos' `IPXCCAdjustment.loctable` and
/// `IPXMain.loctable` (see docs/photos-reverse-engineering.md, "Image editor"). As in Photos,
/// Light, Color, and Black & White expose one master slider; each Options sub-slider is an
/// offset added on top of what the master contributes (`IPASmartBlackAndWhiteOperation_offset*`).
/// Every slider is unitless: -1…1 for bipolar controls and 0…1 for amounts.
struct PhotoAdjustments: Equatable, Codable, Sendable {
  var light = Light()
  var color = Color()
  var blackAndWhite = BlackAndWhite()
  var whiteBalance = WhiteBalance()
  var curves = Curves()
  var levels = Levels()
  var definition = Definition()
  var selectiveColor = SelectiveColor()
  var noiseReduction = NoiseReduction()
  var sharpen = Sharpen()
  var vignette = Vignette()
  var redEye = RedEye()
  var retouch = Retouch()
  var filter: PhotoFilter = .original
  var geometry = Geometry()

  static let identity = PhotoAdjustments()

  var isIdentity: Bool { self == .identity }

  /// Everything except crop/rotate/flip — the part Immich cannot store server-side.
  var hasPixelAdjustments: Bool {
    var withoutGeometry = self
    withoutGeometry.geometry = Geometry()
    return withoutGeometry != .identity
  }

  var hasGeometry: Bool { geometry != Geometry() }

  /// Photos' Copy Edits/Paste Edits copies adjustments but not crop or spot fixes, which are
  /// tied to one image's pixels.
  func pastingAdjustments(from source: PhotoAdjustments) -> PhotoAdjustments {
    var result = source
    result.geometry = geometry
    result.redEye = redEye
    result.retouch = retouch
    return result
  }

  // MARK: - Light

  struct Light: Equatable, Codable, Sendable {
    var isEnabled = true
    var master: Double = 0
    var brilliance: Double = 0
    var exposure: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var blackPoint: Double = 0

    var isActive: Bool { isEnabled && self != Light() }

    /// How far the master slider pushes each option. The ratios are design estimates; Photos
    /// computes its master response from image statistics we cannot observe statically.
    static let masterWeights = (
      brilliance: 0.35, exposure: 0.45, highlights: -0.30, shadows: 0.40,
      brightness: 0.15, contrast: 0.10, blackPoint: 0.10
    )

    var effective: Light {
      let w = Self.masterWeights
      var result = self
      result.brilliance = clamp(brilliance + master * w.brilliance)
      result.exposure = clamp(exposure + master * w.exposure)
      result.highlights = clamp(highlights + master * w.highlights)
      result.shadows = clamp(shadows + master * w.shadows)
      result.brightness = clamp(brightness + master * w.brightness)
      result.contrast = clamp(contrast + master * w.contrast)
      result.blackPoint = clamp(blackPoint + master * w.blackPoint)
      return result
    }
  }

  // MARK: - Color

  struct Color: Equatable, Codable, Sendable {
    var isEnabled = true
    var master: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    /// Photos' "Cast": shifts the image between cool (-1) and warm (+1) without moving white.
    var cast: Double = 0

    var isActive: Bool { isEnabled && self != Color() }

    var effective: Color {
      var result = self
      result.saturation = clamp(saturation + master * 0.6)
      result.vibrance = clamp(vibrance + master * 0.4)
      return result
    }
  }

  // MARK: - Black & White

  struct BlackAndWhite: Equatable, Codable, Sendable {
    /// Unlike the other bricks, B&W does nothing until the user turns it on or moves a slider.
    var isEnabled = false
    var master: Double = 0
    var intensity: Double = 0
    var neutrals: Double = 0
    var tone: Double = 0
    var grain: Double = 0

    var isActive: Bool { isEnabled }

    var effective: BlackAndWhite {
      var result = self
      result.intensity = clamp(intensity + master * 0.5)
      result.tone = clamp(tone + master * 0.5)
      return result
    }
  }

  // MARK: - White Balance

  struct WhiteBalance: Equatable, Codable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable, Identifiable {
      case neutralGray = "Neutral Gray"
      case skinTone = "Skin Tone"
      case temperatureTint = "Temperature / Tint"
      var id: String { rawValue }
    }

    var isEnabled = true
    var mode: Mode = .neutralGray
    /// Color sampled with the eyedropper (Neutral Gray / Skin Tone), linear-ish sRGB 0…1.
    var sampledColor: RGB?
    /// Warmth for Neutral Gray / Skin Tone, temperature for Temperature / Tint (-1 cool … 1 warm).
    var warmth: Double = 0
    var tint: Double = 0

    var isActive: Bool { isEnabled && (sampledColor != nil || warmth != 0 || tint != 0) }
  }

  struct RGB: Equatable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
  }

  // MARK: - Curves

  struct Curves: Equatable, Codable, Sendable {
    enum Channel: String, CaseIterable, Codable, Sendable, Identifiable {
      case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
      var id: String { rawValue }
    }

    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    var isEnabled = true
    var rgb = Curves.identityPoints
    var red = Curves.identityPoints
    var green = Curves.identityPoints
    var blue = Curves.identityPoints

    var isActive: Bool { isEnabled && self != Curves() }

    func points(for channel: Channel) -> [CurvePoint] {
      switch channel {
      case .rgb: rgb
      case .red: red
      case .green: green
      case .blue: blue
      }
    }

    mutating func setPoints(_ points: [CurvePoint], for channel: Channel) {
      let sorted = points.sorted { $0.x < $1.x }
      switch channel {
      case .rgb: rgb = sorted
      case .red: red = sorted
      case .green: green = sorted
      case .blue: blue = sorted
      }
    }
  }

  struct CurvePoint: Equatable, Codable, Sendable, Hashable {
    var x: Double
    var y: Double
  }

  // MARK: - Levels

  struct Levels: Equatable, Codable, Sendable {
    enum Channel: String, CaseIterable, Codable, Sendable, Identifiable {
      case rgb = "RGB", luminance = "Luminance", red = "Red", green = "Green", blue = "Blue"
      var id: String { rawValue }
    }

    struct Values: Equatable, Codable, Sendable {
      var black: Double = 0
      /// Midtone position between black and white (0.5 = linear).
      var gray: Double = 0.5
      var white: Double = 1

      /// Maps an input level through black/gray/white, like Photos' Levels brick.
      func map(_ value: Double) -> Double {
        let span = max(white - black, 0.0001)
        let normalized = min(max((value - black) / span, 0), 1)
        let midpoint = min(max(gray, 0.01), 0.99)
        let gamma = log(0.5) / log(midpoint)
        return pow(normalized, gamma)
      }
    }

    var isEnabled = true
    var rgb = Values()
    var luminance = Values()
    var red = Values()
    var green = Values()
    var blue = Values()

    var isActive: Bool { isEnabled && self != Levels() }

    func values(for channel: Channel) -> Values {
      switch channel {
      case .rgb: rgb
      case .luminance: luminance
      case .red: red
      case .green: green
      case .blue: blue
      }
    }

    mutating func setValues(_ values: Values, for channel: Channel) {
      switch channel {
      case .rgb: rgb = values
      case .luminance: luminance = values
      case .red: red = values
      case .green: green = values
      case .blue: blue = values
      }
    }
  }

  // MARK: - Detail and finishing

  struct Definition: Equatable, Codable, Sendable {
    var isEnabled = true
    var amount: Double = 0
    var isActive: Bool { isEnabled && amount != 0 }
  }

  struct NoiseReduction: Equatable, Codable, Sendable {
    var isEnabled = true
    var amount: Double = 0
    var isActive: Bool { isEnabled && amount != 0 }
  }

  struct Sharpen: Equatable, Codable, Sendable {
    var isEnabled = true
    var intensity: Double = 0
    var edges: Double = 0.5
    var falloff: Double = 0.5
    var isActive: Bool { isEnabled && intensity != 0 }
  }

  struct Vignette: Equatable, Codable, Sendable {
    var isEnabled = true
    /// Positive darkens edges, negative lightens them.
    var strength: Double = 0
    var radius: Double = 0.5
    var softness: Double = 0.5
    var isActive: Bool { isEnabled && strength != 0 }
  }

  // MARK: - Selective Color

  struct SelectiveColor: Equatable, Codable, Sendable {
    struct Range: Equatable, Codable, Sendable, Identifiable {
      /// Target hue, 0…1 around the color wheel.
      var hue: Double
      var hueShift: Double = 0
      var saturation: Double = 0
      var luminance: Double = 0
      /// Width of the affected hue band, 0…1 (0.5 ≈ ±30°).
      var range: Double = 0.5

      var id: Double { hue }
      var isDefault: Bool { hueShift == 0 && saturation == 0 && luminance == 0 }
    }

    /// Photos offers six hue swatches plus a custom eyedropper hue.
    static let defaultHues: [Double] = [0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6]

    var isEnabled = true
    var ranges: [Range] = SelectiveColor.defaultHues.map { Range(hue: $0) }

    var isActive: Bool { isEnabled && ranges.contains { !$0.isDefault } }
  }

  // MARK: - Spot tools

  /// Normalized point in the source image, y-down (0,0 = top-left).
  struct NormalizedPoint: Equatable, Codable, Sendable, Hashable {
    var x: Double
    var y: Double
  }

  struct RedEye: Equatable, Codable, Sendable {
    struct Spot: Equatable, Codable, Sendable, Hashable {
      var center: NormalizedPoint
      /// Radius as a fraction of the source image's shorter side.
      var radius: Double
    }

    var isEnabled = true
    var spots: [Spot] = []
    /// Photos' "Auto" button: Core Image's automatic red-eye detection.
    var automatic = false

    var isActive: Bool { isEnabled && (automatic || !spots.isEmpty) }
  }

  struct Retouch: Equatable, Codable, Sendable {
    struct Spot: Equatable, Codable, Sendable, Hashable {
      var center: NormalizedPoint
      /// Pixels are copied from `center + sourceOffset` (Photos' Option-click source).
      var sourceOffset: NormalizedPoint
      var radius: Double
    }

    var isEnabled = true
    var spots: [Spot] = []
    /// Brush size, as a fraction of the shorter side (Photos' "Size" slider).
    var brushSize: Double = 0.03

    var isActive: Bool { isEnabled && !spots.isEmpty }
  }

  // MARK: - Geometry

  struct Geometry: Equatable, Codable, Sendable {
    /// Straighten angle in degrees, -45…45. Positive rotates clockwise.
    var straighten: Double = 0
    /// Clockwise quarter turns, 0…3.
    var quarterTurns: Int = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Crop inside the straightened, valid image area. Normalized, y-down.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: CropAspect = .freeform
    var isPortrait = false

    var isFullFrame: Bool { crop == CGRect(x: 0, y: 0, width: 1, height: 1) }

    /// Rotates by quarter turns (positive = clockwise), carrying the crop with the image.
    func rotated(by turns: Int) -> Geometry {
      var result = self
      let normalizedTurns = ((turns % 4) + 4) % 4
      for _ in 0..<normalizedTurns {
        // A clockwise quarter turn maps a normalized y-down point (x, y) to (1 - y, x).
        let crop = result.crop
        result.crop = CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
        result.quarterTurns = (result.quarterTurns + 1) % 4
        result.isPortrait.toggle()
      }
      return result
    }
  }
}

/// Photos' nine filters plus Original, named as in `IPXEffect.loctable`.
enum PhotoFilter: String, CaseIterable, Codable, Sendable, Identifiable {
  case original = "Original"
  case vivid = "Vivid"
  case vividWarm = "Vivid Warm"
  case vividCool = "Vivid Cool"
  case dramatic = "Dramatic"
  case dramaticWarm = "Dramatic Warm"
  case dramaticCool = "Dramatic Cool"
  case mono = "Mono"
  case silvertone = "Silvertone"
  case noir = "Noir"

  var id: String { rawValue }
}

/// Photos' crop aspect menu (`IPXCropAspect*`). Ratios are width:height in landscape.
enum CropAspect: String, CaseIterable, Codable, Sendable, Identifiable {
  case freeform = "Freeform"
  case original = "Original"
  case square = "Square"
  case sixteenNine = "16:9"
  case fourFive = "4:5"
  case fiveSeven = "5:7"
  case fourThree = "4:3"
  case threeFive = "3:5"
  case threeTwo = "3:2"

  var id: String { rawValue }

  /// Landscape-oriented ratio, or nil when unconstrained / source-dependent.
  func ratio(sourceAspect: Double) -> Double? {
    switch self {
    case .freeform: nil
    case .original: sourceAspect
    case .square: 1
    case .sixteenNine: 16.0 / 9.0
    case .fourFive: 5.0 / 4.0
    case .fiveSeven: 7.0 / 5.0
    case .fourThree: 4.0 / 3.0
    case .threeFive: 5.0 / 3.0
    case .threeTwo: 3.0 / 2.0
    }
  }

  /// Whether the aspect has distinct landscape/portrait orientations.
  var hasOrientation: Bool {
    switch self {
    case .freeform, .original, .square: false
    default: true
    }
  }
}

func clamp(_ value: Double, _ lower: Double = -1, _ upper: Double = 1) -> Double {
  min(max(value, lower), upper)
}
