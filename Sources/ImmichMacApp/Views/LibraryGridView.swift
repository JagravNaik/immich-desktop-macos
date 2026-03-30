#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// MARK: - Library Grid View (Photos-style chronological timeline)

struct LibraryGridView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  private let gridColumns = [
    GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 2),
  ]

  var body: some View {
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
    .onKeyPress(.leftArrow) { moveSelection(by: -1); return .handled }
    .onKeyPress(.rightArrow) { moveSelection(by: 1); return .handled }
    .onKeyPress(.upArrow) { moveSelection(by: -columnsEstimate); return .handled }
    .onKeyPress(.downArrow) { moveSelection(by: columnsEstimate); return .handled }
    .onKeyPress(.return) { openSelected(); return .handled }
    .dropDestination(for: URL.self) { urls, _ in
      appState.importFiles(urls)
      return true
    }
  }

  /// Flat ordered list of all visible items matching the current grid order.
  private var orderedItems: [AppState.PhotoItem] {
    if shouldShowSectionedTimeline {
      return appState.librarySections.flatMap(\.items)
    }
    return appState.filteredItems
  }

  /// Rough estimate of columns visible in the adaptive grid (minimum 140pt).
  private var columnsEstimate: Int {
    max(Int(NSApp.mainWindow?.frame.width ?? 900) / 160, 1)
  }

  private func moveSelection(by offset: Int) {
    let items = orderedItems
    guard !items.isEmpty else { return }
    guard let currentID = appState.selectedItemID,
          let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
      appState.selectedItemID = items.first?.id
      return
    }
    let newIndex = min(max(currentIndex + offset, 0), items.count - 1)
    appState.selectedItemID = items[newIndex].id
  }

  private func openSelected() {
    guard appState.selectedItemID != nil else { return }
    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
      appState.isViewingLivePhoto = false
      appState.isViewingPhoto = true
    }
  }

  private var shouldShowSectionedTimeline: Bool {
    (appState.sidebarSelection == .library || appState.sidebarSelection == nil)
    && appState.searchText.isEmpty
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
            LazyVGrid(columns: gridColumns, spacing: 2) {
              ForEach(section.items) { item in
                PhotoGridCell(
                  item: item,
                  isSelected: item.id == selectedID,
                  isMultiSelected: appState.selectedItemIDs.contains(item.id),
                  isMultiSelectMode: appState.isMultiSelectMode,
                  context: context,
                  thumbnailStore: thumbnailStore,
                  onSelect: { appState.selectedItemID = item.id },
                  onOpen: {
                    appState.selectedItemID = item.id
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                      appState.isViewingLivePhoto = false
                      appState.isViewingPhoto = true
                    }
                  },
                  onFavoriteToggle: { appState.toggleFavorite(for: item.id) },
                  onMultiSelectToggle: { appState.toggleItemSelection(item.id) },
                  onDownload: { appState.downloadAsset(item.id) },
                  onAddToAlbum: {
                    appState.selectedItemIDs = [item.id]
                    appState.showAddToAlbumSheet = true
                  }
                )
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
      .padding(.horizontal, 2)
      .padding(.vertical, 4)
    }
  }

  // MARK: - Flat Grid

  private var flatGrid: some View {
    let context = appState.thumbnailContext
    let selectedID = appState.selectedItemID
    return ScrollView {
      LazyVGrid(columns: gridColumns, spacing: 2) {
        ForEach(appState.filteredItems) { item in
          PhotoGridCell(
            item: item,
            isSelected: item.id == selectedID,
            isMultiSelected: appState.selectedItemIDs.contains(item.id),
            isMultiSelectMode: appState.isMultiSelectMode,
            context: context,
            thumbnailStore: thumbnailStore,
            onSelect: { appState.selectedItemID = item.id },
            onOpen: {
              appState.selectedItemID = item.id
              withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                appState.isViewingLivePhoto = false
                appState.isViewingPhoto = true
              }
            },
            onFavoriteToggle: { appState.toggleFavorite(for: item.id) },
            onMultiSelectToggle: { appState.toggleItemSelection(item.id) },
            onDownload: { appState.downloadAsset(item.id) },
            onAddToAlbum: {
              appState.selectedItemIDs = [item.id]
              appState.showAddToAlbumSheet = true
            }
          )
        }
      }
      .padding(.horizontal, 2)
      .padding(.vertical, 4)
    }
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
  let context: AppState.ThumbnailContext?
  let thumbnailStore: ThumbnailStore
  let onSelect: () -> Void
  let onOpen: () -> Void
  let onFavoriteToggle: () -> Void
  let onMultiSelectToggle: () -> Void
  var onDownload: (() -> Void)?
  var onAddToAlbum: (() -> Void)?

  @State private var isHovered = false

  var body: some View {
    ZStack {
      // Thumbnail (edge-to-edge, Photos style)
      AssetThumbnailView(
        item: item,
        context: context,
        store: thumbnailStore
      )
      .aspectRatio(1, contentMode: .fit)

      // Video duration badge (bottom-trailing, macOS Photos style)
      if item.isVideo, !item.timeLabel.isEmpty {
        VStack {
          Spacer()
          HStack {
            Spacer()
            Text(item.timeLabel)
              .font(.caption2.weight(.medium).monospacedDigit())
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
              .padding(4)
          }
        }
      }

      // Bottom-leading badges (favorite, live photo, stack)
      VStack {
        Spacer()
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
          Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(4)
        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
      }
    }
    .overlay {
      // Selection ring
      if isSelected || isMultiSelected {
        RoundedRectangle(cornerRadius: 2)
          .strokeBorder(Color.accentColor, lineWidth: 3)
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
          .contentShape(Rectangle())
          .onTapGesture { onMultiSelectToggle() }
      }
    }
    .overlay(alignment: .topTrailing) {
      // Hover favorite button
      if isHovered {
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
        .padding(4)
        .transition(.opacity)
      }
    }
    .onHover { isHovered = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if !isMultiSelectMode { onOpen() }
    }
    .onTapGesture(count: 1) {
      if isMultiSelectMode {
        onMultiSelectToggle()
      } else {
        onSelect()
      }
    }
    .contextMenu {
      Button("Open") { onOpen() }
      Button(item.isFavorite ? "Unfavorite" : "Favorite") { onFavoriteToggle() }
      Divider()
      Button("Download Original") { onDownload?() }
      Button("Add to Album…") { onAddToAlbum?() }
      Divider()
      Button("Get Info") { onSelect() }
    }
  }
}
#endif
