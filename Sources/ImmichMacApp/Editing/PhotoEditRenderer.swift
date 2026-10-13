#if canImport(CoreImage)
import CoreGraphics
@preconcurrency import CoreImage
@preconcurrency import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Stateless Core Image implementation of `PhotoAdjustments`.
///
/// Photos' private imaging stack (PAImaging/NeutrinoCore) isn't public, so every tool is rebuilt
/// from public Core Image filters. Tonal tools that act per channel (Light's tone response, Curves,
/// Levels, Selective Color, Cast) are folded into a single 32³ color cube so they cost one pass.
enum PhotoEditRenderer {
  // MARK: - Full render

  /// Renders `adjustments` onto `source`. `includeGeometry: false` returns the full uncropped,
  /// unrotated image (used while picking spots in source space). `cropPreview: true` returns the
  /// straightened image fitted to its valid area without the crop, for the crop tool.
  static func render(
    _ source: CIImage,
    adjustments: PhotoAdjustments,
    includeGeometry: Bool = true,
    cropPreview: Bool = false
  ) -> CIImage {
    let extent = source.extent
    let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    var image = source.transformed(by: origin)
    let size = image.extent.size

    image = applyRetouch(adjustments.retouch, to: image, size: size)
    image = applyRedEye(adjustments.redEye, to: image, size: size)
    image = applyWhiteBalance(adjustments.whiteBalance, to: image)
    image = applyLightFilters(adjustments.light, to: image, size: size)
    image = applyColorCube(adjustments, to: image)
    image = applyColorControls(adjustments.color, to: image)
    image = applyDefinition(adjustments.definition, to: image, size: size)
    image = applyNoiseReduction(adjustments.noiseReduction, to: image)
    image = applySharpen(adjustments.sharpen, to: image, size: size)
    image = applyFilter(adjustments.filter, to: image)
    image = applyBlackAndWhite(adjustments.blackAndWhite, to: image, size: size)
    image = image.cropped(to: CGRect(origin: .zero, size: size))

    if includeGeometry {
      let mapping = PhotoEditGeometry(sourceSize: size, geometry: adjustments.geometry)
      let transform = cropPreview ? mapping.sourceToValidArea : mapping.sourceToOutput
      let outputSize = cropPreview ? mapping.validRect.size : mapping.outputSize
      image = image
        .clampedToExtent()
        .transformed(by: transform)
        .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    // Photos applies the vignette to the final frame, so it follows the crop.
    return applyVignette(adjustments.vignette, to: image)
  }

  // MARK: - Spot tools

  private static func pixelPoint(_ point: PhotoAdjustments.NormalizedPoint, size: CGSize) -> CGPoint {
    CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
  }

  private static func radialMask(center: CGPoint, radius: Double, hardness: Double) -> CIImage {
    let gradient = CIFilter.radialGradient()
    gradient.center = center
    gradient.radius0 = Float(radius * hardness)
    gradient.radius1 = Float(radius)
    gradient.color0 = CIColor.white
    gradient.color1 = CIColor.black
    return gradient.outputImage ?? CIImage.empty()
  }

  static func applyRetouch(_ retouch: PhotoAdjustments.Retouch, to image: CIImage, size: CGSize) -> CIImage {
    guard retouch.isActive else { return image }
    let shortSide = min(size.width, size.height)
    var result = image
    for spot in retouch.spots {
      let center = pixelPoint(spot.center, size: size)
      let radius = spot.radius * shortSide
      // Copy pixels from the source area onto the spot, feathered at the edge.
      let dx = -spot.sourceOffset.x * size.width
      let dy = spot.sourceOffset.y * size.height
      let patch = result.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: dy))
      let blend = CIFilter.blendWithMask()
      blend.inputImage = patch
      blend.backgroundImage = result
      blend.maskImage = radialMask(center: center, radius: radius, hardness: 0.55)
      result = blend.outputImage?.cropped(to: image.extent) ?? result
    }
    return result
  }

  static func applyRedEye(_ redEye: PhotoAdjustments.RedEye, to image: CIImage, size: CGSize) -> CIImage {
    guard redEye.isActive else { return image }
    var result = image
    if redEye.automatic {
      for filter in image.autoAdjustmentFilters(options: [.enhance: false, .redEye: true]) {
        filter.setValue(result, forKey: kCIInputImageKey)
        result = filter.outputImage ?? result
      }
    }
    guard !redEye.spots.isEmpty else { return result }

    // Replace red with the average of green and blue, which darkens a red pupil to a neutral one.
    let neutralize = CIFilter.colorMatrix()
    neutralize.inputImage = result
    neutralize.rVector = CIVector(x: 0, y: 0.5, z: 0.5, w: 0)
    neutralize.gVector = CIVector(x: 0, y: 0.85, z: 0, w: 0)
    neutralize.bVector = CIVector(x: 0, y: 0, z: 0.85, w: 0)
    guard let corrected = neutralize.outputImage else { return result }

    let shortSide = min(size.width, size.height)
    for spot in redEye.spots {
      let blend = CIFilter.blendWithMask()
      blend.inputImage = corrected
      blend.backgroundImage = result
      blend.maskImage = radialMask(
        center: pixelPoint(spot.center, size: size),
        radius: spot.radius * shortSide,
        hardness: 0.7
      )
      result = blend.outputImage?.cropped(to: image.extent) ?? result
    }
    return result
  }

  // MARK: - White Balance

  /// Typical skin chromaticity used by Skin Tone mode (relative R:G:B).
  static let skinToneTarget = PhotoAdjustments.RGB(red: 1.0, green: 0.78, blue: 0.66)

  /// Per-channel gains that turn `sample` into a neutral gray (or skin tone) of the same luminance.
  static func whiteBalanceGains(
    sample: PhotoAdjustments.RGB,
    mode: PhotoAdjustments.WhiteBalance.Mode
  ) -> PhotoAdjustments.RGB? {
    let luminance = sample.luminance
    guard luminance > 0.001, sample.red > 0.001, sample.green > 0.001, sample.blue > 0.001 else { return nil }
    let target: PhotoAdjustments.RGB
    switch mode {
    case .neutralGray:
      target = .init(red: luminance, green: luminance, blue: luminance)
    case .skinTone:
      let scale = luminance / skinToneTarget.luminance
      target = .init(red: skinToneTarget.red * scale, green: skinToneTarget.green * scale, blue: skinToneTarget.blue * scale)
    case .temperatureTint:
      return nil
    }
    return .init(red: target.red / sample.red, green: target.green / sample.green, blue: target.blue / sample.blue)
  }

  static func applyWhiteBalance(_ balance: PhotoAdjustments.WhiteBalance, to image: CIImage) -> CIImage {
    guard balance.isActive else { return image }
    var result = image
    if balance.mode != .temperatureTint, let sample = balance.sampledColor,
       let gains = whiteBalanceGains(sample: sample, mode: balance.mode) {
      let matrix = CIFilter.colorMatrix()
      matrix.inputImage = result
      matrix.rVector = CIVector(x: gains.red, y: 0, z: 0, w: 0)
      matrix.gVector = CIVector(x: 0, y: gains.green, z: 0, w: 0)
      matrix.bVector = CIVector(x: 0, y: 0, z: gains.blue, w: 0)
      result = matrix.outputImage ?? result
    }
    if balance.warmth != 0 || balance.tint != 0 {
      result = applyTemperature(warmth: balance.warmth, tint: balance.tint, to: result)
    }
    return result
  }

  static func applyTemperature(warmth: Double, tint: Double, to image: CIImage) -> CIImage {
    let filter = CIFilter.temperatureAndTint()
    filter.inputImage = image
    filter.neutral = CIVector(x: 6500 + warmth * 2500, y: tint * 60)
    filter.targetNeutral = CIVector(x: 6500, y: 0)
    return filter.outputImage ?? image
  }

  // MARK: - Light

  private static func applyLightFilters(_ light: PhotoAdjustments.Light, to image: CIImage, size: CGSize) -> CIImage {
    guard light.isActive else { return image }
    let values = light.effective
    var result = image
    if values.exposure != 0 {
      let exposure = CIFilter.exposureAdjust()
      exposure.inputImage = result
      exposure.ev = Float(values.exposure * 2)
      result = exposure.outputImage ?? result
    }
    if values.brilliance != 0 {
      // Brilliance lifts shadows and recovers highlights adaptively, which is what
      // CIHighlightShadowAdjust's local (radius-based) mode does.
      let local = CIFilter.highlightShadowAdjust()
      local.inputImage = result
      local.radius = Float(max(size.width, size.height) / 200)
      local.shadowAmount = Float(max(values.brilliance, 0) * 0.8)
      local.highlightAmount = Float(1 - max(values.brilliance, 0) * 0.45)
      result = local.outputImage ?? result
      if values.brilliance < 0 {
        let flatten = CIFilter.colorControls()
        flatten.inputImage = result
        flatten.contrast = Float(1 + values.brilliance * 0.25)
        result = flatten.outputImage ?? result
      }
    }
    return result
  }

  /// Light's per-channel tone response for highlights, shadows, brightness, contrast, and black point.
  static func lightTone(_ value: Double, light: PhotoAdjustments.Light) -> Double {
    var v = value
    if light.blackPoint > 0 {
      let cut = light.blackPoint * 0.15
      v = (v - cut) / (1 - cut)
    } else if light.blackPoint < 0 {
      v += -light.blackPoint * 0.15 * (1 - v)
    }
    v = min(max(v, 0), 1)
    if light.brightness != 0 {
      v = pow(v, pow(2, -light.brightness * 0.8))
    }
    if light.shadows != 0 {
      v += light.shadows * 0.35 * v * pow(1 - v, 2) * 2.25
    }
    if light.highlights != 0 {
      v += light.highlights * 0.35 * pow(v, 2) * (1 - v) * 2.25
    }
    v = min(max(v, 0), 1)
    if light.contrast > 0 {
      let smooth = v * v * (3 - 2 * v)
      v += (smooth - v) * light.contrast
    } else if light.contrast < 0 {
      v += (0.5 - v) * -light.contrast * 0.4
    }
    return min(max(v, 0), 1)
  }

  // MARK: - Color cube (Light tone, Curves, Levels, Selective Color, Cast)

  static let cubeDimension = 32

  private static func needsCube(_ adjustments: PhotoAdjustments) -> Bool {
    let light = adjustments.light.effective
    let lightTone = adjustments.light.isActive
      && (light.highlights != 0 || light.shadows != 0 || light.brightness != 0 || light.contrast != 0 || light.blackPoint != 0)
    return lightTone || adjustments.curves.isActive || adjustments.levels.isActive
      || adjustments.selectiveColor.isActive || (adjustments.color.isActive && adjustments.color.cast != 0)
  }

  private static func applyColorCube(_ adjustments: PhotoAdjustments, to image: CIImage) -> CIImage {
    guard needsCube(adjustments) else { return image }
    let data = colorCubeData(for: adjustments)
    let cube = CIFilter.colorCubeWithColorSpace()
    cube.inputImage = image
    cube.cubeDimension = Float(cubeDimension)
    cube.cubeData = data
    cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    return cube.outputImage ?? image
  }

  static func colorCubeData(for adjustments: PhotoAdjustments) -> Data {
    let n = cubeDimension
    let light = adjustments.light.isActive ? adjustments.light.effective : nil
    let curves = adjustments.curves.isActive ? CurveLUTs(curves: adjustments.curves) : nil
    let levels = adjustments.levels.isActive ? adjustments.levels : nil
    let selective = adjustments.selectiveColor.isActive ? adjustments.selectiveColor : nil
    let cast = adjustments.color.isActive ? adjustments.color.cast : 0

    var values = [Float](repeating: 0, count: n * n * n * 4)
    var index = 0
    for b in 0..<n {
      for g in 0..<n {
        for r in 0..<n {
          var rgb = PhotoAdjustments.RGB(
            red: Double(r) / Double(n - 1),
            green: Double(g) / Double(n - 1),
            blue: Double(b) / Double(n - 1)
          )
          rgb = mapColor(rgb, light: light, curves: curves, levels: levels, selective: selective, cast: cast)
          values[index] = Float(rgb.red)
          values[index + 1] = Float(rgb.green)
          values[index + 2] = Float(rgb.blue)
          values[index + 3] = 1
          index += 4
        }
      }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func mapColor(
    _ input: PhotoAdjustments.RGB,
    light: PhotoAdjustments.Light?,
    curves: CurveLUTs?,
    levels: PhotoAdjustments.Levels?,
    selective: PhotoAdjustments.SelectiveColor?,
    cast: Double
  ) -> PhotoAdjustments.RGB {
    var rgb = input
    if let light {
      rgb = .init(red: lightTone(rgb.red, light: light), green: lightTone(rgb.green, light: light), blue: lightTone(rgb.blue, light: light))
    }
    if cast != 0 {
      rgb = .init(
        red: min(max(rgb.red + cast * 0.06 * (1 - rgb.red), 0), 1),
        green: rgb.green,
        blue: min(max(rgb.blue - cast * 0.06 * rgb.blue, 0), 1)
      )
    }
    if let curves {
      rgb = curves.apply(rgb)
    }
    if let levels {
      rgb = applyLevels(levels, to: rgb)
    }
    if let selective {
      rgb = applySelectiveColor(selective, to: rgb)
    }
    return rgb
  }

  static func applyLevels(_ levels: PhotoAdjustments.Levels, to input: PhotoAdjustments.RGB) -> PhotoAdjustments.RGB {
    var rgb = PhotoAdjustments.RGB(
      red: levels.red.map(levels.rgb.map(input.red)),
      green: levels.green.map(levels.rgb.map(input.green)),
      blue: levels.blue.map(levels.rgb.map(input.blue))
    )
    if levels.luminance != PhotoAdjustments.Levels.Values() {
      let luminance = rgb.luminance
      if luminance > 0.0001 {
        let ratio = levels.luminance.map(luminance) / luminance
        rgb = .init(red: min(rgb.red * ratio, 1), green: min(rgb.green * ratio, 1), blue: min(rgb.blue * ratio, 1))
      }
    }
    return rgb
  }

  static func applySelectiveColor(_ selective: PhotoAdjustments.SelectiveColor, to input: PhotoAdjustments.RGB) -> PhotoAdjustments.RGB {
    var hsl = HSL(rgb: input)
    guard hsl.saturation > 0.02 else { return input }
    var hueShift = 0.0
    var saturationScale = 0.0
    var luminanceShift = 0.0
    for range in selective.ranges where !range.isDefault {
      let distance = min(abs(hsl.hue - range.hue), 1 - abs(hsl.hue - range.hue))
      let halfWidth = 0.02 + range.range * (1.0 / 6.0)
      let weight = max(0, 1 - distance / halfWidth) * min(hsl.saturation * 2, 1)
      guard weight > 0 else { continue }
      hueShift += range.hueShift * weight * 0.1
      saturationScale += range.saturation * weight
      luminanceShift += range.luminance * weight * 0.25
    }
    hsl.hue = (hsl.hue + hueShift).truncatingRemainder(dividingBy: 1)
    if hsl.hue < 0 { hsl.hue += 1 }
    hsl.saturation = min(max(hsl.saturation * (1 + saturationScale), 0), 1)
    hsl.lightness = min(max(hsl.lightness + luminanceShift * hsl.saturation, 0), 1)
    return hsl.rgb
  }

  // MARK: - Color, detail, filters

  private static func applyColorControls(_ color: PhotoAdjustments.Color, to image: CIImage) -> CIImage {
    guard color.isActive else { return image }
    let values = color.effective
    var result = image
    if values.saturation != 0 {
      let controls = CIFilter.colorControls()
      controls.inputImage = result
      controls.saturation = Float(1 + values.saturation)
      result = controls.outputImage ?? result
    }
    if values.vibrance != 0 {
      let vibrance = CIFilter.vibrance()
      vibrance.inputImage = result
      vibrance.amount = Float(values.vibrance)
      result = vibrance.outputImage ?? result
    }
    return result
  }

  private static func applyDefinition(_ definition: PhotoAdjustments.Definition, to image: CIImage, size: CGSize) -> CIImage {
    guard definition.isActive else { return image }
    // Definition is local contrast: a wide, gentle unsharp mask.
    let filter = CIFilter.unsharpMask()
    filter.inputImage = image
    filter.radius = Float(max(size.width, size.height) / 60)
    filter.intensity = Float(definition.amount * 0.6)
    return filter.outputImage ?? image
  }

  private static func applyNoiseReduction(_ reduction: PhotoAdjustments.NoiseReduction, to image: CIImage) -> CIImage {
    guard reduction.isActive else { return image }
    let filter = CIFilter.noiseReduction()
    filter.inputImage = image
    filter.noiseLevel = Float(reduction.amount * 0.05)
    filter.sharpness = 0.4
    return filter.outputImage ?? image
  }

  private static func applySharpen(_ sharpen: PhotoAdjustments.Sharpen, to image: CIImage, size: CGSize) -> CIImage {
    guard sharpen.isActive else { return image }
    let filter = CIFilter.sharpenLuminance()
    filter.inputImage = image
    // Edges widens the radius; Falloff softens how hard the result is pushed.
    filter.radius = Float((0.5 + sharpen.edges * 2.5) * max(1, max(size.width, size.height) / 2000))
    filter.sharpness = Float(sharpen.intensity * 1.5 * (1 - sharpen.falloff * 0.5))
    return filter.outputImage ?? image
  }

  static func applyFilter(_ filter: PhotoFilter, to image: CIImage) -> CIImage {
    func vivid(_ input: CIImage) -> CIImage {
      let vibrance = CIFilter.vibrance()
      vibrance.inputImage = input
      vibrance.amount = 0.6
      let controls = CIFilter.colorControls()
      controls.inputImage = vibrance.outputImage ?? input
      controls.contrast = 1.08
      controls.saturation = 1.12
      return controls.outputImage ?? input
    }
    func dramatic(_ input: CIImage) -> CIImage {
      let lift = CIFilter.highlightShadowAdjust()
      lift.inputImage = input
      lift.shadowAmount = 0.35
      lift.highlightAmount = 0.8
      let controls = CIFilter.colorControls()
      controls.inputImage = lift.outputImage ?? input
      controls.contrast = 1.32
      controls.saturation = 0.78
      controls.brightness = -0.03
      return controls.outputImage ?? input
    }
    func photoEffect(_ effect: CIFilter & CIPhotoEffect) -> CIImage {
      effect.inputImage = image
      return effect.outputImage ?? image
    }

    switch filter {
    case .original: return image
    case .vivid: return vivid(image)
    case .vividWarm: return applyTemperature(warmth: 0.35, tint: 0, to: vivid(image))
    case .vividCool: return applyTemperature(warmth: -0.35, tint: 0, to: vivid(image))
    case .dramatic: return dramatic(image)
    case .dramaticWarm: return applyTemperature(warmth: 0.35, tint: 0, to: dramatic(image))
    case .dramaticCool: return applyTemperature(warmth: -0.35, tint: 0, to: dramatic(image))
    case .mono: return photoEffect(CIFilter.photoEffectMono())
    case .silvertone: return photoEffect(CIFilter.photoEffectTonal())
    case .noir: return photoEffect(CIFilter.photoEffectNoir())
    }
  }

  private static func applyBlackAndWhite(_ bw: PhotoAdjustments.BlackAndWhite, to image: CIImage, size: CGSize) -> CIImage {
    guard bw.isActive else { return image }
    let values = bw.effective
    // Tone shifts the gray mix between a red filter (+) and a blue filter (−), like B&W film filters.
    let red = 0.30 + values.tone * 0.25
    let blue = 0.11 - values.tone * 0.08
    let green = 1 - red - blue
    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    let weights = CIVector(x: red, y: green, z: blue, w: 0)
    matrix.rVector = weights
    matrix.gVector = weights
    matrix.bVector = weights
    var result = matrix.outputImage ?? image

    if values.neutrals != 0 {
      let gamma = CIFilter.gammaAdjust()
      gamma.inputImage = result
      gamma.power = Float(pow(2, -values.neutrals * 0.6))
      result = gamma.outputImage ?? result
    }
    if values.intensity != 0 {
      let controls = CIFilter.colorControls()
      controls.inputImage = result
      controls.contrast = Float(1 + values.intensity * 0.45)
      result = controls.outputImage ?? result
    }
    if values.grain > 0 {
      result = addGrain(amount: values.grain, to: result, size: size)
    }
    return result
  }

  private static func addGrain(amount: Double, to image: CIImage, size: CGSize) -> CIImage {
    guard let noise = CIFilter.randomGenerator().outputImage else { return image }
    let gray = CIFilter.colorMatrix()
    gray.inputImage = noise
    let weights = CIVector(x: 0, y: 1, z: 0, w: 0)
    gray.rVector = weights
    gray.gVector = weights
    gray.bVector = weights
    gray.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    gray.biasVector = CIVector(x: 0, y: 0, z: 0, w: amount * 0.35)
    let grainScale = max(1, min(size.width, size.height) / 1500)
    guard let grain = gray.outputImage?.transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale)) else {
      return image
    }
    let blend = CIFilter.softLightBlendMode()
    blend.inputImage = grain.cropped(to: image.extent)
    blend.backgroundImage = image
    return blend.outputImage ?? image
  }

  private static func applyVignette(_ vignette: PhotoAdjustments.Vignette, to image: CIImage) -> CIImage {
    guard vignette.isActive else { return image }
    let extent = image.extent
    let filter = CIFilter.vignetteEffect()
    filter.inputImage = image
    filter.center = CGPoint(x: extent.midX, y: extent.midY)
    filter.radius = Float(hypot(extent.width, extent.height) / 2 * (0.35 + vignette.radius * 0.65))
    filter.intensity = Float(vignette.strength)
    filter.falloff = Float(0.15 + vignette.softness * 0.85)
    return filter.outputImage?.cropped(to: extent) ?? image
  }

  // MARK: - Analysis

  /// Photos' Auto Enhance: reads Core Image's automatic adjustment analysis and maps it onto
  /// the Light and Color sliders, so the result stays editable like Photos' AUTO button.
  static func autoEnhancedAdjustments(for source: CIImage, base: PhotoAdjustments) -> PhotoAdjustments {
    var result = base
    let analysis = downsampled(source, maxDimension: 1024)
    var light = PhotoAdjustments.Light()
    var color = base.color
    color.isEnabled = true
    for filter in analysis.autoAdjustmentFilters(options: [.redEye: false]) {
      switch filter.name {
      case "CIHighlightShadowAdjust":
        let shadows = (filter.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue ?? 0
        let highlights = (filter.value(forKey: "inputHighlightAmount") as? NSNumber)?.doubleValue ?? 1
        light.shadows = clamp(shadows * 0.8)
        light.highlights = clamp(-(1 - highlights))
      case "CIVibrance":
        color.vibrance = clamp((filter.value(forKey: "inputAmount") as? NSNumber)?.doubleValue ?? 0)
      case "CIToneCurve":
        if let mid = filter.value(forKey: "inputPoint2") as? CIVector {
          light.exposure = clamp((Double(mid.y) - Double(mid.x)) * 1.5)
        }
      case "CIFaceBalance":
        light.brilliance = 0.15
      default:
        break
      }
    }
    if light == PhotoAdjustments.Light() {
      light.brilliance = 0.1
    }
    result.light = light
    result.color = color
    return result
  }

  /// Photos' Crop ▸ Auto: horizon detection from Vision, as a straighten angle in degrees.
  static func detectHorizonAngle(in source: CIImage) -> Double? {
    let request = VNDetectHorizonRequest()
    let handler = VNImageRequestHandler(ciImage: downsampled(source, maxDimension: 1024))
    try? handler.perform([request])
    guard let observation = request.results?.first else { return nil }
    let degrees = -Double(observation.angle) * 180 / .pi
    return abs(degrees) <= 45 ? degrees : nil
  }

  /// Average color around a normalized source point (eyedropper).
  static func sampleColor(
    in source: CIImage,
    at point: PhotoAdjustments.NormalizedPoint,
    context: CIContext
  ) -> PhotoAdjustments.RGB? {
    let extent = source.extent
    let radius = max(2, min(extent.width, extent.height) * 0.006)
    let center = CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2).intersection(extent)
    guard !rect.isEmpty else { return nil }
    let average = CIFilter.areaAverage()
    average.inputImage = source
    average.extent = rect
    guard let output = average.outputImage else { return nil }
    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      output,
      toBitmap: &pixel,
      rowBytes: 16,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return .init(red: Double(pixel[0]), green: Double(pixel[1]), blue: Double(pixel[2]))
  }

  /// RGB histogram with `bins` buckets per channel, each normalized so the tallest bucket is 1.
  static func histogram(of image: CIImage, bins: Int = 64, context: CIContext) -> Histogram? {
    let small = downsampled(image, maxDimension: 512)
    let filter = CIFilter.areaHistogram()
    filter.inputImage = small
    filter.extent = small.extent
    filter.count = bins
    filter.scale = 1
    guard let output = filter.outputImage else { return nil }
    var values = [Float](repeating: 0, count: bins * 4)
    context.render(
      output,
      toBitmap: &values,
      rowBytes: bins * 16,
      bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )
    func channel(_ offset: Int) -> [Double] {
      stride(from: offset, to: values.count, by: 4).map { Double(values[$0]) }
    }
    return Histogram(red: channel(0), green: channel(1), blue: channel(2)).normalized()
  }

  static func downsampled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
    let extent = image.extent
    let largest = max(extent.width, extent.height)
    guard largest > maxDimension, largest.isFinite else { return image }
    let scale = maxDimension / largest
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  }
}

// MARK: - Supporting types

struct Histogram: Equatable, Sendable {
  var red: [Double]
  var green: [Double]
  var blue: [Double]

  var luminance: [Double] {
    zip(zip(red, green), blue).map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $1 }
  }

  func normalized() -> Histogram {
    let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
    guard peak > 0 else { return self }
    return Histogram(red: red.map { $0 / peak }, green: green.map { $0 / peak }, blue: blue.map { $0 / peak })
  }
}

/// Per-channel lookup tables built from Curves control points with monotone cubic interpolation,
/// so curves never overshoot between points (as in Photos' Curves brick).
struct CurveLUTs: Sendable {
  static let resolution = 256
  let rgb: [Double]
  let red: [Double]
  let green: [Double]
  let blue: [Double]

  init(curves: PhotoAdjustments.Curves) {
    rgb = Self.lut(curves.rgb)
    red = Self.lut(curves.red)
    green = Self.lut(curves.green)
    blue = Self.lut(curves.blue)
  }

  func apply(_ input: PhotoAdjustments.RGB) -> PhotoAdjustments.RGB {
    .init(
      red: Self.lookup(red, Self.lookup(rgb, input.red)),
      green: Self.lookup(green, Self.lookup(rgb, input.green)),
      blue: Self.lookup(blue, Self.lookup(rgb, input.blue))
    )
  }

  static func lookup(_ table: [Double], _ value: Double) -> Double {
    let position = min(max(value, 0), 1) * Double(table.count - 1)
    let lower = Int(position)
    let upper = min(lower + 1, table.count - 1)
    let fraction = position - Double(lower)
    return table[lower] + (table[upper] - table[lower]) * fraction
  }

  static func lut(_ points: [PhotoAdjustments.CurvePoint]) -> [Double] {
    (0..<resolution).map { index in
      evaluate(points, at: Double(index) / Double(resolution - 1))
    }
  }

  /// Fritsch–Carlson monotone cubic interpolation through sorted control points.
  static func evaluate(_ unsorted: [PhotoAdjustments.CurvePoint], at x: Double) -> Double {
    let points = unsorted.sorted { $0.x < $1.x }
    guard let first = points.first, let last = points.last else { return x }
    if points.count == 1 { return min(max(first.y, 0), 1) }
    if x <= first.x { return min(max(first.y, 0), 1) }
    if x >= last.x { return min(max(last.y, 0), 1) }

    let count = points.count
    var deltas = [Double](repeating: 0, count: count - 1)
    for i in 0..<(count - 1) {
      let dx = points[i + 1].x - points[i].x
      deltas[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
    }
    var tangents = [Double](repeating: 0, count: count)
    tangents[0] = deltas[0]
    tangents[count - 1] = deltas[count - 2]
    for i in 1..<(count - 1) {
      tangents[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2
    }
    for i in 0..<(count - 1) where deltas[i] == 0 {
      tangents[i] = 0
      tangents[i + 1] = 0
    }
    for i in 0..<(count - 1) where deltas[i] != 0 {
      let a = tangents[i] / deltas[i]
      let b = tangents[i + 1] / deltas[i]
      let sum = a * a + b * b
      if sum > 9 {
        let t = 3 / sqrt(sum)
        tangents[i] = t * a * deltas[i]
        tangents[i + 1] = t * b * deltas[i]
      }
    }

    var segment = 0
    while segment < count - 2, x > points[segment + 1].x { segment += 1 }
    let p0 = points[segment]
    let p1 = points[segment + 1]
    let h = p1.x - p0.x
    guard h > 0 else { return min(max(p0.y, 0), 1) }
    let t = (x - p0.x) / h
    let t2 = t * t
    let t3 = t2 * t
    let value = (2 * t3 - 3 * t2 + 1) * p0.y
      + (t3 - 2 * t2 + t) * h * tangents[segment]
      + (-2 * t3 + 3 * t2) * p1.y
      + (t3 - t2) * h * tangents[segment + 1]
    return min(max(value, 0), 1)
  }
}

struct HSL: Equatable {
  var hue: Double
  var saturation: Double
  var lightness: Double

  init(hue: Double, saturation: Double, lightness: Double) {
    self.hue = hue
    self.saturation = saturation
    self.lightness = lightness
  }

  init(rgb: PhotoAdjustments.RGB) {
    let maximum = max(rgb.red, rgb.green, rgb.blue)
    let minimum = min(rgb.red, rgb.green, rgb.blue)
    lightness = (maximum + minimum) / 2
    let delta = maximum - minimum
    guard delta > 0.000001 else {
      hue = 0
      saturation = 0
      return
    }
    saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
    var h: Double
    if maximum == rgb.red {
      h = (rgb.green - rgb.blue) / delta + (rgb.green < rgb.blue ? 6 : 0)
    } else if maximum == rgb.green {
      h = (rgb.blue - rgb.red) / delta + 2
    } else {
      h = (rgb.red - rgb.green) / delta + 4
    }
    hue = h / 6
  }

  var rgb: PhotoAdjustments.RGB {
    guard saturation > 0 else { return .init(red: lightness, green: lightness, blue: lightness) }
    let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
    let p = 2 * lightness - q
    func channel(_ offset: Double) -> Double {
      var t = hue + offset
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      if t < 1.0 / 6 { return p + (q - p) * 6 * t }
      if t < 0.5 { return q }
      if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
      return p
    }
    return .init(red: channel(1.0 / 3), green: channel(0), blue: channel(-1.0 / 3))
  }
}
#endif
