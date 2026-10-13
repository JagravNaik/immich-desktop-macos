#if canImport(AppKit) && canImport(PhotosUI)
import AppKit
import Photos
import PhotosUI
import SwiftUI

/// Wraps `PHLivePhotoView`, the player Photos itself uses. Photos starts playback with
/// `startPlaybackWithStyle:1` (`PHLivePhotoViewPlaybackStyle.full`) and ends it with
/// `stopPlayback`; the system view supplies the blur-in and the settle back to the still.
struct LivePhotoPlayerView: NSViewRepresentable {
  let livePhoto: PHLivePhoto
  /// While true the Live Photo plays; switching to false stops it, as releasing a deep press does.
  let isPlaying: Bool
  var isMuted = false
  var onPlaybackEnded: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onPlaybackEnded: onPlaybackEnded)
  }

  func makeNSView(context: Context) -> PHLivePhotoView {
    let view = PHLivePhotoView()
    view.contentMode = .aspectFit
    view.delegate = context.coordinator
    view.livePhoto = livePhoto
    view.isMuted = isMuted
    // Hide the system badge; the viewer draws Photos' expanding LIVE badge instead.
    view.livePhotoBadgeView?.isHidden = true
    return view
  }

  func updateNSView(_ view: PHLivePhotoView, context: Context) {
    context.coordinator.onPlaybackEnded = onPlaybackEnded
    if view.livePhoto !== livePhoto {
      view.livePhoto = livePhoto
    }
    view.isMuted = isMuted
    if isPlaying != context.coordinator.isPlaying {
      context.coordinator.isPlaying = isPlaying
      if isPlaying {
        view.startPlayback(with: .full)
      } else {
        view.stopPlayback()
      }
    }
  }

  final class Coordinator: NSObject, PHLivePhotoViewDelegate {
    var onPlaybackEnded: () -> Void
    var isPlaying = false

    init(onPlaybackEnded: @escaping () -> Void) {
      self.onPlaybackEnded = onPlaybackEnded
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
      isPlaying = false
      onPlaybackEnded()
    }
  }
}

/// Photos' viewer LIVE badge (`IPXLivePhotoBadge`): a vibrant capsule with the Live Photo glyph and
/// "LIVE" label. It expands while the pointer moves over the photo and collapses to the glyph
/// after 3 s (`_showMouseOverBadges:` → `_hideMouseOverBadgesAfterDelay:3`). Hovering plays the
/// Live Photo, and pressing it plays while held (`NSPressGestureRecognizer`, minimum duration 0).
struct LivePhotoBadge: View {
  let isExpanded: Bool
  let isPlaying: Bool
  let isLoading: Bool
  var onHoverChanged: (Bool) -> Void = { _ in }
  var onPressChanged: (Bool) -> Void = { _ in }

  @State private var isPressed = false

  var body: some View {
    HStack(spacing: 4) {
      badgeGlyph
        .frame(width: 14, height: 14)
      if isExpanded || isPlaying {
        Text("LIVE")
          .font(.system(size: 10, weight: .semibold))
          .tracking(0.6)
          .transition(.opacity.combined(with: .move(edge: .leading)))
      }
      if isLoading {
        ProgressView().controlSize(.mini)
      }
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, isExpanded || isPlaying ? 8 : 5)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: Capsule())
    .environment(\.colorScheme, .dark)
    .contentShape(Capsule())
    .onHover(perform: onHoverChanged)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !isPressed else { return }
          isPressed = true
          onPressChanged(true)
        }
        .onEnded { _ in
          isPressed = false
          onPressChanged(false)
        }
    )
    .animation(.timingCurve(0.42, 0, 0.58, 1, duration: PhotosMotion.standardDuration), value: isExpanded || isPlaying)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Live Photo")
    .accessibilityHint("Press and hold to play")
    .accessibilityAddTraits(.isButton)
  }

  private var badgeGlyph: some View {
    Image(systemName: isPlaying ? "livephoto.play" : "livephoto")
      .resizable()
      .scaledToFit()
      .symbolRenderingMode(.hierarchical)
  }
}
#endif
