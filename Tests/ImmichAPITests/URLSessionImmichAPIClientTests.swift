import Foundation
import XCTest
@testable import ImmichAPI
import ImmichCore

final class URLSessionImmichAPIClientTests: XCTestCase {
  override func tearDown() {
    StubURLProtocol.requestHandler = nil
    super.tearDown()
  }

  func testFetchServerInfoWithoutAPIKeyUsesVersionEndpoint() async throws {
    StubURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/server/version")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"major":1,"minor":118,"patch":2}"#.data(using: .utf8)!
      return (response, data)
    }

    let client = URLSessionImmichAPIClient(session: makeSession())
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: nil
    )

    XCTAssertEqual(info.version, "1.118.2")
    XCTAssertNil(info.repository)
  }

  func testFetchServerInfoWithAPIKeyUsesAboutEndpoint() async throws {
    StubURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/server/about")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"version":"1.118.2","repository":"immich-app/immich"}"#.data(using: .utf8)!
      return (response, data)
    }

    let client = URLSessionImmichAPIClient(session: makeSession())
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: "secret"
    )

    XCTAssertEqual(info.version, "1.118.2")
    XCTAssertEqual(info.repository, "immich-app/immich")
  }

  func testFetchLoginConfigurationLoadsServerFeaturesAndConfig() async throws {
    StubURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!

      switch request.url?.path {
      case "/api/server/features":
        let data = #"{"oauth":true,"passwordLogin":true}"#.data(using: .utf8)!
        return (response, data)
      case "/api/server/config":
        let data = #"{"isInitialized":true,"isOnboarded":true,"loginPageMessage":"Welcome to Immich","oauthButtonText":"Continue with SSO"}"#.data(using: .utf8)!
        return (response, data)
      default:
        XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
        return (response, Data())
      }
    }

    let client = URLSessionImmichAPIClient(session: makeSession())
    let configuration = try await client.fetchLoginConfiguration(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api")))
    )

    XCTAssertTrue(configuration.isInitialized)
    XCTAssertTrue(configuration.isOnboarded)
    XCTAssertEqual(configuration.loginPageMessage, "Welcome to Immich")
    XCTAssertEqual(configuration.oauthButtonText, "Continue with SSO")
    XCTAssertTrue(configuration.passwordLoginEnabled)
    XCTAssertTrue(configuration.oauthEnabled)
  }

  func testLoginUsesAuthLoginEndpoint() async throws {
    StubURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/auth/login")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(LoginRequestPayload.self, from: body)
      XCTAssertEqual(payload.email, "demo@immich.app")
      XCTAssertEqual(payload.password, "demo")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
      let data = #"{"accessToken":"token","isAdmin":false,"isOnboarded":true,"name":"Demo User","profileImagePath":"","shouldChangePassword":false,"userEmail":"demo@immich.app","userId":"user-1"}"#.data(using: .utf8)!
      return (response, data)
    }

    let client = URLSessionImmichAPIClient(session: makeSession())
    let session = try await client.login(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      email: "demo@immich.app",
      password: "demo"
    )

    XCTAssertEqual(session.accessToken, "token")
    XCTAssertEqual(session.userName, "Demo User")
    XCTAssertEqual(session.userEmail, "demo@immich.app")
    XCTAssertEqual(session.userID, "user-1")
    XCTAssertFalse(session.isAdmin)
  }

  func testImmichServerNormalizesRootEndpointToAPIBaseURL() throws {
    let server = ImmichServer(endpointURL: try XCTUnwrap(URL(string: "https://demo.immich.app")))
    XCTAssertEqual(server.baseURL.absoluteString, "https://demo.immich.app/api")
  }

  func testImmichServerPreservesAPIEndpointWithoutDuplicatingPath() throws {
    let server = ImmichServer(endpointURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api")))
    XCTAssertEqual(server.baseURL.absoluteString, "https://demo.immich.app/api")
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func requestBody(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 {
        break
      }
      data.append(buffer, count: read)
    }

    return data
  }
}

private final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("Missing request handler")
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private struct LoginRequestPayload: Decodable {
  let email: String
  let password: String
}
