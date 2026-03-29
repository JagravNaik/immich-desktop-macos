#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import ImmichCore

// MARK: - Editing Sidebar (Photos-style: Adjust / Filters / Crop tabs)

struct EditingSidebar: View {
  @ObservedObject var appState: AppState
  let item: AppState.PhotoItem

  @State private var brightness: Double = 0
  @State private var contrast: Double = 0
  @State private var saturation: Double = 0
  @State private var exposure: Double = 0
  @State private var highlights: Double = 0
  @State private var shadows: Double = 0
  @State private var warmth: Double = 0
  @State private var sharpness: Double = 0
  @State private var rotation: Double = 0
  @State private var selectedFilterIndex = 0

  var body: some View {
    VStack(spacing: 0) {
      // Tab picker (Photos-style segmented control)
      Picker("", selection: $appState.editingTab) {
        ForEach(AppState.EditingTab.allCases, id: \.self) { tab in
          Label(tab.rawValue, systemImage: tab.iconName)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(12)

      Divider()

      // Tab content
      ScrollView {
        switch appState.editingTab {
        case .adjust:
          adjustContent
        case .filters:
          filtersContent
        case .crop:
          cropContent
        }
      }

      Divider()

      // Bottom bar
      HStack {
        Button("Auto Enhance") {
          autoEnhance()
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("Reset") {
          resetAll()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)

        Button("Done") {
          withAnimation(.easeInOut(duration: 0.2)) {
            appState.isEditing = false
          }
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(12)
    }
    .frame(width: 280)
    .background(.ultraThinMaterial)
  }

  // MARK: - Adjust Tab

  private var adjustContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      adjustSlider(label: "Exposure", value: $exposure, range: -2...2)
      adjustSlider(label: "Brightness", value: $brightness, range: -1...1)
      adjustSlider(label: "Contrast", value: $contrast, range: -1...1)
      adjustSlider(label: "Highlights", value: $highlights, range: -1...1)
      adjustSlider(label: "Shadows", value: $shadows, range: -1...1)
      adjustSlider(label: "Saturation", value: $saturation, range: -1...1)
      adjustSlider(label: "Warmth", value: $warmth, range: -1...1)
      adjustSlider(label: "Sharpness", value: $sharpness, range: 0...1)
    }
    .padding(16)
  }

  private func adjustSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
          .font(.caption.weight(.medium))
        Spacer()
        Text(String(format: "%+.2f", value.wrappedValue))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
        .controlSize(.small)
    }
  }

  // MARK: - Filters Tab

  private var filtersContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Filters")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
        ForEach(Array(filterNames.enumerated()), id: \.offset) { index, name in
          VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
              .fill(filterGradient(for: index))
              .frame(height: 56)
              .overlay {
                if selectedFilterIndex == index {
                  RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                }
              }

            Text(name)
              .font(.system(size: 9))
              .lineLimit(1)
          }
          .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
              selectedFilterIndex = index
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)
    }
  }

  private let filterNames = [
    "Original", "Vivid", "Dramatic", "Mono",
    "Noir", "Silvertone", "Fade", "Chrome", "Process"
  ]

  private func filterGradient(for index: Int) -> LinearGradient {
    let colors: [Color] = switch index {
    case 0: [.gray.opacity(0.2), .gray.opacity(0.3)]
    case 1: [.orange.opacity(0.4), .red.opacity(0.3)]
    case 2: [.indigo.opacity(0.4), .black.opacity(0.3)]
    case 3: [.gray.opacity(0.5), .white.opacity(0.2)]
    case 4: [.black.opacity(0.6), .gray.opacity(0.3)]
    case 5: [.brown.opacity(0.3), .gray.opacity(0.2)]
    case 6: [.mint.opacity(0.2), .gray.opacity(0.15)]
    case 7: [.teal.opacity(0.3), .blue.opacity(0.2)]
    default: [.purple.opacity(0.3), .pink.opacity(0.2)]
    }
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  // MARK: - Crop Tab

  private var cropContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Straighten")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      adjustSlider(label: "Rotation", value: $rotation, range: -45...45)

      Divider()

      Text("Aspect Ratio")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
        aspectButton("Free", ratio: nil)
        aspectButton("1:1", ratio: 1)
        aspectButton("4:3", ratio: 4.0/3.0)
        aspectButton("16:9", ratio: 16.0/9.0)
        aspectButton("3:2", ratio: 3.0/2.0)
      }

      Divider()

      HStack(spacing: 16) {
        Button {
          rotation = 0 // Rotate left 90
        } label: {
          Image(systemName: "rotate.left")
        }
        .help("Rotate Left")

        Button {
          rotation = 0 // Rotate right 90
        } label: {
          Image(systemName: "rotate.right")
        }
        .help("Rotate Right")

        Button {
          // Flip horizontal
        } label: {
          Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .help("Flip Horizontal")

        Button {
          // Flip vertical
        } label: {
          Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
        }
        .help("Flip Vertical")
      }
      .buttonStyle(.bordered)
    }
    .padding(16)
  }

  private func aspectButton(_ label: String, ratio: Double?) -> some View {
    Button(label) {}
      .buttonStyle(.bordered)
      .controlSize(.small)
  }

  // MARK: - Actions

  private func autoEnhance() {
    withAnimation(.easeInOut(duration: 0.3)) {
      brightness = 0.05
      contrast = 0.1
      saturation = 0.15
      exposure = 0.1
      highlights = -0.1
      shadows = 0.15
      sharpness = 0.3
    }
  }

  private func resetAll() {
    withAnimation(.easeInOut(duration: 0.2)) {
      brightness = 0; contrast = 0; saturation = 0; exposure = 0
      highlights = 0; shadows = 0; warmth = 0; sharpness = 0
      rotation = 0; selectedFilterIndex = 0
    }
  }
}
#endif
