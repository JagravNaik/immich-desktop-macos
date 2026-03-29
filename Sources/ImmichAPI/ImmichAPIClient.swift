import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImmichCore

private let debugLogURL = URL(fileURLWithPath: "/tmp/immich-debug.log")

public func immichLog(_ message: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  if let data = line.data(using: .utf8) {
    if FileManager.default.fileExists(atPath: debugLogURL.path) {
      if let handle = try? FileHandle(forWritingTo: debugLogURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      }
    } else {
      try? data.write(to: debugLogURL)
    }
  }
}

public protocol ImmichAPIClient: Sendable {
  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo
  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration
  func login(server: ImmichServer, email: String, password: String) async throws -> UserSession
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
    request.addValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
    return request
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

  static let dateFormatters: [DateFormatter] = {
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
      "yyyy-MM-dd'T'HH:mm:ssZ",
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ss"
    ]
    return formats.map { format in
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .iso8601)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter
    }
  }()

  private static func parseDate(_ value: String) -> Date? {
    for formatter in dateFormatters {
      if let date = formatter.date(from: value) {
        return date
      }
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
      createdAt: createdAt.flatMap { s in TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first } ?? Date(),
      updatedAt: updatedAt.flatMap { s in TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first } ?? Date(),
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
      createdAt: TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: createdAt) }.first ?? Date(),
      updatedAt: TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: updatedAt) }.first ?? Date(),
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
          let createdAt = TimelineBucketMapper.dateFormatters.lazy.compactMap({ $0.date(from: createdAtStr) }).first else {
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
    let birthDateParsed: Date? = birthDate.flatMap { dateStr in
      TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: dateStr) }.first
    }
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
        dateTimeOriginal: e.dateTimeOriginal.flatMap { s in
          TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
        }
      )
    }
    return AssetDetail(
      id: id,
      type: type ?? "IMAGE",
      originalFileName: originalFileName ?? "",
      localDateTime: localDateTime.flatMap { s in
        TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
      },
      fileCreatedAt: fileCreatedAt.flatMap { s in
        TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
      },
      width: exifInfo?.exifImageWidth,
      height: exifInfo?.exifImageHeight,
      fileSizeInByte: exifInfo?.fileSizeInByte,
      isFavorite: isFavorite ?? false,
      duration: duration,
      livePhotoVideoId: livePhotoVideoId,
      exif: exifModel
    )
  }

  func toTimelineAsset() -> RemoteTimelineAsset? {
    guard let createdAt = fileCreatedAt.flatMap({ s in
      TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
    }) else { return nil }

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
    let parsedDate = memoryAt.flatMap { s in
      TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
    } ?? Date()
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
    let parsedExpiry = expiresAt.flatMap { s in
      TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
    }
    let parsedCreated = createdAt.flatMap { s in
      TimelineBucketMapper.dateFormatters.lazy.compactMap { $0.date(from: s) }.first
    } ?? Date()
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
