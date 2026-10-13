import Foundation
import XCTest
@testable import ImmichAPI
import ImmichCore

private let emptySearchResponseData = Data(#"{"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":0,"facets":[],"items":[],"nextCursor":null,"nextPage":null,"total":0}}"#.utf8)

final class URLSessionImmichAPIClientTests: XCTestCase {
  private var handlerSessionIDs: [String] = []
  private let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ImmichAPITests-\(UUID().uuidString)", isDirectory: true)

  override func tearDown() {
    for sessionID in handlerSessionIDs {
      StubURLProtocol.removeRequestHandler(for: sessionID)
    }
    handlerSessionIDs.removeAll()
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  func testFetchServerInfoWithoutAPIKeyUsesVersionEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/server/version")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"major":3,"minor":3,"patch":1}"#.data(using: .utf8)!
      return (response, data)
    })
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: nil
    )

    XCTAssertEqual(info.version, "3.3.1")
    XCTAssertNil(info.repository)
  }

  func testFetchServerInfoWithAPIKeyUsesAboutEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/server/about")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"version":"3.3.1","repository":"immich-app/immich"}"#.data(using: .utf8)!
      return (response, data)
    })
    let info = try await client.fetchServerInfo(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      apiKey: "secret"
    )

    XCTAssertEqual(info.version, "3.3.1")
    XCTAssertEqual(info.repository, "immich-app/immich")
  }

  func testFetchVersionCheckStateUsesAuthorizedVersionCheckEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/server/version-check")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"checkedAt":"2026-04-07T17:04:00.000Z","releaseVersion":"v3.3.1"}"#.data(using: .utf8)!
      return (response, data)
    })
    let session = UserSession(
      apiKey: "secret",
      isAdmin: true,
      shouldChangePassword: false,
      userEmail: "admin@example.com",
      userID: "admin-1",
      userName: "Admin"
    )

    let state = try await client.fetchVersionCheckState(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session
    )

    XCTAssertEqual(state.checkedAt, "2026-04-07T17:04:00.000Z")
    XCTAssertEqual(state.releaseVersion, "v3.3.1")
  }

  func testFetchLoginConfigurationUsesPublicConfig() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/public/config")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"""
      {"oauth":{"enabled":true,"buttonText":"Continue with SSO"},"passwordLogin":{"enabled":true},"server":{"loginPageMessage":"Welcome to Immich"},"theme":{"customCss":""}}
      """#.data(using: .utf8)!
      return (response, data)
    })
    let configuration = try await client.fetchLoginConfiguration(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api")))
    )

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

  func testTimelineBucketDecodesOptionalLocationAndMillisecondDuration() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/timeline/bucket")
      let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      XCTAssertEqual(
        components?.queryItems?.first(where: { $0.name == "timeBucket" })?.value,
        "2026-05-06T00:00:00.000Z"
      )
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"""
      {"createdAt":["2026-05-06T10:00:00.000Z"],"duration":[125000],"fileCreatedAt":["2026-05-06T10:00:00.000Z"],"id":["423e4567-e89b-42d3-a456-426614174003"],"isFavorite":[false],"isImage":[false],"isTrashed":[false],"livePhotoVideoId":[null],"localOffsetHours":[0.0],"ownerId":["223e4567-e89b-42d3-a456-426614174001"],"projectionType":[null],"ratio":[1.7778],"thumbhash":[null],"visibility":["timeline"]}
      """#.data(using: .utf8)!
      return (response, data)
    })

    let assets = try await client.fetchTimelineBucket(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      timeBucket: "2026-05-06"
    )

    XCTAssertEqual(assets.count, 1)
    XCTAssertNil(assets[0].city)
    XCTAssertNil(assets[0].country)
    XCTAssertEqual(assets[0].durationMilliseconds, 125_000)
  }

  func testTimelineBucketDecodeErrorIncludesMismatchedField() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/timeline/bucket")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"{"fileCreatedAt":[],"id":"not-an-array","isFavorite":[],"isImage":[],"isTrashed":[],"ownerId":[],"ratio":[],"visibility":[]}"#.data(using: .utf8)!
      return (response, data)
    })

    do {
      _ = try await client.fetchTimelineBucket(
        server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
        session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
        timeBucket: "2026-06-01"
      )
      XCTFail("Expected the malformed timeline response to fail decoding")
    } catch let error as ImmichAPIError {
      guard case let .decodingFailed(_, detail) = error else {
        XCTFail("Expected a decoding error, received \(error)")
        return
      }
      XCTAssertTrue(detail.contains("id"))
      XCTAssertTrue(detail.contains("JSON object keys"))
      XCTAssertFalse(detail.contains("not-an-array"))
    } catch {
      XCTFail("Expected ImmichAPIError, received \(error)")
    }
  }

  func testTimelineBucketDecodeErrorReportsRootShapeWithoutEchoingResponse() async throws {
    let sentinel = "private-response-value"
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/timeline/bucket")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      return (response, try JSONEncoder().encode(sentinel))
    })

    do {
      _ = try await client.fetchTimelineBucket(
        server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
        session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
        timeBucket: "2026-06-01"
      )
      XCTFail("Expected the malformed timeline response to fail decoding")
    } catch let error as ImmichAPIError {
      guard case let .decodingFailed(_, detail) = error else {
        XCTFail("Expected a decoding error, received \(error)")
        return
      }
      XCTAssertTrue(detail.contains("response root"))
      XCTAssertTrue(detail.contains("JSON string"))
      XCTAssertFalse(detail.contains(sentinel))
    } catch {
      XCTFail("Expected ImmichAPIError, received \(error)")
    }
  }


  func testAssetDetailMapsV3TopLevelDimensionsOwnerVisibilityAndDuration() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/423e4567-e89b-42d3-a456-426614174003")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"""
      {"id":"423e4567-e89b-42d3-a456-426614174003","type":"VIDEO","fileCreatedAt":"2026-05-06T10:00:00.000Z","duration":125000,"width":1920,"height":1080,"ownerId":"223e4567-e89b-42d3-a456-426614174001","visibility":"timeline"}
      """#.data(using: .utf8)!
      return (response, data)
    })

    let detail = try await client.fetchAssetDetail(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: "423e4567-e89b-42d3-a456-426614174003"
    )

    XCTAssertEqual(detail.width, 1920)
    XCTAssertEqual(detail.height, 1080)
    XCTAssertEqual(detail.ownerID, "223e4567-e89b-42d3-a456-426614174001")
    XCTAssertEqual(detail.visibility, "timeline")
    XCTAssertEqual(detail.durationMilliseconds, 125_000)
  }

  func testAlbumAssetsUseMetadataSearchAndAlbumUsersOwner() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      switch request.url?.path {
      case "/api/albums/123e4567-e89b-42d3-a456-426614174000":
        XCTAssertEqual(request.httpMethod, "GET")
        let data = #"""
        {"albumName":"Trip","albumThumbnailAssetId":null,"albumUsers":[{"role":"owner","user":{"avatarColor":"primary","email":"owner@example.com","id":"223e4567-e89b-42d3-a456-426614174001","name":"Owner","profileChangedAt":"2024-01-01T00:00:00.000Z","profileImagePath":""}}],"assetCount":1,"createdAt":"2026-05-01T10:00:00.000Z","description":"","hasSharedLink":false,"id":"123e4567-e89b-42d3-a456-426614174000","isActivityEnabled":false,"shared":false,"updatedAt":"2026-05-01T10:00:00.000Z"}
        """#.data(using: .utf8)!
        return (response, data)
      case "/api/search/metadata":
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(self.requestBody(for: request))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let filter = try XCTUnwrap(payload["filter"] as? [String: Any])
        let albumIDs = try XCTUnwrap(filter["albumIds"] as? [String: Any])
        XCTAssertEqual(albumIDs["any"] as? [String], ["123e4567-e89b-42d3-a456-426614174000"])
        let data = #"""
        {"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":1,"facets":[],"items":[{"id":"323e4567-e89b-42d3-a456-426614174002","type":"IMAGE","fileCreatedAt":"2026-05-06T10:00:00.000Z"}],"nextCursor":null,"nextPage":null,"total":1}}
        """#.data(using: .utf8)!
        return (response, data)
      default:
        XCTFail("Unexpected request: \(String(describing: request.url))")
        return (response, emptySearchResponseData)
      }
    })

    let (album, assets) = try await client.fetchAlbumAssets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      albumId: "123e4567-e89b-42d3-a456-426614174000"
    )

    XCTAssertEqual(album.ownerID, "223e4567-e89b-42d3-a456-426614174001")
    XCTAssertEqual(assets.map(\.id), ["323e4567-e89b-42d3-a456-426614174002"])
  }

  func testFetchPeopleUsesV3EnvelopeAndDateOnlyBirthDate() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/people")
      let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
      let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      XCTAssertEqual(queryItems["page"], "1")
      XCTAssertEqual(queryItems["size"], "1000")
      XCTAssertEqual(queryItems["withHidden"], "true")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      let data = #"""
      {"hidden":0,"people":[{"birthDate":"1995-04-05","id":"823e4567-e89b-42d3-a456-426614174007","isHidden":false,"name":"Person","otherPeople":[],"sharedBy":[],"sharedWith":[],"thumbnailPath":"/api/people/823e4567-e89b-42d3-a456-426614174007/thumbnail"}],"total":1,"hasNextPage":false}
      """#.data(using: .utf8)!
      return (response, data)
    })

    let people = try await client.fetchPeople(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo")
    )

    XCTAssertEqual(people.count, 1)
    XCTAssertEqual(people[0].id, "823e4567-e89b-42d3-a456-426614174007")
    XCTAssertFalse(people[0].isHidden)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(people[0].birthDate)), 1995)
    XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(people[0].birthDate)), 4)
    XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(people[0].birthDate)), 5)
  }

  func testTrashedAssetsEncodeNullableTrashedAtFilter() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/metadata")
      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let filter = try XCTUnwrap(payload["filter"] as? [String: Any])
      let trashedAt = try XCTUnwrap(filter["trashedAt"] as? [String: Any])
      XCTAssertTrue(trashedAt["ne"] is NSNull)
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, emptySearchResponseData)
    })

    let assets = try await client.fetchTrashedAssets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo")
    )
    XCTAssertTrue(assets.isEmpty)
  }

  func testEmptyTrashUsesImmichV3Endpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/trash/empty")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      XCTAssertNil(request.httpBody)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"{"count":2}"#.data(using: .utf8)!)
    })

    try await client.emptyTrash(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo")
    )
  }

  func testSetFavoriteUsesImmichV3PatchEndpoint() async throws {
    let assetID = "423e4567-e89b-42d3-a456-426614174003"
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Bool])
      XCTAssertEqual(payload["isFavorite"], true)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"{"id":"423e4567-e89b-42d3-a456-426614174003"}"#.data(using: .utf8)!)
    })

    try await client.setFavorite(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: assetID,
      isFavorite: true
    )
  }

  func testUpdateAssetLocationUsesImmichV3PatchEndpoint() async throws {
    let assetID = "423e4567-e89b-42d3-a456-426614174003"
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Double])
      XCTAssertEqual(try XCTUnwrap(payload["latitude"]), 37.7749, accuracy: 0.000001)
      XCTAssertEqual(try XCTUnwrap(payload["longitude"]), -122.4194, accuracy: 0.000001)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"{"id":"423e4567-e89b-42d3-a456-426614174003"}"#.data(using: .utf8)!)
    })

    try await client.updateAssetLocation(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: assetID,
      latitude: 37.7749,
      longitude: -122.4194
    )
  }

  func testUpdateAssetsLocationUsesImmichV3BulkPutEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets")
      XCTAssertEqual(request.httpMethod, "PUT")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Any])
      XCTAssertEqual(payload["ids"] as? [String], ["a", "b"])
      XCTAssertEqual(try XCTUnwrap(payload["latitude"] as? Double), 48.8584, accuracy: 0.000001)
      XCTAssertEqual(try XCTUnwrap(payload["longitude"] as? Double), 2.2945, accuracy: 0.000001)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    })

    try await client.updateAssetsLocation(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetIds: ["a", "b"],
      latitude: 48.8584,
      longitude: 2.2945
    )
  }

  func testUpdateAssetsEncodesOnlyProvidedFieldsAndNullRating() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets")
      XCTAssertEqual(request.httpMethod, "PUT")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Any])
      XCTAssertEqual(Set(payload.keys), ["ids", "rating", "visibility"])
      XCTAssertTrue(payload["rating"] is NSNull)
      XCTAssertEqual(payload["visibility"] as? String, "hidden")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    })

    try await client.updateAssets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetIds: ["a"],
      update: AssetBulkUpdate(rating: AssetBulkUpdate.Rating.none, visibility: "hidden")
    )
  }

  func testResolveDuplicatesSendsKeepAndTrashIDs() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/duplicates/resolve")
      XCTAssertEqual(request.httpMethod, "POST")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Any])
      let groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
      XCTAssertEqual(groups.first?["duplicateId"] as? String, "dup")
      XCTAssertEqual(groups.first?["keepAssetIds"] as? [String], ["b"])
      XCTAssertEqual(groups.first?["trashAssetIds"] as? [String], ["a"])
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data("[]".utf8))
    })
    let asset: (String) -> RemoteTimelineAsset = { id in
      RemoteTimelineAsset(
        id: id, city: nil, country: nil, createdAt: Date(), durationMilliseconds: nil, isFavorite: false,
        isImage: true, isTrashed: false, latitude: nil, longitude: nil, livePhotoVideoID: nil, ownerID: "u",
        projectionType: nil, ratio: 1, stackChildrenCount: nil, thumbhash: nil, visibility: "timeline"
      )
    }

    try await client.resolveDuplicates(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      groups: [DuplicateGroup(id: "dup", assets: [asset("a"), asset("b")], suggestedKeepAssetIDs: ["b"])]
    )
  }

  func testReplaceAssetEditsEncodesActionsAndFetchDecodesThem() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/a1/edits")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      if request.httpMethod == "PUT" {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: Any])
        let edits = try XCTUnwrap(payload["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.map { $0["action"] as? String }, ["rotate", "mirror", "crop"])
        XCTAssertEqual((edits[0]["parameters"] as? [String: Any])?["angle"] as? Int, 90)
        XCTAssertEqual((edits[1]["parameters"] as? [String: Any])?["axis"] as? String, "vertical")
        XCTAssertEqual(Set(((edits[2]["parameters"] as? [String: Any]) ?? [:]).keys), ["x", "y", "width", "height"])
        return (response, Data("{}".utf8))
      }
      XCTAssertEqual(request.httpMethod, "GET")
      let body = #"{"assetId":"a1","edits":[{"id":"e1","action":"crop","parameters":{"x":1,"y":2,"width":30,"height":40}},{"id":"e2","action":"rotate","parameters":{"angle":270}}]}"#
      return (response, Data(body.utf8))
    })
    let server = ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api")))
    let session = UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo")

    try await client.replaceAssetEdits(
      server: server, session: session, assetId: "a1",
      edits: [.rotate(degrees: 90), .mirror(axis: "vertical"), .crop(x: 0, y: 0, width: 10, height: 10)]
    )
    let fetched = try await client.fetchAssetEdits(server: server, session: session, assetId: "a1")
    XCTAssertEqual(fetched, [.crop(x: 1, y: 2, width: 30, height: 40), .rotate(degrees: 270)])
  }

  func testReplacingWithNoEditsDeletesThem() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/a1/edits")
      XCTAssertEqual(request.httpMethod, "DELETE")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    })
    try await client.replaceAssetEdits(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: "a1",
      edits: []
    )
  }

  func testReverseGeocodeSendsCoordinatesAndDecodesPlaces() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/map/reverse-geocode")
      let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
      XCTAssertEqual(items.first { $0.name == "lat" }?.value, "48.8584")
      XCTAssertEqual(items.first { $0.name == "lon" }?.value, "2.2945")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"[{"city":"Paris","state":"Île-de-France","country":"France"}]"#.data(using: .utf8)!)
    })

    let places = try await client.reverseGeocode(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      latitude: 48.8584,
      longitude: 2.2945
    )
    XCTAssertEqual(places.first?.displayName, "Paris, Île-de-France, France")
  }

  func testFetchAlbumMapMarkersUsesAlbumScopedEndpoint() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/albums/album-1/map-markers")
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"[{"id":"x","lat":1.5,"lon":2.5,"city":null,"state":null,"country":"Kenya"}]"#.data(using: .utf8)!)
    })

    let markers = try await client.fetchAlbumMapMarkers(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      albumId: "album-1"
    )
    XCTAssertEqual(markers, [MapMarker(id: "x", latitude: 1.5, longitude: 2.5, city: nil, country: "Kenya")])
  }

  func testUpdateAssetDescriptionUsesImmichV3PatchEndpoint() async throws {
    let assetID = "423e4567-e89b-42d3-a456-426614174003"
    let description = "Evening light over the bay"
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: String])
      XCTAssertEqual(payload["description"], description)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"{"id":"423e4567-e89b-42d3-a456-426614174003"}"#.data(using: .utf8)!)
    })

    try await client.updateAssetDescription(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: assetID,
      description: description
    )
  }

  func testUpdateAssetDateTimeUsesImmichV3PatchEndpoint() async throws {
    let assetID = "423e4567-e89b-42d3-a456-426614174003"
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-15T12:30:00Z"))
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets/\(assetID)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.requestBody(for: request))) as? [String: String])
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let encodedDate = try XCTUnwrap(payload["dateTimeOriginal"])
      let decodedDate = try XCTUnwrap(formatter.date(from: encodedDate))
      XCTAssertEqual(decodedDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, #"{"id":"423e4567-e89b-42d3-a456-426614174003"}"#.data(using: .utf8)!)
    })

    try await client.updateAssetDateTime(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: UserSession(accessToken: "token", isAdmin: false, shouldChangePassword: false, userEmail: "demo", userID: "user-1", userName: "Demo"),
      assetId: assetID,
      date: date
    )
  }


  func testSearchAssetsEncodesDateFiltersWithFractionalSeconds() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/smart")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(SmartSearchRequestPayload.self, from: body)
      XCTAssertEqual(payload.query, "mountain")
      XCTAssertEqual(payload.filter?.takenAt?.gte, "2026-05-24T12:34:56.789Z")
      XCTAssertEqual(payload.filter?.takenAt?.lte, "2026-05-25T01:02:03.012Z")
      XCTAssertEqual(payload.size, 1000)
      XCTAssertEqual(payload.page, 3)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, emptySearchResponseData)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    var filters = SearchFilters()
    filters.takenAfter = try XCTUnwrap(DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 5,
      day: 24,
      hour: 12,
      minute: 34,
      second: 56,
      nanosecond: 789_000_000
    ).date)
    filters.takenBefore = try XCTUnwrap(DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 5,
      day: 25,
      hour: 1,
      minute: 2,
      second: 3,
      nanosecond: 12_000_000
    ).date)

    let result = try await client.searchAssets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      query: "mountain",
      filters: filters,
      page: "3"
    )

    XCTAssertTrue(result.assets.isEmpty)
  }
  func testSearchMetadataTextEncodesDateFiltersWithFractionalSeconds() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/metadata")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(MetadataSearchRequestPayload.self, from: body)
      XCTAssertEqual(payload.originalFileName, "mountain")
      XCTAssertEqual(payload.filter?.takenAt?.gte, "2026-05-24T12:34:56.789Z")
      XCTAssertEqual(payload.filter?.takenAt?.lte, "2026-05-25T01:02:03.012Z")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, emptySearchResponseData)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    var filters = SearchFilters()
    filters.takenAfter = try XCTUnwrap(DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 5,
      day: 24,
      hour: 12,
      minute: 34,
      second: 56,
      nanosecond: 789_000_000
    ).date)
    filters.takenBefore = try XCTUnwrap(DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 5,
      day: 25,
      hour: 1,
      minute: 2,
      second: 3,
      nanosecond: 12_000_000
    ).date)

    let result = try await client.searchMetadataText(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      query: "mountain",
      filters: filters
    )

    XCTAssertTrue(result.assets.isEmpty)
  }

  func testSearchAssetsEncodesRequestedPageWithFilters() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/smart")
      XCTAssertEqual(request.httpMethod, "POST")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(SmartSearchRequestPayload.self, from: body)
      XCTAssertEqual(payload.query, "mountain")
      XCTAssertEqual(payload.filter?.isFavorite?.eq, true)
      XCTAssertEqual(payload.page, 3)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, emptySearchResponseData)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )

    var filters = SearchFilters()
    filters.isFavorite = true

    let result = try await client.searchAssets(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      query: "mountain",
      filters: filters,
      page: "3"
    )

    XCTAssertTrue(result.assets.isEmpty)
  }

  func testSearchMetadataTextEncodesRequestedCursor() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/metadata")
      XCTAssertEqual(request.httpMethod, "POST")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(MetadataSearchRequestPayload.self, from: body)
      XCTAssertEqual(payload.originalFileName, "mountain")
      XCTAssertEqual(payload.cursor, "cursor-4")

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!

      let data = #"{"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":0,"facets":[],"items":[],"nextCursor":"cursor-next","nextPage":null,"total":0}}"#.data(using: .utf8)!
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

    let result = try await client.searchMetadataText(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      query: "mountain",
      filters: SearchFilters(),
      page: "cursor-4"
    )

    XCTAssertTrue(result.assets.isEmpty)
    XCTAssertEqual(result.nextPage, "cursor-next")
  }

  func testSearchMetadataTextOmitsEmptyQueryWhenFiltersAreUsed() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/metadata")
      XCTAssertEqual(request.httpMethod, "POST")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(MetadataSearchRequestPayload.self, from: body)
      XCTAssertNil(payload.originalFileName)
      XCTAssertEqual(payload.filter?.isFavorite?.eq, true)

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, emptySearchResponseData)
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )
    var filters = SearchFilters()
    filters.isFavorite = true

    let result = try await client.searchMetadataText(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session,
      query: "",
      filters: filters
    )

    XCTAssertTrue(result.assets.isEmpty)
  }
  func testFetchScreenshotsIncludesIOSStylePNGScreenshotsAcrossCursorPages() async throws {
    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/search/metadata")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let body = try XCTUnwrap(self.requestBody(for: request))
      let payload = try JSONDecoder().decode(MetadataSearchRequestPayload.self, from: body)
      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!

      switch (payload.originalFileName, payload.originalPath, payload.cursor) {
      case (".png", nil, nil):
        XCTAssertEqual(payload.filter?.type?.eq, "IMAGE")
        XCTAssertEqual(payload.withExif, true)
        let data = #"""
        {"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":1,"facets":[],"items":[{"id":"523e4567-e89b-42d3-a456-426614174004","type":"IMAGE","originalFileName":"poster.png","fileCreatedAt":"2026-05-05T10:00:00.000Z","width":1200,"height":1800}],"nextCursor":"cursor-2","nextPage":"2","total":2}}
        """#.data(using: .utf8)!
        return (response, data)
      case (".png", nil, "cursor-2"):
        let data = #"""
        {"albums":{"count":0,"facets":[],"items":[],"total":0},"assets":{"count":1,"facets":[],"items":[{"id":"623e4567-e89b-42d3-a456-426614174005","type":"IMAGE","originalFileName":"IMG_0189.PNG","fileCreatedAt":"2026-05-06T10:00:00.000Z","width":1179,"height":2556}],"nextCursor":null,"nextPage":null,"total":2}}
        """#.data(using: .utf8)!
        return (response, data)
      case ("screenshot", nil, nil), ("screen shot", nil, nil), ("screen_shot", nil, nil), ("screen-shot", nil, nil), (nil, "screenshots", nil):
        return (response, emptySearchResponseData)
      default:
        XCTFail("Unexpected metadata search payload: \(payload)")
        return (response, emptySearchResponseData)
      }
    })
    let session = UserSession(
      accessToken: "token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "demo@immich.app",
      userID: "user-1",
      userName: "Demo User"
    )

    let screenshots = try await client.fetchScreenshots(
      server: ImmichServer(baseURL: try XCTUnwrap(URL(string: "https://demo.immich.app/api"))),
      session: session
    )

    XCTAssertEqual(screenshots.map(\.id), ["623e4567-e89b-42d3-a456-426614174005"])
  }

  func testUploadAssetUsesMultipartBodyStreamAndReturnsID() async throws {
    let fileURL = try makeTempFile(named: "sample.mov", contents: "video-data")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let fileModifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
    try FileManager.default.setAttributes([.modificationDate: fileModifiedAt], ofItemAtPath: fileURL.path)

    let client = URLSessionImmichAPIClient(session: makeSession { request in
      XCTAssertEqual(request.url?.path, "/api/assets")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

      let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
      XCTAssertTrue(contentType.contains("multipart/form-data; boundary="))

      let body = try XCTUnwrap(self.requestBody(for: request))
      let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
      XCTAssertFalse(bodyString.contains("Content-Disposition: form-data; name=\"deviceAssetId\""))
      XCTAssertFalse(bodyString.contains("Content-Disposition: form-data; name=\"deviceId\""))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n2023-11-14T22:13:20.000Z"))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"duration\"\r\n\r\n1250"))
      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n2023-11-14T22:15:00.000Z"))

      XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(fileURL.lastPathComponent)\""))
      XCTAssertTrue(bodyString.contains("Content-Type: video/quicktime"))
      XCTAssertTrue(bodyString.contains("video-data"))
      XCTAssertNotNil(request.value(forHTTPHeaderField: "Content-Length"))

      let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: nil)!
      let data = #"{"id":"723e4567-e89b-42d3-a456-426614174006","status":"created"}"#.data(using: .utf8)!
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
      fileCreatedAt: fileCreatedAt,
      durationMilliseconds: 1250,
      onProgress: { progressRecorder.append($0) }
    )

    let progressUpdates = progressRecorder.snapshot()
    XCTAssertEqual(assetID, "723e4567-e89b-42d3-a456-426614174006")
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
        durationMilliseconds: nil,
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
    try FileManager.default.createDirectory(
      at: tempDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let fileURL = tempDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
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

private struct DateFilterPayload: Decodable {
  let gte: String?
  let lte: String?
}

private struct StringEqualityPayload: Decodable {
  let eq: String?
}

private struct BoolEqualityPayload: Decodable {
  let eq: Bool?
}

private struct SearchFilterPayload: Decodable {
  let takenAt: DateFilterPayload?
  let type: StringEqualityPayload?
  let isFavorite: BoolEqualityPayload?
}

private struct SmartSearchRequestPayload: Decodable {
  let query: String?
  let filter: SearchFilterPayload?
  let size: Int?
  let page: Int?
}

private struct MetadataSearchRequestPayload: Decodable, CustomStringConvertible {
  let originalFileName: String?
  let originalPath: String?
  let cursor: String?
  let filter: SearchFilterPayload?
  let size: Int?
  let withExif: Bool?

  var description: String {
    "MetadataSearchRequestPayload(originalFileName: \(originalFileName ?? "nil"), originalPath: \(originalPath ?? "nil"), cursor: \(cursor ?? "nil"), withExif: \(withExif.map(String.init) ?? "nil"))"
  }
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
