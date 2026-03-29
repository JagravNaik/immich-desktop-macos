import Foundation

public struct ImmichServer: Hashable, Sendable {
  public let baseURL: URL

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }

  public init(endpointURL: URL) {
    self.baseURL = Self.normalizedAPIBaseURL(from: endpointURL)
  }

  private static func normalizedAPIBaseURL(from endpointURL: URL) -> URL {
    guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
      return endpointURL
    }

    var pathComponents = components.path.split(separator: "/").map(String.init)
    if pathComponents.last != "api" {
      pathComponents.append("api")
    }

    components.path = "/" + pathComponents.joined(separator: "/")
    return components.url ?? endpointURL
  }
}

public struct ServerInfo: Decodable, Sendable {
  public let version: String
  public let repository: String?

  public init(version: String, repository: String? = nil) {
    self.version = version
    self.repository = repository
  }
}

public struct ServerLoginConfiguration: Sendable {
  public let isInitialized: Bool
  public let isOnboarded: Bool
  public let loginPageMessage: String
  public let oauthButtonText: String
  public let passwordLoginEnabled: Bool
  public let oauthEnabled: Bool

  public init(
    isInitialized: Bool,
    isOnboarded: Bool,
    loginPageMessage: String,
    oauthButtonText: String,
    passwordLoginEnabled: Bool,
    oauthEnabled: Bool
  ) {
    self.isInitialized = isInitialized
    self.isOnboarded = isOnboarded
    self.loginPageMessage = loginPageMessage
    self.oauthButtonText = oauthButtonText
    self.passwordLoginEnabled = passwordLoginEnabled
    self.oauthEnabled = oauthEnabled
  }
}

public struct UserSession: Sendable {
  public let accessToken: String
  public let isAdmin: Bool
  public let shouldChangePassword: Bool
  public let userEmail: String
  public let userID: String
  public let userName: String

  public init(
    accessToken: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    userEmail: String,
    userID: String,
    userName: String
  ) {
    self.accessToken = accessToken
    self.isAdmin = isAdmin
    self.shouldChangePassword = shouldChangePassword
    self.userEmail = userEmail
    self.userID = userID
    self.userName = userName
  }
}

public struct TimelineBucketSummary: Decodable, Hashable, Sendable {
  public let timeBucket: String
  public let count: Int

  public init(timeBucket: String, count: Int) {
    self.timeBucket = timeBucket
    self.count = count
  }
}

public struct RemoteTimelineAsset: Identifiable, Hashable, Sendable {
  public let id: String
  public let city: String?
  public let country: String?
  public let createdAt: Date
  public let duration: String?
  public let isFavorite: Bool
  public let isImage: Bool
  public let isTrashed: Bool
  public let latitude: Double?
  public let longitude: Double?
  public let livePhotoVideoID: String?
  public let ownerID: String
  public let projectionType: String?
  public let ratio: Double
  public let stackChildrenCount: Int?
  public let thumbhash: String?
  public let visibility: String

  public init(
    id: String,
    city: String?,
    country: String?,
    createdAt: Date,
    duration: String?,
    isFavorite: Bool,
    isImage: Bool,
    isTrashed: Bool,
    latitude: Double?,
    longitude: Double?,
    livePhotoVideoID: String?,
    ownerID: String,
    projectionType: String?,
    ratio: Double,
    stackChildrenCount: Int?,
    thumbhash: String?,
    visibility: String
  ) {
    self.id = id
    self.city = city
    self.country = country
    self.createdAt = createdAt
    self.duration = duration
    self.isFavorite = isFavorite
    self.isImage = isImage
    self.isTrashed = isTrashed
    self.latitude = latitude
    self.longitude = longitude
    self.livePhotoVideoID = livePhotoVideoID
    self.ownerID = ownerID
    self.projectionType = projectionType
    self.ratio = ratio
    self.stackChildrenCount = stackChildrenCount
    self.thumbhash = thumbhash
    self.visibility = visibility
  }
}

public struct UploadItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let fileURL: URL

  public init(id: UUID = UUID(), fileURL: URL) {
    self.id = id
    self.fileURL = fileURL
  }
}

public enum UploadState: Equatable, Sendable {
  case queued
  case uploading(progress: Double)
  case done
  case failed(reason: String)
}
