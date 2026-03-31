#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

let photoHeroCoordinateSpaceName = "ImmichPhotoHero"

// MARK: - Main Content View (Photos-style three-pane layout)

struct MainContentView: View {
  @StateObject var appState: AppState
  @StateObject private var thumbnailStore = ThumbnailStore()
  @StateObject private var editingPipeline = PhotoEditingPipeline()
  @State private var spacebarMonitor: Any?
  @State private var heroTransition: HeroTransitionState?
  @State private var heroItemFrames: [String: CGRect] = [:]
  @State private var isHeroExpanded = false

  struct HeroTransitionState: Equatable {
    enum Direction: Equatable {
      case opening
      case closing
    }

    let itemID: String
    let direction: Direction
    let sourceFrame: CGRect
    let image: NSImage
    let aspectRatio: CGFloat

    static func == (lhs: HeroTransitionState, rhs: HeroTransitionState) -> Bool {
      lhs.itemID == rhs.itemID
        && lhs.direction == rhs.direction
        && lhs.sourceFrame == rhs.sourceFrame
        && lhs.aspectRatio == rhs.aspectRatio
    }
  }

  var body: some View {
    ZStack {
      switch appState.appPhase {
      case .launching:
        AuthShell {
          ProgressView("Connecting…")
            .controlSize(.large)
            .padding(32)
        }
      case .serverSetup:
        AuthShell { ServerSetupCard(appState: appState) }
      case .login:
        AuthShell { LoginCard(appState: appState) }
      case .library:
        libraryLayout
      }
    }
    .overlay {
      ForceTouchOverlay(onPressureChange: appState.handlePressureChange)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
    .onAppear {
      appState.autoSignInIfNeeded()
      installSpacebarHandler()
    }
    .onDisappear {
      removeSpacebarHandler()
    }
  }

  // MARK: - Library Layout (Three-Pane)

  private var libraryLayout: some View {
    NavigationSplitView {
      SidebarView(selection: $appState.sidebarSelection, appState: appState)
        .navigationTitle("Immich")
        .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
    } detail: {
      detailArea
    }
    .navigationSplitViewStyle(.balanced)
    .background(SplitViewDividerConfigurator())
    .onChange(of: appState.sidebarSelection) { _, _ in
      heroItemFrames = [:]
      dismissViewer()
    }
    .sheet(isPresented: $appState.showCreateAlbumSheet) {
      CreateAlbumSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showAddToAlbumSheet) {
      AddToAlbumSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showAPIKeysSheet) {
      APIKeysSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showTagsSheet) {
      TagsSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showTagEditorSheet) {
      AssetTagEditorSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showAdminUsersSheet) {
      AdminUsersSheet(appState: appState)
    }
  }

  private func dismissViewer() {
    if appState.isViewingPhoto {
      appState.isViewingPhoto = false
      appState.isViewingLivePhoto = false
      appState.isEditing = false
    }
    heroTransition = nil
    isHeroExpanded = false
  }

  // MARK: - Detail Area

  @ViewBuilder
  private var detailArea: some View {
    ZStack {
      VStack(spacing: 0) {
        contentHeader
        routedContentView
      }
      .background(.background)
      .opacity(browserOpacity)
      .allowsHitTesting(!shouldPresentViewer)

      if shouldPresentViewer, let item = appState.selectedItem {
        PhotoDetailView(
          appState: appState,
          thumbnailStore: thumbnailStore,
          editingPipeline: editingPipeline,
          initialDisplayImage: heroSeedImage(for: item),
          isHeroTransitioning: heroTransition?.itemID == item.id,
          onDismiss: closeViewer
        )
        .opacity(viewerOpacity)
        .allowsHitTesting(appState.isViewingPhoto && heroTransition == nil)

        if appState.isEditing {
          HStack(spacing: 0) {
            Spacer()
            EditingSidebar(appState: appState, pipeline: editingPipeline, item: item)
              .transition(.move(edge: .trailing))
          }
          .opacity(viewerOpacity)
        }
      }

      if let heroTransition {
        HeroOpenOverlay(
          heroState: heroTransition,
          isExpanded: isHeroExpanded
        )
        .zIndex(3)
      }
    }
    .coordinateSpace(name: photoHeroCoordinateSpaceName)
    .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search")
    .onChange(of: appState.searchText) { _, newValue in
      appState.performSmartSearch(query: newValue)
    }
    .toolbar {
      if shouldPresentViewer {
        viewerToolbar
      } else {
        browserToolbar
      }
    }
  }

  private var shouldPresentViewer: Bool {
    appState.isViewingPhoto || heroTransition != nil
  }

  private var browserOpacity: Double {
    if heroTransition != nil {
      return 1
    }
    return appState.isViewingPhoto ? 0 : 1
  }

  private var viewerOpacity: Double {
    if heroTransition != nil {
      return 0
    }
    return appState.isViewingPhoto ? 1 : 0
  }

  private var activeHeroHiddenItemID: String? {
    guard heroTransition?.direction == .opening else { return nil }
    return heroTransition?.itemID
  }

  // MARK: - Content Header (Photos-style)

  private var contentHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(headerTitle)
        .font(.largeTitle.weight(.bold))

      HStack {
        Text(appState.itemCountText)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var headerTitle: String {
    switch appState.sidebarSelection {
    case .library: "Library"
    case .collections: "Collections"
    case .favorites: "Favorites"
    case .videos: "Videos"
    case .livePhotos: "Live Photos"
    case .panoramas: "Panoramas"
    case .screenshots: "Screenshots"
    case .imports: "Imports"
    case .recentlyDeleted: "Recently Deleted"
    case .allAlbums: "Albums"
    case .album(let id): appState.albums.first(where: { $0.id == id })?.albumName ?? "Album"
    case .pinnedAlbum(let id): appState.albums.first(where: { $0.id == id })?.albumName ?? "Album"
    case .person(let id): appState.people.first(where: { $0.id == id })?.name ?? "Person"
    case .sharedLinks: "Shared Links"
    case .sharedLink(let id): appState.sharedLinks.first(where: { $0.id == id })?.description ?? "Shared Link"
    case .memory(let id): appState.memories.first(where: { $0.id == id })?.title ?? "Memory"
    case .none: "Library"
    }
  }

  // MARK: - Routed Content

  @ViewBuilder
  private var routedContentView: some View {
    switch appState.sidebarSelection {
    case .collections:
      CollectionsView(appState: appState, thumbnailStore: thumbnailStore)
    case .sharedLinks:
      SharedLinksView(appState: appState)
    case .allAlbums:
      AllAlbumsView(appState: appState, thumbnailStore: thumbnailStore)
    case .album(let id), .pinnedAlbum(let id):
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
        .task(id: id) { await appState.loadAlbum(id) }
    case .person(let id):
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
        .task(id: id) { await appState.loadPerson(id) }
    case .sharedLink(let id):
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
        .task(id: id) { appState.loadSharedLink(id) }
    case .memory(let id):
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
        .task(id: id) { appState.loadMemory(id) }
    case .recentlyDeleted:
      RecentlyDeletedView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
    default:
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
    }
  }

  // MARK: - Browser Toolbar

  @ToolbarContentBuilder
  private var browserToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if appState.isMultiSelectMode {
        Text("\(appState.selectedItemIDs.count) selected")
          .foregroundStyle(.secondary)
          .font(.callout)

        Button {
          if appState.allItemsSelected {
            appState.deselectAllItems()
          } else {
            appState.selectAllItems()
          }
        } label: {
          Image(systemName: appState.allItemsSelected ? "checkmark.circle.badge.xmark" : "checkmark.circle.fill")
        }
        .help(appState.allItemsSelected ? "Deselect All" : "Select All")

        Button {
          appState.batchFavorite()
        } label: {
          Image(systemName: "heart")
        }
        .help("Favorite Selected")
        .disabled(appState.selectedItemIDs.isEmpty)

        Button {
          appState.batchDownload()
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .help("Download Selected")
        .disabled(appState.selectedItemIDs.isEmpty)

        Button {
          appState.showAddToAlbumSheet = true
        } label: {
          Image(systemName: "rectangle.stack.badge.plus")
        }
        .help("Add to Album")
        .disabled(appState.selectedItemIDs.isEmpty)

        Button {
          appState.presentTagEditor(
            for: Array(appState.selectedItemIDs),
            currentTags: [],
            title: "Tag Selected Items"
          )
        } label: {
          Image(systemName: "tag")
        }
        .help("Add Tags")
        .disabled(appState.selectedItemIDs.isEmpty)

        Button {
          appState.batchTrash()
        } label: {
          Image(systemName: "trash")
        }
        .help("Trash Selected")
        .disabled(appState.selectedItemIDs.isEmpty)
      }

      Button {
        appState.toggleMultiSelect()
      } label: {
        Image(systemName: appState.isMultiSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
      }
      .help(appState.isMultiSelectMode ? "Exit Selection" : "Select Multiple")

      Button {
        importFromFinder()
      } label: {
        Image(systemName: "plus")
      }
      .help("Import Files")

      if showsPhotoGridZoomControl {
        PhotoGridZoomControl(
          canZoomOut: appState.canZoomOutPhotoGrid,
          canZoomIn: appState.canZoomInPhotoGrid,
          onZoomOut: appState.zoomOutPhotoGrid,
          onZoomIn: appState.zoomInPhotoGrid
        )
      }

      // View options
      Menu {
        Button("Hide Screenshots") {
          // TODO: Implement screenshot filtering.
        }
        .disabled(true)
        Button("Show Only Photos") {
          // TODO: Implement photos-only filtering.
        }
        .disabled(true)
        Button("Show Only Videos") {
          // TODO: Implement videos-only filtering.
        }
        .disabled(true)
        Divider()
        Button("Sort by Date Captured") {
          // TODO: Implement captured-date sorting.
        }
        .disabled(true)
        Button("Sort by Date Added") {
          // TODO: Implement added-date sorting.
        }
        .disabled(true)
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
      }
      .help("Filter & Sort")
    }
  }

  // MARK: - Viewer Toolbar

  @ToolbarContentBuilder
  private var viewerToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button {
        closeViewer()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 16, weight: .medium))
      }
      .help("Back to Library")
    }

    ToolbarItem(placement: .principal) {
      if let item = appState.selectedItem {
        VStack(spacing: 0) {
          Text(item.date, style: .date)
            .font(.headline)
          Text(item.date, style: .time)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      if let item = appState.selectedItem {
        Button {
          appState.toggleFavorite(for: item.id)
        } label: {
          Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            .foregroundColor(item.isFavorite ? .red : nil)
        }
        .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

        Button {
          withAnimation(.easeInOut(duration: 0.25)) {
            appState.isEditing.toggle()
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .help("Edit")

        Button {
          appState.showInfoPopover.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .popover(isPresented: $appState.showInfoPopover, arrowEdge: .bottom) {
          AssetInfoInspector(appState: appState, item: item)
        }

        Button {
          Task {
            await presentTagEditor(for: item.id)
          }
        } label: {
          Image(systemName: "tag")
        }
        .help("Edit Tags")

        Button {
          appState.downloadAsset(item.id)
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .help("Download Original")
        .disabled(appState.isDownloading)

        ShareButton(appState: appState, assetID: item.id)

        Button {
          appState.trashItem(item.id)
        } label: {
          Image(systemName: "trash")
        }
        .help("Move to Trash")
      }
    }
  }

  // MARK: - Helpers

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

  private func handleOpenAsset(_ item: AppState.PhotoItem, sourceFrame: CGRect, sourceImage: NSImage?) {
    appState.selectedItemID = item.id
    appState.isViewingLivePhoto = false
    appState.isEditing = false

    guard let sourceImage, sourceFrame != .zero else {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
        appState.isViewingPhoto = true
      }
      return
    }

    heroTransition = HeroTransitionState(
      itemID: item.id,
      direction: .opening,
      sourceFrame: sourceFrame,
      image: sourceImage,
      aspectRatio: preferredHeroAspectRatio(for: item, image: sourceImage)
    )
    isHeroExpanded = false

    withAnimation(.easeOut(duration: 0.12)) {
      appState.isViewingPhoto = true
    }

    DispatchQueue.main.async {
      guard heroTransition?.itemID == item.id else { return }
      withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
        isHeroExpanded = true
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
      guard heroTransition?.itemID == item.id else { return }
      heroTransition = nil
      isHeroExpanded = false
    }
  }

  private func closeViewer() {
    guard appState.isViewingPhoto else { return }

    appState.isViewingLivePhoto = false
    appState.isEditing = false

    guard let item = appState.selectedItem,
          let destinationFrame = heroItemFrames[item.id],
          destinationFrame != .zero,
          let heroImage = bestAvailableHeroImage(for: item)
    else {
      withAnimation(.easeOut(duration: 0.18)) {
        appState.isViewingPhoto = false
      }
      return
    }

    heroTransition = HeroTransitionState(
      itemID: item.id,
      direction: .closing,
      sourceFrame: destinationFrame,
      image: heroImage,
      aspectRatio: preferredHeroAspectRatio(for: item, image: heroImage)
    )
    isHeroExpanded = true

    DispatchQueue.main.async {
      guard heroTransition?.itemID == item.id else { return }
      withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
        appState.isViewingPhoto = false
        isHeroExpanded = false
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
      guard heroTransition?.itemID == item.id else { return }
      heroTransition = nil
      isHeroExpanded = false
    }
  }

  private func heroSeedImage(for item: AppState.PhotoItem) -> NSImage? {
    guard heroTransition?.itemID == item.id else { return nil }
    return heroTransition?.image
  }

  private func bestAvailableHeroImage(for item: AppState.PhotoItem) -> NSImage? {
    thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .original)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
      ?? heroTransition?.image
  }

  private func preferredHeroAspectRatio(for item: AppState.PhotoItem, image: NSImage?) -> CGFloat {
    if let image {
      let size = image.size
      if size.width > 0, size.height > 0 {
        return size.width / size.height
      }
    }

    if item.aspectRatio.isFinite, item.aspectRatio > 0 {
      return item.aspectRatio
    }

    return item.gridAspectRatio
  }

  private var showsPhotoGridZoomControl: Bool {
    switch appState.sidebarSelection {
    case .collections, .sharedLinks, .allAlbums:
      return false
    default:
      return true
    }
  }

  private func installSpacebarHandler() {
    guard spacebarMonitor == nil else { return }
    spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 49 { // Spacebar
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           NSStringFromClass(type(of: firstResponder)).contains("NSTextView") {
          return event
        }
        if appState.appPhase == .library, appState.selectedItem != nil {
          if appState.isViewingPhoto {
            closeViewer()
          } else {
            openSelectedItemWithHero()
          }
          return nil
        }
      }
      return event
    }
  }

  private func removeSpacebarHandler() {
    guard let spacebarMonitor else { return }
    NSEvent.removeMonitor(spacebarMonitor)
    self.spacebarMonitor = nil
  }

  private func openSelectedItemWithHero() {
    guard let item = appState.selectedItem else { return }

    let sourceImage =
      thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .original)
    let sourceFrame = heroItemFrames[item.id] ?? .zero

    handleOpenAsset(item, sourceFrame: sourceFrame, sourceImage: sourceImage)
  }

  private func presentTagEditor(for assetID: String) async {
    do {
      let detail = try await appState.fetchAssetDetail(assetID)
      appState.presentTagEditor(for: [assetID], currentTags: detail.tags, title: "Edit Tags")
    } catch {
      appState.presentTagEditor(for: [assetID], currentTags: [], title: "Edit Tags")
    }
  }
}

// MARK: - Shared Links View (simple list)

struct SharedLinksView: View {
  @ObservedObject var appState: AppState
  @State private var isLoading = true
  @State private var loadError: String?

  var body: some View {
    Group {
      if isLoading {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Loading shared links…")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appState.sharedLinks.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "link")
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(.quaternary)
          Text("No shared links")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
          if let loadError {
            Text(loadError)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 300)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(appState.sharedLinks) { link in
          Button {
            if link.type == "ALBUM", let albumId = link.albumId {
              appState.sidebarSelection = .album(id: albumId)
            } else {
              appState.sidebarSelection = .sharedLink(id: link.id)
            }
          } label: {
            HStack {
              Image(systemName: link.type == "ALBUM" ? "rectangle.stack" : "photo.on.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 24)

              VStack(alignment: .leading, spacing: 2) {
                Text(link.description ?? String(link.key.prefix(12)) + "…")
                  .font(.subheadline)
                Text("\(link.assetCount) items")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              if let expires = link.expiresAt {
                Text("Expires \(expires, style: .relative)")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }

              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .task {
      isLoading = true
      loadError = nil
      let error = await appState.reloadSharedLinks()
      loadError = error
      isLoading = false
    }
  }
}

// MARK: - All Albums View (grid of all albums)

struct AllAlbumsView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  var body: some View {
    if appState.albums.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "rectangle.stack")
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.quaternary)
        Text("No albums")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 16) {
          ForEach(appState.albums) { album in
            AlbumCard(album: album, context: appState.thumbnailContext, thumbnailStore: thumbnailStore) {
              appState.sidebarSelection = .album(id: album.id)
            } onPin: {
              appState.togglePinAlbum(album.id)
            }
            .contextMenu {
              Button("Open Album") {
                appState.sidebarSelection = .album(id: album.id)
              }
              Button("Pin to Sidebar") {
                appState.togglePinAlbum(album.id)
              }
              Divider()
              Button("Delete Album") {
                Task { await appState.deleteAlbum(album.id) }
              }
            }
          }
        }
        .padding(20)
      }
    }
  }
}

// MARK: - Recently Deleted View

struct RecentlyDeletedView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore
  let heroHiddenItemID: String?
  let onOpenAsset: (AppState.PhotoItem, CGRect, NSImage?) -> Void
  let onHeroFramesChanged: ([String: CGRect]) -> Void

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
    Group {
      if appState.isLoadingTrash {
        VStack(spacing: 16) {
          ProgressView().controlSize(.large)
          Text("Loading trash…")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appState.trashedItems.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "trash")
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(.quaternary)
          Text("Trash is empty")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
          Text("Items you delete will appear here for 30 days before being permanently removed.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: gridColumns, spacing: appState.photoGridSpacing) {
            ForEach(appState.trashedItems) { item in
              PhotoGridCell(
                item: item,
                isSelected: item.id == appState.selectedItemID,
                isMultiSelected: false,
                isMultiSelectMode: false,
                heroHidden: heroHiddenItemID == item.id,
                context: appState.thumbnailContext,
                thumbnailStore: thumbnailStore,
                onSelect: { appState.selectedItemID = item.id },
                onOpen: { _, sourceFrame, sourceImage in onOpenAsset(item, sourceFrame, sourceImage) },
                onFavoriteToggle: {},
                onMultiSelectToggle: {}
              )
              .contextMenu {
                Button("Restore") { appState.restoreItem(item.id) }
              }
            }
          }
          .padding(.horizontal, appState.photoGridPadding)
          .padding(.vertical, appState.photoGridPadding)
        }
        .onPreferenceChange(PhotoHeroSourceFramePreferenceKey.self) { onHeroFramesChanged($0) }
      }
    }
    .task { await appState.loadTrashedAssets() }
  }
}

struct PhotoGridZoomControl: View {
  let canZoomOut: Bool
  let canZoomIn: Bool
  let onZoomOut: () -> Void
  let onZoomIn: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      toolbarButton(systemName: "minus", isEnabled: canZoomOut, action: onZoomOut)
        .help("Show More Photos")

      Rectangle()
        .fill(.quaternary)
        .frame(width: 1, height: 16)

      toolbarButton(systemName: "plus", isEnabled: canZoomIn, action: onZoomIn)
        .help("Show Fewer Photos")
    }
    .padding(2)
    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    .overlay {
      Capsule(style: .continuous)
        .strokeBorder(.quaternary.opacity(0.9))
    }
  }

  private func toolbarButton(systemName: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .disabled(!isEnabled)
  }
}

private struct HeroOpenOverlay: View {
  let heroState: MainContentView.HeroTransitionState
  let isExpanded: Bool

  var body: some View {
    GeometryReader { proxy in
      let targetFrame = targetFrame(in: proxy.size)
      let activeFrame = isExpanded ? targetFrame : heroState.sourceFrame

      ZStack(alignment: .topLeading) {
        Color.black
          .opacity(isExpanded ? 0.96 : 0)
          .ignoresSafeArea()

        Image(nsImage: heroState.image)
          .resizable()
          .scaledToFit()
          .frame(width: activeFrame.width, height: activeFrame.height)
          .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 0 : 10, style: .continuous))
          .shadow(color: .black.opacity(isExpanded ? 0 : 0.08), radius: isExpanded ? 0 : 8, y: isExpanded ? 0 : 4)
          .position(x: activeFrame.midX, y: activeFrame.midY)
      }
      .animation(nil, value: heroState.itemID)
    }
    .allowsHitTesting(false)
  }

  private func targetFrame(in size: CGSize) -> CGRect {
    let maxWidth = max(size.width, 200)
    let maxHeight = max(size.height, 200)
    let aspectRatio = heroState.aspectRatio.isFinite && heroState.aspectRatio > 0
      ? heroState.aspectRatio
      : 1

    var width = maxWidth
    var height = width / aspectRatio

    if height > maxHeight {
      height = maxHeight
      width = height * aspectRatio
    }

    let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
    return CGRect(origin: origin, size: CGSize(width: width, height: height))
  }
}

// MARK: - Split View Divider Configurator

/// Share button that provides an NSView anchor for NSSharingServicePicker
struct ShareButton: NSViewRepresentable {
  @ObservedObject var appState: AppState
  let assetID: String

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
    button.bezelStyle = .toolbar
    button.isBordered = false
    button.target = context.coordinator
    button.action = #selector(Coordinator.share(_:))
    button.toolTip = "Share"
    return button
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.appState = appState
    context.coordinator.assetID = assetID
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(appState: appState, assetID: assetID)
  }

  class Coordinator: NSObject {
    var appState: AppState
    var assetID: String

    init(appState: AppState, assetID: String) {
      self.appState = appState
      self.assetID = assetID
    }

    @MainActor @objc func share(_ sender: NSButton) {
      appState.shareAsset(assetID, from: sender)
    }
  }
}

/// Finds the underlying NSSplitView and widens the divider so the resize cursor appears on hover.
private struct SplitViewDividerConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      configureSplitView(from: view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private func configureSplitView(from view: NSView) {
    guard let splitView = findSplitView(from: view) else { return }
    splitView.dividerStyle = .thick
  }

  private func findSplitView(from view: NSView) -> NSSplitView? {
    if let splitView = view as? NSSplitView { return splitView }
    if let parent = view.superview { return findSplitView(from: parent) }
    return nil
  }
}

// MARK: - Create Album Sheet

struct CreateAlbumSheet: View {
  @ObservedObject var appState: AppState
  @State private var name = ""
  @State private var description = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Create Album")
        .font(.title2.weight(.semibold))

      TextField("Album Name", text: $name)
        .textFieldStyle(.roundedBorder)

      TextField("Description (optional)", text: $description)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button("Cancel") {
          appState.showCreateAlbumSheet = false
        }
        Button("Create") {
          let assetIds = appState.isMultiSelectMode ? Array(appState.selectedItemIDs) : []
          Task {
            await appState.createAlbum(name: name, description: description, assetIds: assetIds)
            appState.showCreateAlbumSheet = false
            if appState.isMultiSelectMode {
              appState.selectedItemIDs.removeAll()
              appState.isMultiSelectMode = false
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 380)
  }
}

// MARK: - Add to Album Sheet

struct AddToAlbumSheet: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add to Album")
        .font(.title2.weight(.semibold))

      Text("Choose an album to add \(appState.selectedItemIDs.count) item(s) to:")
        .foregroundStyle(.secondary)

      if appState.albums.isEmpty {
        Text("No albums available.")
          .foregroundStyle(.tertiary)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(spacing: 2) {
            ForEach(appState.albums) { album in
              Button {
                let ids = Array(appState.selectedItemIDs)
                Task {
                  await appState.addAssetsToAlbum(album.id, assetIds: ids)
                  appState.showAddToAlbumSheet = false
                  appState.selectedItemIDs.removeAll()
                  appState.isMultiSelectMode = false
                }
              } label: {
                HStack {
                  Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                  VStack(alignment: .leading) {
                    Text(album.albumName)
                      .font(.subheadline)
                    Text("\(album.assetCount) items")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 300)
      }

      HStack {
        Button("New Album…") {
          appState.showAddToAlbumSheet = false
          appState.showCreateAlbumSheet = true
        }
        Spacer()
        Button("Cancel") {
          appState.showAddToAlbumSheet = false
        }
      }
    }
    .padding(24)
    .frame(width: 380)
  }
}
#endif
