#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit
import AVKit

struct AuthenticatedVideoPlayer: View {
  let url: URL
  let accessToken: String
  var showControls: Bool = true

  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        MacAVPlayerView(player: player, showControls: showControls)
          .onAppear {
            player.play()
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
    .task(id: url) {
      // Configure AVURLAsset to pass the Authorization header
      let options: [String: Any] = [
        "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(accessToken)"]
      ]
      let asset = AVURLAsset(url: url, options: options)
      let playerItem = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: playerItem)
      // Loop the video for Live Photos
      newPlayer.actionAtItemEnd = .none // We can handle custom looping if needed
      self.player = newPlayer
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
