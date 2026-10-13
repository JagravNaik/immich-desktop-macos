#if canImport(SwiftUI) && canImport(AppKit) && canImport(AVFoundation)
import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import AVKit

struct VideoTrimRange: Equatable {
  let start: Double
  let end: Double

  static func validated(start: Double, end: Double, duration: Double) -> VideoTrimRange? {
    guard duration.isFinite, duration > 0, start.isFinite, end.isFinite else { return nil }
    let lower = min(max(start, 0), duration)
    let upper = min(max(end, 0), duration)
    guard upper > lower else { return nil }
    return VideoTrimRange(start: lower, end: upper)
  }
}

// AVFoundation owns export threading; the unchecked box carries the session to its completion handoff.
private final class ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}


struct VideoTrimEditor: View {
  let url: URL
  let authHeaderFields: [String: String]

  @Environment(\.dismiss) private var dismiss
  @State private var asset: AVURLAsset?
  @State private var player: AVPlayer?
  @State private var duration: Double = 0
  @State private var startTime: Double = 0
  @State private var endTime: Double = 0
  @State private var isLoading = true
  @State private var isExporting = false
  @State private var errorMessage: String?
  @State private var exportWasCancelled = false
  @State private var exportSession: AVAssetExportSession?
  @State private var previewBoundaryObserver: Any?

  private let minimumDuration = 0.1

  private var validRange: VideoTrimRange? {
    guard let range = VideoTrimRange.validated(start: startTime, end: endTime, duration: duration),
          range.end - range.start >= min(minimumDuration, duration) else { return nil }
    return range
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Trim Video").font(.headline)
        Spacer()
        Button("Cancel") { cancel() }
      }
      .padding()

      Divider()

      Group {
        if let player {
          VideoTrimPlayerView(player: player)
            .frame(minHeight: 220)
        } else if isLoading {
          ProgressView("Loading video…")
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          ContentUnavailableView("Video unavailable", systemImage: "video.slash")
            .frame(maxWidth: .infinity, minHeight: 220)
        }
      }
      .background(.black)

      if duration > 0 {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("Start")
            Slider(value: $startTime, in: 0...duration, onEditingChanged: { editing in
              if !editing { previewFromStart() }
            })
            Text(timeLabel(startTime)).monospacedDigit().frame(width: 58, alignment: .trailing)
          }
          HStack {
            Text("End")
            Slider(value: $endTime, in: 0...duration, onEditingChanged: { editing in
              if !editing { previewFromStart() }
            })
            Text(timeLabel(endTime)).monospacedDigit().frame(width: 58, alignment: .trailing)
          }
          HStack {
            Button(action: previewSelectedRange) {
              Label("Preview Selection", systemImage: "play.fill")
            }
            .disabled(validRange == nil)
            Spacer()
            Text("Exported as a separate local file; the Immich original is unchanged.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding()
      }

      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.bottom, 8)
      }

      if isExporting { ProgressView("Exporting…").padding(.bottom, 10) }

      Divider()
      HStack {
        Spacer()
        Button("Export Trimmed Clip…", action: exportTrimmedVideo)
          .buttonStyle(.borderedProminent)
          .disabled(isLoading || isExporting || validRange == nil)
      }
      .padding()
    }
    .frame(width: 640, height: 520)
    .task(id: url) { await loadAsset() }
    .onDisappear {
      exportWasCancelled = true
      exportSession?.cancelExport()
      if let player, let previewBoundaryObserver {
        player.removeTimeObserver(previewBoundaryObserver)
        self.previewBoundaryObserver = nil
      }
    }
  }

  @MainActor
  private func loadAsset() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": authHeaderFields]
      let loadedAsset = AVURLAsset(url: url, options: options)
      let loadedDuration = try await loadedAsset.load(.duration).seconds
      guard loadedDuration.isFinite, loadedDuration > 0 else {
        errorMessage = "This video has no usable duration."
        return
      }
      let tracks = try await loadedAsset.loadTracks(withMediaType: .video)
      guard !tracks.isEmpty else {
        errorMessage = "This media contains no video track."
        return
      }
      asset = loadedAsset
      duration = loadedDuration
      startTime = 0
      endTime = loadedDuration
      let previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: loadedAsset))
      player = previewPlayer
    } catch {
      errorMessage = "Unable to load video: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func exportTrimmedVideo() {
    guard let asset, let range = validRange else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Trimmed Video.mov"
    panel.allowedContentTypes = [.movie]
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
          let outputType = session.supportedFileTypes.contains(.mov) ? AVFileType.mov : session.supportedFileTypes.first else {
      errorMessage = "This video cannot be exported in a supported format."
      return
    }

    let outputExtension = fileExtension(for: outputType)
    let finalURL = destination.pathExtension.lowercased() == outputExtension
      ? destination
      : destination.deletingPathExtension().appendingPathExtension(outputExtension)
    let temporaryURL = finalURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).\(outputExtension)")

    session.outputURL = temporaryURL
    session.outputFileType = outputType
    session.timeRange = CMTimeRange(
      start: CMTime(seconds: range.start, preferredTimescale: 600),
      duration: CMTime(seconds: range.end - range.start, preferredTimescale: 600)
    )
    exportSession = session
    isExporting = true
    errorMessage = nil
    exportWasCancelled = false

    let sessionBox = ExportSessionBox(session)
    session.exportAsynchronously {
      Task { @MainActor in
        isExporting = false
        exportSession = nil
        let completedSession = sessionBox.session
        guard completedSession.status == .completed, !exportWasCancelled else {
          try? FileManager.default.removeItem(at: temporaryURL)
          if completedSession.status != .cancelled, !exportWasCancelled {
            errorMessage = completedSession.error?.localizedDescription ?? "The video export failed."
          }
          return
        }
        do {
          if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
          }
          try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
          dismiss()
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
          errorMessage = "Unable to save the exported video: \(error.localizedDescription)"
        }
      }
    }
  }

  @MainActor
  private func previewSelectedRange() {
    guard let player, let range = validRange else { return }
    if let previewBoundaryObserver {
      player.removeTimeObserver(previewBoundaryObserver)
      self.previewBoundaryObserver = nil
    }
    let end = CMTime(seconds: range.end, preferredTimescale: 600)
    previewBoundaryObserver = player.addBoundaryTimeObserver(
      forTimes: [NSValue(time: end)],
      queue: .main
    ) {
      player.pause()
    }
    player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600))
    player.play()
  }

  @MainActor
  private func previewFromStart() {
    guard let player, let range = validRange else { return }
    if let previewBoundaryObserver {
      player.removeTimeObserver(previewBoundaryObserver)
      self.previewBoundaryObserver = nil
    }
    player.pause()
    player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600))
  }

  private func fileExtension(for fileType: AVFileType) -> String {
    switch fileType {
    case .mov: return "mov"
    case .mp4: return "mp4"
    case .m4v: return "m4v"
    default: return "mov"
    }
  }

  private func cancel() {
    exportWasCancelled = true
    exportSession?.cancelExport()
    player?.pause()
    dismiss()
  }

  private func timeLabel(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
  }
}

private struct VideoTrimPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .none
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
}
#endif
