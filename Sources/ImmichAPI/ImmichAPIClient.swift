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
  private let session: URLSession

  public init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: config)
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
    let (data, response) = try await session.data(for: request)
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

  nonisolated(unsafe) static let dateFormatters: [DateFormatter] = {
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
