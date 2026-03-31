#if canImport(SwiftUI)
import SwiftUI

// MARK: - Auth Views (Server Setup & Login)

struct AuthShell<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.95, green: 0.97, blue: 1.0),
          Color(red: 0.88, green: 0.94, blue: 0.98),
          Color(red: 0.98, green: 0.94, blue: 0.9),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 28) {
        authHero
        content()
      }
      .padding(32)
      .frame(maxWidth: 540)
    }
  }

  private var authHero: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(.ultraThinMaterial)
          .frame(width: 84, height: 84)
          .shadow(color: .black.opacity(0.08), radius: 20, y: 10)

        Image(systemName: "photo.stack")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }

      VStack(spacing: 8) {
        Text("Immich for macOS")
          .font(.system(size: 30, weight: .bold, design: .rounded))

        Text("Start by verifying your server, then sign in with your Immich account.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Server Setup Card

struct ServerSetupCard: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connect to your server")
        .font(.title2.weight(.semibold))

      Text("Enter the same Immich URL you use on mobile or web.")
        .foregroundStyle(.secondary)

      TextField("https://demo.immich.app", text: $appState.serverURLText)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()

      Button {
        Task { await appState.connect() }
      } label: {
        if appState.isConnecting {
          ProgressView().frame(maxWidth: .infinity)
        } else {
          Text("Continue").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(appState.isConnecting)

      statusLabel
    }
    .padding(28)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var statusLabel: some View {
    Label(appState.statusText, systemImage: "info.circle")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

// MARK: - Login Card

struct LoginCard: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Sign in")
            .font(.title2.weight(.semibold))

          if let url = appState.connectedServerDisplayURL {
            Text(url)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Change Server") { appState.changeServer() }
      }

      if let msg = appState.loginPageMessage {
        Text(msg)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      Picker("Sign in with", selection: $appState.authMethod) {
        ForEach(AppState.AuthMethod.allCases) { method in
          Text(method.rawValue).tag(method)
        }
      }
      .pickerStyle(.segmented)

      if appState.authMethod == .apiKey {
        apiKeyFields
      } else if appState.passwordLoginEnabled {
        passwordFields
      } else {
        noPasswordLogin
      }

      statusLabel
    }
    .padding(28)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var passwordFields: some View {
    VStack(spacing: 14) {
      TextField("Email", text: $appState.emailText)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()

      SecureField("Password", text: $appState.passwordText)
        .textFieldStyle(.roundedBorder)

      Button {
        Task { await appState.signIn() }
      } label: {
        if appState.isSigningIn {
          ProgressView().frame(maxWidth: .infinity)
        } else {
          Text("Sign In").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(appState.isSigningIn)

      if appState.oauthEnabled {
        Divider()
        Button {
          appState.signInWithOAuth()
        } label: {
          Label(appState.oauthButtonText, systemImage: "globe")
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(appState.isSigningIn)
      }
    }
  }

  private var apiKeyFields: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Use an Immich API key to sign in without a password.")
        .font(.callout)
        .foregroundStyle(.secondary)

      SecureField("API Key", text: $appState.apiKeyText)
        .textFieldStyle(.roundedBorder)

      Button {
        Task { await appState.signInWithAPIKey() }
      } label: {
        if appState.isSigningIn {
          ProgressView().frame(maxWidth: .infinity)
        } else {
          Text("Use API Key").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(appState.isSigningIn)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var noPasswordLogin: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Password login is disabled.", systemImage: "lock.shield")
        .font(.headline)

      if appState.oauthEnabled {
        Button {
          appState.signInWithOAuth()
        } label: {
          if appState.isSigningIn {
            ProgressView().frame(maxWidth: .infinity)
          } else {
            Label(appState.oauthButtonText, systemImage: "globe")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(appState.isSigningIn)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var statusLabel: some View {
    Label(appState.statusText, systemImage: "info.circle")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
#endif
