#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import ImmichCore

// MARK: - Editing Sidebar (Photos for macOS: Adjust / Filters / Crop)

/// The editor's inspector, laid out like Photos' `IPXAdjustmentStackController`: a tab switcher,
/// then collapsible adjustment bricks in Photos' order, a filter list, or crop controls.
struct EditingSidebar: View {
  @ObservedObject var appState: AppState
  @ObservedObject var pipeline: PhotoEditingPipeline
  let thumbnailStore: ThumbnailStore
  let item: AppState.PhotoItem

  @AppStorage("editor.expandedBricks") private var expandedBricksStorage = "Light,Color,Black & White"
  @State private var selectiveColorIndex = 0
  @State private var isConfirmingDone = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      Picker("", selection: $appState.editingTab) {
        ForEach(AppState.EditingTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(12)

      Divider()

      switch appState.editingSessionState {
      case .loading, .idle:
        Spacer()
        ProgressView("Loading Original…").controlSize(.small)
        Spacer()
      case .failed(let message):
        Spacer()
        ContentUnavailableView("Can’t Edit Photo", systemImage: "exclamationmark.triangle", description: Text(message))
        Spacer()
      case .ready, .saving:
        ScrollView {
          switch appState.editingTab {
          case .adjust: adjustContent
          case .filters: filtersContent
          case .crop: cropContent
          }
        }
      }

      Divider()
      footer
    }
    .frame(width: 280)
    .background(.ultraThinMaterial)
    .onChange(of: appState.editingTab) { _, tab in
      pipeline.canvasTool = tab == .crop ? .crop : .none
    }
    .onAppear {
      pipeline.canvasTool = appState.editingTab == .crop ? .crop : .none
    }
    .confirmationDialog("Save your edits?", isPresented: $isConfirmingDone) {
      Button("Save as New Photo") { finish { try await appState.saveEditedCopy(pipeline: pipeline) } }
      Button("Export to Disk…") { appState.exportEditedImage(pipeline: pipeline) }
      Button("Discard Changes", role: .destructive) { closeEditor() }
    } message: {
      Text("Immich keeps crop, rotate, and flip on the original. Light, color, filter, and spot edits are saved as a new photo next to the original.")
    }
    .alert("Couldn’t Save Edits", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        pipeline.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(!pipeline.canUndo)
      .keyboardShortcut("z", modifiers: .command)
      .help("Undo (⌘Z)")
      .accessibilityLabel("Undo")

      Button {
        pipeline.redo()
      } label: {
        Image(systemName: "arrow.uturn.forward")
      }
      .disabled(!pipeline.canRedo)
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .help("Redo (⇧⌘Z)")
      .accessibilityLabel("Redo")

      Spacer()

      Button("Revert to Original") {
        withAnimation(ImmichMotion.Curves.structuralShort) { pipeline.revertToOriginal() }
      }
      .disabled(!pipeline.hasEdits)
      .controlSize(.small)

      Button(appState.editingSessionState == .saving ? "Saving…" : "Done") {
        done()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.return, modifiers: [])
      .disabled(appState.editingSessionState == .saving)
    }
    .buttonStyle(.bordered)
    .padding(12)
  }

  private func done() {
    switch AppState.saveStrategy(for: pipeline) {
    case .nothing:
      closeEditor()
    case .immichEdits:
      finish { try await appState.saveGeometryEdits(pipeline: pipeline, thumbnailStore: thumbnailStore) }
    case .newPhoto:
      if case .localFile = item.source {
        appState.exportEditedImage(pipeline: pipeline)
      } else {
        isConfirmingDone = true
      }
    }
  }

  private func finish(_ save: @escaping () async throws -> Void) {
    Task {
      do {
        try await save()
        closeEditor()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func closeEditor() {
    withAnimation(ImmichMotion.Curves.structuralShort) {
      appState.endEditingSession(pipeline: pipeline)
    }
  }

  // MARK: - Brick expansion

  private func expanded(_ title: String) -> Binding<Bool> {
    Binding(
      get: { expandedBricksStorage.split(separator: ",").map(String.init).contains(title) },
      set: { isExpanded in
        var titles = Set(expandedBricksStorage.split(separator: ",").map(String.init))
        if isExpanded { titles.insert(title) } else { titles.remove(title) }
        expandedBricksStorage = titles.sorted().joined(separator: ",")
      }
    )
  }

  private var adjustments: Binding<PhotoAdjustments> { $pipeline.adjustments }

  // MARK: - Adjust

  private var adjustContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button {
          withAnimation(ImmichMotion.Curves.searchSpring) { pipeline.autoEnhance() }
        } label: {
          Label("Auto Enhance", systemImage: "wand.and.stars")
        }
        .controlSize(.small)
        .help("Auto Enhance")
        Spacer()
        Button {} label: { Image(systemName: "square.split.2x1") }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Hold to show the original (M)")
          .accessibilityLabel("Show Original")
          .onLongPressGesture(minimumDuration: 0, pressing: { pipeline.isShowingOriginal = $0 }, perform: {})
      }
      .padding(12)

      HistogramView(histogram: pipeline.histogram)
        .frame(height: 56)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)

      Divider()

      lightBrick
      colorBrick
      blackAndWhiteBrick
      retouchBrick
      redEyeBrick
      whiteBalanceBrick
      curvesBrick
      levelsBrick
      definitionBrick
      selectiveColorBrick
      noiseReductionBrick
      sharpenBrick
      vignetteBrick
    }
  }

  private var lightBrick: some View {
    let light = adjustments.light
    return AdjustmentBrick(
      title: "Light",
      isExpanded: expanded("Light"),
      isEnabled: light.isEnabled,
      isModified: pipeline.adjustments.light.isActive,
      autoAction: { withAnimation { pipeline.autoEnhance() } },
      onReset: { pipeline.adjustments.light = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        EditSlider(title: "Light", value: light.master)
        OptionsDisclosure {
          EditSlider(title: "Brilliance", value: light.brilliance)
          EditSlider(title: "Exposure", value: light.exposure)
          EditSlider(title: "Highlights", value: light.highlights)
          EditSlider(title: "Shadows", value: light.shadows)
          EditSlider(title: "Brightness", value: light.brightness)
          EditSlider(title: "Contrast", value: light.contrast)
          EditSlider(title: "Black Point", value: light.blackPoint)
        }
      }
    }
  }

  private var colorBrick: some View {
    let color = adjustments.color
    return AdjustmentBrick(
      title: "Color",
      isExpanded: expanded("Color"),
      isEnabled: color.isEnabled,
      isModified: pipeline.adjustments.color.isActive,
      autoAction: { withAnimation { pipeline.autoEnhance() } },
      onReset: { pipeline.adjustments.color = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        EditSlider(title: "Color", value: color.master)
        OptionsDisclosure {
          EditSlider(title: "Saturation", value: color.saturation)
          EditSlider(title: "Vibrance", value: color.vibrance)
          EditSlider(title: "Cast", value: color.cast)
        }
      }
    }
  }

  private var blackAndWhiteBrick: some View {
    let bw = adjustments.blackAndWhite
    return AdjustmentBrick(
      title: "Black & White",
      isExpanded: expanded("Black & White"),
      isEnabled: bw.isEnabled,
      isModified: pipeline.adjustments.blackAndWhite.isActive,
      onReset: { pipeline.adjustments.blackAndWhite = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        EditSlider(title: "Black & White", value: enabling(bw.master, bw.isEnabled))
        OptionsDisclosure {
          EditSlider(title: "Intensity", value: enabling(bw.intensity, bw.isEnabled))
          EditSlider(title: "Neutrals", value: enabling(bw.neutrals, bw.isEnabled))
          EditSlider(title: "Tone", value: enabling(bw.tone, bw.isEnabled))
          EditSlider(title: "Grain", value: enabling(bw.grain, bw.isEnabled), range: 0...1)
        }
      }
    }
  }

  /// Moving a slider in an off brick turns it on, as in Photos.
  private func enabling(_ value: Binding<Double>, _ isEnabled: Binding<Bool>) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { newValue in
      if !isEnabled.wrappedValue { isEnabled.wrappedValue = true }
      value.wrappedValue = newValue
    })
  }

  private var retouchBrick: some View {
    AdjustmentBrick(
      title: "Retouch",
      isExpanded: expanded("Retouch"),
      isModified: !pipeline.adjustments.retouch.spots.isEmpty,
      onReset: { pipeline.adjustments.retouch.spots = [] }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        toolToggle(.retouch, title: "Retouch Brush", systemImage: "bandage")
        EditSlider(title: "Size", value: adjustments.retouch.brushSize, range: 0.005...0.12, defaultValue: 0.03) {
          "\(Int($0 * 1000))"
        }
        Text(pipeline.pendingRetouchSource == nil
          ? "Click & drag over spots to remove. Option-click to choose the source area."
          : "Source set. Click a spot to copy from it.")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var redEyeBrick: some View {
    AdjustmentBrick(
      title: "Red-eye",
      isExpanded: expanded("Red-eye"),
      isModified: pipeline.adjustments.redEye.isActive,
      autoAction: { pipeline.adjustments.redEye.automatic = true },
      onReset: { pipeline.adjustments.redEye = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        toolToggle(.redEye, title: "Red-eye Tool", systemImage: "eye")
        Text("Click each red-eye to correct.")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var whiteBalanceBrick: some View {
    let balance = adjustments.whiteBalance
    let mode = pipeline.adjustments.whiteBalance.mode
    return AdjustmentBrick(
      title: "White Balance",
      isExpanded: expanded("White Balance"),
      isEnabled: balance.isEnabled,
      isModified: pipeline.adjustments.whiteBalance.isActive,
      onReset: { pipeline.adjustments.whiteBalance = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Picker("Mode", selection: balance.mode) {
          ForEach(PhotoAdjustments.WhiteBalance.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)

        if mode != .temperatureTint {
          toolToggle(.whiteBalancePicker, title: mode == .neutralGray ? "Pick Neutral Gray" : "Pick Skin Tone", systemImage: "eyedropper")
          Text(mode == .neutralGray
            ? "Choose a neutral gray in the photo to set its white balance."
            : "Choose a skin tone in the photo to set its white balance.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
          EditSlider(title: "Warmth", value: balance.warmth)
        } else {
          EditSlider(title: "Temperature", value: balance.warmth)
          EditSlider(title: "Tint", value: balance.tint)
        }
      }
    }
  }

  private var curvesBrick: some View {
    AdjustmentBrick(
      title: "Curves",
      isExpanded: expanded("Curves"),
      isEnabled: adjustments.curves.isEnabled,
      isModified: pipeline.adjustments.curves.isActive,
      onReset: { pipeline.adjustments.curves = .init() }
    ) {
      CurvesEditor(curves: adjustments.curves, histogram: pipeline.histogram)
    }
  }

  private var levelsBrick: some View {
    AdjustmentBrick(
      title: "Levels",
      isExpanded: expanded("Levels"),
      isEnabled: adjustments.levels.isEnabled,
      isModified: pipeline.adjustments.levels.isActive,
      onReset: { pipeline.adjustments.levels = .init() }
    ) {
      LevelsEditor(levels: adjustments.levels, histogram: pipeline.histogram)
    }
  }

  private var definitionBrick: some View {
    AdjustmentBrick(
      title: "Definition",
      isExpanded: expanded("Definition"),
      isEnabled: adjustments.definition.isEnabled,
      isModified: pipeline.adjustments.definition.isActive,
      onReset: { pipeline.adjustments.definition = .init() }
    ) {
      EditSlider(title: "Amount", value: adjustments.definition.amount, range: 0...1)
    }
  }

  private var selectiveColorBrick: some View {
    let ranges = pipeline.adjustments.selectiveColor.ranges
    let index = min(selectiveColorIndex, max(ranges.count - 1, 0))
    return AdjustmentBrick(
      title: "Selective Color",
      isExpanded: expanded("Selective Color"),
      isEnabled: adjustments.selectiveColor.isEnabled,
      isModified: pipeline.adjustments.selectiveColor.isActive,
      onReset: { pipeline.adjustments.selectiveColor = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          ForEach(Array(ranges.enumerated()), id: \.offset) { offset, range in
            HueSwatch(hue: range.hue, isSelected: offset == index, isModified: !range.isDefault)
              .onTapGesture { selectiveColorIndex = offset }
          }
          Spacer()
          Button {
            pipeline.canvasTool = pipeline.canvasTool == .selectiveColorPicker ? .none : .selectiveColorPicker
          } label: {
            Image(systemName: "eyedropper")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(pipeline.canvasTool == .selectiveColorPicker ? .accentColor : nil)
          .help("Choose a custom hue in the photo.")
        }
        if ranges.indices.contains(index) {
          let range = adjustments.selectiveColor.ranges[index]
          EditSlider(title: "Hue", value: range.hueShift)
          EditSlider(title: "Saturation", value: range.saturation)
          EditSlider(title: "Luminance", value: range.luminance)
          EditSlider(title: "Range", value: range.range, range: 0...1, defaultValue: 0.5)
        }
      }
    }
  }

  private var noiseReductionBrick: some View {
    AdjustmentBrick(
      title: "Noise Reduction",
      isExpanded: expanded("Noise Reduction"),
      isEnabled: adjustments.noiseReduction.isEnabled,
      isModified: pipeline.adjustments.noiseReduction.isActive,
      onReset: { pipeline.adjustments.noiseReduction = .init() }
    ) {
      EditSlider(title: "Amount", value: adjustments.noiseReduction.amount, range: 0...1)
    }
  }

  private var sharpenBrick: some View {
    AdjustmentBrick(
      title: "Sharpen",
      isExpanded: expanded("Sharpen"),
      isEnabled: adjustments.sharpen.isEnabled,
      isModified: pipeline.adjustments.sharpen.isActive,
      onReset: { pipeline.adjustments.sharpen = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        EditSlider(title: "Intensity", value: adjustments.sharpen.intensity, range: 0...1)
        EditSlider(title: "Edges", value: adjustments.sharpen.edges, range: 0...1, defaultValue: 0.5)
        EditSlider(title: "Falloff", value: adjustments.sharpen.falloff, range: 0...1, defaultValue: 0.5)
      }
    }
  }

  private var vignetteBrick: some View {
    AdjustmentBrick(
      title: "Vignette",
      isExpanded: expanded("Vignette"),
      isEnabled: adjustments.vignette.isEnabled,
      isModified: pipeline.adjustments.vignette.isActive,
      onReset: { pipeline.adjustments.vignette = .init() }
    ) {
      VStack(alignment: .leading, spacing: 8) {
        EditSlider(title: "Strength", value: adjustments.vignette.strength)
        EditSlider(title: "Radius", value: adjustments.vignette.radius, range: 0...1, defaultValue: 0.5)
        EditSlider(title: "Softness", value: adjustments.vignette.softness, range: 0...1, defaultValue: 0.5)
      }
    }
  }

  private func toolToggle(_ tool: PhotoEditingPipeline.CanvasTool, title: String, systemImage: String) -> some View {
    Button {
      pipeline.canvasTool = pipeline.canvasTool == tool ? .none : tool
      if tool != .retouch { pipeline.pendingRetouchSource = nil }
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .tint(pipeline.canvasTool == tool ? .accentColor : nil)
  }

  // MARK: - Filters

  private var filtersContent: some View {
    VStack(spacing: 10) {
      ForEach(PhotoFilter.allCases) { filter in
        Button {
          withAnimation(ImmichMotion.Curves.interactiveFast) {
            pipeline.adjustments.filter = filter
          }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            FilterPreviewThumbnail(pipeline: pipeline, filter: filter, isSelected: pipeline.adjustments.filter == filter)
              .frame(height: 86)
            Text(filter.rawValue)
              .font(.system(size: 11, weight: pipeline.adjustments.filter == filter ? .semibold : .regular))
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.rawValue)
        .accessibilityAddTraits(pipeline.adjustments.filter == filter ? .isSelected : [])
      }
    }
    .padding(12)
  }

  // MARK: - Crop

  private var cropContent: some View {
    let geometry = adjustments.geometry
    let current = pipeline.adjustments.geometry
    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Button("Auto") { withAnimation { pipeline.autoStraighten() } }
          .help("Automatically straighten and crop")
        Spacer()
        Button("Reset") { withAnimation(ImmichMotion.Curves.structuralShort) { pipeline.resetCrop() } }
          .help("Reset all crop settings")
          .disabled(current == PhotoAdjustments.Geometry())
      }
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 4) {
        Text("Straighten").font(.system(size: 11, weight: .semibold))
        StraightenDial(angle: geometry.straighten)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Aspect").font(.system(size: 11, weight: .semibold))
          Spacer()
          if current.aspect.hasOrientation {
            Picker("Orientation", selection: Binding(
              get: { current.isPortrait },
              set: { pipeline.setCropAspect(current.aspect, portrait: $0) }
            )) {
              Image(systemName: "rectangle").tag(false).help("Crop as landscape")
              Image(systemName: "rectangle.portrait").tag(true).help("Crop as portrait")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
          }
        }
        ForEach(CropAspect.allCases) { aspect in
          Button {
            withAnimation(ImmichMotion.Curves.interactiveFast) { pipeline.setCropAspect(aspect) }
          } label: {
            HStack {
              Image(systemName: current.aspect == aspect ? "checkmark" : "")
                .frame(width: 12)
              Text(aspect.rawValue)
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .font(.system(size: 11))
        }
      }

      HStack(spacing: 8) {
        Button { pipeline.rotateLeft() } label: { Image(systemName: "rotate.left") }
          .help("Rotate counterclockwise (⌘R)")
          .accessibilityLabel("Rotate")
        Button { pipeline.adjustments.geometry.flipHorizontal.toggle() } label: {
          Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .help("Flip horizontally")
        .accessibilityLabel("Flip Horizontal")
        Button { pipeline.adjustments.geometry.flipVertical.toggle() } label: {
          Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
        }
        .help("Flip vertically")
        .accessibilityLabel("Flip Vertical")
      }
      .buttonStyle(.bordered)

      if pipeline.adjustments.geometry.straighten != 0 {
        Text("Immich can’t store a straighten angle on the original, so a straightened photo is saved as a new photo.")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
  }
}

// MARK: - Options disclosure

/// Photos' "Options" disclosure under a brick's master slider.
private struct OptionsDisclosure<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8, content: content)
        .padding(.top, 6)
    } label: {
      Text("Options").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
    }
  }
}

// MARK: - Straighten dial

/// Photos' straighten control: a ±45° ruler with a center mark; double-click resets.
private struct StraightenDial: View {
  @Binding var angle: Double

  var body: some View {
    VStack(spacing: 2) {
      Slider(value: $angle, in: -45...45)
        .controlSize(.small)
        .accessibilityLabel("Straighten")
        .accessibilityValue("\(Int(angle.rounded())) degrees")
      HStack {
        Text("-45°")
        Spacer()
        Text(String(format: "%.1f°", angle))
          .monospacedDigit()
          .onTapGesture(count: 2) { angle = 0 }
        Spacer()
        Text("45°")
      }
      .font(.system(size: 9))
      .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Filter thumbnail

struct FilterPreviewThumbnail: View {
  @ObservedObject var pipeline: PhotoEditingPipeline
  let filter: PhotoFilter
  let isSelected: Bool
  @State private var previewImage: NSImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6).fill(.quaternary)
      if let image = previewImage ?? pipeline.cachedFilterPreview(for: filter) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      }
    }
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
    }
    .task(id: "\(pipeline.filterPreviewCacheVersion)::\(filter.rawValue)") {
      previewImage = pipeline.cachedFilterPreview(for: filter)
      if previewImage == nil {
        previewImage = await pipeline.loadFilterPreview(for: filter)
      }
    }
  }
}
#endif
