import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImmichCore

public func immichLog(_ message: @autoclosure () -> String) {
  #if DEBUG
  print("[Immich]", message())
  #endif
}

private struct MultipartFormField {
  let name: String
  let value: String
}

private struct MultipartBodyFile {
  let url: URL
  let contentLength: UInt64
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let onProgress: @Sendable (Double) -> Void

  init(onProgress: @escaping @Sendable (Double) -> Void) {
    self.onProgress = onProgress
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    let progress = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
    onProgress(progress)
  }
}

private func buildMultipartBodyFile(
  boundary: String,
  fields: [MultipartFormField],
  fileFieldName: String,
  fileURL: URL,
  filename: String,
  mimeType: String
) throws -> MultipartBodyFile {
  let fileManager = FileManager.default
  let directoryURL = fileManager.temporaryDirectory.appendingPathComponent("ImmichMacApp", isDirectory: true)
  try fileManager.createDirectory(
    at: directoryURL,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )

  let multipartURL = directoryURL.appendingPathComponent("upload-\(UUID().uuidString).multipart")
  guard fileManager.createFile(
    atPath: multipartURL.path,
    contents: nil,
    attributes: [.posixPermissions: 0o600]
  ) else {
    throw ImmichAPIError.requestFailed(statusCode: 0, message: "Failed to prepare upload body.")
  }

  let outputHandle = try FileHandle(forWritingTo: multipartURL)
  defer { try? outputHandle.close() }

  for field in fields {
    try writeMultipartString("--\(boundary)\r\n", to: outputHandle)
    try writeMultipartString("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n", to: outputHandle)
    try writeMultipartString("\(field.value)\r\n", to: outputHandle)
  }

  try writeMultipartString("--\(boundary)\r\n", to: outputHandle)
  try writeMultipartString(
    "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n",
    to: outputHandle
  )
  try writeMultipartString("Content-Type: \(mimeType)\r\n\r\n", to: outputHandle)
  try copyFileContents(from: fileURL, to: outputHandle)
  try writeMultipartString("\r\n--\(boundary)--\r\n", to: outputHandle)

  let attributes = try fileManager.attributesOfItem(atPath: multipartURL.path)
  let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
  return MultipartBodyFile(url: multipartURL, contentLength: size)
}

private func writeMultipartString(_ string: String, to handle: FileHandle) throws {
  guard let data = string.data(using: .utf8) else { return }
  try handle.write(contentsOf: data)
}

private func copyFileContents(from fileURL: URL, to handle: FileHandle) throws {
  let inputHandle = try FileHandle(forReadingFrom: fileURL)
  defer { try? inputHandle.close() }

  while true {
    let chunk = try inputHandle.read(upToCount: 64 * 1024) ?? Data()
    if chunk.isEmpty {
      break
    }
    try handle.write(contentsOf: chunk)
  }
}

private enum ISO8601FractionalSecondsFormatter {
  private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let lock = NSLock()

  static func string(from date: Date) -> String {
    lock.lock()
    defer { lock.unlock() }
    return formatter.string(from: date)
  }
}

private func iso8601FractionalSecondsString(for date: Date) -> String {
  ISO8601FractionalSecondsFormatter.string(from: date)
}

// /timeline/bucket requires a UTC-midnight timestamp, even when a bucket ID is date-only.
private func normalizedTimelineBucketValue(_ value: String) -> String {
  guard let date = TimelineBucketMapper.parseDate(value) else { return value }
  return iso8601FractionalSecondsString(for: date)
}

public protocol ImmichAPIClient: Sendable {
  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo
  func fetchVersionCheckState(server: ImmichServer, session: UserSession) async throws -> VersionCheckState
  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration
  func login(server: ImmichServer, email: String, password: String) async throws -> UserSession
  func loginWithAPIKey(server: ImmichServer, apiKey: String) async throws -> UserSession
  func resumeSession(server: ImmichServer, accessToken: String) async throws -> UserSession
  func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary]
  func fetchTimelineBucket(server: ImmichServer, session: UserSession, timeBucket: String) async throws -> [RemoteTimelineAsset]
  func fetchAlbums(server: ImmichServer, session: UserSession) async throws -> [Album]
  func fetchAlbumAssets(server: ImmichServer, session: UserSession, albumId: String) async throws -> (Album, [RemoteTimelineAsset])
  func fetchPeople(server: ImmichServer, session: UserSession) async throws -> [Person]
  func fetchAssetDetail(server: ImmichServer, session: UserSession, assetId: String) async throws -> AssetDetail
  func fetchAssetStatistics(server: ImmichServer, session: UserSession) async throws -> AssetStatistics
  func setFavorite(server: ImmichServer, session: UserSession, assetId: String, isFavorite: Bool) async throws
  func updateAssetLocation(server: ImmichServer, session: UserSession, assetId: String, latitude: Double, longitude: Double) async throws
  func updateAssetsLocation(server: ImmichServer, session: UserSession, assetIds: [String], latitude: Double, longitude: Double) async throws
  func reverseGeocode(server: ImmichServer, session: UserSession, latitude: Double, longitude: Double) async throws -> [ReverseGeocodePlace]
  func updateAssets(server: ImmichServer, session: UserSession, assetIds: [String], update: AssetBulkUpdate) async throws
  func fetchAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws -> [AssetEditAction]
  func replaceAssetEdits(server: ImmichServer, session: UserSession, assetId: String, edits: [AssetEditAction]) async throws
  func deleteAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws
  func fetchHiddenAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset]
  func fetchDuplicates(server: ImmichServer, session: UserSession) async throws -> [DuplicateGroup]
  func resolveDuplicates(server: ImmichServer, session: UserSession, groups: [DuplicateGroup]) async throws
  func updateAssetDescription(server: ImmichServer, session: UserSession, assetId: String, description: String) async throws
  func updateAssetDateTime(server: ImmichServer, session: UserSession, assetId: String, date: Date) async throws
  func trashAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws
  func fetchTrashedAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset]
  func restoreAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws
  func emptyTrash(server: ImmichServer, session: UserSession) async throws
  func searchAssets(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult
  func searchMetadataText(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult
  func searchMetadataDescription(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult
  func searchMetadataOCR(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult
  func fetchSearchSuggestions(server: ImmichServer, session: UserSession, type: String, filters: [String: String]) async throws -> [String]
  func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset]
  func fetchScreenshots(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset]
  func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker]
  func fetchAlbumMapMarkers(server: ImmichServer, session: UserSession, albumId: String) async throws -> [MapMarker]
  func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory]
  func downloadOriginalAsset(server: ImmichServer, session: UserSession, assetId: String) async throws -> (Data, String)
  func uploadAsset(server: ImmichServer, session: UserSession, fileURL: URL, fileCreatedAt: Date?, durationMilliseconds: Int?, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String
  func createAlbum(server: ImmichServer, session: UserSession, name: String, description: String, assetIds: [String]) async throws -> Album
  func renameAlbum(server: ImmichServer, session: UserSession, albumId: String, newName: String) async throws
  func deleteAlbum(server: ImmichServer, session: UserSession, albumId: String) async throws
  func addAssetsToAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws
  func removeAssetsFromAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws
  func fetchAPIKeys(server: ImmichServer, session: UserSession) async throws -> [ImmichAPIKey]
  func createAPIKey(server: ImmichServer, session: UserSession, name: String, permissions: [String]) async throws -> CreatedAPIKey
  func deleteAPIKey(server: ImmichServer, session: UserSession, id: String) async throws
  func fetchTags(server: ImmichServer, session: UserSession) async throws -> [ImmichTag]
  func upsertTags(server: ImmichServer, session: UserSession, tagNames: [String]) async throws -> [ImmichTag]
  func tagAssets(server: ImmichServer, session: UserSession, assetIDs: [String], tagIDs: [String]) async throws
  func untagAssets(server: ImmichServer, session: UserSession, tagID: String, assetIDs: [String]) async throws
  func deleteTag(server: ImmichServer, session: UserSession, id: String) async throws
  func fetchAdminUsers(server: ImmichServer, session: UserSession, includeDeleted: Bool) async throws -> [AdminUser]
  func createAdminUser(
    server: ImmichServer,
    session: UserSession,
    name: String,
    email: String,
    password: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    quotaSizeInBytes: Int?,
    storageLabel: String?,
    notify: Bool
  ) async throws -> AdminUser
  func deleteAdminUser(server: ImmichServer, session: UserSession, id: String, force: Bool) async throws -> AdminUser
  func restoreAdminUser(server: ImmichServer, session: UserSession, id: String) async throws -> AdminUser
  func startOAuth(server: ImmichServer, redirectUri: String) async throws -> String
  func finishOAuth(server: ImmichServer, oauthCallbackUrl: String) async throws -> UserSession
}
public extension ImmichAPIClient {
  func searchAssets(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters) async throws -> SearchResult {
    try await searchAssets(server: server, session: session, query: query, filters: filters, page: nil)
  }

  func searchMetadataText(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters) async throws -> SearchResult {
    try await searchMetadataText(server: server, session: session, query: query, filters: filters, page: nil)
  }

  func searchMetadataDescription(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters) async throws -> SearchResult {
    try await searchMetadataDescription(server: server, session: session, query: query, filters: filters, page: nil)
  }

  func searchMetadataOCR(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters) async throws -> SearchResult {
    try await searchMetadataOCR(server: server, session: session, query: query, filters: filters, page: nil)
  }
}

public enum ImmichAPIError: Error, LocalizedError, Sendable {
  case invalidResponse(url: String)
  case requestFailed(statusCode: Int, message: String?)
  case decodingFailed(url: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let url):
      return "The server response from \(url) was invalid."
    case .decodingFailed(let url, let detail):
      return "Failed to decode response from \(url): \(detail)"
    case .requestFailed(_, let message) where message?.isEmpty == false:
      return message
    case .requestFailed(statusCode: 401, message: _), .requestFailed(statusCode: 403, message: _):
      return "The server rejected the request."
    case .requestFailed(let statusCode, _):
      return "The server returned an unexpected status code (\(statusCode))."
    }
  }
}

public struct URLSessionImmichAPIClient: ImmichAPIClient {
  private let urlSession: URLSession

  public init(session: URLSession? = nil) {
    if let session {
      self.urlSession = session
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.urlSession = URLSession(configuration: config)
    }
  }

  public func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo {
    if let apiKey, apiKey.isEmpty == false {
      return try await fetchAboutInfo(server: server, apiKey: apiKey)
    }

    return try await fetchVersion(server: server)
  }

  public func fetchVersionCheckState(server: ImmichServer, session: UserSession) async throws -> VersionCheckState {
    var request = authorizedRequest(url: server.baseURL.appending(path: "server/version-check"), session: session)
    request.httpMethod = "GET"
    return try await perform(request)
  }

  public func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration {
    let response: PublicConfigResponse = try await perform(URLRequest(url: server.baseURL.appending(path: "public/config")))
    return ServerLoginConfiguration(
      loginPageMessage: response.server.loginPageMessage ?? "",
      oauthButtonText: response.oauth.buttonText ?? "",
      passwordLoginEnabled: response.passwordLogin.enabled,
      oauthEnabled: response.oauth.enabled
    )
  }

  public func login(server: ImmichServer, email: String, password: String) async throws -> UserSession {
    var request = URLRequest(url: server.baseURL.appending(path: "auth/login"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(LoginRequest(email: email, password: password))

    let response: LoginResponse = try await perform(request)
    return UserSession(
      accessToken: response.accessToken,
      isAdmin: response.isAdmin,
      shouldChangePassword: response.shouldChangePassword,
      userEmail: response.userEmail,
      userID: response.userID,
      userName: response.name
    )
  }

  public func loginWithAPIKey(server: ImmichServer, apiKey: String) async throws -> UserSession {
    let auth = SessionAuthentication.apiKey(apiKey)
    let apiKeyRecord = try await fetchCurrentAPIKey(server: server, apiKey: apiKey)
    let currentUser = try? await fetchCurrentUser(server: server, authentication: auth)
    let isAdmin = (try? await determineAdminAccess(server: server, authentication: auth)) ?? false

    return UserSession(
      apiKey: apiKey,
      isAdmin: isAdmin,
      shouldChangePassword: false,
      userEmail: currentUser?.email ?? "API key session",
      userID: currentUser?.id ?? "api-key-\(apiKeyRecord.id)",
      userName: currentUser?.name ?? apiKeyRecord.name
    )
  }

  public func resumeSession(server: ImmichServer, accessToken: String) async throws -> UserSession {
    let auth = SessionAuthentication.accessToken(accessToken)
    let currentUser = try await fetchCurrentUser(server: server, authentication: auth)
    let isAdmin = (try? await determineAdminAccess(server: server, authentication: auth)) ?? false

    return UserSession(
      accessToken: accessToken,
      isAdmin: isAdmin,
      shouldChangePassword: false,
      userEmail: currentUser.email,
      userID: currentUser.id,
      userName: currentUser.name
    )
  }

  public func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary] {
    var components = URLComponents(url: server.baseURL.appending(path: "timeline/buckets"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "order", value: "desc"),
      URLQueryItem(name: "visibility", value: "timeline"),
      URLQueryItem(name: "withStacked", value: "true"),
    ]

    var request = authorizedRequest(url: components?.url ?? server.baseURL.appending(path: "timeline/buckets"), session: session)
    request.httpMethod = "GET"
    return try await perform(request)
  }

  public func fetchTimelineBucket(
    server: ImmichServer,
    session: UserSession,
    timeBucket: String
  ) async throws -> [RemoteTimelineAsset] {
    var components = URLComponents(url: server.baseURL.appending(path: "timeline/bucket"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "order", value: "desc"),
      URLQueryItem(name: "timeBucket", value: normalizedTimelineBucketValue(timeBucket)),
      URLQueryItem(name: "visibility", value: "timeline"),
      URLQueryItem(name: "withStacked", value: "true"),
    ]

    var request = authorizedRequest(url: components?.url ?? server.baseURL.appending(path: "timeline/bucket"), session: session)
    request.httpMethod = "GET"

    let response: TimelineBucketResponse = try await perform(request)
    return TimelineBucketMapper.assets(from: response)
  }

  // MARK: - Albums

  public func fetchAlbums(server: ImmichServer, session: UserSession) async throws -> [Album] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "albums"), session: session)
    let responses: [AlbumResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  public func fetchAlbumAssets(server: ImmichServer, session: UserSession, albumId: String) async throws -> (Album, [RemoteTimelineAsset]) {
    let request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId),
      session: session
    )
    let album: AlbumResponse = try await perform(request)
    let assets = try await fetchMetadataAssets(
      server: server,
      session: session,
      request: MetadataSearchRequest(filters: SearchFilters(), albumIds: [albumId])
    )
    return (album.toModel(), assets)
  }

  public func fetchPeople(server: ImmichServer, session: UserSession) async throws -> [Person] {
    let pageSize = 1000
    var page = 1
    var people: [Person] = []

    while true {
      var components = URLComponents(url: server.baseURL.appending(path: "people"), resolvingAgainstBaseURL: false)
      components?.queryItems = [
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "size", value: String(pageSize)),
        URLQueryItem(name: "withHidden", value: "true"),
      ]
      let url = components?.url ?? server.baseURL.appending(path: "people")
      var request = authorizedRequest(url: url, session: session)
      request.httpMethod = "GET"
      let response: PeopleResponse = try await perform(request)
      people.append(contentsOf: response.people.map { $0.toModel() })

      guard response.hasNextPage ?? (people.count < response.total) else {
        break
      }
      page += 1
    }

    return people
  }


  // MARK: - Asset Detail

  public func fetchAssetDetail(server: ImmichServer, session: UserSession, assetId: String) async throws -> AssetDetail {
    let request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    let response: AssetDetailResponse = try await perform(request)
    return response.toModel()
  }

  // MARK: - Asset Statistics

  public func fetchAssetStatistics(server: ImmichServer, session: UserSession) async throws -> AssetStatistics {
    let request = authorizedRequest(url: server.baseURL.appending(path: "assets/statistics"), session: session)
    let response: AssetStatisticsResponse = try await perform(request)
    return AssetStatistics(total: response.total, images: response.images, videos: response.videos)
  }

  // MARK: - Asset Updates

  public func setFavorite(server: ImmichServer, session: UserSession, assetId: String, isFavorite: Bool) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    request.httpMethod = "PATCH"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["isFavorite": isFavorite])
    let _: AssetDetailResponse = try await perform(request)
  }

  public func updateAssetLocation(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    latitude: Double,
    longitude: Double
  ) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    request.httpMethod = "PATCH"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["latitude": latitude, "longitude": longitude])
    let _: AssetDetailResponse = try await perform(request)
  }

  /// Bulk location assignment, matching Photos' "Assign Location to N Items". Immich v3 `PUT /assets`.
  public func updateAssetsLocation(
    server: ImmichServer,
    session: UserSession,
    assetIds: [String],
    latitude: Double,
    longitude: Double
  ) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "assets"), session: session)
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BulkLocationUpdateRequest(ids: assetIds, latitude: latitude, longitude: longitude))
    try await performWithoutResponse(request, errorMessage: "Failed to assign location")
  }

  public func updateAssets(server: ImmichServer, session: UserSession, assetIds: [String], update: AssetBulkUpdate) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "assets"), session: session)
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(AssetBulkUpdateRequest(ids: assetIds, update: update))
    try await performWithoutResponse(request, errorMessage: "Failed to update assets")
  }

  // MARK: - Non-destructive edits (crop / rotate / mirror)

  public func fetchAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws -> [AssetEditAction] {
    let request = authorizedRequest(url: editsURL(server: server, assetId: assetId), session: session)
    let response: AssetEditsResponse = try await perform(request)
    return response.edits.compactMap(\.model)
  }

  /// Replaces every edit on the asset. An empty list removes them (Revert to Original).
  public func replaceAssetEdits(server: ImmichServer, session: UserSession, assetId: String, edits: [AssetEditAction]) async throws {
    guard !edits.isEmpty else {
      try await deleteAssetEdits(server: server, session: session, assetId: assetId)
      return
    }
    var request = authorizedRequest(url: editsURL(server: server, assetId: assetId), session: session)
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(AssetEditsRequest(edits: edits.map(AssetEditItem.init)))
    try await performWithoutResponse(request, errorMessage: "Failed to save edits")
  }

  public func deleteAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws {
    var request = authorizedRequest(url: editsURL(server: server, assetId: assetId), session: session)
    request.httpMethod = "DELETE"
    try await performWithoutResponse(request, errorMessage: "Failed to revert edits")
  }

  private func editsURL(server: ImmichServer, assetId: String) -> URL {
    server.baseURL.appending(path: "assets").appending(path: assetId).appending(path: "edits")
  }

  public func fetchHiddenAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] {
    try await fetchMetadataAssets(
      server: server,
      session: session,
      request: MetadataSearchRequest(visibility: "hidden")
    )
  }

  public func fetchDuplicates(server: ImmichServer, session: UserSession) async throws -> [DuplicateGroup] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "duplicates"), session: session)
    let responses: [DuplicateGroupResponse] = try await perform(request)
    return responses.map {
      DuplicateGroup(
        id: $0.duplicateId,
        assets: $0.assets.compactMap { $0.toTimelineAsset() },
        suggestedKeepAssetIDs: $0.suggestedKeepAssetIds
      )
    }
  }

  public func resolveDuplicates(server: ImmichServer, session: UserSession, groups: [DuplicateGroup]) async throws {
    guard !groups.isEmpty else { return }
    var request = authorizedRequest(url: server.baseURL.appending(path: "duplicates/resolve"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(DuplicateResolveRequest(groups: groups.map {
      DuplicateResolveGroupRequest(duplicateId: $0.id, keepAssetIds: $0.keepAssetIDs, trashAssetIds: $0.suggestedTrashAssetIDs)
    }))
    try await performWithoutResponse(request, errorMessage: "Failed to merge duplicates")
  }

  public func updateAssetDescription(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    description: String
  ) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    request.httpMethod = "PATCH"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["description": description])
    let _: AssetDetailResponse = try await perform(request)
  }

  public func updateAssetDateTime(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    date: Date
  ) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    request.httpMethod = "PATCH"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "dateTimeOriginal": ISO8601FractionalSecondsFormatter.string(from: date)
    ])
    let _: AssetDetailResponse = try await perform(request)
  }

  // MARK: - Trash

  public func trashAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "assets"), session: session)
    request.httpMethod = "DELETE"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TrashRequest(ids: assetIds))
    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to trash assets")
    }
  }

  public func fetchTrashedAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] {
    try await fetchMetadataAssets(
      server: server,
      session: session,
      request: MetadataSearchRequest(filters: SearchFilters(), trashedOnly: true)
    )
  }

  public func restoreAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "trash/restore/assets"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TrashRequest(ids: assetIds))
    let (_, restoreResponse) = try await urlSession.data(for: request)
    guard let httpResponse = restoreResponse as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (restoreResponse as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to restore assets")
    }
  }

  public func emptyTrash(server: ImmichServer, session: UserSession) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "trash/empty"), session: session)
    request.httpMethod = "POST"
    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to empty trash")
    }
  }

  // MARK: - Search

  public func searchAssets(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    let response = try await performSmartSearch(
      server: server,
      session: session,
      request: SmartSearchRequest(query: query, filters: filters, page: page)
    )
    return Self.searchResult(from: response, nextPage: response.assets.nextPage)
  }

  public func searchMetadataText(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    let response = try await performMetadataSearch(
      server: server,
      session: session,
      request: MetadataSearchRequest(
        originalFileName: Self.nonEmptySearchText(query),
        filters: filters,
        cursor: page
      )
    )
    return Self.searchResult(from: response, nextPage: response.assets.nextCursor)
  }

  public func searchMetadataDescription(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    let response = try await performMetadataSearch(
      server: server,
      session: session,
      request: MetadataSearchRequest(
        description: Self.nonEmptySearchText(query),
        filters: filters,
        cursor: page
      )
    )
    return Self.searchResult(from: response, nextPage: response.assets.nextCursor)
  }

  public func searchMetadataOCR(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    let response = try await performMetadataSearch(
      server: server,
      session: session,
      request: MetadataSearchRequest(
        ocr: Self.nonEmptySearchText(query),
        filters: filters,
        cursor: page
      )
    )
    return Self.searchResult(from: response, nextPage: response.assets.nextCursor)
  }

  private func performSmartSearch(server: ImmichServer, session: UserSession, request searchRequest: SmartSearchRequest) async throws -> SearchAssetsResponse {
    var request = authorizedRequest(url: server.baseURL.appending(path: "search/smart"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(searchRequest)
    return try await perform(request)
  }

  private func performMetadataSearch(server: ImmichServer, session: UserSession, request searchRequest: MetadataSearchRequest) async throws -> SearchAssetsResponse {
    var request = authorizedRequest(url: server.baseURL.appending(path: "search/metadata"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(searchRequest)
    return try await perform(request)
  }

  private static func searchResult(from response: SearchAssetsResponse, nextPage: String?) -> SearchResult {
    let assets = response.assets.items.compactMap { $0.toTimelineAsset() }
    let totalCount = response.assets.total ?? response.assets.count ?? assets.count
    return SearchResult(assets: assets, totalCount: totalCount, nextPage: nextPage)
  }

  private static func nonEmptySearchText(_ query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public func fetchSearchSuggestions(server: ImmichServer, session: UserSession, type: String, filters: [String: String]) async throws -> [String] {
    var components = URLComponents(url: server.baseURL.appending(path: "search/suggestions"), resolvingAgainstBaseURL: false)
    var queryItems = [URLQueryItem(name: "type", value: type)]
    for (key, value) in filters {
      queryItems.append(URLQueryItem(name: key, value: value))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else { throw ImmichAPIError.invalidResponse(url: "search/suggestions") }
    var request = authorizedRequest(url: url, session: session)
    request.httpMethod = "GET"
    let response: [String?] = try await perform(request)
    return response.compactMap { $0 }
  }

  public func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset] {
    try await fetchMetadataAssets(
      server: server,
      session: session,
      request: MetadataSearchRequest(filters: SearchFilters(), personIds: [personId])
    )
  }

  public func fetchScreenshots(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] {
    var filters = SearchFilters()
    filters.mediaType = .image
    let directRequests = [
      MetadataSearchRequest(originalPath: "screenshots", filters: filters),
      MetadataSearchRequest(originalFileName: "screenshot", filters: filters),
      MetadataSearchRequest(originalFileName: "screen shot", filters: filters),
      MetadataSearchRequest(originalFileName: "screen_shot", filters: filters),
      MetadataSearchRequest(originalFileName: "screen-shot", filters: filters),
    ]
    let appleMobileCandidateRequest = MetadataSearchRequest(
      originalFileName: ".png",
      filters: filters,
      withExif: true
    )

    async let directMatchesTask = fetchMetadataAssets(
      server: server,
      session: session,
      requests: directRequests
    )
    async let appleMobileCandidatesTask = fetchMetadataItems(
      server: server,
      session: session,
      request: appleMobileCandidateRequest
    )

    let directMatches = try await directMatchesTask
    let appleMobileCandidates = try await appleMobileCandidatesTask
    let inferredMatches = appleMobileCandidates
      .filter(Self.isLikelyAppleMobileScreenshot)
      .compactMap { $0.toTimelineAsset() }

    let combined = directMatches + inferredMatches
    let deduped = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
    return deduped.values.sorted { $0.createdAt > $1.createdAt }
  }

  // MARK: - Map

  public func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "map/markers"), session: session)
    let responses: [MapMarkerResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  public func fetchAlbumMapMarkers(server: ImmichServer, session: UserSession, albumId: String) async throws -> [MapMarker] {
    let request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId).appending(path: "map-markers"),
      session: session
    )
    let responses: [MapMarkerResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  public func reverseGeocode(server: ImmichServer, session: UserSession, latitude: Double, longitude: Double) async throws -> [ReverseGeocodePlace] {
    var components = URLComponents(url: server.baseURL.appending(path: "map/reverse-geocode"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "lat", value: String(latitude)),
      URLQueryItem(name: "lon", value: String(longitude)),
    ]
    guard let url = components?.url else { throw ImmichAPIError.invalidResponse(url: "map/reverse-geocode") }
    let responses: [ReverseGeocodeResponse] = try await perform(authorizedRequest(url: url, session: session))
    return responses.map { ReverseGeocodePlace(city: $0.city, state: $0.state, country: $0.country) }
  }

  // MARK: - Memories

  public func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "memories"), session: session)
    let responses: [MemoryResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  // MARK: - Download Original Asset

  public func downloadOriginalAsset(server: ImmichServer, session: UserSession, assetId: String) async throws -> (Data, String) {
    let request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId).appending(path: "original"),
      session: session
    )
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to download asset")
    }
    // Extract filename from Content-Disposition header or use assetId
    let filename: String
    if let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") {
      if let name = Self.parseFilename(from: disposition) {
        filename = name
      } else {
        filename = "\(assetId).jpg"
      }
    } else if let suggestedName = response.suggestedFilename, suggestedName != assetId {
      filename = suggestedName
    } else {
      let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
      let ext = contentType.contains("video") ? "mp4" : (contentType.contains("png") ? "png" : "jpg")
      filename = "\(assetId).\(ext)"
    }
    return (data, filename)
  }

  /// Parse filename from Content-Disposition header, handling both
  /// `filename="..."` and `filename*=UTF-8''...` forms.
  private static func parseFilename(from disposition: String) -> String? {
    // Prefer filename*= (RFC 5987) which carries the real UTF-8 name
    if let starRange = disposition.range(of: "filename\\*=(?:UTF-8|utf-8)''", options: .regularExpression) {
      let afterStar = disposition[starRange.upperBound...]
      let end = afterStar.firstIndex(where: { $0 == ";" || $0 == " " }) ?? afterStar.endIndex
      let encoded = String(afterStar[..<end])
      if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
        return decoded
      }
    }
    // Fall back to filename="..."
    if let range = disposition.range(of: "filename=\""),
       let end = disposition[range.upperBound...].firstIndex(of: "\"") {
      let name = String(disposition[range.upperBound..<end])
      if !name.isEmpty { return name }
    }
    // Fall back to filename=... (unquoted)
    if let range = disposition.range(of: "filename=") {
      let after = disposition[range.upperBound...].trimmingCharacters(in: .whitespaces)
      let end = after.firstIndex(where: { $0 == ";" || $0 == " " }) ?? after.endIndex
      let name = String(after[..<end])
      if !name.isEmpty && name != "\"" { return name }
    }
    return nil
  }

  // MARK: - Upload Asset

  public func uploadAsset(server: ImmichServer, session: UserSession, fileURL: URL, fileCreatedAt: Date? = nil, durationMilliseconds: Int?, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
    let boundary = UUID().uuidString
    let filename = fileURL.lastPathComponent
    let mimeType = fileURL.mimeType

    // Preserve the file timestamps expected by Immich's asset-upload API.
    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let createdDate = fileCreatedAt ?? (attrs?[.creationDate] as? Date) ?? Date()
    let modifiedDate = (attrs?[.modificationDate] as? Date) ?? createdDate
    var fields = [
      MultipartFormField(name: "fileCreatedAt", value: iso8601FractionalSecondsString(for: createdDate)),
      MultipartFormField(name: "fileModifiedAt", value: iso8601FractionalSecondsString(for: modifiedDate)),
      MultipartFormField(name: "isFavorite", value: "false"),
    ]
    if let durationMilliseconds {
      fields.append(MultipartFormField(name: "duration", value: String(durationMilliseconds)))
    }
    let multipartBody = try buildMultipartBodyFile(
      boundary: boundary,
      fields: fields,
      fileFieldName: "assetData",
      fileURL: fileURL,
      filename: filename,
      mimeType: mimeType
    )
    defer { try? FileManager.default.removeItem(at: multipartBody.url) }

    var request = authorizedRequest(url: server.baseURL.appending(path: "assets"), session: session)
    request.httpMethod = "POST"
    request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.addValue(String(multipartBody.contentLength), forHTTPHeaderField: "Content-Length")

    onProgress(0)
    let progressDelegate = UploadProgressDelegate(onProgress: onProgress)
    let (data, response) = try await urlSession.upload(for: request, fromFile: multipartBody.url, delegate: progressDelegate)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ImmichAPIError.invalidResponse(url: request.url?.absoluteString ?? "unknown")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw apiError(from: data, statusCode: httpResponse.statusCode)
    }

    do {
      let json = try JSONDecoder().decode(UploadResponse.self, from: data)
      guard !json.id.isEmpty else {
        throw ImmichAPIError.requestFailed(statusCode: httpResponse.statusCode, message: "Invalid upload response")
      }
      onProgress(1)
      return json.id
    } catch let error as ImmichAPIError {
      throw error
    } catch {
      throw ImmichAPIError.requestFailed(statusCode: httpResponse.statusCode, message: "Invalid upload response")
    }
  }

  // MARK: - Album CRUD

  public func createAlbum(server: ImmichServer, session: UserSession, name: String, description: String, assetIds: [String]) async throws -> Album {
    var request = authorizedRequest(url: server.baseURL.appending(path: "albums"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(CreateAlbumRequest(albumName: name, description: description, assetIds: assetIds))
    let response: AlbumResponse = try await perform(request)
    return response.toModel()
  }

  public func renameAlbum(server: ImmichServer, session: UserSession, albumId: String, newName: String) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId),
      session: session
    )
    request.httpMethod = "PATCH"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["albumName": newName])
    let _: AlbumResponse = try await perform(request)
  }

  public func deleteAlbum(server: ImmichServer, session: UserSession, albumId: String) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId),
      session: session
    )
    request.httpMethod = "DELETE"
    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to delete album")
    }
  }

  public func addAssetsToAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId).appending(path: "assets"),
      session: session
    )
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BulkIdsRequest(ids: assetIds))
    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to add assets to album")
    }
  }

  public func removeAssetsFromAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "albums").appending(path: albumId).appending(path: "assets"),
      session: session
    )
    request.httpMethod = "DELETE"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BulkIdsRequest(ids: assetIds))
    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Failed to remove assets from album")
    }
  }

  // MARK: - OAuth

  public func startOAuth(server: ImmichServer, redirectUri: String) async throws -> String {
    var request = URLRequest(url: server.baseURL.appending(path: "oauth/authorize"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["redirectUri": redirectUri])
    let response: OAuthAuthorizeResponse = try await perform(request)
    return response.url
  }

  public func finishOAuth(server: ImmichServer, oauthCallbackUrl: String) async throws -> UserSession {
    var request = URLRequest(url: server.baseURL.appending(path: "oauth/callback"))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["url": oauthCallbackUrl])
    let response: LoginResponse = try await perform(request)
    return UserSession(
      accessToken: response.accessToken,
      isAdmin: response.isAdmin,
      shouldChangePassword: response.shouldChangePassword,
      userEmail: response.userEmail,
      userID: response.userID,
      userName: response.name
    )
  }


  // MARK: - API Keys

  public func fetchAPIKeys(server: ImmichServer, session: UserSession) async throws -> [ImmichAPIKey] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "api-keys"), session: session)
    let response: [APIKeyResponse] = try await perform(request)
    return response.map { $0.toModel() }
  }

  public func createAPIKey(
    server: ImmichServer,
    session: UserSession,
    name: String,
    permissions: [String]
  ) async throws -> CreatedAPIKey {
    var request = authorizedRequest(url: server.baseURL.appending(path: "api-keys"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(APIKeyCreateRequest(name: name, permissions: permissions))
    let response: APIKeyCreateResponse = try await perform(request)
    return response.toModel()
  }

  public func deleteAPIKey(server: ImmichServer, session: UserSession, id: String) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "api-keys").appending(path: id),
      session: session
    )
    request.httpMethod = "DELETE"
    try await performWithoutResponse(request, errorMessage: "Failed to delete API key")
  }

  // MARK: - Tags

  public func fetchTags(server: ImmichServer, session: UserSession) async throws -> [ImmichTag] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "tags"), session: session)
    let response: [TagResponse] = try await perform(request)
    return response.map { $0.toModel() }.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
  }

  public func upsertTags(server: ImmichServer, session: UserSession, tagNames: [String]) async throws -> [ImmichTag] {
    var request = authorizedRequest(url: server.baseURL.appending(path: "tags"), session: session)
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TagUpsertRequest(tags: tagNames))
    let response: [TagResponse] = try await perform(request)
    return response.map { $0.toModel() }
  }

  public func tagAssets(server: ImmichServer, session: UserSession, assetIDs: [String], tagIDs: [String]) async throws {
    var request = authorizedRequest(url: server.baseURL.appending(path: "tags/assets"), session: session)
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TagBulkAssetsRequest(assetIds: assetIDs, tagIds: tagIDs))
    let _: TagBulkAssetsResponse = try await perform(request)
  }

  public func untagAssets(server: ImmichServer, session: UserSession, tagID: String, assetIDs: [String]) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "tags").appending(path: tagID).appending(path: "assets"),
      session: session
    )
    request.httpMethod = "DELETE"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BulkIdsRequest(ids: assetIDs))
    let _: [BulkIDResponse] = try await perform(request)
  }

  public func deleteTag(server: ImmichServer, session: UserSession, id: String) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "tags").appending(path: id),
      session: session
    )
    request.httpMethod = "DELETE"
    try await performWithoutResponse(request, errorMessage: "Failed to delete tag")
  }

  // MARK: - Admin Users

  public func fetchAdminUsers(server: ImmichServer, session: UserSession, includeDeleted: Bool) async throws -> [AdminUser] {
    var components = URLComponents(url: server.baseURL.appending(path: "admin/users"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "withDeleted", value: includeDeleted ? "true" : "false")]
    let request = authorizedRequest(url: components?.url ?? server.baseURL.appending(path: "admin/users"), session: session)
    let response: [AdminUserResponse] = try await perform(request)
    return response.map { $0.toModel() }
  }

  public func createAdminUser(
    server: ImmichServer,
    session: UserSession,
    name: String,
    email: String,
    password: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    quotaSizeInBytes: Int?,
    storageLabel: String?,
    notify: Bool
  ) async throws -> AdminUser {
    var request = authorizedRequest(url: server.baseURL.appending(path: "admin/users"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      AdminUserCreateRequest(
        email: email,
        isAdmin: isAdmin,
        name: name,
        notify: notify,
        password: password,
        quotaSizeInBytes: quotaSizeInBytes,
        shouldChangePassword: shouldChangePassword,
        storageLabel: storageLabel
      )
    )
    let response: AdminUserResponse = try await perform(request)
    return response.toModel()
  }

  public func deleteAdminUser(server: ImmichServer, session: UserSession, id: String, force: Bool) async throws -> AdminUser {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "admin/users").appending(path: id),
      session: session
    )
    request.httpMethod = "DELETE"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(AdminUserDeleteRequest(force: force))
    let response: AdminUserResponse = try await perform(request)
    return response.toModel()
  }

  public func restoreAdminUser(server: ImmichServer, session: UserSession, id: String) async throws -> AdminUser {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "admin/users").appending(path: id).appending(path: "restore"),
      session: session
    )
    request.httpMethod = "POST"
    let response: AdminUserResponse = try await perform(request)
    return response.toModel()
  }

  private func fetchAboutInfo(server: ImmichServer, apiKey: String) async throws -> ServerInfo {
    var request = URLRequest(url: server.baseURL.appending(path: "server/about"))
    request.httpMethod = "GET"
    request.addValue(apiKey, forHTTPHeaderField: "x-api-key")

    let response: ServerAboutResponse = try await perform(request)
    return ServerInfo(version: response.version, repository: response.repository)
  }

  private func fetchVersion(server: ImmichServer) async throws -> ServerInfo {
    let request = URLRequest(url: server.baseURL.appending(path: "server/version"))
    let response: ServerVersionResponse = try await perform(request)

    return ServerInfo(version: "\(response.major).\(response.minor).\(response.patch)")
  }

  private func authorizedRequest(url: URL, session: UserSession) -> URLRequest {
    var request = URLRequest(url: url)
    request.addValue(session.authHeaderValue, forHTTPHeaderField: session.authHeaderField)
    return request
  }

  private func request(url: URL, authentication: SessionAuthentication) -> URLRequest {
    var request = URLRequest(url: url)
    request.addValue(authentication.headerValue, forHTTPHeaderField: authentication.headerField)
    return request
  }

  private func fetchCurrentAPIKey(server: ImmichServer, apiKey: String) async throws -> ImmichAPIKey {
    var request = URLRequest(url: server.baseURL.appending(path: "api-keys/me"))
    request.httpMethod = "GET"
    request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
    let response: APIKeyResponse = try await perform(request)
    return response.toModel()
  }

  private func fetchCurrentUser(server: ImmichServer, authentication: SessionAuthentication) async throws -> CurrentUserResponse {
    let request = request(url: server.baseURL.appending(path: "users/me"), authentication: authentication)
    return try await perform(request)
  }

  private func determineAdminAccess(server: ImmichServer, authentication: SessionAuthentication) async throws -> Bool {
    var components = URLComponents(url: server.baseURL.appending(path: "admin/users"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "withDeleted", value: "false")]
    let request = request(url: components?.url ?? server.baseURL.appending(path: "admin/users"), authentication: authentication)
    let _: [AdminUserResponse] = try await perform(request)
    return true
  }

  private static func isLikelyAppleMobileScreenshot(_ asset: AssetDetailResponse) -> Bool {
    let originalFileName = asset.originalFileName?.lowercased() ?? ""
    guard originalFileName.hasPrefix("img_"), originalFileName.hasSuffix(".png") else {
      return false
    }

    guard let width = asset.exifInfo?.exifImageWidth, let height = asset.exifInfo?.exifImageHeight else {
      return true
    }

    let shortEdge = Double(min(width, height))
    let longEdge = Double(max(width, height))
    guard shortEdge >= 640, longEdge >= 960 else {
      return false
    }

    let ratio = shortEdge / longEdge
    let supportedRatios = [0.462, 0.562, 0.657, 0.699, 0.750]
    return supportedRatios.contains { abs($0 - ratio) <= 0.02 }
  }

  private func fetchMetadataItems(
    server: ImmichServer,
    session: UserSession,
    request metadataRequest: MetadataSearchRequest
  ) async throws -> [AssetDetailResponse] {
    var items: [AssetDetailResponse] = []
    var cursor = metadataRequest.cursor

    while true {
      var pagedRequest = metadataRequest
      pagedRequest.cursor = cursor

      let response = try await performMetadataSearch(
        server: server,
        session: session,
        request: pagedRequest
      )
      items.append(contentsOf: response.assets.items)

      guard
        let nextCursor = response.assets.nextCursor,
        !nextCursor.isEmpty,
        nextCursor != cursor
      else {
        break
      }
      cursor = nextCursor
    }

    return items
  }

  private func fetchMetadataAssets(
    server: ImmichServer,
    session: UserSession,
    request metadataRequest: MetadataSearchRequest
  ) async throws -> [RemoteTimelineAsset] {
    let items = try await fetchMetadataItems(server: server, session: session, request: metadataRequest)
    return items.compactMap { $0.toTimelineAsset() }
  }

  private func fetchMetadataAssets(
    server: ImmichServer,
    session: UserSession,
    requests metadataRequests: [MetadataSearchRequest]
  ) async throws -> [RemoteTimelineAsset] {
    try await withThrowingTaskGroup(of: [RemoteTimelineAsset].self) { group in
      for metadataRequest in metadataRequests {
        group.addTask {
          try await self.fetchMetadataAssets(
            server: server,
            session: session,
            request: metadataRequest
          )
        }
      }

      var combined: [RemoteTimelineAsset] = []
      for try await assets in group {
        combined.append(contentsOf: assets)
      }
      return combined
    }
  }


  private func responseShape(_ data: Data) -> String {
    guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
      return "non-JSON (\(data.count) bytes)"
    }

    if let object = value as? [String: Any] {
      let keys = object.keys.sorted()
      let summary = keys.prefix(16).joined(separator: ", ")
      let suffix = keys.count > 16 ? ", …" : ""
      return "JSON object keys [\(summary)\(suffix)]"
    }
    if value is String { return "JSON string" }
    if value is [Any] { return "JSON array" }
    if value is NSNull { return "JSON null" }
    return "JSON scalar"
  }

  private func decodingFailureDetail(
    for error: Error,
    responseData: Data,
    httpResponse: HTTPURLResponse
  ) -> String {
    let envelope = "HTTP \(httpResponse.statusCode), Content-Type \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "missing"), body \(responseShape(responseData))"
    guard let decodingError = error as? DecodingError else {
      return "\(error.localizedDescription); \(envelope)"
    }

    let context: DecodingError.Context
    var pathSuffix: String?
    var expectedType: String?
    switch decodingError {
    case .typeMismatch(let type, let value), .valueNotFound(let type, let value):
      context = value
      expectedType = String(reflecting: type)
    case .dataCorrupted(let value):
      context = value
    case .keyNotFound(let key, let value):
      context = value
      pathSuffix = key.stringValue
    @unknown default:
      return "\(error.localizedDescription); \(envelope)"
    }

    let path = (context.codingPath.map(\.stringValue) + [pathSuffix].compactMap { $0 })
      .joined(separator: ".")
    let location = path.isEmpty ? "response root" : "coding path \(path)"
    let expected = expectedType.map { " (expected \($0))" } ?? ""
    return "\(context.debugDescription) at \(location)\(expected); \(envelope)"
  }


  private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let requestURL = request.url?.absoluteString ?? "unknown"
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ImmichAPIError.invalidResponse(url: requestURL)
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw apiError(from: data, statusCode: httpResponse.statusCode)
    }

    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw ImmichAPIError.decodingFailed(
        url: requestURL,
        detail: decodingFailureDetail(for: error, responseData: data, httpResponse: httpResponse)
      )
    }
  }

  private func performWithoutResponse(_ request: URLRequest, errorMessage: String) async throws {
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      if let httpResponse = response as? HTTPURLResponse {
        throw apiError(from: data, statusCode: httpResponse.statusCode)
      }
      throw ImmichAPIError.requestFailed(statusCode: 0, message: errorMessage)
    }
  }

  private func apiError(from data: Data, statusCode: Int) -> ImmichAPIError {
    if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data), let message = errorResponse.messageText {
      return .requestFailed(statusCode: statusCode, message: message)
    }

    return .requestFailed(statusCode: statusCode, message: nil)
  }
}

private struct ServerAboutResponse: Decodable {
  let version: String
  let repository: String?
}

private struct ServerVersionResponse: Decodable {
  let major: Int
  let minor: Int
  let patch: Int
}

private struct PublicConfigResponse: Decodable {
  let oauth: OAuthConfig
  let passwordLogin: PasswordLoginConfig
  let server: ServerConfig

  struct OAuthConfig: Decodable {
    let enabled: Bool
    let buttonText: String?
  }

  struct PasswordLoginConfig: Decodable {
    let enabled: Bool
  }

  struct ServerConfig: Decodable {
    let loginPageMessage: String?
  }
}

private struct LoginRequest: Encodable {
  let email: String
  let password: String
}

private struct LoginResponse: Decodable {
  let accessToken: String
  let isAdmin: Bool
  let name: String
  let shouldChangePassword: Bool
  let userEmail: String
  let userID: String

  enum CodingKeys: String, CodingKey {
    case accessToken
    case isAdmin
    case name
    case shouldChangePassword
    case userEmail
    case userID = "userId"
  }
}

private struct CurrentUserResponse: Decodable {
  let email: String
  let id: String
  let name: String
}

private struct APIKeyCreateRequest: Encodable {
  let name: String?
  let permissions: [String]
}

private struct APIKeyResponse: Decodable {
  let createdAt: String
  let id: String
  let name: String
  let permissions: [String]
  let updatedAt: String

  func toModel() -> ImmichAPIKey {
    ImmichAPIKey(
      id: id,
      name: name,
      permissions: permissions,
      createdAt: TimelineBucketMapper.parseDate(createdAt) ?? .distantPast,
      updatedAt: TimelineBucketMapper.parseDate(updatedAt) ?? .distantPast
    )
  }
}

private struct APIKeyCreateResponse: Decodable {
  let apiKey: APIKeyResponse
  let secret: String

  func toModel() -> CreatedAPIKey {
    CreatedAPIKey(apiKey: apiKey.toModel(), secret: secret)
  }
}

private struct TagResponse: Decodable {
  let color: String?
  let createdAt: String
  let id: String
  let name: String
  let parentId: String?
  let updatedAt: String
  let value: String

  func toModel() -> ImmichTag {
    ImmichTag(
      id: id,
      name: name,
      value: value,
      color: color,
      parentID: parentId,
      createdAt: TimelineBucketMapper.parseDate(createdAt) ?? .distantPast,
      updatedAt: TimelineBucketMapper.parseDate(updatedAt) ?? .distantPast
    )
  }
}

private struct TagUpsertRequest: Encodable {
  let tags: [String]
}

private struct TagBulkAssetsRequest: Encodable {
  let assetIds: [String]
  let tagIds: [String]
}

private struct TagBulkAssetsResponse: Decodable {
  let count: Int?
}

private struct BulkIDResponse: Decodable {
  let id: String?
  let success: Bool?
}

private struct AdminUserCreateRequest: Encodable {
  let email: String
  let isAdmin: Bool
  let name: String
  let notify: Bool
  let password: String
  let quotaSizeInBytes: Int?
  let shouldChangePassword: Bool
  let storageLabel: String?
}

private struct AdminUserDeleteRequest: Encodable {
  let force: Bool
}

private struct AdminUserResponse: Decodable {
  let avatarColor: String
  let createdAt: String
  let deletedAt: String?
  let email: String
  let id: String
  let isAdmin: Bool
  let name: String
  let oauthId: String
  let profileChangedAt: String
  let profileImagePath: String
  let quotaSizeInBytes: Int?
  let quotaUsageInBytes: Int?
  let shouldChangePassword: Bool
  let status: String
  let storageLabel: String?
  let updatedAt: String

  func toModel() -> AdminUser {
    AdminUser(
      id: id,
      name: name,
      email: email,
      avatarColor: avatarColor,
      isAdmin: isAdmin,
      shouldChangePassword: shouldChangePassword,
      status: status,
      createdAt: TimelineBucketMapper.parseDate(createdAt) ?? .distantPast,
      updatedAt: TimelineBucketMapper.parseDate(updatedAt) ?? .distantPast,
      deletedAt: deletedAt.flatMap(TimelineBucketMapper.parseDate),
      oauthID: oauthId,
      profileChangedAt: TimelineBucketMapper.parseDate(profileChangedAt) ?? .distantPast,
      profileImagePath: profileImagePath,
      quotaSizeInBytes: quotaSizeInBytes,
      quotaUsageInBytes: quotaUsageInBytes,
      storageLabel: storageLabel
    )
  }
}

private struct TimelineBucketResponse: Decodable {
  let city: [String?]?
  let country: [String?]?
  let duration: [Int?]?
  let fileCreatedAt: [String]
  let createdAt: [String?]?
  let id: [String]
  let isFavorite: [Bool]
  let isImage: [Bool]
  let isTrashed: [Bool]
  let latitude: [Double?]?
  let livePhotoVideoId: [String?]?
  let longitude: [Double?]?
  let ownerId: [String]
  let projectionType: [String?]?
  let ratio: [Double]
  let stack: [[String]?]?
  let thumbhash: [String?]?
  let visibility: [String]
}

private enum TimelineBucketMapper {
  static func assets(from response: TimelineBucketResponse) -> [RemoteTimelineAsset] {
    response.id.indices.compactMap { index in
      guard
        let id = response.id[safe: index],
        let createdAtString = response.fileCreatedAt[safe: index],
        let createdAt = parseDate(createdAtString),
        let ownerID = response.ownerId[safe: index],
        let isFavorite = response.isFavorite[safe: index],
        let isImage = response.isImage[safe: index],
        let isTrashed = response.isTrashed[safe: index],
        let ratio = response.ratio[safe: index],
        let visibility = response.visibility[safe: index]
      else {
        return nil
      }

      let stack = response.stack?[safe: index] ?? nil
      let stackChildrenCount = stack?.dropFirst().first.flatMap(Int.init)
      let durationMilliseconds = response.duration?[safe: index] ?? nil
      let addedAt = response.createdAt?[safe: index] ?? nil

      return RemoteTimelineAsset(
        id: id,
        city: response.city?[safe: index] ?? nil,
        country: response.country?[safe: index] ?? nil,
        createdAt: createdAt,
        durationMilliseconds: durationMilliseconds,
        isFavorite: isFavorite,
        isImage: isImage,
        isTrashed: isTrashed,
        latitude: response.latitude?[safe: index] ?? nil,
        longitude: response.longitude?[safe: index] ?? nil,
        livePhotoVideoID: response.livePhotoVideoId?[safe: index] ?? nil,
        ownerID: ownerID,
        projectionType: response.projectionType?[safe: index] ?? nil,
        ratio: ratio,
        stackChildrenCount: stackChildrenCount,
        thumbhash: response.thumbhash?[safe: index] ?? nil,
        visibility: visibility,
        addedAt: addedAt.flatMap(parseDate)
      )
    }
  }

  private static let dateFormats = [
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    "yyyy-MM-dd'T'HH:mm:ssZ",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd"
  ]
  private nonisolated(unsafe) static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private nonisolated(unsafe) static let iso8601WithoutFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
  private static let fallbackFormatterLock = NSLock()
  private static let fallbackDateFormatters: [DateFormatter] = dateFormats.map { format in
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
  }

  static func parseDate(_ value: String) -> Date? {
    if let date = iso8601WithFractionalSeconds.date(from: value) { return date }
    if let date = iso8601WithoutFractionalSeconds.date(from: value) { return date }

    fallbackFormatterLock.lock()
    defer { fallbackFormatterLock.unlock() }
    for formatter in fallbackDateFormatters {
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }
}

private struct ErrorResponse: Decodable {
  let message: ErrorMessage

  var messageText: String? {
    switch message {
    case .string(let value):
      value
    case .array(let values):
      values.joined(separator: ", ")
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private enum ErrorMessage: Decodable {
  case string(String)
  case array([String])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }

    self = .array(try container.decode([String].self))
  }
}

// MARK: - Album Response DTOs

private struct AlbumResponse: Decodable {
  let id: String
  let albumName: String
  let description: String?
  let assetCount: Int?
  let albumThumbnailAssetId: String?
  let createdAt: String?
  let updatedAt: String?
  let isActivityEnabled: Bool?
  let shared: Bool?
  let ownerId: String?
  let albumUsers: [AlbumUserResponse]?

  func toModel() -> Album {
    Album(
      id: id,
      albumName: albumName,
      description: description ?? "",
      assetCount: assetCount ?? 0,
      albumThumbnailAssetId: albumThumbnailAssetId,
      createdAt: createdAt.flatMap { TimelineBucketMapper.parseDate($0) } ?? Date(),
      updatedAt: updatedAt.flatMap { TimelineBucketMapper.parseDate($0) } ?? Date(),
      isActivityEnabled: isActivityEnabled ?? false,
      shared: shared ?? false,
      ownerID: albumUsers?.first?.user.id ?? ownerId ?? ""
    )
  }
}

private struct AlbumUserResponse: Decodable {
  let user: AlbumUserAccountResponse
}

private struct AlbumUserAccountResponse: Decodable {
  let id: String
}


// MARK: - People Response DTOs

private struct PeopleResponse: Decodable {
  let hidden: Int
  let total: Int
  let people: [PersonResponse]
  let hasNextPage: Bool?
}

private struct PersonResponse: Decodable {
  let id: String
  let name: String
  let birthDate: String?
  let thumbnailPath: String
  let isHidden: Bool
  let updatedAt: String?

  func toModel() -> Person {
    let birthDateParsed: Date? = birthDate.flatMap { TimelineBucketMapper.parseDate($0) }
    return Person(
      id: id,
      name: name,
      birthDate: birthDateParsed,
      thumbnailPath: thumbnailPath,
      isHidden: isHidden,
      assetCount: 0
    )
  }
}

// MARK: - Asset Detail Response

private struct AssetDetailResponse: Decodable {
  let id: String
  let type: String?
  let originalFileName: String?
  let createdAt: String?
  let localDateTime: String?
  let fileCreatedAt: String?
  let width: Int?
  let height: Int?
  let fileSizeInByte: Int?
  let ownerId: String?
  let visibility: String?
  let exifInfo: ExifInfoResponse?
  let isFavorite: Bool?
  let isTrashed: Bool?
  let duration: Int?
  let livePhotoVideoId: String?
  let tags: [TagResponse]?

  struct ExifInfoResponse: Decodable {
    let make: String?
    let model: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Int?
    let exposureTime: String?
    let lensModel: String?
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let description: String?
    let rating: Int?
    let dateTimeOriginal: String?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    let fileSizeInByte: Int?
  }

  func toModel() -> AssetDetail {
    let exifModel: ExifInfo? = exifInfo.map { e in
      ExifInfo(
        make: e.make, model: e.model, fNumber: e.fNumber, focalLength: e.focalLength,
        iso: e.iso, exposureTime: e.exposureTime, lensModel: e.lensModel,
        city: e.city, state: e.state, country: e.country,
        latitude: e.latitude, longitude: e.longitude,
        description: e.description, rating: e.rating,
        dateTimeOriginal: e.dateTimeOriginal.flatMap { TimelineBucketMapper.parseDate($0) }
      )
    }
    return AssetDetail(
      id: id,
      type: type ?? "IMAGE",
      originalFileName: originalFileName ?? "",
      localDateTime: localDateTime.flatMap { TimelineBucketMapper.parseDate($0) },
      fileCreatedAt: fileCreatedAt.flatMap { TimelineBucketMapper.parseDate($0) },
      width: width ?? exifInfo?.exifImageWidth,
      height: height ?? exifInfo?.exifImageHeight,
      fileSizeInByte: fileSizeInByte ?? exifInfo?.fileSizeInByte,
      isFavorite: isFavorite ?? false,
      durationMilliseconds: duration,
      livePhotoVideoId: livePhotoVideoId,
      exif: exifModel,
      tags: (tags ?? []).map { $0.toModel() },
      ownerID: ownerId,
      visibility: visibility
    )
  }

  func toTimelineAsset() -> RemoteTimelineAsset? {
    guard let createdAt = fileCreatedAt.flatMap({ TimelineBucketMapper.parseDate($0) }) else { return nil }
    let width = self.width ?? exifInfo?.exifImageWidth ?? 1
    let height = self.height ?? exifInfo?.exifImageHeight ?? 1

    return RemoteTimelineAsset(
      id: id,
      city: exifInfo?.city,
      country: exifInfo?.country,
      createdAt: createdAt,
      durationMilliseconds: duration,
      isFavorite: isFavorite ?? false,
      isImage: (type ?? "IMAGE") == "IMAGE",
      isTrashed: isTrashed ?? false,
      latitude: exifInfo?.latitude,
      longitude: exifInfo?.longitude,
      livePhotoVideoID: livePhotoVideoId,
      ownerID: ownerId ?? "",
      projectionType: nil,
      ratio: Double(width) / Double(height),
      stackChildrenCount: nil,
      thumbhash: nil,
      visibility: visibility ?? "timeline",
      addedAt: self.createdAt.flatMap { TimelineBucketMapper.parseDate($0) }
    )
  }
}

// MARK: - Asset Statistics Response

private struct AssetStatisticsResponse: Decodable {
  let total: Int
  let images: Int
  let videos: Int
}

// MARK: - Search DTOs

private struct SmartSearchRequest: Encodable {
  let query: String?
  let filter: SearchFilterRequest?
  let size: Int
  let page: Int?

  init(query: String, filters: SearchFilters, page: String?) {
    self.query = query.isEmpty ? nil : query
    let searchFilter = SearchFilterRequest(filters: filters)
    self.filter = searchFilter.isEmpty ? nil : searchFilter
    self.size = 1000
    self.page = page.flatMap(Int.init)
  }
}

private struct MetadataSearchRequest: Encodable {
  let filter: SearchFilterRequest?
  let originalFileName: String?
  let originalPath: String?
  let description: String?
  let ocr: String?
  var cursor: String?
  let size: Int
  let withExif: Bool?
  let withStacked: Bool?

  init(
    originalFileName: String? = nil,
    originalPath: String? = nil,
    description: String? = nil,
    ocr: String? = nil,
    filters: SearchFilters = SearchFilters(),
    withExif: Bool? = nil,
    cursor: String? = nil,
    albumIds: [String]? = nil,
    personIds: [String]? = nil,
    trashedOnly: Bool = false,
    visibility: String? = nil
  ) {
    let searchFilter = SearchFilterRequest(
      filters: filters,
      personIds: personIds,
      albumIds: albumIds,
      trashedOnly: trashedOnly,
      visibility: visibility
    )
    self.filter = searchFilter.isEmpty ? nil : searchFilter
    self.originalFileName = originalFileName
    self.originalPath = originalPath
    self.description = description
    self.ocr = ocr
    self.cursor = cursor
    self.size = 1000
    self.withExif = withExif
    self.withStacked = true
  }
}

private struct SearchFilterRequest: Encodable {
  let takenAt: DateFilterRequest?
  let make: StringFilterRequest?
  let model: StringFilterRequest?
  let city: StringFilterRequest?
  let country: StringFilterRequest?
  let type: EnumFilterRequest?
  let isFavorite: BoolFilterRequest?
  let personIds: IdsFilterRequest?
  let albumIds: IdsFilterRequest?
  let trashedAt: NullableDateFilterRequest?
  let visibility: EnumFilterRequest?

  init(
    filters: SearchFilters,
    personIds: [String]? = nil,
    albumIds: [String]? = nil,
    trashedOnly: Bool = false,
    visibility: String? = nil
  ) {
    self.visibility = visibility.map(EnumFilterRequest.init(eq:))
    let gte = filters.takenAfter.map { iso8601FractionalSecondsString(for: $0) }
    let lte = filters.takenBefore.map { iso8601FractionalSecondsString(for: $0) }
    self.takenAt = gte == nil && lte == nil ? nil : DateFilterRequest(gte: gte, lte: lte)
    self.make = filters.cameraMake.map(StringFilterRequest.init(eq:))
    self.model = filters.cameraModel.map(StringFilterRequest.init(eq:))
    self.city = filters.city.map(StringFilterRequest.init(eq:))
    self.country = filters.country.map(StringFilterRequest.init(eq:))
    switch filters.mediaType {
    case .some(.image):
      self.type = EnumFilterRequest(eq: "IMAGE")
    case .some(.video):
      self.type = EnumFilterRequest(eq: "VIDEO")
    case .some(.all), nil:
      self.type = nil
    }
    self.isFavorite = filters.isFavorite.map(BoolFilterRequest.init(eq:))
    self.personIds = personIds.flatMap { $0.isEmpty ? nil : IdsFilterRequest(any: $0) }
    self.albumIds = albumIds.flatMap { $0.isEmpty ? nil : IdsFilterRequest(any: $0) }
    self.trashedAt = trashedOnly ? NullableDateFilterRequest(ne: JSONNull()) : nil
  }

  var isEmpty: Bool {
    takenAt == nil && make == nil && model == nil && city == nil && country == nil
      && type == nil && isFavorite == nil && personIds == nil && albumIds == nil && trashedAt == nil
      && visibility == nil
  }
}

private struct DateFilterRequest: Encodable {
  let gte: String?
  let lte: String?
}

private struct StringFilterRequest: Encodable {
  let eq: String
}

private struct EnumFilterRequest: Encodable {
  let eq: String
}

private struct BoolFilterRequest: Encodable {
  let eq: Bool
}

private struct IdsFilterRequest: Encodable {
  let any: [String]
}

private struct NullableDateFilterRequest: Encodable {
  let ne: JSONNull
}

private struct JSONNull: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encodeNil()
  }
}

private struct SearchAssetsResponse: Decodable {
  let assets: SearchAssetsPage

  struct SearchAssetsPage: Decodable {
    let items: [AssetDetailResponse]
    let count: Int?
    let total: Int?
    let nextCursor: String?
    let nextPage: String?
  }
}

private struct TrashRequest: Encodable {
  let ids: [String]
}

// MARK: - Map DTOs

private struct MapMarkerResponse: Decodable {
  let id: String
  let lat: Double
  let lon: Double
  let city: String?
  let state: String?
  let country: String?

  func toModel() -> MapMarker {
    MapMarker(id: id, latitude: lat, longitude: lon, city: city, country: country, state: state)
  }
}

private struct AssetBulkUpdateRequest: Encodable {
  let ids: [String]
  let update: AssetBulkUpdate

  private enum CodingKeys: String, CodingKey {
    case ids, rating, isFavorite, visibility, dateTimeRelative, timeZone
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ids, forKey: .ids)
    switch update.rating {
    case .stars(let stars):
      try container.encode(min(max(stars, 1), 5), forKey: .rating)
    case .none?:
      try container.encodeNil(forKey: .rating)
    case nil:
      break
    }
    try container.encodeIfPresent(update.isFavorite, forKey: .isFavorite)
    try container.encodeIfPresent(update.visibility, forKey: .visibility)
    try container.encodeIfPresent(update.dateTimeRelativeMinutes, forKey: .dateTimeRelative)
    try container.encodeIfPresent(update.timeZone, forKey: .timeZone)
  }
}

private struct AssetEditsRequest: Encodable {
  let edits: [AssetEditItem]
}

private struct AssetEditsResponse: Decodable {
  let edits: [AssetEditItem]
}

/// One `AssetEditActionItemDto`. `parameters` is a crop, rotate, or mirror object chosen by `action`.
private struct AssetEditItem: Codable {
  let action: String
  let parameters: Parameters

  struct Parameters: Codable {
    var x: Int?
    var y: Int?
    var width: Int?
    var height: Int?
    var angle: Int?
    var axis: String?
  }

  init(_ model: AssetEditAction) {
    switch model {
    case .crop(let x, let y, let width, let height):
      action = "crop"
      parameters = Parameters(x: x, y: y, width: width, height: height)
    case .rotate(let degrees):
      action = "rotate"
      parameters = Parameters(angle: degrees)
    case .mirror(let axis):
      action = "mirror"
      parameters = Parameters(axis: axis)
    }
  }

  var model: AssetEditAction? {
    switch action {
    case "crop":
      guard let x = parameters.x, let y = parameters.y, let width = parameters.width, let height = parameters.height else { return nil }
      return .crop(x: x, y: y, width: width, height: height)
    case "rotate":
      return parameters.angle.map { .rotate(degrees: $0) }
    case "mirror":
      return parameters.axis.map { .mirror(axis: $0) }
    default:
      return nil
    }
  }
}

private struct DuplicateGroupResponse: Decodable {
  let duplicateId: String
  let assets: [AssetDetailResponse]
  let suggestedKeepAssetIds: [String]
}

private struct DuplicateResolveRequest: Encodable {
  let groups: [DuplicateResolveGroupRequest]
}

private struct DuplicateResolveGroupRequest: Encodable {
  let duplicateId: String
  let keepAssetIds: [String]
  let trashAssetIds: [String]
}

private struct ReverseGeocodeResponse: Decodable {
  let city: String?
  let state: String?
  let country: String?
}

private struct BulkLocationUpdateRequest: Encodable {
  let ids: [String]
  let latitude: Double
  let longitude: Double
}

// MARK: - Memory DTOs

private struct MemoryResponse: Decodable {
  let id: String
  let data: MemoryData?
  let memoryAt: String?
  let isSaved: Bool?
  let assets: [AssetDetailResponse]?

  struct MemoryData: Decodable {
    let year: Int?
  }

  func toModel() -> Memory {
    let parsedDate = memoryAt.flatMap { TimelineBucketMapper.parseDate($0) } ?? Date()
    let yearText = data?.year.map { "On This Day (\($0))" } ?? "Memory"
    let assetModels = (assets ?? []).compactMap { $0.toTimelineAsset() }
    return Memory(
      id: id,
      title: yearText,
      memoryAt: parsedDate,
      assetCount: assetModels.count,
      isSaved: isSaved ?? false,
      assets: assetModels
    )
  }
}

// MARK: - Upload DTOs

private struct UploadResponse: Decodable {
  let id: String
  let status: String
}

private struct CreateAlbumRequest: Encodable {
  let albumName: String
  let description: String
  let assetIds: [String]
}

private struct BulkIdsRequest: Encodable {
  let ids: [String]
}

private struct OAuthAuthorizeResponse: Decodable {
  let url: String
}

// MARK: - URL MIME Type Helper

extension URL {
  var mimeType: String {
    switch pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "heic": return "image/heic"
    case "heif": return "image/heif"
    case "webp": return "image/webp"
    case "mov": return "video/quicktime"
    case "mp4": return "video/mp4"
    case "m4v": return "video/x-m4v"
    case "avi": return "video/x-msvideo"
    case "tiff", "tif": return "image/tiff"
    case "raw", "dng", "cr2", "nef", "arw": return "image/raw"
    default: return "application/octet-stream"
    }
  }
}
