#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// The image area while editing: the live render, plus Photos' interactive overlays for the
/// crop frame (`IPXCropView`), retouch brush, red-eye clicks, and eyedroppers.
struct EditorCanvasView: View {
  @ObservedObject var pipeline: PhotoEditingPipeline
  let isLoading: Bool
  let fallbackImage: NSImage?

  @State private var hoverLocation: CGPoint?
  @State private var lastBrushPoint: CGPoint?
  @FocusState private var isFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      let image = pipeline.displayImage ?? fallbackImage
      let rect = fittedRect(for: image?.size ?? .zero, in: geometry.size)
      ZStack(alignment: .topLeading) {
        if let image {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(nil, value: pipeline.editedImage)
        }

        if pipeline.isShowingOriginal {
          Text("Original")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .position(x: rect.midX, y: max(rect.minY - 14, 14))
        }

        if !pipeline.isShowingOriginal, pipeline.isSourceLoaded {
          switch pipeline.canvasTool {
          case .crop:
            CropOverlay(pipeline: pipeline, imageRect: rect)
          case .retouch, .redEye, .whiteBalancePicker, .selectiveColorPicker:
            spotToolLayer(rect: rect, size: geometry.size)
          case .none:
            EmptyView()
          }
        }

        if isLoading {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
      }
    }
    .padding(24)
    .focusable()
    .focusEffectDisabled()
    .focused($isFocused)
    .onAppear { isFocused = true }
    // Photos: hold M to see the original.
    .onKeyPress("m", phases: [.down, .up]) { press in
      pipeline.isShowingOriginal = press.phase == .down
      return .handled
    }
    .onKeyPress(.escape) {
      guard pipeline.canvasTool != .none, pipeline.canvasTool != .crop else { return .ignored }
      pipeline.canvasTool = .none
      return .handled
    }
  }

  private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
      return CGRect(origin: .zero, size: container)
    }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
  }

  // MARK: - Spot tools

  private func normalized(_ location: CGPoint, in rect: CGRect) -> PhotoAdjustments.NormalizedPoint? {
    guard rect.width > 0, rect.height > 0, rect.contains(location) else { return nil }
    return .init(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
  }

  private func brushDiameter(in rect: CGRect) -> CGFloat {
    let output = pipeline.previewGeometry.outputSize
    let shortSource = min(pipeline.sourceSize.width, pipeline.sourceSize.height)
    guard output.width > 0 else { return 20 }
    let pixelsPerPoint = output.width / rect.width
    return CGFloat(pipeline.adjustments.retouch.brushSize * shortSource * 2) / pixelsPerPoint
  }

  private func spotToolLayer(rect: CGRect, size: CGSize) -> some View {
    ZStack(alignment: .topLeading) {
      Color.clear
        .contentShape(Rectangle())
        .frame(width: size.width, height: size.height)
        .onContinuousHover { phase in
          if case .active(let location) = phase { hoverLocation = location } else { hoverLocation = nil }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let option = NSEvent.modifierFlags.contains(.option)
              if pipeline.canvasTool == .retouch, !option {
                // Click & drag paints a stroke: drop a spot every half brush width.
                let spacing = brushDiameter(in: rect) / 2
                if let last = lastBrushPoint, hypot(value.location.x - last.x, value.location.y - last.y) < spacing {
                  return
                }
                lastBrushPoint = value.location
                if let point = normalized(value.location, in: rect) {
                  pipeline.handleCanvasClick(at: point, optionKey: false)
                }
              } else if value.translation == .zero, let point = normalized(value.location, in: rect) {
                pipeline.handleCanvasClick(at: point, optionKey: option)
              }
            }
            .onEnded { _ in lastBrushPoint = nil }
        )

      if pipeline.canvasTool == .retouch, let hoverLocation {
        let diameter = brushDiameter(in: rect)
        Circle()
          .stroke(Color.white, lineWidth: 1)
          .shadow(color: .black, radius: 1)
          .frame(width: diameter, height: diameter)
          .position(hoverLocation)
          .allowsHitTesting(false)
      }
    }
    .onHover { inside in
      switch pipeline.canvasTool {
      case .whiteBalancePicker, .selectiveColorPicker, .redEye:
        inside ? NSCursor.crosshair.push() : NSCursor.pop()
      default:
        break
      }
    }
  }
}

// MARK: - Crop overlay

/// Photos' crop frame: dimmed surround, rule-of-thirds grid, L-shaped corner handles and edge
/// handles, drag inside to move. The aspect constraint comes from the Aspect menu.
private struct CropOverlay: View {
  @ObservedObject var pipeline: PhotoEditingPipeline
  let imageRect: CGRect

  @State private var dragStart: CGRect?
  @State private var isDragging = false

  private static let minimumSize = 0.05

  var body: some View {
    let crop = pipeline.adjustments.geometry.crop
    let frame = CGRect(
      x: imageRect.minX + crop.minX * imageRect.width,
      y: imageRect.minY + crop.minY * imageRect.height,
      width: crop.width * imageRect.width,
      height: crop.height * imageRect.height
    )
    ZStack(alignment: .topLeading) {
      Path { path in
        path.addRect(imageRect)
        path.addRect(frame)
      }
      .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
      .allowsHitTesting(false)

      thirds(frame)
        .stroke(Color.white.opacity(isDragging ? 0.6 : 0.25), lineWidth: 0.5)
        .allowsHitTesting(false)

      Rectangle()
        .stroke(Color.white, lineWidth: 1)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)

      Color.clear
        .contentShape(Rectangle())
        .frame(width: max(frame.width - 24, 1), height: max(frame.height - 24, 1))
        .position(x: frame.midX, y: frame.midY)
        .gesture(dragGesture(.move))
        .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }

      ForEach(handles(for: frame), id: \.0) { item in
        handleView(item.1, at: item.2)
      }
    }
    .animation(isDragging ? nil : ImmichMotion.Curves.structuralShort, value: crop)
  }

  private func handles(for frame: CGRect) -> [(Int, CropHandle, CGPoint)] {
    [
      (0, .topLeft, CGPoint(x: frame.minX, y: frame.minY)),
      (1, .topRight, CGPoint(x: frame.maxX, y: frame.minY)),
      (2, .bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
      (3, .bottomRight, CGPoint(x: frame.maxX, y: frame.maxY)),
      (4, .top, CGPoint(x: frame.midX, y: frame.minY)),
      (5, .bottom, CGPoint(x: frame.midX, y: frame.maxY)),
      (6, .left, CGPoint(x: frame.minX, y: frame.midY)),
      (7, .right, CGPoint(x: frame.maxX, y: frame.midY)),
    ]
  }

  @ViewBuilder
  private func handleView(_ handle: CropHandle, at point: CGPoint) -> some View {
    let isCorner: Bool = {
      switch handle {
      case .topLeft, .topRight, .bottomLeft, .bottomRight: true
      default: false
      }
    }()
    CornerHandleShape(handle: handle)
      .stroke(Color.white, style: StrokeStyle(lineWidth: isCorner ? 3 : 2.5, lineCap: .square))
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
      .position(point)
      .gesture(dragGesture(handle))
      .accessibilityLabel("Crop handle")
  }

  private func thirds(_ frame: CGRect) -> Path {
    Path { path in
      for step in 1...2 {
        let x = frame.minX + frame.width * CGFloat(step) / 3
        let y = frame.minY + frame.height * CGFloat(step) / 3
        path.move(to: CGPoint(x: x, y: frame.minY)); path.addLine(to: CGPoint(x: x, y: frame.maxY))
        path.move(to: CGPoint(x: frame.minX, y: y)); path.addLine(to: CGPoint(x: frame.maxX, y: y))
      }
    }
  }

  private func dragGesture(_ handle: CropHandle) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        if dragStart == nil { dragStart = pipeline.adjustments.geometry.crop }
        isDragging = true
        guard let start = dragStart, imageRect.width > 0, imageRect.height > 0 else { return }
        let dx = value.translation.width / imageRect.width
        let dy = value.translation.height / imageRect.height
        pipeline.adjustments.geometry.crop = resized(start, handle: handle, dx: dx, dy: dy)
      }
      .onEnded { _ in
        dragStart = nil
        isDragging = false
      }
  }

  /// Normalized aspect (width / height in valid-area units) the crop must keep, if any.
  private var normalizedAspect: Double? {
    guard let target = pipeline.targetCropAspect() else { return nil }
    let valid = pipeline.previewGeometry.validAspect
    return valid > 0 ? target / valid : nil
  }

  private func resized(_ start: CGRect, handle: CropHandle, dx: Double, dy: Double) -> CGRect {
    var rect = start
    switch handle {
    case .move:
      rect.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
      rect.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
      return rect
    case .topLeft:
      rect = CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width - dx, height: start.height - dy)
    case .topRight:
      rect = CGRect(x: start.minX, y: start.minY + dy, width: start.width + dx, height: start.height - dy)
    case .bottomLeft:
      rect = CGRect(x: start.minX + dx, y: start.minY, width: start.width - dx, height: start.height + dy)
    case .bottomRight:
      rect = CGRect(x: start.minX, y: start.minY, width: start.width + dx, height: start.height + dy)
    case .top:
      rect = CGRect(x: start.minX, y: start.minY + dy, width: start.width, height: start.height - dy)
    case .bottom:
      rect = CGRect(x: start.minX, y: start.minY, width: start.width, height: start.height + dy)
    case .left:
      rect = CGRect(x: start.minX + dx, y: start.minY, width: start.width - dx, height: start.height)
    case .right:
      rect = CGRect(x: start.minX, y: start.minY, width: start.width + dx, height: start.height)
    }
    rect = rect.standardized
    rect.size.width = max(rect.width, Self.minimumSize)
    rect.size.height = max(rect.height, Self.minimumSize)

    if let aspect = normalizedAspect {
      // Keep the aspect, anchored at the corner or edge opposite the dragged handle.
      let byWidth: Bool
      switch handle {
      case .top, .bottom: byWidth = false
      case .left, .right: byWidth = true
      default: byWidth = abs(dx) >= abs(dy)
      }
      if byWidth {
        rect.size.height = rect.width / aspect
      } else {
        rect.size.width = rect.height * aspect
      }
      switch handle {
      case .topLeft:
        rect.origin = CGPoint(x: start.maxX - rect.width, y: start.maxY - rect.height)
      case .topRight, .top:
        rect.origin.y = start.maxY - rect.height
      case .bottomLeft, .left:
        rect.origin.x = start.maxX - rect.width
      default:
        break
      }
      if case .top = handle { rect.origin.x = start.midX - rect.width / 2 }
      if case .bottom = handle { rect.origin.x = start.midX - rect.width / 2 }
      if case .left = handle { rect.origin.y = start.midY - rect.height / 2 }
      if case .right = handle { rect.origin.y = start.midY - rect.height / 2 }
    }

    // Keep inside the image; shrink proportionally if needed.
    let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    if !bounds.contains(rect) {
      let clipped = rect.intersection(bounds)
      if let aspect = normalizedAspect, clipped.width > 0, clipped.height > 0 {
        var fitted = clipped
        if clipped.width / clipped.height > aspect {
          fitted.size.width = clipped.height * aspect
        } else {
          fitted.size.height = clipped.width / aspect
        }
        if rect.minX < 0 || handle == .left || handle == .topLeft || handle == .bottomLeft { fitted.origin.x = clipped.maxX - fitted.width }
        if rect.minY < 0 || handle == .top || handle == .topLeft || handle == .topRight { fitted.origin.y = clipped.maxY - fitted.height }
        rect = fitted
      } else {
        rect = clipped
      }
    }
    return rect
  }
}

private enum CropHandle { case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

/// L-shaped corner marks and short bars for edge handles, like `IPXCropDragCornerLayer`.
private struct CornerHandleShape: Shape {
  let handle: CropHandle

  func path(in rect: CGRect) -> Path {
    let length: CGFloat = 14
    let c = CGPoint(x: rect.midX, y: rect.midY)
    return Path { path in
      switch handle {
      case .topLeft:
        path.move(to: CGPoint(x: c.x, y: c.y + length)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x + length, y: c.y))
      case .topRight:
        path.move(to: CGPoint(x: c.x - length, y: c.y)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x, y: c.y + length))
      case .bottomLeft:
        path.move(to: CGPoint(x: c.x, y: c.y - length)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x + length, y: c.y))
      case .bottomRight:
        path.move(to: CGPoint(x: c.x - length, y: c.y)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x, y: c.y - length))
      case .top, .bottom:
        path.move(to: CGPoint(x: c.x - length / 2, y: c.y)); path.addLine(to: CGPoint(x: c.x + length / 2, y: c.y))
      case .left, .right:
        path.move(to: CGPoint(x: c.x, y: c.y - length / 2)); path.addLine(to: CGPoint(x: c.x, y: c.y + length / 2))
      case .move:
        break
      }
    }
  }
}
#endif
