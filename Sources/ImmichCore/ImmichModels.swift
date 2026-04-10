import Foundation

// MARK: - Server & Auth

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
    if let apiIndex = pathComponents.firstIndex(of: "api") {
      pathComponents = Array(pathComponents[...apiIndex])
    } else {
      pathComponents.append("api")
    }

    components.path = "/" + pathComponents.joined(separator: "/")
    components.query = nil
    components.fragment = nil
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

public struct VersionCheckState: Decodable, Sendable {
  public let checkedAt: String?
  public let releaseVersion: String?

  public init(checkedAt: String? = nil, releaseVersion: String? = nil) {
    self.checkedAt = checkedAt
    self.releaseVersion = releaseVersion
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

public enum SessionAuthentication: Sendable {
  case accessToken(String)
  case apiKey(String)

  public var headerField: String {
    switch self {
    case .accessToken:
      return "Authorization"
    case .apiKey:
      return "x-api-key"
    }
  }

  public var headerValue: String {
    switch self {
    case .accessToken(let token):
      return "Bearer \(token)"
    case .apiKey(let key):
      return key
    }
  }

  public var accessToken: String? {
    if case .accessToken(let token) = self {
      return token
    }
    return nil
  }

  public var apiKey: String? {
    if case .apiKey(let key) = self {
      return key
    }
    return nil
  }

  public var modeLabel: String {
    switch self {
    case .accessToken:
      return "Password"
    case .apiKey:
      return "API Key"
    }
  }
}

public struct UserSession: Sendable {
  public let authentication: SessionAuthentication
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
    self.authentication = .accessToken(accessToken)
    self.isAdmin = isAdmin
    self.shouldChangePassword = shouldChangePassword
    self.userEmail = userEmail
    self.userID = userID
    self.userName = userName
  }

  public init(
    apiKey: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    userEmail: String,
    userID: String,
    userName: String
  ) {
    self.authentication = .apiKey(apiKey)
    self.isAdmin = isAdmin
    self.shouldChangePassword = shouldChangePassword
    self.userEmail = userEmail
    self.userID = userID
    self.userName = userName
  }

  public var accessToken: String {
    authentication.accessToken ?? ""
  }

  public var apiKey: String? {
    authentication.apiKey
  }

  public var authHeaderField: String {
    authentication.headerField
  }

  public var authHeaderValue: String {
    authentication.headerValue
  }

  public var usesAPIKey: Bool {
    authentication.apiKey != nil
  }

  public var authenticationModeLabel: String {
    authentication.modeLabel
  }
}

public struct ImmichAPIKey: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let permissions: [String]
  public let createdAt: Date
  public let updatedAt: Date

  public init(id: String, name: String, permissions: [String], createdAt: Date, updatedAt: Date) {
    self.id = id
    self.name = name
    self.permissions = permissions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct CreatedAPIKey: Sendable {
  public let apiKey: ImmichAPIKey
  public let secret: String

  public init(apiKey: ImmichAPIKey, secret: String) {
    self.apiKey = apiKey
    self.secret = secret
  }
}

public struct ImmichTag: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let value: String
  public let color: String?
  public let parentID: String?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: String,
    name: String,
    value: String,
    color: String?,
    parentID: String?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.value = value
    self.color = color
    self.parentID = parentID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct AdminUser: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let email: String
  public let avatarColor: String
  public let isAdmin: Bool
  public let shouldChangePassword: Bool
  public let status: String
  public let createdAt: Date
  public let updatedAt: Date
  public let deletedAt: Date?
  public let oauthID: String
  public let profileChangedAt: Date
  public let profileImagePath: String
  public let quotaSizeInBytes: Int?
  public let quotaUsageInBytes: Int?
  public let storageLabel: String?

  public init(
    id: String,
    name: String,
    email: String,
    avatarColor: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    status: String,
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date?,
    oauthID: String,
    profileChangedAt: Date,
    profileImagePath: String,
    quotaSizeInBytes: Int?,
    quotaUsageInBytes: Int?,
    storageLabel: String?
  ) {
    self.id = id
    self.name = name
    self.email = email
    self.avatarColor = avatarColor
    self.isAdmin = isAdmin
    self.shouldChangePassword = shouldChangePassword
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.oauthID = oauthID
    self.profileChangedAt = profileChangedAt
    self.profileImagePath = profileImagePath
    self.quotaSizeInBytes = quotaSizeInBytes
    self.quotaUsageInBytes = quotaUsageInBytes
    self.storageLabel = storageLabel
  }

  public var isDeleted: Bool {
    status == "deleted" || deletedAt != nil
  }
}

// MARK: - Timeline

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

// MARK: - Albums

public struct Album: Identifiable, Hashable, Sendable {
  public let id: String
  public let albumName: String
  public let description: String
  public let assetCount: Int
  public let albumThumbnailAssetId: String?
  public let createdAt: Date
  public let updatedAt: Date
  public let isActivityEnabled: Bool
  public let shared: Bool
  public let ownerID: String

  public init(
    id: String,
    albumName: String,
    description: String,
    assetCount: Int,
    albumThumbnailAssetId: String?,
    createdAt: Date,
    updatedAt: Date,
    isActivityEnabled: Bool,
    shared: Bool,
    ownerID: String
  ) {
    self.id = id
    self.albumName = albumName
    self.description = description
    self.assetCount = assetCount
    self.albumThumbnailAssetId = albumThumbnailAssetId
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isActivityEnabled = isActivityEnabled
    self.shared = shared
    self.ownerID = ownerID
  }
}

// MARK: - People

public struct Person: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let birthDate: Date?
  public let thumbnailPath: String
  public let isHidden: Bool
  public let assetCount: Int

  public init(
    id: String,
    name: String,
    birthDate: Date?,
    thumbnailPath: String,
    isHidden: Bool,
    assetCount: Int
  ) {
    self.id = id
    self.name = name
    self.birthDate = birthDate
    self.thumbnailPath = thumbnailPath
    self.isHidden = isHidden
    self.assetCount = assetCount
  }
}

// MARK: - Search

public enum SearchType: String, CaseIterable, Identifiable, Sendable {
  case smart = "Smart"
  case filename = "Filename"
  case description = "Description"
  case ocr = "OCR"

  public var id: String { rawValue }
}

public struct SearchFilters: Sendable {
  public var cameraMake: String?
  public var cameraModel: String?
  public var city: String?
  public var country: String?
  public var takenAfter: Date?
  public var takenBefore: Date?
  public var mediaType: MediaType?
  public var isFavorite: Bool?

  public enum MediaType: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case image = "Image"
    case video = "Video"
    public var id: String { rawValue }
  }

  public init() {}

  public var isEmpty: Bool {
    cameraMake == nil && cameraModel == nil && city == nil && country == nil
      && takenAfter == nil && takenBefore == nil && mediaType == nil && isFavorite == nil
  }
}

public struct SearchResult: Sendable {
  public let assets: [RemoteTimelineAsset]
  public let totalCount: Int
  public let nextPage: String?

  public init(assets: [RemoteTimelineAsset], totalCount: Int, nextPage: String? = nil) {
    self.assets = assets
    self.totalCount = totalCount
    self.nextPage = nextPage
  }
}

public struct MapMarker: Identifiable, Hashable, Sendable {
  public let id: String
  public let latitude: Double
  public let longitude: Double
  public let city: String?
  public let country: String?

  public init(id: String, latitude: Double, longitude: Double, city: String?, country: String?) {
    self.id = id
    self.latitude = latitude
    self.longitude = longitude
    self.city = city
    self.country = country
  }
}

// MARK: - Memories

public struct Memory: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let memoryAt: Date
  public let assetCount: Int
  public let isSaved: Bool
  public let assets: [RemoteTimelineAsset]

  public init(
    id: String,
    title: String,
    memoryAt: Date,
    assetCount: Int,
    isSaved: Bool,
    assets: [RemoteTimelineAsset]
  ) {
    self.id = id
    self.title = title
    self.memoryAt = memoryAt
    self.assetCount = assetCount
    self.isSaved = isSaved
    self.assets = assets
  }
}

// MARK: - Asset Detail (full metadata)

public struct AssetDetail: Sendable {
  public let id: String
  public let type: String
  public let originalFileName: String
  public let localDateTime: Date?
  public let fileCreatedAt: Date?
  public let width: Int?
  public let height: Int?
  public let fileSizeInByte: Int?
  public let isFavorite: Bool
  public let duration: String?
  public let livePhotoVideoId: String?
  public let exif: ExifInfo?
  public let tags: [ImmichTag]

  public init(
    id: String,
    type: String,
    originalFileName: String,
    localDateTime: Date?,
    fileCreatedAt: Date?,
    width: Int?,
    height: Int?,
    fileSizeInByte: Int?,
    isFavorite: Bool,
    duration: String?,
    livePhotoVideoId: String?,
    exif: ExifInfo?,
    tags: [ImmichTag]
  ) {
    self.id = id
    self.type = type
    self.originalFileName = originalFileName
    self.localDateTime = localDateTime
    self.fileCreatedAt = fileCreatedAt
    self.width = width
    self.height = height
    self.fileSizeInByte = fileSizeInByte
    self.isFavorite = isFavorite
    self.duration = duration
    self.livePhotoVideoId = livePhotoVideoId
    self.exif = exif
    self.tags = tags
  }
}

public struct ExifInfo: Sendable {
  public let make: String?
  public let model: String?
  public let fNumber: Double?
  public let focalLength: Double?
  public let iso: Int?
  public let exposureTime: String?
  public let lensModel: String?
  public let city: String?
  public let state: String?
  public let country: String?
  public let latitude: Double?
  public let longitude: Double?
  public let description: String?
  public let rating: Int?
  public let dateTimeOriginal: Date?

  public init(
    make: String?, model: String?, fNumber: Double?, focalLength: Double?,
    iso: Int?, exposureTime: String?, lensModel: String?,
    city: String?, state: String?, country: String?,
    latitude: Double?, longitude: Double?,
    description: String?, rating: Int?, dateTimeOriginal: Date?
  ) {
    self.make = make
    self.model = model
    self.fNumber = fNumber
    self.focalLength = focalLength
    self.iso = iso
    self.exposureTime = exposureTime
    self.lensModel = lensModel
    self.city = city
    self.state = state
    self.country = country
    self.latitude = latitude
    self.longitude = longitude
    self.description = description
    self.rating = rating
    self.dateTimeOriginal = dateTimeOriginal
  }
}

// MARK: - Upload

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

// MARK: - Asset Statistics

public struct AssetStatistics: Sendable {
  public let total: Int
  public let images: Int
  public let videos: Int

  public init(total: Int, images: Int, videos: Int) {
    self.total = total
    self.images = images
    self.videos = videos
  }
}
