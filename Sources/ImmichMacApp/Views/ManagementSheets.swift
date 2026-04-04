#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import ImmichCore

private struct ManagementStatusBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

struct TagPill: View {
  let title: String
  let colorHex: String?
  var removeAction: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Self.color(from: colorHex))
        .frame(width: 10, height: 10)

      Text(title)
        .font(.caption.weight(.medium))
        .lineLimit(1)

      if let removeAction {
        Button(action: removeAction) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove tag")
        .accessibilityHint("Removes this tag")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
  }

  private static func color(from hex: String?) -> Color {
    guard let hex else { return .accentColor }
    let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
      return .accentColor
    }

    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    return Color(red: red, green: green, blue: blue)
  }
}

struct APIKeysSheet: View {
  @ObservedObject var appState: AppState
  @State private var name = ""
  @State private var permissionsText = "all"
  @State private var isLoading = false
  @State private var isCreating = false
  @State private var errorMessage: String?
  @State private var createdSecret: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("API Keys")
            .font(.title2.weight(.semibold))
          Text("Create keys for scripts, automation, or alternate Mac sign-in.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") {
          appState.showAPIKeysSheet = false
        }
      }

      if let errorMessage {
        ManagementStatusBanner(message: errorMessage)
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Create New Key")
          .font(.headline)

        TextField("Key name", text: $name)
          .textFieldStyle(.roundedBorder)

        TextField("Permissions (comma separated)", text: $permissionsText)
          .textFieldStyle(.roundedBorder)

        HStack {
          Spacer()
          Button {
            Task { await createKey() }
          } label: {
            if isCreating {
              ProgressView()
            } else {
              Text("Create Key")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isCreating)
        }
      }
      .padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      if let createdSecret {
        VStack(alignment: .leading, spacing: 10) {
          Text("Copy This Secret Now")
            .font(.headline)
          Text(createdSecret)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

          HStack {
            Spacer()
            Button("Copy Secret") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(createdSecret, forType: .string)
            }
          }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      VStack(alignment: .leading, spacing: 0) {
        if isLoading {
          ProgressView("Loading API keys…")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if appState.apiKeys.isEmpty {
          Text("No API keys yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else {
          ScrollView {
            VStack(spacing: 10) {
              ForEach(appState.apiKeys) { apiKey in
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                  VStack(alignment: .leading, spacing: 4) {
                    Text(apiKey.name.isEmpty ? "Untitled Key" : apiKey.name)
                      .font(.headline)

                    Text(permissionSummary(for: apiKey))
                      .font(.caption)
                      .foregroundStyle(.secondary)

                    Text("Updated \(apiKey.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }

                  Spacer()

                  Button("Delete", role: .destructive) {
                    Task { await deleteKey(apiKey) }
                  }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
              }
            }
          }
        }
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 620, height: 640)
    .task {
      await refresh()
    }
  }

  private func permissionSummary(for apiKey: ImmichAPIKey) -> String {
    if apiKey.permissions.contains("all") {
      return "All permissions"
    }
    if apiKey.permissions.isEmpty {
      return "No permissions"
    }
    return apiKey.permissions.joined(separator: ", ")
  }

  private func refresh() async {
    isLoading = true
    defer { isLoading = false }

    do {
      try await appState.loadAPIKeys()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func createKey() async {
    isCreating = true
    createdSecret = nil
    defer { isCreating = false }

    do {
      let created = try await appState.createAPIKey(name: name, permissionsText: permissionsText)
      createdSecret = created.secret
      name = ""
      permissionsText = "all"
      errorMessage = nil
    } catch {
      createdSecret = nil
      errorMessage = error.localizedDescription
    }
  }

  private func deleteKey(_ apiKey: ImmichAPIKey) async {
    do {
      try await appState.deleteAPIKey(apiKey.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct TagsSheet: View {
  @ObservedObject var appState: AppState
  @State private var draftTags = ""
  @State private var isLoading = false
  @State private var isCreating = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Tags")
            .font(.title2.weight(.semibold))
          Text("Create reusable tags and clean up the global tag list.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") {
          appState.showTagsSheet = false
        }
      }

      if let errorMessage {
        ManagementStatusBanner(message: errorMessage)
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Upsert Tags")
          .font(.headline)

        TextField("Family, Travel/Italy, Favorites/Prints", text: $draftTags)
          .textFieldStyle(.roundedBorder)

        HStack {
          Spacer()
          Button {
            Task { await createTags() }
          } label: {
            if isCreating {
              ProgressView()
            } else {
              Text("Save Tags")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isCreating)
        }
      }
      .padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      VStack(alignment: .leading, spacing: 0) {
        if isLoading {
          ProgressView("Loading tags…")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if appState.tags.isEmpty {
          Text("No tags yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else {
          ScrollView {
            VStack(spacing: 10) {
              ForEach(appState.tags) { tag in
                HStack(spacing: 12) {
                  TagPill(title: tag.value, colorHex: tag.color)
                  Spacer()
                  Button("Delete", role: .destructive) {
                    Task { await deleteTag(tag) }
                  }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
              }
            }
          }
        }
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 620, height: 640)
    .task {
      await refresh()
    }
  }

  private func refresh() async {
    isLoading = true
    defer { isLoading = false }

    do {
      try await appState.loadTags()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func createTags() async {
    isCreating = true
    defer { isCreating = false }

    do {
      _ = try await appState.upsertTags(from: draftTags)
      draftTags = ""
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteTag(_ tag: ImmichTag) async {
    do {
      try await appState.deleteTag(tag.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct AssetTagEditorSheet: View {
  @ObservedObject var appState: AppState
  @State private var newTagsText = ""
  @State private var isWorking = false
  @State private var errorMessage: String?

  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(appState.activeTagEditorTitle)
            .font(.title2.weight(.semibold))
          Text("\(appState.activeTagEditorAssetIDs.count) selected item(s)")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") {
          appState.showTagEditorSheet = false
        }
      }

      if let errorMessage {
        ManagementStatusBanner(message: errorMessage)
      }

      if !appState.activeTagEditorCurrentTags.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Current Tags")
            .font(.headline)

          LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(appState.activeTagEditorCurrentTags) { tag in
              TagPill(title: tag.value, colorHex: tag.color) {
                Task { await removeTag(tag) }
              }
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Add Tags")
          .font(.headline)

        TextField("Family, Travel/Italy", text: $newTagsText)
          .textFieldStyle(.roundedBorder)

        HStack {
          Spacer()
          Button {
            Task { await addTypedTags() }
          } label: {
            if isWorking {
              ProgressView()
            } else {
              Text("Apply Tags")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isWorking)
        }
      }
      .padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      if !appState.tags.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Existing Tags")
            .font(.headline)

          ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
              ForEach(appState.tags) { tag in
                Button {
                  Task { await addExistingTag(tag) }
                } label: {
                  TagPill(title: tag.value, colorHex: tag.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 700, height: 560)
    .task {
      if appState.tags.isEmpty {
        do {
          try await appState.loadTags()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func addTypedTags() async {
    isWorking = true
    defer { isWorking = false }

    do {
      let tagNames = newTagsText
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let added = try await appState.applyTags(
        named: tagNames,
        to: appState.activeTagEditorAssetIDs
      )
      mergeCurrentTags(with: added)
      newTagsText = ""
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addExistingTag(_ tag: ImmichTag) async {
    isWorking = true
    defer { isWorking = false }

    do {
      let added = try await appState.applyTags(named: [tag.value], to: appState.activeTagEditorAssetIDs)
      mergeCurrentTags(with: added)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func removeTag(_ tag: ImmichTag) async {
    isWorking = true
    defer { isWorking = false }

    do {
      try await appState.removeTag(tag.id, from: appState.activeTagEditorAssetIDs)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func mergeCurrentTags(with incoming: [ImmichTag]) {
    guard !incoming.isEmpty else { return }
    var merged = Dictionary(appState.activeTagEditorCurrentTags.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    for tag in incoming {
      merged[tag.id] = tag
    }
    appState.activeTagEditorCurrentTags = merged.values.sorted {
      $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
    }
  }
}

struct AdminUsersSheet: View {
  @ObservedObject var appState: AppState
  @State private var includeDeleted = true
  @State private var name = ""
  @State private var email = ""
  @State private var password = ""
  @State private var storageLabel = ""
  @State private var quotaText = ""
  @State private var grantAdmin = false
  @State private var requirePasswordChange = true
  @State private var sendNotification = false
  @State private var isLoading = false
  @State private var isCreating = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Admin Users")
            .font(.title2.weight(.semibold))
          Text("Create, delete, and restore Immich users from macOS.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Include Deleted", isOn: $includeDeleted)
          .toggleStyle(.switch)
          .onChange(of: includeDeleted) { _, _ in
            Task { await refresh() }
          }
        Button("Done") {
          appState.showAdminUsersSheet = false
        }
      }

      if let errorMessage {
        ManagementStatusBanner(message: errorMessage)
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Create User")
          .font(.headline)

        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)

        TextField("Email", text: $email)
          .textFieldStyle(.roundedBorder)

        SecureField("Password", text: $password)
          .textFieldStyle(.roundedBorder)

        HStack {
          TextField("Storage label (optional)", text: $storageLabel)
            .textFieldStyle(.roundedBorder)
          TextField("Quota bytes", text: $quotaText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
        }

        Toggle("Grant admin access", isOn: $grantAdmin)
        Toggle("Require password change on next login", isOn: $requirePasswordChange)
        Toggle("Send notification email", isOn: $sendNotification)

        HStack {
          Spacer()
          Button {
            Task { await createUser() }
          } label: {
            if isCreating {
              ProgressView()
            } else {
              Text("Create User")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isCreating)
        }
      }
      .padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      VStack(alignment: .leading, spacing: 0) {
        if isLoading {
          ProgressView("Loading users…")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if appState.adminUsers.isEmpty {
          Text(appState.hasAdminAccess ? "No users found." : "Admin access is required to manage users.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else {
          ScrollView {
            VStack(spacing: 10) {
              ForEach(appState.adminUsers) { user in
                HStack(alignment: .top, spacing: 12) {
                  Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 32, height: 32)
                    .overlay(
                      Text(String(user.name.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                    )

                  VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                      Text(user.name)
                        .font(.headline)
                      if user.isAdmin {
                        Text("Admin")
                          .font(.caption2.weight(.semibold))
                          .padding(.horizontal, 6)
                          .padding(.vertical, 3)
                          .background(.blue.opacity(0.15), in: Capsule())
                      }
                      if user.isDeleted {
                        Text("Deleted")
                          .font(.caption2.weight(.semibold))
                          .padding(.horizontal, 6)
                          .padding(.vertical, 3)
                          .background(.red.opacity(0.15), in: Capsule())
                      }
                    }

                    Text(user.email)
                      .font(.subheadline)
                      .foregroundStyle(.secondary)

                    if let storageLabel = user.storageLabel, !storageLabel.isEmpty {
                      Text(storageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    let used = ByteCountFormatter.string(fromByteCount: Int64(user.quotaUsageInBytes ?? 0), countStyle: .file)
                    let quota = user.quotaSizeInBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unlimited"
                    Text("Usage \(used) of \(quota)")
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }

                  Spacer()

                  Menu {
                    if user.isDeleted {
                      Button("Restore") {
                        Task { await restore(user) }
                      }
                    } else {
                      Button("Delete") {
                        Task { await delete(user, force: false) }
                      }
                      Button("Force Delete", role: .destructive) {
                        Task { await delete(user, force: true) }
                      }
                    }
                  } label: {
                    Image(systemName: "ellipsis.circle")
                      .font(.title3)
                  }
                  .menuStyle(.borderlessButton)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
              }
            }
          }
        }
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 760, height: 680)
    .task {
      await refresh()
    }
  }

  private func refresh() async {
    isLoading = true
    defer { isLoading = false }

    do {
      try await appState.loadAdminUsers(includeDeleted: includeDeleted)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func createUser() async {
    isCreating = true
    defer { isCreating = false }

    do {
      _ = try await appState.createAdminUser(
        name: name,
        email: email,
        password: password,
        isAdmin: grantAdmin,
        shouldChangePassword: requirePasswordChange,
        quotaSizeInBytes: Int(quotaText),
        storageLabel: storageLabel.isEmpty ? nil : storageLabel,
        notify: sendNotification
      )
      name = ""
      email = ""
      password = ""
      storageLabel = ""
      quotaText = ""
      grantAdmin = false
      requirePasswordChange = true
      sendNotification = false
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func delete(_ user: AdminUser, force: Bool) async {
    do {
      _ = try await appState.deleteAdminUser(user.id, force: force)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func restore(_ user: AdminUser) async {
    do {
      _ = try await appState.restoreAdminUser(user.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
#endif
