#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import ImmichCore

let photoHeroCoordinateSpaceName = "ImmichPhotoHero"

struct InteractiveDismissPresentation: Equatable {
  let offset: CGSize
  let scale: CGFloat
  let backdropOpacity: Double
  let progress: CGFloat

  static let identity = InteractiveDismissPresentation(offset: .zero, scale: 1, backdropOpacity: 0.96, progress: 0)

  var isInteractive: Bool {
    progress > 0.001
  }
}

// MARK: - Main Content View (Photos-style three-pane layout)

struct MainContentView: View {
  @StateObject var appState: AppState
  @StateObject private var thumbnailStore = ThumbnailStore()
  @StateObject private var editingPipeline = PhotoEditingPipeline()
  @State private var spacebarMonitor: Any?
  @State private var heroTransition: HeroTransitionState?
  @State private var heroItemFrames: [String: CGRect] = [:]
  @State private var isHeroExpanded = false
  @State private var interactiveDismissPresentation: InteractiveDismissPresentation = .identity
  @State private var isSearchPresented = false
  @State private var showSearchSuggestions = false

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
    let expandedPresentation: InteractiveDismissPresentation

    static func == (lhs: HeroTransitionState, rhs: HeroTransitionState) -> Bool {
      lhs.itemID == rhs.itemID
        && lhs.direction == rhs.direction
        && lhs.sourceFrame == rhs.sourceFrame
        && lhs.aspectRatio == rhs.aspectRatio
        && lhs.expandedPresentation == rhs.expandedPresentation
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
    .animation(.easeInOut(duration: 0.2), value: appState.sidebarSelection)
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
    .alert("Immich Update Available", isPresented: $appState.showVersionAnnouncement) {
      Button("Release Notes") {
        if let releaseVersion = appState.availableReleaseVersion,
           let url = URL(string: "https://github.com/immich-app/immich/releases/tag/\(releaseVersion)") {
          NSWorkspace.shared.open(url)
        }
        appState.dismissVersionAnnouncement()
      }
      Button("Dismiss", role: .cancel) {
        appState.dismissVersionAnnouncement()
      }
    } message: {
      if let releaseVersion = appState.availableReleaseVersion,
         let serverVersion = appState.availableReleaseServerVersion {
        Text("Server \(serverVersion) is running. Immich \(releaseVersion) is available.")
      } else {
        Text("A newer Immich server version is available.")
      }
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
    interactiveDismissPresentation = .identity
  }

  // MARK: - Detail Area

  @ViewBuilder
  private var detailArea: some View {
    ZStack {
      detailBackgroundLayer
      detailOverlayLayer
      searchSuggestionsLayer
    }
    .background {
      Button("") {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
          isSearchPresented = true
        }
      }
      .keyboardShortcut("f", modifiers: .command)
      .hidden()
      .accessibilityHidden(true)

      Button("") { appState.zoomInPhotoGrid() }
        .keyboardShortcut("+", modifiers: .command)
        .hidden()
        .accessibilityHidden(true)

      Button("") { appState.zoomInPhotoGrid() }
        .keyboardShortcut("=", modifiers: .command)
        .hidden()
        .accessibilityHidden(true)

      Button("") { appState.zoomOutPhotoGrid() }
        .keyboardShortcut("-", modifiers: .command)
        .hidden()
        .accessibilityHidden(true)

      Button("") { thumbnailStore.logTelemetry(reason: "keyboard_shortcut") }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .hidden()
        .accessibilityHidden(true)
    }
    .toolbar {
      if shouldPresentViewer {
        viewerToolbar
      } else {
        browserToolbar
      }
    }
    .coordinateSpace(name: photoHeroCoordinateSpaceName)
    .onChange(of: appState.searchText) { _, newValue in
      showSearchSuggestions = newValue.isEmpty && isSearchPresented
      appState.performSearch(query: newValue)
    }
    .onChange(of: isSearchPresented) { _, presented in
      if presented {
        appState.selectedItemID = nil
        showSearchSuggestions = appState.searchText.isEmpty
      } else {
        appState.searchText = ""
        showSearchSuggestions = false
      }
    }
    .onChange(of: appState.selectedItemID) { _, newID in
      if newID != nil && isSearchPresented {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
          isSearchPresented = false
        }
      }
    }
  }

  private var detailBackgroundLayer: some View {
    VStack(spacing: 0) {
      contentHeader
      routedContentView
    }
    .background(.background)
    .opacity(browserOpacity)
    .allowsHitTesting(!shouldPresentViewer)
    .simultaneousGesture(TapGesture().onEnded {
      dismissSearchFieldFocus()
    })
    .overlay(alignment: .bottom) {
      if let notification = appState.uploadNotification {
        UploadFailureBanner(
          filename: notification.filename,
          reason: notification.reason,
          onDismiss: { appState.dismissUploadNotification() }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder
  private var detailOverlayLayer: some View {
    if shouldPresentViewer, let item = appState.selectedItem {
      PhotoDetailView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        editingPipeline: editingPipeline,
        initialDisplayImage: heroSeedImage(for: item),
        isHeroTransitioning: heroTransition?.itemID == item.id,
        onDismissPresentationChanged: { interactiveDismissPresentation = $0 },
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

  @ViewBuilder
  private var searchSuggestionsLayer: some View {
    if showSearchSuggestions && !appState.recentSearches.isEmpty {
      SearchSuggestionsOverlay(
        recentSearches: appState.recentSearches,
        onSelect: { query in
          appState.searchText = query
          showSearchSuggestions = false
        },
        onClearAll: {
          appState.clearRecentSearches()
        }
      )
      .frame(maxWidth: 260, alignment: .trailing)
      .padding(.trailing, 16)
      .padding(.top, 56)
      .zIndex(10)
      .transition(.opacity)
    }
  }

  private var shouldPresentViewer: Bool {
    appState.isViewingPhoto || heroTransition != nil
  }

  private var browserOpacity: Double {
    if heroTransition != nil {
      return 1
    }
    return appState.isViewingPhoto ? Double(interactiveDismissPresentation.progress) : 1
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
    case .map: "Map"
    case .favorites: "Favorites"
    case .videos: "Videos"
    case .livePhotos: "Live Photos"
    case .panoramas: "Panoramas"
    case .screenshots: "Screenshots"
    case .imports: "Imports"
    case .recentlyDeleted: "Recently Deleted"
    case .allAlbums: "Albums"
    case .allPeople: "People"
    case .allMemories: "Memories"
    case .album(let id): appState.albums.first(where: { $0.id == id })?.albumName ?? "Album"
    case .pinnedAlbum(let id): appState.albums.first(where: { $0.id == id })?.albumName ?? "Album"
    case .person(let id): appState.people.first(where: { $0.id == id })?.name ?? "Person"
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
    case .map:
      MapBrowserView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        onOpenAsset: handleOpenAsset
      )
    case .allAlbums:
      AllAlbumsView(appState: appState, thumbnailStore: thumbnailStore)
    case .allPeople:
      AllPeopleView(appState: appState, thumbnailStore: thumbnailStore)
    case .allMemories:
      AllMemoriesView(appState: appState, thumbnailStore: thumbnailStore)
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
    case .screenshots:
      LibraryGridView(
        appState: appState,
        thumbnailStore: thumbnailStore,
        heroHiddenItemID: activeHeroHiddenItemID,
        onOpenAsset: handleOpenAsset,
        onHeroFramesChanged: { heroItemFrames = $0 }
      )
        .task { await appState.loadScreenshots() }
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
    // Left: Zoom −/+ capsule
    ToolbarItem(placement: .navigation) {
      if showsPhotoGridZoomControl {
        PhotoGridZoomControl(
          canZoomOut: appState.canZoomOutPhotoGrid,
          canZoomIn: appState.canZoomInPhotoGrid,
          onZoomOut: appState.zoomOutPhotoGrid,
          onZoomIn: appState.zoomInPhotoGrid
        )
      }
    }

    // Center: Years | Months | All Photos segmented control (Library only)
    ToolbarItem(placement: .principal) {
      if showsTimelineViewModePicker {
        Picker("", selection: $appState.timelineViewMode) {
          ForEach(AppState.TimelineViewMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
      }
    }

    // Right: Search field
    ToolbarItem(placement: .automatic) {
      ToolbarSearchField(
        text: $appState.searchText,
        isPresented: $isSearchPresented,
        searchType: $appState.searchType,
        searchFilters: $appState.searchFilters
      )
    }

    // Right: Action buttons grouped in capsule pill
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

        ToolbarActionGroup(actions: [
          .init(icon: "heart", help: "Favorite Selected", enabled: !appState.selectedItemIDs.isEmpty) {
            appState.batchFavorite()
          },
          .init(icon: "arrow.down.circle", help: "Download Selected", enabled: !appState.selectedItemIDs.isEmpty) {
            appState.batchDownload()
          },
          .init(icon: "rectangle.stack.badge.plus", help: "Add to Album", enabled: !appState.selectedItemIDs.isEmpty) {
            appState.showAddToAlbumSheet = true
          },
          .init(icon: "tag", help: "Add Tags", enabled: !appState.selectedItemIDs.isEmpty) {
            appState.presentTagEditor(
              for: Array(appState.selectedItemIDs),
              currentTags: [],
              title: "Tag Selected Items"
            )
          },
          .init(icon: "trash", help: "Trash Selected", enabled: !appState.selectedItemIDs.isEmpty) {
            appState.batchTrash()
          },
        ])
      }

      Button {
        appState.toggleMultiSelect()
      } label: {
        Image(systemName: appState.isMultiSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
      }
      .help(appState.isMultiSelectMode ? "Exit Selection" : "Select Multiple")
      .accessibilityLabel(appState.isMultiSelectMode ? "Exit Selection" : "Select Multiple")

      Button {
        thumbnailStore.logTelemetry(reason: "pre_refresh")
        Task { await appState.loadRemoteTimeline(reset: true) }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Refresh Library")
      .accessibilityLabel("Refresh Library")
      .disabled(appState.isLoadingTimeline)

      Button {
        importFromFinder()
      } label: {
        Image(systemName: "plus")
      }
      .help("Import Files")
      .accessibilityLabel("Import Files")

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
        Image(systemName: "ellipsis.circle")
      }
      .help("More Options")
      .accessibilityLabel("More Options")
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
      .accessibilityLabel("Back to Library")
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
        .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

        if !item.isVideo {
          Button {
            withAnimation(.easeInOut(duration: 0.25)) {
              appState.isEditing.toggle()
            }
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .help("Edit")
          .accessibilityLabel("Edit")
        }

        Button {
          appState.showInfoPopover.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .accessibilityLabel("Show Info")
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
        .accessibilityLabel("Edit Tags")

        Button {
          appState.downloadAsset(item.id)
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .help("Download Original")
        .accessibilityLabel("Download Original")
        .disabled(appState.isDownloading)

        ShareButton(appState: appState, assetID: item.id)

        Button {
          appState.trashItem(item.id)
        } label: {
          Image(systemName: "trash")
        }
        .help("Move to Trash")
        .accessibilityLabel("Move to Trash")
      }
    }
  }

  // MARK: - Helpers

  private func dismissSearchFieldFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    if isSearchPresented && appState.searchText.isEmpty {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
        isSearchPresented = false
      }
    }
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

  private func handleOpenAsset(_ item: AppState.PhotoItem, sourceFrame: CGRect, sourceImage: NSImage?) {
    appState.selectedItemID = item.id
    appState.isViewingLivePhoto = false
    appState.isEditing = false
    interactiveDismissPresentation = .identity

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
      aspectRatio: preferredHeroAspectRatio(for: item, image: sourceImage),
      expandedPresentation: .identity
    )
    isHeroExpanded = false

    withAnimation(.easeOut(duration: 0.12)) {
      appState.isViewingPhoto = true
    }

    DispatchQueue.main.async {
      guard heroTransition?.itemID == item.id else { return }
      withAnimation(.easeInOut(duration: 0.24)) {
        isHeroExpanded = true
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
      guard heroTransition?.itemID == item.id else { return }
      heroTransition = nil
      isHeroExpanded = false
    }
  }

  private func closeViewer(_ presentation: InteractiveDismissPresentation = .identity) {
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
      interactiveDismissPresentation = .identity
      return
    }

    let expandedPresentation = presentation.isInteractive
      ? presentation
      : .identity

    heroTransition = HeroTransitionState(
      itemID: item.id,
      direction: .closing,
      sourceFrame: destinationFrame,
      image: heroImage,
      aspectRatio: preferredHeroAspectRatio(for: item, image: heroImage),
      expandedPresentation: expandedPresentation
    )
    isHeroExpanded = true

    DispatchQueue.main.async {
      guard heroTransition?.itemID == item.id else { return }
      withAnimation(.easeInOut(duration: 0.22)) {
        appState.isViewingPhoto = false
        isHeroExpanded = false
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
      guard heroTransition?.itemID == item.id else { return }
      heroTransition = nil
      isHeroExpanded = false
      interactiveDismissPresentation = .identity
    }
  }

  private func heroSeedImage(for item: AppState.PhotoItem) -> NSImage? {
    guard heroTransition?.itemID == item.id else { return nil }
    return heroTransition?.image
  }

  private func bestAvailableHeroImage(for item: AppState.PhotoItem) -> NSImage? {
    // Prefer smaller decoded images for hero transitions to keep open/close animations
    // responsive even when full-resolution assets are loaded in the detail view.
    thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
      ?? heroTransition?.image
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .original)
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
    case .collections, .map, .allAlbums, .allPeople, .allMemories:
      return false
    default:
      return true
    }
  }

  private var showsTimelineViewModePicker: Bool {
    (appState.sidebarSelection == .library || appState.sidebarSelection == nil)
    && !appState.isViewingPhoto
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

struct AllPeopleView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  private var visiblePeople: [Person] {
    appState.people.filter { !$0.isHidden }
  }

  var body: some View {
    if visiblePeople.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "person.2")
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.quaternary)
        Text("No people")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 16)], spacing: 20) {
          ForEach(visiblePeople) { person in
            PersonCard(person: person, context: appState.thumbnailContext, thumbnailStore: thumbnailStore)
              .onTapGesture {
                appState.sidebarSelection = .person(id: person.id)
              }
          }
        }
        .padding(20)
      }
    }
  }
}

struct AllMemoriesView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  var body: some View {
    if appState.memories.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "memories")
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.quaternary)
        Text("No memories")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], spacing: 16) {
          ForEach(appState.memories) { memory in
            MemoryCard(memory: memory, context: appState.thumbnailContext, thumbnailStore: thumbnailStore)
              .onTapGesture {
                appState.sidebarSelection = .memory(id: memory.id)
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
        .onTapGesture { appState.selectedItemID = nil }
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

      ZStack {
        Rectangle()
          .fill(.quaternary)
          .frame(width: 1, height: 18)
      }
      .frame(width: 10, height: 28)

      toolbarButton(systemName: "plus", isEnabled: canZoomIn, action: onZoomIn)
        .help("Show Fewer Photos")
    }
    .frame(height: 32)
    .padding(3)
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
        .frame(width: 32, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .disabled(!isEnabled)
  }
}

struct ToolbarActionGroup: View {
  struct Action: Identifiable {
    let id: String
    let icon: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    init(icon: String, help: String, enabled: Bool = true, action: @escaping () -> Void) {
      self.id = icon
      self.icon = icon
      self.help = help
      self.enabled = enabled
      self.action = action
    }
  }

  let actions: [Action]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 16)
        }

        Button(action: item.action) {
          Image(systemName: item.icon)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(item.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!item.enabled)
        .help(item.help)
        .accessibilityLabel(Text(item.help))
      }
    }
    .padding(2)
    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    .overlay {
      Capsule(style: .continuous)
        .strokeBorder(.quaternary.opacity(0.9))
    }
  }
}

private struct HeroOpenOverlay: View {
  let heroState: MainContentView.HeroTransitionState
  let isExpanded: Bool

  var body: some View {
    GeometryReader { proxy in
      let expandedFrame = expandedFrame(in: proxy.size)
      let activeFrame = isExpanded ? expandedFrame : heroState.sourceFrame

      ZStack(alignment: .topLeading) {
        Color.black
          .opacity(isExpanded ? heroState.expandedPresentation.backdropOpacity : 0)
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

  private func expandedFrame(in size: CGSize) -> CGRect {
    let targetFrame = targetFrame(in: size)
    let scaledWidth = targetFrame.width * heroState.expandedPresentation.scale
    let scaledHeight = targetFrame.height * heroState.expandedPresentation.scale
    let origin = CGPoint(
      x: targetFrame.midX - (scaledWidth / 2) + heroState.expandedPresentation.offset.width,
      y: targetFrame.midY - (scaledHeight / 2) + heroState.expandedPresentation.offset.height
    )
    return CGRect(origin: origin, size: CGSize(width: scaledWidth, height: scaledHeight))
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
// MARK: - Upload Failure Banner

struct UploadFailureBanner: View {
  let filename: String
  let reason: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .font(.system(size: 16))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Upload failed: \(filename)")
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.quaternary)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    .frame(maxWidth: 420)
  }
}

#endif
