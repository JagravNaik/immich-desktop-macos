import Foundation
import XCTest
@testable import ImmichAPI
import ImmichCore

final class URLSessionImmichAPIClientTests: XCTestCase {
  private var handlerSessionIDs: [String] = []

  override func tearDown() {
    for sessionID in handlerSessionIDs {
      StubURLProtocol.removeRequestHandler(for: sessionID)
    }
    handlerSessionIDs.removeAll()
    super.tearDown()
  }

  func testFetchServerInfoWithoutAPIKeyUsesVersionEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/server/version")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"major":1,"minor":118,"patch":2}"#.data(using: .utf8)!
      return (response, data)
    })
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: nil
    )

    XCTAssertEqual(info.version, "1.118.2")
    XCTAssertNil(info.repository)
  }

  func testFetchServerInfoWithAPIKeyUsesAboutEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/server/about")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"version":"1.118.2","repository":"immich-app/immich"}"#.data(using: .utf8)!
      return (response, data)
    })
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: "secret"
    )

    XCTAssertEqual(info.version, "1.118.2")
    XCTAssertEqual(info.repository, "immich-app/immich")
  }

  func testFetchLoginConfigurationLoadsServerFeaturesAndConfig() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
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
    })
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
    let client = URLSessionImmichAPIClient(session: makeSession { request in
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
    })
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

  func testLoginWithAPIKeyUsesCurrentKeyAndUserEndpoints() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      let url = try XCTUnwrap(request.url)
      let responseHeaders = ["Content-Type": "application/json"]

      switch url.path {
      case "/api/api-keys/me":
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: responseHeaders)!
        let data = #"{"createdAt":"2026-03-30T12:00:00.000Z","id":"key-1","name":"Desktop Automation","permissions":["all"],"updatedAt":"2026-03-30T12:00:00.000Z"}"#.data(using: .utf8)!
        return (response, data)
      case "/api/users/me":
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: responseHeaders)!
        let data = #"{"avatarColor":"primary","email":"demo@immich.app","id":"user-1","name":"Demo User","profileChangedAt":"2026-03-30T12:00:00.000Z","profileImagePath":""}"#.data(using: .utf8)!
        return (response, data)
      case "/api/admin/users":
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: responseHeaders)!
        let data = #"[]"#.data(using: .utf8)!
        return (response, data)
      default:
        XCTFail("Unexpected request path: \(url.path)")
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: responseHeaders)!
        return (response, Data())
      }
    })
    let session = try await client.loginWithAPIKey(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: "secret"
    )

    XCTAssertTrue(session.usesAPIKey)
    XCTAssertEqual(session.apiKey, "secret")
    XCTAssertEqual(session.userName, "Demo User")
    XCTAssertEqual(session.userEmail, "demo@immich.app")
    XCTAssertEqual(session.userID, "user-1")
    XCTAssertTrue(session.isAdmin)
  }

  func testTimelineBucketsWithAPIKeySessionUseAPIKeyHeader() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/timeline/buckets")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"[]"#.data(using: .utf8)!
      return (response, data)
    })
    let session = UserSession(
      apiKey: "secret",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "API key session",
      userID: "key-1",
      userName: "Automation"
    )

    let buckets = try await client.fetchTimelineBuckets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session
    )

    XCTAssertTrue(buckets.isEmpty)
  }

  func testUploadAssetUsesMultipartBodyStreamAndReturnsID() async throws {
    let fileURL = try makeTempFile(named: "sample.jpg", contents: "image-data")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
      XCTAssertTrue(contentType.contains("multipart/form-data; boundary="))

      let body = try XCTUnwrap(self.requestBody(for: request))
      let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"deviceAssetId\""))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"deviceId\""))
      XCTAssertTrue(bodyString.contains("macos-desktop"))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(fileURL.lastPathComponent)\""))
      XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
      XCTAssertTrue(bodyString.contains("image-data"))
      XCTAssertNotNil(request.value(forHTTPHeaderField: "Content-Length"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
      let data = #"{"id":"asset-123"}"#.data(using: .utf8)!
      return (response, data)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )
    let progressRecorder = ProgressRecorder()

    let assetID = try await client.uploadAsset(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      fileURL: fileURL,
      onProgress: { progressRecorder.append($0) }
    )

    let progressUpdates = progressRecorder.snapshot()
    XCTAssertEqual(assetID, "asset-123")
    XCTAssertEqual(progressUpdates.first, 0)
    XCTAssertEqual(progressUpdates.last, 1)
  }

  func testUploadAssetThrowsWhenResponseIsInvalid() async throws {
    let fileURL = try makeTempFile(named: "sample.jpg", contents: "image-data")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let client = URLSessionImmichAPIClient(session: makeSession { request in
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
      let data = #"{"unexpected":"shape"}"#.data(using: .utf8)!
      return (response, data)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )

    do {
      _ = try await client.uploadAsset(
        server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
        session: session,
        fileURL: fileURL,
        onProgress: { _ in }
      )
      XCTFail("Expected invalid upload response to throw")
    } catch let error as ImmichAPIError {
      guard case .requestFailed(let statusCode, let message) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(statusCode, 201)
      XCTAssertEqual(message, "Invalid upload response")
    }
  }

  func testReplaceAssetUsesExpectedEndpointAndMultipartBody() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/asset-1/original")
      XCTAssertEqual(request.httpMethod, "PUT")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
      XCTAssertTrue(contentType.contains("multipart/form-data; boundary="))

      let body = try XCTUnwrap(self.requestBody(for: request))
      let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"deviceAssetId\""))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"assetData\"; filename=\"edited.png\""))
      XCTAssertTrue(bodyString.contains("Content-Type: image/png"))
      XCTAssertTrue(bodyString.contains("png-data"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )

    try await client.replaceAsset(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      assetId: "asset-1",
      imageData: Data("png-data".utf8),
      filename: "edited.png"
    )
  }

  func testImmichServerNormalizesRootEndpointToAPIBaseURL() throws {
    let server = ImmichServer(endpointURL: try XCTUnwrap(URL(string: "https://demo.immich.app")))
    XCTAssertEqual(server.baseURL.absoluteString, "https://demo.immich.app/api")
  }

  func testImmichServerPreservesAPIEndpointWithoutDuplicatingPath() throws {
    let server = ImmichServer(endpointURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api")))
    XCTAssertEqual(server.baseURL.absoluteString, "https://demo.immich.app/api")
  }

  func testImmichServerStripsQueryAndFragmentWhenNormalizingAPIEndpoint() throws {
    let server = ImmichServer(
      endpointURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api?foo=bar#debug"))
    )
    XCTAssertEqual(server.baseURL.absoluteString, "https://demo.immich.app/api")
  }

  private func makeSession(handler: @escaping StubURLProtocol.Handler) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let sessionID = UUID().uuidString
    configuration.httpAdditionalHeaders = [StubURLProtocol.handlerSessionHeader: sessionID]
    StubURLProtocol.setRequestHandler(handler, for: sessionID)
    handlerSessionIDs.append(sessionID)
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

    while true {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read > 0 {
        data.append(buffer, count: read)
      } else if read == 0 {
        break
      } else {
        let errorDescription = stream.streamError?.localizedDescription ?? "Unknown stream error"
        XCTFail("Failed to read HTTP body stream: \(errorDescription)")
        break
      }
    }

    return data
  }

  private func makeTempFile(named name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichAPITests", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let fileURL = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try Data(contents.utf8).write(to: fileURL)
    return fileURL
  }
}

private final class RequestHandlerStore: @unchecked Sendable {
  typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

  private let lock = NSLock()
  private var handlers: [String: Handler] = [:]

  func set(_ handler: @escaping Handler, for sessionID: String) {
    lock.lock()
    defer { lock.unlock() }
    handlers[sessionID] = handler
  }

  func get(for sessionID: String) -> Handler? {
    lock.lock()
    defer { lock.unlock() }
    return handlers[sessionID]
  }

  func remove(for sessionID: String) {
    lock.lock()
    defer { lock.unlock() }
    handlers.removeValue(forKey: sessionID)
  }
}

private final class StubURLProtocol: URLProtocol {
  typealias Handler = RequestHandlerStore.Handler
  private static let requestHandlerStore = RequestHandlerStore()
  static let handlerSessionHeader = "X-Immich-Test-Session-ID"

  static func setRequestHandler(_ handler: @escaping Handler, for sessionID: String) {
    requestHandlerStore.set(handler, for: sessionID)
  }

  static func removeRequestHandler(for sessionID: String) {
    requestHandlerStore.remove(for: sessionID)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: Self.handlerSessionHeader) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let sessionID = request.value(forHTTPHeaderField: Self.handlerSessionHeader),
          let handler = Self.requestHandlerStore.get(for: sessionID) else {
      XCTFail("Missing request handler")
      let error = NSError(
        domain: "StubURLProtocolError",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing request handler for test session header \(Self.handlerSessionHeader)"]
      )
      client?.urlProtocol(self, didFailWithError: error)
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

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double] = []

  func append(_ value: Double) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func snapshot() -> [Double] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
