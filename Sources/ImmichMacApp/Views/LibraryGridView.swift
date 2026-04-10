#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

private let photoGridCoordinateSpace = "ImmichPhotoGrid"
private let libraryTopAnchorID = "ImmichLibraryTopAnchor"

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
  @State private var itemFrameBuckets: [SpatialBucket: [String]] = [:]
  @State private var heroItemFrames: [String: CGRect] = [:]
  @State private var dragSelectionState: DragSelectionState?
  @State private var keyboardScrollTargetID: String?
  @State private var pendingTimelineScrollToTop = false
  @FocusState private var isKeyboardFocused: Bool

  private struct SpatialBucket: Hashable {
    let x: Int
    let y: Int
  }

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

  private var yearsGridColumns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
  }

  // MARK: - Years Grid

  private func yearsGrid(scrollProxy: ScrollViewProxy) -> some View {
    let context = appState.thumbnailContext
    return interactiveGridChrome(
      ScrollView {
      LazyVGrid(columns: yearsGridColumns, spacing: 8) {
        ForEach(appState.libraryYearSections) { section in
          if let item = section.representativeItem ?? section.items.first {
            Button {
              // Switch to months view
              appState.timelineViewMode = .months
              // Bonus: scroll to that year? (Optional stretch goal)
            } label: {
              AssetThumbnailView(
                item: item,
                context: context,
                store: thumbnailStore
              )
              .aspectRatio(1.0, contentMode: .fill)
              .frame(minWidth: 0, maxWidth: .infinity)
              .clipped()
              .overlay(alignment: .topLeading) {
                Text(section.title)
                  .font(.system(size: 48, weight: .bold))
                  .foregroundStyle(.white)
                  .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                  .padding([.top, .leading], 12)
              }
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
    },
      clearSelection: { appState.selectedItemID = nil }
    )
    .animation(.easeInOut(duration: 0.22), value: appState.photoGridScaleIndex)
  }

  // MARK: - Months Mosaic

  private func monthsMosaic(scrollProxy: ScrollViewProxy) -> some View {
    let context = appState.thumbnailContext
    let sections = appState.librarySections
    return interactiveGridChrome(
      ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        ForEach(sections) { section in
          VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
              .font(.title2.weight(.bold))
              .foregroundStyle(.primary)
              .padding(.horizontal, 8)

            monthsMosaicSection(items: section.items, context: context)
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
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
    },
      clearSelection: { appState.selectedItemID = nil }
    )
    .animation(.easeInOut(duration: 0.22), value: appState.photoGridScaleIndex)
  }

  @ViewBuilder
  private func monthsMosaicSection(items: [AppState.PhotoItem], context: AppState.ThumbnailContext?) -> some View {
    let spacing: CGFloat = 8
    VStack(spacing: spacing) {
      if items.count >= 3 {
        HStack(spacing: spacing) {
          mosaicCell(item: items[0], context: context)
            .aspectRatio(0.8, contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity)
            .layoutPriority(1)
          
          VStack(spacing: spacing) {
            mosaicCell(item: items[1], context: context)
              .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
              .clipped()
            
            mosaicCell(item: items[2], context: context)
              .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
              .clipped()
          }
          .frame(minWidth: 0, maxWidth: .infinity)
        }
      } else if items.count == 2 {
        HStack(spacing: spacing) {
          mosaicCell(item: items[0], context: context)
            .frame(maxWidth: .infinity)
            .aspectRatio(1.0, contentMode: .fill)
          mosaicCell(item: items[1], context: context)
            .frame(maxWidth: .infinity)
            .aspectRatio(1.0, contentMode: .fill)
        }
      } else if items.count == 1 {
        mosaicCell(item: items[0], context: context)
          .frame(maxWidth: .infinity)
          .aspectRatio(1.5, contentMode: .fill)
      }

      // Rest of items in grid
      if items.count > 3 {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 4), spacing: spacing) {
          ForEach(items.dropFirst(3)) { item in
            mosaicCell(item: item, context: context)
              .aspectRatio(1.0, contentMode: .fill)
              .clipped()
          }
        }
      }
    }
  }

  private func mosaicCell(item: AppState.PhotoItem, context: AppState.ThumbnailContext?) -> some View {
    Button {
      appState.selectedItemID = item.id
      onOpenAsset(
        item,
        heroItemFrames[item.id] ?? itemFrames[item.id] ?? .zero,
        thumbnailStore.cachedImage(for: item, context: context, size: .thumbnail)
      )
    } label: {
      AssetThumbnailView(
        item: item,
        context: context,
        store: thumbnailStore
      )
      .overlay(alignment: .topLeading) {
        Text("\(item.dayOfMonth)")
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
          .padding([.top, .leading], 8)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
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
    }
    .buttonStyle(.plain)
    .id(item.id)
  }

  var body: some View {
    ScrollViewReader { proxy in
      Group {
        if appState.filteredItems.isEmpty {
          if appState.isLoadingTimeline || appState.isSearching {
            loadingView
          } else {
            emptyView
          }
        } else if isLibraryTimeline && appState.timelineViewMode == .years {
          yearsGrid(scrollProxy: proxy)
        } else if isLibraryTimeline && appState.timelineViewMode == .months {
          monthsMosaic(scrollProxy: proxy)
        } else {
          flatGrid(scrollProxy: proxy)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: appState.timelineViewMode)
      .onChange(of: appState.isMultiSelectMode) { _, isEnabled in
        if !isEnabled {
          dragSelectionState = nil
        }
      }
      .onChange(of: appState.timelineViewMode) { previousMode, newMode in
        guard isLibraryTimeline else { return }
        guard previousMode != .allPhotos, newMode == .allPhotos else { return }
        pendingTimelineScrollToTop = true
        DispatchQueue.main.async {
          isKeyboardFocused = true
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
    }
  }

  /// Flat ordered list of all visible items matching the current grid order.
  private var orderedItems: [AppState.PhotoItem] {
    let isLibrary = appState.sidebarSelection == .library || appState.sidebarSelection == nil
    if isLibrary && appState.searchText.isEmpty {
      if appState.timelineViewMode == .months {
        return appState.librarySections.flatMap(\.items)
      } else if appState.timelineViewMode == .years {
        return appState.libraryYearSections.compactMap { $0.representativeItem ?? $0.items.first }
      }
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

  private func interactiveGridChrome<Content: View>(
    _ content: Content,
    clearSelection: @escaping () -> Void
  ) -> some View {
    content
      .focusable()
      .focused($isKeyboardFocused)
      .focusEffectDisabled()
      .overlay { scrubSelectionOverlay }
      .coordinateSpace(name: photoGridCoordinateSpace)
      .onTapGesture {
        clearSelection()
        isKeyboardFocused = true
      }
      .onPreferenceChange(PhotoGridItemFramePreferenceKey.self) { updateItemFrames($0) }
      .onPreferenceChange(PhotoHeroSourceFramePreferenceKey.self) { frames in
        heroItemFrames = frames
        onHeroFramesChanged(frames)
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
    let itemIndices = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, new in new })
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

  private var isLibraryTimeline: Bool {
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
    let bucket = spatialBucket(for: location)
    guard let candidateIDs = itemFrameBuckets[bucket] else {
      return nil
    }

    for itemID in candidateIDs {
      guard let frame = itemFrames[itemID] else { continue }
      if frame.contains(location) {
        return itemID
      }
    }
    return nil
  }

  private var spatialBucketSize: CGFloat {
    max(appState.photoGridThumbnailWidth + appState.photoGridSpacing, 1)
  }

  private func spatialBucket(for point: CGPoint) -> SpatialBucket {
    SpatialBucket(
      x: Int(floor(point.x / spatialBucketSize)),
      y: Int(floor(point.y / spatialBucketSize))
    )
  }

  private func rebuildItemFrameBuckets(from frames: [String: CGRect]) -> [SpatialBucket: [String]] {
    let bucketSize = spatialBucketSize
    var buckets: [SpatialBucket: [String]] = [:]

    for (itemID, frame) in frames {
      let minX = Int(floor(frame.minX / bucketSize))
      let maxX = Int(floor((max(frame.maxX, frame.minX + 1) - 1) / bucketSize))
      let minY = Int(floor(frame.minY / bucketSize))
      let maxY = Int(floor((max(frame.maxY, frame.minY + 1) - 1) / bucketSize))

      for x in minX...maxX {
        for y in minY...maxY {
          buckets[SpatialBucket(x: x, y: y), default: []].append(itemID)
        }
      }
    }

    return buckets
  }

  private func updateItemFrames(_ frames: [String: CGRect]) {
    itemFrames = frames
    itemFrameBuckets = rebuildItemFrameBuckets(from: frames)
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

  // MARK: - Flat Grid

  private func flatGrid(scrollProxy: ScrollViewProxy) -> some View {
    let context = appState.thumbnailContext
    let selectedID = appState.selectedItemID
    return interactiveGridChrome(
      ScrollView {
      Color.clear
        .frame(height: 0)
        .id(libraryTopAnchorID)

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
    .onAppear {
      isKeyboardFocused = true
      guard pendingTimelineScrollToTop else { return }
      scrollToMostRecent(using: scrollProxy)
    },
      clearSelection: { appState.selectedItemID = nil }
    )
    .animation(.easeInOut(duration: 0.22), value: appState.photoGridScaleIndex)
  }

  private func scrollToMostRecent(using proxy: ScrollViewProxy) {
    withAnimation(.easeInOut(duration: 0.22)) {
      proxy.scrollTo(libraryTopAnchorID, anchor: .top)
    }
    pendingTimelineScrollToTop = false
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
      Image(systemName: !appState.searchText.isEmpty ? "magnifyingglass" : "photo.on.rectangle.angled")
        .font(.system(size: 48, weight: .light))
        .foregroundStyle(.quaternary)
        .accessibilityHidden(true)

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
    .shadow(
      color: .black.opacity(isHovered && !isSelected ? 0.15 : 0),
      radius: isHovered && !isSelected ? 8 : 0,
      y: isHovered && !isSelected ? 4 : 0
    )
    .scaleEffect(isHovered && !isSelected && !isMultiSelectMode ? 1.02 : 1.0)
    .animation(.easeOut(duration: 0.2), value: isHovered)
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
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.accentColor, lineWidth: isMultiSelectMode && isMultiSelected ? 3 : 2)
        .opacity(isSelected || (isMultiSelectMode && isMultiSelected) ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isMultiSelected)
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
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
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
      if let onDownload = onDownload {
        Button("Download Original") { onDownload() }
      }
      if let onAddToAlbum = onAddToAlbum {
        Button("Add to Album…") { onAddToAlbum() }
      }
      if let onEditTags = onEditTags {
        Button("Edit Tags…") { onEditTags() }
      }
      if onDownload != nil || onAddToAlbum != nil || onEditTags != nil {
        Divider()
      }
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
            .accessibilityHidden(true)
        }
        if item.isVideo {
          Image(systemName: "video.fill")
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        } else if item.isLivePhoto {
          Image(systemName: "livephoto")
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        }
        if let count = item.stackCount, count > 0 {
          Image(systemName: "square.stack")
            .accessibilityHidden(true)
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
