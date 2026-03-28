#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
  @StateObject var viewModel: ContentViewModel

  private let gridColumns = [
    GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12),
  ]

  @ViewBuilder
  var body: some View {
    switch viewModel.appPhase {
    case .serverSetup:
      authShell {
        serverSetupCard
      }
    case .login:
      authShell {
        loginCard
      }
    case .library:
      libraryShell
    }
  }

  private var libraryShell: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
  }

  private func authShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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

  private var sidebar: some View {
    List(selection: $viewModel.selectedSidebarItem) {
      Section("Library") {
        ForEach(ContentViewModel.SidebarItem.allCases) { item in
          Label(item.rawValue, systemImage: item.iconName)
            .tag(item)
        }
      }

      accountSection
      uploadsSection
    }
    .navigationTitle("Immich")
    .listStyle(.sidebar)
  }

  private var detail: some View {
    VStack(spacing: 0) {
      header
      photoGrid

      if let selectedItem = viewModel.selectedItem {
        Divider()
        metadataPanel(for: selectedItem)
      }
    }
    .background(.background)
    .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search")
    .toolbar { primaryToolbar }
  }

  private var photoGrid: some View {
    Group {
      if viewModel.filteredItems.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(viewModel.filteredItems) { item in
              PhotoCard(
                item: item,
                isSelected: item.id == viewModel.selectedItemID,
                onSelect: { viewModel.selectedItemID = item.id },
                onFavoriteToggle: { viewModel.toggleFavorite(for: item.id) }
              )
            }
          }
          .padding(16)
        }
      }
    }
    .dropDestination(for: URL.self) { items, _ in
      viewModel.importFiles(items)
      return true
    }
  }

  private var accountSection: some View {
    Section("Account") {
      if let session = viewModel.currentSession {
        VStack(alignment: .leading, spacing: 6) {
          Text(session.userName)
            .font(.headline)
          Text(session.userEmail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let connectedServerDisplayURL = viewModel.connectedServerDisplayURL {
        Label(connectedServerDisplayURL, systemImage: "server.rack")
          .font(.caption)
      }

      if let connectedServerVersion = viewModel.connectedServerVersion {
        Label("Immich \(connectedServerVersion)", systemImage: "checkmark.seal")
          .font(.caption)
      }

      Button("Sign Out") {
        viewModel.signOut()
      }

      Button("Change Server") {
        viewModel.changeServer()
      }
    }
  }

  @ViewBuilder
  private var uploadsSection: some View {
    if viewModel.uploadRows.isEmpty == false {
      Section("Uploads") {
        ForEach(viewModel.uploadRows.prefix(5)) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.filename)
              .lineLimit(1)
              .font(.caption)
            ProgressView(value: row.progress)
              .controlSize(.small)
          }
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var primaryToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        importFromFinder()
      } label: {
        Image(systemName: "plus")
      }

      Button {
      } label: {
        Image(systemName: "square.and.arrow.up")
      }

      Menu {
        Button("Date Captured") {}
        Button("Date Added") {}
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(viewModel.selectedSidebarItem.rawValue)
        .font(.largeTitle)
        .fontWeight(.semibold)

      HStack {
        Text("\(viewModel.filteredItems.count) items")
          .foregroundStyle(.secondary)

        Spacer()

        Text(viewModel.statusText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.bar)
  }

  private var authHero: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Color.white.opacity(0.75))
          .frame(width: 84, height: 84)
          .shadow(color: Color.black.opacity(0.08), radius: 20, y: 10)

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

  private var serverSetupCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connect to your server")
        .font(.title2.weight(.semibold))

      Text("Enter the same Immich URL you use on mobile or web. The app will verify it before showing the login screen.")
        .foregroundStyle(.secondary)

      TextField("https://demo.immich.app", text: $viewModel.serverURLText)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()

      Button {
        Task {
          await viewModel.connect()
        }
      } label: {
        if viewModel.isConnecting {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text("Continue")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(viewModel.isConnecting)

      statusPanel
    }
    .padding(28)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var loginCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Sign in")
            .font(.title2.weight(.semibold))

          if let connectedServerDisplayURL = viewModel.connectedServerDisplayURL {
            Text(connectedServerDisplayURL)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Button("Change Server") {
          viewModel.changeServer()
        }
      }

      if let loginPageMessage = viewModel.loginPageMessage {
        Text(loginPageMessage)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      if viewModel.passwordLoginEnabled {
        TextField("Email", text: $viewModel.emailText)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()

        SecureField("Password", text: $viewModel.passwordText)
          .textFieldStyle(.roundedBorder)

        Button {
          Task {
            await viewModel.signIn()
          }
        } label: {
          if viewModel.isSigningIn {
            ProgressView()
              .frame(maxWidth: .infinity)
          } else {
            Text("Sign In")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isSigningIn)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Label("Password login is disabled on this server.", systemImage: "lock.shield")
            .font(.headline)

          if viewModel.oauthEnabled {
            Text("\(viewModel.oauthButtonText) is enabled on this server, but OAuth is not implemented yet in the macOS scaffold.")
              .foregroundStyle(.secondary)
          } else {
            Text("No supported login method is currently available in the macOS scaffold.")
              .foregroundStyle(.secondary)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      statusPanel
    }
    .padding(28)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var statusPanel: some View {
    Label(viewModel.statusText, systemImage: "info.circle")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "rectangle.stack.badge.person.crop")
        .font(.system(size: 42, weight: .semibold))
        .foregroundStyle(.secondary)

      VStack(spacing: 8) {
        Text(viewModel.emptyStateTitle)
          .font(.title3.weight(.semibold))

        Text(viewModel.emptyStateMessage)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }

      if viewModel.selectedSidebarItem == .imports {
        Button("Import Files") {
          importFromFinder()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }

  @ViewBuilder
  private func metadataPanel(for item: ContentViewModel.PhotoItem) -> some View {
    HStack(spacing: 24) {
      Label(item.title, systemImage: item.isVideo ? "video" : "photo")
      Label(item.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
      if item.isFavorite {
        Label("Favorite", systemImage: "heart.fill")
      }
      if item.isImported {
        Label("Imported", systemImage: "square.and.arrow.down")
      }
      Spacer()
    }
    .font(.caption)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.regularMaterial)
  }

  private func importFromFinder() {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.begin { response in
      guard response == .OK else { return }
      viewModel.importFiles(panel.urls)
    }
    #endif
  }
}

private struct PhotoCard: View {
  let item: ContentViewModel.PhotoItem
  let isSelected: Bool
  let onSelect: () -> Void
  let onFavoriteToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary)
          .aspectRatio(1, contentMode: .fit)
          .overlay {
            Image(systemName: item.isVideo ? "video" : "photo")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(.secondary)
          }

        HStack(spacing: 6) {
          if item.isFavorite {
            Image(systemName: "heart.fill")
          }

          if item.isVideo {
            Image(systemName: "video.fill")
            Text(item.timeLabel)
              .font(.caption2)
          }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(8)
        .shadow(radius: 3)
      }

      HStack(spacing: 8) {
        Text(item.title)
          .lineLimit(1)

        Spacer()

        Button {
          onFavoriteToggle()
        } label: {
          Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            .foregroundStyle(item.isFavorite ? .red : .secondary)
        }
        .buttonStyle(.plain)
      }

      Text(item.date.formatted(date: .abbreviated, time: .omitted))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(8)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
    .onTapGesture(perform: onSelect)
  }
}
#endif
