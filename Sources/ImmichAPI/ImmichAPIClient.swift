import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImmichCore

private let debugLogURL = URL(fileURLWithPath: "/tmp/immich-debug.log")

private let isImmichDebugLoggingEnabled: Bool = {
  #if DEBUG
  return true
  #else
  return ProcessInfo.processInfo.environment["IMMICH_DEBUG_LOG"] == "1"
  #endif
}()

private let immichDebugLogMaxSize: UInt64 = 5 * 1024 * 1024 // 5 MB

public func immichLog(_ message: String) {
  guard isImmichDebugLoggingEnabled else { return }

  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  guard let data = line.data(using: .utf8) else { return }

  let fileManager = FileManager.default
  let path = debugLogURL.path

  if fileManager.fileExists(atPath: path) {
    if let attrs = try? fileManager.attributesOfItem(atPath: path),
       let size = attrs[.size] as? NSNumber,
       size.uint64Value > immichDebugLogMaxSize {
      try? fileManager.removeItem(at: debugLogURL)
    }
  }

  if fileManager.fileExists(atPath: path) {
    if let handle = try? FileHandle(forWritingTo: debugLogURL) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    }
  } else {
    try? data.write(to: debugLogURL)
  }
}

public protocol ImmichAPIClient: Sendable {
  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo
  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration
  func login(server: ImmichServer, email: String, password: String) async throws -> UserSession
  func loginWithAPIKey(server: ImmichServer, apiKey: String) async throws -> UserSession
  func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary]
  func fetchTimelineBucket(server: ImmichServer, session: UserSession, timeBucket: String) async throws -> [RemoteTimelineAsset]
  func fetchAlbums(server: ImmichServer, session: UserSession) async throws -> [Album]
  func fetchAlbumAssets(server: ImmichServer, session: UserSession, albumId: String) async throws -> (Album, [RemoteTimelineAsset])
  func fetchPeople(server: ImmichServer, session: UserSession) async throws -> [Person]
  func fetchAssetDetail(server: ImmichServer, session: UserSession, assetId: String) async throws -> AssetDetail
  func fetchAssetStatistics(server: ImmichServer, session: UserSession) async throws -> AssetStatistics
  func setFavorite(server: ImmichServer, session: UserSession, assetId: String, isFavorite: Bool) async throws
  func trashAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws
  func fetchTrashedAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset]
  func restoreAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws
  func searchAssets(server: ImmichServer, session: UserSession, query: String) async throws -> SearchResult
  func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset]
  func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker]
  func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory]
  func fetchSharedLinks(server: ImmichServer, session: UserSession) async throws -> ([SharedLink], [String: [RemoteTimelineAsset]])
  func downloadOriginalAsset(server: ImmichServer, session: UserSession, assetId: String) async throws -> (Data, String)
  func uploadAsset(server: ImmichServer, session: UserSession, fileURL: URL, onProgress: @Sendable (Double) -> Void) async throws -> String
  func createAlbum(server: ImmichServer, session: UserSession, name: String, description: String, assetIds: [String]) async throws -> Album
  func renameAlbum(server: ImmichServer, session: UserSession, albumId: String, newName: String) async throws
  func deleteAlbum(server: ImmichServer, session: UserSession, albumId: String) async throws
  func addAssetsToAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws
  func removeAssetsFromAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws
  func replaceAsset(server: ImmichServer, session: UserSession, assetId: String, imageData: Data, filename: String) async throws
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

  public func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration {
    async let features: ServerFeaturesResponse = perform(URLRequest(url: server.baseURL.appending(path: "server/features")))
    async let config: ServerConfigResponse = perform(URLRequest(url: server.baseURL.appending(path: "server/config")))

    let (featuresResponse, configResponse) = try await (features, config)
    return ServerLoginConfiguration(
      isInitialized: configResponse.isInitialized,
      isOnboarded: configResponse.isOnboarded,
      loginPageMessage: configResponse.loginPageMessage,
      oauthButtonText: configResponse.oauthButtonText,
      passwordLoginEnabled: featuresResponse.passwordLogin,
      oauthEnabled: featuresResponse.oauth
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

  public func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary] {
    var components = URLComponents(url: server.baseURL.appending(path: "timeline/buckets"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "order", value: "desc"),
      URLQueryItem(name: "visibility", value: "timeline"),
      URLQueryItem(name: "withCoordinates", value: "true"),
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
      URLQueryItem(name: "timeBucket", value: timeBucket),
      URLQueryItem(name: "visibility", value: "timeline"),
      URLQueryItem(name: "withCoordinates", value: "true"),
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
    let response: AlbumDetailResponse = try await perform(request)
    return (response.toAlbumModel(), response.toAssetModels())
  }

  // MARK: - People

  public func fetchPeople(server: ImmichServer, session: UserSession) async throws -> [Person] {
    var components = URLComponents(url: server.baseURL.appending(path: "people"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "withHidden", value: "false")]
    let request = authorizedRequest(url: components?.url ?? server.baseURL.appending(path: "people"), session: session)
    let response: PeopleResponse = try await perform(request)
    return response.people.map { $0.toModel() }
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

  // MARK: - Favorites

  public func setFavorite(server: ImmichServer, session: UserSession, assetId: String, isFavorite: Bool) async throws {
    var request = authorizedRequest(
      url: server.baseURL.appending(path: "assets").appending(path: assetId),
      session: session
    )
    request.httpMethod = "PUT"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["isFavorite": isFavorite])
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
    var request = authorizedRequest(url: server.baseURL.appending(path: "search/metadata"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TrashedSearchRequest())
    let response: SearchAssetsResponse = try await perform(request)
    return response.assets.items.compactMap { $0.toTimelineAsset() }
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

  // MARK: - Search

  public func searchAssets(server: ImmichServer, session: UserSession, query: String) async throws -> SearchResult {
    var request = authorizedRequest(url: server.baseURL.appending(path: "search/smart"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(SmartSearchRequest(query: query))
    let response: SearchAssetsResponse = try await perform(request)
    let assets = response.assets.items.compactMap { $0.toTimelineAsset() }
    return SearchResult(assets: assets, totalCount: response.assets.total ?? assets.count)
  }

  public func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset] {
    var request = authorizedRequest(url: server.baseURL.appending(path: "search/metadata"), session: session)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(MetadataSearchRequest(personIds: [personId]))
    let response: SearchAssetsResponse = try await perform(request)
    return response.assets.items.compactMap { $0.toTimelineAsset() }
  }

  // MARK: - Map

  public func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "map/markers"), session: session)
    let responses: [MapMarkerResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  // MARK: - Memories

  public func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory] {
    let request = authorizedRequest(url: server.baseURL.appending(path: "memories"), session: session)
    let responses: [MemoryResponse] = try await perform(request)
    return responses.map { $0.toModel() }
  }

  // MARK: - Shared Links

  public func fetchSharedLinks(server: ImmichServer, session: UserSession) async throws -> ([SharedLink], [String: [RemoteTimelineAsset]]) {
    let request = authorizedRequest(url: server.baseURL.appending(path: "shared-links"), session: session)
    let responses: [SharedLinkResponse] = try await perform(request)
    let links = responses.map { $0.toModel() }
    var assetsMap: [String: [RemoteTimelineAsset]] = [:]
    for response in responses {
      assetsMap[response.id] = response.toTimelineAssets()
    }
    return (links, assetsMap)
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

  public func uploadAsset(server: ImmichServer, session: UserSession, fileURL: URL, onProgress: @Sendable (Double) -> Void) async throws -> String {
    let boundary = UUID().uuidString
    let fileData = try Data(contentsOf: fileURL)
    let filename = fileURL.lastPathComponent
    let mimeType = fileURL.mimeType

    // Get file creation date
    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let createdDate = (attrs?[.creationDate] as? Date) ?? Date()
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let deviceAssetId = "\(filename)-\(Int(createdDate.timeIntervalSince1970 * 1000))"

    var body = Data()
    func appendField(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(value)\r\n".data(using: .utf8)!)
    }
    appendField("deviceAssetId", deviceAssetId)
    appendField("deviceId", "macos-desktop")
    appendField("fileCreatedAt", isoFormatter.string(from: createdDate))
    appendField("fileModifiedAt", isoFormatter.string(from: Date()))
    appendField("isFavorite", "false")

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(fileData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = authorizedRequest(url: server.baseURL.appending(path: "assets"), session: session)
    request.httpMethod = "POST"
    request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    onProgress(0.5) // halfway after building body
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Upload failed")
    }
    onProgress(1.0)

    if let json = try? JSONDecoder().decode(UploadResponse.self, from: data) {
      return json.id
    }
    return ""
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

  public func replaceAsset(server: ImmichServer, session: UserSession, assetId: String, imageData: Data, filename: String) async throws {
    let boundary = UUID().uuidString
    let mimeType: String
    if filename.lowercased().hasSuffix(".png") {
      mimeType = "image/png"
    } else {
      mimeType = "image/jpeg"
    }

    var body = Data()
    func appendField(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(value)\r\n".data(using: .utf8)!)
    }
    appendField("deviceAssetId", "\(filename)-edited-\(Int(Date().timeIntervalSince1970 * 1000))")
    appendField("deviceId", "macos-desktop")
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    appendField("fileCreatedAt", isoFormatter.string(from: Date()))
    appendField("fileModifiedAt", isoFormatter.string(from: Date()))

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(imageData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = authorizedRequest(
      url: server.baseURL
        .appendingPathComponent("assets")
        .appendingPathComponent(assetId)
        .appendingPathComponent("original"),
      session: session
    )
    request.httpMethod = "PUT"
    request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (_, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.requestFailed(
        statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
        message: "Replace asset failed"
      )
    }
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

  private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let requestURL = request.url?.absoluteString ?? "unknown"
    immichLog("[ImmichAPI] Request: \(request.httpMethod ?? "GET") \(requestURL)")
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ImmichAPIError.invalidResponse(url: requestURL)
    }

    immichLog("[ImmichAPI] Response: \(httpResponse.statusCode) from \(requestURL) (\(data.count) bytes)")

    guard (200...299).contains(httpResponse.statusCode) else {
      let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
      immichLog("[ImmichAPI] Error body: \(bodySnippet)")
      throw apiError(from: data, statusCode: httpResponse.statusCode)
    }

    do {
      let result = try JSONDecoder().decode(Response.self, from: data)
      immichLog("[ImmichAPI] Decoded \(String(describing: Response.self)) successfully")
      return result
    } catch {
      let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
      immichLog("[ImmichAPI] Decode FAILED for \(requestURL): \(error)")
      immichLog("[ImmichAPI] Body (500 chars): \(bodySnippet)")
      throw ImmichAPIError.decodingFailed(url: requestURL, detail: error.localizedDescription)
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

private struct ServerFeaturesResponse: Decodable {
  let oauth: Bool
  let passwordLogin: Bool
}

private struct ServerConfigResponse: Decodable {
  let isInitialized: Bool
  let isOnboarded: Bool
  let loginPageMessage: String
  let oauthButtonText: String
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
  let city: [String?]
  let country: [String?]
  let duration: [String?]
  let fileCreatedAt: [String]
  let id: [String]
  let isFavorite: [Bool]
  let isImage: [Bool]
  let isTrashed: [Bool]
  let latitude: [Double?]?
  let livePhotoVideoId: [String?]
  let localOffsetHours: [Double]
  let longitude: [Double?]?
  let ownerId: [String]
  let projectionType: [String?]
  let ratio: [Double]
  let stack: [[String]?]?
  let thumbhash: [String?]
  let visibility: [String]
}

private enum TimelineBucketMapper {
  static func assets(from response: TimelineBucketResponse) -> [RemoteTimelineAsset] {
    return response.id.indices.compactMap { index in
      guard
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

      let stackChildrenCount: Int?
      if let stackArray = response.stack,
         let maybePair = stackArray[safe: index],
         let pair = maybePair,
         let countString = pair[safe: 1] {
        stackChildrenCount = Int(countString)
      } else {
        stackChildrenCount = nil
      }

      return RemoteTimelineAsset(
        id: response.id[index],
        city: response.city[safe: index] ?? nil,
        country: response.country[safe: index] ?? nil,
        createdAt: createdAt,
        duration: response.duration[safe: index] ?? nil,
        isFavorite: isFavorite,
        isImage: isImage,
        isTrashed: isTrashed,
        latitude: response.latitude?[safe: index] ?? nil,
        longitude: response.longitude?[safe: index] ?? nil,
        livePhotoVideoID: response.livePhotoVideoId[safe: index] ?? nil,
        ownerID: ownerID,
        projectionType: response.projectionType[safe: index] ?? nil,
        ratio: ratio,
        stackChildrenCount: stackChildrenCount,
        thumbhash: response.thumbhash[safe: index] ?? nil,
        visibility: visibility
      )
    }
  }

  private static let dateFormats = [
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    "yyyy-MM-dd'T'HH:mm:ssZ",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
    "yyyy-MM-dd'T'HH:mm:ss"
  ]

  static func parseDate(_ value: String) -> Date? {
    // ISO8601DateFormatter is thread-safe unlike DateFormatter
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }
    // Fall back to per-call DateFormatter instances for non-standard formats
    for format in dateFormats {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .iso8601)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
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
  let hasSharedLink: Bool?
  let ownerId: String?

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
      hasSharedLink: hasSharedLink ?? false,
      ownerID: ownerId ?? ""
    )
  }
}

// MARK: - Album Detail Response (includes assets)

private struct AlbumDetailResponse: Decodable {
  let id: String
  let albumName: String
  let description: String?
  let assetCount: Int
  let albumThumbnailAssetId: String?
  let createdAt: String
  let updatedAt: String
  let isActivityEnabled: Bool?
  let shared: Bool?
  let hasSharedLink: Bool?
  let ownerId: String?
  let assets: [AlbumAssetResponse]?

  func toAlbumModel() -> Album {
    Album(
      id: id,
      albumName: albumName,
      description: description ?? "",
      assetCount: assetCount,
      albumThumbnailAssetId: albumThumbnailAssetId,
      createdAt: TimelineBucketMapper.parseDate(createdAt) ?? Date(),
      updatedAt: TimelineBucketMapper.parseDate(updatedAt) ?? Date(),
      isActivityEnabled: isActivityEnabled ?? false,
      shared: shared ?? false,
      hasSharedLink: hasSharedLink ?? false,
      ownerID: ownerId ?? ""
    )
  }

  func toAssetModels() -> [RemoteTimelineAsset] {
    (assets ?? []).compactMap { $0.toModel() }
  }
}

private struct AlbumAssetResponse: Decodable {
  let id: String
  let type: String?
  let fileCreatedAt: String?
  let duration: String?
  let isFavorite: Bool?
  let isTrashed: Bool?
  let livePhotoVideoId: String?
  let ownerId: String?
  let exifInfo: AlbumAssetExifResponse?
  let projectionType: String?
  let thumbhash: String?
  let stack: AlbumAssetStackResponse?

  func toModel() -> RemoteTimelineAsset? {
        guard let createdAtStr = fileCreatedAt,
          let createdAt = TimelineBucketMapper.parseDate(createdAtStr) else {
      return nil
    }
    let isImage = (type ?? "IMAGE") == "IMAGE"
    return RemoteTimelineAsset(
      id: id,
      city: exifInfo?.city,
      country: exifInfo?.country,
      createdAt: createdAt,
      duration: duration,
      isFavorite: isFavorite ?? false,
      isImage: isImage,
      isTrashed: isTrashed ?? false,
      latitude: exifInfo?.latitude,
      longitude: exifInfo?.longitude,
      livePhotoVideoID: livePhotoVideoId,
      ownerID: ownerId ?? "",
      projectionType: projectionType,
      ratio: 1.0,
      stackChildrenCount: stack?.assetCount,
      thumbhash: thumbhash,
      visibility: "timeline"
    )
  }
}

private struct AlbumAssetExifResponse: Decodable {
  let city: String?
  let country: String?
  let latitude: Double?
  let longitude: Double?
}

private struct AlbumAssetStackResponse: Decodable {
  let id: String?
  let assetCount: Int?
}

// MARK: - People Response DTOs

private struct PeopleResponse: Decodable {
  let total: Int
  let people: [PersonResponse]
}

private struct PersonResponse: Decodable {
  let id: String
  let name: String
  let birthDate: String?
  let thumbnailPath: String?
  let isHidden: Bool
  let updatedAt: String?

  func toModel() -> Person {
    let birthDateParsed: Date? = birthDate.flatMap { TimelineBucketMapper.parseDate($0) }
    return Person(
      id: id,
      name: name,
      birthDate: birthDateParsed,
      thumbnailPath: thumbnailPath ?? "",
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
  let localDateTime: String?
  let fileCreatedAt: String?
  let exifInfo: ExifInfoResponse?
  let isFavorite: Bool?
  let isTrashed: Bool?
  let duration: String?
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
      width: exifInfo?.exifImageWidth,
      height: exifInfo?.exifImageHeight,
      fileSizeInByte: exifInfo?.fileSizeInByte,
      isFavorite: isFavorite ?? false,
      duration: duration,
      livePhotoVideoId: livePhotoVideoId,
      exif: exifModel,
      tags: (tags ?? []).map { $0.toModel() }
    )
  }

  func toTimelineAsset() -> RemoteTimelineAsset? {
    guard let createdAt = fileCreatedAt.flatMap({ TimelineBucketMapper.parseDate($0) }) else { return nil }

    return RemoteTimelineAsset(
      id: id,
      city: exifInfo?.city,
      country: exifInfo?.country,
      createdAt: createdAt,
      duration: duration,
      isFavorite: isFavorite ?? false,
      isImage: (type ?? "IMAGE") == "IMAGE",
      isTrashed: isTrashed ?? false,
      latitude: exifInfo?.latitude,
      longitude: exifInfo?.longitude,
      livePhotoVideoID: livePhotoVideoId,
      ownerID: "",
      projectionType: nil,
      ratio: Double(exifInfo?.exifImageWidth ?? 1) / Double(exifInfo?.exifImageHeight ?? 1),
      stackChildrenCount: nil,
      thumbhash: nil,
      visibility: "timeline"
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
  let query: String
}

private struct MetadataSearchRequest: Encodable {
  let personIds: [String]
}

private struct SearchAssetsResponse: Decodable {
  let assets: SearchAssetsPage

  struct SearchAssetsPage: Decodable {
    let items: [AssetDetailResponse]
    let total: Int?
  }
}

// MARK: - Trash DTOs

private struct TrashRequest: Encodable {
  let ids: [String]
}

private struct TrashedSearchRequest: Encodable {
  let withDeleted = true
  let trashedAfter = "1970-01-01T00:00:00.000Z"
}

// MARK: - Map DTOs

private struct MapMarkerResponse: Decodable {
  let id: String
  let lat: Double
  let lon: Double
  let city: String?
  let country: String?

  func toModel() -> MapMarker {
    MapMarker(id: id, latitude: lat, longitude: lon, city: city, country: country)
  }
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

// MARK: - Shared Link DTOs

private struct SharedLinkResponse: Decodable {
  let id: String
  let type: String?
  let key: String?
  let description: String?
  let expiresAt: String?
  let allowUpload: Bool?
  let allowDownload: Bool?
  let assets: [AssetDetailResponse]?
  let album: AlbumResponse?
  let createdAt: String?

  func toModel() -> SharedLink {
    let parsedExpiry = expiresAt.flatMap { TimelineBucketMapper.parseDate($0) }
    let parsedCreated = createdAt.flatMap { TimelineBucketMapper.parseDate($0) } ?? Date()
    return SharedLink(
      id: id,
      type: type ?? "INDIVIDUAL",
      key: key ?? "",
      description: description,
      expiresAt: parsedExpiry,
      allowUpload: allowUpload ?? false,
      allowDownload: allowDownload ?? true,
      assetCount: assets?.count ?? album?.assetCount ?? 0,
      albumId: album?.id,
      createdAt: parsedCreated,
      assetIds: assets?.map(\.id) ?? []
    )
  }

  func toTimelineAssets() -> [RemoteTimelineAsset] {
    (assets ?? []).compactMap { $0.toTimelineAsset() }
  }
}

// MARK: - Upload DTOs

private struct UploadResponse: Decodable {
  let id: String
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
