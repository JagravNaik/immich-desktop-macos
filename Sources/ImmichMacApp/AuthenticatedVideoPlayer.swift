#if canImport(SwiftUI)
import SwiftUI

#if canImport(AppKit)
import AppKit
import AVKit

struct AuthenticatedVideoPlayer: View {
  let url: URL
  let accessToken: String

  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        MacAVPlayerView(player: player)
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
      self.player = newPlayer
    }
  }
}

private struct MacAVPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .floating
    return view
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    if nsView.player !== player {
      nsView.player = player
    }
  }
}
#endif
#endif
