#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import ImmichCore

// MARK: - Collections View (macOS 26 Photos-style)

struct CollectionsView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        // People & Pets
        if !appState.people.isEmpty {
          peopleSection
        }

        // Memories
        if !appState.memories.isEmpty {
          memoriesSection
        }

        // Albums
        if !appState.albums.isEmpty {
          albumsSection
        }

        // Media Types (quick access cards)
        mediaTypesSection

        Spacer(minLength: 20)
      }
      .padding(20)
    }
  }

  // MARK: - People Section

  private var peopleSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("People")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Show All") {
          // Could navigate to a dedicated people view
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(appState.people.filter { !$0.isHidden }.prefix(20)) { person in
            PersonCard(person: person, context: appState.thumbnailContext)
              .onTapGesture {
                appState.sidebarSelection = .person(id: person.id)
              }
          }
        }
        .padding(.horizontal, 4)
      }
    }
  }

  // MARK: - Memories Section

  private var memoriesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Memories")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Show All") {}
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 16) {
          ForEach(appState.memories.prefix(10)) { memory in
            MemoryCard(memory: memory, context: appState.thumbnailContext, thumbnailStore: thumbnailStore)
              .onTapGesture {
                appState.sidebarSelection = .memory(id: memory.id)
              }
          }
        }
        .padding(.horizontal, 4)
      }
    }
  }

  // MARK: - Albums Section

  private var albumsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Albums")
          .font(.title2.weight(.semibold))

        Text("\(appState.albums.count)")
          .font(.callout)
          .foregroundStyle(.tertiary)

        Spacer()

        Button("Show All") {
          appState.sidebarSelection = .allAlbums
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 16) {
        ForEach(appState.albums.prefix(8)) { album in
          AlbumCard(album: album, context: appState.thumbnailContext, thumbnailStore: thumbnailStore) {
            appState.sidebarSelection = .album(id: album.id)
          } onPin: {
            appState.togglePinAlbum(album.id)
          }
        }
      }
    }
  }

  // MARK: - Media Types Section

  private var mediaTypesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Media Types")
        .font(.title2.weight(.semibold))

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)], spacing: 12) {
        MediaTypeCard(title: "Favorites", icon: "heart.fill", count: appState.favoritesCount, color: .red) {
          appState.sidebarSelection = .favorites
        }
        MediaTypeCard(title: "Videos", icon: "video.fill", count: appState.videosCount, color: .blue) {
          appState.sidebarSelection = .videos
        }
        MediaTypeCard(title: "Live Photos", icon: "livephoto", count: appState.livePhotosCount, color: .orange) {
          appState.sidebarSelection = .livePhotos
        }
        MediaTypeCard(title: "Panoramas", icon: "pano", count: appState.panoramasCount, color: .teal) {
          appState.sidebarSelection = .panoramas
        }
        MediaTypeCard(title: "Recently Deleted", icon: "trash", count: nil, color: .gray) {
          appState.sidebarSelection = .recentlyDeleted
        }
      }
    }
  }
}

// MARK: - Person Card

struct PersonCard: View {
  let person: Person
  let context: AppState.ThumbnailContext?

  @State private var thumbnail: NSImage?

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(.quaternary)
          .frame(width: 80, height: 80)

        if let thumbnail {
          Image(nsImage: thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 80, height: 80)
            .clipShape(Circle())
        } else {
          Image(systemName: "person.fill")
            .font(.title)
            .foregroundStyle(.secondary)
        }
      }

      Text(person.name.isEmpty ? "Unknown" : person.name)
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: 90)
    }
    .task {
      guard let context else { return }
      let url = context.baseURL.appending(path: "people").appending(path: person.id).appending(path: "thumbnail")
      var request = URLRequest(url: url)
      context.apply(to: &request)
      if let (data, response) = try? await URLSession.shared.data(for: request),
         let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
        self.thumbnail = NSImage(data: data)
      }
    }
  }
}

// MARK: - Memory Card

struct MemoryCard: View {
  let memory: Memory
  let context: AppState.ThumbnailContext?
  @ObservedObject var thumbnailStore: ThumbnailStore

  @State private var coverImage: NSImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomLeading) {
        if let coverImage {
          Image(nsImage: coverImage)
            .resizable()
            .scaledToFill()
            .frame(width: 200, height: 140)
            .clipped()
        } else {
          RoundedRectangle(cornerRadius: 12)
            .fill(
              LinearGradient(
                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 200, height: 140)
        }

        // Gradient scrim for text readability
        LinearGradient(
          colors: [.clear, .black.opacity(0.6)],
          startPoint: .center,
          endPoint: .bottom
        )
        .frame(width: 200, height: 140)

        VStack(alignment: .leading, spacing: 2) {
          Text(memory.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
          Text("\(memory.assetCount) photos")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(12)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .task {
      guard let firstAsset = memory.assets.first, let context else { return }
      let item = AppState.PhotoItem(
        id: firstAsset.id,
        source: .remoteAsset(id: firstAsset.id),
        title: "",
        date: firstAsset.createdAt,
        isFavorite: false,
        isVideo: false,
        isImported: false,
        livePhotoVideoID: nil,
        latitude: nil,
        longitude: nil,
        durationText: nil,
        city: nil,
        country: nil,
        stackCount: nil,
        timeBucketKey: "",
        projectionType: nil,
        aspectRatio: 1
      )
      coverImage = await thumbnailStore.loadImage(for: item, context: context, size: .thumbnail)
    }
  }
}

// MARK: - Album Card

struct AlbumCard: View {
  let album: Album
  let context: AppState.ThumbnailContext?
  @ObservedObject var thumbnailStore: ThumbnailStore
  let onTap: () -> Void
  let onPin: () -> Void

  @State private var coverImage: NSImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary)
          .aspectRatio(1, contentMode: .fit)

        if let coverImage {
          Image(nsImage: coverImage)
            .resizable()
            .scaledToFill()
            .aspectRatio(1, contentMode: .fill)
            .clipped()
        } else {
          Image(systemName: album.shared ? "rectangle.stack.person.crop" : "rectangle.stack")
            .font(.title)
            .foregroundStyle(.secondary)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 2) {
        Text(album.albumName)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)

        Text("\(album.assetCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onTapGesture { onTap() }
    .contextMenu {
      Button("Open Album") { onTap() }
      Button("Pin to Sidebar") { onPin() }
    }
    .task {
      guard let thumbId = album.albumThumbnailAssetId, let context else { return }
      var components = URLComponents(
        url: context.baseURL.appending(path: "assets").appending(path: thumbId).appending(path: "thumbnail"),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [URLQueryItem(name: "size", value: "preview")]
      guard let url = components?.url else { return }
      var request = URLRequest(url: url)
      context.apply(to: &request)
      if let (data, response) = try? await URLSession.shared.data(for: request),
         let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
        self.coverImage = NSImage(data: data)
      }
    }
  }
}

// MARK: - Media Type Card

struct MediaTypeCard: View {
  let title: String
  let icon: String
  let count: Int?
  let color: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(color)
          .frame(width: 36)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.subheadline.weight(.medium))
          if let count {
            Text("\(count)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}
#endif
