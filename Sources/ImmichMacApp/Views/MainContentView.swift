#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// MARK: - Main Content View (Photos-style three-pane layout)

struct MainContentView: View {
  @StateObject var appState: AppState
  @StateObject private var thumbnailStore = ThumbnailStore()
  @State private var spacebarMonitor: Any?

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
      dismissViewer()
    }
    .sheet(isPresented: $appState.showCreateAlbumSheet) {
      CreateAlbumSheet(appState: appState)
    }
    .sheet(isPresented: $appState.showAddToAlbumSheet) {
      AddToAlbumSheet(appState: appState)
    }
  }

  private func dismissViewer() {
    if appState.isViewingPhoto {
      appState.isViewingPhoto = false
      appState.isViewingLivePhoto = false
      appState.isEditing = false
    }
  }

  // MARK: - Detail Area

  @ViewBuilder
  private var detailArea: some View {
    ZStack {
      if appState.isViewingPhoto, let item = appState.selectedItem {
        // Photo viewer with hero transition
        PhotoDetailView(
          appState: appState,
          thumbnailStore: thumbnailStore
        )

        // Editing sidebar (right side, slides in)
        if appState.isEditing {
          HStack(spacing: 0) {
            Spacer()
            EditingSidebar(appState: appState, item: item)
              .transition(.move(edge: .trailing))
          }
        }
      } else {
        // Browser view
        VStack(spacing: 0) {
          contentHeader
          routedContentView
        }
        .background(.background)
      }
    }
    .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search")
    .onChange(of: appState.searchText) { _, newValue in
      appState.performSmartSearch(query: newValue)
    }
    .toolbar {
      if appState.isViewingPhoto {
        viewerToolbar
      } else {
        browserToolbar
      }
    }
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
      LibraryGridView(appState: appState, thumbnailStore: thumbnailStore)
        .task(id: id) { await appState.loadAlbum(id) }
    case .person(let id):
      LibraryGridView(appState: appState, thumbnailStore: thumbnailStore)
        .task(id: id) { await appState.loadPerson(id) }
    case .sharedLink(let id):
      LibraryGridView(appState: appState, thumbnailStore: thumbnailStore)
        .task(id: id) { appState.loadSharedLink(id) }
    case .memory(let id):
      LibraryGridView(appState: appState, thumbnailStore: thumbnailStore)
        .task(id: id) { appState.loadMemory(id) }
    case .recentlyDeleted:
      RecentlyDeletedView(appState: appState, thumbnailStore: thumbnailStore)
    default:
      LibraryGridView(appState: appState, thumbnailStore: thumbnailStore)
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
          appState.selectAllItems()
        } label: {
          Image(systemName: "checkmark.circle.fill")
        }
        .help("Select All")

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

      // View options
      Menu {
        Button("Hide Screenshots") {}
        Button("Show Only Photos") {}
        Button("Show Only Videos") {}
        Divider()
        Button("Sort by Date Captured") {}
        Button("Sort by Date Added") {}
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          appState.isViewingPhoto = false
          appState.isViewingLivePhoto = false
          appState.isEditing = false
        }
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

  private func installSpacebarHandler() {
    guard spacebarMonitor == nil else { return }
    spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 49 { // Spacebar
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           NSStringFromClass(type(of: firstResponder)).contains("NSTextView") {
          return event
        }
        if appState.appPhase == .library, appState.selectedItem != nil {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
            if !appState.isViewingPhoto {
              appState.isViewingLivePhoto = false
            }
            appState.isViewingPhoto.toggle()
            if !appState.isViewingPhoto {
              appState.isEditing = false
            }
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

  private let gridColumns = [
    GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 2),
  ]

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
          LazyVGrid(columns: gridColumns, spacing: 2) {
            ForEach(appState.trashedItems) { item in
              PhotoGridCell(
                item: item,
                isSelected: item.id == appState.selectedItemID,
                isMultiSelected: false,
                isMultiSelectMode: false,
                context: appState.thumbnailContext,
                thumbnailStore: thumbnailStore,
                onSelect: { appState.selectedItemID = item.id },
                onOpen: {
                  appState.selectedItemID = item.id
                  withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    appState.isViewingPhoto = true
                  }
                },
                onFavoriteToggle: {},
                onMultiSelectToggle: {}
              )
              .contextMenu {
                Button("Restore") { appState.restoreItem(item.id) }
              }
            }
          }
          .padding(12)
        }
      }
    }
    .task { await appState.loadTrashedAssets() }
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
