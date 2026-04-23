#if canImport(SwiftUI)
import SwiftUI

enum ImmichMotion {
  enum Context {
    case structural
    case interactive
    case search
    case hero
    case auth
  }

  enum Curves {
    static let searchSpring = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let uploadBannerSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let heroFallbackOpen = Animation.spring(response: 0.35, dampingFraction: 0.88)
    static let heroReveal = Animation.easeOut(duration: 0.12)
    static let heroExpand = Animation.easeInOut(duration: 0.24)
    static let heroFallbackClose = Animation.easeOut(duration: 0.18)
    static let heroCollapse = Animation.easeInOut(duration: 0.22)

    static let structuralShort = Animation.easeInOut(duration: 0.2)
    static let structuralMedium = Animation.easeInOut(duration: 0.25)
    static let structuralLong = Animation.easeInOut(duration: 0.3)
    static let structuralQuick = Animation.easeInOut(duration: 0.18)

    static let interactiveQuick = Animation.easeOut(duration: 0.08)
    static let interactiveFast = Animation.easeOut(duration: 0.15)
    static let interactive = Animation.easeOut(duration: 0.2)

    static let viewerPaging = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let pinchRebound = Animation.spring(response: 0.28, dampingFraction: 0.88)
    static let livePhotoFade = Animation.easeOut(duration: 0.4)
    static let statusFade = Animation.easeOut(duration: 0.2)
    static let authAmbient = Animation.easeInOut(duration: 8).repeatForever(autoreverses: true)
  }

  static func animation(for context: Context) -> Animation {
    switch context {
    case .structural:
      Curves.structuralShort
    case .interactive:
      Curves.interactiveFast
    case .search:
      Curves.searchSpring
    case .hero:
      Curves.heroCollapse
    case .auth:
      Curves.authAmbient
    }
  }

  enum Timing {
    static let heroOpenCleanupDelay: TimeInterval = 0.42
    static let heroCloseCleanupDelay: TimeInterval = 0.38
    static let pageSwipeDuration: Duration = .milliseconds(280)
  }
}
#endif
