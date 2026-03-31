#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit
import AVKit

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
      let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": authHeaderFields]
      let asset = AVURLAsset(url: url, options: options)
      let playerItem = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: playerItem)
      newPlayer.actionAtItemEnd = .pause
      self.player = newPlayer

      // Observe end of playback
      let center = NotificationCenter.default
      for await _ in center.notifications(named: .AVPlayerItemDidPlayToEndTime, object: playerItem) {
        onPlaybackEnded?()
      }
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
