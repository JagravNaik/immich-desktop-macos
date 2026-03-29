#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// MARK: - Photo Detail View (Photos-style full viewer with hero transition)

struct PhotoDetailView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore

  @State private var image: NSImage?
  @State private var currentItemID: String?
  @State private var loadedSize: ThumbnailStore.ThumbnailSize = .thumbnail
  @State private var isLoading = false
  @State private var dragOffset: CGSize = .zero

  var body: some View {
    if let item = appState.selectedItem {
      ZStack {
        // Dark background
        Color(white: 0.06)
          .ignoresSafeArea()

        // Main content
        contentView(for: item)
          .id(item.id)
          .overlay(alignment: .topLeading) {
            if item.isLivePhoto {
              liveBadge
                .padding(16)
            }
          }
          .offset(dragOffset)
          .gesture(dismissDragGesture)

        // Keyboard shortcuts (invisible)
        keyboardShortcuts
      }
      .transition(.opacity.combined(with: .scale(scale: 0.95)))
      .onChange(of: item.id) { _, newID in
        // Immediately clear stale image to prevent flash of previous photo
        image = nil
        currentItemID = newID
        loadedSize = .thumbnail
        isLoading = true
      }
      .task(id: item.id) {
        currentItemID = item.id
        isLoading = true
        loadedSize = .thumbnail
        defer {
          if currentItemID == item.id {
            isLoading = false
          }
        }

        // Step 1: Show cached thumbnail immediately (already loaded from grid)
        let thumb = await thumbnailStore.loadImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
        guard currentItemID == item.id else { return }
        if let thumb {
          self.image = thumb
        }

        // Step 2: Load preview (~1440px) for quick high-quality display
        if let preview = await thumbnailStore.loadImage(for: item, context: appState.thumbnailContext, size: .preview) {
          guard currentItemID == item.id else { return }
          self.image = preview
          self.loadedSize = .preview
        }

        // Step 3: Load original full-resolution (only for photos, not videos)
        if !item.isVideo {
          if let original = await thumbnailStore.loadImage(for: item, context: appState.thumbnailContext, size: .original) {
            guard currentItemID == item.id else { return }
            self.image = original
            self.loadedSize = .original
          }
        }
      }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private func contentView(for item: AppState.PhotoItem) -> some View {
    ZStack {
      // Still image always rendered underneath
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if isLoading {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
      } else if !item.isVideo {
        Image(systemName: "photo")
          .font(.system(size: 64))
          .foregroundColor(.white.opacity(0.3))
      }

      // Video layer
      if item.isVideo {
        // Regular video: always show the player
        if let videoURL = videoPlaybackURL(for: item) {
          AuthenticatedVideoPlayer(
            url: videoURL,
            accessToken: appState.thumbnailContext?.accessToken ?? "",
            showControls: true,
            onPlaybackEnded: nil
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if item.isLivePhoto, let videoURL = livePhotoPlaybackURL(for: item) {
        // Live photo: keep player mounted, fade with opacity
        AuthenticatedVideoPlayer(
          url: videoURL,
          accessToken: appState.thumbnailContext?.accessToken ?? "",
          showControls: false,
          isPlaying: appState.isViewingLivePhoto,
          onPlaybackEnded: {
            withAnimation(.easeOut(duration: 0.4)) {
              appState.isViewingLivePhoto = false
              appState.isPeeking = false
            }
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appState.isViewingLivePhoto ? 1 : 0)
        .allowsHitTesting(appState.isViewingLivePhoto)
      }
    }
  }

  // MARK: - Live Photo Badge

  private var liveBadge: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        appState.isViewingLivePhoto.toggle()
        appState.isPeeking = false
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "livephoto")
        if appState.isViewingLivePhoto {
          Text("LIVE")
            .font(.system(size: 10, weight: .bold))
        }
      }
      .foregroundStyle(appState.isViewingLivePhoto ? Color.accentColor : .white)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Dismiss Drag Gesture

  private var dismissDragGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        dragOffset = value.translation
      }
      .onEnded { value in
        let magnitude = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))
        if magnitude > 120 {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appState.isViewingPhoto = false
            appState.isViewingLivePhoto = false
          }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          dragOffset = .zero
        }
      }
  }

  // MARK: - Keyboard

  private var keyboardShortcuts: some View {
    Group {
      Button("") {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          appState.isViewingPhoto = false
          appState.isViewingLivePhoto = false
        }
      }
      .keyboardShortcut(.escape, modifiers: [])
      .opacity(0)

      Button("") {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          appState.isViewingPhoto = false
          appState.isViewingLivePhoto = false
        }
      }
      .keyboardShortcut(.space, modifiers: [])
      .opacity(0)

      Button("") { appState.selectNextItem() }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .opacity(0)

      Button("") { appState.selectPreviousItem() }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .opacity(0)
    }
  }

  // MARK: - URL Helper

  private func videoPlaybackURL(for item: AppState.PhotoItem) -> URL? {
    guard item.isVideo, let baseURL = appState.thumbnailContext?.baseURL else { return nil }
    return baseURL.appending(path: "assets").appending(path: item.id).appending(path: "video").appending(path: "playback")
  }

  private func livePhotoPlaybackURL(for item: AppState.PhotoItem) -> URL? {
    guard let videoID = item.livePhotoVideoID, let baseURL = appState.thumbnailContext?.baseURL else { return nil }
    return baseURL.appending(path: "assets").appending(path: videoID).appending(path: "video").appending(path: "playback")
  }
}
#endif
