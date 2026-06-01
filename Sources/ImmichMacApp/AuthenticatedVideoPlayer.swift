#if canImport(SwiftUI)
import Combine
@preconcurrency import Foundation
import SwiftUI

#if canImport(AppKit)
@preconcurrency import AppKit
@preconcurrency import AVKit

// AVFoundation does not expose a Swift symbol for this option on macOS, so we centralize the
// framework-defined key here instead of scattering raw literals through the code.
private let AVURLAssetHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

struct AuthenticatedVideoPlayer: View {
  let url: URL
  let authHeaderFields: [String: String]
  var showControls: Bool = true
  var isPlaying: Bool = true
  var onPlaybackEnded: (() -> Void)?

  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        MacAVPlayerView(player: player, showControls: showControls)
          .onAppear {
            if isPlaying { player.play() }
          }
          .onDisappear {
            player.pause()
          }
      } else {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
      }
    }
    .onChange(of: isPlaying) { _, playing in
      guard let player else { return }
      if playing {
        player.seek(to: .zero)
        player.play()
      } else {
        player.pause()
      }
    }
    .task(id: url) {
      // Configure AVURLAsset to pass the Authorization header
      let options: [String: Any] = [AVURLAssetHTTPHeaderFieldsKey: authHeaderFields]
      let asset = AVURLAsset(url: url, options: options)
      let playerItem = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: playerItem)
      newPlayer.actionAtItemEnd = .pause
      self.player = newPlayer
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
      guard
        let endedItem = notification.object as? AVPlayerItem,
        endedItem === player?.currentItem
      else {
        return
      }

      onPlaybackEnded?()
    }
  }
}

private struct MacAVPlayerView: NSViewRepresentable {
  let player: AVPlayer
  let showControls: Bool

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = showControls ? .floating : .none
    return view
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    if nsView.player !== player {
      nsView.player = player
    }
    nsView.controlsStyle = showControls ? .floating : .none
  }
}
#endif
#endif
