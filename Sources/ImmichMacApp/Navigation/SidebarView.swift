#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

// MARK: - Sidebar Item Model

enum SidebarDestination: Hashable {
  // Top-level
  case library
  case collections

  // Pinned
  case pinnedAlbum(id: String)

  // Albums
  case allAlbums
  case album(id: String)

  // People
  case person(id: String)

  // Media Types
  case videos
  case livePhotos
  case panoramas
  case screenshots

  // Utilities
  case imports
  case recentlyDeleted
  case favorites

  // Sharing
  case sharedLinks
  case sharedLink(id: String)

  // Memories
  case memory(id: String)

  var label: String {
    switch self {
    case .library: "Library"
    case .collections: "Collections"
    case .pinnedAlbum: "Pinned Album"
    case .allAlbums: "All Albums"
    case .album: "Album"
    case .person: "Person"
    case .videos: "Videos"
    case .livePhotos: "Live Photos"
    case .panoramas: "Panoramas"
    case .screenshots: "Screenshots"
    case .imports: "Imports"
    case .recentlyDeleted: "Recently Deleted"
    case .favorites: "Favorites"
    case .sharedLinks: "Shared Links"
    case .sharedLink: "Shared Link"
    case .memory: "Memory"
    }
  }

  var iconName: String {
    switch self {
    case .library: "photo.on.rectangle.angled"
    case .collections: "square.grid.2x2"
    case .pinnedAlbum: "pin.fill"
    case .allAlbums: "rectangle.stack"
    case .album: "rectangle.stack"
    case .person: "person.crop.circle"
    case .videos: "video"
    case .livePhotos: "livephoto"
    case .panoramas: "pano"
    case .screenshots: "camera.viewfinder"
    case .imports: "square.and.arrow.down"
    case .recentlyDeleted: "trash"
    case .favorites: "heart"
    case .sharedLinks: "link"
    case .sharedLink: "link"
    case .memory: "memories"
    }
  }
}

// MARK: - Section Collapse State

struct SidebarSectionState {
  var isPinnedExpanded = true
  var isAlbumsExpanded = true
  var isMediaTypesExpanded = true
  var isUtilitiesExpanded = true
  var isSharingExpanded = true
}

// MARK: - Sidebar View

struct SidebarView: View {
  @Binding var selection: SidebarDestination?
  @ObservedObject var appState: AppState
  @State private var sectionState = SidebarSectionState()

  var body: some View {
    List(selection: $selection) {
      // Top-level: Library & Collections (fixed position, like Photos)
      topSection

      // Pinned albums
      if !appState.pinnedAlbumIDs.isEmpty {
        pinnedSection
      }

      // Albums
      albumsSection

      // Media Types
      mediaTypesSection

      // Utilities
      utilitiesSection

      // Sharing
      sharingSection

      // Account (at bottom)
      accountSection
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      statusBar
    }
  }

  // MARK: - Top Section (Library / Collections)

  private var topSection: some View {
    Section {
      Label("Library", systemImage: "photo.on.rectangle.angled")
        .tag(SidebarDestination.library)
        .fontWeight(selection == .library ? .semibold : .regular)

      Label("Collections", systemImage: "square.grid.2x2")
        .tag(SidebarDestination.collections)
        .fontWeight(selection == .collections ? .semibold : .regular)
    }
  }

  // MARK: - Pinned Section

  private var pinnedSection: some View {
    Section(isExpanded: $sectionState.isPinnedExpanded) {
      ForEach(appState.pinnedAlbums) { album in
        Label(album.albumName, systemImage: "pin.fill")
          .tag(SidebarDestination.pinnedAlbum(id: album.id))
      }
    } header: {
      sectionHeader("Pinned", isExpanded: $sectionState.isPinnedExpanded)
    }
  }

  // MARK: - Albums Section

  private var albumsSection: some View {
    Section(isExpanded: $sectionState.isAlbumsExpanded) {
      Label("All Albums", systemImage: "rectangle.stack")
        .tag(SidebarDestination.allAlbums)

      ForEach(appState.albums.prefix(8)) { album in
        Label(album.albumName, systemImage: album.shared ? "rectangle.stack.person.crop" : "rectangle.stack")
          .tag(SidebarDestination.album(id: album.id))
          .badge(album.assetCount)
      }
    } header: {
      sectionHeader("Albums", isExpanded: $sectionState.isAlbumsExpanded)
    }
  }

  // MARK: - Media Types Section

  private var mediaTypesSection: some View {
    Section(isExpanded: $sectionState.isMediaTypesExpanded) {
      Label("Videos", systemImage: "video")
        .tag(SidebarDestination.videos)

      Label("Live Photos", systemImage: "livephoto")
        .tag(SidebarDestination.livePhotos)

      Label("Panoramas", systemImage: "pano")
        .tag(SidebarDestination.panoramas)

      Label("Screenshots", systemImage: "camera.viewfinder")
        .tag(SidebarDestination.screenshots)
    } header: {
      sectionHeader("Media Types", isExpanded: $sectionState.isMediaTypesExpanded)
    }
  }

  // MARK: - Utilities Section

  private var utilitiesSection: some View {
    Section(isExpanded: $sectionState.isUtilitiesExpanded) {
      Label("Favorites", systemImage: "heart")
        .tag(SidebarDestination.favorites)

      Label("Imports", systemImage: "square.and.arrow.down")
        .tag(SidebarDestination.imports)

      Label {
        Text("Recently Deleted")
      } icon: {
        Image(systemName: "trash")
          .foregroundStyle(.red)
      }
      .tag(SidebarDestination.recentlyDeleted)
    } header: {
      sectionHeader("Utilities", isExpanded: $sectionState.isUtilitiesExpanded)
    }
  }

  // MARK: - Sharing Section

  private var sharingSection: some View {
    Section(isExpanded: $sectionState.isSharingExpanded) {
      Label("Shared Links", systemImage: "link")
        .tag(SidebarDestination.sharedLinks)
        .badge(appState.sharedLinks.count)
    } header: {
      sectionHeader("Sharing", isExpanded: $sectionState.isSharingExpanded)
    }
  }

  // MARK: - Account Section

  private var accountSection: some View {
    Section("Account") {
      if let session = appState.currentSession {
        VStack(alignment: .leading, spacing: 4) {
          Text(session.userName)
            .font(.headline)
          Text(session.userEmail)
            .font(.caption)
            .foregroundStyle(.secondary)
          Label(session.authenticationModeLabel, systemImage: session.usesAPIKey ? "key.fill" : "person.crop.circle.badge.checkmark")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      if let url = appState.connectedServerDisplayURL {
        Label(url, systemImage: "server.rack")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let version = appState.connectedServerVersion {
        Label("Immich \(version)", systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button("API Keys") {
        appState.showAPIKeysSheet = true
      }
      .buttonStyle(.plain)

      Button("Tags") {
        appState.showTagsSheet = true
      }
      .buttonStyle(.plain)

      if let session = appState.currentSession, session.isAdmin || appState.hasAdminAccess {
        Button("Admin Users") {
          appState.showAdminUsersSheet = true
        }
        .buttonStyle(.plain)
      }

      Button("Sign Out", role: .destructive) {
        appState.signOut()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.red)

      Button("Change Server") {
        appState.changeServer()
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Status Bar

  private var statusBar: some View {
    HStack {
      if let stats = appState.assetStatistics {
        Text("\(stats.total) items · \(stats.images) photos · \(stats.videos) videos")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }

  // MARK: - Section Header Helper

  private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
    HStack {
      Text(title)
      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.wrappedValue.toggle()
      }
    }
  }
}
#endif
