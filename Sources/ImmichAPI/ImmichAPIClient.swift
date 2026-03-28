import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImmichCore

public protocol ImmichAPIClient: Sendable {
  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo
  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration
  func login(server: ImmichServer, email: String, password: String) async throws -> UserSession
}

public enum ImmichAPIError: Error, LocalizedError, Sendable {
  case invalidResponse
  case requestFailed(statusCode: Int, message: String?)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The server response was invalid."
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

  public init(session: URLSession = .shared) {
    self.session = session
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

  private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ImmichAPIError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw apiError(from: data, statusCode: httpResponse.statusCode)
    }

    return try JSONDecoder().decode(Response.self, from: data)
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
