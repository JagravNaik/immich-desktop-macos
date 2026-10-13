#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

// MARK: - Brick

/// One collapsible section of Photos' Adjust panel (`IPXAdjustmentBrickController`): a disclosure
/// chevron, title, optional AUTO button, a reset control shown when modified, and an enable checkbox.
struct AdjustmentBrick<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  var isEnabled: Binding<Bool>?
  let isModified: Bool
  var autoAction: (() -> Void)?
  let onReset: () -> Void
  @ViewBuilder let content: () -> Content

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Button {
          withAnimation(ImmichMotion.Curves.structuralShort) { isExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .foregroundStyle(.secondary)
            Text(title)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.primary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")

        Spacer(minLength: 4)

        if let autoAction {
          Button("AUTO", action: autoAction)
            .font(.system(size: 9, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Automatically adjust \(title)")
        }

        if isModified {
          Button(action: onReset) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .opacity(isHovering ? 1 : 0.55)
          .help("Reset")
          .accessibilityLabel("Reset \(title)")
        }

        if let isEnabled {
          Toggle("", isOn: isEnabled)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(isEnabled.wrappedValue ? "Turn off \(title)" : "Turn on \(title)")
            .accessibilityLabel("\(title) enabled")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      if isExpanded {
        content()
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
          .opacity(isEnabled?.wrappedValue == false ? 0.45 : 1)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Divider()
    }
    .onHover { isHovering = $0 }
  }
}

// MARK: - Slider

/// Photos' brick slider: title, value readout, and double-click on the title to reset.
struct EditSlider: View {
  let title: String
  @Binding var value: Double
  var range: ClosedRange<Double> = -1...1
  var defaultValue: Double = 0
  var format: (Double) -> String = { String(format: "%.2f", $0) }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title)
          .font(.system(size: 11))
          .onTapGesture(count: 2) { value = defaultValue }
          .help("Double-click to reset")
        Spacer()
        Text(format(value))
          .font(.system(size: 10).monospacedDigit())
          .foregroundStyle(value == defaultValue ? .tertiary : .secondary)
      }
      Slider(value: $value, in: range)
        .controlSize(.mini)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
  }
}

// MARK: - Histogram

struct HistogramView: View {
  let histogram: Histogram?
  var showsChannels = true

  var body: some View {
    Canvas { context, size in
      guard let histogram else { return }
      func path(_ values: [Double]) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in values.enumerated() {
          let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
          path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(min(value, 1)))))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
      }
      if showsChannels {
        context.blendMode = .plusLighter
        context.fill(path(histogram.red), with: .color(.red.opacity(0.55)))
        context.fill(path(histogram.green), with: .color(.green.opacity(0.55)))
        context.fill(path(histogram.blue), with: .color(.blue.opacity(0.55)))
      } else {
        context.fill(path(histogram.luminance), with: .color(.gray.opacity(0.6)))
      }
    }
    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    .accessibilityLabel("Histogram")
  }
}

// MARK: - Curves

/// Photos' Curves brick: a channel menu, the curve over a histogram, click to add a point,
/// drag to move it, and double-click a point to remove it.
struct CurvesEditor: View {
  @Binding var curves: PhotoAdjustments.Curves
  let histogram: Histogram?
  @State private var channel: PhotoAdjustments.Curves.Channel = .rgb
  @State private var draggingIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Channel", selection: $channel) {
        ForEach(PhotoAdjustments.Curves.Channel.allCases) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)

      GeometryReader { geometry in
        let size = geometry.size
        let points = curves.points(for: channel)
        ZStack {
          HistogramView(histogram: histogram, showsChannels: channel == .rgb)
          grid(size: size)
          curvePath(points: points, size: size)
            .stroke(curveColor, lineWidth: 1.5)
          ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            Circle()
              .fill(Color.white)
              .overlay(Circle().stroke(curveColor, lineWidth: 1.5))
              .frame(width: 9, height: 9)
              .position(x: point.x * size.width, y: (1 - point.y) * size.height)
              .onTapGesture(count: 2) { removePoint(at: index) }
          }
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in drag(value, size: size) }
            .onEnded { _ in draggingIndex = nil }
        )
      }
      .aspectRatio(1, contentMode: .fit)

      HStack {
        Text("Click to add a point. Double-click a point to remove it.")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
  }

  private var curveColor: Color {
    switch channel {
    case .rgb: .white
    case .red: .red
    case .green: .green
    case .blue: .blue
    }
  }

  private func grid(size: CGSize) -> some View {
    Path { path in
      for step in 1..<4 {
        let x = size.width * CGFloat(step) / 4
        let y = size.height * CGFloat(step) / 4
        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
      }
    }
    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
  }

  private func curvePath(points: [PhotoAdjustments.CurvePoint], size: CGSize) -> Path {
    Path { path in
      let samples = 64
      for index in 0...samples {
        let x = Double(index) / Double(samples)
        let y = CurveLUTs.evaluate(points, at: x)
        let point = CGPoint(x: x * size.width, y: (1 - y) * size.height)
        index == 0 ? path.move(to: point) : path.addLine(to: point)
      }
    }
  }

  private func drag(_ value: DragGesture.Value, size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let x = min(max(value.location.x / size.width, 0), 1)
    let y = min(max(1 - value.location.y / size.height, 0), 1)
    var points = curves.points(for: channel)
    if draggingIndex == nil {
      if let nearest = points.indices.min(by: {
        hypot(points[$0].x - x, points[$0].y - y) < hypot(points[$1].x - x, points[$1].y - y)
      }), hypot(points[nearest].x - x, points[nearest].y - y) < 0.06 {
        draggingIndex = nearest
      } else {
        points.append(.init(x: x, y: y))
        points.sort { $0.x < $1.x }
        draggingIndex = points.firstIndex(of: .init(x: x, y: y))
      }
    }
    guard let index = draggingIndex, points.indices.contains(index) else { return }
    // Endpoints stay pinned to the left and right edges; inner points can't cross neighbors.
    let lower = index == 0 ? 0 : points[index - 1].x + 0.01
    let upper = index == points.count - 1 ? 1 : points[index + 1].x - 0.01
    let isEndpoint = index == 0 || index == points.count - 1
    points[index] = .init(x: isEndpoint ? points[index].x : min(max(x, lower), upper), y: y)
    curves.setPoints(points, for: channel)
  }

  private func removePoint(at index: Int) {
    var points = curves.points(for: channel)
    guard points.count > 2, index != 0, index != points.count - 1 else { return }
    points.remove(at: index)
    curves.setPoints(points, for: channel)
  }
}

// MARK: - Levels

/// Photos' Levels brick: histogram with black, gray, and white input handles per channel.
struct LevelsEditor: View {
  @Binding var levels: PhotoAdjustments.Levels
  let histogram: Histogram?
  @State private var channel: PhotoAdjustments.Levels.Channel = .rgb

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Channel", selection: $channel) {
        ForEach(PhotoAdjustments.Levels.Channel.allCases) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden()
      .controlSize(.small)

      GeometryReader { geometry in
        let width = geometry.size.width
        let values = levels.values(for: channel)
        ZStack(alignment: .bottomLeading) {
          HistogramView(histogram: histogram, showsChannels: channel == .rgb)
            .frame(height: geometry.size.height - 12)
            .frame(maxHeight: .infinity, alignment: .top)
          handle(color: .black, at: values.black, width: width) { update(\.black, $0, values) }
          handle(color: .gray, at: values.black + (values.white - values.black) * values.gray, width: width) { position in
            let span = max(values.white - values.black, 0.01)
            update(\.gray, min(max((position - values.black) / span, 0.05), 0.95), values)
          }
          handle(color: .white, at: values.white, width: width) { update(\.white, $0, values) }
        }
        .coordinateSpace(name: "levels")
      }
      .frame(height: 84)
    }
  }

  private func update(_ keyPath: WritableKeyPath<PhotoAdjustments.Levels.Values, Double>, _ value: Double, _ current: PhotoAdjustments.Levels.Values) {
    var values = current
    values[keyPath: keyPath] = value
    if values.black > values.white - 0.02 {
      if keyPath == \.black { values.black = values.white - 0.02 } else { values.white = values.black + 0.02 }
    }
    levels.setValues(values, for: channel)
  }

  private func handle(color: Color, at position: Double, width: CGFloat, onChange: @escaping (Double) -> Void) -> some View {
    Triangle()
      .fill(color)
      .overlay(Triangle().stroke(Color.white.opacity(0.7), lineWidth: 0.5))
      .frame(width: 10, height: 10)
      .offset(x: CGFloat(position) * width - 5)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("levels"))
          .onChanged { value in
            guard width > 0 else { return }
            onChange(min(max(value.location.x / width, 0), 1))
          }
      )
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}

// MARK: - Selective Color swatch

struct HueSwatch: View {
  let hue: Double
  let isSelected: Bool
  let isModified: Bool

  var body: some View {
    Circle()
      .fill(Color(hue: hue, saturation: 0.85, brightness: 0.9))
      .frame(width: 20, height: 20)
      .overlay(Circle().stroke(Color.white, lineWidth: isSelected ? 2 : 0))
      .overlay(alignment: .topTrailing) {
        if isModified {
          Circle().fill(Color.white).frame(width: 5, height: 5)
        }
      }
      .accessibilityLabel("Color range")
  }
}
#endif
