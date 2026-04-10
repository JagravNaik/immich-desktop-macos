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
  let onDismiss: (InteractiveDismissPresentation) -> Void

  @State private var image: NSImage?
  @State private var currentItemID: String?
  @State private var isLoading = false
  @State private var dragOffset: CGSize = .zero
  @State private var imagePanOffset: CGSize = .zero
  @State private var dismissProgress: CGFloat = 0
  @State private var zoomScale: CGFloat = 1
  @State private var pinchDismissScale: CGFloat = 1
  @State private var containerSize: CGSize = .zero
  @State private var containerWidth: CGFloat = 0
  @State private var isAnimatingPageSwipe = false
  @State private var isPinchDismissing = false
  @State private var pageSwipeTask: Task<Void, Never>?

  var body: some View {
    if let item = appState.selectedItem {
      ZStack {
        // Dark background
        Color(white: 0.06)
          .opacity(backgroundOpacity)
          .ignoresSafeArea()

        // Main content
        GeometryReader { geometry in
          ZStack {
            if shouldRenderPreviousItem, let prev = appState.previousItem {
              itemContainer(for: prev, isCurrent: false)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: -geometry.size.width + dragOffset.width, y: dragOffset.height)
            }

            itemContainer(for: item, isCurrent: true)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .offset(dragOffset)

            if shouldRenderNextItem, let next = appState.nextItem {
              itemContainer(for: next, isCurrent: false)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: geometry.size.width + dragOffset.width, y: dragOffset.height)
            }
          }
          .clipped()
          .onAppear {
            containerSize = geometry.size
            containerWidth = geometry.size.width
          }
          .onChange(of: geometry.size) { _, newSize in
            containerSize = newSize
            containerWidth = newSize.width
            clampImagePanIfNeeded()
          }
        }

        // Keyboard shortcuts (invisible)
        keyboardShortcuts

        TrackpadSwipeDismissOverlay(
          isEnabled: trackpadSwipeDismissEnabled(for: item),
          onTranslationChanged: { translation in
            updateDismissOffset(translation)
          },
          onSwipeEnded: { translation in
            finishDismissInteraction(with: translation)
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
      }
      .onDisappear {
        pageSwipeTask?.cancel()
        pageSwipeTask = nil
        isAnimatingPageSwipe = false
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
        let thumb = await thumbnailStore.loadImage(
          for: item,
          context: appState.thumbnailContext,
          size: .thumbnail,
          loadClass: .interactive
        )
        guard currentItemID == item.id else { return }
        if let thumb {
          self.image = thumb
        }

        // Step 2: Load preview (~1440px) for quick high-quality display
        if let preview = await thumbnailStore.loadImage(
          for: item,
          context: appState.thumbnailContext,
          size: .preview,
          loadClass: .interactive
        ) {
          guard currentItemID == item.id else { return }
          self.image = preview
        }

        // Step 3: Load original full-resolution (photos only) after a short settle delay.
        // This keeps next/previous navigation responsive by not competing with
        // interactive thumbnail/preview loads while the user is paging quickly.
        if !item.isVideo {
          try? await Task.sleep(for: .milliseconds(220))
          guard currentItemID == item.id else { return }

          if let original = await thumbnailStore.loadImage(
            for: item,
            context: appState.thumbnailContext,
            size: .original,
            loadClass: .background
          ) {
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
  private func itemContainer(for item: AppState.PhotoItem, isCurrent: Bool) -> some View {
    let content = contentView(for: item, isCurrent: isCurrent)
      .overlay(alignment: .topLeading) {
        if isCurrent, item.isLivePhoto {
          liveBadge
            .padding(16)
        }
      }
      .scaleEffect(isCurrent ? interactiveScale : 1.0)
      
    if isCurrent, !item.isPanorama {
      content.gesture(dismissDragGesture)
    } else {
      content
    }
  }

  @ViewBuilder
  private func contentView(for item: AppState.PhotoItem, isCurrent: Bool) -> some View {
    ZStack {
      // Still image: show edited version when editing, otherwise raw
      if isCurrent, appState.isEditing, let editedImage = editingPipeline.editedImage {
        zoomableImageView(editedImage)
      } else if item.isPanorama, let img = displayImage(for: item), !isHeroTransitioning {
        ZStack(alignment: .bottomLeading) {
          PanoramaSceneView(image: img)
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
        if isCurrent {
          zoomableImageView(displayImage)
        } else {
          Image(nsImage: displayImage)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
        }
      } else if isCurrent, isLoading {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
      } else if !item.isVideo {
        Image(systemName: "photo")
          .font(.system(size: 64))
          .foregroundColor(.white.opacity(0.3))
          .accessibilityHidden(true)
      }

      // Video layer
      if isCurrent, item.isVideo, !isHeroTransitioning {
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
      } else if isCurrent, item.isLivePhoto, let videoURL = livePhotoPlaybackURL(for: item), !isHeroTransitioning {
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
    if item.id == currentItemID {
      if let image {
        return image
      }
      if let initialDisplayImage {
        return initialDisplayImage
      }
    }
    
    return thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
  }

  private func zoomableImageView(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .resizable()
      .scaledToFit()
      .scaleEffect(effectiveZoomScale)
      .offset(imagePanOffset)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .clipped()
      .overlay {
        PhotoPanAndZoomOverlay(
          isEnabled: !isHeroTransitioning,
          isZoomed: isImageZoomed,
          onMagnify: { deltaScale, location in
            handleMagnification(deltaScale: deltaScale, location: location, image: image)
          },
          onMagnifyEnded: {
            finishMagnificationGesture()
          },
          onPan: { translation in
            handlePanScroll(translation, image: image)
          }
        )
      }
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
    let verticalOpacity = 1 - Double(dismissProgress * 0.72)
    let pinchOpacity = max(0.08, 1 - Double(pinchDismissProgress * 0.94))
    return min(verticalOpacity, pinchOpacity)
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
          .accessibilityHidden(true)
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
    .accessibilityLabel(appState.isViewingLivePhoto ? "Exit Live Photo" : "View Live Photo")
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

  private var effectiveZoomScale: CGFloat {
    clampedZoomScale(zoomScale)
  }

  private var isImageZoomed: Bool {
    effectiveZoomScale > 1.01
  }

  private var pinchDismissProgress: CGFloat {
    let progress = (1 - pinchDismissScale) / 0.32
    return min(max(progress, 0), 1)
  }

  private var interactiveScale: CGFloat {
    dismissScale * pinchDismissScale
  }

  private var shouldHandlePinchDismissGesture: Bool {
    guard let item = appState.selectedItem else { return false }
    return !isHeroTransitioning
      && !isAnimatingPageSwipe
      && !item.isVideo
      && !item.isPanorama
      && !appState.isViewingLivePhoto
      && !appState.isEditing
      && zoomScale <= 1.01
  }

  private func clampedZoomScale(_ value: CGFloat) -> CGFloat {
    min(max(value, 1), 6)
  }

  private func resetImageViewState() {
    dismissProgress = 0
    zoomScale = 1
    pinchDismissScale = 1
    imagePanOffset = .zero
    isPinchDismissing = false
  }

  private enum SwipeAxis {
    case horizontal
    case vertical
  }

  private enum PageSwipeDirection {
    case previous
    case next

    var targetOffsetSign: CGFloat {
      switch self {
      case .previous: 1
      case .next: -1
      }
    }
  }

  private var pageSwipeAnimation: Animation {
    .spring(response: 0.28, dampingFraction: 0.9)
  }

  private var pageSwipeAnimationDuration: Duration {
    .milliseconds(280)
  }

  private var shouldRenderPreviousItem: Bool {
    dragOffset.width > 0.5
  }

  private var shouldRenderNextItem: Bool {
    dragOffset.width < -0.5
  }

  private func dismissOffset(for translation: CGSize) -> CGSize {
    let vertical = max(translation.height, 0)
    return CGSize(width: translation.width, height: vertical)
  }

  private func swipeAxis(for offset: CGSize) -> SwipeAxis {
    offset.height > abs(offset.width) ? .vertical : .horizontal
  }

  private func updateDismissOffset(_ translation: CGSize) {
    guard !isImageZoomed, !isAnimatingPageSwipe else { return }
    resetPinchDismissInteraction(notify: false)
    let offset = dismissOffset(for: translation)

    switch swipeAxis(for: offset) {
    case .vertical:
      dragOffset = offset
      dismissProgress = min(max(offset.height / 360, 0), 1)
    case .horizontal:
      dragOffset = CGSize(width: offset.width, height: 0)
      dismissProgress = 0
    }

    onDismissPresentationChanged(currentDismissPresentation)
  }

  private func finishDismissInteraction(with translation: CGSize) {
    guard !isImageZoomed, !isAnimatingPageSwipe else { return }
    resetPinchDismissInteraction(notify: false)
    let offset = dismissOffset(for: translation)

    if swipeAxis(for: offset) == .vertical, offset.height > 120 {
      dragOffset = offset
      dismissProgress = min(max(offset.height / 360, 0), 1)
      let presentation = currentDismissPresentation
      onDismissPresentationChanged(presentation)
      onDismiss(presentation)
      return
    }

    if swipeAxis(for: offset) == .horizontal {
      if offset.width < -100, animatePageSwipe(.next, originItemID: currentItemID ?? appState.selectedItemID) {
        return
      }

      if offset.width > 100, animatePageSwipe(.previous, originItemID: currentItemID ?? appState.selectedItemID) {
        return
      }
    }

    withAnimation(pageSwipeAnimation) {
      dragOffset = .zero
      dismissProgress = 0
    }
    onDismissPresentationChanged(.identity)
  }

  private func animatePageSwipe(_ direction: PageSwipeDirection, originItemID: String?) -> Bool {
    guard !isAnimatingPageSwipe else { return false }
    guard let originItemID else { return false }
    guard containerWidth > 0 else { return false }

    switch direction {
    case .previous:
      guard appState.previousItem != nil else { return false }
    case .next:
      guard appState.nextItem != nil else { return false }
    }

    isAnimatingPageSwipe = true
    pageSwipeTask?.cancel()
    resetPinchDismissInteraction(notify: false)

    withAnimation(pageSwipeAnimation) {
      dragOffset = CGSize(width: containerWidth * direction.targetOffsetSign, height: 0)
      dismissProgress = 0
    }
    onDismissPresentationChanged(.identity)

    pageSwipeTask = Task { @MainActor in
      try? await Task.sleep(for: pageSwipeAnimationDuration)
      guard !Task.isCancelled else { return }

      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        defer {
          dragOffset = .zero
          dismissProgress = 0
          isAnimatingPageSwipe = false
        }

        guard appState.selectedItemID == originItemID else {
          return
        }

        switch direction {
        case .previous:
          appState.selectPreviousItem()
        case .next:
          appState.selectNextItem()
        }
      }

      pageSwipeTask = nil
      onDismissPresentationChanged(.identity)
    }

    return true
  }

  private func updatePinchDismissScale(_ magnification: CGFloat) {
    let clampedScale = max(magnification, 0.58)
    pinchDismissScale = clampedScale
    imagePanOffset = .zero
    dragOffset = .zero
    dismissProgress = 0
    onDismissPresentationChanged(currentDismissPresentation)
  }

  private func finishPinchDismiss(with magnification: CGFloat) {
    let clampedScale = max(magnification, 0.58)
    pinchDismissScale = clampedScale
    onDismissPresentationChanged(currentDismissPresentation)

    if clampedScale <= 0.82 {
      onDismiss(currentDismissPresentation)
      return
    }

    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
      pinchDismissScale = 1
    }
    onDismissPresentationChanged(.identity)
  }

  private func resetPinchDismissInteraction(notify: Bool = true) {
    isPinchDismissing = false
    pinchDismissScale = 1
    if notify {
      onDismissPresentationChanged(.identity)
    }
  }

  private func handleMagnification(deltaScale: CGFloat, location: CGPoint, image: NSImage) {
    guard deltaScale.isFinite, deltaScale > 0 else { return }

    if isPinchDismissing || (shouldHandlePinchDismissGesture && deltaScale < 1) {
      isPinchDismissing = true
      updatePinchDismissScale(pinchDismissScale * deltaScale)
      return
    }

    resetPinchDismissInteraction()

    let oldScale = effectiveZoomScale
    let newScale = clampedZoomScale(oldScale * deltaScale)
    let anchor = CGPoint(
      x: location.x - (containerSize.width / 2),
      y: location.y - (containerSize.height / 2)
    )
    let scaleRatio = newScale / max(oldScale, 0.0001)
    let proposedOffset = CGSize(
      width: anchor.x - scaleRatio * (anchor.x - imagePanOffset.width),
      height: anchor.y - scaleRatio * (anchor.y - imagePanOffset.height)
    )

    zoomScale = newScale
    imagePanOffset = clampedImagePanOffset(proposedOffset, zoomScale: newScale, image: image)

    if newScale <= 1.01 {
      imagePanOffset = .zero
    }
  }

  private func finishMagnificationGesture() {
    if isPinchDismissing {
      finishPinchDismiss(with: pinchDismissScale)
      return
    }

    if !isImageZoomed {
      zoomScale = 1
      imagePanOffset = .zero
    }
  }

  private func handlePanScroll(_ translation: CGSize, image: NSImage) {
    guard isImageZoomed else { return }

    let proposedOffset = CGSize(
      width: imagePanOffset.width + translation.width,
      height: imagePanOffset.height + translation.height
    )
    imagePanOffset = clampedImagePanOffset(proposedOffset, zoomScale: effectiveZoomScale, image: image)
  }

  private func clampImagePanIfNeeded() {
    guard let item = appState.selectedItem, let image = displayImage(for: item) else { return }
    imagePanOffset = clampedImagePanOffset(imagePanOffset, zoomScale: effectiveZoomScale, image: image)
  }

  private func clampedImagePanOffset(_ proposedOffset: CGSize, zoomScale: CGFloat, image: NSImage) -> CGSize {
    let fittedSize = fittedImageSize(for: image)
    let horizontalLimit = max((fittedSize.width * zoomScale - containerSize.width) / 2, 0)
    let verticalLimit = max((fittedSize.height * zoomScale - containerSize.height) / 2, 0)

    return CGSize(
      width: min(max(proposedOffset.width, -horizontalLimit), horizontalLimit),
      height: min(max(proposedOffset.height, -verticalLimit), verticalLimit)
    )
  }

  private func fittedImageSize(for image: NSImage) -> CGSize {
    let imageSize = image.size
    guard containerSize.width > 0, containerSize.height > 0,
          imageSize.width > 0, imageSize.height > 0 else {
      return containerSize
    }

    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
  }

  private var currentDismissPresentation: InteractiveDismissPresentation {
    InteractiveDismissPresentation(
      offset: dragOffset,
      scale: interactiveScale,
      backdropOpacity: max(0.02, backgroundOpacity * 0.96),
      progress: max(dismissProgress, pinchDismissProgress)
    )
  }

  // MARK: - Keyboard

  private var keyboardShortcuts: some View {
    Group {
      Button("") { onDismiss(.identity) }
      .keyboardShortcut(.escape, modifiers: [])
      .opacity(0)

      Button("") { onDismiss(.identity) }
      .keyboardShortcut(.space, modifiers: [])
      .opacity(0)

      Button("") { onDismiss(.identity) }
      .keyboardShortcut(.return, modifiers: [])
      .opacity(0)

      Button("") { _ = animatePageSwipe(.next, originItemID: currentItemID ?? appState.selectedItemID) }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .opacity(0)

      Button("") { _ = animatePageSwipe(.previous, originItemID: currentItemID ?? appState.selectedItemID) }
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
  let onTranslationChanged: (CGSize) -> Void
  let onSwipeEnded: (CGSize) -> Void

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

private struct PhotoPanAndZoomOverlay: NSViewRepresentable {
  let isEnabled: Bool
  let isZoomed: Bool
  let onMagnify: (CGFloat, CGPoint) -> Void
  let onMagnifyEnded: () -> Void
  let onPan: (CGSize) -> Void

  func makeNSView(context: Context) -> PhotoPanAndZoomNSView {
    let view = PhotoPanAndZoomNSView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: PhotoPanAndZoomNSView, context: Context) {
    nsView.isEnabled = isEnabled
    nsView.isZoomed = isZoomed
    nsView.onMagnify = onMagnify
    nsView.onMagnifyEnded = onMagnifyEnded
    nsView.onPan = onPan
  }
}

private final class ScrollWheelEventMonitor {
  private var monitors: [Any] = []

  deinit {
    remove()
  }

  func replace(with monitors: [Any]) {
    remove()
    self.monitors = monitors
  }

  func remove() {
    for monitor in monitors {
      NSEvent.removeMonitor(monitor)
    }
    monitors.removeAll()
  }
}

private final class TrackpadSwipeDismissNSView: NSView {
  var isEnabled = false
  var onTranslationChanged: (CGSize) -> Void = { _ in }
  var onSwipeEnded: (CGSize) -> Void = { _ in }

  private let eventMonitor = ScrollWheelEventMonitor()
  private var accumulatedTranslation: CGSize = .zero
  private var isTrackingSwipe = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    eventMonitor.remove()

    guard window != nil else { return }
    let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      self?.handleScrollWheel(event) ?? event
    }
    if let scrollMonitor {
      eventMonitor.replace(with: [scrollMonitor])
    }
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
    let rightwardTranslation = normalizedRightwardTranslation(for: event)

    if phase.contains(.began) {
      accumulatedTranslation = .zero
      isTrackingSwipe = true
    }

    if phase.contains(.changed) {
      isTrackingSwipe = true
      accumulatedTranslation.width += rightwardTranslation
      accumulatedTranslation.height = max(0, accumulatedTranslation.height + downwardTranslation)
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

  private func normalizedRightwardTranslation(for event: NSEvent) -> CGFloat {
    let deltaX = CGFloat(event.scrollingDeltaX)
    return event.isDirectionInvertedFromDevice ? deltaX : -deltaX
  }

  private func endTrackingIfNeeded() {
    guard isTrackingSwipe else { return }
    onSwipeEnded(accumulatedTranslation)
    resetTracking()
  }

  private func resetTracking() {
    accumulatedTranslation = .zero
    isTrackingSwipe = false
  }
}

private final class PhotoPanAndZoomNSView: NSView {
  var isEnabled = false
  var isZoomed = false
  var onMagnify: (CGFloat, CGPoint) -> Void = { _, _ in }
  var onMagnifyEnded: () -> Void = {}
  var onPan: (CGSize) -> Void = { _ in }

  private let eventMonitor = ScrollWheelEventMonitor()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    eventMonitor.remove()

    guard window != nil else { return }
    let monitors = [
      NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
        self?.handleMagnify(event) ?? event
      },
      NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
        self?.handlePanScroll(event) ?? event
      },
    ].compactMap { $0 }
    eventMonitor.replace(with: monitors)
  }

  private func handleMagnify(_ event: NSEvent) -> NSEvent? {
    guard isEnabled else { return event }
    let localPoint = convert(event.locationInWindow, from: nil)
    guard bounds.contains(localPoint) else { return event }

    let deltaScale = max(0.01, 1 + CGFloat(event.magnification))
    onMagnify(deltaScale, localPoint)

    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      onMagnifyEnded()
    }

    return nil
  }

  private func handlePanScroll(_ event: NSEvent) -> NSEvent? {
    guard isEnabled, isZoomed, event.hasPreciseScrollingDeltas else { return event }
    let localPoint = convert(event.locationInWindow, from: nil)
    guard bounds.contains(localPoint) else { return event }

    let translation = CGSize(
      width: CGFloat(event.scrollingDeltaX),
      height: CGFloat(event.scrollingDeltaY)
    )
    onPan(translation)
    return nil
  }
}
#endif
