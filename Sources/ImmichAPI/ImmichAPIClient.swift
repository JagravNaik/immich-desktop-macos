import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImmichCore

public protocol ImmichAPIClient {
  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo
}

public enum ImmichAPIError: Error, LocalizedError, Sendable {
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The server response was invalid."
    }
  }
}

public struct URLSessionImmichAPIClient: ImmichAPIClient {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo {
    var request = URLRequest(url: server.baseURL.appending(path: "server-info"))
    request.httpMethod = "GET"

    if let apiKey, apiKey.isEmpty == false {
      request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
      throw ImmichAPIError.invalidResponse
    }

    return try JSONDecoder().decode(ServerInfo.self, from: data)
  }
}
