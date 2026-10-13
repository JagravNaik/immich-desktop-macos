#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

// MARK: - Sidebar Item Model

enum SidebarDestination: Hashable {
  // Top-level
  case library
  case collections
  case map
  case recentDays

  // Pinned
  case pinnedAlbum(id: String)

  // Albums
  case allAlbums
  case album(id: String)

  case allPeople
  case allMemories

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
  case hidden
  case duplicates
  case favorites

  // Memories
  case memory(id: String)

  var label: String {
    switch self {
    case .library: "Library"
    case .recentDays: "Recent Days"
    case .collections: "Collections"
    case .map: "Map"
    case .pinnedAlbum: "Pinned Album"
    case .allAlbums: "All Albums"
    case .album: "Album"
    case .allPeople: "People"
    case .allMemories: "Memories"
    case .person: "Person"
    case .videos: "Videos"
    case .livePhotos: "Live Photos"
    case .panoramas: "Panoramas"
    case .screenshots: "Screenshots"
    case .imports: "Imports"
    case .recentlyDeleted: "Recently Deleted"
    case .hidden: "Hidden"
    case .duplicates: "Duplicates"
    case .favorites: "Favorites"
    case .memory: "Memory"
    }
  }

  var iconName: String {
    switch self {
    case .library: "photo.on.rectangle.angled"
    case .recentDays: "calendar"
    case .collections: "square.grid.2x2"
    case .map: "map"
    case .pinnedAlbum: "pin.fill"
    case .allAlbums: "rectangle.stack"
    case .album: "rectangle.stack"
    case .allPeople: "person.2"
    case .allMemories: "memories"
    case .person: "person.crop.circle"
    case .videos: "video"
    case .livePhotos: "livephoto"
    case .panoramas: "pano"
    case .screenshots: "camera.viewfinder"
    case .imports: "square.and.arrow.down"
    case .recentlyDeleted: "trash"
    case .hidden: "eye.slash"
    case .duplicates: "square.on.square"
    case .favorites: "heart"
    case .memory: "memories"
    }
  }
}

// MARK: - Section Collapse State

struct SidebarSectionState {
  var isPinnedExpanded = true
  var isAlbumsExpanded = true
  var isPeopleExpanded = true
  var isMemoriesExpanded = true
  var isMediaTypesExpanded = true
  var isUtilitiesExpanded = true
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

      // People and memories
      if !appState.people.isEmpty {
        peopleSection
      }
      if !appState.memories.isEmpty {
        memoriesSection
      }

      // Media Types
      mediaTypesSection

      // Utilities
      utilitiesSection

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

      Label("Recent Days", systemImage: "calendar")
        .tag(SidebarDestination.recentDays)
        .fontWeight(selection == .recentDays ? .semibold : .regular)

      Label("Collections", systemImage: "square.grid.2x2")
        .tag(SidebarDestination.collections)
        .fontWeight(selection == .collections ? .semibold : .regular)

      Label("Map", systemImage: "map")
        .tag(SidebarDestination.map)
        .fontWeight(selection == .map ? .semibold : .regular)
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
          .badge(album.assetCount)
          .tag(SidebarDestination.album(id: album.id))
      }
    } header: {
      sectionHeader("Albums", isExpanded: $sectionState.isAlbumsExpanded)
    }
  }

  // MARK: - People and Memories

  private var peopleSection: some View {
    Section(isExpanded: $sectionState.isPeopleExpanded) {
      Label("All People", systemImage: "person.2")
        .tag(SidebarDestination.allPeople)

      ForEach(appState.people.filter { !$0.isHidden }.prefix(8)) { person in
        Label(person.name.isEmpty ? "Unknown" : person.name, systemImage: "person.crop.circle")
          .badge(person.assetCount)
          .tag(SidebarDestination.person(id: person.id))
      }
    } header: {
      sectionHeader("People & Pets", isExpanded: $sectionState.isPeopleExpanded)
    }
  }

  private var memoriesSection: some View {
    Section(isExpanded: $sectionState.isMemoriesExpanded) {
      Label("All Memories", systemImage: "memories")
        .tag(SidebarDestination.allMemories)

      ForEach(appState.memories.prefix(6)) { memory in
        Label {
          Text(memory.title)
            .lineLimit(1)
        } icon: {
          Image(systemName: "memories")
        }
        .tag(SidebarDestination.memory(id: memory.id))
      }
    } header: {
      sectionHeader("Memories", isExpanded: $sectionState.isMemoriesExpanded)
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

      Label("Duplicates", systemImage: "square.on.square")
        .tag(SidebarDestination.duplicates)

      // Photos shows Hidden in Utilities (View ▸ Show Hidden Photo Album).
      Label("Hidden", systemImage: "eye.slash")
        .tag(SidebarDestination.hidden)

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
          Label(accountAuthenticationModeLabel, systemImage: accountAuthenticationModeIcon)
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

  private var accountAuthenticationModeLabel: String {
    if appState.isOAuthSession {
      return "OAuth"
    }
    return appState.currentSession?.authenticationModeLabel ?? "Password"
  }

  private var accountAuthenticationModeIcon: String {
    if appState.isOAuthSession {
      return "globe"
    }
    return appState.currentSession?.usesAPIKey == true ? "key.fill" : "person.crop.circle.badge.checkmark"
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
      withAnimation(ImmichMotion.Curves.structuralShort) {
        isExpanded.wrappedValue.toggle()
      }
    }
  }
}
#endif
