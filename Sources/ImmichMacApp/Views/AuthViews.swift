#if canImport(SwiftUI)
import SwiftUI

// MARK: - Premium Shared Styles

struct PremiumButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false
  
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .padding(.vertical, 12)
      .padding(.horizontal, 24)
      .background(
        LinearGradient(
          colors: isEnabled
            ? (configuration.isPressed
               ? [Color(red: 0.25, green: 0.35, blue: 0.85), Color(red: 0.20, green: 0.30, blue: 0.80)]
               : [Color(red: 0.35, green: 0.45, blue: 0.95), Color(red: 0.30, green: 0.40, blue: 0.90)])
            : [Color.secondary.opacity(0.2), Color.secondary.opacity(0.2)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .foregroundColor(isEnabled ? .white : .secondary)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .shadow(color: isEnabled ? Color(red: 0.30, green: 0.40, blue: 0.90).opacity(isHovered ? 0.4 : 0.2) : .clear, radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(.white.opacity(0.2), lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.2), value: isHovered)
      .onHover { hovering in
        isHovered = hovering
      }
      .contentShape(Rectangle())
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false
  
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .padding(.vertical, 12)
      .padding(.horizontal, 24)
      .background(.regularMaterial)
      .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
      .foregroundColor(isEnabled ? .primary : .secondary)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.2), value: isHovered)
      .onHover { hovering in
        isHovered = hovering
      }
      .contentShape(Rectangle())
  }
}

struct PremiumTextFieldStyle: TextFieldStyle {
  @Environment(\.colorScheme) private var colorScheme
  
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.6))
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
  }
}

struct GlassCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  
  func body(content: Content) -> some View {
    content
      .padding(32)
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.4))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.05), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
  }
}

extension View {
  func glassCard() -> some View {
    modifier(GlassCardModifier())
  }
}

// MARK: - Auth Views (Server Setup & Login)

struct AuthShell<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @Environment(\.colorScheme) private var colorScheme
  @State private var isAnimating = false

  var body: some View {
    ZStack {
      ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        
        GeometryReader { proxy in
          let width = proxy.size.width
          let height = proxy.size.height
          
          Circle()
            .fill(Color(red: 0.30, green: 0.40, blue: 0.90).opacity(colorScheme == .dark ? 0.3 : 0.15))
            .frame(width: width * 0.8)
            .blur(radius: 80)
            .offset(x: isAnimating ? width * 0.1 : -width * 0.1, y: isAnimating ? -height * 0.1 : height * 0.1)
            
          Circle()
            .fill(Color(red: 0.40, green: 0.20, blue: 0.80).opacity(colorScheme == .dark ? 0.2 : 0.1))
            .frame(width: width * 0.6)
            .blur(radius: 80)
            .offset(x: isAnimating ? -width * 0.2 : width * 0.2, y: isAnimating ? height * 0.2 : -height * 0.2)
        }
      }
      .ignoresSafeArea()
      .onAppear {
        withAnimation(.easeInOut(duration: 8.0).repeatForever(autoreverses: true)) {
          isAnimating = true
        }
      }

      VStack(spacing: 36) {
        authHero
        content()
      }
      .padding(32)
      .frame(maxWidth: 520)
      .offset(y: -20)
    }
  }

  private var authHero: some View {
    VStack(spacing: 20) {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color(red: 0.35, green: 0.45, blue: 0.95),
                Color(red: 0.25, green: 0.35, blue: 0.85)
              ],
              startPoint: .top, endPoint: .bottom
            )
          )
          .frame(width: 88, height: 88)
          .shadow(color: Color(red: 0.30, green: 0.40, blue: 0.90).opacity(0.3), radius: 16, y: 8)
          .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .stroke(.white.opacity(0.2), lineWidth: 1)
          )

        Image(systemName: "photo.stack")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white)
          .accessibilityHidden(true)
      }

      VStack(spacing: 8) {
        Text("Immich for macOS")
          .font(.system(size: 28, weight: .semibold, design: .default))
          .tracking(-0.3)

        Text("Start by verifying your server, then sign in with your Immich account.")
          .multilineTextAlignment(.center)
          .font(.body)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
    }
  }
}

// MARK: - Server Setup Card

struct ServerSetupCard: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Connect to your server")
          .font(.title2.weight(.semibold))

        Text("Enter the same Immich URL you use on mobile or web.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      TextField("https://demo.immich.app", text: $appState.serverURLText)
        .textFieldStyle(PremiumTextFieldStyle())
        .autocorrectionDisabled()
        .submitLabel(.go)

      Button {
        Task { await appState.connect() }
      } label: {
        if appState.isConnecting {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
          Text("Continue").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(PremiumButtonStyle())
      .disabled(appState.isConnecting)

      statusLabel
    }
    .glassCard()
    .onSubmit {
      guard !appState.isConnecting else { return }
      Task { await appState.connect() }
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    if !appState.statusText.isEmpty {
      Label(appState.statusText, systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeOut, value: appState.statusText)
    }
  }
}

// MARK: - Login Card

struct LoginCard: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Sign in")
            .font(.title2.weight(.semibold))

          if let url = appState.connectedServerDisplayURL {
            Text(url)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Change Server") { appState.changeServer() }
          .buttonStyle(.link)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Color.accentColor)
      }

      if let msg = appState.loginPageMessage {
        Text(msg)
          .font(.callout)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(.thinMaterial)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
          )
      }

      Picker("Sign in with", selection: $appState.authMethod) {
        ForEach(AppState.AuthMethod.allCases) { method in
          Text(method.rawValue).tag(method)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if appState.authMethod == .apiKey {
        apiKeyFields
      } else if appState.passwordLoginEnabled {
        passwordFields
      } else {
        noPasswordLogin
      }

      statusLabel
    }
    .glassCard()
    .animation(.easeInOut(duration: 0.3), value: appState.authMethod)
  }

  private var passwordFields: some View {
    VStack(spacing: 16) {
      TextField("Email", text: $appState.emailText)
        .textFieldStyle(PremiumTextFieldStyle())
        .autocorrectionDisabled()
        .submitLabel(.next)

      SecureField("Password", text: $appState.passwordText)
        .textFieldStyle(PremiumTextFieldStyle())
        .submitLabel(.go)

      Button {
        Task { await appState.signIn() }
      } label: {
        if appState.isSigningIn {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
          Text("Sign In").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(PremiumButtonStyle())
      .disabled(appState.isSigningIn)

      if appState.oauthEnabled {
        HStack {
          VStack { Divider() }
          Text("OR").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
          VStack { Divider() }
        }
        .padding(.vertical, 4)
        
        Button {
          appState.signInWithOAuth()
        } label: {
          Label(appState.oauthButtonText, systemImage: "globe")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(appState.isSigningIn)
      }
    }
    .onSubmit {
      guard !appState.isSigningIn else { return }
      Task { await appState.signIn() }
    }
  }

  private var apiKeyFields: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Use an Immich API key to sign in without a password.")
        .font(.callout)
        .foregroundStyle(.secondary)

      SecureField("API Key", text: $appState.apiKeyText)
        .textFieldStyle(PremiumTextFieldStyle())
        .submitLabel(.go)

      Button {
        Task { await appState.signInWithAPIKey() }
      } label: {
        if appState.isSigningIn {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
          Text("Use API Key").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(PremiumButtonStyle())
      .disabled(appState.isSigningIn)
    }
    .onSubmit {
      guard !appState.isSigningIn else { return }
      Task { await appState.signInWithAPIKey() }
    }
  }

  private var noPasswordLogin: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Password login is disabled.", systemImage: "lock.shield")
        .font(.headline)

      if appState.oauthEnabled {
        Button {
          appState.signInWithOAuth()
        } label: {
          if appState.isSigningIn {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
          } else {
            Label(appState.oauthButtonText, systemImage: "globe")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(PremiumButtonStyle())
        .disabled(appState.isSigningIn)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.thinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
    )
  }

  @ViewBuilder
  private var statusLabel: some View {
    if !appState.statusText.isEmpty {
      Label(appState.statusText, systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeOut, value: appState.statusText)
    }
  }
}
#endif
