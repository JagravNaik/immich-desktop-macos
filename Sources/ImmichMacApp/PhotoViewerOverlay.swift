#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit

struct PhotoViewerOverlay: View {
  @ObservedObject var viewModel: ContentViewModel
  @ObservedObject var store: ThumbnailStore
  let item: ContentViewModel.PhotoItem

  @State private var image: NSImage?
  @State private var isLoading = false

  var body: some View {
    ZStack {
      if let videoURL = self.playbackURL(for: item) {
        ZStack(alignment: .topLeading) {
          AuthenticatedVideoPlayer(
            url: videoURL,
            accessToken: viewModel.thumbnailContext?.accessToken ?? "",
            showControls: !viewModel.isViewingLivePhoto
          )
          
          if item.livePhotoVideoID != nil {
            liveBadge
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let image {
        ZStack(alignment: .topLeading) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
          
          if item.livePhotoVideoID != nil {
            liveBadge
              .padding(12)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        if isLoading {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
        } else {
          Image(systemName: item.isVideo ? "video.fill" : "photo")
            .font(.system(size: 64))
            .foregroundColor(.white.opacity(0.5))
        }
      }

      // Invisible buttons for keyboard shortcuts
      Button("") {
        withAnimation(.easeInOut(duration: 0.2)) {
          viewModel.isViewingPhoto = false
        }
      }
      .keyboardShortcut(.escape, modifiers: [])
      .opacity(0)

      Button("") {
        withAnimation(.easeInOut(duration: 0.2)) {
          viewModel.isViewingPhoto = false
        }
      }
      .keyboardShortcut(.space, modifiers: [])
      .opacity(0)

      Button("") {
        viewModel.selectNextItem()
      }
      .keyboardShortcut(.rightArrow, modifiers: [])
      .opacity(0)

      Button("") {
        viewModel.selectPreviousItem()
      }
      .keyboardShortcut(.leftArrow, modifiers: [])
      .opacity(0)
    }
    .task(id: item.id) {
      isLoading = true
      let loadedImage = await store.loadImage(for: item, context: viewModel.thumbnailContext)
      // Small animation smoothing
      withAnimation(.easeInOut(duration: 0.15)) {
        self.image = loadedImage
        self.isLoading = false
      }
    }
  }

  private var liveBadge: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.isViewingLivePhoto.toggle()
        viewModel.isPeeking = false
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "livephoto")
        if viewModel.isViewingLivePhoto {
          Text("LIVE")
            .font(.system(size: 10, weight: .bold))
        }
      }
      .foregroundStyle(viewModel.isViewingLivePhoto ? Color.accentColor : .white)
      .padding(6)
      .background(.black.opacity(0.3))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func playbackURL(for item: ContentViewModel.PhotoItem) -> URL? {
    // If it's a live photo inherently playing, OR if it's a normal video
    let videoID: String?
    if viewModel.isViewingLivePhoto {
      videoID = item.livePhotoVideoID ?? (item.isVideo ? item.id : nil)
    } else {
      videoID = item.isVideo ? item.id : nil
    }

    guard let videoID, let baseURL = viewModel.thumbnailContext?.baseURL else { return nil }
    
    return baseURL
      .appending(path: "assets")
      .appending(path: videoID)
      .appending(path: "video")
      .appending(path: "playback")
  }
}
#endif
#endif
