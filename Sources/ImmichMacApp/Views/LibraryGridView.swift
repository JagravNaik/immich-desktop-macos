#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

private let photoGridCoordinateSpace = "ImmichPhotoGrid"

private struct PhotoGridItemFramePreferenceKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct PhotoHeroSourceFramePreferenceKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

// MARK: - Library Grid View (Photos-style chronological timeline)

struct LibraryGridView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore
  let heroHiddenItemID: String?
  let onOpenAsset: (AppState.PhotoItem, CGRect, NSImage?) -> Void
  let onHeroFramesChanged: ([String: CGRect]) -> Void
  @State private var itemFrames: [String: CGRect] = [:]
  @State private var heroItemFrames: [String: CGRect] = [:]
  @State private var dragSelectionState: DragSelectionState?
  @State private var keyboardScrollTargetID: String?

  private struct DragSelectionState {
    let mode: DragSelectionMode
    var visitedItemIDs: Set<String> = []
  }

  private enum DragSelectionMode {
    case select
    case deselect
  }

  private var gridColumns: [GridItem] {
    [
      GridItem(
        .adaptive(
          minimum: appState.photoGridThumbnailWidth,
          maximum: appState.photoGridThumbnailWidth
        ),
        spacing: appState.photoGridSpacing
      ),
    ]
  }

  var body: some View {
    ScrollViewReader { proxy in
      Group {
        if appState.filteredItems.isEmpty {
          if appState.isLoadingTimeline {
            loadingView
          } else {
            emptyView
          }
        } else if shouldShowSectionedTimeline {
          sectionedTimeline
        } else {
          flatGrid
        }
      }
      .focusable()
      .focusEffectDisabled()
      .onChange(of: appState.isMultiSelectMode) { _, isEnabled in
        if !isEnabled {
          dragSelectionState = nil
        }
      }
      .onChange(of: keyboardScrollTargetID) { _, targetID in
        guard let targetID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
          proxy.scrollTo(targetID, anchor: .center)
        }
        DispatchQueue.main.async {
          if keyboardScrollTargetID == targetID {
            keyboardScrollTargetID = nil
          }
        }
      }
      .onKeyPress(.leftArrow) { moveSelection(by: -1, shouldScrollIntoView: true); return .handled }
      .onKeyPress(.rightArrow) { moveSelection(by: 1, shouldScrollIntoView: true); return .handled }
      .onKeyPress(.upArrow) { moveSelectionVertically(.up, shouldScrollIntoView: true); return .handled }
      .onKeyPress(.downArrow) { moveSelectionVertically(.down, shouldScrollIntoView: true); return .handled }
      .onKeyPress(.return) {
        guard !appState.isViewingPhoto else { return .ignored }
        openSelected()
        return .handled
      }
      .dropDestination(for: URL.self) { urls, _ in
        appState.importFiles(urls)
        return true
      }
    }
  }

  /// Flat ordered list of all visible items matching the current grid order.
  private var orderedItems: [AppState.PhotoItem] {
    if shouldShowSectionedTimeline {
      return appState.librarySections.flatMap(\.items)
    }
    return appState.filteredItems
  }

  /// Rough estimate of columns visible in the adaptive grid for arrow-key navigation.
  private var columnsEstimate: Int {
    let windowWidth = NSApp.mainWindow?.contentLayoutRect.width ?? 900
    let availableWidth = max(windowWidth - (appState.photoGridPadding * 2), appState.photoGridThumbnailWidth)
    let slotWidth = appState.photoGridThumbnailWidth + appState.photoGridSpacing
    return max(Int((availableWidth + appState.photoGridSpacing) / slotWidth), 1)
  }

  private enum VerticalSelectionDirection {
    case up
    case down
  }

  private func moveSelection(by offset: Int, shouldScrollIntoView: Bool = false) {
    let items = orderedItems
    guard !items.isEmpty else { return }
    guard let currentID = appState.selectedItemID,
          let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
      if let firstID = items.first?.id {
        setSelection(firstID, shouldScrollIntoView: shouldScrollIntoView)
      }
      return
    }
    let newIndex = min(max(currentIndex + offset, 0), items.count - 1)
    setSelection(items[newIndex].id, shouldScrollIntoView: shouldScrollIntoView)
  }

  private func moveSelectionVertically(_ direction: VerticalSelectionDirection, shouldScrollIntoView: Bool = false) {
    let items = orderedItems
    let itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    guard !items.isEmpty else { return }
    guard let currentID = appState.selectedItemID,
          let currentIndex = itemIndices[currentID],
          let currentFrame = itemFrames[currentID]
    else {
      moveSelection(by: direction == .up ? -columnsEstimate : columnsEstimate, shouldScrollIntoView: shouldScrollIntoView)
      return
    }

    let directionOffset = direction == .up ? -columnsEstimate : columnsEstimate
    let clampedPreferredIndex = min(max(currentIndex + directionOffset, 0), items.count - 1)
    let searchRadius = max(columnsEstimate, 2)

    let fastPathRange = max(0, clampedPreferredIndex - searchRadius)...min(items.count - 1, clampedPreferredIndex + searchRadius)
    let fastPathItems = fastPathRange.map { items[$0] }
    let fastPathCandidates = directionalCandidates(
      from: fastPathItems,
      currentID: currentID,
      currentFrame: currentFrame,
      direction: direction
    )

    if let bestMatch = bestVerticalMatch(
      in: fastPathCandidates,
      currentFrame: currentFrame,
      itemIndices: itemIndices
    ) {
      setSelection(bestMatch.id, shouldScrollIntoView: shouldScrollIntoView)
      return
    }

    let fallbackCandidates = directionalCandidates(
      from: items,
      currentID: currentID,
      currentFrame: currentFrame,
      direction: direction
    )
    if let bestMatch = bestVerticalMatch(
      in: fallbackCandidates,
      currentFrame: currentFrame,
      itemIndices: itemIndices
    ) {
      setSelection(bestMatch.id, shouldScrollIntoView: shouldScrollIntoView)
    }
  }

  private func directionalCandidates(
    from items: [AppState.PhotoItem],
    currentID: String,
    currentFrame: CGRect,
    direction: VerticalSelectionDirection
  ) -> [(id: String, frame: CGRect)] {
    items.compactMap { item -> (id: String, frame: CGRect)? in
      guard item.id != currentID, let frame = itemFrames[item.id] else { return nil }

      switch direction {
      case .up where frame.midY < currentFrame.midY:
        return (item.id, frame)
      case .down where frame.midY > currentFrame.midY:
        return (item.id, frame)
      default:
        return nil
      }
    }
  }

  private func bestVerticalMatch(
    in directionalCandidates: [(id: String, frame: CGRect)],
    currentFrame: CGRect,
    itemIndices: [String: Int]
  ) -> (id: String, frame: CGRect)? {
    guard !directionalCandidates.isEmpty else { return nil }

    let overlappingCandidates = directionalCandidates.filter {
      $0.frame.maxX > currentFrame.minX && $0.frame.minX < currentFrame.maxX
    }

    let pool = overlappingCandidates.isEmpty ? directionalCandidates : overlappingCandidates
    let currentMidX = currentFrame.midX
    let currentMidY = currentFrame.midY

    return pool.min { lhs, rhs in
      let lhsHorizontal = abs(lhs.frame.midX - currentMidX)
      let rhsHorizontal = abs(rhs.frame.midX - currentMidX)

      if abs(lhsHorizontal - rhsHorizontal) > 1 {
        return lhsHorizontal < rhsHorizontal
      }

      let lhsVertical = abs(lhs.frame.midY - currentMidY)
      let rhsVertical = abs(rhs.frame.midY - currentMidY)

      if abs(lhsVertical - rhsVertical) > 1 {
        return lhsVertical < rhsVertical
      }

      return itemIndices[lhs.id] ?? 0 < itemIndices[rhs.id] ?? 0
    }
  }

  private func setSelection(_ itemID: String, shouldScrollIntoView: Bool) {
    appState.selectedItemID = itemID
    if shouldScrollIntoView {
      keyboardScrollTargetID = itemID
    }
  }

  private func openSelected() {
    guard let selectedItemID = appState.selectedItemID,
          let item = orderedItems.first(where: { $0.id == selectedItemID })
    else { return }

    let sourceImage =
      thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
    let sourceFrame = heroItemFrames[item.id] ?? itemFrames[item.id] ?? .zero

    onOpenAsset(item, sourceFrame, sourceImage)
  }

  private var shouldShowSectionedTimeline: Bool {
    (appState.sidebarSelection == .library || appState.sidebarSelection == nil)
    && appState.searchText.isEmpty
  }

  private func applyScrubSelection(to itemID: String) {
    guard var dragSelectionState else { return }
    guard dragSelectionState.visitedItemIDs.insert(itemID).inserted else { return }

    withAnimation(.easeOut(duration: 0.08)) {
      appState.setItemSelection(itemID, isSelected: dragSelectionState.mode == .select)
    }
    appState.selectedItemID = itemID
    self.dragSelectionState = dragSelectionState
  }

  private func itemID(at location: CGPoint) -> String? {
    for (itemID, frame) in itemFrames {
      if frame.contains(location) {
        return itemID
      }
    }
    return nil
  }

  private func startScrubSelectionIfNeeded(at location: CGPoint) {
    guard dragSelectionState == nil else { return }
    guard let startItemID = itemID(at: location) else { return }

    let mode: DragSelectionMode = appState.selectedItemIDs.contains(startItemID) ? .deselect : .select
    dragSelectionState = DragSelectionState(mode: mode)
    applyScrubSelection(to: startItemID)
  }

  private var scrubSelectionGesture: some Gesture {
    DragGesture(
      minimumDistance: appState.isMultiSelectMode ? 0 : .greatestFiniteMagnitude,
      coordinateSpace: .named(photoGridCoordinateSpace)
    )
    .onChanged { value in
      guard appState.isMultiSelectMode else { return }
      startScrubSelectionIfNeeded(at: value.startLocation)

      guard let currentItemID = itemID(at: value.location) else { return }
      applyScrubSelection(to: currentItemID)
    }
    .onEnded { _ in
      dragSelectionState = nil
    }
  }

  @ViewBuilder
  private var scrubSelectionOverlay: some View {
    if appState.isMultiSelectMode {
      Color.clear
        .contentShape(Rectangle())
        .gesture(scrubSelectionGesture)
    }
  }

  // MARK: - Sectioned Timeline

  private var sectionedTimeline: some View {
    let context = appState.thumbnailContext
    let selectedID = appState.selectedItemID
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(appState.librarySections) { section in
          VStack(alignment: .leading, spacing: 4) {
            // Section header (Photos-style: subtle date label)
            Text(section.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
              .padding(.top, 4)

            // Photo grid
            LazyVGrid(columns: gridColumns, spacing: appState.photoGridSpacing) {
              ForEach(section.items) { item in
                PhotoGridCell(
                  item: item,
                  isSelected: item.id == selectedID,
                  isMultiSelected: appState.selectedItemIDs.contains(item.id),
                  isMultiSelectMode: appState.isMultiSelectMode,
                  heroHidden: heroHiddenItemID == item.id,
                  context: context,
                  thumbnailStore: thumbnailStore,
                  onSelect: { appState.selectedItemID = item.id },
                  onOpen: { item, sourceFrame, sourceImage in
                    appState.selectedItemID = item.id
                    onOpenAsset(item, heroItemFrames[item.id] ?? sourceFrame, sourceImage)
                  },
                  onFavoriteToggle: { appState.toggleFavorite(for: item.id) },
                  onMultiSelectToggle: { appState.toggleItemSelection(item.id) },
                  onDownload: { appState.downloadAsset(item.id) },
                  onAddToAlbum: {
                    appState.selectedItemIDs = [item.id]
                    appState.showAddToAlbumSheet = true
                  },
                  onEditTags: {
                    appState.presentTagEditor(for: [item.id], currentTags: [], title: "Edit Tags")
                  }
                )
                .id(item.id)
              }
            }
          }
          .onAppear {
            appState.loadMoreTimelineIfNeeded(after: section.id)
          }
        }

        // Footer
        if let footer = appState.timelineFooterMessage {
          HStack {
            Spacer()
            if appState.isLoadingTimeline {
              ProgressView().controlSize(.small)
              Text(footer).foregroundStyle(.secondary)
            } else {
              Button(footer) { Task { await appState.loadNextTimelinePage() } }
                .buttonStyle(.bordered)
            }
            Spacer()
          }
          .padding(.vertical, 16)
        }
      }
      .padding(.horizontal, appState.photoGridPadding)
      .padding(.vertical, appState.photoGridPadding)
    }
    .overlay { scrubSelectionOverlay }
    .coordinateSpace(name: photoGridCoordinateSpace)
    .onPreferenceChange(PhotoGridItemFramePreferenceKey.self) { itemFrames = $0 }
    .onPreferenceChange(PhotoHeroSourceFramePreferenceKey.self) { frames in
      heroItemFrames = frames
      onHeroFramesChanged(frames)
    }
    .animation(.easeInOut(duration: 0.22), value: appState.photoGridScaleIndex)
  }

  // MARK: - Flat Grid

  private var flatGrid: some View {
    let context = appState.thumbnailContext
    let selectedID = appState.selectedItemID
    return ScrollView {
      LazyVGrid(columns: gridColumns, spacing: appState.photoGridSpacing) {
        ForEach(appState.filteredItems) { item in
          PhotoGridCell(
            item: item,
            isSelected: item.id == selectedID,
            isMultiSelected: appState.selectedItemIDs.contains(item.id),
            isMultiSelectMode: appState.isMultiSelectMode,
            heroHidden: heroHiddenItemID == item.id,
            context: context,
            thumbnailStore: thumbnailStore,
            onSelect: { appState.selectedItemID = item.id },
            onOpen: { item, sourceFrame, sourceImage in
              appState.selectedItemID = item.id
              onOpenAsset(item, heroItemFrames[item.id] ?? sourceFrame, sourceImage)
            },
            onFavoriteToggle: { appState.toggleFavorite(for: item.id) },
            onMultiSelectToggle: { appState.toggleItemSelection(item.id) },
            onDownload: { appState.downloadAsset(item.id) },
            onAddToAlbum: {
              appState.selectedItemIDs = [item.id]
              appState.showAddToAlbumSheet = true
            },
            onEditTags: {
              appState.presentTagEditor(for: [item.id], currentTags: [], title: "Edit Tags")
            }
          )
          .id(item.id)
        }
      }
      .padding(.horizontal, appState.photoGridPadding)
      .padding(.vertical, appState.photoGridPadding)
    }
    .overlay { scrubSelectionOverlay }
    .coordinateSpace(name: photoGridCoordinateSpace)
    .onPreferenceChange(PhotoGridItemFramePreferenceKey.self) { itemFrames = $0 }
    .onPreferenceChange(PhotoHeroSourceFramePreferenceKey.self) { frames in
      heroItemFrames = frames
      onHeroFramesChanged(frames)
    }
    .animation(.easeInOut(duration: 0.22), value: appState.photoGridScaleIndex)
  }

  // MARK: - Empty / Loading

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView().controlSize(.large)
      Text("Loading your library…")
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyView: some View {
    VStack(spacing: 16) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 48, weight: .light))
        .foregroundStyle(.quaternary)

      VStack(spacing: 6) {
        Text(appState.emptyStateTitle)
          .font(.title3.weight(.semibold))
        Text(appState.emptyStateMessage)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 300)
      }

      if appState.sidebarSelection == .imports {
        Button("Import Files") {
          importFromFinder()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func importFromFinder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.begin { response in
      guard response == .OK else { return }
      appState.importFiles(panel.urls)
    }
  }
}

// MARK: - Photo Grid Cell (Photos-style: edge-to-edge thumbnails, minimal chrome)

struct PhotoGridCell: View {
  let item: AppState.PhotoItem
  let isSelected: Bool
  let isMultiSelected: Bool
  let isMultiSelectMode: Bool
  let heroHidden: Bool
  let context: AppState.ThumbnailContext?
  let thumbnailStore: ThumbnailStore
  let onSelect: () -> Void
  let onOpen: (AppState.PhotoItem, CGRect, NSImage?) -> Void
  let onFavoriteToggle: () -> Void
  let onMultiSelectToggle: () -> Void
  var onDownload: (() -> Void)?
  var onAddToAlbum: (() -> Void)?
  var onEditTags: (() -> Void)?

  @State private var isHovered = false
  private let cornerRadius: CGFloat = 10

  var body: some View {
    contentLayer
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: PhotoGridItemFramePreferenceKey.self,
          value: [item.id: proxy.frame(in: .named(photoGridCoordinateSpace))]
        )
        .preference(
          key: PhotoHeroSourceFramePreferenceKey.self,
          value: [item.id: proxy.frame(in: .named(photoHeroCoordinateSpaceName))]
        )
      }
    }
    .overlay {
      // Keep normal single-item selection visible, but reserve multi-select
      // checkboxes and multi-selection for explicit selection mode only.
      if isSelected || (isMultiSelectMode && isMultiSelected) {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: isMultiSelectMode && isMultiSelected ? 3 : 2)
      }
    }
    .overlay(alignment: .topLeading) {
      // Multi-select checkbox
      if isMultiSelectMode {
        Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isMultiSelected ? Color.accentColor : .white)
          .shadow(color: .black.opacity(0.5), radius: 2)
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .topTrailing) {
      // Hover favorite button
      if isHovered && !isMultiSelectMode {
        Button {
          onFavoriteToggle()
        } label: {
          Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            .font(.caption)
            .foregroundStyle(item.isFavorite ? .red : .white)
            .padding(6)
            .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.isFavorite ? "Unfavorite" : "Favorite"))
        .accessibilityHint(Text("Toggle favorite"))
        .padding(4)
        .transition(.opacity)
      }
    }
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Open") {
        onOpen(
          item,
          .zero,
          thumbnailStore.cachedImage(for: item, context: context, size: .thumbnail)
        )
      }
      Button(item.isFavorite ? "Unfavorite" : "Favorite") { onFavoriteToggle() }
      Divider()
      Button("Download Original") { onDownload?() }
      Button("Add to Album…") { onAddToAlbum?() }
      Button("Edit Tags…") { onEditTags?() }
      Divider()
      Button("Get Info") { onSelect() }
    }
  }

  private var contentLayer: some View {
    AssetThumbnailView(
      item: item,
      context: context,
      store: thumbnailStore
    )
    .aspectRatio(item.gridAspectRatio, contentMode: .fit)
    .opacity(heroHidden ? 0 : 1)
    .overlay(alignment: .bottomTrailing) {
      if item.isVideo, !item.timeLabel.isEmpty {
        Text(item.timeLabel)
          .font(.caption2.weight(.medium).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
          .padding(4)
      }
    }
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 3) {
        if item.isFavorite {
          Image(systemName: "heart.fill")
            .foregroundStyle(.white)
        }
        if item.isVideo {
          Image(systemName: "video.fill")
            .foregroundStyle(.white)
        } else if item.isLivePhoto {
          Image(systemName: "livephoto")
            .foregroundStyle(.white)
        }
        if let count = item.stackCount, count > 0 {
          Image(systemName: "square.stack")
          Text("+\(count)").font(.caption2)
        }
      }
      .font(.caption2)
      .foregroundStyle(.white)
      .padding(4)
      .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
    }
    .contentShape(Rectangle())
    .highPriorityGesture(TapGesture().onEnded {
      if isMultiSelectMode {
        onMultiSelectToggle()
      } else {
        onSelect()
      }
    })
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      if !isMultiSelectMode {
        onOpen(
          item,
          .zero,
          thumbnailStore.cachedImage(for: item, context: context, size: .thumbnail)
        )
      }
    })
  }
}
#endif
