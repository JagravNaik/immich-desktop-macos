#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// MARK: - Photo Detail View (Photos-style full viewer with hero transition)

struct PhotoDetailView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore
  @ObservedObject var editingPipeline: PhotoEditingPipeline
  let initialDisplayImage: NSImage?
  let isHeroTransitioning: Bool
  let onDismissPresentationChanged: (InteractiveDismissPresentation) -> Void
  let onDismiss: () -> Void

  @State private var image: NSImage?
  @State private var currentItemID: String?
  @State private var isLoading = false
  @State private var dragOffset: CGSize = .zero
  @State private var dismissProgress: CGFloat = 0
  @State private var zoomScale: CGFloat = 1
  @GestureState private var pinchScale: CGFloat = 1

  var body: some View {
    if let item = appState.selectedItem {
      ZStack {
        // Dark background
        Color(white: 0.06)
          .opacity(backgroundOpacity)
          .ignoresSafeArea()

        // Main content
        Group {
          if item.isPanorama {
            contentView(for: item)
              .overlay(alignment: .topLeading) {
                if item.isLivePhoto {
                  liveBadge
                    .padding(16)
                }
              }
              .scaleEffect(dismissScale)
              .offset(dragOffset)
          } else {
            contentView(for: item)
              .overlay(alignment: .topLeading) {
                if item.isLivePhoto {
                  liveBadge
                    .padding(16)
                }
              }
              .scaleEffect(dismissScale)
              .offset(dragOffset)
              .gesture(dismissDragGesture)
          }
        }

        // Keyboard shortcuts (invisible)
        keyboardShortcuts

        TrackpadSwipeDismissOverlay(
          isEnabled: trackpadSwipeDismissEnabled(for: item),
          onTranslationChanged: { translation in
            updateDismissOffset(CGSize(width: 0, height: translation))
          },
          onSwipeEnded: { translation in
            finishDismissInteraction(with: CGSize(width: 0, height: translation))
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
      }
      .onChange(of: item.id) { _, newID in
        image = initialDisplayImage
          ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext)
        currentItemID = newID
        isLoading = true
        resetImageViewState()
        onDismissPresentationChanged(.identity)
      }
      .task(id: "\(item.id)::\(isHeroTransitioning)") {
        currentItemID = item.id
        isLoading = true

        if let initialDisplayImage {
          self.image = initialDisplayImage
        } else if let cached = thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext) {
          self.image = cached
        }

        defer {
          if currentItemID == item.id {
            isLoading = false
          }
        }

        if isHeroTransitioning {
          if let img = self.image {
            editingPipeline.setSourceImage(img)
          }
          return
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
        }

        // Step 3: Load original full-resolution (only for photos, not videos)
        if !item.isVideo {
          if let original = await thumbnailStore.loadImage(for: item, context: appState.thumbnailContext, size: .original) {
            guard currentItemID == item.id else { return }
            self.image = original
            // Feed the best available image to the editing pipeline
            editingPipeline.setSourceImage(original)
          }
        } else {
          // For non-original loads, still set the pipeline source from best available
          if let img = self.image {
            editingPipeline.setSourceImage(img)
          }
        }
      }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private func contentView(for item: AppState.PhotoItem) -> some View {
    ZStack {
      // Still image: show edited version when editing, otherwise raw
      if appState.isEditing, let editedImage = editingPipeline.editedImage {
        zoomableImageView(editedImage)
      } else if item.isPanorama, let image, !isHeroTransitioning {
        ZStack(alignment: .bottomLeading) {
          PanoramaSceneView(image: image)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          Label("Drag to look around. Scroll to zoom.", systemImage: "pano")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(18)
        }
      } else if let displayImage = displayImage(for: item) {
        zoomableImageView(displayImage)
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
      if item.isVideo, !isHeroTransitioning {
        // Regular video: always show the player
        if let videoURL = videoPlaybackURL(for: item) {
          AuthenticatedVideoPlayer(
            url: videoURL,
            authHeaderFields: appState.thumbnailContext?.assetHeaderFields ?? [:],
            showControls: true,
            onPlaybackEnded: nil
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if item.isLivePhoto, let videoURL = livePhotoPlaybackURL(for: item), !isHeroTransitioning {
        // Live photo: keep player mounted, fade with opacity
        AuthenticatedVideoPlayer(
          url: videoURL,
          authHeaderFields: appState.thumbnailContext?.assetHeaderFields ?? [:],
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

  private func displayImage(for item: AppState.PhotoItem) -> NSImage? {
    if let image {
      return image
    }
    if let initialDisplayImage {
      return initialDisplayImage
    }
    return thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
  }

  private func zoomableImageView(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .resizable()
      .scaledToFit()
      .scaleEffect(effectiveZoomScale)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .clipped()
      .simultaneousGesture(zoomGesture)
  }

  private func trackpadSwipeDismissEnabled(for item: AppState.PhotoItem) -> Bool {
    !isHeroTransitioning
      && !item.isVideo
      && !item.isPanorama
      && !appState.isViewingLivePhoto
      && !isImageZoomed
  }

  private var dismissScale: CGFloat {
    1 - (dismissProgress * 0.12)
  }

  private var backgroundOpacity: Double {
    1 - Double(dismissProgress * 0.72)
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
        updateDismissOffset(value.translation)
      }
      .onEnded { value in
        finishDismissInteraction(with: value.translation)
      }
  }

  private var zoomGesture: some Gesture {
    MagnificationGesture()
      .updating($pinchScale) { value, state, _ in
        state = value
      }
      .onEnded { value in
        zoomScale = clampedZoomScale(zoomScale * value)
        if !isImageZoomed {
          dragOffset = .zero
        }
      }
  }

  private var effectiveZoomScale: CGFloat {
    clampedZoomScale(zoomScale * pinchScale)
  }

  private var isImageZoomed: Bool {
    effectiveZoomScale > 1.01
  }

  private func clampedZoomScale(_ value: CGFloat) -> CGFloat {
    min(max(value, 1), 6)
  }

  private func resetImageViewState() {
    dragOffset = .zero
    dismissProgress = 0
    zoomScale = 1
  }

  private func dismissOffset(for translation: CGSize) -> CGSize {
    let vertical = max(translation.height, 0)
    let horizontal = translation.width * 0.18
    return CGSize(width: horizontal, height: vertical)
  }

  private func updateDismissOffset(_ translation: CGSize) {
    guard !isImageZoomed else { return }
    let offset = dismissOffset(for: translation)
    let progress = min(max(offset.height / 360, 0), 1)
    dragOffset = offset
    dismissProgress = progress
    onDismissPresentationChanged(currentDismissPresentation)
  }

  private func finishDismissInteraction(with translation: CGSize) {
    guard !isImageZoomed else { return }
    let offset = dismissOffset(for: translation)
    if offset.height > 120 {
      dragOffset = offset
      dismissProgress = min(max(offset.height / 360, 0), 1)
      onDismissPresentationChanged(currentDismissPresentation)
      onDismiss()
      return
    }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
      dragOffset = .zero
      dismissProgress = 0
    }
    onDismissPresentationChanged(.identity)
  }

  private var currentDismissPresentation: InteractiveDismissPresentation {
    InteractiveDismissPresentation(
      offset: dragOffset,
      scale: dismissScale,
      backdropOpacity: backgroundOpacity,
      progress: dismissProgress
    )
  }

  // MARK: - Keyboard

  private var keyboardShortcuts: some View {
    Group {
      Button("") { onDismiss() }
      .keyboardShortcut(.escape, modifiers: [])
      .opacity(0)

      Button("") { onDismiss() }
      .keyboardShortcut(.space, modifiers: [])
      .opacity(0)

      Button("") { onDismiss() }
      .keyboardShortcut(.return, modifiers: [])
      .opacity(0)

      Button("") { appState.selectNextItem() }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .opacity(0)

      Button("") { appState.selectPreviousItem() }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .opacity(0)
    }
    .accessibilityHidden(true)
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

private struct TrackpadSwipeDismissOverlay: NSViewRepresentable {
  let isEnabled: Bool
  let onTranslationChanged: (CGFloat) -> Void
  let onSwipeEnded: (CGFloat) -> Void

  func makeNSView(context: Context) -> TrackpadSwipeDismissNSView {
    let view = TrackpadSwipeDismissNSView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TrackpadSwipeDismissNSView, context: Context) {
    nsView.isEnabled = isEnabled
    nsView.onTranslationChanged = onTranslationChanged
    nsView.onSwipeEnded = onSwipeEnded
  }
}

private final class ScrollWheelEventMonitor {
  private var monitor: Any?

  deinit {
    remove()
  }

  func replace(with monitor: Any?) {
    remove()
    self.monitor = monitor
  }

  func remove() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }
}

private final class TrackpadSwipeDismissNSView: NSView {
  var isEnabled = false
  var onTranslationChanged: (CGFloat) -> Void = { _ in }
  var onSwipeEnded: (CGFloat) -> Void = { _ in }

  private let eventMonitor = ScrollWheelEventMonitor()
  private var accumulatedTranslation: CGFloat = 0
  private var isTrackingSwipe = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    eventMonitor.remove()

    guard window != nil else { return }
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      self?.handleScrollWheel(event) ?? event
    }
    eventMonitor.replace(with: monitor)
  }

  private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
    guard isEnabled else {
      resetTracking()
      return event
    }

    let phase = event.phase
    let momentumPhase = event.momentumPhase
    guard event.hasPreciseScrollingDeltas, phase != [] || momentumPhase != [] else {
      return event
    }

    if momentumPhase != [] {
      endTrackingIfNeeded()
      return nil
    }

    let downwardTranslation = normalizedDownwardTranslation(for: event)

    if phase.contains(.began) {
      accumulatedTranslation = 0
      isTrackingSwipe = true
    }

    if phase.contains(.changed) {
      isTrackingSwipe = true
      accumulatedTranslation = max(0, accumulatedTranslation + downwardTranslation)
      onTranslationChanged(accumulatedTranslation)
      return nil
    }

    if phase.contains(.ended) || phase.contains(.cancelled) {
      endTrackingIfNeeded()
      return nil
    }

    return event
  }

  private func normalizedDownwardTranslation(for event: NSEvent) -> CGFloat {
    let deltaY = CGFloat(event.scrollingDeltaY)
    return event.isDirectionInvertedFromDevice ? deltaY : -deltaY
  }

  private func endTrackingIfNeeded() {
    guard isTrackingSwipe else { return }
    onSwipeEnded(accumulatedTranslation)
    resetTracking()
  }

  private func resetTracking() {
    accumulatedTranslation = 0
    isTrackingSwipe = false
  }
}
#endif
