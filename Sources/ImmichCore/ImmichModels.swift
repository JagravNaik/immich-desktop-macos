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
  public let loginPageMessage: String
  public let oauthButtonText: String
  public let passwordLoginEnabled: Bool
  public let oauthEnabled: Bool

  public init(
    loginPageMessage: String,
    oauthButtonText: String,
    passwordLoginEnabled: Bool,
    oauthEnabled: Bool
  ) {
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
  public let addedAt: Date?
  public let durationMilliseconds: Int?
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
    durationMilliseconds: Int?,
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
    visibility: String,
    addedAt: Date? = nil
  ) {
    self.id = id
    self.city = city
    self.country = country
    self.createdAt = createdAt
    self.addedAt = addedAt
    self.durationMilliseconds = durationMilliseconds
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

public struct SearchFilters: Sendable, Equatable {
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
  public let state: String?

  public init(id: String, latitude: Double, longitude: Double, city: String?, country: String?, state: String? = nil) {
    self.id = id
    self.latitude = latitude
    self.longitude = longitude
    self.city = city
    self.country = country
    self.state = state
  }
}

/// One Immich v3 non-destructive edit (`/assets/{id}/edits`): crop, rotate, or mirror.
/// Crop is in pixels from the top-left of the image as transformed by the preceding actions.
public enum AssetEditAction: Equatable, Hashable, Sendable {
  case crop(x: Int, y: Int, width: Int, height: Int)
  /// Clockwise degrees: 90, 180, or 270.
  case rotate(degrees: Int)
  /// `horizontal` or `vertical`.
  case mirror(axis: String)
}

/// Fields for Immich v3 bulk asset updates (`PUT /assets`). Only non-nil fields are sent.
public struct AssetBulkUpdate: Equatable, Sendable {
  public enum Rating: Equatable, Sendable {
    /// One to five stars (Photos' Set Star Rating ⌥1–⌥5).
    case stars(Int)
    /// Unrated (Photos' Remove Rating ⌥0). Immich v3 represents this as `null`.
    case none
  }

  public var rating: Rating?
  public var isFavorite: Bool?
  /// `timeline`, `hidden`, `archive`, or `locked`.
  public var visibility: String?
  /// Shift capture dates by this many minutes (Photos' Adjust Date and Time).
  public var dateTimeRelativeMinutes: Int?
  /// IANA time zone identifier.
  public var timeZone: String?

  public init(
    rating: Rating? = nil,
    isFavorite: Bool? = nil,
    visibility: String? = nil,
    dateTimeRelativeMinutes: Int? = nil,
    timeZone: String? = nil
  ) {
    self.rating = rating
    self.isFavorite = isFavorite
    self.visibility = visibility
    self.dateTimeRelativeMinutes = dateTimeRelativeMinutes
    self.timeZone = timeZone
  }
}

/// An Immich duplicate group (`GET /duplicates`), the backing for Photos' Utilities ▸ Duplicates.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
  public let id: String
  public let assets: [RemoteTimelineAsset]
  public let suggestedKeepAssetIDs: [String]

  public init(id: String, assets: [RemoteTimelineAsset], suggestedKeepAssetIDs: [String]) {
    self.id = id
    self.assets = assets
    self.suggestedKeepAssetIDs = suggestedKeepAssetIDs
  }

  /// IDs Photos' Merge Duplicates would discard: everything except the kept assets.
  public var suggestedTrashAssetIDs: [String] {
    let keep = Set(keepAssetIDs)
    return assets.map(\.id).filter { !keep.contains($0) }
  }

  /// Server suggestion, falling back to the first asset so a merge always keeps one item.
  public var keepAssetIDs: [String] {
    let known = Set(assets.map(\.id))
    let suggested = suggestedKeepAssetIDs.filter(known.contains)
    if !suggested.isEmpty { return suggested }
    return assets.first.map { [$0.id] } ?? []
  }
}

/// A place name returned by Immich reverse geocoding (`GET /map/reverse-geocode`).
public struct ReverseGeocodePlace: Hashable, Sendable {
  public let city: String?
  public let state: String?
  public let country: String?

  public init(city: String?, state: String?, country: String?) {
    self.city = city
    self.state = state
    self.country = country
  }

  /// Photos joins place components with ", " (`IPXPlacesMailingAddressOneLineDelimiter`).
  public var displayName: String? {
    let parts = [city, state, country].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
  public let durationMilliseconds: Int?
  public let ownerID: String?
  public let visibility: String?
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
    durationMilliseconds: Int?,
    livePhotoVideoId: String?,
    exif: ExifInfo?,
    tags: [ImmichTag],
    ownerID: String? = nil,
    visibility: String? = nil
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
    self.durationMilliseconds = durationMilliseconds
    self.livePhotoVideoId = livePhotoVideoId
    self.exif = exif
    self.tags = tags
    self.ownerID = ownerID
    self.visibility = visibility
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
  public let fileCreatedAt: Date?

  public init(
    id: UUID = UUID(),
    fileURL: URL,
    fileCreatedAt: Date? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.fileCreatedAt = fileCreatedAt
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
