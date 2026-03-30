#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import ImmichCore

// MARK: - Editing Sidebar (Photos-style: Adjust / Filters / Crop tabs)

struct EditingSidebar: View {
  @ObservedObject var appState: AppState
  @ObservedObject var pipeline: PhotoEditingPipeline
  let item: AppState.PhotoItem

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
        Button("Auto") {
          withAnimation(.easeInOut(duration: 0.3)) {
            pipeline.autoEnhance()
          }
        }
        .buttonStyle(.bordered)
        .help("Auto Enhance")

        Spacer()

        Button("Reset") {
          withAnimation(.easeInOut(duration: 0.2)) {
            pipeline.resetAll()
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!pipeline.hasEdits)

        Menu {
          Button("Save to Server") {
            appState.saveEditedImage(pipeline: pipeline)
          }
          Button("Export to Disk…") {
            appState.exportEditedImage(pipeline: pipeline)
          }
          Divider()
          Button("Revert to Original") {
            withAnimation(.easeInOut(duration: 0.2)) {
              pipeline.resetAll()
            }
          }
        } label: {
          Text("Save")
        }
        .menuStyle(.borderedButton)
        .disabled(!pipeline.hasEdits)

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
      adjustSlider(label: "Exposure", value: $pipeline.exposure, range: -2...2)
      adjustSlider(label: "Brightness", value: $pipeline.brightness, range: -1...1)
      adjustSlider(label: "Contrast", value: $pipeline.contrast, range: -1...1)
      adjustSlider(label: "Highlights", value: $pipeline.highlights, range: -1...1)
      adjustSlider(label: "Shadows", value: $pipeline.shadows, range: -1...1)
      adjustSlider(label: "Saturation", value: $pipeline.saturation, range: -1...1)
      adjustSlider(label: "Warmth", value: $pipeline.warmth, range: -1...1)
      adjustSlider(label: "Sharpness", value: $pipeline.sharpness, range: 0...1)
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
        ForEach(PhotoEditingPipeline.FilterPreset.allCases) { preset in
          VStack(spacing: 4) {
            FilterPreviewThumbnail(
              pipeline: pipeline,
              preset: preset,
              isSelected: pipeline.selectedFilter == preset
            )
            .frame(height: 56)

            Text(preset.rawValue)
              .font(.system(size: 9))
              .lineLimit(1)
          }
          .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
              pipeline.selectedFilter = preset
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)
    }
  }

  // MARK: - Crop Tab

  private var cropContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Straighten")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      adjustSlider(label: "Rotation", value: $pipeline.rotation, range: -45...45)

      Divider()

      Text("Aspect Ratio")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
        ForEach(PhotoEditingPipeline.CropAspect.allCases) { aspect in
          Button(aspect.rawValue) {
            pipeline.cropAspectRatio = aspect
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(pipeline.cropAspectRatio == aspect ? .accentColor : nil)
        }
      }

      Divider()

      HStack(spacing: 16) {
        Button {
          pipeline.rotateLeft()
        } label: {
          Image(systemName: "rotate.left")
        }
        .help("Rotate Left 90°")

        Button {
          pipeline.rotateRight()
        } label: {
          Image(systemName: "rotate.right")
        }
        .help("Rotate Right 90°")

        Button {
          pipeline.flipHorizontal.toggle()
        } label: {
          Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            .foregroundStyle(pipeline.flipHorizontal ? Color.accentColor : .primary)
        }
        .help("Flip Horizontal")

        Button {
          pipeline.flipVertical.toggle()
        } label: {
          Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            .foregroundStyle(pipeline.flipVertical ? Color.accentColor : .primary)
        }
        .help("Flip Vertical")
      }
      .buttonStyle(.bordered)
    }
    .padding(16)
  }
}

// MARK: - Filter Preview Thumbnail

/// Shows a tiny preview of the source image with each filter applied.
struct FilterPreviewThumbnail: View {
  @ObservedObject var pipeline: PhotoEditingPipeline
  let preset: PhotoEditingPipeline.FilterPreset
  let isSelected: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(.quaternary)

      if let img = pipeline.previewImage(for: preset) {
        Image(nsImage: img)
          .resizable()
          .scaledToFill()
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
  }
}
#endif
